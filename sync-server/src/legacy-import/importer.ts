import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";

import type { QueryResultRow } from "pg";

import type { Database, Queryable } from "../db/database.js";
import {
  MediaStorageIntegrityError,
  MediaStorageMissingError,
  mediaStorageKey,
  type MediaStorage,
} from "../media/storage.js";
import {
  mappedDeviceId,
  type ResolvedLegacyImportMapping,
} from "./mapping.js";
import type {
  LegacyEntrySource,
  LegacyMediaSource,
  LegacyStoreManifest,
  LegacyStoreScan,
  LegacyTagSource,
} from "./scanner.js";

export interface LegacyImportOptions {
  readonly database: Database;
  readonly storage: MediaStorage;
  readonly scan: LegacyStoreScan;
  readonly mapping: ResolvedLegacyImportMapping;
  readonly dryRun: boolean;
  readonly onProgress?: (progress: LegacyImportProgress) => void;
}

export interface LegacyImportProgress {
  readonly phase: "tags" | "records" | "verify";
  readonly completed: number;
  readonly total: number;
  readonly resourceId?: string;
}

export interface LegacyImportResourceCounts {
  readonly tags: number;
  readonly records: number;
  readonly media: number;
}

export interface LegacyImportReport {
  readonly schemaVersion: 1;
  readonly mode: "dry-run" | "applied" | "verified-rerun";
  readonly userId: string;
  readonly sourceChecksum: string;
  readonly mappingChecksum: string;
  readonly source: LegacyImportResourceCounts & { readonly mediaBytes: number };
  readonly wouldCreate?: LegacyImportResourceCounts;
  readonly wouldVerify?: LegacyImportResourceCounts;
  readonly created?: LegacyImportResourceCounts;
  readonly verified: LegacyImportResourceCounts;
  readonly runId?: string;
}

export class LegacyImportConflictError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "LegacyImportConflictError";
  }
}

interface ExistingResources {
  readonly tags: ReadonlyMap<string, ExistingTagRow>;
  readonly records: ReadonlyMap<string, ExistingRecordRow>;
  readonly media: ReadonlyMap<string, ExistingMediaRow>;
}

interface ExistingTagRow extends QueryResultRow {
  readonly id: string;
  readonly user_id: string;
  readonly name?: string;
  readonly emoji?: string | null;
  readonly color?: string | null;
  readonly sort_order?: number;
  readonly source_sha256: string | null;
  readonly source_document?: unknown;
  readonly deleted_at: Date | string | null;
}

interface ExistingRecordRow extends QueryResultRow {
  readonly id: string;
  readonly user_id: string;
  readonly device_id: string;
  readonly visibility: string;
  readonly event_at?: Date | string;
  readonly end_at?: Date | string | null;
  readonly public_payload?: unknown;
  readonly source_kind?: string | null;
  readonly source_provider?: string | null;
  readonly source_external_id?: string | null;
  readonly source_sha256: string | null;
  readonly deleted_at: Date | string | null;
}

interface ExistingMediaRow extends QueryResultRow {
  readonly id: string;
  readonly user_id: string;
  readonly device_id: string;
  readonly visibility: string;
  readonly status: string;
  readonly file_name?: string;
  readonly content_type?: string;
  readonly byte_size: string | number;
  readonly sha256: string;
  readonly storage_key: string;
  readonly source_sha256: string | null;
}

interface UserRow extends QueryResultRow {
  readonly id: string;
  readonly status: string;
}

interface DeviceRow extends QueryResultRow {
  readonly id: string;
  readonly user_id: string;
  readonly revoked_at: Date | string | null;
}

interface ImportRunRow extends QueryResultRow {
  readonly id: string;
  readonly status: "running" | "completed" | "failed";
  readonly mapping_checksum: string;
  readonly attempt_count: number;
  readonly updated_at: Date | string;
}

interface ImportRun {
  readonly id: string;
  readonly attemptCount: number;
  readonly alreadyCompleted: boolean;
}

const IMPORT_LEASE_MINUTES = 10;

export async function importLegacyStore(options: LegacyImportOptions): Promise<LegacyImportReport> {
  const { database, storage, scan, mapping } = options;
  await validateOwnerAndDevices(database, scan, mapping);
  const existing = await inspectExistingResources(database, scan);
  validateExistingResources(scan, mapping, existing);
  const existingCounts = countsForExisting(existing);
  const sourceCounts = countsForSource(scan.manifest);
  const wouldCreate = subtractCounts(sourceCounts, existingCounts);

  if (options.dryRun) {
    return {
      schemaVersion: 1,
      mode: "dry-run",
      userId: mapping.userId,
      sourceChecksum: scan.manifest.sourceChecksum,
      mappingChecksum: mapping.mappingChecksum,
      source: { ...sourceCounts, mediaBytes: scan.manifest.mediaBytes },
      wouldCreate,
      wouldVerify: existingCounts,
      verified: { tags: 0, records: 0, media: 0 },
    };
  }

  const run = await beginImportRun(database, scan.manifest, mapping);
  if (run.alreadyCompleted) {
    await verifyImportedStore(database, storage, scan, mapping, options.onProgress);
    await database.query(
      `UPDATE legacy_import_runs
       SET last_verified_at = clock_timestamp(), updated_at = clock_timestamp()
       WHERE id = $1 AND attempt_count = $2 AND status = 'completed'`,
      [run.id, run.attemptCount],
    );
    return {
      schemaVersion: 1,
      mode: "verified-rerun",
      userId: mapping.userId,
      sourceChecksum: scan.manifest.sourceChecksum,
      mappingChecksum: mapping.mappingChecksum,
      source: { ...sourceCounts, mediaBytes: scan.manifest.mediaBytes },
      verified: sourceCounts,
      runId: run.id,
    };
  }

  const created = { tags: 0, records: 0, media: 0 };
  try {
    for (const [index, tag] of scan.tags.entries()) {
      created.tags += await importTag(database, mapping.userId, tag);
      await heartbeatImportRun(database, run);
      options.onProgress?.({
        phase: "tags",
        completed: index + 1,
        total: scan.tags.length,
        resourceId: tag.id,
      });
    }

    const tagIds = new Map(scan.tags.map((tag) => [tag.compactId, tag.id]));
    for (const [index, entry] of scan.entries.entries()) {
      await heartbeatImportRun(database, run);
      const result = await importEntry(database, storage, mapping, tagIds, entry);
      created.records += result.record;
      created.media += result.media;
      await heartbeatImportRun(database, run);
      options.onProgress?.({
        phase: "records",
        completed: index + 1,
        total: scan.entries.length,
        resourceId: entry.id,
      });
    }

    await verifyImportedStore(
      database,
      storage,
      scan,
      mapping,
      options.onProgress,
      () => heartbeatImportRun(database, run),
    );
    const report: LegacyImportReport = {
      schemaVersion: 1,
      mode: "applied",
      userId: mapping.userId,
      sourceChecksum: scan.manifest.sourceChecksum,
      mappingChecksum: mapping.mappingChecksum,
      source: { ...sourceCounts, mediaBytes: scan.manifest.mediaBytes },
      created,
      verified: sourceCounts,
      runId: run.id,
    };
    await completeImportRun(database, run, report);
    return report;
  } catch (error) {
    await failImportRun(database, run, error).catch(() => undefined);
    throw error;
  }
}

async function validateOwnerAndDevices(
  database: Database,
  scan: LegacyStoreScan,
  mapping: ResolvedLegacyImportMapping,
): Promise<void> {
  const user = await database.query<UserRow>(
    "SELECT id, status FROM users WHERE id = $1",
    [mapping.userId],
  );
  if (user.rows[0]?.status !== "active") {
    throw new LegacyImportConflictError(`Import owner ${mapping.userId} does not exist or is disabled`);
  }
  const requestedIds = [...new Set([
    ...scan.manifest.deviceIds.map((id) => mappedDeviceId(mapping, id)),
    ...(mapping.unattributedDeviceId === undefined ? [] : [mapping.unattributedDeviceId]),
  ])];
  const devices = await database.query<DeviceRow>(
    "SELECT id, user_id, revoked_at FROM devices WHERE id = ANY($1::uuid[])",
    [requestedIds],
  );
  const byId = new Map(devices.rows.map((row) => [row.id, row]));
  for (const deviceId of requestedIds) {
    const row = byId.get(deviceId);
    if (row === undefined || row.user_id !== mapping.userId || row.revoked_at !== null) {
      throw new LegacyImportConflictError(
        `Mapped device ${deviceId} must exist, belong to ${mapping.userId}, and remain active`,
      );
    }
  }
}

async function inspectExistingResources(
  database: Database,
  scan: LegacyStoreScan,
): Promise<ExistingResources> {
  const tagIds = scan.tags.map((tag) => tag.id);
  const recordIds = scan.entries.map((entry) => entry.id);
  const mediaIds = scan.entries.flatMap((entry) => entry.media.map((media) => media.id));
  const [tags, records, media] = await Promise.all([
    tagIds.length === 0
      ? { rows: [] as readonly ExistingTagRow[] }
      : database.query<ExistingTagRow>(
        `SELECT id, user_id, metadata #>> '{legacyImport,sourceSha256}' AS source_sha256,
                deleted_at
         FROM tags WHERE id = ANY($1::uuid[])`,
        [tagIds],
      ),
    recordIds.length === 0
      ? { rows: [] as readonly ExistingRecordRow[] }
      : database.query<ExistingRecordRow>(
        `SELECT id, user_id, device_id, visibility,
                metadata #>> '{legacyImport,sourceSha256}' AS source_sha256,
                deleted_at
         FROM records WHERE id = ANY($1::uuid[])`,
        [recordIds],
      ),
    mediaIds.length === 0
      ? { rows: [] as readonly ExistingMediaRow[] }
      : database.query<ExistingMediaRow>(
        `SELECT id, user_id, device_id, visibility, status, file_name, content_type, byte_size,
                encode(sha256, 'hex') AS sha256, storage_key,
                metadata #>> '{legacyImport,sourceSha256}' AS source_sha256
         FROM media_objects WHERE id = ANY($1::uuid[])`,
        [mediaIds],
      ),
  ]);
  return {
    tags: new Map(tags.rows.map((row) => [row.id, row])),
    records: new Map(records.rows.map((row) => [row.id, row])),
    media: new Map(media.rows.map((row) => [row.id, row])),
  };
}

function validateExistingResources(
  scan: LegacyStoreScan,
  mapping: ResolvedLegacyImportMapping,
  existing: ExistingResources,
): void {
  for (const tag of scan.tags) {
    const row = existing.tags.get(tag.id);
    if (
      row !== undefined &&
      (row.user_id !== mapping.userId ||
        row.source_sha256 !== tag.sha256 ||
        row.deleted_at !== null)
    ) {
      throw new LegacyImportConflictError(`Tag ${tag.id} already exists but is not this legacy source object`);
    }
  }
  for (const entry of scan.entries) {
    const deviceId = mappedDeviceId(mapping, entry.sourceDeviceId);
    const row = existing.records.get(entry.id);
    if (
      row !== undefined &&
      (row.user_id !== mapping.userId ||
        row.device_id !== deviceId ||
        row.visibility !== "public" ||
        row.source_sha256 !== entry.sha256 ||
        row.deleted_at !== null)
    ) {
      throw new LegacyImportConflictError(`Record ${entry.id} already exists but is not this legacy source object`);
    }
    for (const media of entry.media) {
      const mediaRow = existing.media.get(media.id);
      const key = mediaStorageKey(mapping.userId, media.id);
      if (
        mediaRow !== undefined &&
        (mediaRow.user_id !== mapping.userId ||
          mediaRow.device_id !== deviceId ||
          mediaRow.visibility !== "public" ||
          mediaRow.status !== "ready" ||
          Number(mediaRow.byte_size) !== media.byteLength ||
          mediaRow.sha256 !== media.sha256 ||
          mediaRow.storage_key !== key ||
          mediaRow.source_sha256 !== media.sha256)
      ) {
        throw new LegacyImportConflictError(`Media ${media.id} already exists but is not this legacy source object`);
      }
    }
  }
}

async function beginImportRun(
  database: Database,
  manifest: LegacyStoreManifest,
  mapping: ResolvedLegacyImportMapping,
): Promise<ImportRun> {
  return database.transaction(async (queryable) => {
    const existing = await queryable.query<ImportRunRow>(
      `SELECT id, status, encode(mapping_checksum, 'hex') AS mapping_checksum,
              attempt_count, updated_at
       FROM legacy_import_runs
       WHERE user_id = $1 AND source_checksum = decode($2, 'hex')
       FOR UPDATE`,
      [mapping.userId, manifest.sourceChecksum],
    );
    const row = existing.rows[0];
    if (row === undefined) {
      const inserted = await queryable.query<{
        readonly id: string;
        readonly attempt_count: number;
      } & QueryResultRow>(
        `INSERT INTO legacy_import_runs (
           user_id, source_checksum, mapping_checksum, status, manifest
         ) VALUES ($1, decode($2, 'hex'), decode($3, 'hex'), 'running', $4::jsonb)
         RETURNING id, attempt_count`,
        [mapping.userId, manifest.sourceChecksum, mapping.mappingChecksum, JSON.stringify(storedManifest(manifest))],
      );
      const insertedRun = inserted.rows[0];
      if (insertedRun === undefined) throw new Error("Legacy import run could not be created");
      const { id, attempt_count: attemptCount } = insertedRun;
      await writeImportAudit(queryable, mapping.userId, id, "legacy_import.start", storedManifest(manifest));
      return { id, attemptCount, alreadyCompleted: false };
    }
    if (row.mapping_checksum !== mapping.mappingChecksum) {
      throw new LegacyImportConflictError(
        "This source checksum is already bound to a different owner/device mapping",
      );
    }
    if (row.status === "completed") {
      return { id: row.id, attemptCount: row.attempt_count, alreadyCompleted: true };
    }
    const updatedAt = new Date(row.updated_at).getTime();
    if (row.status === "running" && Date.now() - updatedAt < IMPORT_LEASE_MINUTES * 60_000) {
      throw new LegacyImportConflictError(
        `Legacy import ${row.id} is already running; retry after its ${IMPORT_LEASE_MINUTES}-minute lease expires`,
      );
    }
    const resumed = await queryable.query<{ readonly attempt_count: number } & QueryResultRow>(
      `UPDATE legacy_import_runs
       SET status = 'running', failure = NULL, result = NULL,
           attempt_count = attempt_count + 1,
           started_at = clock_timestamp(), updated_at = clock_timestamp(),
           completed_at = NULL
       WHERE id = $1
       RETURNING attempt_count`,
      [row.id],
    );
    const attemptCount = resumed.rows[0]?.attempt_count;
    if (attemptCount === undefined) throw new Error("Legacy import run could not be resumed");
    await writeImportAudit(queryable, mapping.userId, row.id, "legacy_import.resume", {});
    return { id: row.id, attemptCount, alreadyCompleted: false };
  });
}

async function importTag(database: Database, userId: string, tag: LegacyTagSource): Promise<number> {
  return database.transaction(async (queryable) => {
    const result = await queryable.query(
      `INSERT INTO tags (
         id, user_id, name, emoji, color, sort_order, metadata, created_at, updated_at
       ) VALUES ($1, $2, $3, $4, $5, $6, $7::jsonb, $8::timestamptz, $9::timestamptz)
       ON CONFLICT (id) DO NOTHING`,
      [
        tag.id,
        userId,
        legacyString(tag.document.name) ?? `Legacy tag ${tag.compactId}`,
        legacyString(tag.document.emoji),
        legacyColor(tag.document.colorHex),
        Number.parseInt(tag.compactId, 8),
        JSON.stringify(legacyMetadata(tag.relativePath, tag.sha256, tag.document)),
        legacyDate(tag.document.createdAt),
        legacyDate(tag.document.updatedAt),
      ],
    );
    await assertTagImported(queryable, userId, tag);
    return result.rowCount;
  });
}

async function importEntry(
  database: Database,
  storage: MediaStorage,
  mapping: ResolvedLegacyImportMapping,
  tagIds: ReadonlyMap<string, string>,
  entry: LegacyEntrySource,
): Promise<{ readonly record: number; readonly media: number }> {
  const deviceId = mappedDeviceId(mapping, entry.sourceDeviceId);
  let createdMedia = 0;
  for (const media of entry.media) {
    createdMedia += await importMedia(database, storage, mapping.userId, deviceId, media);
  }

  const createdRecord = await database.transaction(async (queryable) => {
    const inserted = await queryable.query(
      `INSERT INTO records (
         id, user_id, device_id, visibility, event_at, end_at, public_payload,
         metadata, source_kind, source_provider, source_external_id,
         source_metadata, created_at, updated_at
       ) VALUES (
         $1, $2, $3, 'public', $4::timestamptz, $5::timestamptz, $6::jsonb,
         $7::jsonb, 'import', 'exeligmos.folder-relay', $8,
         $9::jsonb, $10::timestamptz, $11::timestamptz
       )
       ON CONFLICT (id) DO NOTHING`,
      [
        entry.id,
        mapping.userId,
        deviceId,
        entry.eventDate,
        entry.endDate ?? null,
        JSON.stringify(entry.document),
        JSON.stringify(legacyMetadata(entry.relativePath, entry.sha256)),
        entry.id,
        JSON.stringify({
          legacyDeviceId: entry.sourceDeviceId ?? null,
          legacyDeviceName: legacyString(entry.document.sourceDeviceName) ?? null,
          legacyDeviceEmoji: legacyString(entry.document.sourceDeviceEmoji) ?? null,
        }),
        entry.createdAt,
        entry.updatedAt,
      ],
    );
    await assertRecordImported(queryable, mapping.userId, deviceId, entry);
    for (const compactId of entry.tagCompactIds) {
      const tagId = tagIds.get(compactId);
      if (tagId === undefined) {
        throw new LegacyImportConflictError(`Record ${entry.id} references unresolved tag ${compactId}`);
      }
      await queryable.query(
        `INSERT INTO record_tags (user_id, record_id, tag_id)
         VALUES ($1, $2, $3) ON CONFLICT (record_id, tag_id) DO NOTHING`,
        [mapping.userId, entry.id, tagId],
      );
    }
    for (const [position, media] of entry.media.entries()) {
      await queryable.query(
        `INSERT INTO record_media (user_id, record_id, media_id, position)
         VALUES ($1, $2, $3, $4)
         ON CONFLICT (record_id, media_id) DO NOTHING`,
        [mapping.userId, entry.id, media.id, position],
      );
    }
    await assertRecordRelationships(queryable, entry, tagIds);
    return inserted.rowCount;
  });
  return { record: createdRecord, media: createdMedia };
}

async function importMedia(
  database: Database,
  storage: MediaStorage,
  userId: string,
  deviceId: string,
  media: LegacyMediaSource,
): Promise<number> {
  const key = mediaStorageKey(userId, media.id);
  const existing = await database.query<ExistingMediaRow>(
    `SELECT id, user_id, device_id, visibility, status, file_name, content_type, byte_size,
            encode(sha256, 'hex') AS sha256, storage_key,
            metadata #>> '{legacyImport,sourceSha256}' AS source_sha256
     FROM media_objects WHERE id = $1`,
    [media.id],
  );
  if (existing.rows[0] !== undefined) {
    assertExistingMedia(existing.rows[0], userId, deviceId, key, media);
    await verifyStoredMedia(storage, key, media);
    return 0;
  }

  await storage.writeVerified(
    key,
    createReadStream(media.absolutePath),
    media.byteLength,
    media.sha256,
  );
  return database.transaction(async (queryable) => {
    const result = await queryable.query(
      `INSERT INTO media_objects (
         id, user_id, device_id, visibility, status, file_name, content_type,
         byte_size, sha256, storage_key, metadata, created_at, updated_at, completed_at
       ) VALUES (
         $1, $2, $3, 'public', 'ready', $4, $5,
         $6, decode($7, 'hex'), $8, $9::jsonb,
         $10::timestamptz, $10::timestamptz, $10::timestamptz
       )
       ON CONFLICT (id) DO NOTHING`,
      [
        media.id,
        userId,
        deviceId,
        media.fileName,
        media.contentType,
        media.byteLength,
        media.sha256,
        key,
        JSON.stringify(legacyMetadata(media.relativePath, media.sha256, { type: media.type })),
        media.createdAt,
      ],
    );
    const inserted = await queryable.query<ExistingMediaRow>(
      `SELECT id, user_id, device_id, visibility, status, file_name, content_type, byte_size,
              encode(sha256, 'hex') AS sha256, storage_key,
              metadata #>> '{legacyImport,sourceSha256}' AS source_sha256
       FROM media_objects WHERE id = $1`,
      [media.id],
    );
    const row = inserted.rows[0];
    if (row === undefined) throw new Error(`Imported media ${media.id} could not be reloaded`);
    assertExistingMedia(row, userId, deviceId, key, media);
    return result.rowCount;
  });
}

async function verifyImportedStore(
  database: Database,
  storage: MediaStorage,
  scan: LegacyStoreScan,
  mapping: ResolvedLegacyImportMapping,
  onProgress: LegacyImportOptions["onProgress"],
  heartbeat?: () => Promise<void>,
): Promise<void> {
  const existing = await inspectExistingResources(database, scan);
  validateExistingResources(scan, mapping, existing);
  const expected = countsForSource(scan.manifest);
  const actual = countsForExisting(existing);
  if (actual.tags !== expected.tags || actual.records !== expected.records || actual.media !== expected.media) {
    throw new LegacyImportConflictError(
      `Imported counts differ: expected ${JSON.stringify(expected)}, found ${JSON.stringify(actual)}`,
    );
  }
  const tagIds = new Map(scan.tags.map((tag) => [tag.compactId, tag.id]));
  for (const tag of scan.tags) {
    await assertTagImported(database, mapping.userId, tag);
  }
  let completed = 0;
  for (const entry of scan.entries) {
    await heartbeat?.();
    const deviceId = mappedDeviceId(mapping, entry.sourceDeviceId);
    await database.transaction(async (queryable) => {
      await assertRecordImported(queryable, mapping.userId, deviceId, entry);
      await assertRecordRelationships(queryable, entry, tagIds);
    });
    for (const media of entry.media) {
      await verifyStoredMedia(storage, mediaStorageKey(mapping.userId, media.id), media);
    }
    await heartbeat?.();
    completed += 1;
    onProgress?.({ phase: "verify", completed, total: scan.entries.length, resourceId: entry.id });
  }
}

async function verifyStoredMedia(
  storage: MediaStorage,
  key: string,
  media: LegacyMediaSource,
): Promise<void> {
  try {
    const stored = await storage.open(key);
    if (stored.byteLength !== media.byteLength) {
      throw new LegacyImportConflictError(`Stored media ${media.id} has the wrong byte length`);
    }
    const hash = createHash("sha256");
    let bytes = 0;
    for await (const chunk of stored.stream) {
      const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      bytes += buffer.byteLength;
      hash.update(buffer);
    }
    if (bytes !== media.byteLength || hash.digest("hex") !== media.sha256) {
      throw new LegacyImportConflictError(`Stored media ${media.id} failed checksum verification`);
    }
  } catch (error) {
    if (error instanceof LegacyImportConflictError) throw error;
    if (error instanceof MediaStorageMissingError || error instanceof MediaStorageIntegrityError) {
      throw new LegacyImportConflictError(`Stored media ${media.id} is missing or corrupt`);
    }
    throw error;
  }
}

async function assertTagImported(
  queryable: Queryable,
  userId: string,
  tag: LegacyTagSource,
): Promise<void> {
  const result = await queryable.query<ExistingTagRow>(
    `SELECT id, user_id, name, emoji, color, sort_order,
            metadata #>> '{legacyImport,sourceSha256}' AS source_sha256,
            metadata #> '{legacyImport,document}' AS source_document,
            deleted_at
     FROM tags WHERE id = $1`,
    [tag.id],
  );
  const row = result.rows[0];
  if (
    row === undefined || row.user_id !== userId || row.source_sha256 !== tag.sha256 ||
    row.deleted_at !== null ||
    row.name !== (legacyString(tag.document.name) ?? `Legacy tag ${tag.compactId}`) ||
    row.emoji !== (legacyString(tag.document.emoji) ?? null) ||
    row.color !== legacyColor(tag.document.colorHex) ||
    row.sort_order !== Number.parseInt(tag.compactId, 8) ||
    canonicalJson(row.source_document) !== canonicalJson(tag.document)
  ) {
    throw new LegacyImportConflictError(`Tag ${tag.id} conflicts with the import source`);
  }
}

async function assertRecordImported(
  queryable: Queryable,
  userId: string,
  deviceId: string,
  entry: LegacyEntrySource,
): Promise<void> {
  const result = await queryable.query<ExistingRecordRow>(
    `SELECT id, user_id, device_id, visibility, event_at, end_at, public_payload,
            source_kind, source_provider, source_external_id,
            metadata #>> '{legacyImport,sourceSha256}' AS source_sha256,
            deleted_at
     FROM records WHERE id = $1`,
    [entry.id],
  );
  const row = result.rows[0];
  if (
    row === undefined || row.user_id !== userId || row.device_id !== deviceId ||
    row.visibility !== "public" || row.source_sha256 !== entry.sha256 ||
    row.deleted_at !== null ||
    row.event_at === undefined || new Date(row.event_at).toISOString() !== entry.eventDate ||
    (row.end_at === null ? undefined : row.end_at === undefined ? undefined : new Date(row.end_at).toISOString()) !== entry.endDate ||
    canonicalJson(row.public_payload) !== canonicalJson(entry.document) ||
    row.source_kind !== "import" || row.source_provider !== "exeligmos.folder-relay" ||
    row.source_external_id !== entry.id
  ) {
    throw new LegacyImportConflictError(`Record ${entry.id} conflicts with the import source`);
  }
}

async function assertRecordRelationships(
  queryable: Queryable,
  entry: LegacyEntrySource,
  tagIds: ReadonlyMap<string, string>,
): Promise<void> {
  const relationships = await queryable.query<{
    readonly tag_ids: readonly string[];
    readonly media_ids: readonly string[];
  } & QueryResultRow>(
    `SELECT
       ARRAY(SELECT tag_id::text FROM record_tags WHERE record_id = $1 ORDER BY tag_id) AS tag_ids,
       ARRAY(SELECT media_id::text FROM record_media WHERE record_id = $1 ORDER BY position) AS media_ids`,
    [entry.id],
  );
  const row = relationships.rows[0];
  const expectedTags = entry.tagCompactIds.map((id) => tagIds.get(id)!).sort();
  const expectedMedia = entry.media.map((item) => item.id);
  if (
    row === undefined ||
    row.tag_ids.join("\0") !== expectedTags.join("\0") ||
    row.media_ids.join("\0") !== expectedMedia.join("\0")
  ) {
    throw new LegacyImportConflictError(`Record ${entry.id} has incomplete tag or media relationships`);
  }
}

function assertExistingMedia(
  row: ExistingMediaRow,
  userId: string,
  deviceId: string,
  key: string,
  media: LegacyMediaSource,
): void {
  if (
    row.user_id !== userId || row.device_id !== deviceId || row.visibility !== "public" ||
    row.status !== "ready" || Number(row.byte_size) !== media.byteLength ||
    row.sha256 !== media.sha256 || row.storage_key !== key || row.source_sha256 !== media.sha256 ||
    (row.file_name !== undefined && row.file_name !== media.fileName) ||
    (row.content_type !== undefined && row.content_type !== media.contentType)
  ) {
    throw new LegacyImportConflictError(`Media ${media.id} conflicts with the import source`);
  }
}

async function heartbeatImportRun(database: Database, run: ImportRun): Promise<void> {
  const result = await database.query(
    `UPDATE legacy_import_runs
     SET updated_at = clock_timestamp()
     WHERE id = $1 AND attempt_count = $2 AND status = 'running'`,
    [run.id, run.attemptCount],
  );
  assertImportLeaseHeld(result.rowCount, run);
}

async function completeImportRun(
  database: Database,
  run: ImportRun,
  report: LegacyImportReport,
): Promise<void> {
  await database.transaction(async (queryable) => {
    const completed = await queryable.query(
      `UPDATE legacy_import_runs
       SET status = 'completed', result = $2::jsonb, failure = NULL,
           completed_at = clock_timestamp(), last_verified_at = clock_timestamp(),
           updated_at = clock_timestamp()
       WHERE id = $1 AND attempt_count = $3 AND status = 'running'`,
      [run.id, JSON.stringify(report), run.attemptCount],
    );
    assertImportLeaseHeld(completed.rowCount, run);
    await writeImportAudit(queryable, report.userId, run.id, "legacy_import.complete", report.source);
  });
}

async function failImportRun(database: Database, run: ImportRun, error: unknown): Promise<void> {
  const failure = (error instanceof Error ? error.message : String(error)).slice(0, 4_000);
  await database.query(
    `UPDATE legacy_import_runs
     SET status = 'failed', failure = $2, result = NULL,
         completed_at = NULL, updated_at = clock_timestamp()
     WHERE id = $1 AND attempt_count = $3 AND status = 'running'`,
    [run.id, failure, run.attemptCount],
  );
}

function assertImportLeaseHeld(rowCount: number, run: ImportRun): void {
  if (rowCount !== 1) {
    throw new LegacyImportConflictError(
      `Legacy import ${run.id} attempt ${run.attemptCount} lost its lease to a newer attempt`,
    );
  }
}

async function writeImportAudit(
  queryable: Queryable,
  userId: string,
  runId: string,
  action: string,
  metadata: unknown,
): Promise<void> {
  await queryable.query(
    `INSERT INTO audit_log (user_id, actor_type, action, entity_type, entity_id, metadata)
     VALUES ($1, 'system', $2, 'legacy_import', $3, $4::jsonb)`,
    [userId, action, runId, JSON.stringify(metadata)],
  );
}

function legacyMetadata(
  relativePath: string,
  sourceSha256: string,
  document?: unknown,
): Record<string, unknown> {
  return {
    legacyImport: {
      schemaVersion: 1,
      sourcePath: relativePath,
      sourceSha256,
      ...(document === undefined ? {} : { document }),
    },
  };
}

function legacyString(value: unknown): string | undefined {
  return typeof value === "string" && value.trim().length > 0 ? value : undefined;
}

function legacyColor(value: unknown): string | null {
  return typeof value === "string" && /^#[0-9A-Fa-f]{6}(?:[0-9A-Fa-f]{2})?$/.test(value)
    ? value
    : null;
}

function legacyDate(value: unknown): string {
  if (typeof value !== "string" || !Number.isFinite(Date.parse(value))) {
    throw new LegacyImportConflictError("Legacy resource contains an invalid timestamp after scanning");
  }
  return new Date(value).toISOString();
}

function storedManifest(manifest: LegacyStoreManifest): Record<string, unknown> {
  return {
    schemaVersion: manifest.schemaVersion,
    sourceChecksum: manifest.sourceChecksum,
    tagCount: manifest.tagCount,
    recordCount: manifest.recordCount,
    mediaCount: manifest.mediaCount,
    mediaBytes: manifest.mediaBytes,
    deviceIds: manifest.deviceIds,
  };
}

function countsForSource(manifest: LegacyStoreManifest): LegacyImportResourceCounts {
  return { tags: manifest.tagCount, records: manifest.recordCount, media: manifest.mediaCount };
}

function countsForExisting(existing: ExistingResources): LegacyImportResourceCounts {
  return { tags: existing.tags.size, records: existing.records.size, media: existing.media.size };
}

function subtractCounts(
  total: LegacyImportResourceCounts,
  existing: LegacyImportResourceCounts,
): LegacyImportResourceCounts {
  return {
    tags: total.tags - existing.tags,
    records: total.records - existing.records,
    media: total.media - existing.media,
  };
}

function canonicalJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (typeof value === "object" && value !== null) {
    const object = value as Record<string, unknown>;
    return `{${Object.keys(object).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson(object[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}
