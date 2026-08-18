import { describe, expect, it } from "vitest";

import {
  clampTemplateStart,
  dotRadiusForSize,
  makeTemplateEntries,
  numberGroupsFor,
} from "./print-template";

describe("print template pages", () => {
  it("fills blank practice pages with empty prompts", () => {
    expect(
      makeTemplateEntries({ mode: "blank", radix: 16, capacity: 6, startDigit: 0 }),
    ).toEqual([null, null, null, null, null, null]);
  });

  it("paginates guided digits without wrapping past the radix", () => {
    expect(
      makeTemplateEntries({ mode: "guided", radix: 16, capacity: 6, startDigit: 13 }),
    ).toEqual([13, 14, 15, null, null, null]);
  });

  it("clamps page starts and exposes ordered physical dot sizes", () => {
    expect(clampTemplateStart(-20, 32)).toBe(0);
    expect(clampTemplateStart(99, 32)).toBe(31);
    expect((["small", "medium", "large"] as const).map(dotRadiusForSize)).toEqual([
      3.2,
      4.8,
      6.6,
    ]);
  });

  it("classifies overlapping arithmetic groups in legend order", () => {
    expect(numberGroupsFor(0)).toEqual(["even", "perfect-square"]);
    expect(numberGroupsFor(1)).toEqual(["odd", "squarefree", "perfect-square", "deficient"]);
    expect(numberGroupsFor(5)).toEqual(["odd", "prime", "squarefree", "deficient"]);
    expect(numberGroupsFor(6)).toEqual(["even", "composite", "squarefree", "perfect"]);
    expect(numberGroupsFor(12)).toEqual(["even", "composite", "abundant"]);
    expect(numberGroupsFor(16)).toEqual(["even", "composite", "perfect-square", "deficient"]);
  });

  it("rejects values that cannot correspond to a numbered template cell", () => {
    expect(numberGroupsFor(-1)).toEqual([]);
    expect(numberGroupsFor(2.5)).toEqual([]);
    expect(numberGroupsFor(Number.POSITIVE_INFINITY)).toEqual([]);
  });
});
