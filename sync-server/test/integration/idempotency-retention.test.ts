import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import path from "node:path";
import test from "node:test";

import { Client, type QueryResultRow } from "pg";

import type { Principal } from "../../src/auth/principal.js";
import type {
  Database,
  DatabaseReadiness,
  DatabaseResult,
  Queryable,
} from "../../src/db/database.js";
import { createPostgresDatabase } from "../../src/db/database.js";
import { runMigrations } from "../../src/db/migrate.js";
import { executeIdempotentJson } from "../../src/owner-security/idempotency.js";
import { executeIdempotentMutation } from "../../src/resources/shared.js";
import { testConfig } from "../helpers.js";

const databaseUrl = process.env.TEST_DATABASE_URL?.trim();

test(
  "both idempotency paths bound expired-row cleanup and retain live responses",
  { skip: databaseUrl === undefined || databaseUrl.length === 0 },
  async () => {
    assert.ok(databaseUrl);
    await runMigrations({
      databaseUrl,
      directory: path.resolve(process.cwd(), "db/migrations"),
    });

    const sql = new Client({ connectionString: databaseUrl });
    await sql.connect();
    await sql.query("BEGIN");
    const database = new TransactionScopedDatabase(sql);

    try {
      const user = await database.query<{ id: string }>(
        `INSERT INTO users (login, display_name, password_hash)
         VALUES ($1, 'Idempotency Retention', 'not-a-real-password-hash')
         RETURNING id`,
        [`idempotency-retention-${randomUUID()}`],
      );
      const userId = user.rows[0]?.id;
      assert.ok(userId);
      const principal: Principal = {
        kind: "jwt",
        userId,
        actorId: randomUUID(),
        scopes: new Set(),
      };

      await seedRetentionRows(database, principal, "resource");
      let resourceExecutions = 0;
      const resourceRequest = { body: { label: "retained resource response" } };
      const firstResource = await executeIdempotentMutation(
        database,
        principal,
        "retentionResourceCurrent",
        "retention-resource-current",
        resourceRequest,
        async () => {
          resourceExecutions += 1;
          return {
            status: 201,
            headers: { etag: '"retention-resource-r1"' },
            body: { source: "resource" },
          };
        },
      );
      assert.equal(firstResource.status, 201);
      assert.equal(await expiredCount(database, "resource"), 5);
      await assertRetainedResponse(database, "resource");

      const replayedResource = await executeIdempotentMutation(
        database,
        principal,
        "retentionResourceCurrent",
        "retention-resource-current",
        resourceRequest,
        async () => {
          resourceExecutions += 1;
          return { status: 500, headers: {}, body: { unexpected: true } };
        },
      );
      assert.equal(resourceExecutions, 1);
      assert.equal(replayedResource.replayed, true);
      assert.deepEqual(replayedResource.body, { source: "resource" });
      assert.equal(await expiredCount(database, "resource"), 0);
      await assertRetainedResponse(database, "resource");

      await seedRetentionRows(database, principal, "owner");
      let ownerExecutions = 0;
      const ownerRequest = { name: "retained owner response" };
      const firstOwner = await executeIdempotentJson({
        client: database,
        principal,
        operationId: "retentionOwnerCurrent",
        idempotencyKey: "retention-owner-current",
        request: ownerRequest,
        execute: async () => {
          ownerExecutions += 1;
          return {
            status: 201,
            headers: { etag: '"retention-owner-r1"' },
            body: { source: "owner" },
          };
        },
      });
      assert.equal(firstOwner.replayed, false);
      assert.equal(await expiredCount(database, "owner"), 5);
      await assertRetainedResponse(database, "owner");

      const replayedOwner = await executeIdempotentJson({
        client: database,
        principal,
        operationId: "retentionOwnerCurrent",
        idempotencyKey: "retention-owner-current",
        request: ownerRequest,
        execute: async () => {
          ownerExecutions += 1;
          return { status: 500, headers: {}, body: { unexpected: true } };
        },
      });
      assert.equal(ownerExecutions, 1);
      assert.equal(replayedOwner.replayed, true);
      assert.deepEqual(replayedOwner.body, { source: "owner" });
      assert.equal(await expiredCount(database, "owner"), 0);
      await assertRetainedResponse(database, "owner");
    } finally {
      await sql.query("ROLLBACK");
      await sql.end();
    }
  },
);

test(
  "resource and owner cleanup keep exact-key-first lock ordering",
  { skip: databaseUrl === undefined || databaseUrl.length === 0 },
  async () => {
    assert.ok(databaseUrl);
    const baseConfig = testConfig();
    const database = createPostgresDatabase({ ...baseConfig.database, url: databaseUrl });
    const coordinator = new Client({ connectionString: databaseUrl });
    await coordinator.connect();

    let userId: string | undefined;
    let coordinatorTransactionOpen = false;
    try {
      const user = await database.query<{ id: string }>(
        `INSERT INTO users (login, display_name, password_hash)
         VALUES ($1, 'Idempotency Lock Order', 'not-a-real-password-hash')
         RETURNING id`,
        [`idempotency-lock-order-${randomUUID()}`],
      );
      userId = user.rows[0]?.id;
      assert.ok(userId);
      const principal: Principal = {
        kind: "jwt",
        userId,
        actorId: randomUUID(),
        scopes: new Set(),
      };
      const resourceOperation = "retentionLockResource";
      const resourceKey = "retention-lock-resource";
      const ownerOperation = "retentionLockOwner";
      const ownerKey = "retention-lock-owner";
      await database.query(
        `INSERT INTO idempotency_keys (
           user_id, operation_id, idempotency_key, actor_type, actor_id,
           request_hash, created_at, expires_at
         ) VALUES
           ($1, $2, $3, 'jwt', $4, $5,
             TIMESTAMPTZ '2000-01-01T00:00:00Z', TIMESTAMPTZ '2001-01-01T00:00:00Z'),
           ($1, $6, $7, 'jwt', $4, $5,
             TIMESTAMPTZ '2000-01-01T00:00:00Z', TIMESTAMPTZ '2001-01-01T00:00:00Z')`,
        [
          userId,
          resourceOperation,
          resourceKey,
          principal.actorId,
          Buffer.alloc(32, 9),
          ownerOperation,
          ownerKey,
        ],
      );

      await coordinator.query("BEGIN");
      coordinatorTransactionOpen = true;
      await coordinator.query(
        `SELECT 1
         FROM idempotency_keys
         WHERE user_id = $1 AND operation_id = ANY($2::text[])
         FOR UPDATE`,
        [userId, [resourceOperation, ownerOperation]],
      );

      let resourceExecutions = 0;
      let ownerExecutions = 0;
      const resourceMutation = executeIdempotentMutation(
        database,
        principal,
        resourceOperation,
        resourceKey,
        { source: "resource-lock-order" },
        async () => {
          resourceExecutions += 1;
          return { status: 201, headers: {}, body: { source: "resource" } };
        },
      );
      const ownerMutation = database.transaction((client) =>
        executeIdempotentJson({
          client,
          principal,
          operationId: ownerOperation,
          idempotencyKey: ownerKey,
          request: { source: "owner-lock-order" },
          execute: async () => {
            ownerExecutions += 1;
            return { status: 201, headers: {}, body: { source: "owner" } };
          },
        }),
      );

      await delay(50);
      await coordinator.query("COMMIT");
      coordinatorTransactionOpen = false;
      const [resourceResult, ownerResult] = await withTimeout(
        Promise.all([resourceMutation, ownerMutation]),
        5_000,
      );

      assert.equal(resourceResult.status, 201);
      assert.equal(ownerResult.status, 201);
      assert.equal(resourceExecutions, 1);
      assert.equal(ownerExecutions, 1);
    } finally {
      if (coordinatorTransactionOpen) {
        await coordinator.query("ROLLBACK");
      }
      if (userId !== undefined) {
        await database.query("DELETE FROM users WHERE id = $1", [userId]);
      }
      await database.close();
      await coordinator.end();
    }
  },
);

async function seedRetentionRows(
  queryable: Queryable,
  principal: Principal,
  namespace: "resource" | "owner",
): Promise<void> {
  await queryable.query(
    `INSERT INTO idempotency_keys (
       user_id, operation_id, idempotency_key, actor_type, actor_id,
       request_hash, response_status, response_headers, response_body,
       created_at, expires_at
     )
     SELECT $1, $2, $3 || item::text, 'jwt', $4, $5, 201,
            '{"etag":"retired"}'::jsonb, '{"expired":true}'::jsonb,
            TIMESTAMPTZ '2000-01-01T00:00:00Z',
            TIMESTAMPTZ '2001-01-01T00:00:00Z'
     FROM generate_series(1, 105) AS item`,
    [
      principal.userId,
      `retention${namespace}Expired`,
      `retention-${namespace}-expired-`,
      principal.actorId,
      Buffer.alloc(32, 7),
    ],
  );
  await queryable.query(
    `INSERT INTO idempotency_keys (
       user_id, operation_id, idempotency_key, actor_type, actor_id,
       request_hash, response_status, response_headers, response_body, expires_at
     ) VALUES ($1, $2, $3, 'jwt', $4, $5, 202, $6::jsonb, $7::jsonb,
       now() + interval '1 hour')`,
    [
      principal.userId,
      `retention${namespace}Live`,
      `retention-${namespace}-live-response`,
      principal.actorId,
      Buffer.alloc(32, 8),
      JSON.stringify({ etag: `"retention-${namespace}-live"` }),
      JSON.stringify({ namespace, retained: true }),
    ],
  );
}

async function expiredCount(
  queryable: Queryable,
  namespace: "resource" | "owner",
): Promise<number> {
  const result = await queryable.query<{ count: string }>(
    `SELECT count(*)::text AS count
     FROM idempotency_keys
     WHERE operation_id = $1 AND expires_at <= now()`,
    [`retention${namespace}Expired`],
  );
  return Number(result.rows[0]?.count ?? "0");
}

async function assertRetainedResponse(
  queryable: Queryable,
  namespace: "resource" | "owner",
): Promise<void> {
  const result = await queryable.query<{
    response_status: number;
    response_headers: { etag: string };
    response_body: { namespace: string; retained: boolean };
  }>(
    `SELECT response_status, response_headers, response_body
     FROM idempotency_keys
     WHERE operation_id = $1 AND idempotency_key = $2`,
    [`retention${namespace}Live`, `retention-${namespace}-live-response`],
  );
  assert.deepEqual(result.rows[0], {
    response_status: 202,
    response_headers: { etag: `"retention-${namespace}-live"` },
    response_body: { namespace, retained: true },
  });
}

class TransactionScopedDatabase implements Database {
  constructor(private readonly client: Client) {}

  async query<Row extends QueryResultRow = QueryResultRow>(
    text: string,
    values?: readonly unknown[],
  ): Promise<DatabaseResult<Row>> {
    const result = await this.client.query<Row>(text, values === undefined ? [] : [...values]);
    return { rows: result.rows, rowCount: result.rowCount ?? result.rows.length };
  }

  async transaction<Result>(work: (client: Queryable) => Promise<Result>): Promise<Result> {
    return work(this);
  }

  async checkReadiness(): Promise<DatabaseReadiness> {
    return { ready: true, database: "up", pgvector: "up", latencyMs: 0 };
  }

  async close(): Promise<void> {}
}

async function delay(milliseconds: number): Promise<void> {
  await new Promise<void>((resolve) => setTimeout(resolve, milliseconds));
}

async function withTimeout<Result>(promise: Promise<Result>, milliseconds: number): Promise<Result> {
  return new Promise<Result>((resolve, reject) => {
    const timeout = setTimeout(
      () => reject(new Error(`Timed out after ${milliseconds}ms waiting for concurrent mutations`)),
      milliseconds,
    );
    promise.then(
      (result) => {
        clearTimeout(timeout);
        resolve(result);
      },
      (error: unknown) => {
        clearTimeout(timeout);
        reject(error);
      },
    );
  });
}
