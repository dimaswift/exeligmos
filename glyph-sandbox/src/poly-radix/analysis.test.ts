import { describe, expect, it } from "vitest";

import {
  analyzeBinary,
  analyzeComposite,
  analyzeRadix,
  analyzeTemporal,
  DEFAULT_RADICES,
  digitsForRadix,
  minimalRepeatingBlock,
  TEMPORAL_FRAMES,
  wrapUint16,
} from "./analysis";

describe("poly-radix conversion and morphology", () => {
  it("converts an invariant integer into significant base digits", () => {
    expect(digitsForRadix(73, 8)).toEqual([1, 1, 1]);
    expect(analyzeRadix(73, 8)).toMatchObject({
      residue: 1,
      representation: "111",
      isRepdigit: true,
      repdigitDigit: 1,
      repdigitLength: 3,
      minimalPeriod: 1,
      repeatCount: 3,
    });
  });

  it("detects palindromes, runs, and shortest repeating blocks", () => {
    const analysis = analyzeRadix(0b101101, 2);
    expect(analysis.representation).toBe("101101");
    expect(analysis.repeatCount).toBe(2);
    expect(analysis.periodBlock).toEqual([1, 0, 1]);
    expect(minimalRepeatingBlock([1, 2, 1, 2, 1, 2])).toMatchObject({ periodLength: 2, repeatCount: 3 });
    expect(analyzeRadix(9, 2).isPalindrome).toBe(true);
  });
});

describe("16-bit binary structure", () => {
  it("keeps the exact fixed word separate from significant morphology", () => {
    const analysis = analyzeBinary(85);
    expect(analysis.fixedWord).toBe("0000000001010101");
    expect(analysis.significantWord).toBe("1010101");
    expect(analysis.popcount).toBe(4);
    expect(analysis.significantAlternating).toBe(true);
    expect(analysis.rotationalPeriod).toBe(16);
  });

  it("finds cyclic rotational and reflection symmetry", () => {
    expect(analyzeBinary(0xaaaa).rotationalPeriod).toBe(2);
    expect(analyzeBinary(0xffff).rotationalPeriod).toBe(1);
    expect(analyzeBinary(0xffff).reflectionAxes).toHaveLength(16);
    expect(analyzeBinary(0xaaaa).complementSymmetries).toContainEqual({ kind: "rotation", index: 1 });
  });

  it("wraps animated values across the unsigned 16-bit boundary", () => {
    expect(wrapUint16(65_536)).toBe(0);
    expect(wrapUint16(-1)).toBe(65_535);
  });
});

describe("composite cycles and temporal frames", () => {
  it("calculates the canonical 10,296-state outer supercycle", () => {
    const zero = analyzeComposite(0, DEFAULT_RADICES);
    const nextCycle = analyzeComposite(10_296, DEFAULT_RADICES);
    expect(zero.lcm).toBe(10_296);
    expect(zero.product).toBe(10_296);
    expect(nextCycle.outerPhase).toBe(0);
    expect(nextCycle.supercycleIndex).toBe(1);
    expect(nextCycle.radices.map(({ residue }) => residue)).toEqual([0, 0, 0, 0]);
  });

  it("preserves a custom ordered basis and uses its true least-common cycle", () => {
    const custom = analyzeComposite(72, [8, 9, 12]);

    expect(custom.radices.map(({ radix }) => radix)).toEqual([8, 9, 12]);
    expect(custom.radices.map(({ residue }) => residue)).toEqual([0, 0, 0]);
    expect(custom.lcm).toBe(72);
    expect(custom.product).toBe(864);
    expect(custom.pairwiseGcd[0]?.[2]).toBe(4);
  });

  it("uses 65,536 cyclic bins for every temporal frame", () => {
    const lunar = TEMPORAL_FRAMES[0];
    if (lunar === undefined) throw new Error("Missing lunar frame");
    const start = analyzeTemporal(0, lunar);
    const halfway = analyzeTemporal(32_768, lunar);
    expect(start.normalizedPhase).toBe(0);
    expect(halfway.normalizedPhase).toBe(0.5);
    expect(halfway.degrees).toBe(180);
    expect(start.binDurationSeconds).toBeCloseTo(lunar.days * 86_400 / 65_536, 8);
  });
});
