import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test, { afterEach } from "node:test";

import { FractonicaClient } from "../src/server-client.mjs";

const originalFetch = globalThis.fetch;

afterEach(() => {
  globalThis.fetch = originalFetch;
});

test("creates a job manifest with device attribution and stable idempotency", async () => {
  const requests = [];
  globalThis.fetch = async (input, init) => {
    requests.push(new Request(input, init));
    return Response.json(
      { id: "job", totalItems: 1, items: [] },
      { status: 201 },
    );
  };
  const client = new FractonicaClient({
    serverUrl: "https://fractonica.test",
    apiKey: "exk_secret",
    deviceId: "11111111-1111-4111-8111-111111111111",
  });
  const item = {
    sourceKey: "a".repeat(64),
    groupKey: "b".repeat(64),
    relativePath: "PHOTO/one.jpg",
    kind: "photo",
    capturedAt: "2026-07-29T00:00:00.000Z",
    byteLength: 10,
    contentSha256: "c".repeat(64),
  };
  await client.createJob(
    {
      mountName: "THUMB_CAM",
      descriptionModel: "gemma4",
      descriptionPrompt: "prompt",
      embeddingModel: "embeddinggemma",
      whisperModel: "small",
      sarosGroupSeconds: 271.30686904907227,
    },
    [[item]],
  );

  assert.equal(requests.length, 1);
  assert.equal(requests[0].method, "POST");
  assert.equal(requests[0].headers.get("authorization"), "Bearer exk_secret");
  assert.match(
    requests[0].headers.get("idempotency-key"),
    /^thumb-cam:[a-f0-9]{64}:job$/,
  );
  assert.deepEqual(await requests[0].json(), {
    deviceId: "11111111-1111-4111-8111-111111111111",
    source: { volume: "THUMB_CAM" },
    config: {
      descriptionModel: "gemma4",
      descriptionPrompt: "prompt",
      embeddingModel: "embeddinggemma",
      whisperModel: "small",
      sarosWindowSeconds: 271.30686904907227,
      mirrorMode: "paired-rotated",
    },
    items: [
      {
        sourceKey: "a".repeat(64),
        groupKey: "b".repeat(64),
        relativePath: "PHOTO/one.jpg",
        kind: "photo",
        capturedAt: "2026-07-29T00:00:00.000Z",
        byteLength: 10,
        contentSha256: "c".repeat(64),
      },
    ],
  });

  await client.createJob(
    {
      mountName: "THUMB_CAM",
      descriptionModel: "another-model",
      descriptionPrompt: "prompt",
      embeddingModel: "embeddinggemma",
      whisperModel: "small",
      sarosGroupSeconds: 271.30686904907227,
    },
    [[item]],
  );
  assert.notEqual(
    requests[1].headers.get("idempotency-key"),
    requests[0].headers.get("idempotency-key"),
  );
});

test("reads every device-bound job page with an opaque cursor", async () => {
  let request;
  globalThis.fetch = async (input, init) => {
    request = new Request(input, init);
    return Response.json({ data: [], hasMore: false });
  };
  const client = new FractonicaClient({
    serverUrl: "https://fractonica.test",
    apiKey: "exk_secret",
    deviceId: "11111111-1111-4111-8111-111111111111",
  });

  await client.listJobs("opaque cursor/+");

  const url = new URL(request.url);
  assert.equal(url.pathname, "/jobs");
  assert.equal(
    url.searchParams.get("deviceId"),
    "11111111-1111-4111-8111-111111111111",
  );
  assert.equal(url.searchParams.get("limit"), "200");
  assert.equal(url.searchParams.get("cursor"), "opaque cursor/+");
});

test("persists worker diagnostics through the bound worker endpoint", async () => {
  let request;
  globalThis.fetch = async (input, init) => {
    request = new Request(input, init);
    return Response.json(
      {
        id: "22222222-2222-4222-8222-222222222222",
        deviceId: "11111111-1111-4111-8111-111111111111",
        level: "error",
        message: "processing failed",
        context: { sourceRecordId: "abc12", attempt: 2 },
        createdAt: "2026-07-31T00:00:00.000Z",
      },
      { status: 201 },
    );
  };
  const client = new FractonicaClient({
    serverUrl: "https://fractonica.test",
    apiKey: "exk_secret",
    deviceId: "11111111-1111-4111-8111-111111111111",
  });

  await client.writeWorkerLog("error", "processing failed", {
    sourceRecordId: "abc12",
    attempt: 2,
  });

  assert.equal(request.method, "POST");
  assert.equal(
    new URL(request.url).pathname,
    "/workers/current/logs",
  );
  assert.deepEqual(await request.json(), {
    level: "error",
    message: "processing failed",
    context: { sourceRecordId: "abc12", attempt: 2 },
  });
});

test("sends the final text vector with revision-specific idempotency", async () => {
  const requests = [];
  globalThis.fetch = async (input, init) => {
    requests.push(new Request(input, init));
    return Response.json(
      {
        recordId: "abcde",
        recordRevision: 1,
        model: "embeddinggemma",
        dimensions: 3,
      },
      { status: 201 },
    );
  };
  const client = new FractonicaClient({
    serverUrl: "https://fractonica.test",
    apiKey: "exk_secret",
    deviceId: "11111111-1111-4111-8111-111111111111",
  });
  await client.storeEmbedding(
    {
      id: "abcde",
      originId: "22222222-2222-4222-8222-222222222222",
      revision: 1,
    },
    "I see a river.",
    "embeddinggemma",
    [0.1, 0.2, 0.3],
  );
  await client.storeEmbedding(
    {
      id: "abcde",
      originId: "22222222-2222-4222-8222-222222222222",
      revision: 2,
    },
    "I see a river.",
    "embeddinggemma",
    [0.1, 0.2, 0.3],
  );
  await client.storeEmbedding(
    {
      id: "abcde",
      originId: "22222222-2222-4222-8222-222222222222",
      revision: 2,
    },
    "I see a bridge.",
    "embeddinggemma",
    [0.1, 0.2, 0.3],
  );

  const request = requests[0];
  assert.equal(new URL(request.url).pathname, "/records/abcde/embeddings");
  assert.equal(request.method, "PUT");
  assert.match(
    request.headers.get("idempotency-key"),
    /^thumb-cam:22222222-2222-4222-8222-222222222222:embedding:r1:[a-f0-9]{64}$/,
  );
  assert.notEqual(
    requests[0].headers.get("idempotency-key"),
    requests[1].headers.get("idempotency-key"),
  );
  assert.notEqual(
    requests[1].headers.get("idempotency-key"),
    requests[2].headers.get("idempotency-key"),
  );
  assert.deepEqual(await request.json(), {
    recordRevision: 1,
    model: "embeddinggemma",
    contentHash:
      "ac0991a787e782d542bee2e0bc487777d42cd25ced976e10c21ca05b0094b56a",
    vector: [0.1, 0.2, 0.3],
  });
});

test("creates a compact iOS-shaped record with canonical Saros context", async () => {
  const requests = [];
  globalThis.fetch = async (input, init) => {
    const request = new Request(input, init);
    requests.push(request);
    if (request.method === "GET") {
      return Response.json({ data: [], hasMore: false });
    }
    return Response.json(
      {
        id: "camera-record",
        originId: "bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb",
        revision: 1,
      },
      { status: 201 },
    );
  };
  const client = new FractonicaClient({
    serverUrl: "https://fractonica.test",
    apiKey: "exk_secret",
    deviceId: "11111111-1111-4111-8111-111111111111",
  });
  const group = [
    {
      groupKey: "b".repeat(64),
      sourceKey: "a".repeat(64),
      relativePath: "PHOTO/one.jpg",
      kind: "photo",
      capturedAt: "2026-07-29T16:20:56.000Z",
    },
    {
      groupKey: "b".repeat(64),
      sourceKey: "c".repeat(64),
      relativePath: "AUDIO/two.wav",
      kind: "audio",
      capturedAt: "2026-07-29T16:21:03.000Z",
    },
  ];

  await client.createRecord(
    group,
    [{ id: "media-one" }, { id: "media-two" }],
    "I photograph the river while someone speaks nearby.",
    "🌉",
    {
      mountName: "THUMB_CAM",
      descriptionModel: "gemma4",
      embeddingModel: "embeddinggemma",
    },
  );

  assert.equal(requests.length, 2);
  const request = requests[1];
  assert.equal(request.method, "POST");
  assert.equal(new URL(request.url).pathname, "/records");
  const body = await request.json();
  assert.deepEqual(body.mediaIds, ["media-one", "media-two"]);
  assert.deepEqual(body.metadata, {
    ingest: {
      source: "THUMB_CAM",
      descriptionModel: "gemma4",
      embeddingModel: "embeddinggemma",
      mirror: "paired-rotated",
      groupKey: "b".repeat(64),
      mediaCount: 2,
    },
  });
  assert.equal(body.metadata.ingest.media, undefined);
  assert.equal(body.payload.createdAt, group[0].capturedAt);
  assert.equal(body.payload.updatedAt, group[1].capturedAt);
  assert.equal(body.payload.eventDate, group[0].capturedAt);
  assert.equal(body.payload.endDate, group[1].capturedAt);
  assert.equal(body.payload.unixTimestamp, 1_785_342_056);
  assert.deepEqual(body.payload.mediaItems, []);
  assert.equal(body.payload.emoji, "🌉");
  assert.equal(
    body.payload.sourceDeviceID,
    "11111111-1111-4111-8111-111111111111",
  );
  assert.equal(body.payload.sourceDeviceEmoji, "📷");
  assert.equal(body.payload.sourceDeviceName, "THUMB");
  assert.equal(body.payload.context.closestSarosPhase.saros, 140);
  assert.equal(body.payload.context.spikes.length, 4);
  assert.ok(JSON.stringify(body.payload).length < 8_000);
});

test("advances a job item with the current strong job precondition", async () => {
  let request;
  globalThis.fetch = async (input, init) => {
    request = new Request(input, init);
    return Response.json({ id: "job-id", revision: 8, items: [] });
  };
  const client = new FractonicaClient({
    serverUrl: "https://fractonica.test",
    apiKey: "exk_secret",
    deviceId: "11111111-1111-4111-8111-111111111111",
  });
  await client.updateJobItem("job-id", "item-id", 7, {
    status: "processing",
    stage: "describing",
    outputMode: "paired_rotated",
  });

  assert.equal(request.headers.get("if-match"), '"job-job-id-r7"');
  assert.match(
    request.headers.get("idempotency-key"),
    /^thumb-cam:item-id:r7:[a-f0-9]{24}$/,
  );
  assert.deepEqual(await request.json(), {
    status: "processing",
    stage: "describing",
    outputMode: "paired_rotated",
  });
});

test("replaces an expired persisted upload reservation before retrying bytes", async () => {
  const temporary = await mkdtemp(
    path.join(os.tmpdir(), "thumb-upload-retry-"),
  );
  const absolutePath = path.join(temporary, "capture.wav");
  await writeFile(absolutePath, "camera audio");
  const oldUploadId = "22222222-2222-4222-8222-222222222222";
  const newUploadId = "33333333-3333-4333-8333-333333333333";
  const mediaId = "44444444-4444-4444-8444-444444444444";
  const requests = [];
  let reservedId;
  let requestedMediaId;
  globalThis.fetch = async (input, init) => {
    const request = new Request(input, init);
    requests.push(request);
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname.startsWith("/media/")) {
      return Response.json({ detail: "not found" }, { status: 404 });
    }
    if (
      request.method === "GET" &&
      url.pathname === `/media-upload-sessions/${oldUploadId}`
    ) {
      return Response.json({ id: oldUploadId, status: "expired" });
    }
    if (
      request.method === "POST" &&
      url.pathname === "/media-upload-sessions"
    ) {
      requestedMediaId = (await request.clone().json()).mediaId;
      return Response.json(
        {
          id: newUploadId,
          mediaId: requestedMediaId,
          status: "reserved",
          uploadUrl: `/media-upload-sessions/${newUploadId}/content`,
        },
        { status: 201 },
      );
    }
    if (
      request.method === "GET" &&
      url.pathname === `/media-upload-sessions/${newUploadId}`
    ) {
      return Response.json({
        id: newUploadId,
        mediaId: requestedMediaId,
        status: "reserved",
        uploadUrl: `/media-upload-sessions/${newUploadId}/content`,
      });
    }
    if (
      request.method === "PUT" &&
      url.pathname === `/media-upload-sessions/${newUploadId}/content`
    ) {
      return new Response(null, { status: 204 });
    }
    if (
      request.method === "POST" &&
      url.pathname === `/media-upload-sessions/${newUploadId}/complete`
    ) {
      return Response.json({ id: mediaId }, { status: 200 });
    }
    return Response.json({ detail: "unexpected request" }, { status: 500 });
  };
  const client = new FractonicaClient({
    serverUrl: "https://fractonica.test",
    apiKey: "exk_secret",
    deviceId: "11111111-1111-4111-8111-111111111111",
  });

  try {
    const completed = await client.uploadMedia(
      {
        sourceKey: "a".repeat(64),
        uploadId: oldUploadId,
      },
      {
        absolutePath,
        fileName: "capture.wav",
        contentType: "audio/wav",
      },
      async (reservation) => {
        reservedId = reservation.id;
      },
    );

    assert.equal(completed.id, mediaId);
    assert.equal(reservedId, newUploadId);
    const create = requests.find(
      (request) =>
        request.method === "POST" &&
        new URL(request.url).pathname === "/media-upload-sessions",
    );
    assert.ok(create);
    assert.match(
      create.headers.get("idempotency-key"),
      new RegExp(`:reserve:${oldUploadId}$`),
    );
  } finally {
    await rm(temporary, { force: true, recursive: true });
  }
});
