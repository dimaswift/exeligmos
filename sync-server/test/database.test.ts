import assert from "node:assert/strict";
import test from "node:test";

import {
  PostgresDatabase,
  type DatabasePool,
} from "../src/db/database.js";

function fakePool(
  query: DatabasePool["query"],
  onEnd: () => void = () => undefined,
): DatabasePool {
  return {
    query,
    async end() {
      onEnd();
    },
  };
}

test("PostgresDatabase is ready only when pgvector is installed", async () => {
  const database = new PostgresDatabase(
    fakePool(async (config) => {
      assert.equal(config.query_timeout, 500);
      assert.match(config.text, /pg_catalog\.pg_extension/);
      return { rows: [{ pgvector_version: "0.8.5" }] };
    }),
    500,
  );

  const result = await database.checkReadiness();

  assert.equal(result.ready, true);
  assert.equal(result.database, "up");
  assert.equal(result.pgvector, "up");
  assert.equal(result.pgvectorVersion, "0.8.5");
});

test("PostgresDatabase reports a reachable database without pgvector as not ready", async () => {
  const database = new PostgresDatabase(
    fakePool(async () => ({ rows: [{ pgvector_version: null }] })),
    500,
  );

  const result = await database.checkReadiness();

  assert.equal(result.ready, false);
  assert.equal(result.database, "up");
  assert.equal(result.pgvector, "down");
});

test("PostgresDatabase contains connection failures and closes the pool once", async () => {
  let closes = 0;
  const database = new PostgresDatabase(
    fakePool(
      async () => {
        throw new Error("connection details that must not escape");
      },
      () => {
        closes += 1;
      },
    ),
    500,
  );

  const result = await database.checkReadiness();
  await database.close();
  await database.close();

  assert.deepEqual(
    {
      ready: result.ready,
      database: result.database,
      pgvector: result.pgvector,
    },
    { ready: false, database: "down", pgvector: "unknown" },
  );
  assert.equal(closes, 1);
});
