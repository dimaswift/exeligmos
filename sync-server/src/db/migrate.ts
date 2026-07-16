import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { Client } from 'pg';

import { loadMigrationFiles, validateMigrationHistory } from './migration-files.js';

const migrationLockKey = 893_827_451;

interface AppliedMigrationRow {
  version: string;
  checksum: string;
}

export async function runMigrations(options: {
  databaseUrl: string;
  directory: string;
}): Promise<string[]> {
  const migrations = await loadMigrationFiles(options.directory);
  const client = new Client({ connectionString: options.databaseUrl });
  const applied: string[] = [];
  let lockAcquired = false;

  await client.connect();
  try {
    await client.query('SELECT pg_advisory_lock($1)', [migrationLockKey]);
    lockAcquired = true;
    await client.query(`
      CREATE TABLE IF NOT EXISTS schema_migrations (
        version text PRIMARY KEY,
        file_name text NOT NULL,
        checksum text NOT NULL,
        applied_at timestamptz NOT NULL DEFAULT now()
      )
    `);

    const result = await client.query<AppliedMigrationRow>(
      'SELECT version, checksum FROM schema_migrations ORDER BY version'
    );
    validateMigrationHistory(migrations, result.rows);
    const existing = new Map(result.rows.map((row) => [row.version, row.checksum]));

    for (const migration of migrations) {
      const existingChecksum = existing.get(migration.version);
      if (existingChecksum !== undefined) {
        continue;
      }

      await client.query('BEGIN');
      try {
        await client.query(migration.sql);
        await client.query(
          `INSERT INTO schema_migrations (version, file_name, checksum)
           VALUES ($1, $2, $3)`,
          [migration.version, migration.fileName, migration.checksum]
        );
        await client.query('COMMIT');
        applied.push(migration.fileName);
      } catch (error) {
        await client.query('ROLLBACK');
        throw error;
      }
    }
  } finally {
    try {
      if (lockAcquired) {
        await client.query('SELECT pg_advisory_unlock($1)', [migrationLockKey]);
      }
    } finally {
      await client.end();
    }
  }

  return applied;
}

function defaultMigrationDirectory(): string {
  return path.resolve(process.cwd(), 'db/migrations');
}

async function main(): Promise<void> {
  const databaseUrl = process.env.DATABASE_URL?.trim();
  if (databaseUrl === undefined || databaseUrl.length === 0) {
    throw new Error('DATABASE_URL is required to run database migrations.');
  }

  const directory = process.env.MIGRATIONS_DIR?.trim() || defaultMigrationDirectory();
  const applied = await runMigrations({ databaseUrl, directory });
  if (applied.length === 0) {
    console.log('Database schema is already current.');
    return;
  }
  console.log(`Applied ${applied.length} migration(s): ${applied.join(', ')}`);
}

const isEntrypoint = process.argv[1] !== undefined && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isEntrypoint) {
  main().catch((error: unknown) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  });
}
