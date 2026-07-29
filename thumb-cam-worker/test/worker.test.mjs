import assert from "node:assert/strict";
import test from "node:test";

import {
  batchMediaGroups,
  partitionMatureGroups,
  ThumbCamWorker,
} from "../src/worker.mjs";

test("batches large scans without splitting a Saros group", () => {
  const groups = [
    Array.from({ length: 600 }, (_, index) => ({ index })),
    Array.from({ length: 400 }, (_, index) => ({ index })),
    Array.from({ length: 2 }, (_, index) => ({ index })),
  ];

  const batches = batchMediaGroups(groups, 1_000);

  assert.deepEqual(
    batches.map((batch) => batch.map((group) => group.length)),
    [[600, 400], [2]],
  );
  assert.throws(
    () => batchMediaGroups([Array.from({ length: 1_001 })], 1_000),
    /One Saros group contains 1001 media items/,
  );
});

test("waits a full Saros after discovery and resets when a late capture joins", () => {
  const spanSeconds = 10;
  const observed = new Map();
  const first = {
    groupKey: "group-a",
    capturedAt: "2026-07-29T00:00:00.000Z",
  };
  const discoveredAt = Date.parse("2026-07-29T00:01:00.000Z");

  let result = partitionMatureGroups(
    [[first]],
    observed,
    discoveredAt,
    spanSeconds,
  );
  assert.deepEqual(result.ready, []);
  assert.equal(result.pendingUntil, discoveredAt + 10_000);

  result = partitionMatureGroups(
    [[first]],
    observed,
    discoveredAt + 10_000,
    spanSeconds,
  );
  assert.deepEqual(result.ready, [[first]]);
  assert.equal(result.pendingUntil, undefined);

  const joined = [
    { ...first, groupKey: "group-a-plus-late" },
    {
      groupKey: "group-a-plus-late",
      capturedAt: "2026-07-29T00:00:08.000Z",
    },
  ];
  result = partitionMatureGroups(
    [joined],
    observed,
    discoveredAt + 11_000,
    spanSeconds,
  );
  assert.deepEqual(result.ready, []);
  assert.equal(result.pendingUntil, discoveredAt + 21_000);
  assert.equal(observed.has("group-a"), false);
});

test("merges compact item progress responses into the local resumable job", async () => {
  const requests = [];
  const worker = new ThumbCamWorker(
    {},
    {
      client: {
        async updateJobItem(jobId, itemId, revision, patch) {
          requests.push({ jobId, itemId, revision, patch });
          return {
            id: jobId,
            revision: revision + 1,
            status: "processing",
            item: {
              id: itemId,
              status: patch.status,
              stage: patch.stage,
            },
          };
        },
      },
    },
  );
  const local = {
    id: "item-1",
    status: "queued",
    stage: "queued",
    absolutePath: "/Volumes/THUMB_CAM/PHOTO/one.jpg",
  };
  const job = {
    id: "job-1",
    revision: 7,
    status: "queued",
    items: [{ ...local }],
  };

  await worker.updateItem(job, local, {
    status: "processing",
    stage: "describing",
  });

  assert.deepEqual(requests, [
    {
      jobId: "job-1",
      itemId: "item-1",
      revision: 7,
      patch: { status: "processing", stage: "describing" },
    },
  ]);
  assert.equal(job.revision, 8);
  assert.equal(job.status, "processing");
  assert.equal(job.items[0].stage, "describing");
  assert.equal(local.stage, "describing");
  assert.equal(local.absolutePath, "/Volumes/THUMB_CAM/PHOTO/one.jpg");
});

test("renews the same processing stage while a long operation runs", async () => {
  const revisions = [];
  const worker = new ThumbCamWorker(
    {},
    {
      heartbeatIntervalMs: 5,
      client: {
        async updateJobItem(jobId, itemId, revision, patch) {
          revisions.push(revision);
          return {
            id: jobId,
            revision: revision + 1,
            status: "processing",
            item: {
              id: itemId,
              status: patch.status,
              stage: patch.stage,
            },
          };
        },
      },
    },
  );
  const item = {
    id: "item-1",
    status: "processing",
    stage: "describing",
  };
  const job = {
    id: "job-1",
    revision: 3,
    status: "processing",
    items: [{ ...item }],
  };

  const result = await worker.withHeartbeat(
    job,
    item,
    "describing",
    async () => {
      await new Promise((resolve) => setTimeout(resolve, 18));
      return "done";
    },
  );

  assert.equal(result, "done");
  assert.ok(revisions.length >= 2);
  assert.deepEqual(
    revisions,
    Array.from({ length: revisions.length }, (_, index) => 3 + index),
  );
  assert.equal(job.revision, 3 + revisions.length);
});

test("does not regress completed siblings when a resumed group fails", async () => {
  const patches = [];
  const worker = new ThumbCamWorker(
    {},
    {
      log: { error() {}, info() {} },
      client: {
        async updateJobItem(jobId, itemId, revision, patch) {
          patches.push({ itemId, patch });
          return {
            id: jobId,
            revision: revision + 1,
            status: "failed",
            item: { id: itemId, ...patch },
          };
        },
      },
    },
  );
  worker.processGroup = async () => {
    throw new Error("embedding unavailable");
  };
  const completed = {
    id: "completed",
    sourceKey: "a",
    groupKey: "group",
    capturedAt: "2026-07-29T00:00:00.000Z",
    status: "completed",
  };
  const retryable = {
    id: "retryable",
    sourceKey: "b",
    groupKey: "group",
    capturedAt: "2026-07-29T00:00:01.000Z",
    status: "processing",
    stage: "embedding",
  };
  const job = {
    id: "job",
    revision: 1,
    items: [completed, retryable],
  };

  await worker.processJob(
    job,
    new Map([
      ["a", { ...completed, absolutePath: "/camera/a" }],
      ["b", { ...retryable, absolutePath: "/camera/b" }],
    ]),
  );

  assert.deepEqual(patches, [
    {
      itemId: "retryable",
      patch: {
        status: "failed",
        stage: "embedding",
        error: "embedding unavailable",
      },
    },
  ]);
});

test("refreshes and yields a job after a competing revision wins", async () => {
  let patchCount = 0;
  let reloadCount = 0;
  const warnings = [];
  const worker = new ThumbCamWorker(
    {},
    {
      log: {
        error() {},
        info() {},
        warn(message) {
          warnings.push(message);
        },
      },
      client: {
        async updateJobItem() {
          patchCount += 1;
          throw Object.assign(new Error("precondition failed"), {
            status: 412,
          });
        },
        async getJob() {
          reloadCount += 1;
          return {
            id: "job",
            revision: 8,
            status: "processing",
            items: [
              {
                id: "item",
                sourceKey: "source",
                groupKey: "group",
                capturedAt: "2026-07-29T00:00:00.000Z",
                status: "processing",
                stage: "uploading",
              },
            ],
          };
        },
      },
    },
  );
  worker.processGroup = async (job, group) => {
    await worker.updateItem(job, group[0], {
      status: "processing",
      stage: "describing",
    });
  };
  const item = {
    id: "item",
    sourceKey: "source",
    groupKey: "group",
    capturedAt: "2026-07-29T00:00:00.000Z",
    status: "queued",
    stage: "queued",
  };
  const job = { id: "job", revision: 7, status: "queued", items: [item] };

  await worker.processJob(
    job,
    new Map([["source", { ...item, absolutePath: "/snapshots/source.wav" }]]),
  );

  assert.equal(patchCount, 1);
  assert.equal(reloadCount, 1);
  assert.equal(job.revision, 8);
  assert.equal(job.items[0].stage, "uploading");
  assert.deepEqual(warnings, [
    "Job job changed remotely; yielding it until the next poll.",
  ]);
});

test("does not submit while any supported media file is unstable", async () => {
  let createCount = 0;
  const now = Date.parse("2026-07-29T00:00:00.000Z");
  const worker = new ThumbCamWorker(
    {
      mountName: "THUMB_CAM",
      pollIntervalMs: 5_000,
      settleDelayMs: 1_500,
    },
    {
      now: () => now,
      scanVolume: async () => ({
        items: [],
        unstable: [{ relativePath: "PHOTO/recording.jpg" }],
      }),
      client: {
        async listJobs() {
          return { data: [], hasMore: false };
        },
        async createJob() {
          createCount += 1;
        },
      },
      log: { error() {}, info() {}, warn() {} },
    },
  );

  const retryAt = await worker.processMountedVolume();

  assert.equal(createCount, 0);
  assert.equal(retryAt, now + 5_000);
});
