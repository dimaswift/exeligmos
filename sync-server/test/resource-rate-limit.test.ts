import assert from "node:assert/strict";
import test from "node:test";

import Fastify from "fastify";
import type { FastifyRequest } from "fastify";
import type { QueryResultRow } from "pg";

import type { Principal } from "../src/auth/principal.js";
import type {
  Database,
  DatabaseReadiness,
  DatabaseResult,
  Queryable,
} from "../src/db/database.js";
import { HttpProblem, registerProblemHandlers } from "../src/http/problem.js";
import {
  assertSerializedJsonSize,
  postgresJsonbCompactJson,
  parseRecordPageLimit,
  RECORD_PAGE_DEFAULT_LIMIT,
  RECORD_PAGE_MAX_LIMIT,
} from "../src/resources/limits.js";
import {
  NOOP_RESOURCE_REQUEST_LIMITER,
  PostgresResourceRequestLimiter,
  type ResourceRateLimitPolicy,
  type ResourceRequestLimiter,
} from "../src/resources/rate-limit.js";
import { registerEventRoutes } from "../src/routes/events.js";
import { registerOwnerSecurityRoutes } from "../src/routes/owner-security.js";
import { registerRecordRoutes } from "../src/routes/records.js";

const principal: Principal = {
  kind: "api_key",
  userId: "e42b4fde-8baf-4b95-8bc8-5395b68d0dd2",
  actorId: "0ce129e6-cbf7-4731-8829-7592f69fb31e",
  deviceId: "2dca8eab-00a8-4e94-9bd2-2fcbfe17e890",
  scopes: new Set(["records:read", "records:write", "events:read", "events:write"]),
};
const jwtPrincipal: Principal = {
  kind: "jwt",
  userId: principal.userId,
  actorId: principal.actorId,
  deviceId: "2dca8eab-00a8-4e94-9bd2-2fcbfe17e890",
  scopes: new Set(),
};

const testPolicy: ResourceRateLimitPolicy = {
  windowMs: 60_000,
  publicRecordReadsGlobal: 9,
  publicRecordReadsPerIp: 3,
  authenticatedReadsPerUser: 8,
  authenticatedReadsPerPrincipal: 4,
  authenticatedWritesPerUser: 6,
  authenticatedWritesPerPrincipal: 2,
};

test("resource limiter sends only hashed identities and dual aggregate buckets", async () => {
  const database = new CapturingDatabase();
  const limiter = new PostgresResourceRequestLimiter(database, testPolicy);

  await limiter.checkPublicRecordRead(requestFrom("203.0.113.7"));
  assert.deepEqual(database.lastValues?.[1], [9, 3]);
  assert.deepEqual(database.lastValues?.[2], [
    "public-record-read-global",
    "public-record-read-ip",
  ]);
  assertHashes(database.lastValues?.[0], ["203.0.113.7", "all"]);

  await limiter.checkAuthenticatedRead(requestFrom("198.51.100.2"), principal);
  assert.deepEqual(database.lastValues?.[1], [8, 4]);
  assertHashes(database.lastValues?.[0], [principal.userId, principal.actorId]);

  await limiter.checkAuthenticatedWrite(requestFrom("198.51.100.2"), principal);
  assert.deepEqual(database.lastValues?.[1], [6, 2]);
  assert.deepEqual(database.lastValues?.[3], 60_000);
  assert.match(database.lastQuery, /ON CONFLICT \(bucket_hash\) DO UPDATE/);
});

test("resource limiter returns Retry-After and non-secret policy details", async () => {
  const database = new CapturingDatabase({
    policy_name: "authenticated-resource-write-principal",
    maximum: 2,
    request_count: 3,
    retry_after: 42,
  });
  const limiter = new PostgresResourceRequestLimiter(database, testPolicy);

  await assert.rejects(
    limiter.checkAuthenticatedWrite(requestFrom("198.51.100.2"), principal),
    (error: unknown) => {
      assert.ok(error instanceof HttpProblem);
      assert.equal(error.status, 429);
      assert.equal(error.code, "resource_rate_limited");
      assert.equal(error.headers["retry-after"], "42");
      assert.equal(error.extensions.policy, "authenticated-resource-write-principal");
      assert.equal(error.extensions.limit, 2);
      assert.equal(error.extensions.windowSeconds, 60);
      return true;
    },
  );
});

test("record page and serialized JSON bounds are explicit", () => {
  assert.equal(parseRecordPageLimit(undefined), RECORD_PAGE_DEFAULT_LIMIT);
  assert.equal(parseRecordPageLimit(String(RECORD_PAGE_MAX_LIMIT)), RECORD_PAGE_MAX_LIMIT);
  assert.throws(
    () => parseRecordPageLimit(RECORD_PAGE_MAX_LIMIT + 1),
    (error: unknown) => error instanceof HttpProblem && error.status === 400,
  );

  assert.doesNotThrow(() => assertSerializedJsonSize({ text: "é" }, 13, "payload"));
  assert.throws(
    () => assertSerializedJsonSize({ text: "é" }, 12, "payload"),
    (error: unknown) =>
      error instanceof HttpProblem &&
      error.status === 422 &&
      error.code === "payload_too_large" &&
      error.extensions.actualBytes === 13,
  );

  assert.equal(postgresJsonbCompactJson({ n: 1e21 }), `{"n":${"1"}${"0".repeat(21)}}`);
  assert.equal(postgresJsonbCompactJson({ n: 1e-7 }), '{"n":0.0000001}');
  assert.throws(
    () => assertSerializedJsonSize({ n: 1e21 }, 27, "payload"),
    (error: unknown) =>
      error instanceof HttpProblem &&
      error.code === "payload_too_large" &&
      error.extensions.actualBytes === 28,
  );
  assert.throws(
    () => assertSerializedJsonSize({ text: "contains\0nul" }, 1_000, "payload"),
    (error: unknown) =>
      error instanceof HttpProblem && error.status === 422 && error.code === "invalid_json",
  );
  assert.throws(
    () => assertSerializedJsonSize({ text: "\ud800" }, 1_000, "payload"),
    (error: unknown) =>
      error instanceof HttpProblem && error.status === 422 && error.code === "invalid_json",
  );
});

test("record routes invoke public, authenticated-read, and authenticated-write limits", async () => {
  const limiter = new RejectingRecordingLimiter();
  const app = Fastify({ logger: false });
  registerProblemHandlers(app);
  await app.register(registerRecordRoutes, {
    database: new CapturingDatabase(),
    authenticator: { async authenticate() { return principal; } },
    requestLimiter: limiter,
  });
  try {
    const publicResponse = await app.inject({ method: "GET", url: "/v1/public/records" });
    assert.equal(publicResponse.statusCode, 429);
    const ownerResponse = await app.inject({
      method: "GET",
      url: "/v1/records",
      headers: { authorization: "Bearer ignored" },
    });
    assert.equal(ownerResponse.statusCode, 429);
    const writeResponse = await app.inject({
      method: "DELETE",
      url: "/v1/records/Q7_xA",
      headers: {
        authorization: "Bearer ignored",
        "if-match": '"record-r1"',
        "idempotency-key": "record-delete-1",
      },
    });
    assert.equal(writeResponse.statusCode, 429);
    assert.deepEqual(limiter.calls, ["public", "read", "write"]);
  } finally {
    await app.close();
  }
});

test("event routes share authenticated read and write limits", async () => {
  const limiter = new RejectingRecordingLimiter();
  const app = Fastify({ logger: false });
  registerProblemHandlers(app);
  await app.register(registerEventRoutes, {
    database: new CapturingDatabase(),
    authenticator: { async authenticate() { return principal; } },
    requestLimiter: limiter,
  });
  try {
    assert.equal((await app.inject({ method: "GET", url: "/v1/events" })).statusCode, 429);
    assert.equal(
      (await app.inject({
        method: "DELETE",
        url: "/v1/events/20a78723-c33e-4794-a036-5da69a15e8bf",
        headers: {
          "if-match": '"event-r1"',
          "idempotency-key": "event-delete-1",
        },
      })).statusCode,
      429,
    );
    assert.deepEqual(limiter.calls, ["read", "write"]);
  } finally {
    await app.close();
  }
});

test("owner and security routes share authenticated read and write limits", async () => {
  const limiter = new RejectingRecordingLimiter();
  const app = Fastify({ logger: false });
  registerProblemHandlers(app);
  await app.register(registerOwnerSecurityRoutes, {
    database: new CapturingDatabase(),
    authenticator: { async authenticate() { return jwtPrincipal; } },
    requestLimiter: limiter,
  });
  try {
    assert.equal((await app.inject({ method: "GET", url: "/v1/me" })).statusCode, 429);
    assert.equal(
      (await app.inject({
        method: "PATCH",
        url: "/v1/me",
        headers: { "if-match": '"user-r1"' },
        payload: { sarosAnchor: 141 },
      })).statusCode,
      429,
    );
    assert.equal(
      (await app.inject({
        method: "POST",
        url: "/v1/devices",
        headers: { "idempotency-key": "device-create-1" },
        payload: { name: "Agent", kind: "agent" },
      })).statusCode,
      429,
    );
    assert.deepEqual(limiter.calls, ["read", "write", "write"]);
  } finally {
    await app.close();
  }
});

test("resource limiter has an explicit deterministic no-op", async () => {
  await NOOP_RESOURCE_REQUEST_LIMITER.checkPublicRecordRead(requestFrom("192.0.2.1"));
  await NOOP_RESOURCE_REQUEST_LIMITER.checkAuthenticatedRead(requestFrom("192.0.2.1"), principal);
  await NOOP_RESOURCE_REQUEST_LIMITER.checkAuthenticatedWrite(requestFrom("192.0.2.1"), principal);
});

class CapturingDatabase implements Database {
  lastQuery = "";
  lastValues: readonly unknown[] | undefined;

  constructor(private readonly violation?: QueryResultRow) {}

  async checkReadiness(): Promise<DatabaseReadiness> {
    return { ready: true, database: "up", pgvector: "up", latencyMs: 0 };
  }

  async query<Row extends QueryResultRow = QueryResultRow>(
    text: string,
    values?: readonly unknown[],
  ): Promise<DatabaseResult<Row>> {
    this.lastQuery = text;
    this.lastValues = values;
    return result(this.violation === undefined ? [] : [this.violation as Row]);
  }

  async transaction<Result>(work: (client: Queryable) => Promise<Result>): Promise<Result> {
    return work(this);
  }

  async close(): Promise<void> {}
}

class RejectingRecordingLimiter implements ResourceRequestLimiter {
  readonly calls: string[] = [];

  async checkPublicRecordRead(): Promise<void> {
    this.reject("public");
  }

  async checkAuthenticatedRead(): Promise<void> {
    this.reject("read");
  }

  async checkAuthenticatedWrite(): Promise<void> {
    this.reject("write");
  }

  private reject(kind: string): never {
    this.calls.push(kind);
    throw new HttpProblem({ status: 429, code: "test_limit", detail: "limited" });
  }
}

function requestFrom(ip: string): FastifyRequest {
  return { ip } as unknown as FastifyRequest;
}

function assertHashes(value: unknown, forbidden: readonly string[]): void {
  assert.ok(Array.isArray(value));
  assert.ok(value.length >= 1);
  for (const hash of value) {
    assert.match(String(hash), /^[a-f0-9]{64}$/);
  }
  const joined = JSON.stringify(value);
  for (const secret of forbidden) {
    assert.equal(joined.includes(secret), false);
  }
}

function result<Row extends QueryResultRow>(rows: readonly Row[]): DatabaseResult<Row> {
  return { rows, rowCount: rows.length };
}
