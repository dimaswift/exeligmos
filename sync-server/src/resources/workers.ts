import type { QueryResultRow } from "pg";

import type { Principal } from "../auth/principal.js";
import type { Database, Queryable } from "../db/database.js";
import { HttpProblem } from "../http/problem.js";
import {
  requireMatchingEtag,
  resourceEtag,
} from "./shared.js";

export interface WorkerConfig {
  readonly enabled: boolean;
  readonly mountName: string;
  readonly descriptionModel: string;
  readonly descriptionPrompt: string;
  readonly embeddingModel: string;
  readonly whisperModel: string;
}

export type WorkerConfigPatch = Partial<WorkerConfig>;

export interface WorkerView {
  readonly deviceId: string;
  readonly name: string;
  readonly revision: number;
  readonly lastSeenAt: string | null;
  readonly config: WorkerConfig;
  readonly stats: {
    readonly jobs: number;
    readonly media: number;
    readonly records: number;
    readonly failedMedia: number;
    readonly lastJobAt: string | null;
  };
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

const DEFAULT_CONFIG: WorkerConfig = {
  enabled: true,
  mountName: "THUMB_CAM",
  descriptionModel: "gemma4",
  descriptionPrompt:
    "describe the image from 1st person perspective as if you have captured it yourself in present tense, like an entry in the diary. Keep it short and informative",
  embeddingModel: "embeddinggemma",
  whisperModel: "medium",
};

export class WorkerService {
  constructor(private readonly database: Database) {}

  async list(userId: string): Promise<{ readonly data: readonly WorkerView[] }> {
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
        detail: "The current worker configuration requires a device-bound API key.",
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
           AND (name = 'THUMB' OR metadata->>'source' = 'THUMB_CAM')
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
}

function workerRows(
  queryable: Queryable,
  userId: string,
  deviceId?: string,
) {
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
             WHERE j.user_id = d.user_id AND j.device_id = d.id)::bigint AS jobs,
            (SELECT count(*) FROM media_objects m
             WHERE m.user_id = d.user_id AND m.device_id = d.id
               AND m.status = 'ready')::bigint AS media,
            (SELECT count(*) FROM records r
             WHERE r.user_id = d.user_id AND r.device_id = d.id
               AND r.deleted_at IS NULL)::bigint AS records,
            (SELECT count(*) FROM ingestion_job_items i
             WHERE i.user_id = d.user_id AND i.device_id = d.id
               AND i.status = 'failed')::bigint AS failed_media,
            (SELECT max(j.created_at) FROM ingestion_jobs j
             WHERE j.user_id = d.user_id AND j.device_id = d.id) AS last_job_at
     FROM devices d
     WHERE d.user_id = $1
       AND d.kind = 'agent'
       AND d.revoked_at IS NULL
       AND (d.name = 'THUMB' OR d.metadata->>'source' = 'THUMB_CAM')
       ${deviceId === undefined ? "" : "AND d.id = $2"}
     ORDER BY d.registered_at, d.id`,
    deviceId === undefined ? [userId] : [userId, deviceId],
  );
}

function workerView(row: WorkerRow): WorkerView {
  return {
    deviceId: row.id,
    name: row.name,
    revision: Number(row.revision),
    lastSeenAt: timestamp(row.last_seen_at),
    config: workerConfig(row.metadata),
    stats: {
      jobs: Number(row.jobs),
      media: Number(row.media),
      records: Number(row.records),
      failedMedia: Number(row.failed_media),
      lastJobAt: timestamp(row.last_job_at),
    },
  };
}

function workerConfig(metadata: unknown): WorkerConfig {
  const root = object(metadata);
  const saved = object(root.worker);
  return {
    enabled: typeof saved.enabled === "boolean" ? saved.enabled : DEFAULT_CONFIG.enabled,
    mountName: text(saved.mountName, DEFAULT_CONFIG.mountName),
    descriptionModel: text(saved.descriptionModel, DEFAULT_CONFIG.descriptionModel),
    descriptionPrompt: text(saved.descriptionPrompt, DEFAULT_CONFIG.descriptionPrompt),
    embeddingModel: text(saved.embeddingModel, DEFAULT_CONFIG.embeddingModel),
    whisperModel: text(saved.whisperModel, DEFAULT_CONFIG.whisperModel),
  };
}

function object(value: unknown): Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

function text(value: unknown, fallback: string): string {
  return typeof value === "string" && value.trim() !== "" ? value : fallback;
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
