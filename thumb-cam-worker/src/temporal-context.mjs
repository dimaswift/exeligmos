import rawSolarData from "../../web/app/features/temporal/generated/solar-temporal-data.json" with { type: "json" };

import { journalEventContext } from "./generated/temporal-core.mjs";

const CONTEXT_HARMONIC_DEPTH = 8;
const solarData = rawSolarData;

export const solarTemporalDataMetadata = Object.freeze({
  sourceSha256: solarData.sourceSha256,
  seriesCount: solarData.series.length,
  eclipseCount: solarData.series.reduce(
    (sum, [, eclipses]) => sum + eclipses.length,
    0,
  ),
});

/**
 * Derive the same canonical context used when a record is created by the web
 * and iOS-facing flow. The camera timestamp, never worker wall-clock time, is
 * the temporal instant.
 */
export function recordTemporalContextAt(occurredAt) {
  const instantEpochSeconds =
    typeof occurredAt === "number"
      ? occurredAt
      : Date.parse(occurredAt) / 1_000;
  if (!Number.isFinite(instantEpochSeconds)) {
    throw new RangeError("Record occurrence time must be a valid instant.");
  }

  const intervals = activeSarosIntervals(instantEpochSeconds);
  if (intervals.length === 0) {
    throw new RangeError(
      "Could not derive a Saros context outside the canonical eclipse dataset.",
    );
  }
  const context = journalEventContext(
    intervals,
    instantEpochSeconds,
    CONTEXT_HARMONIC_DEPTH,
  );
  if (context.spikes.length === 0 || context.closestSarosPhase === undefined) {
    throw new RangeError(
      "Could not derive a complete Saros context for this instant.",
    );
  }
  return context;
}

function activeSarosIntervals(instantEpochSeconds) {
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

function eclipsePoint(raw, seriesCount) {
  return {
    epochSeconds: raw[0],
    typeCode: raw[1],
    sequence: raw[2],
    seriesCount,
    ...(raw[3] === null ? {} : { magnitude: raw[3] }),
    ...(raw[4] === null ? {} : { gamma: raw[4] }),
  };
}

function upperBound(eclipses, target) {
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
