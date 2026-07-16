import { describe, expect, it } from "vitest";

import {
  FeedQueryError,
  feedCursorHref,
  feedPageLinks,
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

  it("carries a bounded cursor stack so older pages can navigate newer again", () => {
    const first = new URL("https://app.example/feed?eventsCursor=event-page");
    const firstLinks = feedPageLinks(first, "recordsCursor", "records-page-2");
    expect(firstLinks.previousHref).toBeNull();
    expect(firstLinks.nextHref).toContain("recordsCursor=records-page-2");

    const second = new URL(`https://app.example${firstLinks.nextHref}`);
    const secondLinks = feedPageLinks(second, "recordsCursor", "records-page-3");
    expect(secondLinks.previousHref).toBe("/feed?eventsCursor=event-page");
    expect(secondLinks.nextHref).toContain("recordsCursor=records-page-3");

    const third = new URL(`https://app.example${secondLinks.nextHref}`);
    expect(feedPageLinks(third, "recordsCursor", undefined).previousHref).toBe(firstLinks.nextHref);
  });

  it("preserves the other lane's cursor and history while paging records", () => {
    const eventsHistory = encodeHistory(["events-page-1"]);
    const current = new URL(
      `https://app.example/explore?eventsCursor=events-page-2&eventsHistory=${eventsHistory}`,
    );

    const links = feedPageLinks(current, "recordsCursor", "records-page-2");
    const older = new URL(`https://app.example${links.nextHref}`);

    expect(older.searchParams.get("eventsCursor")).toBe("events-page-2");
    expect(older.searchParams.get("eventsHistory")).toBe(eventsHistory);
    expect(older.searchParams.get("recordsCursor")).toBe("records-page-2");
    expect(links.previousHref).toBeNull();
  });

  it("offers a safe return to the first page for a legacy cursor without history", () => {
    const links = feedPageLinks(
      new URL("https://app.example/feed?recordsCursor=legacy-page"),
      "recordsCursor",
      undefined,
    );

    expect(links.previousHref).toBe("/feed");
  });

  it("rejects malformed, ambiguous, orphaned, and oversized cursor histories", () => {
    const malformed = "https://app.example/feed?recordsCursor=current&recordsHistory=not-json";
    expect(() => feedPageLinks(new URL(malformed), "recordsCursor", undefined)).toThrow(
      FeedQueryError,
    );

    const duplicate = `https://app.example/feed?recordsCursor=current&recordsHistory=${encodeHistory(["one"])}&recordsHistory=${encodeHistory(["two"])}`;
    expect(() => feedPageLinks(new URL(duplicate), "recordsCursor", undefined)).toThrow(
      FeedQueryError,
    );

    const orphaned = `https://app.example/feed?recordsHistory=${encodeHistory(["page-1"])}`;
    expect(() => feedPageLinks(new URL(orphaned), "recordsCursor", undefined)).toThrow(
      FeedQueryError,
    );

    const oversized = `https://app.example/feed?recordsCursor=current&recordsHistory=${encodeHistory(Array.from({ length: 51 }, (_, index) => `page-${index}`))}`;
    expect(() => feedPageLinks(new URL(oversized), "recordsCursor", undefined)).toThrow(
      FeedQueryError,
    );
  });
});

function encodeHistory(history: readonly string[]): string {
  return Buffer.from(JSON.stringify(history)).toString("base64url");
}
