import { describe, expect, it } from "vitest";

import {
  activeSarosIntervals,
  realtimeSarosIntervalsAt,
  realtimeSarosWindowAt,
  recordTemporalContextAt,
  solarTemporalDataMetadata,
  systemSnapshotAt,
} from "./solar-engine.server";

const screenshotInstant = Date.parse("2026-07-16T20:54:55Z") / 1_000;

describe("canonical solar temporal adapter", () => {
  it("pins the generated canonical dataset provenance", () => {
    expect(solarTemporalDataMetadata).toEqual({
      schemaVersion: 1,
      sourceSha256: "cf8ca294b6537f7b98e68b791d71448b065d8c445d4b48e49775365da9663b43",
      seriesCount: 180,
      eclipseCount: 13_206,
    });
  });

  it("loads the native 40-series grid for the current era", () => {
    const intervals = activeSarosIntervals(screenshotInstant);
    expect(intervals).toHaveLength(40);
    expect(intervals.map((interval) => interval.saros)).toEqual(
      Array.from({ length: 40 }, (_, index) => 117 + index),
    );
  });

  it("matches the native four-spike screenshot fixture at canonical depth", () => {
    const context = recordTemporalContextAt(screenshotInstant);
    expect(
      context.spikes.map((spike) => [spike.saros, spike.unixTimestamp, spike.octalAddress]),
    ).toEqual([
      [117, Date.parse("2026-07-16T07:10:03Z") / 1_000, "34333333"],
      [122, Date.parse("2026-07-16T20:40:33Z") / 1_000, "32555555"],
      [141, Date.parse("2026-07-17T01:17:07Z") / 1_000, "72444444"],
      [146, Date.parse("2026-07-18T03:43:16Z") / 1_000, "70666666"],
    ]);
    expect(context.closestSarosPhase).toMatchObject({
      saros: 122,
      octalAddress: "32555606",
      harmonicDepth: 8,
    });
  });

  it("matches the native default pulse fixture", () => {
    expect(systemSnapshotAt(screenshotInstant).pulse).toMatchObject({
      saros: 117,
      octalAddress: "362162",
      glyphDepth: 6,
    });
  });

  it("matches the native ten-digit global Spike fixture without truncating time", () => {
    const instant = Date.parse("2026-07-15T00:00:00Z") / 1_000;
    const window = realtimeSarosWindowAt(instant, 32);

    expect(window.pastSpikes).toHaveLength(8);
    expect(window.upcomingSpikes).toHaveLength(4);
    expect(window.pastSpikes[0]).toMatchObject({
      saros: 119,
      octalAddress: "1673333333",
      listGlyphAddress: "16733",
      rarityRawValue: "rare-3",
      rarityTitle: "Gamma Triplex",
    });
    expect(window.pastSpikes[0]?.unixTimestamp).toBeLessThanOrEqual(instant);
    expect(window.incomingSpike).toMatchObject({
      saros: 122,
      octalAddress: "3254444444",
      mostSignificantGlyphAddress: "32544",
      leastSignificantGlyphAddress: "44444",
      listGlyphAddress: "32544",
      rarityRawValue: "rare-4",
      rarityTitle: "Delta Triplex",
    });
    expect(window.incomingSpike.unixTimestamp).toBeGreaterThan(instant);
    expect(Number.isInteger(window.incomingSpike.unixTimestamp)).toBe(false);
    expect(window.incomingPhase).toEqual({
      saros: 122,
      octalAddress: "3254444444",
      harmonicDepth: 10,
      mostSignificantGlyphAddress: "32544",
      leastSignificantGlyphAddress: "44444",
    });
    expect(window.segment.samples).toHaveLength(32);
    expect(window.segment.samples.every((sample) => sample.rarityRawValue !== null)).toBe(true);
  });

  it("loads adjacent eclipse intervals and buckets a real Tera window", () => {
    const eclipseInstant = Date.parse("2024-04-08T18:18:29Z") / 1_000;
    const window = realtimeSarosWindowAt(eclipseInstant, {
      period: "tera",
      minimumRarity: "triplex",
      sampleCount: 8,
      visibleSpikeLimit: 64,
    });

    expect(window.period).toMatchObject({ id: "tera", title: "Tera", exponent: 3 });
    expect(window.segment.visibleSpikesTruncated).toBe(true);
    expect(window.segment.totalSpikeCount).toBeGreaterThan(64);
    expect(window.segment.spikeBuckets.reduce((sum, bucket) => sum + bucket.count, 0)).toBe(
      window.segment.totalSpikeCount,
    );
    expect(
      [window.previousSegment, window.segment, window.nextSegment]
        .flatMap((segment) => segment.visibleSpikes)
        .some(
          (spike) =>
            spike.saros === 139 &&
            spike.unixTimestamp === eclipseInstant &&
            spike.octalAddress === "7777777777",
        ),
    ).toBe(true);
  });

  it("preloads maximum shell coverage across an eclipse boundary", () => {
    const eclipseInstant = Date.parse("2024-04-08T18:18:29Z") / 1_000;
    const intervals = realtimeSarosIntervalsAt(eclipseInstant);
    const saros139 = intervals.filter((interval) => interval.saros === 139);

    expect(saros139).toHaveLength(2);
    expect(saros139[0]?.next.epochSeconds).toBe(eclipseInstant);
    expect(saros139[1]?.previous.epochSeconds).toBe(eclipseInstant);
  });

  it("filters a wide window at Nihil before producing markers and samples", () => {
    const instant = Date.parse("2026-07-15T00:00:00Z") / 1_000;
    const window = realtimeSarosWindowAt(instant, {
      period: "tera",
      minimumRarity: "nihil",
      sampleCount: 8,
      visibleSpikeLimit: 64,
    });

    expect(window.minimumRarity).toMatchObject({
      id: "nihil",
      familyId: "mythic",
      minimumRepeatLength: 10,
    });
    expect(window.segment.visibleSpikes.every((spike) => spike.repeatLength >= 10)).toBe(true);
    expect(
      [...window.pastSpikes, ...window.upcomingSpikes].every((spike) => spike.repeatLength >= 10),
    ).toBe(true);
  });

  it("preserves native eclipse geometry metadata", () => {
    const eclipseInstant = Date.parse("2024-04-08T18:18:29Z") / 1_000;
    const interval = activeSarosIntervals(eclipseInstant).find(
      (candidate) => candidate.saros === 139,
    );

    expect(interval?.previous).toMatchObject({
      epochSeconds: eclipseInstant,
      typeCode: 13,
      sequence: 30,
      seriesCount: 71,
      magnitude: 1.0566,
      gamma: 0.3431,
    });
  });

  it.each([-200_000_000_000, 100_000_000_000])(
    "rejects record context outside the canonical dataset: %s",
    (instant) => {
      expect(() => recordTemporalContextAt(instant)).toThrow(
        "outside the canonical eclipse dataset",
      );
    },
  );
});
