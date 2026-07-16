import assert from "node:assert/strict";
import test from "node:test";

import Fastify from "fastify";
import type { QueryResultRow } from "pg";

import type { Authenticator, Principal } from "../src/auth/principal.js";
import type {
  Database,
  DatabaseReadiness,
  DatabaseResult,
  Queryable,
} from "../src/db/database.js";
import { HttpProblem, registerProblemHandlers } from "../src/http/problem.js";
import type { ResourceRequestLimiter } from "../src/resources/rate-limit.js";
import { decodeSyncCursor, encodeSyncCursor, SyncService } from "../src/resources/sync.js";
import { registerSyncRoutes } from "../src/routes/sync.js";

const principal: Principal = {
  kind: "jwt",
  userId: "11111111-1111-4111-8111-111111111111",
  actorId: "22222222-2222-4222-8222-222222222222",
  deviceId: "33333333-3333-4333-8333-333333333333",
  scopes: new Set(),
};

test("sync cursor round-trips an exact bigint position and rejects another binding", () => {
  const cursor = encodeSyncCursor("bound-feed", 42n);
  assert.deepEqual(decodeSyncCursor(cursor, "bound-feed"), { sequence: 42n });
  assert.throws(
    () => decodeSyncCursor(cursor, "another-feed"),
    (error: unknown) => error instanceof HttpProblem && error.status === 400 && error.code === "invalid_cursor",
  );
});

test("sync batches enforce API-key device binding before reserving idempotency state", async () => {
  const service = new SyncService(new EmptySyncDatabase());
  const apiKeyPrincipal: Principal = {
    ...principal,
    kind: "api_key",
    deviceId: "55555555-5555-4555-8555-555555555555",
  };
  await assert.rejects(
    () => service.applyBatch(
      apiKeyPrincipal,
      {
        deviceId: "66666666-6666-4666-8666-666666666666",
        mutations: [{
          kind: "upsertEvent",
          clientMutationId: "device-bound-event",
          event: {
            deviceId: "66666666-6666-4666-8666-666666666666",
            startsAt: "2026-07-15T00:00:00Z",
            label: "Must not write",
            type: 1,
          },
        }],
      },
      "device-bound-batch",
      "device-bound-request",
    ),
    (error: unknown) =>
      error instanceof HttpProblem && error.status === 403 && error.code === "device_binding_mismatch",
  );
});

test("sync change route authenticates with sync:read, rate limits, and binds its cursor query", async () => {
  const database = new EmptySyncDatabase();
  const requiredScopes: string[][] = [];
  let currentPrincipal = principal;
  const authenticator: Authenticator = {
    async authenticate(_request, scopes = []) {
      requiredScopes.push([...scopes]);
      return currentPrincipal;
    },
  };
  let reads = 0;
  const limiter = noopLimiter({ onRead: () => { reads += 1; } });
  const app = Fastify({ logger: false });
  registerProblemHandlers(app);
  await app.register(registerSyncRoutes, {
    database,
    authenticator,
    requestLimiter: limiter,
  });

  try {
    const first = await app.inject({ method: "GET", url: "/v1/sync/changes" });
    assert.equal(first.statusCode, 200, first.body);
    const page = first.json<{ data: unknown[]; nextCursor: string; hasMore: boolean }>();
    assert.deepEqual(page.data, []);
    assert.equal(page.hasMore, false);
    assert.ok(page.nextCursor.length > 1);
    assert.deepEqual(requiredScopes, [["sync:read"]]);
    assert.equal(reads, 1);

    const rebound = await app.inject({
      method: "GET",
      url: `/v1/sync/changes?resourceType=event&cursor=${encodeURIComponent(page.nextCursor)}`,
    });
    assert.equal(rebound.statusCode, 400, rebound.body);
    assert.equal(rebound.json().code, "invalid_cursor");

    currentPrincipal = { ...principal, userId: "44444444-4444-4444-8444-444444444444" };
    const otherUser = await app.inject({
      method: "GET",
      url: `/v1/sync/changes?cursor=${encodeURIComponent(page.nextCursor)}`,
    });
    assert.equal(otherUser.statusCode, 400, otherUser.body);
    assert.equal(otherUser.json().code, "invalid_cursor");
  } finally {
    await app.close();
  }
});

test("sync batch route validates nested mutations and requests sync:write", async () => {
  const requiredScopes: string[][] = [];
  const authenticator: Authenticator = {
    async authenticate(_request, scopes = []) {
      requiredScopes.push([...scopes]);
      throw new HttpProblem({ status: 403, code: "test_forbidden" });
    },
  };
  const app = Fastify({ logger: false });
  registerProblemHandlers(app);
  await app.register(registerSyncRoutes, {
    database: new EmptySyncDatabase(),
    authenticator,
    requestLimiter: noopLimiter(),
  });

  try {
    const malformed = await app.inject({
      method: "POST",
      url: "/v1/sync/batches",
      headers: { "idempotency-key": "sync-route-malformed" },
      payload: {
        deviceId: principal.deviceId,
        mutations: [{
          kind: "upsertEvent",
          clientMutationId: "event-malformed",
          event: {
            deviceId: principal.deviceId,
            startsAt: "2026-07-15T00:00:00Z",
            type: 1,
            unexpected: true,
          },
        }],
      },
    });
    assert.equal(malformed.statusCode, 400, malformed.body);
    assert.deepEqual(requiredScopes, []);

    const authenticated = await app.inject({
      method: "POST",
      url: "/v1/sync/batches",
      headers: { "idempotency-key": "sync-route-auth" },
      payload: {
        deviceId: principal.deviceId,
        mutations: [{
          kind: "upsertEvent",
          clientMutationId: "event-auth-check",
          event: {
            deviceId: principal.deviceId,
            startsAt: "2026-07-15T00:00:00Z",
            label: "Route validation",
            type: 1,
          },
        }],
      },
    });
    assert.equal(authenticated.statusCode, 403, authenticated.body);
    assert.deepEqual(requiredScopes, [["sync:write"]]);
  } finally {
    await app.close();
  }
});

class EmptySyncDatabase implements Database {
  async checkReadiness(): Promise<DatabaseReadiness> {
    return {
      ready: true,
      database: "up",
      pgvector: "up",
      pgvectorVersion: "test",
      latencyMs: 0,
    };
  }

  async query<Row extends QueryResultRow = QueryResultRow>(
    text: string,
    _values?: readonly unknown[],
  ): Promise<DatabaseResult<Row>> {
    if (text.startsWith("SET TRANSACTION")) {
      return result<Row>([]);
    }
    if (text.includes("AS high_water")) {
      return result<Row>([{ high_water: "0", last_pruned: "0" }]);
    }
    if (text.includes("WITH latest AS")) {
      return result<Row>([]);
    }
    throw new Error(`Unexpected sync test query: ${text}`);
  }

  async transaction<Result>(work: (client: Queryable) => Promise<Result>): Promise<Result> {
    return work(this);
  }

  async close(): Promise<void> {}
}

function result<Row extends QueryResultRow>(rows: readonly unknown[]): DatabaseResult<Row> {
  return { rows: rows as readonly Row[], rowCount: rows.length };
}

function noopLimiter(options: { readonly onRead?: () => void } = {}): ResourceRequestLimiter {
  return {
    async checkPublicRecordRead() {},
    async checkAuthenticatedRead() {
      options.onRead?.();
    },
    async checkAuthenticatedWrite() {},
  };
}
