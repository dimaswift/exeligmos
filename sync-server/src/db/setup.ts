import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { Client } from "pg";

const setupLockKey = 893_827_451;
const canonicalTables = [
  "api_keys",
  "api_rate_limit_buckets",
  "audit_log",
  "auth_rate_limits",
  "auth_sessions",
  "change_log",
  "devices",
  "event_revisions",
  "events",
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

export type DatabaseSetupResult = "created" | "ready";

export async function ensureDatabaseSchema(options: {
  readonly databaseUrl: string;
  readonly schemaPath?: string;
}): Promise<DatabaseSetupResult> {
  const client = new Client({ connectionString: options.databaseUrl });
  await client.connect();
  try {
    await client.query("SELECT pg_advisory_lock($1)", [setupLockKey]);
    const state = await databaseState(client);
    if (state === "ready") {
      return "ready";
    }
    if (state === "partial") {
      throw new Error(
        "Database is not empty and does not match the canonical Fractonica schema. " +
          "Use a fresh database instead of attempting an in-place conversion.",
      );
    }

    const schemaPath = options.schemaPath ?? defaultSchemaPath();
    await client.query(await readFile(schemaPath, "utf8"));
    if ((await databaseState(client)) !== "ready") {
      throw new Error("Canonical schema setup completed without creating every required table.");
    }
    return "created";
  } finally {
    try {
      await client.query("SELECT pg_advisory_unlock($1)", [setupLockKey]);
    } finally {
      await client.end();
    }
  }
}

async function databaseState(client: Client): Promise<"empty" | "partial" | "ready"> {
  const result = await client.query<{
    readonly application_tables: string;
    readonly canonical_tables: string;
  }>(
    `SELECT
       count(*) FILTER (
         WHERE schemaname = 'public'
           AND tablename <> ALL($1::text[])
       )::text AS application_tables,
       count(*) FILTER (
         WHERE schemaname = 'public'
           AND tablename = ANY($2::text[])
       )::text AS canonical_tables
     FROM pg_catalog.pg_tables`,
    [
      ["spatial_ref_sys"],
      [...canonicalTables],
    ],
  );
  const row = result.rows[0];
  const applicationTables = Number(row?.application_tables ?? "0");
  const presentCanonicalTables = Number(row?.canonical_tables ?? "0");
  if (
    applicationTables === canonicalTables.length &&
    presentCanonicalTables === canonicalTables.length
  ) {
    return "ready";
  }
  return applicationTables === 0 ? "empty" : "partial";
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
