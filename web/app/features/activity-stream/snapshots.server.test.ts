import { describe, expect, it } from "vitest";

import {
  activityHistoryCursor,
  hydrateActivityPage,
  ownerEventCursor,
  ownerRecordCursor,
  publicEventCursor,
  publicRecordCursor,
  readFollowingActivity,
  readGlobalActivity,
  readOwnerSnapshot,
  readPublicUserSnapshot,
  recordPageLimit,
  standardPageLimit,
  type ActivityPage,
  type SnapshotAuthorization,
} from "./snapshots.server.js";

const userId = "2dca8eab-00a8-4e94-9bd2-2fcbfe17e890";
const recordId = "40d4fe4f-e287-4446-b7d1-c34f4f1ed923";
const eventId = "88dbb3a8-493f-475e-b699-d6090e1ab5ed";

const profile = {
  id: userId,
  login: "sun",
  displayName: "Sun",
  sarosAnchor: 141,
  createdAt: "2026-07-15T00:00:00Z",
  publicRecordCount: 1,
  publicEventCount: 1,
  followerCount: 3,
};

const auth: SnapshotAuthorization = {
  accessToken: "access-only-token",
  user: {
    id: userId,
    login: "sun",
    displayName: "Sun",
    sarosAnchor: 141,
    createdAt: "2026-07-15T00:00:00Z",
    updatedAt: "2026-07-15T00:00:00Z",
  },
};

describe("typed snapshot boundary", () => {
  it("loads a public profile plus independent latest record and event lanes", async () => {
    const requests: Request[] = [];
    const fetch = routeFetch((request) => {
      requests.push(request);
      switch (new URL(request.url).pathname) {
        case "/v1/public/users/sun":
          return json(profile);
        case "/v1/public/records":
          return json({ data: [{ id: recordId }], nextCursor: "records-next", hasMore: true });
        case "/v1/public/events":
          return json({ data: [{ id: eventId }], nextCursor: "events-next", hasMore: false });
        default:
          return new Response(null, { status: 404 });
      }
    });

    const snapshot = await readPublicUserSnapshot("sun", {
      baseUrl: "https://api.example",
      fetch,
      records: { cursor: publicRecordCursor("records-before"), limit: recordPageLimit(2) },
      events: { cursor: publicEventCursor("events-before"), limit: standardPageLimit(7) },
    });

    expect(snapshot.records.nextCursor).toBe("records-next");
    expect(snapshot.events.nextCursor).toBe("events-next");
    expect(queryFor(requests, "/v1/public/records")).toMatchObject({
      cursor: "records-before",
      limit: "2",
      userId,
    });
    expect(queryFor(requests, "/v1/public/events")).toMatchObject({
      cursor: "events-before",
      limit: "7",
      userId,
    });
  });

  it("loads owner lanes with an access token but no refresh authority", async () => {
    const requests: Request[] = [];
    const fetch = routeFetch((request) => {
      requests.push(request);
      const records = new URL(request.url).pathname === "/v1/records";
      return json({ data: [], hasMore: false, nextCursor: records ? "owner-r" : "owner-e" });
    });

    const snapshot = await readOwnerSnapshot(auth, {
      baseUrl: "https://api.example",
      fetch,
      records: { cursor: ownerRecordCursor("before-r"), limit: recordPageLimit(4) },
      events: { cursor: ownerEventCursor("before-e"), limit: standardPageLimit(8) },
    });

    expect(snapshot.records.nextCursor).toBe("owner-r");
    expect(snapshot.events.nextCursor).toBe("owner-e");
    expect(requests).toHaveLength(2);
    expect(
      requests.every(
        (request) => request.headers.get("Authorization") === "Bearer access-only-token",
      ),
    ).toBe(true);
    expect(requests.every((request) => !request.url.includes("refresh"))).toBe(true);
  });

  it("requests latest activity only for an initial snapshot and resumes normally with a cursor", async () => {
    const requests: Request[] = [];
    const fetch = routeFetch((request) => {
      requests.push(request);
      return json({ data: [], nextCursor: "history-next", hasMore: false });
    });
    const connection = { baseUrl: "https://api.example", fetch };

    await readGlobalActivity({ ...connection, limit: standardPageLimit(20) });
    await readFollowingActivity(auth, {
      ...connection,
      cursor: activityHistoryCursor("history-before"),
      resourceType: ["record", "event"],
    });

    expect(new URL(requests[0]!.url).searchParams.get("snapshot")).toBe("latest");
    const resumed = new URL(requests[1]!.url);
    expect(resumed.searchParams.get("snapshot")).toBeNull();
    expect(resumed.searchParams.get("cursor")).toBe("history-before");
    expect(resumed.searchParams.getAll("resourceType")).toEqual(["record", "event"]);
    expect(requests[1]!.headers.get("Authorization")).toBe("Bearer access-only-token");
  });

  it("hydrates by typed IDs, ignores resourceUrl, caches duplicates, and preserves 404 rows", async () => {
    const requests: Request[] = [];
    const fetch = routeFetch((request) => {
      requests.push(request);
      const path = new URL(request.url).pathname;
      if (path === `/v1/public/records/${recordId}`) return json({ id: recordId });
      if (path === `/v1/public/events/${eventId}`) return problem(404, "not_found");
      if (path === "/v1/public/users/sun") return json(profile);
      return new Response(null, { status: 404 });
    });
    const page: ActivityPage = {
      data: [
        activity("record", "upsert", recordId, "https://attacker.example/one"),
        activity("record", "upsert", recordId, "javascript:alert(1)"),
        activity("event", "upsert", eventId, "https://attacker.example/two"),
        activity("user", "upsert", userId, "https://attacker.example/three"),
        activity("record", "delete", recordId, "https://attacker.example/four"),
      ],
      nextCursor: activityHistoryCursor("after"),
      hasMore: false,
    };

    const hydrated = await hydrateActivityPage(page, {
      baseUrl: "https://api.example",
      fetch,
      concurrency: 3,
    });

    expect(hydrated.data.map((entry) => entry.kind)).toEqual([
      "record",
      "record",
      "event",
      "user",
      "record",
    ]);
    expect(hydrated.data[2]).not.toHaveProperty("projection");
    expect(hydrated.data[4]).not.toHaveProperty("projection");
    expect(requests).toHaveLength(3);
    expect(requests.every((request) => !request.url.includes("attacker.example"))).toBe(true);
  });

  it("enforces endpoint-specific cursor and limit bounds", async () => {
    expect(() => publicRecordCursor("")).toThrow("1 to 2048");
    expect(() => publicEventCursor("x".repeat(2_049))).toThrow("1 to 2048");
    expect(() => recordPageLimit(26)).toThrow("1 through 25");
    expect(() => standardPageLimit(201)).toThrow("1 through 200");
    await expect(
      hydrateActivityPage(
        { data: [], nextCursor: activityHistoryCursor("after"), hasMore: false },
        { concurrency: 17 },
      ),
    ).rejects.toThrow("1 through 16");
  });

  it("preserves generated Problem details in BackendRequestError", async () => {
    const fetch = routeFetch(() => problem(400, "invalid_request", "Wrong cursor query."));
    await expect(
      readGlobalActivity({ baseUrl: "https://api.example", fetch }),
    ).rejects.toMatchObject({
      name: "BackendRequestError",
      message: "Wrong cursor query.",
      status: 400,
      code: "invalid_request",
      requestId: "req_phase3",
    });
  });
});

function activity(
  resourceType: "user" | "record" | "event",
  operation: "upsert" | "delete",
  resourceId: string,
  resourceUrl: string,
) {
  return {
    sequence: 1,
    publishedAt: "2026-07-15T00:00:00Z",
    actor: { id: userId, login: "sun", displayName: "Sun", sarosAnchor: 141 },
    resourceType,
    resourceId,
    operation,
    revision: 1,
    resourceUrl,
  };
}

function queryFor(requests: readonly Request[], path: string): Record<string, string> {
  const request = requests.find((candidate) => new URL(candidate.url).pathname === path)!;
  return Object.fromEntries(new URL(request.url).searchParams);
}

function routeFetch(handler: (request: Request) => Response | Promise<Response>): typeof fetch {
  return async (input, init) =>
    handler(input instanceof Request ? input : new Request(input, init));
}

function json(value: unknown, init: ResponseInit = {}): Response {
  const headers = new Headers(init.headers);
  headers.set("Content-Type", "application/json");
  return new Response(JSON.stringify(value), { ...init, headers });
}

function problem(status: number, code: string, detail?: string): Response {
  return json(
    {
      type: `urn:problem:${code}`,
      title: "Request failed",
      status,
      detail,
      code,
      requestId: "req_phase3",
    },
    { status },
  );
}
