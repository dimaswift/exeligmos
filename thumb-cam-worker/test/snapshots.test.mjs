import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  appendFile,
  mkdtemp,
  readFile,
  readdir,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test, { afterEach } from "node:test";

import {
  copySnapshotBytes,
  SnapshotStore,
  snapshotPathFor,
} from "../src/snapshots.mjs";
import { ThumbCamWorker } from "../src/worker.mjs";

const temporaryDirectories = [];

afterEach(async () => {
  await Promise.all(
    temporaryDirectories
      .splice(0)
      .map((directory) => rm(directory, { force: true, recursive: true })),
  );
});

test("rejects a source that changes while its snapshot is copied", async () => {
  const root = await temporaryRoot();
  const sourcePath = path.join(root, "camera.jpg");
  const original = Buffer.from("camera-original-bytes");
  const changed = Buffer.from("camera-mutated--bytes");
  assert.equal(changed.length, original.length);
  await writeFile(sourcePath, original);
  const item = declaration(sourcePath, original, "PHOTO/camera.jpg");
  let copiedFirstHalf = false;
  const store = new SnapshotStore(
    { workRoot: path.join(root, "work"), snapshotConcurrency: 1 },
    {
      copy: async (source, destination) => {
        const first = (await readFile(source)).subarray(
          0,
          Math.floor(original.length / 2),
        );
        await writeFile(destination, first, { flag: "wx", mode: 0o600 });
        copiedFirstHalf = true;
        await writeFile(source, changed);
        const second = (await readFile(source)).subarray(first.length);
        await appendFile(destination, second);
        const bytes = await readFile(destination);
        return {
          byteLength: bytes.length,
          contentSha256: sha256(bytes),
        };
      },
    },
  );

  await assert.rejects(
    store.ensure(item, sourcePath),
    /Source changed while snapshotting PHOTO\/camera.jpg/,
  );

  assert.equal(copiedFirstHalf, true);
  await assert.rejects(stat(snapshotPathFor(store.root, item)), {
    code: "ENOENT",
  });
  const shard = path.dirname(snapshotPathFor(store.root, item));
  assert.deepEqual(await readdir(shard), []);
});

test("reuses a verified snapshot for an unfinished remote item after the source disappears", async () => {
  const root = await temporaryRoot();
  const sourcePath = path.join(root, "voice.wav");
  const content = Buffer.from("durable voice bytes");
  await writeFile(sourcePath, content);
  const item = {
    ...declaration(sourcePath, content, "AUDIO/voice.wav"),
    id: "item-one",
    groupKey: "b".repeat(64),
    kind: "audio",
    capturedAt: "2026-07-29T00:00:00.000Z",
    status: "failed",
    stage: "transcribing",
  };
  const store = new SnapshotStore({
    workRoot: path.join(root, "work"),
    snapshotConcurrency: 1,
  });
  const sourceBefore = await stat(sourcePath);
  const first = await store.ensure(item, sourcePath);
  const sourceAfter = await stat(sourcePath);
  assert.deepEqual(await readFile(sourcePath), content);
  assert.equal(sourceAfter.size, sourceBefore.size);
  assert.equal(sourceAfter.mode, sourceBefore.mode);
  assert.equal(sourceAfter.mtimeMs, sourceBefore.mtimeMs);
  await rm(sourcePath);
  const worker = new ThumbCamWorker(
    { workRoot: path.join(root, "work") },
    {
      snapshotStore: store,
      client: {},
      log: { info() {}, warn() {}, error() {} },
    },
  );

  const job = { id: "job-one", revision: 1, items: [{ ...item }] };
  const snapshots = await worker.resolveJobSnapshots(job, new Map());

  assert.equal(snapshots.get(item.sourceKey).absolutePath, first.absolutePath);
  assert.deepEqual(await readFile(first.absolutePath), content);
  let processedPath;
  worker.processGroup = async (_job, group) => {
    processedPath = group[0].absolutePath;
    group[0].status = "completed";
  };
  await worker.processJob(job, snapshots);
  assert.equal(processedPath, first.absolutePath);
});

test("refuses to process media directly from the mounted camera", async () => {
  const root = await temporaryRoot();
  const content = Buffer.from("local-only processing");
  const cameraPath = path.join(root, "camera.avi");
  await writeFile(cameraPath, content);
  const item = declaration(cameraPath, content, "VIDEO/camera.avi");
  const store = new SnapshotStore({
    workRoot: path.join(root, "work"),
    snapshotConcurrency: 1,
  });
  const snapshot = await store.ensure(item, cameraPath);

  assert.throws(
    () => store.assertProcessingPath(item),
    /restricted to the local verified snapshot/,
  );
  assert.doesNotThrow(() => store.assertProcessingPath(snapshot));
});

test("removes snapshots when a completed job is replayed", async () => {
  const root = await temporaryRoot();
  const sourcePath = path.join(root, "photo.jpg");
  const content = Buffer.from("completed photo bytes");
  await writeFile(sourcePath, content);
  const item = {
    ...declaration(sourcePath, content, "PHOTO/photo.jpg"),
    id: "item-completed",
    groupKey: "c".repeat(64),
    kind: "photo",
    capturedAt: "2026-07-29T00:00:00.000Z",
    status: "completed",
    stage: "completed",
  };
  const store = new SnapshotStore({
    workRoot: path.join(root, "work"),
    snapshotConcurrency: 1,
  });
  const snapshot = await store.ensure(item, sourcePath);
  const worker = new ThumbCamWorker(
    { workRoot: path.join(root, "work") },
    {
      snapshotStore: store,
      client: {
        async listJobs() {
          return {
            data: [{ id: "job-completed", status: "completed" }],
            hasMore: false,
          };
        },
        async getJob() {
          return {
            id: "job-completed",
            status: "completed",
            items: [item],
          };
        },
      },
      log: { info() {}, warn() {}, error() {} },
    },
  );

  await worker.resumeJobs(new Map());

  await assert.rejects(stat(snapshot.absolutePath), { code: "ENOENT" });
  assert.equal(worker.completedSourceKeys.has(item.sourceKey), true);
});

test("retains a failed group snapshot and removes it after completion", async () => {
  const root = await temporaryRoot();
  const sourcePath = path.join(root, "retry.wav");
  const content = Buffer.from("retryable audio bytes");
  await writeFile(sourcePath, content);
  const item = {
    ...declaration(sourcePath, content, "AUDIO/retry.wav"),
    id: "item-retry",
    groupKey: "d".repeat(64),
    kind: "audio",
    capturedAt: "2026-07-29T00:00:00.000Z",
    status: "queued",
    stage: "queued",
  };
  const store = new SnapshotStore({
    workRoot: path.join(root, "work"),
    snapshotConcurrency: 1,
  });
  const snapshot = await store.ensure(item, sourcePath);
  const job = { id: "job-retry", revision: 1, items: [{ ...item }] };
  const worker = new ThumbCamWorker(
    { workRoot: path.join(root, "work") },
    {
      snapshotStore: store,
      client: {
        async updateJobItem(jobId, itemId, revision, patch) {
          return {
            id: jobId,
            revision: revision + 1,
            status: "failed",
            item: { id: itemId, ...patch },
          };
        },
      },
      log: { info() {}, warn() {}, error() {} },
    },
  );
  worker.processGroup = async () => {
    throw new Error("temporary model failure");
  };

  await worker.processJob(job, new Map([[item.sourceKey, snapshot]]));
  assert.equal((await stat(snapshot.absolutePath)).isFile(), true);

  worker.processGroup = async (_job, group) => {
    for (const entry of group) entry.status = "completed";
  };
  await worker.processJob(job, new Map([[item.sourceKey, snapshot]]));
  await assert.rejects(stat(snapshot.absolutePath), { code: "ENOENT" });
});

test("bounds concurrent snapshot copies", async () => {
  const root = await temporaryRoot();
  let active = 0;
  let maximumActive = 0;
  const store = new SnapshotStore(
    { workRoot: path.join(root, "work"), snapshotConcurrency: 2 },
    {
      copy: async (source, destination) => {
        active += 1;
        maximumActive = Math.max(maximumActive, active);
        await new Promise((resolve) => setTimeout(resolve, 10));
        try {
          return await copySnapshotBytes(source, destination);
        } finally {
          active -= 1;
        }
      },
    },
  );
  const items = [];
  for (let index = 0; index < 5; index += 1) {
    const sourcePath = path.join(root, `photo-${index}.jpg`);
    const content = Buffer.from(`photo bytes ${index}`);
    await writeFile(sourcePath, content);
    items.push(
      declaration(sourcePath, content, `PHOTO/photo-${index}.jpg`, index),
    );
  }

  await store.snapshotGroups([items]);

  assert.equal(maximumActive, 2);
});

async function temporaryRoot() {
  const directory = await mkdtemp(
    path.join(os.tmpdir(), "thumb-cam-snapshot-test-"),
  );
  temporaryDirectories.push(directory);
  return directory;
}

function declaration(sourcePath, content, relativePath, salt = 0) {
  return {
    absolutePath: sourcePath,
    relativePath,
    sourceKey: sha256(`source-${relativePath}-${salt}`),
    contentSha256: sha256(content),
    byteLength: content.length,
  };
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}
