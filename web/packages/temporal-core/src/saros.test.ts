import { describe, expect, it } from "vitest";

import {
  DEFAULT_SAROS_PULSE_ANCHOR,
  journalEventContext,
  MILISAROS_WINDOW_SECONDS,
  repdigitPeriodSeconds,
  sarosPulseAnchorInterval,
  SAROS_REALTIME_PHASE_DEPTH,
  SAROS_REALTIME_PERIODS,
  SAROS_REALTIME_RARITIES,
  sarosPulseReading,
  sarosPulseTickReading,
  sarosRealtimeWindow,
  type SarosInterval,
  type SarosSpikeReference,
} from "./index.js";

describe("native Saros parity", () => {
  it("uses the native repunit landmark and digit multiplier", () => {
    const alpha = repdigitPeriodSeconds({
      basePeriodSeconds: 1,
      harmonicDepth: 7,
      wildcardPrefixCount: 2,
      repeatedDigit: 1,
    });
    const expectedAlpha = (1 - 8 ** -5) / 7 / 8 ** 2;
    expect(alpha).toBeCloseTo(expectedAlpha, 15);
    expect(
      repdigitPeriodSeconds({
        basePeriodSeconds: 1,
        harmonicDepth: 7,
        wildcardPrefixCount: 2,
        repeatedDigit: 7,
      }),
    ).toBeCloseTo(expectedAlpha * 7, 15);
  });

  it("classifies valleys as flat even when their momentum is nonzero", () => {
    const context = journalEventContext([], 4_800, 8, [
      spike(120, 0, false, 1),
      spike(121, 10_000, true, 90),
      spike(122, 20_000, false, 1),
      spike(123, 30_000, true, 90),
    ]);

    expect(Math.abs(context.momentum)).toBeGreaterThan(0.001);
    expect(context.energyPercent).toBeLessThanOrEqual(0.2);
    expect(context.extremumRawValue).toBe("localMinimum");
    expect(context.directionRawValue).toBe("flat");
  });

  it("classifies peaks as flat even when neighboring periods create momentum", () => {
    const context = journalEventContext([], 10_000, 8, [
      spike(120, 0, false, 1),
      spike(121, 10_000, true, 1),
      spike(122, 25_000, false, 90),
      spike(123, 40_000, true, 1),
    ]);

    expect(Math.abs(context.momentum)).toBeGreaterThan(0.001);
    expect(context.extremumRawValue).toBe("localMaximum");
    expect(context.directionRawValue).toBe("flat");
  });

  it("exposes the parent rollover calculation as Tera without adding a seventh pulse digit", () => {
    const reading = sarosPulseReading(
      {
        saros: 117,
        previous: { epochSeconds: 0, typeCode: 13, sequence: 1, seriesCount: 2 },
        next: { epochSeconds: 512, typeCode: 13, sequence: 2, seriesCount: 2 },
      },
      256,
      7,
    );

    expect(reading.octalAddress).toHaveLength(6);
    expect(reading.units).toHaveLength(7);
    expect(reading.units[0]).toMatchObject({
      id: "tera",
      title: "Tera",
      digit: null,
      exponent: 3,
      exactDurationSeconds: 1,
    });
  });

  it("reads a Saros pulse tick as two five-digit MSB-first glyphs", () => {
    const interval = realtimeInterval(8 ** 10);
    const octalAddress = "1244444444";
    const reading = sarosPulseTickReading(interval, Number.parseInt(octalAddress, 8));

    expect(reading).toMatchObject({
      saros: 141,
      octalAddress,
      glyphDepth: 10,
      mostSignificantGlyphAddress: "12444",
      leastSignificantGlyphAddress: "44444",
    });
    expect(reading.nextTickEpochSeconds).toBe(Number.parseInt(octalAddress, 8) + 1);
  });

  it("resolves Saros 141 as the default pulse anchor and never substitutes another series", () => {
    const intervals = [
      { ...realtimeInterval(100), saros: 140 },
      { ...realtimeInterval(100), saros: DEFAULT_SAROS_PULSE_ANCHOR },
      { ...realtimeInterval(100), saros: 142 },
    ];

    expect(sarosPulseAnchorInterval(intervals, 50)?.saros).toBe(141);
    expect(sarosPulseAnchorInterval(intervals, 50, 142)?.saros).toBe(142);
    expect(sarosPulseAnchorInterval(intervals, 50, 180)).toBeUndefined();
  });

  it("selects the pulse-anchor interval that brackets a historical instant", () => {
    const intervals = [
      realtimeInterval(100),
      {
        ...realtimeInterval(100),
        previous: { ...realtimeInterval(100).previous, epochSeconds: 100 },
        next: { ...realtimeInterval(100).next, epochSeconds: 200 },
      },
    ];

    expect(sarosPulseAnchorInterval(intervals, 99)?.previous.epochSeconds).toBe(0);
    expect(sarosPulseAnchorInterval(intervals, 100)?.previous.epochSeconds).toBe(100);
    expect(sarosPulseAnchorInterval(intervals, 200)?.next.epochSeconds).toBe(200);
  });

  it.each([
    ["neutral", null, 1_000],
    ["blue", "kilo", 8 ** 4 - 32],
    ["purple", "mega", 8 ** 5 - 256],
    ["yellow", "giga", 8 ** 6 - 2_048],
    ["red", "tera", 8 ** 7 - 16_384],
  ] as const)(
    "uses %s urgency for the exact anchored-period lead window",
    (color, imminentUnit, instant) => {
      const reading = sarosPulseTickReading(realtimeInterval(8 ** 10), instant);
      expect(reading.color).toBe(color);
      expect(reading.imminentUnit).toBe(imminentUnit);
    },
  );

  it("gives the rarest imminent period priority when lead windows overlap", () => {
    const boundary = 8 ** 7;
    const reading = sarosPulseTickReading(realtimeInterval(8 ** 10), boundary - 1);

    expect(reading).toMatchObject({ color: "red", imminentUnit: "tera" });
  });

  it("builds an epoch-aligned Milisaros window with exact ten-digit Triplex spikes", () => {
    const binCount = 8 ** SAROS_REALTIME_PHASE_DEPTH;
    const interval = realtimeInterval(binCount + 0.5);
    const firstTriplexBin = (8 ** 7 - 1) / 7;
    const firstTriplexTime = (firstTriplexBin / binCount) * interval.next.epochSeconds;
    const snapshot = sarosRealtimeWindow([interval], firstTriplexTime - 0.1, 32);

    expect(MILISAROS_WINDOW_SECONDS).toBeCloseTo(33.913_358_631_134_03, 12);
    expect(snapshot.segment.index).toBe(
      Math.floor((firstTriplexTime - 0.1) / MILISAROS_WINDOW_SECONDS),
    );
    expect(snapshot.segment.endEpochSeconds - snapshot.segment.startEpochSeconds).toBeCloseTo(
      MILISAROS_WINDOW_SECONDS,
      11,
    );
    expect(snapshot.segment.progress).toBeGreaterThanOrEqual(0);
    expect(snapshot.segment.progress).toBeLessThan(1);
    expect(snapshot.previousSegment.index).toBe(snapshot.segment.index - 1);
    expect(snapshot.nextSegment.index).toBe(snapshot.segment.index + 1);

    expect(snapshot.incomingSpike).toMatchObject({
      saros: 141,
      octalAddress: "0001111111",
      mostSignificantGlyphAddress: "00011",
      leastSignificantGlyphAddress: "11111",
      listGlyphAddress: "00011",
      repeatLength: 7,
      presentationRepeatLength: 2,
      rarityRawValue: "rare-1",
      rarityTitle: "Alpha Triplex",
    });
    expect(snapshot.incomingSpike.unixTimestamp).toBeCloseTo(firstTriplexTime, 9);
    expect(Number.isInteger(snapshot.incomingSpike.unixTimestamp)).toBe(false);
    expect(snapshot.incomingPhase).toEqual({
      saros: 141,
      octalAddress: "0001111111",
      harmonicDepth: 10,
      mostSignificantGlyphAddress: "00011",
      leastSignificantGlyphAddress: "11111",
    });
    expect(snapshot.segment.visibleSpikes.map((spike) => spike.id)).toContain(
      snapshot.incomingSpike.id,
    );
    expect(snapshot.segment.samples).toHaveLength(32);
    expect(snapshot.segment.samples.every((sample) => sample.governingSpikeId !== null)).toBe(true);
  });

  it("returns native list ordering and presents event rarity from the five MSB digits", () => {
    const binCount = 8 ** SAROS_REALTIME_PHASE_DEPTH;
    const interval = realtimeInterval(binCount);
    const duplexBin = Number.parseInt("1244444444", 8);
    const snapshot = sarosRealtimeWindow([interval], duplexBin - 0.01, 8);

    expect(snapshot.pastSpikes.map((spike) => spike.unixTimestamp)).toEqual(
      [...snapshot.pastSpikes]
        .map((spike) => spike.unixTimestamp)
        .sort((left, right) => right - left),
    );
    expect(snapshot.upcomingSpikes.map((spike) => spike.unixTimestamp)).toEqual(
      [...snapshot.upcomingSpikes]
        .map((spike) => spike.unixTimestamp)
        .sort((left, right) => left - right),
    );
    expect(snapshot.incomingSpike).toMatchObject({
      octalAddress: "1244444444",
      mostSignificantGlyphAddress: "12444",
      leastSignificantGlyphAddress: "44444",
      listGlyphAddress: "12444",
      repeatLength: 8,
      presentationRepeatLength: 3,
      repeatedDigit: 4,
      rarityRawValue: "epic-4",
      rarityTitle: "Delta Duplex",
      patternLabel: "XX444",
    });
  });

  it("advances a half-open window exactly at its epoch-aligned boundary", () => {
    const interval = realtimeInterval(8 ** SAROS_REALTIME_PHASE_DEPTH);
    const before = sarosRealtimeWindow([interval], 10 * MILISAROS_WINDOW_SECONDS - 0.001, 8);
    const atBoundary = sarosRealtimeWindow([interval], 10 * MILISAROS_WINDOW_SECONDS, 8);

    expect(before.segment.index).toBe(9);
    expect(atBoundary.segment.index).toBe(10);
    expect(atBoundary.segment.startEpochSeconds).toBeCloseTo(before.segment.endEpochSeconds, 11);
    expect(atBoundary.segment.progress).toBeCloseTo(0, 12);
  });

  it("cycles realtime periods from Milisaros through Tera using the catalog calculations", () => {
    expect(SAROS_REALTIME_PERIODS.map((period) => period.id)).toEqual([
      "mili",
      "saros",
      "kilo",
      "mega",
      "giga",
      "tera",
    ]);
    expect(SAROS_REALTIME_PERIODS.map((period) => period.exponent)).toEqual([8, 7, 6, 5, 4, 3]);
    expect(SAROS_REALTIME_PERIODS.map((period) => period.durationSeconds)).toEqual(
      [...SAROS_REALTIME_PERIODS]
        .map((period) => period.durationSeconds)
        .sort((left, right) => left - right),
    );
    expect(SAROS_REALTIME_PERIODS.at(-1)).toMatchObject({
      id: "tera",
      title: "Tera",
      exponent: 3,
    });
    expect(SAROS_REALTIME_RARITIES.map((rarity) => rarity.id)).toEqual([
      "triplex",
      "duplex",
      "simplex",
      "nihil",
    ]);
    expect(SAROS_REALTIME_RARITIES.map((rarity) => rarity.minimumRepeatLength)).toEqual([
      7, 8, 9, 10,
    ]);
  });

  it("applies the selected minimum rarity to candidates, lists, and samples", () => {
    const binCount = 8 ** SAROS_REALTIME_PHASE_DEPTH;
    const interval = realtimeInterval(binCount);
    const duplexBin = Number.parseInt("1244444444", 8);
    const snapshot = sarosRealtimeWindow([interval], duplexBin - 0.01, {
      minimumRarity: "duplex",
      sampleCount: 16,
    });

    expect(snapshot.minimumRarity).toMatchObject({
      id: "duplex",
      familyId: "epic",
      minimumRepeatLength: 8,
    });
    expect(snapshot.incomingSpike).toMatchObject({
      octalAddress: "1244444444",
      repeatLength: 8,
      rarityRawValue: "epic-4",
    });
    expect(
      [...snapshot.pastSpikes, ...snapshot.upcomingSpikes].every(
        (spike) => spike.repeatLength >= 8,
      ),
    ).toBe(true);
  });

  it.each([
    ["triplex", 3_585],
    ["duplex", 449],
    ["simplex", 57],
    ["nihil", 8],
  ] as const)(
    "counts a complete synthetic Saros interval exactly at the %s threshold",
    (minimumRarity, expectedSpikeCount) => {
      const tera = SAROS_REALTIME_PERIODS.find((period) => period.id === "tera");
      expect(tera).toBeDefined();
      const duration = tera?.durationSeconds ?? 1;
      const snapshot = sarosRealtimeWindow([realtimeInterval(duration)], duration / 2, {
        period: "tera",
        minimumRarity,
        sampleCount: 8,
        visibleSpikeLimit: 64,
      });

      expect(snapshot.segment.totalSpikeCount).toBe(expectedSpikeCount);
      expect(snapshot.segment.spikeBuckets.reduce((sum, bucket) => sum + bucket.count, 0)).toBe(
        expectedSpikeCount > 64 ? expectedSpikeCount : 0,
      );
    },
  );

  it("buckets a Tera window with an exact total instead of materializing every Triplex", () => {
    const binCount = 8 ** SAROS_REALTIME_PHASE_DEPTH;
    const intervals = Array.from({ length: 40 }, (_, index) => ({
      ...realtimeInterval(binCount),
      saros: 117 + index,
    }));
    const tera = SAROS_REALTIME_PERIODS.find((period) => period.id === "tera");
    expect(tera).toBeDefined();
    const instant = (tera?.durationSeconds ?? 1) * 10.25;
    const snapshot = sarosRealtimeWindow(intervals, instant, {
      period: "tera",
      minimumRarity: "triplex",
      sampleCount: 8,
      visibleSpikeLimit: 64,
    });

    expect(snapshot.period).toMatchObject({ id: "tera", title: "Tera", exponent: 3 });
    expect(snapshot.segment.periodId).toBe("tera");
    expect(snapshot.segment.visibleSpikesTruncated).toBe(true);
    expect(snapshot.segment.totalSpikeCount).toBeGreaterThan(64);
    expect(snapshot.segment.visibleSpikes.length).toBeLessThanOrEqual(64);
    expect(snapshot.segment.spikeBuckets.length).toBeLessThanOrEqual(64);
    expect(snapshot.segment.spikeBuckets.reduce((sum, bucket) => sum + bucket.count, 0)).toBe(
      snapshot.segment.totalSpikeCount,
    );
    expect(snapshot.segment.visibleSpikes.every((spike) => spike.repeatLength >= 7)).toBe(true);
  });
});

function realtimeInterval(duration: number): SarosInterval {
  return {
    saros: 141,
    previous: {
      epochSeconds: 0,
      typeCode: 13,
      sequence: 1,
      seriesCount: 2,
      gamma: -0.5,
      magnitude: 1,
    },
    next: {
      epochSeconds: duration,
      typeCode: 13,
      sequence: 2,
      seriesCount: 2,
      gamma: 0.5,
      magnitude: 1,
    },
  };
}

function spike(
  saros: number,
  unixTimestamp: number,
  seriesProgressesSouthToNorth: boolean,
  sarosSequence: number,
): SarosSpikeReference {
  return {
    saros,
    unixTimestamp,
    octalAddress: "00111111",
    harmonicDepth: 8,
    rarityRawValue: "epic-1",
    magnitude: 1,
    sarosSequence,
    sarosSeriesCount: 100,
    seriesProgressesSouthToNorth,
  };
}
