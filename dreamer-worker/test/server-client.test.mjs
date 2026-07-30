import assert from "node:assert/strict";
import test from "node:test";

import { DreamerClient } from "../src/server-client.mjs";

test("uses the server's bounded page size for records and tags", async () => {
  const urls = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (input) => {
    urls.push(String(input));
    return Response.json({ data: [], hasMore: false });
  };
  try {
    const client = new DreamerClient({
      serverUrl: "http://server.test",
      apiKey: "secret",
      deviceId: "11111111-1111-4111-8111-111111111111",
      idempotencyPrefix: "dreamer",
    });
    await client.listRecords();
    await client.listTags();
    assert.deepEqual(urls, [
      "http://server.test/records?limit=25",
      "http://server.test/tags?limit=25",
    ]);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("sends Dreamer runtime as the request body", async () => {
  let request;
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (input, init) => {
    request = { input: String(input), init };
    return new Response(null, { status: 204 });
  };
  try {
    const client = new DreamerClient({
      serverUrl: "http://server.test",
      apiKey: "secret",
      deviceId: "11111111-1111-4111-8111-111111111111",
    });
    const runtime = {
      state: "waiting",
      nextRolloverAt: "2026-07-30T20:49:51.750Z",
      saros: 150,
      scheduleId: "150:1785433791750",
      startedAt: null,
      sourceRecordId: null,
      message: null,
    };
    await client.reportRuntime(runtime);
    assert.equal(request.input, "http://server.test/workers/current/dreamer-runtime");
    assert.equal(request.init.method, "PUT");
    assert.deepEqual(JSON.parse(request.init.body), runtime);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("claims and completes an on-demand dream request", async () => {
  const requests = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (input, init) => {
    requests.push({
      url: String(input),
      method: init.method,
      body: init.body === undefined ? undefined : JSON.parse(init.body),
    });
    return String(input).endsWith("/claim")
      ? Response.json({
          request: {
            jobId: "22222222-2222-4222-8222-222222222222",
            recordId: "abc12",
          },
        })
      : new Response(null, { status: 204 });
  };
  try {
    const client = new DreamerClient({
      serverUrl: "http://server.test",
      apiKey: "secret",
      deviceId: "11111111-1111-4111-8111-111111111111",
    });
    const request = await client.claimDreamRequest();
    await client.completeDreamRequest(request.jobId, "xyz89");
    assert.deepEqual(requests, [
      {
        url: "http://server.test/workers/current/dream-requests/claim",
        method: "POST",
        body: undefined,
      },
      {
        url: "http://server.test/workers/current/dream-requests/22222222-2222-4222-8222-222222222222/complete",
        method: "POST",
        body: { dreamRecordId: "xyz89" },
      },
    ]);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
