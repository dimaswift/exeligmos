import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { Client } from "pg";

import {
  applyPendingDatabaseMigrations,
  ensureMigrationTable,
  loadDatabaseMigrations,
  stampDatabaseMigrations,
} from "./migrations.js";

const setupLockKey = 893_827_451;
const baselineTables = [
  "api_keys",
  "api_rate_limit_buckets",
  "audit_log",
  "auth_rate_limits",
  "auth_sessions",
  "change_log",
  "devices",
  "event_revisions",
  "events",
  "ingestion_job_items",
  "ingestion_jobs",
  "idempotency_keys",
  "media_objects",
  "media_upload_sessions",
  "public_activity",
  "record_embeddings",
  "record_media",
  "record_revisions",
  "record_tags",
  "users",
  "records",
  "resource_references",
  "subscriptions",
  "sync_change_retention",
  "sync_mutation_receipts",
  "tags",
  "templates",
  "user_encryption_profiles",
] as const;
// Append future tables here without changing baselineTables. Existing
// databases are upgraded by ordered db/migrations files before this final
// shape is verified.
const canonicalTables = [
  ...baselineTables,
  "worker_dream_attempts",
  "worker_logs",
] as const;
const migrationTable = "schema_migrations";

export type DatabaseSetupResult = "created" | "migrated" | "ready";

export async function ensureDatabaseSchema(options: {
  readonly databaseUrl: string;
  readonly schemaPath?: string;
  readonly migrationDirectory?: string;
}): Promise<DatabaseSetupResult> {
  const client = new Client({ connectionString: options.databaseUrl });
  await client.connect();
  try {
    await client.query("SELECT pg_advisory_lock($1)", [setupLockKey]);
    const migrations = await loadDatabaseMigrations(options.migrationDirectory);
    const initialTables = await applicationTables(client);
    if (initialTables.size === 0) {
      const schemaPath = options.schemaPath ?? defaultSchemaPath();
      await client.query(await readFile(schemaPath, "utf8"));
      await ensureMigrationTable(client);
      // schema.sql is always the latest complete shape, so its migrations are
      // recorded without replaying their DDL on top of that shape.
      await stampDatabaseMigrations(client, migrations);
      await assertCanonicalShape(client);
      return "created";
    }

    assertNoUnexpectedTables(initialTables);
    const missingBaseline = baselineTables.filter(
      (table) => !initialTables.has(table),
    );
    if (missingBaseline.length > 0) {
      throw new Error(
        "Database predates the supported migration baseline or is incomplete. " +
          `Missing tables: ${missingBaseline.join(", ")}.`,
      );
    }

    const migrationTableExisted = initialTables.has(migrationTable);
    await ensureMigrationTable(client);
    if (!migrationTableExisted) {
      // This adopts databases created from the canonical schema immediately
      // before migration tracking was introduced. Their full table set proves
      // that every current migration is already represented.
      const isCurrentCanonical = canonicalTables.every((table) =>
        initialTables.has(table),
      );
      if (!isCurrentCanonical) {
        throw new Error(
          "Database has no migration history and does not match the migration baseline.",
        );
      }
      await stampDatabaseMigrations(client, migrations);
      await assertCanonicalShape(client);
      return "migrated";
    }

    const appliedCount = await applyPendingDatabaseMigrations(
      client,
      migrations,
    );
    await assertCanonicalShape(client);
    return appliedCount > 0 ? "migrated" : "ready";
  } finally {
    try {
      await client.query("SELECT pg_advisory_unlock($1)", [setupLockKey]);
    } finally {
      await client.end();
    }
  }
}

async function applicationTables(client: Client): Promise<ReadonlySet<string>> {
  const result = await client.query<{ readonly tablename: string }>(
    `SELECT tablename
     FROM pg_catalog.pg_tables
     WHERE schemaname = 'public'
       AND tablename <> 'spatial_ref_sys'
     ORDER BY tablename`,
  );
  return new Set(result.rows.map((row) => row.tablename));
}

function assertNoUnexpectedTables(tables: ReadonlySet<string>): void {
  const allowed = new Set<string>([...canonicalTables, migrationTable]);
  const unexpected = [...tables].filter((table) => !allowed.has(table));
  if (unexpected.length > 0) {
    throw new Error(
      `Database contains unsupported public tables: ${unexpected.join(", ")}.`,
    );
  }
}

async function assertCanonicalShape(client: Client): Promise<void> {
  const tables = await applicationTables(client);
  const expected = new Set<string>([...canonicalTables, migrationTable]);
  const missing = [...expected].filter((table) => !tables.has(table));
  const unexpected = [...tables].filter((table) => !expected.has(table));
  if (missing.length > 0 || unexpected.length > 0) {
    throw new Error(
      "Database does not match the canonical Fractonica schema after migrations. " +
        `Missing: ${missing.join(", ") || "none"}. ` +
        `Unexpected: ${unexpected.join(", ") || "none"}.`,
    );
  }
}

function defaultSchemaPath(): string {
  return path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../db/schema.sql");
}

async function main(): Promise<void> {
  const databaseUrl = process.env.DATABASE_URL?.trim();
  if (!databaseUrl) {
    throw new Error("DATABASE_URL is required to set up the database.");
  }
  const result = await ensureDatabaseSchema({ databaseUrl });
  console.log(
    result === "created"
      ? "Canonical database schema created."
      : result === "migrated"
        ? "Database migrations applied."
        : "Canonical database schema is ready.",
  );
}

const entrypoint = process.argv[1];
if (entrypoint !== undefined && path.resolve(entrypoint) === fileURLToPath(import.meta.url)) {
  void main().catch((error: unknown) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  });
}
