import { afterEach, describe, expect, it, vi } from "vitest";

import { createManagedRecord, updateManagedRecord, uploadManagedMedia } from "./management.server";

const originalApiBaseUrl = process.env.API_BASE_URL;

afterEach(() => {
  vi.unstubAllGlobals();
  if (originalApiBaseUrl === undefined) delete process.env.API_BASE_URL;
  else process.env.API_BASE_URL = originalApiBaseUrl;
});

describe("managed media upload", () => {
  it("reserves, sends unencoded bytes, and completes the backend upload session", async () => {
    process.env.API_BASE_URL = "https://api.example.test";
    const calls: Request[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn((input: RequestInfo | URL, init?: RequestInit) => {
        const request = new Request(input, init);
        calls.push(request);
        if (request.method === "POST" && request.url.endsWith("/v1/media-upload-sessions")) {
          return Promise.resolve(
            Response.json(
              uploadResource({
                uploadUrl: "/v1/signed-upload-target",
              }),
              { status: 201 },
            ),
          );
        }
        if (request.method === "PUT") {
          return Promise.resolve(new Response(null, { status: 204 }));
        }
        if (request.method === "POST" && request.url.endsWith("/complete")) {
          return Promise.resolve(
            Response.json({
              id: "22222222-2222-4222-8222-222222222222",
              revision: 1,
            }),
          );
        }
        return Promise.reject(new Error(`Unexpected request ${request.method} ${request.url}`));
      }),
    );

    const media = await uploadManagedMedia(
      { accessToken: "jwt" },
      "33333333-3333-4333-8333-333333333333",
      new File([new TextEncoder().encode("hello")], "note.txt", { type: "text/plain" }),
      { operationId: "44444444-4444-4444-8444-444444444444", position: 0 },
    );

    expect(media.id).toBe("22222222-2222-4222-8222-222222222222");
    expect(calls.map((request) => `${request.method} ${new URL(request.url).pathname}`)).toEqual([
      "POST /v1/media-upload-sessions",
      "PUT /v1/signed-upload-target",
      "POST /v1/media-upload-sessions/11111111-1111-4111-8111-111111111111/complete",
    ]);
    const contentRequest = calls[1];
    expect(contentRequest?.headers.get("Authorization")).toBe("Bearer jwt");
    expect(contentRequest?.headers.get("Content-Type")).toBe("application/octet-stream");
    expect(contentRequest?.headers.get("Content-Length")).toBe("5");
    expect(contentRequest?.headers.get("X-Content-SHA256")).toBe(
      "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
    );
    expect(await contentRequest?.text()).toBe("hello");
    expect(calls[0]?.headers.get("Idempotency-Key")).toContain(
      "web:44444444-4444-4444-8444-444444444444:media:0:reserve:",
    );
    expect(calls[2]?.headers.get("Idempotency-Key")).toBe(
      "web:44444444-4444-4444-8444-444444444444:media:0:complete:11111111-1111-4111-8111-111111111111",
    );
  });

  it("recovers a completed upload after the completion response is lost", async () => {
    process.env.API_BASE_URL = "https://api.example.test";
    const calls: Request[] = [];
    let completeAttempts = 0;
    vi.stubGlobal(
      "fetch",
      vi.fn((input: RequestInfo | URL, init?: RequestInit) => {
        const request = new Request(input, init);
        calls.push(request);
        if (request.method === "POST" && request.url.endsWith("/v1/media-upload-sessions")) {
          return Promise.resolve(Response.json(uploadResource(), { status: 201 }));
        }
        if (request.method === "PUT") return Promise.resolve(new Response(null, { status: 204 }));
        if (request.method === "POST" && request.url.endsWith("/complete")) {
          completeAttempts += 1;
          return Promise.reject(new TypeError("socket closed after commit"));
        }
        if (request.method === "GET" && request.url.includes("media-upload-sessions")) {
          return Promise.resolve(
            Response.json(uploadResource({ status: "completed", receivedBytes: 5 })),
          );
        }
        if (request.method === "GET" && request.url.includes("/v1/media/")) {
          return Promise.resolve(Response.json(mediaResource()));
        }
        return Promise.reject(new Error(`Unexpected request ${request.method} ${request.url}`));
      }),
    );

    const media = await uploadManagedMedia(
      { accessToken: "jwt" },
      "33333333-3333-4333-8333-333333333333",
      new File(["hello"], "note.txt", { type: "text/plain" }),
      { operationId: "44444444-4444-4444-8444-444444444444", position: 0 },
    );

    expect(media.id).toBe("22222222-2222-4222-8222-222222222222");
    expect(completeAttempts).toBe(1);
    expect(calls.some((request) => request.method === "DELETE")).toBe(false);
  });

  it("rejects a named zero-byte attachment before reserving an upload", async () => {
    const fetch = vi.fn();
    vi.stubGlobal("fetch", fetch);

    await expect(
      uploadManagedMedia(
        { accessToken: "jwt" },
        "33333333-3333-4333-8333-333333333333",
        new File([], "empty.txt"),
        { operationId: "44444444-4444-4444-8444-444444444444", position: 0 },
      ),
    ).rejects.toThrow("between 1 byte and 64 MiB");
    expect(fetch).not.toHaveBeenCalled();
  });
});

describe("managed record mutations", () => {
  it("retries record creation with the same stable idempotency key", async () => {
    const calls: Request[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn((input: RequestInfo | URL, init?: RequestInit) => {
        const request = new Request(input, init);
        calls.push(request);
        if (calls.length === 1) return Promise.reject(new TypeError("response lost"));
        return Promise.resolve(
          Response.json({ id: "abcde", visibility: "public" }, { status: 201 }),
        );
      }),
    );
    const operationId = "44444444-4444-4444-8444-444444444444";

    await createManagedRecord(
      { accessToken: "jwt" },
      {
        deviceId: "33333333-3333-4333-8333-333333333333",
        visibility: "public",
        occurredAt: "2026-07-17T00:00:00.000Z",
        payload: { text: "hello" },
        tagIds: [],
        mediaIds: [],
        metadata: {},
      },
      operationId,
    );

    expect(calls).toHaveLength(2);
    expect(calls.map((request) => request.headers.get("Idempotency-Key"))).toEqual([
      `web:${operationId}:record:create`,
      `web:${operationId}:record:create`,
    ]);
  });

  it("sends null merge-patch members when text and emoji are cleared", async () => {
    const calls: Request[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn((input: RequestInfo | URL, init?: RequestInit) => {
        const request = new Request(input, init);
        calls.push(request);
        if (request.method === "GET") {
          return Promise.resolve(
            Response.json({
              id: "abcde",
              visibility: "public",
              payload: { text: "old", emoji: "🌞", legacy: true },
            }),
          );
        }
        return Promise.resolve(Response.json({ id: "abcde", visibility: "public" }));
      }),
    );

    await updateManagedRecord({ accessToken: "jwt" }, "abcde", 1, {
      deviceId: "33333333-3333-4333-8333-333333333333",
      occurredAt: "2026-07-17T00:00:00.000Z",
      tagIds: [],
      context: { unixTimestamp: 1 },
    });

    const patch = calls.find((request) => request.method === "PATCH");
    expect(patch).toBeDefined();
    expect(await patch?.json()).toMatchObject({
      payload: { text: null, emoji: null, context: { unixTimestamp: 1 } },
    });
  });
});

function uploadResource(overrides: Record<string, unknown> = {}) {
  return {
    id: "11111111-1111-4111-8111-111111111111",
    userId: "55555555-5555-4555-8555-555555555555",
    deviceId: "33333333-3333-4333-8333-333333333333",
    status: "reserved",
    fileName: "note.txt",
    contentType: "text/plain",
    byteLength: 5,
    receivedBytes: 0,
    sha256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
    uploadUrl: "/v1/media-upload-sessions/11111111-1111-4111-8111-111111111111/content",
    expiresAt: "2026-07-18T00:00:00.000Z",
    createdAt: "2026-07-17T00:00:00.000Z",
    mediaId: "22222222-2222-4222-8222-222222222222",
    ...overrides,
  };
}

function mediaResource() {
  return {
    id: "22222222-2222-4222-8222-222222222222",
    revision: 1,
    userId: "55555555-5555-4555-8555-555555555555",
    deviceId: "33333333-3333-4333-8333-333333333333",
    fileName: "note.txt",
    contentType: "text/plain",
    byteLength: 5,
    sha256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
    createdAt: "2026-07-17T00:00:00.000Z",
    contentUrl: "/v1/media/22222222-2222-4222-8222-222222222222/content",
  };
}
