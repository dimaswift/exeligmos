import { describe, expect, it } from "vitest";

import { DEFAULT_ENGINE_LAB_QUERY, parseEngineLabQuery } from "./query.js";

describe("engine-lab query state", () => {
  it("uses deterministic defaults", () => {
    expect(parseEngineLabQuery("https://example.test/lab/engines")).toEqual({
      ...DEFAULT_ENGINE_LAB_QUERY,
      warnings: [],
    });
  });

  it("preserves explicit address and interval strings", () => {
    expect(
      parseEngineLabQuery(
        "https://example.test/lab/engines?address=&previous=bad&next=0&instant=after&depth=5&clockDepth=8",
      ),
    ).toEqual({
      address: "",
      depth: 5,
      previous: "bad",
      next: "0",
      instant: "after",
      clockDepth: 8,
      warnings: [],
    });
  });

  it("clamps presentation depth but strictly replaces invalid calculation depth", () => {
    const query = parseEngineLabQuery("https://example.test/lab/engines?depth=99&clockDepth=9");

    expect(query.depth).toBe(8);
    expect(query.clockDepth).toBe(DEFAULT_ENGINE_LAB_QUERY.clockDepth);
    expect(query.warnings).toEqual(["Invalid clock depth “9” was replaced with 3."]);
  });

  it("replaces non-integer depths with stable defaults and diagnostics", () => {
    const query = parseEngineLabQuery("https://example.test/lab/engines?depth=3.5&clockDepth=NaN");

    expect(query.depth).toBe(DEFAULT_ENGINE_LAB_QUERY.depth);
    expect(query.clockDepth).toBe(DEFAULT_ENGINE_LAB_QUERY.clockDepth);
    expect(query.warnings).toEqual([
      "Invalid glyph depth “3.5” was replaced with 7.",
      "Invalid clock depth “NaN” was replaced with 3.",
    ]);
  });
});
