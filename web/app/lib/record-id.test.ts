import { describe, expect, it } from "vitest";
import { isRecordPublicId } from "./record-id";

describe("isRecordPublicId", () => {
  it("accepts the case-sensitive five-character Base64URL alphabet", () => {
    expect(isRecordPublicId("aB9_-")).toBe(true);
  });

  it("rejects UUIDs and malformed short identifiers", () => {
    expect(isRecordPublicId("40d4fe4f-e287-4446-b7d1-c34f4f1ed923")).toBe(false);
    expect(isRecordPublicId("abcd")).toBe(false);
    expect(isRecordPublicId("abcdef")).toBe(false);
    expect(isRecordPublicId("ab+c/")).toBe(false);
    expect(isRecordPublicId(undefined)).toBe(false);
  });
});
