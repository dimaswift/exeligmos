import type { QueryResultRow } from "pg";

import type { Principal } from "../auth/principal.js";
import type { Database, Queryable } from "../db/database.js";
import { HttpProblem } from "../http/problem.js";
import {
  assertSerializedJsonSize,
  RESOURCE_METADATA_MAX_BYTES,
} from "./limits.js";
import {
  assertActiveOwnedDevice,
  assertApiKeyDevice,
  cursorSignature,
  databaseErrorCode,
  decodeCursor,
  encodeCursor,
  executeIdempotentMutation,
  invalidRequest,
  isoDate,
  type JsonObject,
  type MutationResponse,
  parsePageLimit,
  requireMatchingEtag,
  resourceEtag,
  translateDatabaseError,
  unprocessable,
} from "./shared.js";

export type IngestionJobStatus =
  "queued" | "processing" | "completed" | "failed";
export type IngestionItemStatus =
  "queued" | "processing" | "completed" | "failed";
export type IngestionItemKind = "photo" | "video" | "audio";

export interface IngestionItemDeclaration {
  readonly sourceKey: string;
  readonly groupKey: string;
  readonly relativePath: string;
  readonly kind: IngestionItemKind;
  readonly capturedAt: string;
  readonly byteLength: number;
  readonly contentSha256: string;
}

export interface CreateIngestionJobInput {
  readonly deviceId: string;
  readonly source: JsonObject;
  readonly config: JsonObject;
  readonly items: readonly IngestionItemDeclaration[];
}

export interface UpdateIngestionItemInput {
  readonly status: Exclude<IngestionItemStatus, "queued">;
  readonly stage?: string;
  readonly outputMode?: string;
  readonly uploadId?: string;
  readonly mediaId?: string;
  /** Public five-character record identifier. */
  readonly recordId?: string;
  readonly error?: string;
}

export interface IngestionJobListQuery {
  readonly cursor?: string;
  readonly limit?: unknown;
  readonly status?: IngestionJobStatus;
  readonly activity?: "active";
  readonly deviceId?: string;
}

export interface IngestionJobItemResource {
  readonly id: string;
  readonly sourceKey: string;
  readonly groupKey: string;
  readonly relativePath: string;
  readonly kind: IngestionItemKind;
  readonly capturedAt: string;
  readonly byteLength: number;
  readonly contentSha256: string;
  readonly status: IngestionItemStatus;
  readonly stage: string;
  readonly outputMode?: string;
  readonly uploadId?: string;
  readonly mediaId?: string;
  readonly recordId?: string;
  readonly error?: string;
  readonly createdAt: string;
  readonly updatedAt: string;
}

export interface IngestionJobStateResource {
  readonly id: string;
  readonly userId: string;
  readonly deviceId: string;
  readonly source: JsonObject;
  readonly config: JsonObject;
  readonly status: IngestionJobStatus;
  readonly totalItems: number;
  readonly processedItems: number;
  readonly failedItems: number;
  readonly remainingItems: number;
  readonly totalRecords: number;
  readonly processedRecords: number;
  readonly failedRecords: number;
  readonly remainingRecords: number;
  readonly currentItem: IngestionJobItemResource | null;
  readonly revision: number;
  readonly createdAt: string;
  readonly updatedAt: string;
  readonly startedAt?: string;
  readonly finishedAt?: string;
}

export interface IngestionJobResource extends IngestionJobStateResource {
  readonly activity: "active" | "idle";
}

export interface IngestionJobDetailResource extends IngestionJobStateResource {
  readonly items: readonly IngestionJobItemResource[];
}

export interface IngestionJobItemMutationResource extends IngestionJobStateResource {
  readonly item: IngestionJobItemResource;
}

export interface SkippedIngestionItem {
  readonly sourceKey: string;
  readonly existingJobId: string;
  readonly existingItemId: string;
  readonly status: IngestionItemStatus;
}

export interface CreatedIngestionJobResource extends IngestionJobDetailResource {
  readonly skippedItems: readonly SkippedIngestionItem[];
}

export interface IngestionJobPage {
  readonly data: readonly IngestionJobResource[];
  readonly hasMore: boolean;
  readonly nextCursor?: string;
}

interface JobRow extends QueryResultRow {
  readonly id: string;
  readonly user_id: string;
  readonly device_id: string;
  readonly source: JsonObject;
  readonly config: JsonObject;
  readonly status: IngestionJobStatus;
  readonly total_items: number;
  readonly processed_items: number;
  readonly failed_items: number;
  readonly total_records: number;
  readonly processed_records: number;
  readonly failed_records: number;
  readonly revision: string | number;
  readonly created_at: Date | string;
  readonly updated_at: Date | string;
  readonly started_at: Date | string | null;
  readonly finished_at: Date | string | null;
}

interface JobItemRow extends QueryResultRow {
  readonly id: string;
  readonly user_id: string;
  readonly device_id: string;
  readonly job_id: string;
  readonly ordinal: number;
  readonly source_key: string;
  readonly group_key: string;
  readonly relative_path: string;
  readonly kind: IngestionItemKind;
  readonly captured_at: Date | string;
  readonly byte_length: string | number;
  readonly content_sha256: Buffer;
  readonly status: IngestionItemStatus;
  readonly stage: string;
  readonly output_mode: string | null;
  readonly upload_id: string | null;
  readonly media_id: string | null;
  readonly record_id: string | null;
  readonly record_public_id: string | null;
  readonly error: string | null;
  readonly created_at: Date | string;
  readonly updated_at: Date | string;
}

interface ExistingItemRow extends QueryResultRow {
  readonly id: string;
  readonly job_id: string;
  readonly status: IngestionItemStatus;
}

interface IdRow extends QueryResultRow {
  readonly id: string;
}

type JobLock = "none" | "share" | "update";

const JOB_COLUMNS = `
  j.id,
  j.user_id,
  j.device_id,
  j.source,
  j.config,
  j.status,
  j.total_items,
  j.processed_items,
  j.failed_items,
  j.total_records,
  j.processed_records,
  j.failed_records,
  j.revision,
  j.created_at,
  j.updated_at,
  j.started_at,
  j.finished_at
`;

const ITEM_COLUMNS = `
  i.id,
  i.user_id,
  i.device_id,
  i.job_id,
  i.ordinal,
  i.source_key,
  i.group_key,
  i.relative_path,
  i.kind,
  i.captured_at,
  i.byte_length,
  i.content_sha256,
  i.status,
  i.stage,
  i.output_mode,
  i.upload_id,
  i.media_id,
  i.record_id,
  record.public_id AS record_public_id,
  i.error,
  i.created_at,
  i.updated_at
`;

export class IngestionJobService {
  constructor(private readonly database: Database) {}

  async list(
    principal: Principal,
    query: IngestionJobListQuery,
  ): Promise<IngestionJobPage> {
    const limit = parsePageLimit(query.limit);
    if (query.status !== undefined && !JOB_STATUSES.has(query.status)) {
      throw invalidRequest(
        "status must be queued, processing, completed, or failed.",
      );
    }
    if (query.activity !== undefined && query.activity !== "active") {
      throw invalidRequest("activity must be active.");
    }
    if (query.deviceId !== undefined && !isUuid(query.deviceId)) {
      throw invalidRequest("deviceId must be a UUID.");
    }

    const deviceId = effectiveReadDevice(principal, query.deviceId);
    const signature = cursorSignature({
      userId: principal.userId,
      status: query.status,
      activity: query.activity,
      deviceId,
    });
    const cursor = decodeCursor(query.cursor, "ingestion-jobs", signature);
    const values: unknown[] = [principal.userId];
    const where = ["j.user_id = $1"];
    if (query.status !== undefined) {
      values.push(query.status);
      where.push(`j.status = $${values.length}`);
    }
    if (query.activity === "active") {
      values.push(INGESTION_JOB_ACTIVITY_LEASE_MS);
      where.push(
        `j.status = 'processing'
         AND EXISTS (
           SELECT 1
           FROM ingestion_job_items active_item
           WHERE active_item.user_id = j.user_id
             AND active_item.job_id = j.id
             AND active_item.status = 'processing'
             AND active_item.updated_at >
               clock_timestamp() - ($${values.length}::double precision * interval '1 millisecond')
         )`,
      );
    }
    if (deviceId !== undefined) {
      values.push(deviceId);
      where.push(`j.device_id = $${values.length}::uuid`);
    }
    if (cursor !== undefined) {
      values.push(cursor.sort, cursor.id);
      where.push(
        `(j.created_at, j.id) < ($${values.length - 1}::timestamptz, $${values.length}::uuid)`,
      );
    }
    values.push(limit + 1);
    return this.database.transaction(async (queryable) => {
      const result = await queryable.query<JobRow>(
        `SELECT ${JOB_COLUMNS}
         FROM ingestion_jobs j
         WHERE ${where.join(" AND ")}
         ORDER BY j.created_at DESC, j.id DESC
         LIMIT $${values.length}
         FOR SHARE OF j`,
        values,
      );
      const hasMore = result.rows.length > limit;
      const rows = result.rows.slice(0, limit);
      const currentItems = await loadCurrentItems(
        queryable,
        principal.userId,
        rows.map((row) => row.id),
      );
      const last = rows.at(-1);
      return {
        data: rows.map((row) =>
          mapJobRow(
            row,
            currentItems.get(row.id) ?? null,
            query.activity === "active",
          ),
        ),
        hasMore,
        ...(hasMore && last !== undefined
          ? {
              nextCursor: encodeCursor(
                "ingestion-jobs",
                signature,
                isoDate(last.created_at),
                last.id,
              ),
            }
          : {}),
      };
    });
  }

  async get(
    principal: Principal,
    jobId: string,
  ): Promise<IngestionJobDetailResource> {
    assertUuid(jobId, "jobId");
    return this.database.transaction(async (queryable) => {
      const row = await loadJob(queryable, principal, jobId, "share");
      if (row === undefined) {
        throw jobNotFound();
      }
      return loadJobDetail(queryable, row);
    });
  }

  async create(
    principal: Principal,
    input: CreateIngestionJobInput,
    idempotencyKey: string,
    requestId: string,
  ): Promise<MutationResponse<CreatedIngestionJobResource>> {
    const validated = validateCreateIngestionJobInput(input);
    assertApiKeyDevice(principal, validated.deviceId);

    return this.translate(() =>
      executeIdempotentMutation(
        this.database,
        principal,
        "createIngestionJob",
        idempotencyKey,
        { input: validated },
        async (queryable) => {
          await assertActiveOwnedDevice(
            queryable,
            principal.userId,
            validated.deviceId,
          );
          const inserted = await queryable.query<JobRow>(
            `INSERT INTO ingestion_jobs (
               user_id, device_id, source, config
             ) VALUES ($1, $2, $3::jsonb, $4::jsonb)
             RETURNING ${JOB_COLUMNS.replaceAll("j.", "")}`,
            [
              principal.userId,
              validated.deviceId,
              JSON.stringify(validated.source),
              JSON.stringify(validated.config),
            ],
          );
          const initial = inserted.rows[0];
          if (initial === undefined) {
            throw new Error("Created ingestion job did not return a row");
          }

          const skippedItems: SkippedIngestionItem[] = [];
          for (const [ordinal, item] of validated.items.entries()) {
            const accepted = await queryable.query<IdRow>(
              `INSERT INTO ingestion_job_items (
                 user_id, device_id, job_id, ordinal, source_key, group_key,
                 relative_path, kind, captured_at, byte_length, content_sha256
               ) VALUES (
                 $1, $2, $3, $4, $5, $6, $7, $8, $9::timestamptz, $10,
                 decode($11, 'hex')
               )
               ON CONFLICT (user_id, device_id, source_key) DO NOTHING
               RETURNING id`,
              [
                principal.userId,
                validated.deviceId,
                initial.id,
                ordinal,
                item.sourceKey,
                item.groupKey,
                item.relativePath,
                item.kind,
                item.capturedAt,
                item.byteLength,
                item.contentSha256,
              ],
            );
            if (accepted.rowCount === 0) {
              const existing = await queryable.query<ExistingItemRow>(
                `SELECT id, job_id, status
                 FROM ingestion_job_items
                 WHERE user_id = $1 AND device_id = $2 AND source_key = $3`,
                [principal.userId, validated.deviceId, item.sourceKey],
              );
              const row = existing.rows[0];
              if (row === undefined) {
                throw new Error("Skipped ingestion item could not be reloaded");
              }
              skippedItems.push({
                sourceKey: item.sourceKey,
                existingJobId: row.job_id,
                existingItemId: row.id,
                status: row.status,
              });
            }
          }

          await recomputeJob(queryable, principal.userId, initial.id);
          await writeJobAudit(
            queryable,
            principal,
            "job.create",
            initial.id,
            requestId,
          );
          const current = await loadJobByOwner(
            queryable,
            principal.userId,
            initial.id,
            "none",
          );
          if (current === undefined) {
            throw new Error("Created ingestion job could not be reloaded");
          }
          const detail = await loadJobDetail(queryable, current);
          return {
            status: 201,
            headers: {
              location: `/jobs/${initial.id}`,
              etag: jobEtag(current),
            },
            body: { ...detail, skippedItems },
          };
        },
      ),
    );
  }

  async updateItem(
    principal: Principal,
    jobId: string,
    itemId: string,
    input: UpdateIngestionItemInput,
    ifMatch: string,
    idempotencyKey: string,
    requestId: string,
  ): Promise<MutationResponse<IngestionJobItemMutationResource>> {
    assertUuid(jobId, "jobId");
    assertUuid(itemId, "itemId");
    const validated = validateUpdateIngestionItemInput(input);

    return this.translate(() =>
      executeIdempotentMutation(
        this.database,
        principal,
        "updateIngestionJobItem",
        idempotencyKey,
        { jobId, itemId, ifMatch, input: validated },
        async (queryable) => {
          const job = await loadJobByOwner(
            queryable,
            principal.userId,
            jobId,
            "update",
          );
          if (job === undefined) {
            throw jobNotFound();
          }
          assertApiKeyDevice(principal, job.device_id);
          requireMatchingEtag(ifMatch, jobEtag(job));

          const item = await loadJobItem(
            queryable,
            principal.userId,
            jobId,
            itemId,
            true,
          );
          if (item === undefined) {
            throw jobItemNotFound();
          }
          assertTransition(item.status, validated.status);

          const outputMode = stableString(
            "outputMode",
            item.output_mode,
            validated.outputMode,
          );
          const uploadId = retryableUploadId(
            item.status,
            item.upload_id,
            validated.uploadId,
          );
          const mediaId = stableString(
            "mediaId",
            item.media_id,
            validated.mediaId,
          );
          const groupRecord = await loadGroupRecord(
            queryable,
            principal.userId,
            jobId,
            item.group_key,
          );
          let recordInternalId = item.record_id;
          let recordPublicId = item.record_public_id;
          if (
            groupRecord !== null &&
            recordInternalId !== null &&
            recordInternalId !== groupRecord.id
          ) {
            throw groupRecordConflict();
          }
          if (validated.recordId !== undefined) {
            if (
              recordPublicId !== null &&
              recordPublicId !== validated.recordId
            ) {
              throw immutableOutput("recordId");
            }
            const record = await resolveRecord(
              queryable,
              principal.userId,
              job.device_id,
              validated.recordId,
            );
            if (groupRecord !== null && groupRecord.id !== record.id) {
              throw groupRecordConflict();
            }
            recordInternalId = record.id;
            recordPublicId = validated.recordId;
          } else if (
            validated.status === "completed" &&
            recordInternalId === null &&
            groupRecord !== null
          ) {
            recordInternalId = groupRecord.id;
            recordPublicId = groupRecord.public_id;
          }

          if (validated.uploadId !== undefined) {
            await assertUpload(
              queryable,
              principal.userId,
              job.device_id,
              validated.uploadId,
            );
          }
          if (mediaId !== null) {
            await assertMedia(
              queryable,
              principal.userId,
              job.device_id,
              mediaId,
            );
          }
          if (
            validated.status === "completed" &&
            (mediaId === null ||
              recordInternalId === null ||
              recordPublicId === null)
          ) {
            throw unprocessable(
              "Completed ingestion items require mediaId and recordId.",
              "job_item_outputs_required",
            );
          }
          if (
            validated.status === "completed" &&
            mediaId !== null &&
            recordInternalId !== null
          ) {
            await assertMediaAttached(
              queryable,
              principal.userId,
              recordInternalId,
              mediaId,
            );
          }

          const stage =
            validated.stage ??
            (validated.status === "completed"
              ? "completed"
              : validated.status === "failed"
                ? "failed"
                : "processing");
          await queryable.query(
            `UPDATE ingestion_job_items
             SET status = $4,
                 stage = $5,
                 output_mode = $6,
                 upload_id = $7,
                 media_id = $8,
                 record_id = $9,
                 error = $10,
                 updated_at = clock_timestamp()
             WHERE user_id = $1 AND job_id = $2 AND id = $3`,
            [
              principal.userId,
              jobId,
              itemId,
              validated.status,
              stage,
              outputMode,
              uploadId,
              mediaId,
              recordInternalId,
              validated.status === "failed" ? validated.error : null,
            ],
          );
          await recomputeJob(queryable, principal.userId, jobId);
          await writeJobAudit(
            queryable,
            principal,
            "job.item.update",
            jobId,
            requestId,
            { itemId, status: validated.status, stage },
          );

          const current = await loadJobByOwner(
            queryable,
            principal.userId,
            jobId,
            "none",
          );
          if (current === undefined) {
            throw new Error("Updated ingestion job could not be reloaded");
          }
          const updatedItem = await loadJobItem(
            queryable,
            principal.userId,
            jobId,
            itemId,
            false,
          );
          if (updatedItem === undefined) {
            throw new Error("Updated ingestion item could not be reloaded");
          }
          const currentItems = await loadCurrentItems(
            queryable,
            principal.userId,
            [jobId],
          );
          return {
            status: 200,
            headers: { etag: jobEtag(current) },
            body: {
              ...mapJobStateRow(current, currentItems.get(jobId) ?? null),
              item: mapItemRow(updatedItem),
            },
          };
        },
      ),
    );
  }

  private async translate<Result>(
    work: () => Promise<Result>,
  ): Promise<Result> {
    try {
      return await work();
    } catch (error) {
      if (databaseErrorCode(error) !== undefined) {
        translateDatabaseError(error);
      }
      throw error;
    }
  }
}

export function validateCreateIngestionJobInput(
  input: CreateIngestionJobInput,
): CreateIngestionJobInput {
  if (!isUuid(input.deviceId)) {
    throw unprocessable("deviceId must be a UUID.", "invalid_device_id");
  }
  if (!isJsonObject(input.source)) {
    throw unprocessable("source must be a JSON object.", "invalid_job_source");
  }
  if (!isJsonObject(input.config)) {
    throw unprocessable("config must be a JSON object.", "invalid_job_config");
  }
  assertSerializedJsonSize(input.source, RESOURCE_METADATA_MAX_BYTES, "source");
  assertSerializedJsonSize(input.config, RESOURCE_METADATA_MAX_BYTES, "config");
  if (
    !Array.isArray(input.items) ||
    input.items.length < 1 ||
    input.items.length > 1_000
  ) {
    throw unprocessable(
      "items must contain between 1 and 1000 declarations.",
      "invalid_job_items",
    );
  }

  const sourceKeys = new Set<string>();
  const items = input.items.map((item, index) => {
    if (!HEX_SHA256.test(item.sourceKey)) {
      invalidItem(index, "sourceKey must be a lowercase SHA-256 value");
    }
    if (sourceKeys.has(item.sourceKey)) {
      invalidItem(index, "sourceKey values must be unique within one request");
    }
    sourceKeys.add(item.sourceKey);
    if (!HEX_SHA256.test(item.groupKey)) {
      invalidItem(index, "groupKey must be a lowercase SHA-256 value");
    }
    if (!validRelativePath(item.relativePath)) {
      invalidItem(
        index,
        "relativePath must be a safe relative POSIX path of at most 1024 characters",
      );
    }
    if (!ITEM_KINDS.has(item.kind)) {
      invalidItem(index, "kind must be photo, video, or audio");
    }
    if (!isRfc3339(item.capturedAt)) {
      invalidItem(index, "capturedAt must be an RFC 3339 timestamp");
    }
    if (
      !Number.isSafeInteger(item.byteLength) ||
      item.byteLength < 1 ||
      item.byteLength > MAX_MEDIA_BYTES
    ) {
      invalidItem(index, `byteLength must be between 1 and ${MAX_MEDIA_BYTES}`);
    }
    if (!HEX_SHA256.test(item.contentSha256)) {
      invalidItem(index, "contentSha256 must be a lowercase SHA-256 value");
    }
    return {
      sourceKey: item.sourceKey,
      groupKey: item.groupKey,
      relativePath: item.relativePath,
      kind: item.kind,
      capturedAt: new Date(item.capturedAt).toISOString(),
      byteLength: item.byteLength,
      contentSha256: item.contentSha256,
    };
  });

  return {
    deviceId: input.deviceId.toLowerCase(),
    source: input.source,
    config: input.config,
    items,
  };
}

export function validateUpdateIngestionItemInput(
  input: UpdateIngestionItemInput,
): UpdateIngestionItemInput {
  if (!UPDATE_STATUSES.has(input.status)) {
    throw unprocessable(
      "status must be processing, completed, or failed.",
      "invalid_job_item_status",
    );
  }
  if (input.stage !== undefined && !LIFECYCLE_TOKEN.test(input.stage)) {
    throw unprocessable(
      "stage must be a lowercase lifecycle token of at most 64 characters.",
      "invalid_job_item_stage",
    );
  }
  if (
    input.outputMode !== undefined &&
    !LIFECYCLE_TOKEN.test(input.outputMode)
  ) {
    throw unprocessable(
      "outputMode must be a lowercase token of at most 64 characters.",
      "invalid_job_output_mode",
    );
  }
  for (const [name, value] of [
    ["uploadId", input.uploadId],
    ["mediaId", input.mediaId],
  ] as const) {
    if (value !== undefined && !isUuid(value)) {
      throw unprocessable(`${name} must be a UUID.`, `invalid_${name}`);
    }
  }
  if (
    input.recordId !== undefined &&
    !/^[A-Za-z0-9_-]{5}$/.test(input.recordId)
  ) {
    throw unprocessable(
      "recordId must be a five-character Base64URL identifier.",
      "invalid_record_id",
    );
  }
  if (
    input.status === "failed" &&
    (input.error === undefined ||
      input.error !== input.error.trim() ||
      input.error.length < 1 ||
      input.error.length > 4_000)
  ) {
    throw unprocessable(
      "A failed item requires a trimmed error of at most 4000 characters.",
      "job_item_error_required",
    );
  }
  if (input.status !== "failed" && input.error !== undefined) {
    throw unprocessable(
      "error is accepted only when status is failed.",
      "invalid_job_item_error",
    );
  }
  return {
    status: input.status,
    ...(input.stage === undefined ? {} : { stage: input.stage }),
    ...(input.outputMode === undefined ? {} : { outputMode: input.outputMode }),
    ...(input.uploadId === undefined
      ? {}
      : { uploadId: input.uploadId.toLowerCase() }),
    ...(input.mediaId === undefined
      ? {}
      : { mediaId: input.mediaId.toLowerCase() }),
    ...(input.recordId === undefined ? {} : { recordId: input.recordId }),
    ...(input.error === undefined ? {} : { error: input.error }),
  };
}

function effectiveReadDevice(
  principal: Principal,
  requestedDeviceId: string | undefined,
): string | undefined {
  if (principal.kind !== "api_key") {
    return requestedDeviceId;
  }
  if (principal.deviceId === undefined) {
    throw new Error("API-key principal has no bound device");
  }
  if (
    requestedDeviceId !== undefined &&
    requestedDeviceId !== principal.deviceId
  ) {
    assertApiKeyDevice(principal, requestedDeviceId);
  }
  return principal.deviceId;
}

async function loadJob(
  queryable: Queryable,
  principal: Principal,
  jobId: string,
  lock: JobLock,
): Promise<JobRow | undefined> {
  const row = await loadJobByOwner(queryable, principal.userId, jobId, lock);
  if (
    row !== undefined &&
    principal.kind === "api_key" &&
    row.device_id !== principal.deviceId
  ) {
    return undefined;
  }
  return row;
}

async function loadJobByOwner(
  queryable: Queryable,
  userId: string,
  jobId: string,
  lock: JobLock,
): Promise<JobRow | undefined> {
  const result = await queryable.query<JobRow>(
    `SELECT ${JOB_COLUMNS}
     FROM ingestion_jobs j
     WHERE j.user_id = $1 AND j.id = $2
     ${jobLockClause(lock)}`,
    [userId, jobId],
  );
  return result.rows[0];
}

function jobLockClause(lock: JobLock): string {
  switch (lock) {
    case "none":
      return "";
    case "share":
      return "FOR SHARE OF j";
    case "update":
      return "FOR UPDATE OF j";
  }
}

async function loadJobItem(
  queryable: Queryable,
  userId: string,
  jobId: string,
  itemId: string,
  forUpdate: boolean,
): Promise<JobItemRow | undefined> {
  const result = await queryable.query<JobItemRow>(
    `SELECT ${ITEM_COLUMNS}
     FROM ingestion_job_items i
     LEFT JOIN records record
       ON record.user_id = i.user_id AND record.id = i.record_id
     WHERE i.user_id = $1 AND i.job_id = $2 AND i.id = $3
     ${forUpdate ? "FOR UPDATE OF i" : ""}`,
    [userId, jobId, itemId],
  );
  return result.rows[0];
}

async function loadJobItems(
  queryable: Queryable,
  userId: string,
  jobId: string,
): Promise<readonly JobItemRow[]> {
  const result = await queryable.query<JobItemRow>(
    `SELECT ${ITEM_COLUMNS}
     FROM ingestion_job_items i
     LEFT JOIN records record
       ON record.user_id = i.user_id AND record.id = i.record_id
     WHERE i.user_id = $1 AND i.job_id = $2
     ORDER BY i.ordinal, i.id`,
    [userId, jobId],
  );
  return result.rows;
}

async function loadCurrentItems(
  queryable: Queryable,
  userId: string,
  jobIds: readonly string[],
): Promise<ReadonlyMap<string, JobItemRow>> {
  if (jobIds.length === 0) {
    return new Map();
  }
  const result = await queryable.query<JobItemRow>(
    `SELECT DISTINCT ON (i.job_id) ${ITEM_COLUMNS}
     FROM ingestion_job_items i
     LEFT JOIN records record
       ON record.user_id = i.user_id AND record.id = i.record_id
     WHERE i.user_id = $1
       AND i.job_id = ANY($2::uuid[])
       AND i.status IN ('processing', 'failed')
     ORDER BY
       i.job_id,
       CASE i.status WHEN 'processing' THEN 0 ELSE 1 END,
       i.updated_at DESC,
       i.ordinal DESC,
       i.id DESC`,
    [userId, jobIds],
  );
  return new Map(result.rows.map((row) => [row.job_id, row]));
}

async function loadJobDetail(
  queryable: Queryable,
  row: JobRow,
): Promise<IngestionJobDetailResource> {
  const items = await loadJobItems(queryable, row.user_id, row.id);
  const current = selectCurrentItem(items);
  return {
    ...mapJobStateRow(row, current),
    items: items.map(mapItemRow),
  };
}

function selectCurrentItem(items: readonly JobItemRow[]): JobItemRow | null {
  return items.reduce<JobItemRow | null>((current, item) => {
    if (item.status !== "processing" && item.status !== "failed") {
      return current;
    }
    return current === null || compareCurrentItems(item, current) < 0
      ? item
      : current;
  }, null);
}

function compareCurrentItems(left: JobItemRow, right: JobItemRow): number {
  const leftPriority = left.status === "processing" ? 0 : 1;
  const rightPriority = right.status === "processing" ? 0 : 1;
  if (leftPriority !== rightPriority) {
    return leftPriority - rightPriority;
  }
  const updated = isoDate(right.updated_at).localeCompare(
    isoDate(left.updated_at),
  );
  if (updated !== 0) {
    return updated;
  }
  if (left.ordinal !== right.ordinal) {
    return right.ordinal - left.ordinal;
  }
  return right.id.localeCompare(left.id);
}

function mapJobRow(
  row: JobRow,
  currentItem: JobItemRow | null,
  knownActive = false,
): IngestionJobResource {
  return {
    ...mapJobStateRow(row, currentItem),
    activity:
      knownActive || isJobActive(row, currentItem) ? "active" : "idle",
  };
}

function mapJobStateRow(
  row: JobRow,
  currentItem: JobItemRow | null,
): IngestionJobStateResource {
  const totalItems = numeric(row.total_items);
  const processedItems = numeric(row.processed_items);
  const totalRecords = numeric(row.total_records);
  const processedRecords = numeric(row.processed_records);
  return {
    id: row.id,
    userId: row.user_id,
    deviceId: row.device_id,
    source: row.source,
    config: row.config,
    status: row.status,
    totalItems,
    processedItems,
    failedItems: numeric(row.failed_items),
    remainingItems: totalItems - processedItems,
    totalRecords,
    processedRecords,
    failedRecords: numeric(row.failed_records),
    remainingRecords: totalRecords - processedRecords,
    currentItem: currentItem === null ? null : mapItemRow(currentItem),
    revision: numeric(row.revision),
    createdAt: isoDate(row.created_at),
    updatedAt: isoDate(row.updated_at),
    ...(row.started_at === null ? {} : { startedAt: isoDate(row.started_at) }),
    ...(row.finished_at === null
      ? {}
      : { finishedAt: isoDate(row.finished_at) }),
  };
}

function isJobActive(row: JobRow, currentItem: JobItemRow | null): boolean {
  return (
    row.status === "processing" &&
    currentItem?.status === "processing" &&
    Date.now() - Date.parse(isoDate(currentItem.updated_at)) <
      INGESTION_JOB_ACTIVITY_LEASE_MS
  );
}

function mapItemRow(row: JobItemRow): IngestionJobItemResource {
  return {
    id: row.id,
    sourceKey: row.source_key,
    groupKey: row.group_key,
    relativePath: row.relative_path,
    kind: row.kind,
    capturedAt: isoDate(row.captured_at),
    byteLength: numeric(row.byte_length),
    contentSha256: row.content_sha256.toString("hex"),
    status: row.status,
    stage: row.stage,
    ...(row.output_mode === null ? {} : { outputMode: row.output_mode }),
    ...(row.upload_id === null ? {} : { uploadId: row.upload_id }),
    ...(row.media_id === null ? {} : { mediaId: row.media_id }),
    ...(row.record_public_id === null
      ? {}
      : { recordId: row.record_public_id }),
    ...(row.error === null ? {} : { error: row.error }),
    createdAt: isoDate(row.created_at),
    updatedAt: isoDate(row.updated_at),
  };
}

async function recomputeJob(
  queryable: Queryable,
  userId: string,
  jobId: string,
): Promise<void> {
  await queryable.query(
    `WITH item_counts AS (
       SELECT
         count(*)::integer AS total_items,
         count(*) FILTER (WHERE status = 'completed')::integer AS processed_items,
         count(*) FILTER (WHERE status = 'failed')::integer AS failed_items,
         count(*) FILTER (WHERE status = 'processing')::integer AS processing_items,
         count(*) FILTER (WHERE status = 'queued')::integer AS queued_items,
         count(*) FILTER (WHERE status <> 'queued')::integer AS started_items
       FROM ingestion_job_items
       WHERE user_id = $1 AND job_id = $2
     ),
     grouped AS (
       SELECT
         group_key,
         bool_and(status = 'completed') AS processed,
         bool_or(status = 'failed') AS failed
       FROM ingestion_job_items
       WHERE user_id = $1 AND job_id = $2
       GROUP BY group_key
     ),
     record_counts AS (
       SELECT
         count(*)::integer AS total_records,
         count(*) FILTER (WHERE processed)::integer AS processed_records,
         count(*) FILTER (WHERE failed)::integer AS failed_records
       FROM grouped
     ),
     next_state AS (
       SELECT
         item_counts.*,
         record_counts.*,
         CASE
           WHEN item_counts.total_items = 0
             OR item_counts.processed_items = item_counts.total_items
             THEN 'completed'
           WHEN item_counts.processing_items > 0 THEN 'processing'
           WHEN item_counts.queued_items > 0 THEN 'queued'
           ELSE 'failed'
         END AS status
       FROM item_counts CROSS JOIN record_counts
     )
     UPDATE ingestion_jobs AS job
     SET total_items = next_state.total_items,
         processed_items = next_state.processed_items,
         failed_items = next_state.failed_items,
         total_records = next_state.total_records,
         processed_records = next_state.processed_records,
         failed_records = next_state.failed_records,
         status = next_state.status,
         started_at = CASE
           WHEN next_state.started_items > 0
             THEN COALESCE(job.started_at, clock_timestamp())
           ELSE job.started_at
         END,
         finished_at = CASE
           WHEN next_state.status IN ('completed', 'failed')
             THEN COALESCE(job.finished_at, clock_timestamp())
           ELSE NULL
         END,
         updated_at = clock_timestamp()
     FROM next_state
     WHERE job.user_id = $1 AND job.id = $2`,
    [userId, jobId],
  );
}

function assertTransition(
  current: IngestionItemStatus,
  next: UpdateIngestionItemInput["status"],
): void {
  const allowed =
    (current === "queued" && (next === "processing" || next === "failed")) ||
    (current === "processing" &&
      (next === "processing" || next === "completed" || next === "failed")) ||
    (current === "failed" && next === "processing");
  if (!allowed) {
    throw new HttpProblem({
      status: 409,
      code: "invalid_job_item_transition",
      title: "Conflict",
      type: "urn:exeligmos:problem:invalid-job-item-transition",
      detail: `An ingestion item cannot transition from ${current} to ${next}.`,
    });
  }
}

function stableString(
  field: string,
  current: string | null,
  requested: string | undefined,
): string | null {
  if (current !== null && requested !== undefined && current !== requested) {
    throw immutableOutput(field);
  }
  return requested ?? current;
}

function retryableUploadId(
  currentStatus: IngestionItemStatus,
  current: string | null,
  requested: string | undefined,
): string | null {
  if (
    current !== null &&
    requested !== undefined &&
    current !== requested &&
    currentStatus !== "processing" &&
    currentStatus !== "failed"
  ) {
    throw immutableOutput("uploadId");
  }
  return requested ?? current;
}

function immutableOutput(field: string): HttpProblem {
  return new HttpProblem({
    status: 409,
    code: "job_item_output_conflict",
    title: "Conflict",
    type: "urn:exeligmos:problem:job-item-output-conflict",
    detail: `${field} is already persisted and cannot be changed on retry.`,
  });
}

async function assertUpload(
  queryable: Queryable,
  userId: string,
  deviceId: string,
  uploadId: string,
): Promise<void> {
  const result = await queryable.query(
    `SELECT 1
     FROM media_upload_sessions
     WHERE user_id = $1 AND device_id = $2 AND id = $3
       AND (
         status = 'completed'
         OR (
           status IN ('reserved', 'received')
           AND expires_at > clock_timestamp()
         )
       )`,
    [userId, deviceId, uploadId],
  );
  if (result.rowCount === 0) {
    throw unprocessable(
      "uploadId must identify an active or completed upload owned by the job device.",
      "invalid_job_upload",
    );
  }
}

interface GroupRecordRow extends QueryResultRow {
  readonly id: string;
  readonly public_id: string;
}

async function loadGroupRecord(
  queryable: Queryable,
  userId: string,
  jobId: string,
  groupKey: string,
): Promise<GroupRecordRow | null> {
  const result = await queryable.query<GroupRecordRow>(
    `SELECT DISTINCT record.id, record.public_id
     FROM ingestion_job_items sibling
     JOIN records record
       ON record.user_id = sibling.user_id
      AND record.id = sibling.record_id
     WHERE sibling.user_id = $1
       AND sibling.job_id = $2
       AND sibling.group_key = $3`,
    [userId, jobId, groupKey],
  );
  if (result.rows.length > 1) {
    throw new Error("An ingestion group references multiple records");
  }
  return result.rows[0] ?? null;
}

function groupRecordConflict(): HttpProblem {
  return new HttpProblem({
    status: 409,
    code: "job_group_record_conflict",
    title: "Conflict",
    type: "urn:exeligmos:problem:job-group-record-conflict",
    detail:
      "Every item in one ingestion group must reference the same recordId.",
  });
}

async function assertMedia(
  queryable: Queryable,
  userId: string,
  deviceId: string,
  mediaId: string,
): Promise<void> {
  const result = await queryable.query(
    `SELECT 1
     FROM media_objects
     WHERE user_id = $1 AND device_id = $2 AND id = $3
       AND status = 'ready' AND deleted_at IS NULL`,
    [userId, deviceId, mediaId],
  );
  if (result.rowCount === 0) {
    throw unprocessable(
      "mediaId must identify active media owned by the job device.",
      "invalid_job_media",
    );
  }
}

async function resolveRecord(
  queryable: Queryable,
  userId: string,
  deviceId: string,
  recordPublicId: string,
): Promise<IdRow> {
  const result = await queryable.query<IdRow>(
    `SELECT id
     FROM records
     WHERE user_id = $1 AND device_id = $2 AND public_id = $3
       AND visibility = 'public' AND deleted_at IS NULL`,
    [userId, deviceId, recordPublicId],
  );
  const row = result.rows[0];
  if (row === undefined) {
    throw unprocessable(
      "recordId must identify an active public record owned by the job device.",
      "invalid_job_record",
    );
  }
  return row;
}

async function assertMediaAttached(
  queryable: Queryable,
  userId: string,
  recordId: string,
  mediaId: string,
): Promise<void> {
  const result = await queryable.query(
    `SELECT 1
     FROM record_media
     WHERE user_id = $1 AND record_id = $2 AND media_id = $3`,
    [userId, recordId, mediaId],
  );
  if (result.rowCount === 0) {
    throw unprocessable(
      "Completed item mediaId must be attached to recordId.",
      "job_item_media_not_attached",
    );
  }
}

async function writeJobAudit(
  queryable: Queryable,
  principal: Principal,
  action: string,
  jobId: string,
  requestId: string,
  metadata: JsonObject = {},
): Promise<void> {
  await queryable.query(
    `INSERT INTO audit_log (
       user_id, actor_type, actor_id, action, entity_type, entity_id,
       request_id, metadata
     ) VALUES ($1, $2, $3, $4, 'job', $5, $6, $7::jsonb)`,
    [
      principal.userId,
      principal.kind,
      principal.actorId,
      action,
      jobId,
      requestId,
      JSON.stringify(metadata),
    ],
  );
}

function jobEtag(row: JobRow): string {
  return resourceEtag("job", row.id, numeric(row.revision));
}

function jobNotFound(): HttpProblem {
  return new HttpProblem({
    status: 404,
    code: "job_not_found",
    title: "Not Found",
    type: "urn:exeligmos:problem:job-not-found",
    detail: "The requested ingestion job does not exist.",
  });
}

function jobItemNotFound(): HttpProblem {
  return new HttpProblem({
    status: 404,
    code: "job_item_not_found",
    title: "Not Found",
    type: "urn:exeligmos:problem:job-item-not-found",
    detail: "The requested ingestion job item does not exist.",
  });
}

function invalidItem(index: number, detail: string): never {
  throw unprocessable(detail, "invalid_job_item", `/items/${index}`);
}

function assertUuid(value: string, name: string): void {
  if (!isUuid(value)) {
    throw invalidRequest(`${name} must be a UUID.`);
  }
}

function numeric(value: string | number): number {
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 0) {
    throw new Error("Database returned an invalid ingestion counter");
  }
  return parsed;
}

function isJsonObject(value: unknown): value is JsonObject {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function validRelativePath(value: string): boolean {
  if (
    typeof value !== "string" ||
    value !== value.trim() ||
    value.length < 1 ||
    value.length > 1_024 ||
    value.startsWith("/") ||
    value.includes("\\") ||
    value.includes("\0")
  ) {
    return false;
  }
  const segments = value.split("/");
  return segments.every(
    (segment) => segment.length > 0 && segment !== "." && segment !== "..",
  );
}

function isRfc3339(value: string): boolean {
  return (
    typeof value === "string" &&
    RFC3339_PATTERN.test(value) &&
    Number.isFinite(Date.parse(value))
  );
}

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
    value,
  );
}

const MAX_MEDIA_BYTES = 5_368_709_120;
export const INGESTION_JOB_ACTIVITY_LEASE_MS = 120_000;
const HEX_SHA256 = /^[a-f0-9]{64}$/;
const LIFECYCLE_TOKEN = /^[a-z][a-z0-9_-]{0,63}$/;
const RFC3339_PATTERN =
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/;
const JOB_STATUSES = new Set<IngestionJobStatus>([
  "queued",
  "processing",
  "completed",
  "failed",
]);
const UPDATE_STATUSES = new Set<UpdateIngestionItemInput["status"]>([
  "processing",
  "completed",
  "failed",
]);
const ITEM_KINDS = new Set<IngestionItemKind>(["photo", "video", "audio"]);
