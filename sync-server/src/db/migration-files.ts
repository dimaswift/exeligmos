import { createHash } from 'node:crypto';
import { readdir, readFile } from 'node:fs/promises';
import path from 'node:path';

const migrationFilePattern = /^(?<version>\d{4})_[a-z0-9][a-z0-9_-]*\.sql$/;

export interface MigrationFile {
  version: string;
  fileName: string;
  absolutePath: string;
  checksum: string;
  sql: string;
}

export interface AppliedMigration {
  readonly version: string;
  readonly checksum: string;
}

export function validateMigrationHistory(
  available: readonly MigrationFile[],
  applied: readonly AppliedMigration[],
): void {
  const filesByVersion = new Map(available.map((migration) => [migration.version, migration]));

  for (const migration of applied) {
    const file = filesByVersion.get(migration.version);
    if (file === undefined) {
      throw new Error(
        `Applied migration file is missing for version ${migration.version}. ` +
          "Restore the file before running migrations.",
      );
    }
    if (file.checksum !== migration.checksum) {
      throw new Error(
        `Migration ${file.fileName} was modified after it was applied. ` +
          `Expected checksum ${migration.checksum}, received ${file.checksum}.`,
      );
    }
  }
}

export async function loadMigrationFiles(directory: string): Promise<MigrationFile[]> {
  const entries = await readdir(directory, { withFileTypes: true });
  const candidates = entries
    .filter((entry) => entry.isFile() && entry.name.endsWith('.sql'))
    .sort((left, right) => left.name.localeCompare(right.name));

  const migrations: MigrationFile[] = [];
  const seenVersions = new Set<string>();

  for (const candidate of candidates) {
    const match = migrationFilePattern.exec(candidate.name);
    const version = match?.groups?.version;
    if (version === undefined) {
      throw new Error(`Invalid migration filename ${candidate.name}. Expected NNNN_description.sql.`);
    }
    if (seenVersions.has(version)) {
      throw new Error(`Duplicate migration version ${version}.`);
    }
    seenVersions.add(version);

    const absolutePath = path.join(directory, candidate.name);
    const sql = await readFile(absolutePath, 'utf8');
    if (sql.trim().length === 0) {
      throw new Error(`Migration ${candidate.name} is empty.`);
    }

    migrations.push({
      version,
      fileName: candidate.name,
      absolutePath,
      checksum: createHash('sha256').update(sql).digest('hex'),
      sql
    });
  }

  return migrations;
}
