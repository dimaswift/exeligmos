import { describe, expect, it } from "vitest";

import { isReferenceKind, referenceInspectorHref } from "./model.js";

describe("references", () => {
  it("creates an inspector-safe route", () => {
    expect(
      referenceInspectorHref({ kind: "user", id: "2dca8eab-00a8-4e94-9bd2-2fcbfe17e890" }),
    ).toBe("/references/user/2dca8eab-00a8-4e94-9bd2-2fcbfe17e890");
  });

  it("rejects non-UUID entity ids", () => {
    expect(() => referenceInspectorHref({ kind: "user", id: "sun/activity" })).toThrow("UUID");
  });

  it("rejects unknown reference kinds", () => {
    expect(isReferenceKind("record")).toBe(true);
    expect(isReferenceKind("tag")).toBe(false);
  });
});
