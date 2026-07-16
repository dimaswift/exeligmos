import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";

import Fastify, { type FastifyRequest } from "fastify";
import type { QueryResultRow } from "pg";

import type { Authenticator, Principal } from "../src/auth/principal.js";
import type {
  Database,
  DatabaseReadiness,
  DatabaseResult,
  Queryable,
} from "../src/db/database.js";
import { registerProblemHandlers } from "../src/http/problem.js";
import { ApiKeyService } from "../src/owner-security/api-key-service.js";
import {
  canonicalRequestHash,
  OwnerSecurityProblem,
} from "../src/owner-security/common.js";
import { DeviceService } from "../src/owner-security/device-service.js";
import {
  executeIdempotentJson,
  reserveSecretOnceIdempotency,
} from "../src/owner-security/idempotency.js";
import { UserSecurityService } from "../src/owner-security/user-service.js";
import { registerOwnerSecurityRoutes } from "../src/routes/owner-security.js";

const USER_ID = "00000000-0000-4000-8000-000000000001";
const DEVICE_ID = "00000000-0000-4000-8000-000000000002";
const API_KEY_ID = "00000000-0000-4000-8000-000000000003";
const ACTOR_ID = "00000000-0000-4000-8000-000000000004";
const NOW = new Date("2026-07-14T20:00:00.000Z");

test("GET /v1/me accepts an API-key principal and returns a strong user ETag", async (context) => {
  const database = new ScriptedDatabase([
    (text, values) => {
      assert.match(text, /FROM users/);
      assert.deepEqual(values, [USER_ID]);
      return rows([userRow()]);
    },
  ]);
  const authenticator = new StubAuthenticator(apiKeyPrincipal());
  const app = await ownerSecurityApp(database, authenticator);
  context.after(() => app.close());

  const response = await app.inject({
    method: "GET",
    url: "/v1/me",
    headers: { authorization: "Bearer exk_example" },
  });

  assert.equal(response.statusCode, 200);
  assert.equal(response.headers.etag, `"user-${USER_ID}-r3"`);
  assert.deepEqual(response.json(), {
    id: USER_ID,
    login: "aurora",
    displayName: "Aurora",
    createdAt: "2026-07-14T18:00:00.000Z",
    updatedAt: "2026-07-14T19:00:00.000Z",
  });
  assert.deepEqual(authenticator.requiredScopes, [[]]);
  database.assertDone();
});

test("device reads request devices:read while device mutations require JWT", async (context) => {
  const database = new ScriptedDatabase([
    (text, values) => {
      assert.match(text, /FROM devices/);
      assert.match(text, /user_id = \$1 AND id = \$2/);
      assert.deepEqual(values, [USER_ID, DEVICE_ID]);
      return rows([deviceRow()]);
    },
  ]);
  const authenticator = new StubAuthenticator(apiKeyPrincipal());
  const app = await ownerSecurityApp(database, authenticator);
  context.after(() => app.close());

  const read = await app.inject({ method: "GET", url: `/v1/devices/${DEVICE_ID}` });
  const create = await app.inject({
    method: "POST",
    url: "/v1/devices",
    headers: { "idempotency-key": "device-create-1" },
    payload: { name: "Agent", kind: "agent" },
  });

  assert.equal(read.statusCode, 200);
  assert.equal(read.headers.etag, `"device-${DEVICE_ID}-r7"`);
  assert.equal(create.statusCode, 403);
  assert.equal(create.json().code, "jwt_required");
  assert.deepEqual(authenticator.requiredScopes, [["devices:read"], []]);
  database.assertDone();
});

test("device updates enforce the current strong ETag and return it on 412", async (context) => {
  const database = new ScriptedDatabase([
    (text) => {
      assert.match(text, /FOR UPDATE/);
      return rows([deviceRow()]);
    },
  ]);
  const app = await ownerSecurityApp(database, new StubAuthenticator(jwtPrincipal()));
  context.after(() => app.close());

  const response = await app.inject({
    method: "PATCH",
    url: `/v1/devices/${DEVICE_ID}`,
    headers: { "if-match": `"device-${DEVICE_ID}-r6"` },
    payload: { name: "Renamed" },
  });

  assert.equal(response.statusCode, 412);
  assert.equal(response.headers.etag, `"device-${DEVICE_ID}-r7"`);
  assert.equal(response.json().code, "precondition_failed");
  database.assertDone();
});

test("device metadata patches use nested RFC 7396 merge semantics", async () => {
  const current = {
    ...deviceRow(),
    metadata: {
      keep: true,
      nested: { keep: 1, remove: 2 },
      array: [1, 2],
    },
  };
  const mergedMetadata = {
    keep: true,
    nested: { keep: 1, add: 3 },
    array: [9],
  };
  const database = new ScriptedDatabase([
    () => rows([current]),
    (text, values) => {
      assert.match(text, /UPDATE devices/);
      assert.deepEqual(values, [USER_ID, DEVICE_ID, JSON.stringify(mergedMetadata)]);
      return rows([{ ...current, metadata: mergedMetadata, revision: "8" }]);
    },
    (text) => {
      assert.match(text, /INSERT INTO audit_log/);
      return rows([]);
    },
  ]);

  const updated = await new DeviceService(database).update({
    principal: jwtPrincipal(),
    deviceId: DEVICE_ID,
    ifMatch: `"device-${DEVICE_ID}-r7"`,
    input: {
      metadata: {
        nested: { remove: null, add: 3 },
        array: [9],
      },
    },
    requestId: "request-metadata-merge",
  });

  assert.deepEqual(updated.view.metadata, mergedMetadata);
  assert.equal(updated.etag, `"device-${DEVICE_ID}-r8"`);
  database.assertDone();
});

test("API-key creation stores only SHA-256 secret material and returns plaintext once", async () => {
  const secret = `exk_${"A".repeat(43)}`;
  const expectedHash = createHash("sha256").update(secret, "utf8").digest();
  const input = {
    name: "Solar watcher",
    deviceId: DEVICE_ID,
    scopes: ["records:write", "events:write"] as const,
    expiresAt: "2027-07-14T20:00:00Z",
  };
  const database = new ScriptedDatabase([
    (text) => {
      assert.match(text, /FROM idempotency_keys/);
      return rows([]);
    },
    (text, values) => {
      assert.match(text, /INSERT INTO idempotency_keys/);
      assert.equal(values?.includes(secret), false);
      return rows([{ idempotency_key: "api-key-create-1" }]);
    },
    (text, values) => {
      assertCleanupQuery(text, values, "createApiKey", "api-key-create-1");
      return rows([]);
    },
    (text, values) => {
      assert.match(text, /FROM devices/);
      assert.deepEqual(values, [USER_ID, DEVICE_ID]);
      return rows([{ id: DEVICE_ID }]);
    },
    (text, values) => {
      assert.match(text, /INSERT INTO api_keys/);
      assert.equal(values?.includes(secret), false);
      assert.deepEqual(values?.[4], expectedHash);
      return rows([apiKeyRow()]);
    },
    (text, values) => {
      assert.match(text, /UPDATE idempotency_keys/);
      assert.deepEqual(values, [USER_ID, "createApiKey", "api-key-create-1", API_KEY_ID]);
      assert.equal(JSON.stringify(values).includes(secret), false);
      return rows([]);
    },
    (text, values) => {
      assert.match(text, /INSERT INTO audit_log/);
      assert.equal(JSON.stringify(values).includes(secret), false);
      return rows([]);
    },
  ]);
  const service = new ApiKeyService(database, {
    generateSecret: () => secret,
    now: () => NOW,
  });

  const result = await service.create({
    principal: jwtPrincipal(),
    input,
    idempotencyKey: "api-key-create-1",
    requestId: "request-1",
  });

  assert.equal(result.secret, secret);
  assert.equal(result.key.prefix, "exk_AAAAAAAA");
  assert.equal(result.etag, `"api-key-${API_KEY_ID}-r1"`);
  database.assertDone();
});

test("encryption profile initialization stores only the v1 key check and is replayable", async () => {
  const keyCheck = Buffer.alloc(32, 7);
  const input = {
    cryptoVersion: 1 as const,
    keyVersion: 1 as const,
    keyCheck: keyCheck.toString("base64"),
  };
  const database = new ScriptedDatabase([
    () => rows([]),
    (text) => {
      assert.match(text, /INSERT INTO idempotency_keys/);
      return rows([{ idempotency_key: "encryption-profile-1" }]);
    },
    (text, values) => {
      assertCleanupQuery(
        text,
        values,
        "initializeEncryptionProfile",
        "encryption-profile-1",
        null,
      );
      return rows([]);
    },
    (text, values) => {
      assert.match(text, /INSERT INTO user_encryption_profiles/);
      assert.deepEqual(values, [USER_ID, keyCheck]);
      return rows([
        {
          user_id: USER_ID,
          crypto_version: 1,
          key_version: 1,
          key_check: keyCheck,
          created_at: NOW,
        },
      ]);
    },
    (text) => {
      assert.match(text, /INSERT INTO audit_log/);
      return rows([]);
    },
    (text, values) => {
      assert.match(text, /UPDATE idempotency_keys/);
      assert.equal(JSON.stringify(values).includes("mnemonic"), false);
      return rows([]);
    },
  ]);
  const service = new UserSecurityService(database);

  const result = await service.initializeEncryptionProfile({
    principal: jwtPrincipal(),
    input,
    idempotencyKey: "encryption-profile-1",
    requestId: "request-profile",
  });

  assert.equal(result.status, 201);
  assert.deepEqual(result.body, {
    userId: USER_ID,
    cryptoVersion: 1,
    keyVersion: 1,
    keyCheck: input.keyCheck,
    createdAt: NOW.toISOString(),
  });
  database.assertDone();
});

test("replaying API-key creation never returns the secret again", async () => {
  const input = {
    name: "Solar watcher",
    deviceId: DEVICE_ID,
    scopes: ["events:write"] as const,
  };
  const database = new ScriptedDatabase([
    (text) => {
      assert.match(text, /FROM idempotency_keys/);
      return rows([
        {
          request_hash: canonicalRequestHash(input),
          response_status: 409,
          response_headers: {},
          response_body: {
            code: "api_key_secret_already_returned",
            apiKeyId: API_KEY_ID,
          },
          expires_at: new Date("2026-07-15T20:00:00Z"),
        },
      ]);
    },
    (text, values) => {
      assertCleanupQuery(text, values, "createApiKey", "api-key-create-1");
      return rows([]);
    },
  ]);
  const service = new ApiKeyService(database, { now: () => NOW });

  await assert.rejects(
    () =>
      service.create({
        principal: jwtPrincipal(),
        input,
        idempotencyKey: "api-key-create-1",
        requestId: "request-2",
      }),
    (error: unknown) =>
      error instanceof OwnerSecurityProblem &&
      error.code === "api_key_secret_already_returned" &&
      error.extensions.apiKeyId === API_KEY_ID,
  );
  database.assertDone();
});

test("API-key expiration requires a future timezone-bearing RFC 3339 instant", async () => {
  const database = new ScriptedDatabase([]);
  const service = new ApiKeyService(database, { now: () => NOW });

  await assert.rejects(
    () =>
      service.create({
        principal: jwtPrincipal(),
        input: {
          name: "Agent",
          deviceId: DEVICE_ID,
          scopes: ["events:read"],
          expiresAt: "2027-07-14T20:00:00",
        },
        idempotencyKey: "api-key-create-2",
        requestId: "request-expiry",
      }),
    (error: unknown) =>
      error instanceof OwnerSecurityProblem && error.code === "invalid_api_key",
  );
  database.assertDone();
});

test("expired idempotency reservations are removed before a key is reused", async () => {
  const request = { deviceId: DEVICE_ID, name: "Agent" };
  const database = new ScriptedDatabase([
    () =>
      rows([
        {
          request_hash: canonicalRequestHash(request),
          response_status: 201,
          response_headers: {},
          response_body: {},
          expires_at: new Date("2026-07-14T19:59:59Z"),
        },
      ]),
    (text, values) => {
      assert.match(text, /DELETE FROM idempotency_keys/);
      assert.deepEqual(values, [USER_ID, "createApiKey", "expired-key-1", NOW]);
      return rows([]);
    },
    (text) => {
      assert.match(text, /INSERT INTO idempotency_keys/);
      return rows([{ idempotency_key: "expired-key-1" }]);
    },
    (text, values) => {
      assertCleanupQuery(text, values, "createApiKey", "expired-key-1");
      return rows([]);
    },
  ]);

  await reserveSecretOnceIdempotency({
    client: database,
    principal: jwtPrincipal(),
    operationId: "createApiKey",
    idempotencyKey: "expired-key-1",
    request,
    now: NOW,
  });

  database.assertDone();
});

test("bounded cleanup preserves a live exact-key response for replay", async () => {
  const request = { name: "Agent", deviceId: DEVICE_ID };
  let executions = 0;
  const database = new ScriptedDatabase([
    (text, values) => {
      assert.match(text, /FOR UPDATE/);
      assert.deepEqual(values, [USER_ID, "registerDevice", "live-replay-key"]);
      return rows([
        {
          request_hash: canonicalRequestHash(request),
          response_status: 201,
          response_headers: { etag: '"device-live-r1"' },
          response_body: { id: DEVICE_ID },
          expires_at: new Date("2026-07-15T20:00:00Z"),
        },
      ]);
    },
    (text, values) => {
      assertCleanupQuery(text, values, "registerDevice", "live-replay-key");
      return { rows: [], rowCount: 100 };
    },
  ]);

  const replay = await executeIdempotentJson({
    client: database,
    principal: jwtPrincipal(),
    operationId: "registerDevice",
    idempotencyKey: "live-replay-key",
    request,
    now: NOW,
    execute: async () => {
      executions += 1;
      return { status: 500, headers: {}, body: { unexpected: true } };
    },
  });

  assert.equal(executions, 0);
  assert.deepEqual(replay, {
    status: 201,
    headers: { etag: '"device-live-r1"' },
    body: { id: DEVICE_ID },
    replayed: true,
  });
  database.assertDone();
});

test("revoking a device revokes its API keys and bound JWT sessions atomically", async () => {
  const database = new ScriptedDatabase([
    () => rows([deviceRow()]),
    (text) => {
      assert.match(text, /UPDATE devices/);
      return rows([]);
    },
    (text) => {
      assert.match(text, /UPDATE api_keys/);
      return rows([]);
    },
    (text) => {
      assert.match(text, /UPDATE auth_sessions/);
      assert.match(text, /device_revoked/);
      return rows([]);
    },
    (text) => {
      assert.match(text, /INSERT INTO audit_log/);
      return rows([]);
    },
  ]);
  const service = new DeviceService(database);

  await service.revoke({
    principal: jwtPrincipal(),
    deviceId: DEVICE_ID,
    ifMatch: `"device-${DEVICE_ID}-r7"`,
    requestId: "request-3",
  });

  database.assertDone();
});

test("replaying device revocation after a lost 204 remains idempotent", async () => {
  const database = new ScriptedDatabase([
    () => rows([{ ...deviceRow(), revision: "8", revoked_at: NOW }]),
  ]);
  const service = new DeviceService(database);

  await service.revoke({
    principal: jwtPrincipal(),
    deviceId: DEVICE_ID,
    // This is the ETag used by the successful first request. Revocation has
    // already advanced the stored resource to revision 8.
    ifMatch: `"device-${DEVICE_ID}-r7"`,
    requestId: "request-3-retry",
  });

  database.assertDone();
});

async function ownerSecurityApp(database: Database, authenticator: Authenticator) {
  const app = Fastify({ logger: false });
  registerProblemHandlers(app);
  await app.register(registerOwnerSecurityRoutes, { database, authenticator });
  await app.ready();
  return app;
}

type Step = (
  text: string,
  values: readonly unknown[] | undefined,
) => DatabaseResult<QueryResultRow>;

class ScriptedDatabase implements Database {
  constructor(private readonly steps: Step[]) {}

  async query<Row extends QueryResultRow = QueryResultRow>(
    text: string,
    values?: readonly unknown[],
  ): Promise<DatabaseResult<Row>> {
    const step = this.steps.shift();
    assert.ok(step, `Unexpected query: ${text}`);
    return step(text, values) as DatabaseResult<Row>;
  }

  async transaction<Result>(work: (client: Queryable) => Promise<Result>): Promise<Result> {
    return work(this);
  }

  async checkReadiness(): Promise<DatabaseReadiness> {
    return { ready: true, database: "up", pgvector: "up", latencyMs: 0 };
  }

  async close(): Promise<void> {}

  assertDone(): void {
    assert.equal(this.steps.length, 0, `${this.steps.length} expected database steps were unused`);
  }
}

class StubAuthenticator implements Authenticator {
  readonly requiredScopes: string[][] = [];

  constructor(private readonly principal: Principal) {}

  async authenticate(
    _request: FastifyRequest,
    requiredScopes: readonly string[] = [],
  ): Promise<Principal> {
    this.requiredScopes.push([...requiredScopes]);
    return this.principal;
  }
}

function rows<Row extends QueryResultRow>(values: Row[]): DatabaseResult<Row> {
  return { rows: values, rowCount: values.length };
}

function assertCleanupQuery(
  text: string,
  values: readonly unknown[] | undefined,
  operationId: string,
  idempotencyKey: string,
  expectedNow: Date | null = NOW,
): void {
  assert.match(text, /WITH expired AS/);
  assert.match(text, /expires_at <= \$4/);
  assert.match(text, /<>\s*\(\$1::uuid, \$2::text, \$3::text\)/);
  assert.match(text, /LIMIT \$5/);
  assert.match(text, /FOR UPDATE SKIP LOCKED/);
  assert.deepEqual(values?.slice(0, 3), [USER_ID, operationId, idempotencyKey]);
  assert.ok(values?.[3] instanceof Date);
  if (expectedNow !== null) {
    assert.deepEqual(values[3], expectedNow);
  }
  assert.equal(values?.[4], 100);
}

function jwtPrincipal(): Principal {
  return {
    kind: "jwt",
    userId: USER_ID,
    actorId: ACTOR_ID,
    scopes: new Set(),
  };
}

function apiKeyPrincipal(): Principal {
  return {
    kind: "api_key",
    userId: USER_ID,
    actorId: API_KEY_ID,
    deviceId: DEVICE_ID,
    scopes: new Set(["devices:read"]),
  };
}

function userRow(): QueryResultRow {
  return {
    id: USER_ID,
    login: "aurora",
    display_name: "Aurora",
    revision: "3",
    created_at: new Date("2026-07-14T18:00:00Z"),
    updated_at: new Date("2026-07-14T19:00:00Z"),
  };
}

function deviceRow(): QueryResultRow {
  return {
    id: DEVICE_ID,
    user_id: USER_ID,
    name: "Solar agent",
    kind: "agent",
    platform: "python",
    app_version: "1.0.0",
    metadata: {},
    revision: "7",
    registered_at: new Date("2026-07-14T18:00:00Z"),
    updated_at: new Date("2026-07-14T19:00:00Z"),
    last_seen_at: null,
    revoked_at: null,
  };
}

function apiKeyRow(): QueryResultRow {
  return {
    id: API_KEY_ID,
    user_id: USER_ID,
    device_id: DEVICE_ID,
    name: "Solar watcher",
    key_prefix: "exk_AAAAAAAA",
    scopes: ["records:write", "events:write"],
    revision: "1",
    created_at: NOW,
    expires_at: new Date("2027-07-14T20:00:00Z"),
    revoked_at: null,
    last_used_at: null,
  };
}
