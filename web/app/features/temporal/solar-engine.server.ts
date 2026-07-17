import {
  journalEventContext,
  sarosRealtimeCoverageBounds,
  sarosRealtimeWindow,
  sarosSystemSnapshot,
  type SarosRealtimeWindow,
  type SarosRealtimeWindowOptions,
  type SarosRealtimePeriodId,
  type SarosInterval,
  type SarosSystemSnapshot,
  type SolarEclipsePoint,
} from "@exeligmos/temporal-core";

import rawSolarData from "./generated/solar-temporal-data.json";

type RawEclipse = readonly [
  epochSeconds: number,
  typeCode: number,
  sequence: number,
  magnitude: number | null,
  gamma: number | null,
];
type RawSeries = readonly [saros: number, eclipses: readonly RawEclipse[]];
interface RawSolarData {
  readonly schemaVersion: number;
  readonly sourceSha256: string;
  readonly series: readonly RawSeries[];
}

const solarData = rawSolarData as unknown as RawSolarData;

export const solarTemporalDataMetadata = Object.freeze({
  schemaVersion: solarData.schemaVersion,
  sourceSha256: solarData.sourceSha256,
  seriesCount: solarData.series.length,
  eclipseCount: solarData.series.reduce((sum, series) => sum + series[1].length, 0),
});

/** Return actual adjacent-eclipse intervals for every series active at the instant. */
export function activeSarosIntervals(instantEpochSeconds: number): readonly SarosInterval[] {
  if (!Number.isFinite(instantEpochSeconds)) {
    throw new RangeError("Temporal instant must be finite.");
  }
  return solarData.series.flatMap(([saros, eclipses]) => {
    const first = eclipses[0]?.[0];
    const last = eclipses.at(-1)?.[0];
    if (
      first === undefined ||
      last === undefined ||
      !(first < instantEpochSeconds && last > instantEpochSeconds)
    ) {
      return [];
    }
    const nextIndex = upperBound(eclipses, instantEpochSeconds);
    const previous = eclipses[nextIndex - 1];
    const next = eclipses[nextIndex];
    if (previous === undefined || next === undefined) return [];
    return [
      {
        saros,
        previous: eclipsePoint(previous, eclipses.length),
        next: eclipsePoint(next, eclipses.length),
      },
    ];
  });
}

export function systemSnapshotAt(
  instantEpochSeconds: number,
  harmonicDepth = 7,
): SarosSystemSnapshot {
  return sarosSystemSnapshot(
    activeSarosIntervals(instantEpochSeconds),
    instantEpochSeconds,
    harmonicDepth,
  );
}

/** Realtime epoch-aligned period waveform with exact 10-digit global Spikes. */
export function realtimeSarosWindowAt(
  instantEpochSeconds: number,
  options: SarosRealtimeWindowOptions | number = {},
): SarosRealtimeWindow {
  const periodId = typeof options === "number" ? "mili" : (options.period ?? "mili");
  const coverage = sarosRealtimeCoverageBounds(instantEpochSeconds, periodId);
  return sarosRealtimeWindow(
    sarosIntervalsOverlapping(coverage.startEpochSeconds, coverage.endEpochSeconds),
    instantEpochSeconds,
    options,
  );
}

/**
 * Return all eclipse intervals needed by a client-owned realtime window. The
 * shell requests Tera coverage once, then can zoom to every smaller period
 * without another route load, including while a segment crosses an eclipse.
 */
export function realtimeSarosIntervalsAt(
  instantEpochSeconds: number,
  maximumPeriod: SarosRealtimePeriodId = "tera",
): readonly SarosInterval[] {
  const coverage = sarosRealtimeCoverageBounds(instantEpochSeconds, maximumPeriod);
  return sarosIntervalsOverlapping(coverage.startEpochSeconds, coverage.endEpochSeconds);
}

export function recordTemporalContextAt(instantEpochSeconds: number) {
  const intervals = activeSarosIntervals(instantEpochSeconds);
  if (intervals.length === 0) {
    throw new RangeError("Could not derive a Saros context outside the canonical eclipse dataset.");
  }
  const context = journalEventContext(intervals, instantEpochSeconds, 8);
  if (context.spikes.length === 0 || context.closestSarosPhase === undefined) {
    throw new RangeError("Could not derive a complete Saros context for this instant.");
  }
  return context;
}

function eclipsePoint(raw: RawEclipse, seriesCount: number): SolarEclipsePoint {
  return {
    epochSeconds: raw[0],
    typeCode: raw[1],
    sequence: raw[2],
    seriesCount,
    ...(raw[3] === null ? {} : { magnitude: raw[3] }),
    ...(raw[4] === null ? {} : { gamma: raw[4] }),
  };
}

function sarosIntervalsOverlapping(
  startEpochSeconds: number,
  endEpochSeconds: number,
): readonly SarosInterval[] {
  if (!(endEpochSeconds > startEpochSeconds)) return [];
  return solarData.series.flatMap(([saros, eclipses]) => {
    const intervals: SarosInterval[] = [];
    for (let index = 1; index < eclipses.length; index += 1) {
      const previous = eclipses[index - 1];
      const next = eclipses[index];
      if (previous === undefined || next === undefined) continue;
      if (previous[0] < endEpochSeconds && next[0] > startEpochSeconds) {
        intervals.push({
          saros,
          previous: eclipsePoint(previous, eclipses.length),
          next: eclipsePoint(next, eclipses.length),
        });
      }
    }
    return intervals;
  });
}

function upperBound(eclipses: readonly RawEclipse[], target: number): number {
  let low = 0;
  let high = eclipses.length;
  while (low < high) {
    const middle = (low + high) >> 1;
    const timestamp = eclipses[middle]?.[0] ?? Number.POSITIVE_INFINITY;
    if (timestamp <= target) low = middle + 1;
    else high = middle;
  }
  return low;
}
