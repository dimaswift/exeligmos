import { createHash } from "node:crypto";
import { readdir, readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import type { Client } from "pg";

const migrationNamePattern = /^\d{4}_[a-z0-9_]+\.sql$/;

export interface DatabaseMigration {
  readonly id: string;
  readonly checksum: string;
  readonly sql: string;
}

export function defaultMigrationDirectory(): string {
  return path.resolve(
    path.dirname(fileURLToPath(import.meta.url)),
    "../../db/migrations",
  );
}

export async function loadDatabaseMigrations(
  directory = defaultMigrationDirectory(),
): Promise<readonly DatabaseMigration[]> {
  const entries = await readdir(directory, { withFileTypes: true });
  const names = entries
    .filter((entry) => entry.isFile() && entry.name.endsWith(".sql"))
    .map((entry) => entry.name)
    .sort();

  for (const name of names) {
    if (!migrationNamePattern.test(name)) {
      throw new Error(
        `Invalid database migration filename ${JSON.stringify(name)}. ` +
          "Use NNNN_lowercase_name.sql.",
      );
    }
  }

  const migrations = await Promise.all(
    names.map(async (id): Promise<DatabaseMigration> => {
      const sql = await readFile(path.join(directory, id), "utf8");
      return {
        id,
        checksum: createHash("sha256").update(sql).digest("hex"),
        sql,
      };
    }),
  );
  return migrations;
}

export async function ensureMigrationTable(client: Client): Promise<boolean> {
  const existing = await client.query<{ exists: boolean }>(
    "SELECT to_regclass('public.schema_migrations') IS NOT NULL AS exists",
  );
  const didExist = existing.rows[0]?.exists === true;
  if (!didExist) {
    await client.query(`
      CREATE TABLE public.schema_migrations (
        id text PRIMARY KEY,
        checksum text NOT NULL,
        applied_at timestamptz NOT NULL DEFAULT now(),
        CONSTRAINT schema_migrations_id_check
          CHECK (id ~ '^[0-9]{4}_[a-z0-9_]+[.]sql$'),
        CONSTRAINT schema_migrations_checksum_check
          CHECK (checksum ~ '^[a-f0-9]{64}$')
      )
    `);
  }
  return didExist;
}

export async function stampDatabaseMigrations(
  client: Client,
  migrations: readonly DatabaseMigration[],
): Promise<void> {
  await client.query("BEGIN");
  try {
    for (const migration of migrations) {
      await client.query(
        `INSERT INTO public.schema_migrations (id, checksum)
         VALUES ($1, $2)
         ON CONFLICT (id) DO NOTHING`,
        [migration.id, migration.checksum],
      );
    }
    await client.query("COMMIT");
  } catch (error) {
    await client.query("ROLLBACK");
    throw error;
  }
  await verifyAppliedMigrations(client, migrations);
}

export async function applyPendingDatabaseMigrations(
  client: Client,
  migrations: readonly DatabaseMigration[],
): Promise<number> {
  const applied = await verifyAppliedMigrations(client, migrations);
  let appliedCount = 0;
  for (const migration of migrations) {
    if (applied.has(migration.id)) {
      continue;
    }
    await client.query("BEGIN");
    try {
      await client.query(migration.sql);
      await client.query(
        `INSERT INTO public.schema_migrations (id, checksum)
         VALUES ($1, $2)`,
        [migration.id, migration.checksum],
      );
      await client.query("COMMIT");
      appliedCount += 1;
    } catch (error) {
      await client.query("ROLLBACK");
      throw new Error(`Database migration ${migration.id} failed.`, {
        cause: error,
      });
    }
  }
  return appliedCount;
}

async function verifyAppliedMigrations(
  client: Client,
  migrations: readonly DatabaseMigration[],
): Promise<ReadonlySet<string>> {
  const rows = await client.query<{ id: string; checksum: string }>(
    "SELECT id, checksum FROM public.schema_migrations ORDER BY id",
  );
  const expected = new Map(
    migrations.map((migration) => [migration.id, migration.checksum]),
  );
  for (const row of rows.rows) {
    const checksum = expected.get(row.id);
    if (checksum === undefined) {
      throw new Error(
        `Database records migration ${row.id}, but that migration file is missing.`,
      );
    }
    if (checksum !== row.checksum) {
      throw new Error(
        `Database migration ${row.id} was edited after it was applied.`,
      );
    }
  }
  return new Set(rows.rows.map((row) => row.id));
}
