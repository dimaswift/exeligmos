import type { QueryResultRow } from "pg";

import type { Principal } from "../auth/principal.js";
import type { Database, Queryable } from "../db/database.js";
import { HttpProblem } from "../http/problem.js";
import { assertRecordPublicId } from "./records.js";
import { requireMatchingEtag, resourceEtag } from "./shared.js";

export interface WorkerConfig {
  readonly enabled: boolean;
  readonly mountName: string;
  readonly pollIntervalMs: number;
  readonly descriptionProvider: "ollama" | "speshu";
  readonly descriptionBaseUrl: string;
  readonly descriptionModel: string;
  readonly descriptionPrompt: string;
  readonly embeddingProvider: "ollama" | "speshu";
  readonly embeddingBaseUrl: string;
  readonly embeddingModel: string;
  readonly whisperModel: string;
  readonly imageGenerationEnabled: boolean;
  readonly imageProvider: "mlx-studio";
  readonly imageBaseUrl: string;
  readonly imageModel: string;
  readonly imagePromptReference: string;
  readonly imageSize: string;
  readonly imageSteps: number;
  readonly imageGuidance: number;
  readonly imageTimeoutMs: number;
}

export type WorkerConfigPatch = Partial<WorkerConfig>;

export interface DreamerRuntime {
  readonly state: "disabled" | "waiting" | "creating" | "error";
  readonly nextRolloverAt: string | null;
  readonly saros: number | null;
  readonly scheduleId: string | null;
  readonly startedAt: string | null;
  readonly sourceRecordId: string | null;
  readonly message: string | null;
}

export interface DreamRequest {
  readonly jobId: string;
  readonly recordId: string;
  readonly status: "queued" | "processing" | "completed" | "failed";
  readonly requestedAt: string;
  readonly startedAt: string | null;
  readonly finishedAt: string | null;
  readonly dreamRecordId: string | null;
  readonly error: string | null;
}

export type WorkerLogLevel = "debug" | "info" | "warn" | "error";

export interface WorkerLog {
  readonly id: string;
  readonly deviceId: string;
  readonly level: WorkerLogLevel;
  readonly message: string;
  readonly context: Readonly<Record<string, unknown>>;
  readonly createdAt: string;
}

export interface DreamAttempt {
  readonly recordId: string;
  readonly attempt: number;
  readonly maxAttempts: 3;
  readonly allowed: boolean;
}

export interface WorkerView {
  readonly deviceId: string;
  readonly name: string;
  readonly type: "thumb-cam" | "dreamer";
  readonly revision: number;
  readonly cacheGeneration: number;
  readonly lastSeenAt: string | null;
  readonly config: WorkerConfig;
  readonly runtime: DreamerRuntime | null;
  readonly stats: {
    readonly jobs: number;
    readonly media: number;
    readonly records: number;
    readonly failedMedia: number;
    readonly lastJobAt: string | null;
    readonly resetAt: string | null;
  };
}

export interface WorkerReset {
  readonly deviceId: string;
  readonly cacheGeneration: number;
  readonly resetAt: string;
  readonly removedJobs: number;
  readonly removedItems: number;
}

interface WorkerRow extends QueryResultRow {
  readonly id: string;
  readonly name: string;
  readonly revision: string | number;
  readonly last_seen_at: Date | string | null;
  readonly metadata: unknown;
  readonly jobs: string | number;
  readonly media: string | number;
  readonly records: string | number;
  readonly failed_media: string | number;
  readonly last_job_at: Date | string | null;
}

interface DreamRequestRow extends QueryResultRow {
  readonly id: string;
  readonly source: unknown;
  readonly config: unknown;
  readonly status: "queued" | "processing" | "completed" | "failed";
  readonly created_at: Date | string;
  readonly started_at: Date | string | null;
  readonly finished_at: Date | string | null;
}

interface WorkerLogRow extends QueryResultRow {
  readonly id: string;
  readonly device_id: string;
  readonly level: WorkerLogLevel;
  readonly message: string;
  readonly context: unknown;
  readonly created_at: Date | string;
}

const DEFAULT_CONFIG: WorkerConfig = {
  enabled: true,
  mountName: "THUMB_CAM",
  pollIntervalMs: 5_000,
  descriptionProvider: "ollama",
  descriptionBaseUrl: "http://127.0.0.1:11434",
  descriptionModel: "gemma4",
  descriptionPrompt:
    "describe the image from 1st person perspective as if you have captured it yourself in present tense, like an entry in the diary. Keep it short and informative",
  embeddingProvider: "ollama",
  embeddingBaseUrl: "http://127.0.0.1:11434",
  embeddingModel: "embeddinggemma",
  whisperModel: "mlx-community/whisper-large-v3-mlx",
  imageGenerationEnabled: true,
  imageProvider: "mlx-studio",
  imageBaseUrl: "http://127.0.0.1:8001",
  imageModel: "schnell",
  imagePromptReference:
    "A compact workstation on a walnut desk, soft window light, eye-level product photo, quiet focused mood",
  imageSize: "512x512",
  imageSteps: 4,
  imageGuidance: 0,
  imageTimeoutMs: 30_000,
};

export class WorkerService {
  constructor(private readonly database: Database) {}

  async list(
    userId: string,
  ): Promise<{ readonly data: readonly WorkerView[] }> {
    const result = await workerRows(this.database, userId);
    return { data: result.rows.map(workerView) };
  }

  async current(principal: Principal): Promise<WorkerView> {
    if (principal.kind !== "api_key" || principal.deviceId === undefined) {
      throw new HttpProblem({
        status: 403,
        code: "worker_key_required",
        title: "Forbidden",
        type: "urn:exeligmos:problem:worker-key-required",
        detail:
          "The current worker configuration requires a device-bound API key.",
      });
    }
    const result = await workerRows(
      this.database,
      principal.userId,
      principal.deviceId,
    );
    const row = result.rows[0];
    if (row === undefined) throw workerNotFound();
    return workerView(row);
  }

  async listLogs(
    principal: Principal,
    deviceId: string,
    limit: number,
  ): Promise<{ readonly data: readonly WorkerLog[] }> {
    if (principal.kind !== "jwt") {
      throw new HttpProblem({
        status: 403,
        code: "jwt_required",
        title: "Forbidden",
        type: "urn:exeligmos:problem:jwt-required",
        detail: "Reading worker logs requires an authenticated user session.",
      });
    }
    const device = await this.database.query(
      `SELECT 1
       FROM devices
       WHERE user_id = $1 AND id = $2 AND kind = 'agent'
         AND revoked_at IS NULL
         AND metadata->>'source' IN ('THUMB_CAM', 'DREAMER')`,
      [principal.userId, deviceId],
    );
    if (device.rows[0] === undefined) throw workerNotFound();
    const logs = await this.database.query<WorkerLogRow>(
      `SELECT id, device_id, level, message, context, created_at
       FROM worker_logs
       WHERE user_id = $1 AND device_id = $2
       ORDER BY created_at DESC, id DESC
       LIMIT $3`,
      [principal.userId, deviceId, limit],
    );
    return { data: logs.rows.map(workerLogView) };
  }

  async appendLog(
    principal: Principal,
    input: {
      readonly level: WorkerLogLevel;
      readonly message: string;
      readonly context: Readonly<Record<string, unknown>>;
    },
  ): Promise<WorkerLog> {
    await this.assertWorkerPrincipal(principal);
    const inserted = await this.database.query<WorkerLogRow>(
      `INSERT INTO worker_logs (user_id, device_id, level, message, context)
       VALUES ($1, $2, $3, $4, $5::jsonb)
       RETURNING id, device_id, level, message, context, created_at`,
      [
        principal.userId,
        principal.deviceId!,
        input.level,
        input.message,
        JSON.stringify(input.context),
      ],
    );
    return workerLogView(inserted.rows[0]!);
  }

  async startDreamAttempt(
    principal: Principal,
    recordId: string,
  ): Promise<DreamAttempt> {
    assertRecordPublicId(recordId);
    await this.assertDreamerPrincipal(principal);
    const attempt = await this.database.transaction(async (client) => {
      const record = await client.query<{ readonly id: string }>(
        `SELECT id
         FROM records
         WHERE user_id = $1 AND public_id = $2 AND deleted_at IS NULL
         FOR SHARE`,
        [principal.userId, recordId],
      );
      const internalId = record.rows[0]?.id;
      if (internalId === undefined) throw dreamSourceNotFound();
      const updated = await client.query<{ readonly attempts: number }>(
        `INSERT INTO worker_dream_attempts (
           user_id, device_id, record_id, attempts
         ) VALUES ($1, $2, $3, 1)
         ON CONFLICT (user_id, device_id, record_id)
         DO UPDATE SET
           attempts = worker_dream_attempts.attempts + 1,
           updated_at = now()
         RETURNING attempts`,
        [principal.userId, principal.deviceId!, internalId],
      );
      return updated.rows[0]!.attempts;
    });
    return {
      recordId,
      attempt,
      maxAttempts: 3,
      allowed: attempt <= 3,
    };
  }

  async update(
    principal: Principal,
    deviceId: string,
    ifMatch: string,
    patch: WorkerConfigPatch,
  ): Promise<WorkerView> {
    if (principal.kind !== "jwt") {
      throw new HttpProblem({
        status: 403,
        code: "jwt_required",
        title: "Forbidden",
        type: "urn:exeligmos:problem:jwt-required",
        detail: "Editing a worker requires an authenticated user session.",
      });
    }
    return this.database.transaction(async (client) => {
      const current = await client.query<WorkerRow>(
        `SELECT id, name, revision, last_seen_at, metadata,
                0::bigint AS jobs, 0::bigint AS media, 0::bigint AS records,
                0::bigint AS failed_media, NULL::timestamptz AS last_job_at
         FROM devices
         WHERE user_id = $1 AND id = $2 AND kind = 'agent'
           AND revoked_at IS NULL
           AND metadata->>'source' IN ('THUMB_CAM', 'DREAMER')
         FOR UPDATE`,
        [principal.userId, deviceId],
      );
      const row = current.rows[0];
      if (row === undefined) throw workerNotFound();
      const etag = resourceEtag("worker", row.id, Number(row.revision));
      requireMatchingEtag(ifMatch, etag);
      const config = { ...workerConfig(row.metadata), ...patch };
      const updated = await client.query<WorkerRow>(
        `UPDATE devices
         SET metadata = jsonb_set(metadata, '{worker}', $3::jsonb, true),
             revision = revision + 1,
             updated_at = now()
         WHERE user_id = $1 AND id = $2
         RETURNING id, name, revision, last_seen_at, metadata,
           0::bigint AS jobs, 0::bigint AS media, 0::bigint AS records,
           0::bigint AS failed_media, NULL::timestamptz AS last_job_at`,
        [principal.userId, deviceId, JSON.stringify(config)],
      );
      const refreshed = await workerRows(client, principal.userId, deviceId);
      return workerView(refreshed.rows[0] ?? updated.rows[0]!);
    });
  }

  async resetThumbCam(
    principal: Principal,
    deviceId: string,
  ): Promise<WorkerReset> {
    if (principal.kind !== "jwt") {
      throw new HttpProblem({
        status: 403,
        code: "jwt_required",
        title: "Forbidden",
        type: "urn:exeligmos:problem:jwt-required",
        detail: "Resetting a worker requires an authenticated user session.",
      });
    }
    return this.database.transaction(async (client) => {
      const device = await client.query<{
        readonly metadata: unknown;
      }>(
        `SELECT metadata
         FROM devices
         WHERE user_id = $1 AND id = $2 AND kind = 'agent'
           AND revoked_at IS NULL
           AND metadata->>'source' = 'THUMB_CAM'
         FOR UPDATE`,
        [principal.userId, deviceId],
      );
      const row = device.rows[0];
      if (row === undefined) throw workerNotFound();
      const removed = await client.query<{
        readonly jobs: string | number;
        readonly items: string | number;
      }>(
        `SELECT count(DISTINCT j.id)::bigint AS jobs,
                count(i.id)::bigint AS items
         FROM ingestion_jobs j
         LEFT JOIN ingestion_job_items i
           ON i.user_id = j.user_id AND i.device_id = j.device_id
          AND i.job_id = j.id
         WHERE j.user_id = $1 AND j.device_id = $2`,
        [principal.userId, deviceId],
      );
      await client.query(
        `DELETE FROM ingestion_jobs
         WHERE user_id = $1 AND device_id = $2`,
        [principal.userId, deviceId],
      );
      await client.query(
        `DELETE FROM idempotency_keys stored
         USING api_keys key
         WHERE stored.user_id = $1
           AND stored.actor_type = 'api_key'
           AND stored.actor_id = key.id
           AND key.user_id = $1 AND key.device_id = $2
           AND stored.operation_id IN (
             'createIngestionJob', 'updateIngestionJobItem'
           )`,
        [principal.userId, deviceId],
      );
      const cacheGeneration = workerCacheGeneration(row.metadata) + 1;
      const updated = await client.query<{
        readonly reset_at: Date | string;
      }>(
        `UPDATE devices
         SET metadata = metadata || jsonb_build_object(
               'thumbCamReset', jsonb_build_object(
                 'generation', $3::integer,
                 'at', clock_timestamp()
               )
             ),
             revision = revision + 1,
             updated_at = now()
         WHERE user_id = $1 AND id = $2
         RETURNING metadata#>>'{thumbCamReset,at}' AS reset_at`,
        [principal.userId, deviceId, cacheGeneration],
      );
      const resetAt = timestamp(updated.rows[0]!.reset_at)!;
      const counts = removed.rows[0]!;
      const removedJobs = Number(counts.jobs);
      const removedItems = Number(counts.items);
      await client.query(
        `INSERT INTO worker_logs (user_id, device_id, level, message, context)
         VALUES ($1, $2, 'info', 'THUMB worker cache reset by owner.', $3::jsonb)`,
        [
          principal.userId,
          deviceId,
          JSON.stringify({
            event: "worker_cache_reset",
            cacheGeneration,
            removedJobs,
            removedItems,
          }),
        ],
      );
      return {
        deviceId,
        cacheGeneration,
        resetAt,
        removedJobs,
        removedItems,
      };
    });
  }

  async markDreamed(principal: Principal, recordId: string): Promise<void> {
    if (principal.kind !== "api_key" || principal.deviceId === undefined) {
      throw workerNotFound();
    }
    await this.database.transaction(async (client) => {
      const device = await client.query<{ readonly source: string | null }>(
        `SELECT metadata->>'source' AS source
         FROM devices
         WHERE user_id = $1 AND id = $2 AND kind = 'agent'
           AND revoked_at IS NULL
         FOR SHARE`,
        [principal.userId, principal.deviceId],
      );
      if (device.rows[0]?.source !== "DREAMER") throw workerNotFound();
      const record = await client.query<{ readonly id: string }>(
        `SELECT id
         FROM records
         WHERE user_id = $1 AND public_id = $2 AND deleted_at IS NULL
         FOR UPDATE`,
        [principal.userId, recordId],
      );
      const internalId = record.rows[0]?.id;
      if (internalId === undefined) throw workerNotFound();
      await client.query(
        `SELECT pg_advisory_xact_lock(hashtextextended($1::text || ':dreamer-tag', 0))`,
        [principal.userId],
      );
      let tag = await client.query<{ readonly id: string }>(
        `SELECT id FROM tags
         WHERE user_id = $1 AND lower(name) = 'dreamer' AND deleted_at IS NULL
         ORDER BY created_at, id
         LIMIT 1`,
        [principal.userId],
      );
      if (tag.rows[0] === undefined) {
        tag = await client.query<{ readonly id: string }>(
          `INSERT INTO tags (id, user_id, name, emoji, color, sort_order, metadata)
           VALUES (gen_random_uuid(), $1, 'Dreamer', '💭', '#9B8CFF', 0, '{}'::jsonb)
           RETURNING id`,
          [principal.userId],
        );
      }
      const attached = await client.query(
        `INSERT INTO record_tags (user_id, record_id, tag_id)
         VALUES ($1, $2, $3)
         ON CONFLICT DO NOTHING
         RETURNING record_id`,
        [principal.userId, internalId, tag.rows[0]!.id],
      );
      if ((attached.rowCount ?? 0) > 0) {
        await client.query(
          `UPDATE records
           SET revision = revision + 1, updated_at = now()
           WHERE user_id = $1 AND id = $2`,
          [principal.userId, internalId],
        );
      }
    });
  }

  async updateDreamerRuntime(
    principal: Principal,
    runtime: DreamerRuntime,
  ): Promise<void> {
    if (principal.kind !== "api_key" || principal.deviceId === undefined) {
      throw workerNotFound();
    }
    const updated = await this.database.query(
      `UPDATE devices
       SET metadata = jsonb_set(metadata, '{dreamerRuntime}', $3::jsonb, true),
           last_seen_at = now(),
           updated_at = now()
       WHERE user_id = $1 AND id = $2 AND kind = 'agent'
         AND revoked_at IS NULL
         AND metadata->>'source' = 'DREAMER'`,
      [principal.userId, principal.deviceId, JSON.stringify(runtime)],
    );
    if ((updated.rowCount ?? 0) === 0) throw workerNotFound();
  }

  async readDreamRequest(
    principal: Principal,
    recordId: string,
  ): Promise<DreamRequest | null> {
    assertRecordPublicId(recordId);
    if (principal.kind !== "jwt") {
      throw new HttpProblem({
        status: 403,
        code: "jwt_required",
        title: "Forbidden",
        type: "urn:exeligmos:problem:jwt-required",
        detail:
          "Reading a dream request requires an authenticated user session.",
      });
    }
    const result = await this.database.query<DreamRequestRow>(
      `SELECT id, source, config, status, created_at, started_at, finished_at
       FROM ingestion_jobs
       WHERE user_id = $1
         AND source->>'kind' = 'dream'
         AND source->>'recordId' = $2
       ORDER BY created_at DESC, id DESC
       LIMIT 1`,
      [principal.userId, recordId],
    );
    return result.rows[0] === undefined
      ? null
      : dreamRequestView(result.rows[0]);
  }

  async scheduleDreamRequest(
    principal: Principal,
    recordId: string,
  ): Promise<DreamRequest> {
    assertRecordPublicId(recordId);
    if (principal.kind !== "jwt") {
      throw new HttpProblem({
        status: 403,
        code: "jwt_required",
        title: "Forbidden",
        type: "urn:exeligmos:problem:jwt-required",
        detail: "Scheduling a dream requires an authenticated user session.",
      });
    }
    return this.database.transaction(async (client) => {
      const record = await client.query<{
        readonly id: string;
        readonly visibility: string;
      }>(
        `SELECT id, visibility
         FROM records
         WHERE user_id = $1 AND public_id = $2 AND deleted_at IS NULL
         FOR SHARE`,
        [principal.userId, recordId],
      );
      const source = record.rows[0];
      if (source === undefined) throw dreamSourceNotFound();
      if (source.visibility !== "public") {
        throw new HttpProblem({
          status: 422,
          code: "public_dream_source_required",
          title: "Unprocessable Content",
          type: "urn:exeligmos:problem:public-dream-source-required",
          detail: "Only public records can be sent to Dreamer.",
        });
      }
      const device = await client.query<{ readonly id: string }>(
        `SELECT id
         FROM devices
         WHERE user_id = $1 AND kind = 'agent' AND revoked_at IS NULL
           AND metadata->>'source' = 'DREAMER'
         ORDER BY registered_at, id
         LIMIT 1
         FOR SHARE`,
        [principal.userId],
      );
      const deviceId = device.rows[0]?.id;
      if (deviceId === undefined) throw workerNotFound();
      await client.query(
        `SELECT pg_advisory_xact_lock(
           hashtextextended($1::text || ':' || $2::text || ':dream-request', 0)
         )`,
        [principal.userId, source.id],
      );
      const existing = await client.query<DreamRequestRow>(
        `SELECT id, source, config, status, created_at, started_at, finished_at
         FROM ingestion_jobs
         WHERE user_id = $1 AND device_id = $2
           AND source->>'kind' = 'dream'
           AND source->>'recordId' = $3
           AND status IN ('queued', 'processing', 'completed')
         ORDER BY created_at DESC, id DESC
         LIMIT 1
         FOR UPDATE`,
        [principal.userId, deviceId, recordId],
      );
      if (existing.rows[0] !== undefined) {
        return dreamRequestView(existing.rows[0]);
      }
      const inserted = await client.query<DreamRequestRow>(
        `INSERT INTO ingestion_jobs (
           user_id, device_id, source, config, total_records
         ) VALUES (
           $1, $2, $3::jsonb, '{"mode":"on-demand"}'::jsonb, 1
         )
         RETURNING id, source, config, status, created_at, started_at, finished_at`,
        [
          principal.userId,
          deviceId,
          JSON.stringify({ kind: "dream", recordId }),
        ],
      );
      const row = inserted.rows[0];
      if (row === undefined)
        throw new Error("Dream request insert returned no row.");
      return dreamRequestView(row);
    });
  }

  async claimDreamRequest(principal: Principal): Promise<DreamRequest | null> {
    await this.assertDreamerPrincipal(principal);
    return this.database.transaction(async (client) => {
      const next = await client.query<DreamRequestRow>(
        `SELECT id, source, config, status, created_at, started_at, finished_at
         FROM ingestion_jobs
         WHERE user_id = $1 AND device_id = $2
           AND source->>'kind' = 'dream'
           AND status IN ('queued', 'processing')
         ORDER BY CASE status WHEN 'processing' THEN 0 ELSE 1 END,
                  created_at, id
         LIMIT 1
         FOR UPDATE SKIP LOCKED`,
        [principal.userId, principal.deviceId],
      );
      const row = next.rows[0];
      if (row === undefined) return null;
      if (row.status === "processing") return dreamRequestView(row);
      const claimed = await client.query<DreamRequestRow>(
        `UPDATE ingestion_jobs
         SET status = 'processing', started_at = COALESCE(started_at, now())
         WHERE user_id = $1 AND device_id = $2 AND id = $3
         RETURNING id, source, config, status, created_at, started_at, finished_at`,
        [principal.userId, principal.deviceId, row.id],
      );
      return dreamRequestView(claimed.rows[0]!);
    });
  }

  async completeDreamRequest(
    principal: Principal,
    jobId: string,
    dreamRecordId: string,
  ): Promise<void> {
    assertRecordPublicId(dreamRecordId, "dream record id");
    await this.assertDreamerPrincipal(principal);
    await this.database.transaction(async (client) => {
      const record = await client.query(
        `SELECT id
         FROM records
         WHERE user_id = $1 AND public_id = $2 AND deleted_at IS NULL
           AND source_provider = 'dreamer'
         FOR SHARE`,
        [principal.userId, dreamRecordId],
      );
      if (record.rows[0] === undefined) throw dreamSourceNotFound();
      const updated = await client.query(
        `UPDATE ingestion_jobs
         SET status = 'completed',
             processed_records = 1,
             failed_records = 0,
             finished_at = now(),
             config = jsonb_set(config, '{dreamRecordId}', to_jsonb($4::text), true)
         WHERE user_id = $1 AND device_id = $2 AND id = $3
           AND source->>'kind' = 'dream'
           AND status IN ('processing', 'completed')`,
        [principal.userId, principal.deviceId, jobId, dreamRecordId],
      );
      if ((updated.rowCount ?? 0) === 0) throw dreamRequestNotFound();
    });
  }

  async failDreamRequest(
    principal: Principal,
    jobId: string,
    error: string,
  ): Promise<void> {
    await this.assertDreamerPrincipal(principal);
    const updated = await this.database.query(
      `UPDATE ingestion_jobs
       SET status = 'failed',
           processed_records = 0,
           failed_records = 1,
           finished_at = now(),
           config = jsonb_set(config, '{error}', to_jsonb($4::text), true)
       WHERE user_id = $1 AND device_id = $2 AND id = $3
         AND source->>'kind' = 'dream'
         AND status IN ('queued', 'processing')`,
      [principal.userId, principal.deviceId, jobId, error],
    );
    if ((updated.rowCount ?? 0) === 0) throw dreamRequestNotFound();
  }

  private async assertDreamerPrincipal(principal: Principal): Promise<void> {
    const source = await this.assertWorkerPrincipal(principal);
    if (source !== "DREAMER") throw workerNotFound();
  }

  private async assertWorkerPrincipal(
    principal: Principal,
  ): Promise<"THUMB_CAM" | "DREAMER"> {
    if (principal.kind !== "api_key" || principal.deviceId === undefined) {
      throw workerNotFound();
    }
    const device = await this.database.query<{
      readonly source: string | null;
    }>(
      `SELECT metadata->>'source' AS source
       FROM devices
       WHERE user_id = $1 AND id = $2 AND kind = 'agent'
         AND revoked_at IS NULL`,
      [principal.userId, principal.deviceId],
    );
    const source = device.rows[0]?.source;
    if (source !== "THUMB_CAM" && source !== "DREAMER") {
      throw workerNotFound();
    }
    return source;
  }
}

function workerRows(queryable: Queryable, userId: string, deviceId?: string) {
  return queryable.query<WorkerRow>(
    `SELECT d.id, d.name, d.revision,
            GREATEST(
              d.last_seen_at,
              (SELECT max(k.last_used_at)
               FROM api_keys k
               WHERE k.user_id = d.user_id AND k.device_id = d.id
                 AND k.revoked_at IS NULL)
            ) AS last_seen_at,
            d.metadata,
            (SELECT count(*) FROM ingestion_jobs j
             WHERE j.user_id = d.user_id AND j.device_id = d.id
               AND (d.metadata#>>'{thumbCamReset,at}' IS NULL
                 OR j.created_at >= (d.metadata#>>'{thumbCamReset,at}')::timestamptz))::bigint AS jobs,
            (SELECT count(*) FROM media_objects m
             WHERE m.user_id = d.user_id AND m.device_id = d.id
               AND m.status = 'ready'
               AND (d.metadata#>>'{thumbCamReset,at}' IS NULL
                 OR m.created_at >= (d.metadata#>>'{thumbCamReset,at}')::timestamptz))::bigint AS media,
            (SELECT count(*) FROM records r
             WHERE r.user_id = d.user_id AND r.device_id = d.id
               AND r.deleted_at IS NULL
               AND (d.metadata#>>'{thumbCamReset,at}' IS NULL
                 OR r.created_at >= (d.metadata#>>'{thumbCamReset,at}')::timestamptz))::bigint AS records,
            (SELECT count(*) FROM ingestion_job_items i
             WHERE i.user_id = d.user_id AND i.device_id = d.id
               AND i.status = 'failed'
               AND (d.metadata#>>'{thumbCamReset,at}' IS NULL
                 OR i.created_at >= (d.metadata#>>'{thumbCamReset,at}')::timestamptz))::bigint AS failed_media,
            GREATEST(
              (SELECT max(j.created_at) FROM ingestion_jobs j
               WHERE j.user_id = d.user_id AND j.device_id = d.id
                 AND (d.metadata#>>'{thumbCamReset,at}' IS NULL
                   OR j.created_at >= (d.metadata#>>'{thumbCamReset,at}')::timestamptz)),
              (SELECT max(r.created_at) FROM records r
               WHERE r.user_id = d.user_id AND r.device_id = d.id
                 AND r.deleted_at IS NULL
                 AND (d.metadata#>>'{thumbCamReset,at}' IS NULL
                   OR r.created_at >= (d.metadata#>>'{thumbCamReset,at}')::timestamptz))
            ) AS last_job_at
     FROM devices d
     WHERE d.user_id = $1
       AND d.kind = 'agent'
       AND d.revoked_at IS NULL
       AND d.metadata->>'source' IN ('THUMB_CAM', 'DREAMER')
       ${deviceId === undefined ? "" : "AND d.id = $2"}
     ORDER BY d.registered_at, d.id`,
    deviceId === undefined ? [userId] : [userId, deviceId],
  );
}

function workerView(row: WorkerRow): WorkerView {
  return {
    deviceId: row.id,
    name: row.name,
    type: workerType(row.metadata),
    revision: Number(row.revision),
    cacheGeneration: workerCacheGeneration(row.metadata),
    lastSeenAt: timestamp(row.last_seen_at),
    config: workerConfig(row.metadata),
    runtime:
      workerType(row.metadata) === "dreamer"
        ? dreamerRuntime(object(row.metadata).dreamerRuntime)
        : null,
    stats: {
      jobs: Number(row.jobs),
      media: Number(row.media),
      records: Number(row.records),
      failedMedia: Number(row.failed_media),
      lastJobAt: timestamp(row.last_job_at),
      resetAt: workerStatsResetAt(row.metadata),
    },
  };
}

function workerCacheGeneration(metadata: unknown): number {
  return integer(object(object(metadata).thumbCamReset).generation, 0);
}

function workerStatsResetAt(metadata: unknown): string | null {
  const value = object(object(metadata).thumbCamReset).at;
  return typeof value === "string" ? timestamp(value) : null;
}

function workerConfig(metadata: unknown): WorkerConfig {
  const root = object(metadata);
  const saved = object(root.worker);
  const fallback =
    workerType(metadata) === "dreamer"
      ? {
          ...DEFAULT_CONFIG,
          mountName: "Dreamer",
          pollIntervalMs: 60_000,
          descriptionPrompt:
            "Describe this image as one concise factual visual observation. Mention the subjects, setting, lighting, mood, and composition.",
        }
      : DEFAULT_CONFIG;
  return {
    enabled:
      typeof saved.enabled === "boolean" ? saved.enabled : fallback.enabled,
    mountName: text(saved.mountName, fallback.mountName),
    pollIntervalMs: integer(saved.pollIntervalMs, fallback.pollIntervalMs),
    descriptionProvider: provider(
      saved.descriptionProvider,
      fallback.descriptionProvider,
    ),
    descriptionBaseUrl: text(
      saved.descriptionBaseUrl,
      fallback.descriptionBaseUrl,
    ),
    descriptionModel: text(saved.descriptionModel, fallback.descriptionModel),
    descriptionPrompt: text(
      saved.descriptionPrompt,
      fallback.descriptionPrompt,
    ),
    embeddingProvider: provider(
      saved.embeddingProvider,
      fallback.embeddingProvider,
    ),
    embeddingBaseUrl: text(saved.embeddingBaseUrl, fallback.embeddingBaseUrl),
    embeddingModel: text(saved.embeddingModel, fallback.embeddingModel),
    whisperModel: text(saved.whisperModel, fallback.whisperModel),
    imageGenerationEnabled:
      typeof saved.imageGenerationEnabled === "boolean"
        ? saved.imageGenerationEnabled
        : fallback.imageGenerationEnabled,
    imageProvider: "mlx-studio",
    imageBaseUrl: text(saved.imageBaseUrl, fallback.imageBaseUrl),
    imageModel: text(saved.imageModel, fallback.imageModel),
    imagePromptReference: text(
      saved.imagePromptReference,
      fallback.imagePromptReference,
    ),
    imageSize: text(saved.imageSize, fallback.imageSize),
    imageSteps: integer(saved.imageSteps, fallback.imageSteps),
    imageGuidance: number(saved.imageGuidance, fallback.imageGuidance),
    imageTimeoutMs: integer(saved.imageTimeoutMs, fallback.imageTimeoutMs),
  };
}

function dreamerRuntime(value: unknown): DreamerRuntime | null {
  const saved = object(value);
  const state = saved.state;
  if (
    state !== "disabled" &&
    state !== "waiting" &&
    state !== "creating" &&
    state !== "error"
  ) {
    return null;
  }
  return {
    state,
    nextRolloverAt: nullableText(saved.nextRolloverAt),
    saros: Number.isSafeInteger(saved.saros) ? Number(saved.saros) : null,
    scheduleId: nullableText(saved.scheduleId),
    startedAt: nullableText(saved.startedAt),
    sourceRecordId: nullableText(saved.sourceRecordId),
    message: nullableText(saved.message),
  };
}

function dreamRequestView(row: DreamRequestRow): DreamRequest {
  const source = object(row.source);
  const config = object(row.config);
  return {
    jobId: row.id,
    recordId: text(source.recordId, ""),
    status: row.status,
    requestedAt: timestamp(row.created_at)!,
    startedAt: timestamp(row.started_at),
    finishedAt: timestamp(row.finished_at),
    dreamRecordId: nullableText(config.dreamRecordId),
    error: nullableText(config.error),
  };
}

function workerLogView(row: WorkerLogRow): WorkerLog {
  return {
    id: row.id,
    deviceId: row.device_id,
    level: row.level,
    message: row.message,
    context: object(row.context),
    createdAt: new Date(row.created_at).toISOString(),
  };
}

function workerType(metadata: unknown): "thumb-cam" | "dreamer" {
  return object(metadata).source === "DREAMER" ? "dreamer" : "thumb-cam";
}

function provider(
  value: unknown,
  fallback: "ollama" | "speshu",
): "ollama" | "speshu" {
  return value === "ollama" || value === "speshu" ? value : fallback;
}

function object(value: unknown): Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

function text(value: unknown, fallback: string): string {
  return typeof value === "string" && value.trim() !== "" ? value : fallback;
}

function nullableText(value: unknown): string | null {
  return typeof value === "string" && value.trim() !== "" ? value : null;
}

function integer(value: unknown, fallback: number): number {
  return Number.isSafeInteger(value) ? Number(value) : fallback;
}

function number(value: unknown, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

function timestamp(value: Date | string | null): string | null {
  return value === null ? null : new Date(value).toISOString();
}

function workerNotFound(): HttpProblem {
  return new HttpProblem({
    status: 404,
    code: "worker_not_found",
    title: "Not Found",
    type: "urn:exeligmos:problem:worker-not-found",
    detail: "The requested registered worker does not exist.",
  });
}

function dreamSourceNotFound(): HttpProblem {
  return new HttpProblem({
    status: 404,
    code: "dream_source_not_found",
    title: "Not Found",
    type: "urn:exeligmos:problem:dream-source-not-found",
    detail: "The requested dream source record does not exist.",
  });
}

function dreamRequestNotFound(): HttpProblem {
  return new HttpProblem({
    status: 404,
    code: "dream_request_not_found",
    title: "Not Found",
    type: "urn:exeligmos:problem:dream-request-not-found",
    detail: "The requested Dreamer job does not exist.",
  });
}
