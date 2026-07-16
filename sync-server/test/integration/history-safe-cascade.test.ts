import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import path from "node:path";
import test from "node:test";

import { Client } from "pg";

import { runMigrations } from "../../src/db/migrate.js";

const databaseUrl = process.env.TEST_DATABASE_URL?.trim();

test(
  "append-only cascade guards preserve migration history and safely remove user-owned sync state",
  { skip: databaseUrl === undefined || databaseUrl.length === 0 },
  async () => {
    assert.ok(databaseUrl);
    await runMigrations({
      databaseUrl,
      directory: path.resolve(process.cwd(), "db/migrations"),
    });

    const database = new Client({ connectionString: databaseUrl });
    await database.connect();
    let transactionOpen = false;
    let userId: string | undefined;

    try {
      const history = await database.query<{ version: string; checksum: string }>(
        `SELECT version, checksum
         FROM schema_migrations
         WHERE version = ANY($1::text[])
         ORDER BY version`,
        [["0006", "0007"]],
      );
      assert.deepEqual(history.rows, [
        {
          version: "0006",
          checksum: "79cf889ecfa308fdeb88bef16c2b2bd131207fcfb68d0c468b3b5a2cc143e587",
        },
        {
          version: "0007",
          checksum: "828e382cbd39c159a72158145581464490da4f2ab321f74c365f6c4ee621d2e6",
        },
      ]);

      await database.query("BEGIN");
      transactionOpen = true;
      const user = await database.query<{ id: string }>(
        `INSERT INTO users (login, display_name, password_hash)
         VALUES ($1, 'Cascade guard', 'not-a-real-password-hash')
         RETURNING id`,
        [`cascade-guard-${randomUUID()}`],
      );
      userId = user.rows[0]?.id;
      assert.ok(userId);

      await database.query(
        `INSERT INTO legacy_import_runs (
           user_id, source_checksum, mapping_checksum, status, manifest
         ) VALUES ($1, $2, $3, 'running', '{}'::jsonb)`,
        [userId, Buffer.alloc(32, 1), Buffer.alloc(32, 2)],
      );
      await database.query(
        `INSERT INTO sync_change_retention (
           user_id, entity_type, last_pruned_sequence
         )
         SELECT $1, 'user', max(sequence)
         FROM change_log
         WHERE user_id = $1`,
        [userId],
      );

      const ownedBefore = await ownedRowCounts(database, userId);
      assert.equal(ownedBefore.legacy_import_runs, "1");
      assert.equal(ownedBefore.sync_change_retention, "1");
      assert.notEqual(ownedBefore.change_log, "0");

      await database.query("COMMIT");
      transactionOpen = false;

      await database.query("BEGIN");
      transactionOpen = true;
      await database.query("DELETE FROM users WHERE id = $1", [userId]);
      await database.query("COMMIT");
      transactionOpen = false;

      assert.deepEqual(await ownedRowCounts(database, userId), {
        users: "0",
        legacy_import_runs: "0",
        sync_change_retention: "0",
        change_log: "0",
      });
    } finally {
      if (transactionOpen) {
        await database.query("ROLLBACK");
      }
      if (userId !== undefined) {
        await database.query("DELETE FROM users WHERE id = $1", [userId]).catch(() => undefined);
      }
      await database.end();
    }
  },
);

async function ownedRowCounts(
  database: Client,
  userId: string,
): Promise<{
  users: string;
  legacy_import_runs: string;
  sync_change_retention: string;
  change_log: string;
}> {
  const result = await database.query<{
    users: string;
    legacy_import_runs: string;
    sync_change_retention: string;
    change_log: string;
  }>(
    `SELECT
       (SELECT count(*) FROM users WHERE id = $1)::text AS users,
       (SELECT count(*) FROM legacy_import_runs WHERE user_id = $1)::text
         AS legacy_import_runs,
       (SELECT count(*) FROM sync_change_retention WHERE user_id = $1)::text
         AS sync_change_retention,
       (SELECT count(*) FROM change_log WHERE user_id = $1)::text AS change_log`,
    [userId],
  );
  const row = result.rows[0];
  assert.ok(row);
  return row;
}
