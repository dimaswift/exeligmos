import { describe, expect, it } from "vitest";

import {
  activityResourceKey,
  activityResourceTimestamp,
  formatAbsoluteTimestamp,
  formatMetadata,
  formatTimestampRange,
  isValidTimestamp,
  type ActivityResource,
} from "./model";

describe("activity feed model", () => {
  it("formats absolute UTC timestamps without wall-clock or locale input", () => {
    expect(formatAbsoluteTimestamp("2026-07-15T17:02:03+03:00")).toBe("15 Jul 2026 · 14:02:03 UTC");
    expect(formatTimestampRange("2026-01-01T00:00:00Z", "2026-01-01T00:00:01Z")).toBe(
      "01 Jan 2026 · 00:00:00 UTC – 01 Jan 2026 · 00:00:01 UTC",
    );
    expect(formatAbsoluteTimestamp("not-a-date")).toBe("Invalid timestamp");
    expect(isValidTimestamp("not-a-date")).toBe(false);
  });

  it("uses occurrence time for public records and creation time for encrypted records", () => {
    const publicResource = {
      kind: "record",
      record: {
        id: "Pub01",
        userId: "user",
        author: { id: "user", login: "sun", displayName: "The Sun" },
        visibility: "public",
        occurredAt: "2026-07-15T10:00:00Z",
        payload: {},
        tagIds: [],
        tags: [],
        media: [],
        metadata: {},
        references: [],
        revision: 1,
        createdAt: "2026-07-15T11:00:00Z",
        updatedAt: "2026-07-15T11:00:00Z",
      },
    } satisfies ActivityResource;
    const privateResource = {
      kind: "record",
      record: {
        id: "Prv01",
        originId: "70000000-0000-4000-8000-000000000007",
        userId: "user",
        deviceId: "device",
        visibility: "private",
        revision: 1,
        createdAt: "2026-07-15T12:00:00Z",
        updatedAt: "2026-07-15T12:00:00Z",
        references: [],
        encryption: {
          algorithm: "A256GCM",
          cryptoVersion: 1,
          keyVersion: 1,
          nonce: "nonce",
          ciphertext: "secret-ciphertext",
          contentType: "application/vnd.exeligmos.record+json",
        },
        media: [],
      },
    } satisfies ActivityResource;

    expect(activityResourceTimestamp(publicResource)).toBe("2026-07-15T10:00:00Z");
    expect(activityResourceTimestamp(privateResource)).toBe("2026-07-15T12:00:00Z");
    expect(activityResourceKey(publicResource)).toBe("record:Pub01");
  });

  it("sorts metadata keys recursively for stable server markup", () => {
    expect(formatMetadata({ z: 1, a: { y: true, b: [3, { d: 4, c: 2 }] } })).toBe(`{
  "a": {
    "b": [
      3,
      {
        "c": 2,
        "d": 4
      }
    ],
    "y": true
  },
  "z": 1
}`);
  });
});
