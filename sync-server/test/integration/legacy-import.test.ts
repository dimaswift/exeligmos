import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { Client } from "pg";

import { createPostgresDatabase } from "../../src/db/database.js";
import { runMigrations } from "../../src/db/migrate.js";
import {
  importLegacyStore,
  LegacyImportConflictError,
} from "../../src/legacy-import/importer.js";
import { validateLegacyImportMapping } from "../../src/legacy-import/mapping.js";
import { scanLegacyStore } from "../../src/legacy-import/scanner.js";
import {
  LocalMediaStorage,
  mediaStorageKey,
  type MediaStorage,
  type StoredMediaStream,
} from "../../src/media/storage.js";
import { testConfig } from "../helpers.js";

const databaseUrl = process.env.TEST_DATABASE_URL?.trim();

test(
  "legacy importer dry-runs, applies, verifies reruns, and detects stored-byte corruption",
  { skip: databaseUrl === undefined || databaseUrl.length === 0 },
  async () => {
    assert.ok(databaseUrl);
    await runMigrations({
      databaseUrl,
      directory: path.resolve(process.cwd(), "db/migrations"),
    });
    const temporary = await mkdtemp(path.join(os.tmpdir(), "exeligmos-legacy-import-"));
    const sourceRoot = path.join(temporary, "source");
    const storageRoot = path.join(temporary, "storage");
    const ids = {
      tag: randomUUID(),
      record: randomUUID(),
      media: randomUUID(),
    };
    await writeFixture(sourceRoot, ids);

    const admin = new Client({ connectionString: databaseUrl });
    await admin.connect();
    const login = `legacy-import-${randomUUID()}`;
    const user = await admin.query<{ id: string }>(
      `INSERT INTO users (login, display_name, password_hash)
       VALUES ($1, 'Legacy Import', 'not-a-real-password-hash') RETURNING id`,
      [login],
    );
    const userId = user.rows[0]!.id;
    const device = await admin.query<{ id: string }>(
      `INSERT INTO devices (user_id, name, kind)
       VALUES ($1, 'Legacy phone', 'ios') RETURNING id`,
      [userId],
    );
    const deviceId = device.rows[0]!.id;
    const base = testConfig().database;
    const database = createPostgresDatabase({ ...base, url: databaseUrl });
    const storage = new LocalMediaStorage(storageRoot);

    try {
      const scan = await scanLegacyStore(sourceRoot);
      const mapping = validateLegacyImportMapping({
        schemaVersion: 1,
        userId,
        devices: { PHONE: deviceId },
      }, scan);
      const dryRun = await importLegacyStore({ database, storage, scan, mapping, dryRun: true });
      assert.equal(dryRun.mode, "dry-run");
      assert.deepEqual(dryRun.wouldCreate, { tags: 1, records: 1, media: 1 });

      const applied = await importLegacyStore({ database, storage, scan, mapping, dryRun: false });
      assert.equal(applied.mode, "applied");
      assert.deepEqual(applied.created, { tags: 1, records: 1, media: 1 });
      const stored = await admin.query<{
        payload_text: string;
        tags: string[];
        media: string[];
      }>(
        `SELECT r.public_payload->>'text' AS payload_text,
                ARRAY(SELECT tag_id::text FROM record_tags WHERE record_id = r.id) AS tags,
                ARRAY(SELECT media_id::text FROM record_media WHERE record_id = r.id ORDER BY position) AS media
         FROM records r WHERE r.id = $1`,
        [ids.record],
      );
      assert.equal(stored.rows[0]?.payload_text, "migrated fixture");
      assert.deepEqual(stored.rows[0]?.tags, [ids.tag]);
      assert.deepEqual(stored.rows[0]?.media, [ids.media]);

      const changesBeforeRerun = await importedChangeCount(admin, userId, ids);
      const rerun = await importLegacyStore({ database, storage, scan, mapping, dryRun: false });
      assert.equal(rerun.mode, "verified-rerun");
      assert.equal(await importedChangeCount(admin, userId, ids), changesBeforeRerun);

      await admin.query(
        "UPDATE records SET deleted_at = clock_timestamp() WHERE id = $1",
        [ids.record],
      );
      await assert.rejects(
        importLegacyStore({ database, storage, scan, mapping, dryRun: false }),
        (error: unknown) => {
          assert.ok(error instanceof LegacyImportConflictError);
          assert.match(error.message, /Record .* already exists but is not this legacy source object/);
          return true;
        },
      );
      // Restore only to exercise the independent stored-byte corruption check;
      // production cutover must treat the failed verification as a hard stop.
      await admin.query(
        "UPDATE records SET deleted_at = NULL WHERE id = $1",
        [ids.record],
      );

      const storedPath = path.join(storageRoot, ...mediaStorageKey(userId, ids.media).split("/"));
      await writeFile(storedPath, "corrupt bytes");
      await assert.rejects(
        importLegacyStore({ database, storage, scan, mapping, dryRun: false }),
        (error: unknown) => {
          assert.ok(error instanceof LegacyImportConflictError);
          assert.match(error.message, /wrong byte length|checksum verification/);
          return true;
        },
      );
    } finally {
      await database.close();
      await admin.query("DELETE FROM legacy_import_runs WHERE user_id = $1", [userId]);
      await admin.query("DELETE FROM users WHERE id = $1", [userId]);
      await admin.end();
      await rm(temporary, { recursive: true, force: true });
    }
  },
);

test(
  "a stale legacy importer cannot heartbeat, fail, or complete a resumed attempt",
  { skip: databaseUrl === undefined || databaseUrl.length === 0 },
  async () => {
    assert.ok(databaseUrl);
    await runMigrations({
      databaseUrl,
      directory: path.resolve(process.cwd(), "db/migrations"),
    });
    const temporary = await mkdtemp(path.join(os.tmpdir(), "exeligmos-legacy-lease-"));
    const sourceRoot = path.join(temporary, "source");
    const storageRoot = path.join(temporary, "storage");
    const ids = {
      tag: randomUUID(),
      record: randomUUID(),
      media: randomUUID(),
    };
    await writeFixture(sourceRoot, ids);

    const admin = new Client({ connectionString: databaseUrl });
    await admin.connect();
    const user = await admin.query<{ id: string }>(
      `INSERT INTO users (login, display_name, password_hash)
       VALUES ($1, 'Legacy Lease', 'not-a-real-password-hash') RETURNING id`,
      [`legacy-lease-${randomUUID()}`],
    );
    const userId = user.rows[0]!.id;
    const device = await admin.query<{ id: string }>(
      `INSERT INTO devices (user_id, name, kind)
       VALUES ($1, 'Legacy lease phone', 'ios') RETURNING id`,
      [userId],
    );
    const deviceId = device.rows[0]!.id;
    const base = testConfig().database;
    const database = createPostgresDatabase({ ...base, url: databaseUrl });
    const storage = new LocalMediaStorage(storageRoot);
    const pausedStorage = new PausingWriteStorage(storage);
    let staleAttempt: Promise<unknown> | undefined;

    try {
      const scan = await scanLegacyStore(sourceRoot);
      const mapping = validateLegacyImportMapping({
        schemaVersion: 1,
        userId,
        devices: { PHONE: deviceId },
      }, scan);

      staleAttempt = importLegacyStore({
        database,
        storage: pausedStorage,
        scan,
        mapping,
        dryRun: false,
      });
      await pausedStorage.writeStarted;

      const firstAttempt = await admin.query<{
        id: string;
        status: string;
        attempt_count: number;
      }>(
        `SELECT id, status, attempt_count
         FROM legacy_import_runs
         WHERE user_id = $1 AND source_checksum = decode($2, 'hex')`,
        [userId, scan.manifest.sourceChecksum],
      );
      assert.equal(firstAttempt.rows[0]?.status, "running");
      assert.equal(firstAttempt.rows[0]?.attempt_count, 1);
      await admin.query(
        `UPDATE legacy_import_runs
         SET updated_at = clock_timestamp() - interval '11 minutes'
         WHERE id = $1 AND attempt_count = 1`,
        [firstAttempt.rows[0]!.id],
      );

      const resumed = await importLegacyStore({
        database,
        storage,
        scan,
        mapping,
        dryRun: false,
      });
      assert.equal(resumed.mode, "applied");

      pausedStorage.release();
      await assert.rejects(staleAttempt, (error: unknown) => {
        assert.ok(error instanceof LegacyImportConflictError);
        assert.match(error.message, /attempt 1 lost its lease to a newer attempt/);
        return true;
      });

      const finalRun = await admin.query<{
        status: string;
        attempt_count: number;
        failure: string | null;
        mode: string | null;
      }>(
        `SELECT status, attempt_count, failure, result->>'mode' AS mode
         FROM legacy_import_runs
         WHERE id = $1`,
        [firstAttempt.rows[0]!.id],
      );
      assert.deepEqual(finalRun.rows[0], {
        status: "completed",
        attempt_count: 2,
        failure: null,
        mode: "applied",
      });
    } finally {
      pausedStorage.release();
      await staleAttempt?.catch(() => undefined);
      await database.close();
      await admin.query("DELETE FROM legacy_import_runs WHERE user_id = $1", [userId]);
      await admin.query("DELETE FROM users WHERE id = $1", [userId]);
      await admin.end();
      await rm(temporary, { recursive: true, force: true });
    }
  },
);

async function importedChangeCount(
  client: Client,
  userId: string,
  ids: { readonly tag: string; readonly record: string; readonly media: string },
): Promise<number> {
  const result = await client.query<{ count: string }>(
    `SELECT count(*)::text AS count FROM change_log
     WHERE user_id = $1 AND entity_id = ANY($2::uuid[])`,
    [userId, [ids.tag, ids.record, ids.media]],
  );
  return Number(result.rows[0]?.count ?? 0);
}

async function writeFixture(
  root: string,
  ids: { readonly tag: string; readonly record: string; readonly media: string },
): Promise<void> {
  const tagDirectory = path.join(root, "tags", ids.tag);
  const entryDirectory = path.join(root, "entries", "fixture");
  const mediaDirectory = path.join(entryDirectory, "media");
  await Promise.all([
    mkdir(tagDirectory, { recursive: true }),
    mkdir(mediaDirectory, { recursive: true }),
  ]);
  await writeFile(path.join(tagDirectory, "tag.json"), JSON.stringify({
    id: ids.tag,
    octalID: "007",
    name: "Imported tag",
    emoji: "◇",
    colorHex: "#112233",
    anchorDate: "2026-01-01T00:00:00Z",
    saros: 1,
    createdAt: "2026-01-01T00:00:00Z",
    updatedAt: "2026-01-01T00:00:00Z",
  }));
  const relativeMediaPath = `entries/fixture/media/${ids.media}.txt`;
  await writeFile(path.join(root, relativeMediaPath), "legacy bytes\n");
  await writeFile(path.join(entryDirectory, "entry.json"), JSON.stringify({
    id: ids.record,
    createdAt: "2026-01-02T00:00:00Z",
    updatedAt: "2026-01-03T00:00:00Z",
    eventDate: "2026-01-02T01:00:00Z",
    endDate: "2026-01-02T02:00:00Z",
    text: "migrated fixture",
    sourceDeviceID: "PHONE",
    sourceDeviceName: "Legacy phone",
    sourceDeviceEmoji: "◇",
    tagIDs: ["007"],
    mediaItems: [{
      id: ids.media,
      type: "document",
      localPath: `${ids.media}.txt`,
      createdAt: "2026-01-02T00:30:00Z",
    }],
  }));
  await writeFile(path.join(entryDirectory, "media.json"), JSON.stringify([{
    id: ids.media,
    type: "document",
    createdAt: "2026-01-02T00:30:00Z",
    relativePath: relativeMediaPath,
    fileName: `${ids.media}.txt`,
    contentType: "text/plain",
  }]));
}

class PausingWriteStorage implements MediaStorage {
  readonly writeStarted: Promise<void>;
  private readonly released: Promise<void>;
  private resolveWriteStarted!: () => void;
  private resolveReleased!: () => void;
  private paused = false;

  constructor(private readonly delegate: MediaStorage) {
    this.writeStarted = new Promise((resolve) => {
      this.resolveWriteStarted = resolve;
    });
    this.released = new Promise((resolve) => {
      this.resolveReleased = resolve;
    });
  }

  async writeVerified(
    key: string,
    source: AsyncIterable<Uint8Array | string>,
    expectedByteLength: number,
    expectedSha256: string,
  ): Promise<void> {
    if (!this.paused) {
      this.paused = true;
      this.resolveWriteStarted();
      await this.released;
    }
    await this.delegate.writeVerified(key, source, expectedByteLength, expectedSha256);
  }

  open(key: string): Promise<StoredMediaStream> {
    return this.delegate.open(key);
  }

  delete(key: string): Promise<void> {
    return this.delegate.delete(key);
  }

  release(): void {
    this.resolveReleased();
  }
}
