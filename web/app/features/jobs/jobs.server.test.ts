import { afterEach, describe, expect, it, vi } from "vitest";

import { readJobs } from "./jobs.server";

const originalApiBaseUrl = process.env.API_BASE_URL;

afterEach(() => {
  vi.unstubAllGlobals();
  if (originalApiBaseUrl === undefined) delete process.env.API_BASE_URL;
  else process.env.API_BASE_URL = originalApiBaseUrl;
});

describe("jobs API boundary", () => {
  it("loads jobs with the request-scoped access token and abort signal", async () => {
    process.env.API_BASE_URL = "https://api.example.test";
    const requests: Request[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn((input: RequestInfo | URL, init?: RequestInit) => {
        const request = new Request(input, init);
        requests.push(request);
        return Promise.resolve(
          Response.json({
            data: [jobResource()],
            hasMore: false,
          }),
        );
      }),
    );
    const controller = new AbortController();

    const page = await readJobs(
      { accessToken: "request-access-token" },
      { signal: controller.signal },
    );

    expect(page.data).toHaveLength(1);
    expect(page.data[0]?.source).toEqual({ volume: "THUMB_CAM" });
    expect(requests).toHaveLength(2);
    const urls = requests.map((request) => new URL(request.url));
    expect(urls.every((url) => url.pathname === "/jobs")).toBe(true);
    expect(
      urls.find((url) => url.searchParams.get("status") == null)?.searchParams.get("limit"),
    ).toBe("200");
    expect(
      urls.find((url) => url.searchParams.get("activity") === "active")?.searchParams.get("limit"),
    ).toBe("1");
    expect(
      requests.every(
        (request) => request.headers.get("Authorization") === "Bearer request-access-token",
      ),
    ).toBe(true);
    controller.abort();
    expect(requests.every((request) => request.signal.aborted)).toBe(true);
  });

  it("keeps an active job visible even when it is outside the recent page", async () => {
    process.env.API_BASE_URL = "https://api.example.test";
    vi.stubGlobal(
      "fetch",
      vi.fn((input: RequestInfo | URL) => {
        const url = new URL(input instanceof Request ? input.url : input);
        const active = url.searchParams.get("activity") === "active";
        return Promise.resolve(
          Response.json({
            data: [
              jobResource(
                active
                  ? { id: "job-active" }
                  : {
                      id: "job-recent",
                      status: "completed",
                      activity: "idle",
                      processedItems: 3,
                      remainingItems: 0,
                      processedRecords: 2,
                      remainingRecords: 0,
                    },
              ),
            ],
            hasMore: !active,
            ...(active ? {} : { nextCursor: "recent-page-2" }),
          }),
        );
      }),
    );

    const page = await readJobs({ accessToken: "request-access-token" });

    expect(page.data.map((job) => job.id)).toEqual(["job-active", "job-recent"]);
    expect(page.hasMore).toBe(true);
    expect(page.nextCursor).toBe("recent-page-2");
  });
});

function jobResource(overrides: Readonly<Record<string, unknown>> = {}) {
  return {
    id: "job-1",
    userId: "11111111-1111-4111-8111-111111111111",
    deviceId: "22222222-2222-4222-8222-222222222222",
    source: { volume: "THUMB_CAM" },
    config: {},
    status: "processing",
    activity: "active",
    totalItems: 3,
    processedItems: 1,
    failedItems: 0,
    remainingItems: 2,
    totalRecords: 2,
    processedRecords: 0,
    failedRecords: 0,
    remainingRecords: 2,
    currentItem: null,
    revision: 1,
    createdAt: "2026-07-29T10:00:00.000Z",
    updatedAt: "2026-07-29T10:00:01.000Z",
    ...overrides,
  };
}
