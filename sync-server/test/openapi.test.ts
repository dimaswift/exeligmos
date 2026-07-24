import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";

import { parse } from "yaml";

type JsonObject = Record<string, unknown>;

function object(value: unknown, label: string): JsonObject {
  assert.ok(value !== null && typeof value === "object" && !Array.isArray(value), label);
  return value as JsonObject;
}

function array(value: unknown, label: string): unknown[] {
  assert.ok(Array.isArray(value), label);
  return value;
}

async function loadContract(): Promise<JsonObject> {
  const contractPath = path.resolve(process.cwd(), "openapi/openapi.yaml");
  return object(parse(await readFile(contractPath, "utf8")), "OpenAPI document must be an object");
}

test("OpenAPI contract exposes the complete resource surface", async () => {
  const contract = await loadContract();
  assert.equal(contract.openapi, "3.1.0");

  const paths = object(contract.paths, "paths must be defined");
  const requiredPaths = [
    "/health/live",
    "/health/ready",
    "/auth/register",
    "/auth/login",
    "/auth/refresh",
    "/me",
    "/me/encryption-profile",
    "/api-keys",
    "/devices",
    "/records",
    "/records/{recordId}",
    "/public/records",
    "/public/records/{recordId}",
    "/events",
    "/events/{eventId}",
    "/public/events",
    "/public/events/{eventId}",
    "/public/users/{login}",
    "/subscriptions",
    "/subscriptions/{targetUserId}",
    "/public/activity",
    "/activity",
    "/sync/changes",
    "/sync/batches",
  ];

  for (const requiredPath of requiredPaths) {
    assert.ok(requiredPath in paths, `missing required path ${requiredPath}`);
  }

  const operationIds: string[] = [];
  for (const pathItem of Object.values(paths)) {
    const operations = object(pathItem, "path item must be an object");
    for (const method of ["get", "post", "put", "patch", "delete"]) {
      const operation = operations[method];
      if (operation === undefined) {
        continue;
      }
      const operationId = object(operation, `${method} operation must be an object`).operationId;
      assert.equal(typeof operationId, "string", `${method} operation must have an operationId`);
      operationIds.push(operationId as string);
    }
  }

  assert.ok(operationIds.length >= 40, "contract should retain the complete API surface");
  assert.equal(new Set(operationIds).size, operationIds.length, "operationId values must be unique");

  const syncChanges = object(object(paths["/sync/changes"], "sync path").get, "sync GET");
  const syncParameters = array(syncChanges.parameters, "sync parameters");
  const resourceTypeParameter = object(syncParameters[2], "sync resourceType parameter");
  assert.equal(
    object(resourceTypeParameter.schema, "sync resourceType schema").maxItems,
    8,
  );
});

test("OpenAPI exposes the per-user Saros anchor and ETag-protected update", async () => {
  const contract = await loadContract();
  const paths = object(contract.paths, "paths must be defined");
  const components = object(contract.components, "components must be defined");
  const schemas = object(components.schemas, "schemas must be defined");

  const me = object(paths["/me"], "/me must exist");
  const update = object(me.patch, "PATCH /me must exist");
  assert.equal(update.operationId, "updateCurrentUser");
  assert.deepEqual(update.security, [{ JwtBearer: [] }]);
  assert.equal(
    object(array(update.parameters, "PATCH /me parameters")[0], "If-Match parameter").$ref,
    "#/components/parameters/IfMatch",
  );

  const sarosAnchor = object(schemas.SarosAnchor, "SarosAnchor must exist");
  assert.deepEqual(
    {
      type: sarosAnchor.type,
      minimum: sarosAnchor.minimum,
      maximum: sarosAnchor.maximum,
      default: sarosAnchor.default,
    },
    { type: "integer", minimum: 1, maximum: 180, default: 141 },
  );
  for (const schemaName of ["User", "PublicUserSummary", "SubscriptionTargetUserSummary"]) {
    const required = array(object(schemas[schemaName], `${schemaName} must exist`).required, `${schemaName} required`);
    assert.ok(required.includes("sarosAnchor"), `${schemaName} must require sarosAnchor`);
  }
});

test("OpenAPI documents the initial latest activity snapshot and live resume contract", async () => {
  const contract = await loadContract();
  const paths = object(contract.paths, "paths must be defined");
  const components = object(contract.components, "components must be defined");
  const parameters = object(components.parameters, "parameters must be defined");
  const snapshot = object(
    parameters.PublicActivitySnapshot,
    "PublicActivitySnapshot parameter must exist",
  );

  assert.equal(snapshot.name, "snapshot");
  assert.equal(snapshot.in, "query");
  assert.deepEqual(
    array(object(snapshot.schema, "snapshot schema").enum, "snapshot enum"),
    ["latest"],
  );
  assert.match(String(snapshot.description), /high-water mark/);

  for (const pathName of ["/public/activity", "/activity"]) {
    const operation = object(object(paths[pathName], pathName).get, `${pathName} GET`);
    const operationParameters = array(operation.parameters, `${pathName} parameters`);
    assert.ok(
      operationParameters.some(
        (parameter) =>
          object(parameter, `${pathName} parameter`).$ref ===
          "#/components/parameters/PublicActivitySnapshot",
      ),
      `${pathName} must expose snapshot=latest`,
    );
  }

  const publicEventParameters = array(
    object(object(paths["/public/events"], "public events path").get, "public events GET")
      .parameters,
    "public events parameters",
  );
  assert.equal(
    publicEventParameters.some(
      (parameter) =>
        object(parameter, "public events parameter").$ref ===
        "#/components/parameters/PublicActivitySnapshot",
    ),
    false,
  );
});

test("OpenAPI contract keeps private records opaque and events lightweight", async () => {
  const contract = await loadContract();
  const components = object(contract.components, "components must be defined");
  const schemas = object(components.schemas, "schemas must be defined");

  const publicInput = object(schemas.PublicRecordInput, "PublicRecordInput must exist");
  const publicProperties = object(publicInput.properties, "PublicRecordInput properties must exist");
  assert.equal(object(publicProperties.visibility, "public visibility must exist").default, "public");
  assert.ok("occurredAt" in publicProperties);
  assert.ok("mediaIds" in publicProperties);

  const privateInput = object(schemas.PrivateRecordInput, "PrivateRecordInput must exist");
  const privateProperties = object(privateInput.properties, "PrivateRecordInput properties must exist");
  assert.deepEqual(Object.keys(privateProperties).sort(), [
    "deviceId",
    "encryption",
    "id",
    "mediaIds",
    "originId",
    "references",
    "visibility",
  ]);
  assert.deepEqual(array(privateInput.required, "private required fields"), [
    "id",
    "originId",
    "deviceId",
    "visibility",
    "encryption",
  ]);
  assert.equal(privateInput.additionalProperties, false);

  const recordPublicId = object(schemas.RecordPublicId, "RecordPublicId must exist");
  assert.equal(recordPublicId.pattern, "^[A-Za-z0-9_-]{5}$");
  assert.equal(recordPublicId.minLength, 5);
  assert.equal(recordPublicId.maxLength, 5);

  const publicRecordProjection = object(
    schemas.PublicRecordProjection,
    "PublicRecordProjection must exist",
  );
  assert.equal(
    "originId" in object(publicRecordProjection.properties, "public projection properties"),
    false,
  );

  const privatePatch = object(schemas.PrivateRecordPatch, "PrivateRecordPatch must exist");
  assert.deepEqual(array(privatePatch.required, "private patch required fields"), [
    "visibility",
    "encryption",
  ]);
  assert.ok(!("source" in object(privatePatch.properties, "private patch properties")));

  const mediaUpload = object(schemas.CreateMediaUploadRequest, "media upload schema must exist");
  assert.deepEqual(
    object(mediaUpload.dependentRequired, "media upload dependencies").encryption,
    ["mediaId"],
  );

  const eventInput = object(schemas.CreateEventRequest, "CreateEventRequest must exist");
  const eventProperties = object(eventInput.properties, "CreateEventRequest properties must exist");
  assert.deepEqual(Object.keys(eventProperties).sort(), [
    "deviceId",
    "endsAt",
    "id",
    "label",
    "metadata",
    "references",
    "startsAt",
    "type",
    "visibility",
  ]);
  assert.ok(!("media" in eventProperties));
  assert.ok(!("embedding" in eventProperties));
  assert.equal(object(eventProperties.type, "event type must exist").type, "integer");
  assert.equal(object(eventProperties.visibility, "event visibility must exist").default, "public");
  assert.ok("references" in eventProperties);

  const publicEvent = object(schemas.PublicEventProjection, "PublicEventProjection must exist");
  const publicEventProperties = object(
    publicEvent.properties,
    "PublicEventProjection properties must exist",
  );
  assert.ok("author" in publicEventProperties);
  assert.ok("references" in publicEventProperties);
  assert.ok(!("deviceId" in publicEventProperties));

  const publicProjection = object(
    schemas.PublicRecordProjection,
    "PublicRecordProjection must exist",
  );
  const publicProjectionProperties = object(
    publicProjection.properties,
    "public projection properties must exist",
  );
  assert.ok(!("deviceId" in publicProjectionProperties));
  assert.ok("author" in publicProjectionProperties);
  assert.ok("tags" in publicProjectionProperties);
  assert.ok("references" in publicProjectionProperties);
  const publicMedia = object(schemas.PublicMediaObject, "PublicMediaObject must exist");
  const publicMediaProperties = object(publicMedia.properties, "public media properties must exist");
  assert.ok(!("deviceId" in publicMediaProperties));
  assert.ok(!("contentUrl" in publicMediaProperties));
  assert.ok("publicContentUrl" in publicMediaProperties);
});

test("OpenAPI contract defines both JWT and scoped API-key bearer authentication", async () => {
  const contract = await loadContract();
  const components = object(contract.components, "components must be defined");
  const securitySchemes = object(components.securitySchemes, "security schemes must exist");

  const jwt = object(securitySchemes.JwtBearer, "JwtBearer must exist");
  assert.equal(jwt.type, "http");
  assert.equal(jwt.scheme, "bearer");
  assert.equal(jwt.bearerFormat, "JWT");

  const apiKey = object(securitySchemes.ApiKeyBearer, "ApiKeyBearer must exist");
  assert.equal(apiKey.type, "http");
  assert.equal(apiKey.scheme, "bearer");
  assert.match(String(apiKey.description), /device-bound, scoped/);

  const createRecord = object(
    object(object(contract.paths, "paths must exist")["/records"], "record path must exist").post,
    "create record operation must exist",
  );
  assert.deepEqual(createRecord["x-required-scopes"], ["records:write"]);

  const listEvents = object(
    object(object(contract.paths, "paths must exist")["/events"], "event path must exist").get,
    "list events operation must exist",
  );
  assert.deepEqual(listEvents["x-required-scopes"], ["events:read"]);
});
