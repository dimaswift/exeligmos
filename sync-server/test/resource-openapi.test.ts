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
  assert.equal(parameterReference(paths, "/v1/records", "get", 1),
    "#/components/parameters/RecordLimit");
  assert.equal(parameterReference(paths, "/v1/public/records", "get", 1),
    "#/components/parameters/RecordLimit");
  assert.equal(parameterReference(paths, "/v1/devices", "get", 1),
    "#/components/parameters/Limit");
  assert.equal(parameterReference(paths, "/v1/api-keys", "get", 1),
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
    ["/v1/me", "get"],
    ["/v1/me/encryption-profile", "get"],
    ["/v1/me/encryption-profile", "post"],
    ["/v1/api-keys", "get"],
    ["/v1/api-keys", "post"],
    ["/v1/api-keys/{apiKeyId}", "get"],
    ["/v1/api-keys/{apiKeyId}", "delete"],
    ["/v1/devices", "get"],
    ["/v1/devices", "post"],
    ["/v1/devices/{deviceId}", "get"],
    ["/v1/devices/{deviceId}", "patch"],
    ["/v1/devices/{deviceId}", "delete"],
    ["/v1/devices/{deviceId}/current-session", "put"],
    ["/v1/records", "get"],
    ["/v1/records", "post"],
    ["/v1/records/{recordId}", "get"],
    ["/v1/records/{recordId}", "put"],
    ["/v1/records/{recordId}", "patch"],
    ["/v1/records/{recordId}", "delete"],
    ["/v1/public/records", "get"],
    ["/v1/public/records/{recordId}", "get"],
    ["/v1/events", "get"],
    ["/v1/events", "post"],
    ["/v1/events/{eventId}", "get"],
    ["/v1/events/{eventId}", "patch"],
    ["/v1/events/{eventId}", "delete"],
    ["/v1/public/events", "get"],
    ["/v1/public/events/{eventId}", "get"],
    ["/v1/public/users/{login}", "get"],
    ["/v1/subscriptions", "get"],
    ["/v1/subscriptions/{targetUserId}", "put"],
    ["/v1/subscriptions/{targetUserId}", "delete"],
    ["/v1/public/activity", "get"],
    ["/v1/activity", "get"],
    ["/v1/tags", "get"],
    ["/v1/tags", "post"],
    ["/v1/tags/{tagId}", "get"],
    ["/v1/tags/{tagId}", "patch"],
    ["/v1/tags/{tagId}", "delete"],
    ["/v1/templates", "get"],
    ["/v1/templates", "post"],
    ["/v1/templates/{templateId}", "get"],
    ["/v1/templates/{templateId}", "patch"],
    ["/v1/templates/{templateId}", "delete"],
    ["/v1/media-upload-sessions", "post"],
    ["/v1/media-upload-sessions/{uploadId}", "get"],
    ["/v1/media-upload-sessions/{uploadId}", "delete"],
    ["/v1/media-upload-sessions/{uploadId}/content", "put"],
    ["/v1/media-upload-sessions/{uploadId}/complete", "post"],
    ["/v1/media/{mediaId}", "get"],
    ["/v1/media/{mediaId}", "delete"],
    ["/v1/media/{mediaId}/content", "get"],
    ["/v1/public/media/{mediaId}/content", "get"],
    ["/v1/sync/changes", "get"],
    ["/v1/sync/batches", "post"],
  ];
  for (const [pathName, method] of limited) {
    const responses = object(operation(paths, pathName, method).responses);
    assert.ok("429" in responses, `${method.toUpperCase()} ${pathName} must advertise 429`);
    assert.ok("503" in responses, `${method.toUpperCase()} ${pathName} must advertise 503`);
  }
  for (const [pathName, method] of [
    ["/health/live", "get"],
    ["/health/ready", "get"],
    ["/v1/auth/logout", "post"],
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
