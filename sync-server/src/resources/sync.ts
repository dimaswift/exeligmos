import { createHash } from "node:crypto";

import type { QueryResultRow } from "pg";

import type { Principal } from "../auth/principal.js";
import type { Database, Queryable } from "../db/database.js";
import { HttpProblem, type ProblemDocument } from "../http/problem.js";
import {
  type CreateEventInput,
  createEventInTransaction,
  deleteEventInTransaction,
  loadEventResourcesForSync,
  replaceEventInTransaction,
} from "./events.js";
import { loadMediaResourcesForSync } from "./media.js";
import {
  type CreateRecordInput,
  assertRecordPublicId,
  createRecordInTransaction,
  deleteRecordInTransaction,
  loadRecordResourcesForSync,
  replaceRecordInTransaction,
} from "./records.js";
import {
  assertActiveOwnedDevice,
  assertApiKeyDevice,
  canonicalJson,
  databaseErrorCode,
  executeIdempotentMutation,
  invalidRequest,
  isoDate,
  type MutationResponse,
  translateDatabaseError,
  unprocessable,
} from "./shared.js";
import {
  type CreateTagInput,
  createTagInTransaction,
  deleteTagInTransaction,
  loadActiveTagResources,
  replaceTagInTransaction,
  tagEtag,
} from "./tags.js";
import {
  type CreateTemplateInput,
  createTemplateInTransaction,
  loadActiveTemplateResources,
  replaceTemplateInTransaction,
  retireTemplateInTransaction,
  templateEtag,
} from "./templates.js";
import { loadSubscriptionResourcesForSync } from "./social.js";

export const SYNC_RESOURCE_TYPES = [
  "record",
  "event",
  "tag",
  "template",
  "device",
  "media",
  "user",
  "subscription",
] as const;

export type SyncResourceType = (typeof SYNC_RESOURCE_TYPES)[number];
export type SyncMutationResourceType = "record" | "event" | "tag" | "template";

export interface SyncChangeQuery {
  readonly cursor?: string;
  readonly limit?: unknown;
  readonly resourceTypes?: readonly string[];
}

export interface SyncTombstone {
  readonly id: string;
  readonly userId: string;
  readonly resourceType: SyncResourceType;
  readonly revision: number;
  readonly deletedAt: string;
}

export interface SyncChange {
  readonly sequence: number;
  readonly changedAt: string;
  readonly resourceType: SyncResourceType;
  readonly operation: "upsert" | "delete";
  readonly resourceId: string;
  readonly revision: number;
  readonly etag: string;
  readonly resource?: unknown;
  readonly tombstone?: SyncTombstone;
}

export interface SyncChangePage {
  readonly data: readonly SyncChange[];
  readonly nextCursor: string;
  readonly hasMore: boolean;
}

export interface SyncResourceCount {
  readonly total: number;
}

export interface SyncRecordCount extends SyncResourceCount {
  readonly public: number;
  readonly private: number;
  readonly pastTera: number;
  readonly pastGiga: number;
  readonly pastMega: number;
}

export interface SyncMediaCount extends SyncResourceCount {
  readonly byteLength: number;
  readonly photo: number;
  readonly video: number;
  readonly audio: number;
  readonly restorable: number;
  readonly restorableByteLength: number;
}

export interface SyncStats {
  readonly cursor: string;
  readonly records: SyncRecordCount;
  readonly events: SyncResourceCount;
  readonly tags: SyncResourceCount;
  readonly templates: SyncResourceCount;
  readonly media: SyncMediaCount;
}

export interface UpsertRecordMutation {
  readonly kind: "upsertRecord";
  readonly clientMutationId: string;
  readonly ifMatch?: string;
  readonly record: CreateRecordInput;
}

export interface UpsertEventMutation {
  readonly kind: "upsertEvent";
  readonly clientMutationId: string;
  readonly ifMatch?: string;
  readonly event: CreateEventInput;
}

export interface UpsertTagMutation {
  readonly kind: "upsertTag";
  readonly clientMutationId: string;
  readonly ifMatch?: string;
  readonly tag: CreateTagInput;
}

export interface UpsertTemplateMutation {
  readonly kind: "upsertTemplate";
  readonly clientMutationId: string;
  readonly ifMatch?: string;
  readonly template: CreateTemplateInput;
}

export interface DeleteSyncMutation {
  readonly kind: "delete";
  readonly clientMutationId: string;
  readonly resourceType: SyncMutationResourceType;
  readonly resourceId: string;
  readonly ifMatch: string;
}

export type SyncMutation =
  | UpsertRecordMutation
  | UpsertEventMutation
  | UpsertTagMutation
  | UpsertTemplateMutation
  | DeleteSyncMutation;

export interface SyncBatchInput {
  readonly deviceId: string;
  readonly atomic?: boolean;
  readonly mutations: readonly SyncMutation[];
}

export interface SyncProblemDocument extends ProblemDocument {
  readonly instance: string;
}

export interface SyncMutationResult {
  readonly clientMutationId: string;
  readonly status: "succeeded" | "failed";
  readonly resourceType?: SyncResourceType;
  readonly resourceId?: string;
  readonly revision?: number;
  readonly etag?: string;
  readonly problem?: SyncProblemDocument;
}

export interface SyncBatchResponse {
  readonly results: readonly SyncMutationResult[];
}

interface ChangeRow extends QueryResultRow {
  readonly sequence: string | number;
  readonly changed_at: Date | string;
  readonly entity_type: SyncResourceType;
  readonly entity_id: string;
  readonly external_entity_id: string;
  readonly operation: "upsert" | "delete";
  readonly revision: string | number;
}

interface SyncMetaRow extends QueryResultRow {
  readonly high_water: string | number;
  readonly last_pruned: string | number;
}

interface SyncStatsRow extends QueryResultRow {
  readonly high_water: string | number;
  readonly public_record_count: string | number;
  readonly private_record_count: string | number;
  readonly past_tera_record_count: string | number;
  readonly past_giga_record_count: string | number;
  readonly past_mega_record_count: string | number;
  readonly event_count: string | number;
  readonly tag_count: string | number;
  readonly template_count: string | number;
  readonly media_count: string | number;
  readonly media_byte_length: string | number;
  readonly photo_media_count: string | number;
  readonly video_media_count: string | number;
  readonly audio_media_count: string | number;
  readonly restorable_media_count: string | number;
  readonly restorable_media_byte_length: string | number;
}

interface RevisionRow extends QueryResultRow {
  readonly revision: string | number;
}

interface ReceiptRow extends QueryResultRow {
  readonly request_hash: Buffer;
  readonly result: unknown;
}

interface DeletedAtRow extends QueryResultRow {
  readonly entity_type: SyncResourceType;
  readonly entity_id: string;
  readonly deleted_at: Date | string;
}

interface DeviceRow extends QueryResultRow {
  readonly id: string;
  readonly user_id: string;
  readonly name: string;
  readonly kind: string;
  readonly platform: string | null;
  readonly app_version: string | null;
  readonly metadata: Readonly<Record<string, unknown>>;
  readonly revision: string | number;
  readonly registered_at: Date | string;
  readonly updated_at: Date | string;
  readonly last_seen_at: Date | string | null;
  readonly revoked_at: Date | string | null;
}

interface UserRow extends QueryResultRow {
  readonly id: string;
  readonly login: string;
  readonly display_name: string;
  readonly saros_anchor: number;
  readonly created_at: Date | string;
  readonly updated_at: Date | string;
}

interface VersionedResource {
  readonly id: string;
  readonly revision: number;
}

interface ResourceStateRow extends QueryResultRow {
  readonly public_id?: string;
  readonly deleted_at: Date | string | null;
  readonly revision: string | number;
}

interface ReceiptReservation {
  readonly replay?: SyncMutationResult;
  readonly requestHash: Buffer;
}

const SYNC_CURSOR_KIND = "sync-changes";
const DEFAULT_CHANGE_LIMIT = 50;
const MAX_CHANGE_LIMIT = 200;
const MAX_BATCH_MUTATIONS = 20;
const RECEIPT_RETENTION_DAYS = 30;
const RECEIPT_CLEANUP_LIMIT = 100;
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const MUTATION_ID_PATTERN = /^[A-Za-z0-9._:-]{8,128}$/;
// Canonical temporal catalog: rollover (Tera) = 8 Giga; each next unit is radix 8.
const TERA_SECONDS = 1_111_272.935_625;
const GIGA_SECONDS = 138_909.116_953_125;
const MEGA_SECONDS = 17_363.639_619_140_625;

export class SyncService {
  constructor(private readonly database: Database) {}

  async stats(principal: Principal): Promise<SyncStats> {
    const result = await this.database.query<SyncStatsRow>(
      `SELECT
         GREATEST(
           COALESCE((
             SELECT max(sequence) FROM change_log WHERE user_id = $1
           ), 0),
           COALESCE((
             SELECT max(last_pruned_sequence)
             FROM sync_change_retention
             WHERE user_id = $1
           ), 0)
         ) AS high_water,
         (SELECT count(*) FROM records
          WHERE user_id = $1 AND visibility = 'public' AND deleted_at IS NULL)
           AS public_record_count,
         (SELECT count(*) FROM records
          WHERE user_id = $1 AND visibility = 'private' AND deleted_at IS NULL)
           AS private_record_count,
         (SELECT count(*) FROM records
          WHERE user_id = $1 AND deleted_at IS NULL
            AND event_at >= now() - make_interval(secs => $2)) AS past_tera_record_count,
         (SELECT count(*) FROM records
          WHERE user_id = $1 AND deleted_at IS NULL
            AND event_at >= now() - make_interval(secs => $3)) AS past_giga_record_count,
         (SELECT count(*) FROM records
          WHERE user_id = $1 AND deleted_at IS NULL
            AND event_at >= now() - make_interval(secs => $4)) AS past_mega_record_count,
         (SELECT count(*) FROM events
          WHERE user_id = $1 AND deleted_at IS NULL) AS event_count,
         (SELECT count(*) FROM tags
          WHERE user_id = $1 AND deleted_at IS NULL) AS tag_count,
         (SELECT count(*) FROM templates
          WHERE user_id = $1 AND deleted_at IS NULL AND retired_at IS NULL)
           AS template_count,
         (SELECT count(*) FROM media_objects
          WHERE user_id = $1 AND status = 'ready' AND deleted_at IS NULL)
           AS media_count,
         (SELECT COALESCE(sum(byte_size), 0) FROM media_objects
          WHERE user_id = $1 AND status = 'ready' AND deleted_at IS NULL)
           AS media_byte_length,
         (SELECT count(*) FROM media_objects
          WHERE user_id = $1 AND status = 'ready' AND deleted_at IS NULL
            AND content_type LIKE 'image/%') AS photo_media_count,
         (SELECT count(*) FROM media_objects
          WHERE user_id = $1 AND status = 'ready' AND deleted_at IS NULL
            AND content_type LIKE 'video/%') AS video_media_count,
         (SELECT count(*) FROM media_objects
          WHERE user_id = $1 AND status = 'ready' AND deleted_at IS NULL
            AND content_type LIKE 'audio/%') AS audio_media_count,
         (SELECT count(*) FROM media_objects media
          WHERE media.user_id = $1 AND media.visibility = 'public'
            AND media.status = 'ready' AND media.deleted_at IS NULL
            AND EXISTS (
              SELECT 1
              FROM record_media link
              JOIN records record ON record.id = link.record_id
              WHERE link.user_id = $1 AND link.media_id = media.id
                AND record.user_id = $1 AND record.visibility = 'public'
                AND record.deleted_at IS NULL
            )) AS restorable_media_count,
         (SELECT COALESCE(sum(media.byte_size), 0) FROM media_objects media
          WHERE media.user_id = $1 AND media.visibility = 'public'
            AND media.status = 'ready' AND media.deleted_at IS NULL
            AND EXISTS (
              SELECT 1
              FROM record_media link
              JOIN records record ON record.id = link.record_id
              WHERE link.user_id = $1 AND link.media_id = media.id
                AND record.user_id = $1 AND record.visibility = 'public'
                AND record.deleted_at IS NULL
            )) AS restorable_media_byte_length`,
      [principal.userId, TERA_SECONDS, GIGA_SECONDS, MEGA_SECONDS],
    );
    const row = result.rows[0];
    if (row === undefined) throw new Error("Synchronization statistics query returned no row");
    const publicRecords = syncStatNumber(row.public_record_count, "public record count");
    const privateRecords = syncStatNumber(row.private_record_count, "private record count");
    return {
      cursor: encodeSyncCursor(
        syncCursorSignature(principal.userId, SYNC_RESOURCE_TYPES),
        BigInt(row.high_water),
      ),
      records: {
        total: publicRecords + privateRecords,
        public: publicRecords,
        private: privateRecords,
        pastTera: syncStatNumber(row.past_tera_record_count, "past Tera record count"),
        pastGiga: syncStatNumber(row.past_giga_record_count, "past Giga record count"),
        pastMega: syncStatNumber(row.past_mega_record_count, "past Mega record count"),
      },
      events: { total: syncStatNumber(row.event_count, "event count") },
      tags: { total: syncStatNumber(row.tag_count, "tag count") },
      templates: { total: syncStatNumber(row.template_count, "template count") },
      media: {
        total: syncStatNumber(row.media_count, "media count"),
        byteLength: syncStatNumber(row.media_byte_length, "media byte length"),
        photo: syncStatNumber(row.photo_media_count, "photo media count"),
        video: syncStatNumber(row.video_media_count, "video media count"),
        audio: syncStatNumber(row.audio_media_count, "audio media count"),
        restorable: syncStatNumber(row.restorable_media_count, "restorable media count"),
        restorableByteLength: syncStatNumber(
          row.restorable_media_byte_length,
          "restorable media byte length",
        ),
      },
    };
  }

  async listChanges(
    principal: Principal,
    query: SyncChangeQuery,
  ): Promise<SyncChangePage> {
    const limit = parseChangeLimit(query.limit);
    const resourceTypes = normalizeResourceTypes(query.resourceTypes);
    const signature = syncCursorSignature(principal.userId, resourceTypes);
    const cursor = decodeSyncCursor(query.cursor, signature);

    return this.database.transaction(async (queryable) => {
      await queryable.query(
        "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY",
      );
      const metaResult = await queryable.query<SyncMetaRow>(
        `SELECT
           GREATEST(
             COALESCE((
               SELECT max(sequence)
               FROM change_log
               WHERE user_id = $1
             ), 0),
             COALESCE((
               SELECT max(last_pruned_sequence)
               FROM sync_change_retention
               WHERE user_id = $1 AND entity_type = ANY($2::text[])
             ), 0)
           ) AS high_water,
           COALESCE((
             SELECT max(last_pruned_sequence)
             FROM sync_change_retention
             WHERE user_id = $1 AND entity_type = ANY($2::text[])
           ), 0) AS last_pruned`,
        [principal.userId, resourceTypes],
      );
      const meta = metaResult.rows[0];
      if (meta === undefined) {
        throw new Error("Synchronization metadata query returned no row");
      }
      const highWater = BigInt(meta.high_water);
      const lastPruned = BigInt(meta.last_pruned);
      const afterSequence = cursor?.sequence ?? 0n;
      if (afterSequence > highWater) {
        throw invalidRequest(
          "The synchronization cursor is ahead of this user's change feed.",
          "invalid_cursor",
        );
      }
      if (cursor !== undefined && afterSequence < lastPruned) {
        throw new HttpProblem({
          status: 410,
          code: "cursor_expired",
          title: "Synchronization cursor expired",
          type: "https://api.exeligmos.app/problems/cursor-expired",
          detail:
            "Perform a full collection reconciliation before restarting the change feed.",
        });
      }

      const result = await queryable.query<ChangeRow>(
        `WITH latest AS (
           SELECT DISTINCT ON (entity_type, entity_id)
             sequence, changed_at, entity_type, entity_id, operation, revision
           FROM change_log
           WHERE user_id = $1
             AND sequence > $2::bigint
             AND entity_type = ANY($3::text[])
           ORDER BY entity_type, entity_id, sequence DESC
         )
         SELECT
           latest.sequence,
           latest.changed_at,
           latest.entity_type,
           latest.entity_id,
           CASE WHEN latest.entity_type = 'record'
             THEN changed_record.public_id
             ELSE latest.entity_id::text
           END AS external_entity_id,
           latest.operation,
           latest.revision
         FROM latest
         LEFT JOIN records changed_record
           ON latest.entity_type = 'record'
          AND changed_record.id = latest.entity_id
         WHERE latest.entity_type <> 'record'
            OR changed_record.id IS NOT NULL
         ORDER BY sequence ASC
         LIMIT $4`,
        [principal.userId, afterSequence.toString(), resourceTypes, limit + 1],
      );
      const hasMore = result.rows.length > limit;
      const rows = result.rows.slice(0, limit);
      const resources = await loadUpsertResources(
        queryable,
        principal.userId,
        rows,
      );
      const deletedAt = await loadDeletionTimes(
        queryable,
        principal.userId,
        rows,
      );
      const data = rows.map((row) =>
        mapChange(row, principal.userId, resources, deletedAt),
      );
      const last = rows.at(-1);
      const nextSequence =
        hasMore && last !== undefined ? BigInt(last.sequence) : highWater;
      return {
        data,
        nextCursor: encodeSyncCursor(signature, nextSequence),
        hasMore,
      };
    });
  }

  async applyBatch(
    principal: Principal,
    input: SyncBatchInput,
    idempotencyKey: string,
    requestId: string,
  ): Promise<MutationResponse<SyncBatchResponse>> {
    validateBatch(input);
    assertApiKeyDevice(principal, input.deviceId);
    try {
      return await executeIdempotentMutation(
        this.database,
        principal,
        "applySyncBatch",
        idempotencyKey,
        { input },
        async (queryable) => {
          await assertActiveOwnedDevice(
            queryable,
            principal.userId,
            input.deviceId,
          );
          const results: SyncMutationResult[] = [];
          for (const mutation of input.mutations) {
            const result = await applyIdempotentMutation(
              queryable,
              principal,
              input.deviceId,
              mutation,
              requestId,
            );
            results.push(result);
            if (input.atomic === true && result.status === "failed") {
              throw new HttpProblem({
                status: 409,
                code: "atomic_sync_batch_failed",
                title: "Conflict",
                type: "https://api.exeligmos.app/problems/atomic-sync-batch-failed",
                detail:
                  "An atomic synchronization mutation failed; the complete batch was rolled back.",
                extensions: {
                  failedMutationId: result.clientMutationId,
                  problem: result.problem,
                },
              });
            }
          }
          await writeBatchAudit(
            queryable,
            principal,
            input,
            results,
            requestId,
          );
          return { status: 200, headers: {}, body: { results } };
        },
      );
    } catch (error) {
      if (databaseErrorCode(error) !== undefined) {
        translateDatabaseError(error);
      }
      throw error;
    }
  }
}

async function applyIdempotentMutation(
  queryable: Queryable,
  principal: Principal,
  deviceId: string,
  mutation: SyncMutation,
  requestId: string,
): Promise<SyncMutationResult> {
  let reservation: ReceiptReservation;
  await queryable.query("SAVEPOINT sync_receipt_reservation");
  try {
    reservation = await reserveMutationReceipt(
      queryable,
      principal,
      deviceId,
      mutation,
    );
    await queryable.query("RELEASE SAVEPOINT sync_receipt_reservation");
  } catch (error) {
    await queryable.query("ROLLBACK TO SAVEPOINT sync_receipt_reservation");
    await queryable.query("RELEASE SAVEPOINT sync_receipt_reservation");
    const problem = knownProblem(error, requestId);
    if (problem === undefined) {
      throw error;
    }
    return failedResult(mutation.clientMutationId, problem);
  }
  if (reservation.replay !== undefined) {
    return reservation.replay;
  }

  await queryable.query("SAVEPOINT sync_mutation_work");
  let result: SyncMutationResult;
  try {
    result = await applyMutation(
      queryable,
      principal,
      deviceId,
      mutation,
      requestId,
    );
    await queryable.query("RELEASE SAVEPOINT sync_mutation_work");
  } catch (error) {
    await queryable.query("ROLLBACK TO SAVEPOINT sync_mutation_work");
    await queryable.query("RELEASE SAVEPOINT sync_mutation_work");
    const problem = knownProblem(error, requestId);
    if (problem === undefined) {
      throw error;
    }
    result = failedResult(mutation.clientMutationId, problem);
  }

  const stored = await queryable.query(
    `UPDATE sync_mutation_receipts
     SET result = $4::jsonb
     WHERE user_id = $1
       AND client_mutation_id = $2
       AND request_hash = $3
       AND result IS NULL`,
    [
      principal.userId,
      mutation.clientMutationId,
      reservation.requestHash,
      JSON.stringify(result),
    ],
  );
  if (stored.rowCount !== 1) {
    throw new Error("Synchronization mutation receipt could not be finalized");
  }
  return result;
}

async function reserveMutationReceipt(
  queryable: Queryable,
  principal: Principal,
  deviceId: string,
  mutation: SyncMutation,
): Promise<ReceiptReservation> {
  const requestHash = createHash("sha256")
    .update(canonicalJson({ deviceId, mutation }))
    .digest();
  await queryable.query(
    `DELETE FROM sync_mutation_receipts
     WHERE user_id = $1 AND client_mutation_id = $2 AND expires_at <= now()`,
    [principal.userId, mutation.clientMutationId],
  );
  const inserted = await queryable.query(
    `INSERT INTO sync_mutation_receipts (
       user_id, client_mutation_id, request_hash, actor_type, actor_id, expires_at
     ) VALUES (
       $1, $2, $3, $4, $5, now() + ($6::integer * interval '1 day')
     )
     ON CONFLICT (user_id, client_mutation_id) DO NOTHING
     RETURNING client_mutation_id`,
    [
      principal.userId,
      mutation.clientMutationId,
      requestHash,
      principal.kind,
      principal.actorId,
      RECEIPT_RETENTION_DAYS,
    ],
  );
  await cleanupExpiredReceipts(
    queryable,
    principal.userId,
    mutation.clientMutationId,
  );
  if (inserted.rowCount === 1) {
    return { requestHash };
  }

  const existing = await queryable.query<ReceiptRow>(
    `SELECT request_hash, result
     FROM sync_mutation_receipts
     WHERE user_id = $1 AND client_mutation_id = $2
     FOR UPDATE`,
    [principal.userId, mutation.clientMutationId],
  );
  const row = existing.rows[0];
  if (row === undefined || !row.request_hash.equals(requestHash)) {
    throw new HttpProblem({
      status: 409,
      code: "client_mutation_id_conflict",
      title: "Conflict",
      type: "https://api.exeligmos.app/problems/client-mutation-id-conflict",
      detail: "This clientMutationId was already used for another mutation.",
    });
  }
  if (!isMutationResult(row.result)) {
    throw new Error(
      "Synchronization mutation receipt is incomplete or malformed",
    );
  }
  return { requestHash, replay: row.result };
}

async function cleanupExpiredReceipts(
  queryable: Queryable,
  userId: string,
  clientMutationId: string,
): Promise<void> {
  await queryable.query(
    `WITH expired AS (
       SELECT user_id, client_mutation_id
       FROM sync_mutation_receipts
       WHERE expires_at <= now()
         AND (user_id, client_mutation_id) <> ($1::uuid, $2::text)
       ORDER BY expires_at
       LIMIT $3
       FOR UPDATE SKIP LOCKED
     )
     DELETE FROM sync_mutation_receipts AS stored
     USING expired
     WHERE stored.user_id = expired.user_id
       AND stored.client_mutation_id = expired.client_mutation_id`,
    [userId, clientMutationId, RECEIPT_CLEANUP_LIMIT],
  );
}

async function applyMutation(
  queryable: Queryable,
  principal: Principal,
  deviceId: string,
  mutation: SyncMutation,
  requestId: string,
): Promise<SyncMutationResult> {
  switch (mutation.kind) {
    case "upsertRecord":
      if (mutation.record.deviceId !== deviceId) {
        throw unprocessable(
          "record.deviceId must match the synchronization batch deviceId.",
          "sync_device_mismatch",
        );
      }
      return upsertRecord(queryable, principal, mutation, requestId);
    case "upsertEvent":
      if (mutation.event.deviceId !== deviceId) {
        throw unprocessable(
          "event.deviceId must match the synchronization batch deviceId.",
          "sync_device_mismatch",
        );
      }
      return upsertEvent(queryable, principal, mutation, requestId);
    case "upsertTag":
      return upsertTag(queryable, principal, mutation, requestId);
    case "upsertTemplate":
      return upsertTemplate(queryable, principal, mutation, requestId);
    case "delete":
      return deleteResource(queryable, principal, mutation, requestId);
  }
}

async function upsertRecord(
  queryable: Queryable,
  principal: Principal,
  mutation: UpsertRecordMutation,
  requestId: string,
): Promise<SyncMutationResult> {
  if (mutation.record.id === undefined || mutation.record.originId === undefined) {
    throw unprocessable(
      "Synchronized records require both id and originId.",
      "record_sync_identity_required",
    );
  }
  assertRecordPublicId(mutation.record.id);
  assertUuid(mutation.record.originId, "record originId");
  const state = await authoritativeRecordUpsertState(
    queryable,
    principal.userId,
    mutation.record.originId,
    mutation.record.id,
  );
  const response =
    state.kind === "create"
      ? await createRecordInTransaction(
          queryable,
          principal,
          mutation.record,
          requestId,
        )
      : await replaceRecordInTransaction(
          queryable,
          principal,
          state.publicId,
          mutation.record,
          state.etag,
          requestId,
          true,
        );
  return succeededResult(mutation.clientMutationId, "record", response.body);
}

/**
 * A sync record is a client-owned offline projection. If its ID already exists,
 * the latest submitted local document replaces the relay copy regardless of a
 * stale or missing client ETag. A local upsert also restores a relay tombstone.
 */
async function authoritativeRecordUpsertState(
  queryable: Queryable,
  userId: string,
  originId: string,
  publicId: string | undefined,
): Promise<
  | { readonly kind: "create" }
  | { readonly kind: "replace"; readonly publicId: string; readonly etag: string }
> {
  // An origin is the stable client identity. Serialize the absent-row case so
  // two devices cannot race to assign different aliases to the same origin.
  await queryable.query(
    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
    [`record-origin:${userId}:${originId}`],
  );
  const result = await queryable.query<ResourceStateRow>(
    `SELECT public_id, revision, deleted_at
     FROM records
     WHERE user_id = $1 AND id = $2
     FOR UPDATE`,
    [userId, originId],
  );
  const row = result.rows[0];
  if (row === undefined) return { kind: "create" };
  if (row.public_id === undefined) {
    throw new Error("Stored record has no public identifier");
  }
  if (publicId !== undefined && row.public_id !== publicId) {
    throw unprocessable(
      "The submitted id does not match the record originId's immutable id.",
      "record_id_mismatch",
    );
  }

  const revision = Number(row.revision);
  return {
    kind: "replace",
    publicId: row.public_id,
    etag: syncResourceEtag("record", row.public_id, revision),
  };
}

async function upsertEvent(
  queryable: Queryable,
  principal: Principal,
  mutation: UpsertEventMutation,
  requestId: string,
): Promise<SyncMutationResult> {
  const state = await upsertState(
    queryable,
    principal.userId,
    "event",
    mutation.event.id,
    mutation.ifMatch,
  );
  const response =
    state === "create"
      ? await createEventInTransaction(
          queryable,
          principal,
          mutation.event,
          requestId,
        )
      : await replaceEventInTransaction(
          queryable,
          principal,
          requiredResourceId(mutation.event.id),
          mutation.event,
          requiredIfMatch(mutation.ifMatch),
          requestId,
        );
  return succeededResult(mutation.clientMutationId, "event", response.body);
}

async function upsertTag(
  queryable: Queryable,
  principal: Principal,
  mutation: UpsertTagMutation,
  requestId: string,
): Promise<SyncMutationResult> {
  const state = await upsertState(
    queryable,
    principal.userId,
    "tag",
    mutation.tag.id,
    mutation.ifMatch,
  );
  const resource =
    state === "create"
      ? await createTagInTransaction(
          queryable,
          principal,
          mutation.tag,
          requestId,
        )
      : await replaceTagInTransaction(
          queryable,
          principal,
          requiredResourceId(mutation.tag.id),
          mutation.tag,
          requiredIfMatch(mutation.ifMatch),
          requestId,
        );
  return succeededResult(
    mutation.clientMutationId,
    "tag",
    resource,
    tagEtag(resource.id, resource.revision),
  );
}

async function upsertTemplate(
  queryable: Queryable,
  principal: Principal,
  mutation: UpsertTemplateMutation,
  requestId: string,
): Promise<SyncMutationResult> {
  const state = await upsertState(
    queryable,
    principal.userId,
    "template",
    mutation.template.id,
    mutation.ifMatch,
  );
  const resource =
    state === "create"
      ? await createTemplateInTransaction(
          queryable,
          principal,
          mutation.template,
          requestId,
        )
      : await replaceTemplateInTransaction(
          queryable,
          principal,
          requiredResourceId(mutation.template.id),
          mutation.template,
          requiredIfMatch(mutation.ifMatch),
          requestId,
        );
  return succeededResult(
    mutation.clientMutationId,
    "template",
    resource,
    templateEtag(resource.id, resource.revision),
  );
}

async function deleteResource(
  queryable: Queryable,
  principal: Principal,
  mutation: DeleteSyncMutation,
  requestId: string,
): Promise<SyncMutationResult> {
  switch (mutation.resourceType) {
    case "record":
      await deleteRecordInTransaction(
        queryable,
        principal,
        mutation.resourceId,
        mutation.ifMatch,
        requestId,
      );
      break;
    case "event":
      await deleteEventInTransaction(
        queryable,
        principal,
        mutation.resourceId,
        mutation.ifMatch,
        requestId,
      );
      break;
    case "tag":
      await deleteTagInTransaction(
        queryable,
        principal,
        mutation.resourceId,
        mutation.ifMatch,
        requestId,
      );
      break;
    case "template":
      await retireTemplateInTransaction(
        queryable,
        principal,
        mutation.resourceId,
        mutation.ifMatch,
        requestId,
      );
      break;
  }
  const revision = await loadDeletedRevision(
    queryable,
    principal.userId,
    mutation.resourceType,
    mutation.resourceId,
  );
  return {
    clientMutationId: mutation.clientMutationId,
    status: "succeeded",
    resourceType: mutation.resourceType,
    resourceId: mutation.resourceId,
    revision,
    etag: syncResourceEtag(
      mutation.resourceType,
      mutation.resourceId,
      revision,
    ),
  };
}

async function upsertState(
  queryable: Queryable,
  userId: string,
  resourceType: SyncMutationResourceType,
  resourceId: string | undefined,
  ifMatch: string | undefined,
): Promise<"create" | "replace"> {
  if (resourceId === undefined) {
    if (ifMatch !== undefined) {
      throw unprocessable(
        "ifMatch cannot be used when the upsert has no resource id.",
        "if_match_without_resource_id",
      );
    }
    return "create";
  }
  assertUuid(resourceId, "resource id");
  const table = tableForMutationResource(resourceType);
  const result = await queryable.query<ResourceStateRow>(
    `SELECT revision, deleted_at FROM ${table} WHERE user_id = $1 AND id = $2`,
    [userId, resourceId],
  );
  const row = result.rows[0];
  if (row === undefined) {
    if (ifMatch !== undefined) {
      throw new HttpProblem({
        status: 409,
        code: "upsert_target_missing",
        title: "Conflict",
        type: "https://api.exeligmos.app/problems/upsert-target-missing",
        detail: "The resource named by ifMatch is no longer available.",
      });
    }
    return "create";
  }
  if (row.deleted_at !== null) {
    throw new HttpProblem({
      status: 409,
      code: "resource_deleted",
      title: "Conflict",
      type: "https://api.exeligmos.app/problems/resource-deleted",
      detail:
        "A soft-deleted resource cannot be resurrected by synchronization upsert.",
    });
  }
  if (ifMatch === undefined) {
    throw unprocessable(
      "ifMatch is required when an upsert replaces an existing resource.",
      "if_match_required",
    );
  }
  return "replace";
}

async function loadDeletedRevision(
  queryable: Queryable,
  userId: string,
  resourceType: SyncMutationResourceType,
  resourceId: string,
): Promise<number> {
  const idColumn = resourceType === "record" ? "public_id" : "id";
  const result = await queryable.query<RevisionRow>(
    `SELECT revision
     FROM ${tableForMutationResource(resourceType)}
     WHERE user_id = $1 AND ${idColumn} = $2 AND deleted_at IS NOT NULL`,
    [userId, resourceId],
  );
  const row = result.rows[0];
  if (row === undefined) {
    throw new Error("Deleted synchronization resource could not be reloaded");
  }
  return Number(row.revision);
}

function tableForMutationResource(
  resourceType: SyncMutationResourceType,
): string {
  switch (resourceType) {
    case "record":
      return "records";
    case "event":
      return "events";
    case "tag":
      return "tags";
    case "template":
      return "templates";
  }
}

function succeededResult(
  clientMutationId: string,
  resourceType: SyncMutationResourceType,
  resource: VersionedResource,
  etag = syncResourceEtag(resourceType, resource.id, resource.revision),
): SyncMutationResult {
  return {
    clientMutationId,
    status: "succeeded",
    resourceType,
    resourceId: resource.id,
    revision: resource.revision,
    etag,
  };
}

function failedResult(
  clientMutationId: string,
  problem: SyncProblemDocument,
): SyncMutationResult {
  return { clientMutationId, status: "failed", problem };
}

async function loadUpsertResources(
  queryable: Queryable,
  userId: string,
  rows: readonly ChangeRow[],
): Promise<ReadonlyMap<string, unknown>> {
  const ids = groupChangeIds(rows, "upsert");
  // Queryable may be a single transaction-bound pg client. Keep reads
  // sequential; node-postgres 9 will reject concurrent client.query calls.
  const records = await loadRecordResourcesForSync(
    queryable,
    userId,
    ids.record,
  );
  const events = await loadEventResourcesForSync(queryable, userId, ids.event);
  const tags = await loadActiveTagResources(queryable, userId, ids.tag);
  const templates = await loadActiveTemplateResources(
    queryable,
    userId,
    ids.template,
  );
  const media = await loadMediaResourcesForSync(queryable, userId, ids.media);
  const devices = await loadDeviceResources(queryable, userId, ids.device);
  const users = await loadUserResources(queryable, userId, ids.user);
  const subscriptions = await loadSubscriptionResourcesForSync(
    queryable,
    userId,
    ids.subscription,
  );
  return new Map([
    ...prefixedEntries("record", records),
    ...prefixedEntries("event", events),
    ...prefixedEntries("tag", tags),
    ...prefixedEntries("template", templates),
    ...prefixedEntries("media", media),
    ...prefixedEntries("device", devices),
    ...prefixedEntries("user", users),
    ...prefixedEntries("subscription", subscriptions),
  ]);
}

async function loadDeviceResources(
  queryable: Queryable,
  userId: string,
  ids: readonly string[],
): Promise<ReadonlyMap<string, unknown>> {
  if (ids.length === 0) {
    return new Map();
  }
  const result = await queryable.query<DeviceRow>(
    `SELECT id, user_id, name, kind, platform, app_version, metadata, revision,
            registered_at, updated_at, last_seen_at, revoked_at
     FROM devices
     WHERE user_id = $1 AND id = ANY($2::uuid[]) AND revoked_at IS NULL`,
    [userId, ids],
  );
  return new Map(
    result.rows.map((row) => [
      row.id,
      {
        id: row.id,
        userId: row.user_id,
        name: row.name,
        kind: row.kind,
        ...(row.platform === null ? {} : { platform: row.platform }),
        ...(row.app_version === null ? {} : { appVersion: row.app_version }),
        metadata: row.metadata,
        revision: Number(row.revision),
        registeredAt: isoDate(row.registered_at),
        updatedAt: isoDate(row.updated_at),
        lastSeenAt:
          row.last_seen_at === null ? null : isoDate(row.last_seen_at),
        revokedAt: null,
      },
    ]),
  );
}

async function loadUserResources(
  queryable: Queryable,
  userId: string,
  ids: readonly string[],
): Promise<ReadonlyMap<string, unknown>> {
  if (!ids.includes(userId)) {
    return new Map();
  }
  const result = await queryable.query<UserRow>(
    `SELECT id, login, display_name, saros_anchor, created_at, updated_at
     FROM users
     WHERE id = $1`,
    [userId],
  );
  const row = result.rows[0];
  return row === undefined
    ? new Map()
    : new Map([
        [
          row.id,
          {
            id: row.id,
            login: row.login,
            displayName: row.display_name,
            sarosAnchor: row.saros_anchor,
            createdAt: isoDate(row.created_at),
            updatedAt: isoDate(row.updated_at),
          },
        ],
      ]);
}

async function loadDeletionTimes(
  queryable: Queryable,
  userId: string,
  rows: readonly ChangeRow[],
): Promise<ReadonlyMap<string, string>> {
  const ids = rows
    .filter((row) => row.operation === "delete")
    .map((row) => row.entity_id);
  if (ids.length === 0) {
    return new Map();
  }
  const result = await queryable.query<DeletedAtRow>(
    `SELECT 'record'::text AS entity_type, id AS entity_id, deleted_at
       FROM records WHERE user_id = $1 AND id = ANY($2::uuid[]) AND deleted_at IS NOT NULL
     UNION ALL
     SELECT 'event', id, deleted_at
       FROM events WHERE user_id = $1 AND id = ANY($2::uuid[]) AND deleted_at IS NOT NULL
     UNION ALL
     SELECT 'tag', id, deleted_at
       FROM tags WHERE user_id = $1 AND id = ANY($2::uuid[]) AND deleted_at IS NOT NULL
     UNION ALL
     SELECT 'template', id, COALESCE(deleted_at, retired_at)
       FROM templates WHERE user_id = $1 AND id = ANY($2::uuid[])
         AND (deleted_at IS NOT NULL OR retired_at IS NOT NULL)
     UNION ALL
     SELECT 'device', id, revoked_at
       FROM devices WHERE user_id = $1 AND id = ANY($2::uuid[]) AND revoked_at IS NOT NULL
     UNION ALL
     SELECT 'media', id, deleted_at
       FROM media_objects WHERE user_id = $1 AND id = ANY($2::uuid[]) AND deleted_at IS NOT NULL
     UNION ALL
     SELECT 'subscription', id, deleted_at
       FROM subscriptions WHERE user_id = $1 AND id = ANY($2::uuid[]) AND deleted_at IS NOT NULL`,
    [userId, ids],
  );
  return new Map(
    result.rows.map((row) => [
      resourceKey(row.entity_type, row.entity_id),
      isoDate(row.deleted_at),
    ]),
  );
}

function mapChange(
  row: ChangeRow,
  userId: string,
  resources: ReadonlyMap<string, unknown>,
  deletedAt: ReadonlyMap<string, string>,
): SyncChange {
  const revision = Number(row.revision);
  const base = {
    sequence: safeSequence(row.sequence),
    changedAt: isoDate(row.changed_at),
    resourceType: row.entity_type,
    operation: row.operation,
    resourceId: row.external_entity_id,
    revision,
    etag: syncResourceEtag(row.entity_type, row.external_entity_id, revision),
  } as const;
  const key = resourceKey(row.entity_type, row.entity_id);
  if (row.operation === "delete") {
    return {
      ...base,
      tombstone: {
        id: row.external_entity_id,
        userId,
        resourceType: row.entity_type,
        revision,
        deletedAt: deletedAt.get(key) ?? isoDate(row.changed_at),
      },
    };
  }
  const resource = resources.get(key);
  if (resource === undefined) {
    throw new Error(
      `Active ${row.entity_type} synchronization resource is missing`,
    );
  }
  return { ...base, resource };
}

function groupChangeIds(
  rows: readonly ChangeRow[],
  operation: ChangeRow["operation"],
): Record<SyncResourceType, readonly string[]> {
  const grouped: Record<SyncResourceType, string[]> = {
    record: [],
    event: [],
    tag: [],
    template: [],
    device: [],
    media: [],
    user: [],
    subscription: [],
  };
  for (const row of rows) {
    if (row.operation === operation) {
      grouped[row.entity_type].push(row.entity_id);
    }
  }
  return grouped;
}

function prefixedEntries(
  resourceType: SyncResourceType,
  resources: ReadonlyMap<string, unknown>,
): Array<[string, unknown]> {
  return [...resources].map(([id, resource]) => [
    resourceKey(resourceType, id),
    resource,
  ]);
}

function resourceKey(
  resourceType: SyncResourceType,
  resourceId: string,
): string {
  return `${resourceType}:${resourceId}`;
}

function syncResourceEtag(
  resourceType: SyncResourceType,
  resourceId: string,
  revision: number,
): string {
  return `"${resourceType}-${resourceId}-r${revision}"`;
}

function validateBatch(input: SyncBatchInput): void {
  assertUuid(input.deviceId, "deviceId");
  if (
    !Array.isArray(input.mutations) ||
    input.mutations.length < 1 ||
    input.mutations.length > MAX_BATCH_MUTATIONS
  ) {
    throw invalidRequest(
      `mutations must contain between 1 and ${MAX_BATCH_MUTATIONS} items.`,
    );
  }
  if (input.atomic !== undefined && typeof input.atomic !== "boolean") {
    throw invalidRequest("atomic must be a boolean.");
  }
  const seen = new Set<string>();
  for (const mutation of input.mutations) {
    if (!MUTATION_ID_PATTERN.test(mutation.clientMutationId)) {
      throw invalidRequest(
        "Every clientMutationId must contain 8 to 128 letters, digits, period, underscore, colon, or hyphen.",
      );
    }
    if (seen.has(mutation.clientMutationId)) {
      throw invalidRequest(
        "clientMutationId values must be unique within a batch.",
      );
    }
    seen.add(mutation.clientMutationId);
  }
}

function parseChangeLimit(value: unknown): number {
  if (value === undefined) {
    return DEFAULT_CHANGE_LIMIT;
  }
  const parsed = typeof value === "number" ? value : Number(value);
  if (!Number.isInteger(parsed) || parsed < 1 || parsed > MAX_CHANGE_LIMIT) {
    throw invalidRequest(
      `limit must be an integer between 1 and ${MAX_CHANGE_LIMIT}.`,
    );
  }
  return parsed;
}

function normalizeResourceTypes(
  values: readonly string[] | undefined,
): readonly SyncResourceType[] {
  if (values === undefined || values.length === 0) {
    return SYNC_RESOURCE_TYPES;
  }
  const selected = new Set<SyncResourceType>();
  for (const value of values) {
    if (!isSyncResourceType(value)) {
      throw invalidRequest(
        `Unsupported synchronization resourceType: ${value}.`,
      );
    }
    selected.add(value);
  }
  return SYNC_RESOURCE_TYPES.filter((value) => selected.has(value));
}

function isSyncResourceType(value: string): value is SyncResourceType {
  return (SYNC_RESOURCE_TYPES as readonly string[]).includes(value);
}

function syncCursorSignature(
  userId: string,
  resourceTypes: readonly SyncResourceType[],
): string {
  return createHash("sha256")
    .update(canonicalJson({ userId, resourceTypes }))
    .digest("base64url");
}

export function encodeSyncCursor(signature: string, sequence: bigint): string {
  return Buffer.from(
    JSON.stringify({
      v: 1,
      kind: SYNC_CURSOR_KIND,
      signature,
      sequence: sequence.toString(),
    }),
    "utf8",
  ).toString("base64url");
}

export function decodeSyncCursor(
  value: string | undefined,
  expectedSignature: string,
): { readonly sequence: bigint } | undefined {
  if (value === undefined) {
    return undefined;
  }
  try {
    if (value.length > 2_048 || !/^[A-Za-z0-9_-]+$/.test(value)) {
      throw new Error("Malformed cursor encoding");
    }
    const decoded: unknown = JSON.parse(
      Buffer.from(value, "base64url").toString("utf8"),
    );
    if (
      decoded === null ||
      typeof decoded !== "object" ||
      Array.isArray(decoded)
    ) {
      throw new Error("Malformed cursor payload");
    }
    const candidate = decoded as Record<string, unknown>;
    if (
      Object.keys(candidate).length !== 4 ||
      candidate.v !== 1 ||
      candidate.kind !== SYNC_CURSOR_KIND ||
      candidate.signature !== expectedSignature ||
      typeof candidate.sequence !== "string" ||
      !/^(?:0|[1-9][0-9]{0,18})$/.test(candidate.sequence)
    ) {
      throw new Error("Cursor does not belong to this feed");
    }
    const sequence = BigInt(candidate.sequence);
    if (sequence > 9_223_372_036_854_775_807n) {
      throw new Error("Cursor sequence is outside bigint range");
    }
    return { sequence };
  } catch {
    throw invalidRequest(
      "The cursor is malformed or does not belong to this synchronization query.",
      "invalid_cursor",
    );
  }
}

function safeSequence(value: string | number): number {
  const sequence = Number(value);
  if (!Number.isSafeInteger(sequence) || sequence < 1) {
    throw new Error(
      "Synchronization sequence exceeds JSON's exact integer range",
    );
  }
  return sequence;
}

function knownProblem(
  error: unknown,
  requestId: string,
): SyncProblemDocument | undefined {
  let candidate = error;
  const errorCode = databaseErrorCode(error);
  if (errorCode === "22P05" || errorCode === "22021") {
    candidate = new HttpProblem({
      status: 422,
      code: "invalid_text",
      title: "Unprocessable Content",
      type: "https://api.exeligmos.app/problems/invalid-text",
      detail: "The mutation contains text that PostgreSQL cannot represent.",
    });
  } else if (
    errorCode === "22P02" &&
    error instanceof Error &&
    "routine" in error &&
    String((error as Error & { readonly routine: unknown }).routine).startsWith(
      "json_",
    )
  ) {
    candidate = new HttpProblem({
      status: 422,
      code: "invalid_json",
      title: "Unprocessable Content",
      type: "https://api.exeligmos.app/problems/invalid-json",
      detail:
        "JSON strings and object keys must contain PostgreSQL-compatible Unicode text.",
    });
  } else if (errorCode !== undefined) {
    try {
      translateDatabaseError(error);
    } catch (translated) {
      candidate = translated;
    }
  }
  if (!(candidate instanceof HttpProblem)) {
    return undefined;
  }
  const code = candidate.code ?? defaultProblemCode(candidate.status);
  return {
    ...candidate.extensions,
    type: candidate.type,
    title: candidate.title,
    status: candidate.status,
    code,
    detail: candidate.message.slice(0, 4_000),
    instance: "/v1/sync/batches",
    requestId,
  };
}

function defaultProblemCode(status: number): string {
  switch (status) {
    case 400:
      return "bad_request";
    case 404:
      return "not_found";
    case 409:
      return "conflict";
    case 412:
      return "precondition_failed";
    case 422:
      return "unprocessable_content";
    default:
      return status >= 500 ? "internal_error" : "http_error";
  }
}

function isMutationResult(value: unknown): value is SyncMutationResult {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    return false;
  }
  const candidate = value as Partial<SyncMutationResult>;
  return (
    typeof candidate.clientMutationId === "string" &&
    (candidate.status === "succeeded" || candidate.status === "failed") &&
    (candidate.status !== "failed" || candidate.problem !== undefined)
  );
}

function requiredResourceId(value: string | undefined): string {
  if (value === undefined) {
    throw new Error("Existing sync upsert has no resource id");
  }
  return value;
}

function requiredIfMatch(value: string | undefined): string {
  if (value === undefined) {
    throw new Error("Existing sync upsert has no If-Match value");
  }
  return value;
}

function syncStatNumber(value: string | number, name: string): number {
  const parsed = typeof value === "number" ? value : Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 0) {
    throw new Error(`Synchronization ${name} is outside the JSON safe-integer range`);
  }
  return parsed;
}

function assertUuid(value: string, name: string): void {
  if (!UUID_PATTERN.test(value)) {
    throw invalidRequest(`${name} must be a UUID.`);
  }
}

async function writeBatchAudit(
  queryable: Queryable,
  principal: Principal,
  input: SyncBatchInput,
  results: readonly SyncMutationResult[],
  requestId: string,
): Promise<void> {
  const succeeded = results.filter(
    (result) => result.status === "succeeded",
  ).length;
  await queryable.query(
    `INSERT INTO audit_log (
       user_id, actor_type, actor_id, action, entity_type, entity_id,
       request_id, metadata
     ) VALUES ($1, $2, $3, 'sync.batch.apply', 'device', $4, $5, $6::jsonb)`,
    [
      principal.userId,
      principal.kind,
      principal.actorId,
      input.deviceId,
      requestId,
      JSON.stringify({
        atomic: input.atomic ?? false,
        total: results.length,
        succeeded,
        failed: results.length - succeeded,
      }),
    ],
  );
}
