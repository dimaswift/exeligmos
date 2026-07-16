import { describe, expect, it } from "vitest";

import {
  FeedQueryError,
  feedCursorHref,
  hasFeedCursor,
  readFeedCursorQuery,
} from "./feed-query.server.js";

describe("feed cursor query", () => {
  it("keeps each lane cursor independent", () => {
    const request = new Request(
      "https://app.example/feed?recordsCursor=records-1&eventsCursor=events-2",
    );

    expect(readFeedCursorQuery(request)).toEqual({
      recordsCursor: "records-1",
      eventsCursor: "events-2",
    });
    expect(feedCursorHref(request, "recordsCursor", "records-3")).toBe(
      "/feed?recordsCursor=records-3&eventsCursor=events-2",
    );
  });

  it("removes only the selected cursor when returning to its first page", () => {
    const request = new Request(
      "https://app.example/feed/global?eventsCursor=event-page&activityCursor=resume",
    );
    expect(feedCursorHref(request, "activityCursor", undefined)).toBe(
      "/feed/global?eventsCursor=event-page",
    );
  });

  it("uses React Router's normalized loader URL instead of the raw .data request URL", () => {
    const normalized = new URL("https://app.example/u/sun?recordsCursor=current");
    expect(feedCursorHref(normalized, "recordsCursor", "next")).toBe("/u/sun?recordsCursor=next");
  });

  it("rejects ambiguous duplicate and empty opaque cursors", () => {
    expect(() =>
      readFeedCursorQuery(
        new Request("https://app.example/explore?activityCursor=one&activityCursor=two"),
      ),
    ).toThrow(FeedQueryError);
    expect(() =>
      readFeedCursorQuery(new Request("https://app.example/explore?recordsCursor=")),
    ).toThrow(FeedQueryError);
  });

  it("reports whether any cursor is active", () => {
    expect(hasFeedCursor({})).toBe(false);
    expect(hasFeedCursor({ activityCursor: "resume" })).toBe(true);
  });
});
