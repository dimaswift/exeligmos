import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";

import { parse } from "yaml";

type JsonObject = Record<string, unknown>;

test("OpenAPI publishes the exact resource amplification policy", async () => {
  const contract = object(
    parse(await readFile(path.resolve(process.cwd(), "openapi/openapi.yaml"), "utf8")),
  );
  const components = object(contract.components);
  const parameters = object(components.parameters);
  const recordLimit = object(parameters.RecordLimit);
  assert.deepEqual(object(recordLimit.schema), {
    type: "integer",
    minimum: 1,
    maximum: 25,
    default: 10,
  });

  const paths = object(contract.paths);
  assert.equal(parameterReference(paths, "/records", "get", 1),
    "#/components/parameters/RecordLimit");
  assert.equal(parameterReference(paths, "/public/records", "get", 1),
    "#/components/parameters/RecordLimit");
  assert.equal(parameterReference(paths, "/devices", "get", 1),
    "#/components/parameters/Limit");
  assert.equal(parameterReference(paths, "/api-keys", "get", 1),
    "#/components/parameters/Limit");

  const policy = object(contract["x-exeligmos-resource-rate-limits"]);
  assert.deepEqual(policy, {
    windowSeconds: 60,
    publicRecordReads: { cluster: 3_000, perIp: 120 },
    authenticatedReads: { perUser: 1_200, perPrincipal: 600 },
    authenticatedWrites: { perUser: 240, perPrincipal: 120 },
  });

  const schemas = object(components.schemas);
  assert.equal(object(schemas.PublicRecordPayload)["x-max-serialized-bytes"], 262_144);
  assert.equal(object(schemas.ResourceMetadata)["x-max-serialized-bytes"], 32_768);
  const cipherProperties = object(object(schemas.CiphertextEnvelope).properties);
  const ciphertext = object(cipherProperties.ciphertext);
  assert.equal(ciphertext.maxLength, 699_052);
  assert.equal(ciphertext["x-max-decoded-bytes"], 524_288);
});

test("OpenAPI advertises 429 and 503 on every implemented limited resource operation", async () => {
  const contract = object(
    parse(await readFile(path.resolve(process.cwd(), "openapi/openapi.yaml"), "utf8")),
  );
  const paths = object(contract.paths);
  const limited: readonly (readonly [string, string])[] = [
    ["/me", "get"],
    ["/me", "patch"],
    ["/me/encryption-profile", "get"],
    ["/me/encryption-profile", "post"],
    ["/api-keys", "get"],
    ["/api-keys", "post"],
    ["/api-keys/{apiKeyId}", "get"],
    ["/api-keys/{apiKeyId}", "delete"],
    ["/devices", "get"],
    ["/devices", "post"],
    ["/devices/{deviceId}", "get"],
    ["/devices/{deviceId}", "patch"],
    ["/devices/{deviceId}", "delete"],
    ["/devices/{deviceId}/current-session", "put"],
    ["/records", "get"],
    ["/records", "post"],
    ["/records/{recordId}", "get"],
    ["/records/{recordId}", "put"],
    ["/records/{recordId}", "patch"],
    ["/records/{recordId}", "delete"],
    ["/public/records", "get"],
    ["/public/records/{recordId}", "get"],
    ["/events", "get"],
    ["/events", "post"],
    ["/events/{eventId}", "get"],
    ["/events/{eventId}", "patch"],
    ["/events/{eventId}", "delete"],
    ["/public/events", "get"],
    ["/public/events/{eventId}", "get"],
    ["/public/users/{login}", "get"],
    ["/subscriptions", "get"],
    ["/subscriptions/{targetUserId}", "put"],
    ["/subscriptions/{targetUserId}", "delete"],
    ["/public/activity", "get"],
    ["/activity", "get"],
    ["/tags", "get"],
    ["/tags", "post"],
    ["/tags/{tagId}", "get"],
    ["/tags/{tagId}", "patch"],
    ["/tags/{tagId}", "delete"],
    ["/templates", "get"],
    ["/templates", "post"],
    ["/templates/{templateId}", "get"],
    ["/templates/{templateId}", "patch"],
    ["/templates/{templateId}", "delete"],
    ["/media-upload-sessions", "post"],
    ["/media-upload-sessions/{uploadId}", "get"],
    ["/media-upload-sessions/{uploadId}", "delete"],
    ["/media-upload-sessions/{uploadId}/content", "put"],
    ["/media-upload-sessions/{uploadId}/complete", "post"],
    ["/media/{mediaId}", "get"],
    ["/media/{mediaId}", "delete"],
    ["/media/{mediaId}/content", "get"],
    ["/public/media/{mediaId}/content", "get"],
    ["/sync/changes", "get"],
    ["/sync/batches", "post"],
  ];
  for (const [pathName, method] of limited) {
    const responses = object(operation(paths, pathName, method).responses);
    assert.ok("429" in responses, `${method.toUpperCase()} ${pathName} must advertise 429`);
    assert.ok("503" in responses, `${method.toUpperCase()} ${pathName} must advertise 503`);
  }
  for (const [pathName, method] of [
    ["/health/live", "get"],
    ["/health/ready", "get"],
    ["/auth/logout", "post"],
  ] as const) {
    assert.equal("429" in object(operation(paths, pathName, method).responses), false);
  }
});

function object(value: unknown): JsonObject {
  assert.ok(value !== null && typeof value === "object" && !Array.isArray(value));
  return value as JsonObject;
}

function operation(paths: JsonObject, pathName: string, method: string): JsonObject {
  return object(object(paths[pathName])[method]);
}

function parameterReference(
  paths: JsonObject,
  pathName: string,
  method: string,
  index: number,
): unknown {
  const parameters = operation(paths, pathName, method).parameters;
  assert.ok(Array.isArray(parameters));
  return object(parameters[index]).$ref;
}
