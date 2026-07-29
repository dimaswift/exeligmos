import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import test from "node:test";

import { Client } from "pg";

import { buildApp } from "../../src/app.js";
import { NOOP_AUTH_ATTEMPT_LIMITER } from "../../src/auth/rate-limit.js";
import { createPostgresDatabase } from "../../src/db/database.js";
import { ensureDatabaseSchema } from "../../src/db/setup.js";
import { NOOP_RESOURCE_REQUEST_LIMITER } from "../../src/resources/rate-limit.js";
import { testConfig } from "../helpers.js";

const databaseUrl = process.env.TEST_DATABASE_URL?.trim();

test(
  "ingestion jobs durably deduplicate files, track retries, and store current-revision embeddings",
  { skip: databaseUrl === undefined || databaseUrl.length === 0 },
  async () => {
    assert.ok(databaseUrl);
    await ensureDatabaseSchema({ databaseUrl });
    const baseConfig = testConfig();
    const config = {
      ...baseConfig,
      database: { ...baseConfig.database, url: databaseUrl },
    };
    const database = createPostgresDatabase(config.database);
    const app = buildApp({
      config,
      database,
      authAttemptLimiter: NOOP_AUTH_ATTEMPT_LIMITER,
      resourceRequestLimiter: NOOP_RESOURCE_REQUEST_LIMITER,
    });
    const sql = new Client({ connectionString: databaseUrl });
    await sql.connect();
    await app.ready();

    let userId: string | undefined;
    try {
      const owner = await register(app, `jobs-${randomUUID()}`);
      userId = owner.userId;
      const thumb = await createDevice(app, owner.accessToken, "THUMB");
      const key = await issueApiKey(app, owner.accessToken, thumb.id, [
        "jobs:read",
        "jobs:write",
        "records:read",
        "records:write",
      ]);
      const otherThumb = await createDevice(
        app,
        owner.accessToken,
        "OTHER_THUMB",
      );
      const otherKey = await issueApiKey(
        app,
        owner.accessToken,
        otherThumb.id,
        ["jobs:write", "records:write"],
      );
      const sourceKey1 = "1".repeat(64);
      const sourceKey2 = "2".repeat(64);
      const groupKey = "a".repeat(64);
      const createPayload = {
        deviceId: thumb.id,
        source: { volume: "THUMB_CAM" },
        config: {
          descriptionModel: "gemma4",
          prompt: "Short first-person diary entry.",
        },
        items: [
          {
            sourceKey: sourceKey1,
            groupKey,
            relativePath: "PHOTO/IMG_0001.JPG",
            kind: "photo",
            capturedAt: "2026-07-29T08:14:22Z",
            byteLength: 120,
            contentSha256: "b".repeat(64),
          },
          {
            sourceKey: sourceKey2,
            groupKey,
            relativePath: "AUDIO/AUD_0001.WAV",
            kind: "audio",
            capturedAt: "2026-07-29T08:15:10Z",
            byteLength: 240,
            contentSha256: "c".repeat(64),
          },
        ],
      };
      const createKey = `create-job-${randomUUID()}`;
      const created = await app.inject({
        method: "POST",
        url: "/jobs",
        headers: mutationHeaders(key, createKey),
        payload: createPayload,
      });
      assert.equal(created.statusCode, 201, created.body);
      const createdBody = created.json<
        JobDetail & {
          skippedItems: readonly SkippedItem[];
        }
      >();
      assert.equal(createdBody.status, "queued");
      assert.equal("activity" in createdBody, false);
      assert.equal(createdBody.totalItems, 2);
      assert.equal(createdBody.processedItems, 0);
      assert.equal(createdBody.remainingItems, 2);
      assert.equal(createdBody.totalRecords, 1);
      assert.equal(createdBody.processedRecords, 0);
      assert.equal(createdBody.items.length, 2);
      assert.deepEqual(createdBody.skippedItems, []);
      let jobEtag = requiredResponseHeader(created.headers.etag);
      assert.equal(jobEtag, `"job-${createdBody.id}-r${createdBody.revision}"`);

      const replay = await app.inject({
        method: "POST",
        url: "/jobs",
        headers: mutationHeaders(key, createKey),
        payload: createPayload,
      });
      assert.equal(replay.statusCode, 201, replay.body);
      assert.deepEqual(replay.json(), createdBody);

      const second = await app.inject({
        method: "POST",
        url: "/jobs",
        headers: mutationHeaders(key, `create-job-${randomUUID()}`),
        payload: {
          ...createPayload,
          items: [
            createPayload.items[0],
            {
              ...createPayload.items[1],
              sourceKey: "3".repeat(64),
              groupKey: "d".repeat(64),
              relativePath: "VIDEO/VID_0001.MP4",
              kind: "video",
            },
          ],
        },
      });
      assert.equal(second.statusCode, 201, second.body);
      const secondBody = second.json<
        JobDetail & {
          skippedItems: readonly SkippedItem[];
        }
      >();
      assert.equal(secondBody.totalItems, 1);
      assert.equal(secondBody.items.length, 1);
      assert.deepEqual(secondBody.skippedItems, [
        {
          sourceKey: sourceKey1,
          existingJobId: createdBody.id,
          existingItemId: createdBody.items[0]?.id,
          status: "queued",
        },
      ]);

      const listed = await app.inject({
        method: "GET",
        url: "/jobs?status=queued",
        headers: bearer(key),
      });
      assert.equal(listed.statusCode, 200, listed.body);
      assert.ok(
        listed
          .json<{ data: readonly JobSummary[] }>()
          .data.some((job) => job.id === createdBody.id),
      );

      const firstItem = requiredItem(createdBody.items[0]);
      const firstProgressKey = `job-progress-${randomUUID()}`;
      const firstProgressPatch = {
        status: "processing",
        stage: "transforming",
        outputMode: "single_positive",
      } as const;
      let progress = await patchItem(
        app,
        key,
        createdBody.id,
        firstItem.id,
        jobEtag,
        firstProgressPatch,
        firstProgressKey,
      );
      assert.equal(progress.body.status, "processing");
      assert.equal("activity" in progress.body, false);
      assert.equal(progress.body.currentItem?.id, firstItem.id);
      assert.equal(progress.body.currentItem?.outputMode, "single_positive");
      assert.equal(progress.body.item.id, firstItem.id);
      assert.equal("items" in progress.body, false);
      const crossDeviceReplay = await app.inject({
        method: "PATCH",
        url: `/jobs/${createdBody.id}/items/${firstItem.id}`,
        headers: conditionalHeaders(otherKey, jobEtag, firstProgressKey),
        payload: firstProgressPatch,
      });
      assert.equal(crossDeviceReplay.statusCode, 409, crossDeviceReplay.body);
      assert.equal(crossDeviceReplay.json().code, "idempotency_conflict");
      jobEtag = progress.etag;

      await sql.query(
        `UPDATE ingestion_job_items
         SET updated_at = clock_timestamp() - interval '121 seconds'
         WHERE user_id = $1 AND job_id = $2 AND id = $3`,
        [owner.userId, createdBody.id, firstItem.id],
      );
      const staleDetail = await app.inject({
        method: "GET",
        url: `/jobs/${createdBody.id}`,
        headers: bearer(key),
      });
      assert.equal(staleDetail.statusCode, 200, staleDetail.body);
      assert.equal("activity" in staleDetail.json<JobDetail>(), false);
      const staleList = await app.inject({
        method: "GET",
        url: "/jobs?status=processing",
        headers: bearer(key),
      });
      assert.equal(staleList.statusCode, 200, staleList.body);
      assert.equal(
        staleList
          .json<{ data: readonly JobSummary[] }>()
          .data.find((job) => job.id === createdBody.id)?.activity,
        "idle",
      );
      const noActiveJobs = await app.inject({
        method: "GET",
        url: "/jobs?activity=active",
        headers: bearer(key),
      });
      assert.equal(noActiveJobs.statusCode, 200, noActiveJobs.body);
      assert.equal(
        noActiveJobs
          .json<{ data: readonly JobSummary[] }>()
          .data.some((job) => job.id === createdBody.id),
        false,
      );
      progress = await patchItem(
        app,
        key,
        createdBody.id,
        firstItem.id,
        jobEtag,
        {
          status: "processing",
          stage: "transforming",
          outputMode: "single_positive",
        },
      );
      assert.equal("activity" in progress.body, false);
      jobEtag = progress.etag;
      const activeJobs = await app.inject({
        method: "GET",
        url: "/jobs?activity=active",
        headers: bearer(key),
      });
      assert.equal(activeJobs.statusCode, 200, activeJobs.body);
      const activeJobPage = activeJobs.json<{ data: readonly JobSummary[] }>();
      assert.ok(activeJobPage.data.some((job) => job.id === createdBody.id));
      assert.ok(activeJobPage.data.every((job) => job.activity === "active"));

      const expiredUploadId = randomUUID();
      const replacementUploadId = randomUUID();
      await insertUpload(
        sql,
        owner.userId,
        thumb.id,
        expiredUploadId,
        "expired-photo.jpg",
      );
      await insertUpload(
        sql,
        owner.userId,
        thumb.id,
        replacementUploadId,
        "replacement-photo.jpg",
      );
      progress = await patchItem(
        app,
        key,
        createdBody.id,
        firstItem.id,
        jobEtag,
        {
          status: "processing",
          stage: "uploading",
          outputMode: "single_positive",
          uploadId: expiredUploadId,
        },
      );
      jobEtag = progress.etag;
      await sql.query(
        `UPDATE media_upload_sessions
         SET status = 'expired',
             aborted_at = clock_timestamp()
         WHERE user_id = $1 AND id = $2`,
        [owner.userId, expiredUploadId],
      );

      progress = await patchItem(
        app,
        key,
        createdBody.id,
        firstItem.id,
        jobEtag,
        {
          status: "failed",
          stage: "failed",
          error: "camera was disconnected",
        },
      );
      assert.equal(progress.body.status, "queued");
      assert.equal(progress.body.failedItems, 1);
      assert.equal(progress.body.remainingItems, 2);
      assert.equal(progress.body.currentItem?.id, firstItem.id);
      assert.equal(progress.body.currentItem?.status, "failed");
      assert.equal(progress.body.currentItem?.error, "camera was disconnected");
      jobEtag = progress.etag;

      const changedOutput = await app.inject({
        method: "PATCH",
        url: `/jobs/${createdBody.id}/items/${firstItem.id}`,
        headers: conditionalHeaders(
          key,
          jobEtag,
          `job-progress-${randomUUID()}`,
        ),
        payload: {
          status: "processing",
          stage: "transforming",
          outputMode: "double",
        },
      });
      assert.equal(changedOutput.statusCode, 409, changedOutput.body);
      assert.equal(changedOutput.json().code, "job_item_output_conflict");

      progress = await patchItem(
        app,
        key,
        createdBody.id,
        firstItem.id,
        jobEtag,
        {
          status: "processing",
          stage: "transforming",
          outputMode: "single_positive",
          uploadId: replacementUploadId,
        },
      );
      assert.equal(progress.body.failedItems, 0);
      assert.equal(progress.body.status, "processing");
      assert.equal(progress.body.item.uploadId, replacementUploadId);
      jobEtag = progress.etag;

      const mediaId1 = randomUUID();
      const mediaId2 = randomUUID();
      await insertMedia(
        sql,
        owner.userId,
        thumb.id,
        mediaId1,
        "photo.jpg",
        "image/jpeg",
      );
      await insertMedia(
        sql,
        owner.userId,
        thumb.id,
        mediaId2,
        "audio.wav",
        "audio/wav",
      );
      const recordText = "I capture a quiet moment with the camera.";
      const record = await app.inject({
        method: "POST",
        url: "/records",
        headers: mutationHeaders(key, `record-${randomUUID()}`),
        payload: {
          deviceId: thumb.id,
          occurredAt: createPayload.items[0]!.capturedAt,
          payload: { text: recordText, emoji: "📷" },
          mediaIds: [mediaId1, mediaId2],
          source: {
            kind: "agent",
            provider: "thumb-cam",
            externalId: groupKey,
          },
        },
      });
      assert.equal(record.statusCode, 201, record.body);
      const recordBody = record.json<{
        id: string;
        revision: number;
      }>();

      progress = await patchItem(
        app,
        key,
        createdBody.id,
        firstItem.id,
        jobEtag,
        {
          status: "completed",
          stage: "completed",
          mediaId: mediaId1,
          recordId: recordBody.id,
        },
      );
      assert.equal(progress.body.processedItems, 1);
      assert.equal(progress.body.processedRecords, 0);
      assert.equal(progress.body.status, "queued");
      jobEtag = progress.etag;

      const secondItem = requiredItem(createdBody.items[1]);
      progress = await patchItem(
        app,
        key,
        createdBody.id,
        secondItem.id,
        jobEtag,
        { status: "processing", stage: "transcribing" },
      );
      jobEtag = progress.etag;
      const conflictingRecord = await app.inject({
        method: "POST",
        url: "/records",
        headers: mutationHeaders(key, `record-${randomUUID()}`),
        payload: {
          deviceId: thumb.id,
          occurredAt: createPayload.items[1]!.capturedAt,
          payload: { text: "A conflicting grouped record.", emoji: "🎙️" },
          mediaIds: [mediaId2],
          source: {
            kind: "agent",
            provider: "thumb-cam",
            externalId: "e".repeat(64),
          },
        },
      });
      assert.equal(conflictingRecord.statusCode, 201, conflictingRecord.body);
      const conflictingRecordId = conflictingRecord.json<{ id: string }>().id;
      const groupConflict = await app.inject({
        method: "PATCH",
        url: `/jobs/${createdBody.id}/items/${secondItem.id}`,
        headers: conditionalHeaders(
          key,
          jobEtag,
          `job-progress-${randomUUID()}`,
        ),
        payload: {
          status: "completed",
          stage: "completed",
          mediaId: mediaId2,
          recordId: conflictingRecordId,
        },
      });
      assert.equal(groupConflict.statusCode, 409, groupConflict.body);
      assert.equal(groupConflict.json().code, "job_group_record_conflict");
      progress = await patchItem(
        app,
        key,
        createdBody.id,
        secondItem.id,
        jobEtag,
        {
          status: "completed",
          stage: "completed",
          mediaId: mediaId2,
          recordId: recordBody.id,
        },
      );
      assert.equal(progress.body.status, "completed");
      assert.equal("activity" in progress.body, false);
      assert.equal(progress.body.processedItems, 2);
      assert.equal(progress.body.remainingItems, 0);
      assert.equal(progress.body.processedRecords, 1);
      assert.equal(progress.body.remainingRecords, 0);
      assert.equal(progress.body.currentItem, null);
      assert.ok(progress.body.finishedAt);

      const embeddingRequest = {
        recordRevision: recordBody.revision,
        model: "embeddinggemma",
        contentHash: createHash("sha256")
          .update(recordText, "utf8")
          .digest("hex"),
        vector: [0.25, -0.5, 0.75],
      };
      const embeddingKey = `embedding-${randomUUID()}`;
      const embedding = await app.inject({
        method: "PUT",
        url: `/records/${recordBody.id}/embeddings`,
        headers: mutationHeaders(key, embeddingKey),
        payload: embeddingRequest,
      });
      assert.equal(embedding.statusCode, 200, embedding.body);
      assert.deepEqual(
        embedding.json<{
          recordId: string;
          recordRevision: number;
          model: string;
          dimensions: number;
          contentHash: string;
        }>(),
        {
          recordId: recordBody.id,
          recordRevision: recordBody.revision,
          model: "embeddinggemma",
          dimensions: 3,
          contentHash: embeddingRequest.contentHash,
          createdAt: embedding.json().createdAt,
        },
      );
      const embeddingReplay = await app.inject({
        method: "PUT",
        url: `/records/${recordBody.id}/embeddings`,
        headers: mutationHeaders(key, embeddingKey),
        payload: embeddingRequest,
      });
      assert.equal(embeddingReplay.statusCode, 200, embeddingReplay.body);
      assert.deepEqual(embeddingReplay.json(), embedding.json());

      const stored = await sql.query<{
        dimensions: number;
        content_hash: string;
      }>(
        `SELECT dimensions, encode(content_hash, 'hex') AS content_hash
         FROM record_embeddings embedding
         JOIN records record ON record.id = embedding.record_id
         WHERE record.user_id = $1 AND record.public_id = $2
           AND embedding.model_key = 'embeddinggemma'`,
        [owner.userId, recordBody.id],
      );
      assert.deepEqual(stored.rows, [
        { dimensions: 3, content_hash: embeddingRequest.contentHash },
      ]);

      const wrongHash = await app.inject({
        method: "PUT",
        url: `/records/${recordBody.id}/embeddings`,
        headers: mutationHeaders(key, `embedding-${randomUUID()}`),
        payload: { ...embeddingRequest, contentHash: "f".repeat(64) },
      });
      assert.equal(wrongHash.statusCode, 422, wrongHash.body);
      assert.equal(wrongHash.json().code, "embedding_content_hash_mismatch");

      const orderingJob = await app.inject({
        method: "POST",
        url: "/jobs",
        headers: mutationHeaders(key, `create-job-${randomUUID()}`),
        payload: {
          ...createPayload,
          items: [
            {
              ...createPayload.items[0],
              sourceKey: "4".repeat(64),
              groupKey: "4".repeat(64),
              relativePath: "PHOTO/ORDER_0001.JPG",
            },
            {
              ...createPayload.items[0],
              sourceKey: "5".repeat(64),
              groupKey: "5".repeat(64),
              relativePath: "PHOTO/ORDER_0002.JPG",
            },
          ],
        },
      });
      assert.equal(orderingJob.statusCode, 201, orderingJob.body);
      const orderingBody = orderingJob.json<JobDetail>();
      const orderingFirst = requiredItem(orderingBody.items[0]);
      const orderingSecond = requiredItem(orderingBody.items[1]);
      let orderingEtag = requiredResponseHeader(orderingJob.headers.etag);
      let orderingProgress = await patchItem(
        app,
        key,
        orderingBody.id,
        orderingFirst.id,
        orderingEtag,
        { status: "processing", stage: "first" },
      );
      orderingEtag = orderingProgress.etag;
      orderingProgress = await patchItem(
        app,
        key,
        orderingBody.id,
        orderingSecond.id,
        orderingEtag,
        { status: "processing", stage: "second" },
      );
      orderingEtag = orderingProgress.etag;
      assert.equal(orderingProgress.body.currentItem?.id, orderingSecond.id);
      let orderingDetail = await app.inject({
        method: "GET",
        url: `/jobs/${orderingBody.id}`,
        headers: bearer(key),
      });
      assert.equal(orderingDetail.statusCode, 200, orderingDetail.body);
      assert.equal(
        orderingDetail.json<JobDetail>().currentItem?.id,
        orderingSecond.id,
      );
      let orderingList = await app.inject({
        method: "GET",
        url: "/jobs?status=processing",
        headers: bearer(key),
      });
      assert.equal(orderingList.statusCode, 200, orderingList.body);
      assert.equal(
        orderingList
          .json<{ data: readonly JobSummary[] }>()
          .data.find((job) => job.id === orderingBody.id)?.currentItem?.id,
        orderingSecond.id,
      );

      orderingProgress = await patchItem(
        app,
        key,
        orderingBody.id,
        orderingFirst.id,
        orderingEtag,
        { status: "processing", stage: "first_heartbeat" },
      );
      assert.equal(orderingProgress.body.currentItem?.id, orderingFirst.id);
      orderingDetail = await app.inject({
        method: "GET",
        url: `/jobs/${orderingBody.id}`,
        headers: bearer(key),
      });
      orderingList = await app.inject({
        method: "GET",
        url: "/jobs?status=processing",
        headers: bearer(key),
      });
      assert.equal(
        orderingDetail.json<JobDetail>().currentItem?.id,
        orderingFirst.id,
      );
      assert.equal(
        orderingList
          .json<{ data: readonly JobSummary[] }>()
          .data.find((job) => job.id === orderingBody.id)?.currentItem?.id,
        orderingFirst.id,
      );
    } finally {
      if (userId !== undefined) {
        await sql.query("DELETE FROM record_media WHERE user_id = $1", [
          userId,
        ]);
        await sql.query("DELETE FROM users WHERE id = $1", [userId]);
      }
      await app.close();
      await sql.end();
    }
  },
);

interface Registration {
  readonly accessToken: string;
  readonly userId: string;
}

interface JobItem {
  readonly id: string;
  readonly status: "queued" | "processing" | "completed" | "failed";
  readonly outputMode?: string;
  readonly uploadId?: string;
  readonly error?: string;
}

interface JobDetail {
  readonly id: string;
  readonly status: "queued" | "processing" | "completed" | "failed";
  readonly totalItems: number;
  readonly processedItems: number;
  readonly failedItems: number;
  readonly remainingItems: number;
  readonly totalRecords: number;
  readonly processedRecords: number;
  readonly remainingRecords: number;
  readonly currentItem: (JobItem & { readonly outputMode?: string }) | null;
  readonly revision: number;
  readonly items: readonly JobItem[];
  readonly finishedAt?: string;
}

interface JobSummary extends Omit<JobDetail, "items"> {
  readonly activity: "active" | "idle";
}

interface JobMutation extends Omit<JobDetail, "items"> {
  readonly item: JobItem;
}

interface SkippedItem {
  readonly sourceKey: string;
  readonly existingJobId: string;
  readonly existingItemId: string;
  readonly status: string;
}

async function register(
  app: ReturnType<typeof buildApp>,
  login: string,
): Promise<Registration> {
  const response = await app.inject({
    method: "POST",
    url: "/auth/register",
    payload: {
      login,
      password: "correct horse battery staple",
      displayName: login,
    },
  });
  assert.equal(response.statusCode, 201, response.body);
  const body = response.json<{
    accessToken: string;
    user: { id: string };
  }>();
  return { accessToken: body.accessToken, userId: body.user.id };
}

async function createDevice(
  app: ReturnType<typeof buildApp>,
  accessToken: string,
  name: string,
): Promise<{ readonly id: string }> {
  const response = await app.inject({
    method: "POST",
    url: "/devices",
    headers: mutationHeaders(accessToken, `device-${randomUUID()}`),
    payload: { name, kind: "agent" },
  });
  assert.equal(response.statusCode, 201, response.body);
  return response.json<{ id: string }>();
}

async function issueApiKey(
  app: ReturnType<typeof buildApp>,
  accessToken: string,
  deviceId: string,
  scopes: readonly string[],
): Promise<string> {
  const response = await app.inject({
    method: "POST",
    url: "/api-keys",
    headers: mutationHeaders(accessToken, `api-key-${randomUUID()}`),
    payload: {
      name: `Key ${randomUUID()}`,
      deviceId,
      scopes,
    },
  });
  assert.equal(response.statusCode, 201, response.body);
  return response.json<{ secret: string }>().secret;
}

async function insertMedia(
  sql: Client,
  userId: string,
  deviceId: string,
  mediaId: string,
  fileName: string,
  contentType: string,
): Promise<void> {
  await sql.query(
    `INSERT INTO media_objects (
       id, user_id, device_id, visibility, status, file_name, content_type,
       byte_size, sha256, storage_key
     ) VALUES ($1, $2, $3, 'public', 'ready', $4, $5, 4, $6, $7)`,
    [
      mediaId,
      userId,
      deviceId,
      fileName,
      contentType,
      Buffer.alloc(32, mediaId === mediaId.toLowerCase() ? 1 : 2),
      `media/${userId}/${mediaId}.blob`,
    ],
  );
}

async function insertUpload(
  sql: Client,
  userId: string,
  deviceId: string,
  uploadId: string,
  fileName: string,
): Promise<void> {
  await sql.query(
    `INSERT INTO media_upload_sessions (
       id, user_id, device_id, status, file_name, content_type, byte_size,
       sha256, temporary_storage_key, expires_at
     ) VALUES (
       $1, $2, $3, 'reserved', $4, 'image/jpeg', 4, $5, $6,
       clock_timestamp() + interval '10 minutes'
     )`,
    [
      uploadId,
      userId,
      deviceId,
      fileName,
      Buffer.alloc(32, 7),
      `uploads/${userId}/${uploadId}.blob`,
    ],
  );
}

async function patchItem(
  app: ReturnType<typeof buildApp>,
  token: string,
  jobId: string,
  itemId: string,
  etag: string,
  payload: Readonly<Record<string, unknown>>,
  idempotencyKey = `job-progress-${randomUUID()}`,
): Promise<{ readonly body: JobMutation; readonly etag: string }> {
  const response = await app.inject({
    method: "PATCH",
    url: `/jobs/${jobId}/items/${itemId}`,
    headers: conditionalHeaders(token, etag, idempotencyKey),
    payload,
  });
  assert.equal(response.statusCode, 200, response.body);
  const body = response.json<JobMutation>();
  const nextEtag = requiredResponseHeader(response.headers.etag);
  assert.equal(nextEtag, `"job-${jobId}-r${body.revision}"`);
  return { body, etag: nextEtag };
}

function requiredItem(item: JobItem | undefined): JobItem {
  assert.ok(item);
  return item;
}

function bearer(token: string): Readonly<Record<string, string>> {
  return { authorization: `Bearer ${token}` };
}

function mutationHeaders(
  token: string,
  key: string,
): Readonly<Record<string, string>> {
  return { ...bearer(token), "idempotency-key": key };
}

function conditionalHeaders(
  token: string,
  etag: string,
  key: string,
): Readonly<Record<string, string>> {
  return {
    ...mutationHeaders(token, key),
    "if-match": etag,
  };
}

function requiredResponseHeader(value: string | string[] | undefined): string {
  if (typeof value !== "string") {
    assert.fail("Expected a single response header value");
  }
  return value;
}
