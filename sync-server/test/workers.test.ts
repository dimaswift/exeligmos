import assert from "node:assert/strict";
import test from "node:test";

import type {
  Database,
  DatabaseReadiness,
  DatabaseResult,
  Queryable,
} from "../src/db/database.js";
import { WorkerService } from "../src/resources/workers.js";
import type { Principal } from "../src/auth/principal.js";
import type { QueryResultRow } from "pg";

const USER_ID = "11111111-1111-4111-8111-111111111111";
const DEVICE_ID = "22222222-2222-4222-8222-222222222222";

test("THUMB reset deletes durable fingerprints and advances the local cache generation", async () => {
  const database = new ScriptedDatabase([
    (sql, values) => {
      assert.match(sql, /FROM devices/);
      assert.match(sql, /metadata->>'source' = 'THUMB_CAM'/);
      assert.deepEqual(values, [USER_ID, DEVICE_ID]);
      return rows([
        {
          metadata: {
            source: "THUMB_CAM",
            thumbCamReset: { generation: 4 },
          },
        },
      ]);
    },
    (sql) => {
      assert.match(sql, /count\(DISTINCT j\.id\)/);
      return rows([{ jobs: "12", items: "48" }]);
    },
    (sql) => {
      assert.match(sql, /DELETE FROM ingestion_jobs/);
      return rows([]);
    },
    (sql) => {
      assert.match(sql, /DELETE FROM idempotency_keys/);
      assert.match(sql, /createIngestionJob/);
      return rows([]);
    },
    (sql, values) => {
      assert.match(sql, /UPDATE devices/);
      assert.deepEqual(values, [USER_ID, DEVICE_ID, 5]);
      return rows([{ reset_at: "2026-07-31T10:00:00.000Z" }]);
    },
    (sql, values) => {
      assert.match(sql, /INSERT INTO worker_logs/);
      assert.deepEqual(values?.slice(0, 2), [USER_ID, DEVICE_ID]);
      assert.deepEqual(JSON.parse(String(values?.[2])), {
        event: "worker_cache_reset",
        cacheGeneration: 5,
        removedJobs: 12,
        removedItems: 48,
      });
      return rows([]);
    },
  ]);
  const service = new WorkerService(database);

  const result = await service.resetThumbCam(jwtPrincipal(), DEVICE_ID);

  assert.deepEqual(result, {
    deviceId: DEVICE_ID,
    cacheGeneration: 5,
    resetAt: "2026-07-31T10:00:00.000Z",
    removedJobs: 12,
    removedItems: 48,
  });
  database.assertDone();
});

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

  async transaction<Result>(
    work: (client: Queryable) => Promise<Result>,
  ): Promise<Result> {
    return work(this);
  }

  async checkReadiness(): Promise<DatabaseReadiness> {
    return { ready: true, database: "up", pgvector: "up", latencyMs: 0 };
  }

  async close(): Promise<void> {}

  assertDone(): void {
    assert.equal(this.steps.length, 0);
  }
}

function rows<Row extends QueryResultRow>(values: Row[]): DatabaseResult<Row> {
  return { rows: values, rowCount: values.length };
}

function jwtPrincipal(): Principal {
  return {
    kind: "jwt",
    userId: USER_ID,
    actorId: "33333333-3333-4333-8333-333333333333",
    scopes: new Set(),
  };
}
