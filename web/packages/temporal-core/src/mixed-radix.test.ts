import { describe, expect, it } from "vitest";

import {
  MIXED_RADIX_RESIDUE_PERIOD,
  MIXED_RADIX_SERIES_ADDRESS_COUNT,
  mixedRadixBinForDigits,
  mixedRadixBinsForDigits,
  mixedRadixClockReading,
  mixedRadixRepdigitMetadata,
  mixedRadixSignificanceLayers,
  mixedRadixSignificanceLayersForBases,
  mixedRadixState,
} from "./index.js";

describe("mixed-radix Saros carrier", () => {
  it("starts the first three eclipses at the intended base-7/base-11 offsets", () => {
    expect(mixedRadixState(0, 1).digits).toEqual([0, 0, 0, 0, 0, 0]);
    expect(mixedRadixState(0, 2).digits).toEqual([10, 0, 0, 1, 0, 0]);
    expect(mixedRadixState(0, 3).digits).toEqual([9, 0, 0, 2, 0, 0]);
  });

  it("returns every eclipse-boundary offset after 77 Saros intervals", () => {
    expect(mixedRadixState(0, 78).digits).toEqual([0, 0, 0, 0, 0, 0]);
    expect(mixedRadixState(0, 78).seriesPhaseIndex).toBe(0);
    expect(MIXED_RADIX_SERIES_ADDRESS_COUNT).toBe(720_720);
  });

  it("makes the raw residue collision explicit", () => {
    const first = mixedRadixState(0, 1);
    const repeated = mixedRadixState(MIXED_RADIX_RESIDUE_PERIOD % 9_360, 39);
    expect(repeated.serialBinIndex).toBe(MIXED_RADIX_RESIDUE_PERIOD);
    expect(repeated.digits).toEqual(first.digits);
    expect(repeated.residueCycle).toBe(1);
  });

  it("uses the exact supplied Saros interval for bin duration and next flip", () => {
    const reading = mixedRadixClockReading({
      previousEpochSeconds: 1_000,
      nextEpochSeconds: 1_000 + 9_360 * 60,
      instantEpochSeconds: 1_000 + 12.5 * 60,
      sarosSequence: 2,
    });
    expect(reading.binIndex).toBe(12);
    expect(reading.progressWithinBin).toBeCloseTo(0.5);
    expect(reading.binDurationSeconds).toBe(60);
    expect(reading.nextFlipEpochSeconds).toBe(1_000 + 13 * 60);
    expect(reading.digits).toEqual([0, 3, 4, 6, 2, 12]);
  });

  it("supports an experimental bin count without changing the canonical default", () => {
    const state = mixedRadixState(99, 2, 100);
    expect(state).toMatchObject({
      binCount: 100,
      binIndex: 99,
      serialBinIndex: 199,
      base7Offset: 2,
      base11Offset: 1,
    });
    const reading = mixedRadixClockReading({
      binCount: 120,
      previousEpochSeconds: 0,
      nextEpochSeconds: 1_200,
      instantEpochSeconds: 125,
      sarosSequence: 1,
    });
    expect(reading.binIndex).toBe(12);
    expect(reading.progressWithinBin).toBeCloseTo(0.5);
    expect(reading.binDurationSeconds).toBe(10);
    expect(reading.nextFlipEpochSeconds).toBe(130);
    expect(() => mixedRadixState(0, 1, 0)).toThrow("at least 1");
  });

  it("exposes higher-significance sets independently for every radix", () => {
    expect(mixedRadixSignificanceLayers(9_372, 2)).toEqual([
      [0, 3, 4, 6, 2, 12],
      [5, 6, 3, 1, 4, 5],
    ]);
    expect(() => mixedRadixSignificanceLayers(0, 9)).toThrow("must be 1...8");
    expect(mixedRadixSignificanceLayersForBases(10, 2, [2, 3])).toEqual([
      [0, 1],
      [1, 0],
    ]);
  });

  it("resolves an LSB address back to its unique bin inside a selected Saros", () => {
    const state = mixedRadixState(4_321, 30);
    expect(mixedRadixBinForDigits(state.digits, 30)).toBe(4_321);
    expect(mixedRadixBinForDigits([0, 0, 0, 0, 0, 0], 2)).toBeNull();
    expect(() => mixedRadixBinForDigits([11, 0, 0, 0, 0, 0], 1)).toThrow("outside base 11");
  });

  it("returns every collision for a caller-selected projection basis", () => {
    expect(mixedRadixBinsForDigits([1, 1], 1, [2, 4]).slice(0, 4)).toEqual([1, 5, 9, 13]);
    expect(mixedRadixBinForDigits([1, 1], 1, [2, 4])).toBe(1);
    expect(mixedRadixBinsForDigits([1, 1], 1, [2, 4], 10)).toEqual([1, 5, 9]);
  });

  it("classifies repetition among the six visible digits", () => {
    expect(mixedRadixRepdigitMetadata([1, 1, 1, 2, 2, 2])).toMatchObject({
      pattern: "3+3",
      rarity: "mythic",
    });
    expect(mixedRadixRepdigitMetadata([5, 5, 5, 5, 5, 5]).rarity).toBe("mythic");
    expect(mixedRadixRepdigitMetadata([1, 1, 1, 2, 2, 5])).toMatchObject({
      pattern: "2+3",
      rarity: "legendary",
    });
    expect(mixedRadixRepdigitMetadata([5, 5, 5, 5, 5, 2]).rarity).toBe("legendary");
    expect(mixedRadixRepdigitMetadata([1, 1, 4, 2, 2, 5]).rarity).toBe("rare");
    expect(mixedRadixRepdigitMetadata([5, 5, 5, 5, 2, 1]).rarity).toBe("epic");
    expect(mixedRadixRepdigitMetadata([6, 6, 3, 3, 4, 0])).toMatchObject({
      pattern: "2+2+2",
      rarity: "rare",
    });
    expect(mixedRadixRepdigitMetadata([1, 1, 1, 2, 3, 4]).rarity).toBe("epic");
    expect(mixedRadixRepdigitMetadata([1, 1, 2, 3, 4, 5]).rarity).toBe("common");
    expect(mixedRadixRepdigitMetadata([0, 1, 2, 3, 4, 5])).toMatchObject({
      pattern: "2",
      rarity: "common",
      zeroBonus: true,
    });
    expect(() => mixedRadixRepdigitMetadata([1, 1, 1])).toThrow("exactly six");
  });

  it("counts every zero group as one larger without lowering an existing rarity", () => {
    expect(mixedRadixRepdigitMetadata([0, 0, 1, 2, 3, 4])).toMatchObject({
      pattern: "3",
      rarity: "epic",
    });
    expect(mixedRadixRepdigitMetadata([0, 0, 0, 1, 2, 3]).rarity).toBe("epic");
    expect(mixedRadixRepdigitMetadata([0, 0, 0, 0, 1, 2]).rarity).toBe("legendary");
    expect(mixedRadixRepdigitMetadata([0, 0, 0, 0, 0, 1]).rarity).toBe("mythic");
    expect(mixedRadixRepdigitMetadata([0, 0, 0, 1, 1, 1]).rarity).toBe("mythic");
  });

  it("promotes mirrored or crossed bilateral arm pairs to at least legendary", () => {
    expect(mixedRadixRepdigitMetadata([9, 1, 2, 8, 2, 1])).toMatchObject({
      bilateral: true,
      rarity: "legendary",
    });
    expect(mixedRadixRepdigitMetadata([9, 1, 2, 8, 1, 2])).toMatchObject({
      bilateral: true,
      rarity: "legendary",
    });
    expect(mixedRadixRepdigitMetadata([7, 7, 7, 7, 7, 7]).rarity).toBe("mythic");
  });
});
