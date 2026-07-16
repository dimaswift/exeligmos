import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import {
  loadMigrationFiles,
  validateMigrationHistory,
  type MigrationFile,
} from '../src/db/migration-files.js';

test('loadMigrationFiles sorts migrations and computes stable checksums', async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'exeligmos-migrations-'));
  try {
    await writeFile(path.join(directory, '0002_second.sql'), 'SELECT 2;\n');
    await writeFile(path.join(directory, '0001_first.sql'), 'SELECT 1;\n');

    const firstRead = await loadMigrationFiles(directory);
    const secondRead = await loadMigrationFiles(directory);

    assert.deepEqual(firstRead.map((migration) => migration.version), ['0001', '0002']);
    assert.deepEqual(
      firstRead.map((migration) => migration.checksum),
      secondRead.map((migration) => migration.checksum)
    );
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test('published sync migrations keep their applied checksums', async () => {
  const migrations = await loadMigrationFiles(path.resolve(process.cwd(), 'db/migrations'));
  const checksums = new Map(
    migrations.map((migration) => [migration.version, migration.checksum]),
  );

  assert.equal(
    checksums.get('0006'),
    '79cf889ecfa308fdeb88bef16c2b2bd131207fcfb68d0c468b3b5a2cc143e587',
  );
  assert.equal(
    checksums.get('0007'),
    '828e382cbd39c159a72158145581464490da4f2ab321f74c365f6c4ee621d2e6',
  );
});

test('loadMigrationFiles rejects malformed and duplicate versions', async () => {
  const malformedDirectory = await mkdtemp(path.join(os.tmpdir(), 'exeligmos-migrations-'));
  const duplicateDirectory = await mkdtemp(path.join(os.tmpdir(), 'exeligmos-migrations-'));
  try {
    await writeFile(path.join(malformedDirectory, 'initial.sql'), 'SELECT 1;\n');
    await assert.rejects(loadMigrationFiles(malformedDirectory), /Invalid migration filename/);
    await rm(path.join(malformedDirectory, 'initial.sql'));
    await writeFile(path.join(malformedDirectory, '10000_too_wide.sql'), 'SELECT 1;\n');
    await assert.rejects(loadMigrationFiles(malformedDirectory), /Invalid migration filename/);

    await writeFile(path.join(duplicateDirectory, '0001_first.sql'), 'SELECT 1;\n');
    await writeFile(path.join(duplicateDirectory, '0001_second.sql'), 'SELECT 2;\n');
    await assert.rejects(loadMigrationFiles(duplicateDirectory), /Duplicate migration version/);
  } finally {
    await rm(malformedDirectory, { recursive: true, force: true });
    await rm(duplicateDirectory, { recursive: true, force: true });
  }
});

test('validateMigrationHistory rejects missing and modified applied files', () => {
  const migration: MigrationFile = {
    version: '0001',
    fileName: '0001_initial.sql',
    absolutePath: '/migrations/0001_initial.sql',
    checksum: 'current',
    sql: 'SELECT 1;',
  };

  assert.doesNotThrow(() =>
    validateMigrationHistory([migration], [{ version: '0001', checksum: 'current' }]),
  );
  assert.throws(
    () => validateMigrationHistory([migration], [{ version: '0002', checksum: 'old' }]),
    /missing for version 0002/,
  );
  assert.throws(
    () => validateMigrationHistory([migration], [{ version: '0001', checksum: 'old' }]),
    /modified after it was applied/,
  );
});
