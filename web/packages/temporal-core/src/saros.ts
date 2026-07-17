import { canonicalCatalog } from "@exeligmos/domain-catalog";

import {
  classifyRarity,
  clockReading,
  pulseDuration,
  rarityDescriptor,
  type ClockReading,
  type RarityDescriptor,
  type RarityId,
  type SemanticColorToken,
} from "./index.js";

export const CANONICAL_CONTEXT_DEPTH = 8;
export const DEFAULT_SAROS_GRID_DEPTH = 7;
export const SAROS_PULSE_DEPTH = 6;
export const SAROS_PULSE_PARENT_EXPONENT = 3;
/** Two five-arm glyphs, ordered most-significant first, form this carrier. */
export const SAROS_REALTIME_PHASE_DEPTH = 10;
/** The user-selectable Saros series used when no pulse anchor is configured. */
export const DEFAULT_SAROS_PULSE_ANCHOR = 141;
/** A pulse tick is presented as two five-digit glyphs, MSB first. */
export const SAROS_PULSE_TICK_DEPTH = SAROS_REALTIME_PHASE_DEPTH;
/** Triplex is the first MSB-qualified realtime Spike: seven repeated trailing octal digits. */
export const SAROS_REALTIME_MINIMUM_REPEAT_LENGTH = 7;
/** Canonical average Milisaros, aligned to Unix epoch for the global realtime window. */
export const MILISAROS_WINDOW_SECONDS = pulseDuration(canonicalCatalog, "mili").seconds;
export const DEFAULT_REALTIME_VISIBLE_SPIKE_LIMIT = 512;

export type SarosRealtimePeriodId = "mili" | "saros" | "kilo" | "mega" | "giga" | "tera";
export type SarosRealtimeMinimumRarity = "triplex" | "duplex" | "simplex" | "nihil";

export interface SarosRealtimePeriodDefinition {
  readonly id: SarosRealtimePeriodId;
  readonly title: string;
  readonly exponent: number;
  readonly durationSeconds: number;
  readonly semanticColorToken: SemanticColorToken;
}

export interface SarosRealtimeRarityDefinition {
  readonly id: SarosRealtimeMinimumRarity;
  readonly title: string;
  readonly familyId: "rare" | "epic" | "legendary" | "mythic";
  readonly minimumRepeatLength: 7 | 8 | 9 | 10;
  readonly semanticColorToken: SemanticColorToken;
}

/** Smallest to largest, matching the realtime period-cycle control. */
export const SAROS_REALTIME_PERIODS: readonly SarosRealtimePeriodDefinition[] = Object.freeze([
  realtimePeriodDefinition("mili", "mili", "Mili"),
  realtimePeriodDefinition("saros", "saros", "Saros"),
  realtimePeriodDefinition("kilo", "kilo", "Kilo"),
  realtimePeriodDefinition("mega", "mega", "Mega"),
  realtimePeriodDefinition("giga", "giga", "Giga"),
  // Tera is the public name for the catalog's historical rollover period.
  realtimePeriodDefinition("tera", "rollover", "Tera"),
]);

export const SAROS_REALTIME_RARITIES: readonly SarosRealtimeRarityDefinition[] = Object.freeze([
  realtimeRarityDefinition("triplex", "rare", 7),
  realtimeRarityDefinition("duplex", "epic", 8),
  realtimeRarityDefinition("simplex", "legendary", 9),
  realtimeRarityDefinition("nihil", "mythic", 10),
]);

export interface SolarEclipsePoint {
  readonly epochSeconds: number;
  readonly typeCode: number;
  readonly sequence: number;
  readonly seriesCount: number;
  readonly magnitude?: number;
  readonly gamma?: number;
}

export interface SarosInterval {
  readonly saros: number;
  readonly previous: SolarEclipsePoint;
  readonly next: SolarEclipsePoint;
}

export interface SarosPulseUnitReading {
  readonly id: "tera" | "giga" | "mega" | "kilo" | "saros" | "mili" | "nano";
  readonly title: string;
  /** Tera is the parent period and therefore has no digit in the six-arm pulse glyph. */
  readonly digit: number | null;
  readonly exponent: number;
  readonly exactDurationSeconds: number;
  readonly averageDurationSeconds: number;
  readonly progress: number;
  readonly timeUntilNextSeconds: number;
}

export interface SarosPulseReading {
  readonly saros: number;
  readonly octalAddress: string;
  readonly glyphDepth: typeof SAROS_PULSE_DEPTH;
  readonly trailingZeroCount: number;
  readonly color: "white" | "blue" | "purple" | "yellow" | "red";
  readonly units: readonly SarosPulseUnitReading[];
}

export type SarosPulseTickColor = "neutral" | "blue" | "purple" | "yellow" | "red";
export type SarosPulseImminentUnit = "kilo" | "mega" | "giga" | "tera";

/**
 * The high-resolution phase of one anchored Saros interval. The two glyph
 * addresses are deliberately named so consumers cannot accidentally render the
 * least-significant half first.
 */
export interface SarosPulseTickReading {
  readonly saros: number;
  readonly octalAddress: string;
  readonly glyphDepth: typeof SAROS_PULSE_TICK_DEPTH;
  readonly mostSignificantGlyphAddress: string;
  readonly leastSignificantGlyphAddress: string;
  readonly color: SarosPulseTickColor;
  readonly imminentUnit: SarosPulseImminentUnit | null;
  readonly nextTickEpochSeconds: number;
  readonly timeUntilNextTickSeconds: number;
  readonly units: readonly SarosPulseUnitReading[];
}

export interface SarosGridReading {
  readonly saros: number;
  readonly clock: ClockReading;
  readonly rarity: RarityDescriptor;
  readonly pulse: SarosPulseReading;
}

export interface SarosSpikeReference {
  readonly saros: number;
  readonly unixTimestamp: number;
  readonly octalAddress: string;
  readonly harmonicDepth: number;
  readonly rarityRawValue: RarityId;
  readonly gamma?: number;
  readonly magnitude?: number;
  readonly eclipseTypeRawValue?: string;
  readonly sarosSequence?: number;
  readonly sarosSeriesCount?: number;
  readonly seriesProgressesSouthToNorth?: boolean;
}

export interface JournalSarosPhaseReference {
  readonly saros: number;
  readonly octalAddress: string;
  readonly harmonicDepth: number;
  readonly rarityRawValue: RarityId;
}

export interface JournalEventContext {
  readonly [key: string]: unknown;
  readonly unixTimestamp: number;
  readonly spikes: readonly SarosSpikeReference[];
  readonly closestSarosPhase?: JournalSarosPhaseReference;
  readonly energy: number;
  readonly energyPercent: number;
  readonly slope: number;
  readonly momentum: number;
  readonly directionRawValue: "ascending" | "descending" | "flat";
  readonly extremumRawValue: "none" | "localMaximum" | "localMinimum";
  readonly majorPeriodSeconds: number;
}

export interface SarosUpcomingFlip extends SarosSpikeReference {
  readonly timeUntilSeconds: number;
  readonly title: string;
  readonly patternLabel: string;
}

export interface SarosWaveformPoint {
  readonly epochSeconds: number;
  readonly position: number;
  readonly energy: number;
}

export interface SarosRealtimeSpike {
  /** Stable within a generated dataset; timestamps deliberately retain sub-second precision. */
  readonly id: string;
  readonly saros: number;
  readonly unixTimestamp: number;
  readonly octalAddress: string;
  readonly harmonicDepth: typeof SAROS_REALTIME_PHASE_DEPTH;
  readonly mostSignificantGlyphAddress: string;
  readonly leastSignificantGlyphAddress: string;
  /** Compact event presentation uses the five most-significant phase digits. */
  readonly listGlyphAddress: string;
  /** Depth-10 qualification suffix used by the event schedule/filter. */
  readonly repeatLength: number;
  /** Repeated suffix visible in the five-digit MSB presentation, or zero for Common. */
  readonly presentationRepeatLength: number;
  readonly repeatedDigit: number;
  readonly rarityRawValue: RarityId;
  readonly rarityTitle: string;
  readonly rarityFamilyTitle: string;
  readonly rarityOrder: number;
  readonly rarityRank: number;
  readonly patternLabel: string;
  readonly semanticColorToken: RarityDescriptor["semanticColorToken"];
  readonly digitSemanticColorToken: RarityDescriptor["digitSemanticColorToken"];
  readonly gamma?: number;
  readonly magnitude?: number;
  readonly eclipseTypeRawValue?: string;
  readonly sarosSequence?: number;
  readonly sarosSeriesCount?: number;
  readonly seriesProgressesSouthToNorth?: boolean;
}

export interface SarosRealtimeWaveformSample extends SarosWaveformPoint {
  /** Midpoint/Voronoi owner used to color this part of the waveform. */
  readonly governingSpikeId: string | null;
  readonly rarityRawValue: RarityId | null;
  readonly semanticColorToken: RarityDescriptor["semanticColorToken"] | null;
}

export interface SarosRealtimeSegment {
  /** Signed epoch-aligned segment index. */
  readonly index: number;
  readonly startEpochSeconds: number;
  readonly endEpochSeconds: number;
  readonly periodId: SarosRealtimePeriodId;
  readonly durationSeconds: number;
  /** Clamped playhead location at the snapshot instant. */
  readonly progress: number;
  readonly visibleSpikes: readonly SarosRealtimeSpike[];
  /** Exact candidate count even when the marker list is bucketed. */
  readonly totalSpikeCount: number;
  readonly visibleSpikesTruncated: boolean;
  readonly spikeBuckets: readonly SarosRealtimeSpikeBucket[];
  readonly samples: readonly SarosRealtimeWaveformSample[];
}

export interface SarosRealtimeSpikeBucket {
  readonly startEpochSeconds: number;
  readonly endEpochSeconds: number;
  readonly count: number;
  readonly representativeSpike?: SarosRealtimeSpike;
}

export interface SarosRealtimeWindowOptions {
  readonly period?: SarosRealtimePeriodId;
  readonly minimumRarity?: SarosRealtimeMinimumRarity;
  readonly sampleCount?: number;
  readonly visibleSpikeLimit?: number;
}

export interface SarosRealtimeIncomingPhase {
  readonly saros: number;
  readonly octalAddress: string;
  readonly harmonicDepth: typeof SAROS_REALTIME_PHASE_DEPTH;
  /** Explicit display order: render this glyph first. */
  readonly mostSignificantGlyphAddress: string;
  /** Explicit display order: render this glyph second. */
  readonly leastSignificantGlyphAddress: string;
}

export interface SarosRealtimeWindow {
  readonly instantEpochSeconds: number;
  readonly period: SarosRealtimePeriodDefinition;
  readonly minimumRarity: SarosRealtimeRarityDefinition;
  readonly segment: SarosRealtimeSegment;
  readonly previousSegment: SarosRealtimeSegment;
  readonly nextSegment: SarosRealtimeSegment;
  /** Native ordering: newest first. */
  readonly pastSpikes: readonly SarosRealtimeSpike[];
  /** Native ordering: soonest first. */
  readonly upcomingSpikes: readonly SarosRealtimeSpike[];
  readonly incomingSpike: SarosRealtimeSpike;
  /** The incoming event address, not the carrier's current-time address. */
  readonly incomingPhase: SarosRealtimeIncomingPhase;
}

export interface SarosSystemSnapshot {
  readonly instantEpochSeconds: number;
  readonly harmonicDepth: number;
  readonly grid: readonly SarosGridReading[];
  readonly context: JournalEventContext;
  readonly candidateSpikes: readonly SarosSpikeReference[];
  readonly nearestUpcomingFlip?: SarosUpcomingFlip;
  readonly pulse?: SarosPulseReading;
}

const pulseGlyphUnitIds = ["giga", "mega", "kilo", "saros", "mili", "nano"] as const;
const pulseUnitIds = ["tera", ...pulseGlyphUnitIds] as const;

export interface RepdigitPeriodInput {
  readonly basePeriodSeconds: number;
  readonly harmonicDepth: number;
  readonly wildcardPrefixCount: number;
  readonly repeatedDigit?: number;
}

export function sarosRealtimePeriod(
  id: SarosRealtimePeriodId = "mili",
): SarosRealtimePeriodDefinition {
  const period = SAROS_REALTIME_PERIODS.find((candidate) => candidate.id === id);
  if (period === undefined) throw new RangeError(`Unknown realtime Saros period ${id}.`);
  return period;
}

export function sarosRealtimeRarity(
  id: SarosRealtimeMinimumRarity = "triplex",
): SarosRealtimeRarityDefinition {
  const rarity = SAROS_REALTIME_RARITIES.find((candidate) => candidate.id === id);
  if (rarity === undefined) throw new RangeError(`Unknown realtime Saros rarity ${id}.`);
  return rarity;
}

/** Coverage required to preload previous/current/next epoch-aligned segments. */
export function sarosRealtimeCoverageBounds(
  instantEpochSeconds: number,
  periodId: SarosRealtimePeriodId = "mili",
): { readonly startEpochSeconds: number; readonly endEpochSeconds: number } {
  if (!Number.isFinite(instantEpochSeconds)) {
    throw new RangeError("Realtime Saros instant must be finite.");
  }
  const duration = sarosRealtimePeriod(periodId).durationSeconds;
  const index = Math.floor(instantEpochSeconds / duration);
  return {
    startEpochSeconds: (index - 1) * duration,
    endEpochSeconds: (index + 2) * duration,
  };
}

/**
 * Native repunit landmark duration. A subrarity's period is its repeated digit
 * multiplied by the normalized 00...011...1 landmark inside the carrier.
 */
export function repdigitPeriodSeconds(input: RepdigitPeriodInput): number {
  if (!Number.isFinite(input.basePeriodSeconds) || input.basePeriodSeconds <= 0) {
    throw new RangeError("Repdigit base period must be positive and finite.");
  }
  if (!Number.isSafeInteger(input.harmonicDepth)) {
    throw new RangeError("Repdigit harmonic depth must be a safe integer.");
  }
  if (!Number.isSafeInteger(input.wildcardPrefixCount) || input.wildcardPrefixCount < 0) {
    throw new RangeError("Repdigit wildcard prefix count must be a nonnegative safe integer.");
  }
  const repeatedDigit = input.repeatedDigit ?? 1;
  if (
    !Number.isSafeInteger(repeatedDigit) ||
    repeatedDigit < 0 ||
    repeatedDigit >= canonicalCatalog.radix.value
  ) {
    throw new RangeError(
      `Repdigit value must be between 0 and ${canonicalCatalog.radix.value - 1}.`,
    );
  }

  const carrierDigits = clamp(
    input.harmonicDepth,
    canonicalCatalog.harmonics.presentationDepth.minimum,
    canonicalCatalog.harmonics.presentationDepth.maximum,
  );
  const suffixLength = clamp(carrierDigits - input.wildcardPrefixCount, 1, carrierDigits);
  const prefixZeros = carrierDigits - suffixLength;
  const repunitWithinSuffix =
    (1 - canonicalCatalog.radix.value ** -suffixLength) / (canonicalCatalog.radix.value - 1);
  const normalizedLandmark = repunitWithinSuffix / canonicalCatalog.radix.value ** prefixZeros;
  return input.basePeriodSeconds * normalizedLandmark * Math.max(repeatedDigit, 1);
}

/** The native six-digit pulse, derived from an actual eclipse interval rather than a mean epoch. */
export function sarosPulseReading(
  interval: SarosInterval,
  instantEpochSeconds: number,
  harmonicDepth = DEFAULT_SAROS_GRID_DEPTH,
): SarosPulseReading {
  const clock = intervalClock(interval, instantEpochSeconds, harmonicDepth);
  const parentBinCount = canonicalCatalog.radix.value ** SAROS_PULSE_PARENT_EXPONENT;
  const pulseBinCount = canonicalCatalog.radix.value ** SAROS_PULSE_DEPTH;
  const localPhase = positiveFraction(clock.phase * parentBinCount);
  const pulseIndex = Math.min(Math.floor(localPhase * pulseBinCount), pulseBinCount - 1);
  const octalAddress = pulseIndex
    .toString(canonicalCatalog.radix.value)
    .padStart(SAROS_PULSE_DEPTH, "0");
  const intervalDuration = interval.next.epochSeconds - interval.previous.epochSeconds;
  const units = pulseUnitIds.map((id): SarosPulseUnitReading => {
    const catalogId = id === "tera" ? "rollover" : id;
    const unit = canonicalCatalog.time.units.find((candidate) => candidate.id === catalogId);
    if (unit === undefined) throw new RangeError(`Missing pulse unit ${catalogId}.`);
    const glyphIndex = pulseGlyphUnitIds.indexOf(id as (typeof pulseGlyphUnitIds)[number]);
    const divisions = canonicalCatalog.radix.value ** unit.exponent;
    const scaled = clock.phase * divisions;
    const progress = positiveFraction(scaled);
    const exactDurationSeconds = intervalDuration / divisions;
    return {
      id,
      title: id === "tera" ? "Tera" : unit.title,
      digit: glyphIndex < 0 ? null : Number(octalAddress[glyphIndex] ?? "0"),
      exponent: unit.exponent,
      exactDurationSeconds,
      averageDurationSeconds: pulseDuration(canonicalCatalog, catalogId).seconds,
      progress,
      timeUntilNextSeconds: (1 - progress) * exactDurationSeconds,
    };
  });
  const trailingZeroCount = [...octalAddress].reverse().findIndex((digit) => digit !== "0");
  const normalizedTrailingZeroCount =
    trailingZeroCount < 0 ? octalAddress.length : trailingZeroCount;
  return {
    saros: interval.saros,
    octalAddress,
    glyphDepth: SAROS_PULSE_DEPTH,
    trailingZeroCount: normalizedTrailingZeroCount,
    color: pulseColor(normalizedTrailingZeroCount),
    units,
  };
}

/** Resolve the configured pulse anchor without silently substituting another series. */
export function sarosPulseAnchorInterval(
  intervals: readonly SarosInterval[],
  instantEpochSeconds: number,
  anchorSaros = DEFAULT_SAROS_PULSE_ANCHOR,
): SarosInterval | undefined {
  if (!Number.isFinite(instantEpochSeconds)) {
    throw new RangeError("Saros pulse anchor instant must be finite.");
  }
  if (!Number.isSafeInteger(anchorSaros) || anchorSaros <= 0) {
    throw new RangeError("Saros pulse anchor must be a positive safe integer.");
  }
  const candidates = intervals
    .filter((interval) => interval.saros === anchorSaros)
    .sort((left, right) => left.previous.epochSeconds - right.previous.epochSeconds);
  const halfOpenMatch = candidates.find(
    (interval) =>
      interval.previous.epochSeconds <= instantEpochSeconds &&
      instantEpochSeconds < interval.next.epochSeconds,
  );
  if (halfOpenMatch !== undefined) return halfOpenMatch;

  // Retain a reading at the final known eclipse when no following interval was supplied.
  return candidates.find((interval) => interval.next.epochSeconds === instantEpochSeconds);
}

/**
 * Read the current 10-octal-digit phase of an anchored Saros interval.
 *
 * Urgency is based on the exact duration of this eclipse interval. The rarest
 * imminent boundary wins when lead windows overlap: Tera, Giga, Mega, Kilo.
 */
export function sarosPulseTickReading(
  interval: SarosInterval,
  instantEpochSeconds: number,
): SarosPulseTickReading {
  if (!Number.isFinite(instantEpochSeconds)) {
    throw new RangeError("Saros pulse tick instant must be finite.");
  }

  const duration = interval.next.epochSeconds - interval.previous.epochSeconds;
  if (!Number.isFinite(duration) || duration <= 0) {
    throw new RangeError("Saros pulse tick interval must have a positive finite duration.");
  }

  const pulse = sarosPulseReading(interval, instantEpochSeconds);
  const rawPhase = (instantEpochSeconds - interval.previous.epochSeconds) / duration;
  const phase = clamp(rawPhase, 0, 1 - Number.EPSILON);
  const binCount = canonicalCatalog.radix.value ** SAROS_PULSE_TICK_DEPTH;
  const scaled = phase * binCount;
  const binIndex = Math.min(Math.floor(scaled), binCount - 1);
  const octalAddress = binIndex
    .toString(canonicalCatalog.radix.value)
    .padStart(SAROS_PULSE_TICK_DEPTH, "0");
  const nextTickEpochSeconds =
    interval.previous.epochSeconds + (Math.min(binIndex + 1, binCount) / binCount) * duration;
  const imminentUnit = pulseImminentUnit(pulse.units);

  return {
    saros: interval.saros,
    octalAddress,
    glyphDepth: SAROS_PULSE_TICK_DEPTH,
    mostSignificantGlyphAddress: octalAddress.slice(0, 5),
    leastSignificantGlyphAddress: octalAddress.slice(5, 10),
    color: pulseTickColor(imminentUnit),
    imminentUnit,
    nextTickEpochSeconds,
    timeUntilNextTickSeconds: nextTickEpochSeconds - instantEpochSeconds,
    units: pulse.units,
  };
}

/** Build the same 40-series/live-context snapshot consumed by the native Saros Grid. */
export function sarosSystemSnapshot(
  intervals: readonly SarosInterval[],
  instantEpochSeconds: number,
  harmonicDepth = DEFAULT_SAROS_GRID_DEPTH,
): SarosSystemSnapshot {
  const sortedIntervals = [...intervals].sort((left, right) => left.saros - right.saros);
  const grid = sortedIntervals.slice(0, 40).map((interval): SarosGridReading => {
    const clock = intervalClock(interval, instantEpochSeconds, harmonicDepth);
    const classification = classifyRarity(canonicalCatalog, {
      octalAddress: clock.octalAddress,
      harmonicDepth,
    });
    return {
      saros: interval.saros,
      clock,
      rarity: rarityDescriptor(canonicalCatalog, {
        rarityId: classification.rarityId,
        harmonicDepth,
      }),
      pulse: sarosPulseReading(interval, instantEpochSeconds, harmonicDepth),
    };
  });
  const candidateSpikes = sarosCandidateSpikes(sortedIntervals, instantEpochSeconds, harmonicDepth);
  const context = journalEventContext(
    sortedIntervals,
    instantEpochSeconds,
    harmonicDepth,
    candidateSpikes,
  );
  const nearestUpcomingFlip = nextUpcomingFlip(candidateSpikes, instantEpochSeconds);
  return {
    instantEpochSeconds,
    harmonicDepth,
    grid,
    context,
    candidateSpikes,
    nearestUpcomingFlip,
    pulse: grid[0]?.pulse,
  };
}

/** Canonical record context: two past and two future spikes at depth eight by default. */
export function journalEventContext(
  intervals: readonly SarosInterval[],
  instantEpochSeconds: number,
  harmonicDepth = CANONICAL_CONTEXT_DEPTH,
  suppliedCandidates?: readonly SarosSpikeReference[],
): JournalEventContext {
  const candidates =
    suppliedCandidates ?? sarosCandidateSpikes(intervals, instantEpochSeconds, harmonicDepth);
  const selected = selectContextSpikes(candidates, instantEpochSeconds);
  const closest = selected.reduce<SarosSpikeReference | undefined>((best, spike) => {
    if (best === undefined) return spike;
    return Math.abs(spike.unixTimestamp - instantEpochSeconds) <
      Math.abs(best.unixTimestamp - instantEpochSeconds)
      ? spike
      : best;
  }, undefined);
  const closestInterval =
    closest === undefined
      ? undefined
      : intervals.find((interval) => interval.saros === closest.saros);
  const closestClock =
    closestInterval === undefined
      ? undefined
      : intervalClock(closestInterval, instantEpochSeconds, harmonicDepth);
  const closestClassification =
    closestClock === undefined
      ? undefined
      : classifyRarity(canonicalCatalog, {
          octalAddress: closestClock.octalAddress,
          harmonicDepth,
        });
  const metrics = temporalWaveMetrics(selected, instantEpochSeconds);
  return {
    unixTimestamp: Math.trunc(instantEpochSeconds),
    spikes: selected,
    ...(closest !== undefined && closestClock !== undefined && closestClassification !== undefined
      ? {
          closestSarosPhase: {
            saros: closest.saros,
            octalAddress: closestClock.octalAddress,
            harmonicDepth,
            rarityRawValue: closestClassification.rarityId,
          },
        }
      : {}),
    ...metrics,
  };
}

/** Qualified Duplex/Simplex/Nihil candidates from every active series. */
export function sarosCandidateSpikes(
  intervals: readonly SarosInterval[],
  instantEpochSeconds: number,
  harmonicDepth: number,
): readonly SarosSpikeReference[] {
  const byKey = new Map<string, SarosSpikeReference>();
  const descriptors = eventRarityDescriptors(harmonicDepth);

  for (const interval of intervals) {
    const clock = intervalClock(interval, instantEpochSeconds, harmonicDepth);
    addSpike(byKey, boundarySpike(interval, interval.previous, harmonicDepth));
    addSpike(byKey, boundarySpike(interval, interval.next, harmonicDepth));

    for (const descriptor of descriptors) {
      const previousBin = qualifiedFlipBin(clock, descriptor, clock.binIndex, -1);
      if (previousBin !== undefined && previousBin > 0 && previousBin < clock.binCount) {
        addSpike(byKey, interiorSpike(interval, clock, descriptor, previousBin));
      }
      const nextBin = qualifiedFlipBin(clock, descriptor, Math.max(clock.binIndex - 1, -1), 1);
      if (nextBin !== undefined && nextBin > 0 && nextBin < clock.binCount) {
        addSpike(byKey, interiorSpike(interval, clock, descriptor, nextBin));
      }
    }
  }

  return [...byKey.values()].sort(compareSpikes);
}

export function selectContextSpikes(
  spikes: readonly SarosSpikeReference[],
  instantEpochSeconds: number,
): readonly SarosSpikeReference[] {
  const past = spikes
    .filter((spike) => spike.unixTimestamp <= instantEpochSeconds)
    .sort((left, right) => right.unixTimestamp - left.unixTimestamp)
    .slice(0, 2)
    .reverse();
  const future = spikes
    .filter((spike) => spike.unixTimestamp > instantEpochSeconds)
    .sort((left, right) => left.unixTimestamp - right.unixTimestamp)
    .slice(0, 2);
  const selected = [...past, ...future];
  if (selected.length >= 4) return selected;
  return [...spikes]
    .sort(
      (left, right) =>
        Math.abs(left.unixTimestamp - instantEpochSeconds) -
        Math.abs(right.unixTimestamp - instantEpochSeconds),
    )
    .slice(0, 4)
    .sort(compareSpikes);
}

export function waveformSamples(
  spikes: readonly SarosSpikeReference[],
  startEpochSeconds: number,
  endEpochSeconds: number,
  sampleCount = 160,
): readonly SarosWaveformPoint[] {
  if (!(endEpochSeconds > startEpochSeconds) || sampleCount < 2) return [];
  const components = temporalComponents(spikes);
  const duration = endEpochSeconds - startEpochSeconds;
  return Array.from({ length: sampleCount }, (_, index) => {
    const position = index / (sampleCount - 1);
    const epochSeconds = startEpochSeconds + duration * position;
    return {
      epochSeconds,
      position,
      energy: totalEnergy(components, epochSeconds),
    };
  });
}

/**
 * Build the selected epoch-aligned realtime window used by the live Saros display.
 *
 * Periods use canonical average durations so every client advances at the same
 * instant. Spike event times and addresses still come from each series' real
 * adjacent-eclipse interval. Existing record-context candidates intentionally
 * remain on their native depth-eight Duplex+ contract.
 */
export function sarosRealtimeWindow(
  intervals: readonly SarosInterval[],
  instantEpochSeconds: number,
  rawOptions: SarosRealtimeWindowOptions | number = {},
): SarosRealtimeWindow {
  if (!Number.isFinite(instantEpochSeconds)) {
    throw new RangeError("Realtime Saros instant must be finite.");
  }
  const options = resolveRealtimeWindowOptions(rawOptions);
  const { period, minimumRarity, sampleCount, visibleSpikeLimit } = options;
  const coverage = sarosRealtimeCoverageBounds(instantEpochSeconds, period.id);
  const usableIntervals = intervals
    .filter(
      (interval) =>
        Number.isFinite(interval.previous.epochSeconds) &&
        Number.isFinite(interval.next.epochSeconds) &&
        interval.previous.epochSeconds < interval.next.epochSeconds &&
        interval.previous.epochSeconds < coverage.endEpochSeconds &&
        interval.next.epochSeconds > coverage.startEpochSeconds,
    )
    .sort(compareIntervals);
  if (usableIntervals.length === 0) {
    throw new RangeError("Realtime Saros window requires eclipse intervals covering its period.");
  }
  const activeIntervals = activeRealtimeIntervals(usableIntervals, instantEpochSeconds);
  if (activeIntervals.length === 0) {
    throw new RangeError("Realtime Saros window requires at least one active eclipse interval.");
  }

  // Extra bracketing events keep the midpoint-governed waveform correct in the
  // previous and next preloaded segments as well as the visible one.
  const expandedPast = collectGlobalRealtimeSpikes(
    activeIntervals,
    instantEpochSeconds,
    16,
    "past",
    minimumRarity.minimumRepeatLength,
  );
  const expandedUpcoming = collectGlobalRealtimeSpikes(
    activeIntervals,
    instantEpochSeconds,
    16,
    "future",
    minimumRarity.minimumRepeatLength,
  );
  const incomingSpike = expandedUpcoming[0];
  if (incomingSpike === undefined) {
    throw new RangeError("Could not derive an incoming Triplex-or-rarer Saros spike.");
  }

  const currentIndex = Math.floor(instantEpochSeconds / period.durationSeconds);
  const bareSegments = [currentIndex - 1, currentIndex, currentIndex + 1].map((index) =>
    realtimeSegmentBounds(index, instantEpochSeconds, period),
  );
  const visibleByIndex = new Map(
    bareSegments.map((segment) => [
      segment.index,
      realtimeSpikesForSegment(
        usableIntervals,
        segment.startEpochSeconds,
        segment.endEpochSeconds,
        minimumRarity.minimumRepeatLength,
        visibleSpikeLimit,
      ),
    ]),
  );
  const waveformContext = uniqueRealtimeSpikes([
    ...expandedPast,
    ...expandedUpcoming,
    ...[...visibleByIndex.values()].flatMap((visible) => visible.spikes),
    ...bareSegments.flatMap((segment) =>
      realtimeWaveformBrackets(
        usableIntervals,
        segment.startEpochSeconds,
        segment.endEpochSeconds,
        sampleCount,
        minimumRarity.minimumRepeatLength,
      ),
    ),
  ]).sort(compareRealtimeSpikes);
  const segments = bareSegments.map((segment) =>
    completeRealtimeSegment(
      segment,
      visibleByIndex.get(segment.index) ?? emptyRealtimeVisibleSpikes,
      waveformContext,
      sampleCount,
    ),
  );
  const previousSegment = segments[0];
  const segment = segments[1];
  const nextSegment = segments[2];
  if (previousSegment === undefined || segment === undefined || nextSegment === undefined) {
    throw new Error("Realtime Saros segment construction failed.");
  }

  return {
    instantEpochSeconds,
    period,
    minimumRarity,
    previousSegment,
    segment,
    nextSegment,
    pastSpikes: expandedPast.slice(0, 8),
    upcomingSpikes: expandedUpcoming.slice(0, 4),
    incomingSpike,
    incomingPhase: {
      saros: incomingSpike.saros,
      octalAddress: incomingSpike.octalAddress,
      harmonicDepth: SAROS_REALTIME_PHASE_DEPTH,
      mostSignificantGlyphAddress: incomingSpike.mostSignificantGlyphAddress,
      leastSignificantGlyphAddress: incomingSpike.leastSignificantGlyphAddress,
    },
  };
}

type BareRealtimeSegment = Omit<
  SarosRealtimeSegment,
  "visibleSpikes" | "totalSpikeCount" | "visibleSpikesTruncated" | "spikeBuckets" | "samples"
>;
type RealtimeSearchDirection = "past" | "future";

interface ResolvedRealtimeWindowOptions {
  readonly period: SarosRealtimePeriodDefinition;
  readonly minimumRarity: SarosRealtimeRarityDefinition;
  readonly sampleCount: number;
  readonly visibleSpikeLimit: number;
}

interface RealtimeVisibleSpikes {
  readonly spikes: readonly SarosRealtimeSpike[];
  readonly totalCount: number;
  readonly truncated: boolean;
  readonly buckets: readonly SarosRealtimeSpikeBucket[];
}

const emptyRealtimeVisibleSpikes: RealtimeVisibleSpikes = Object.freeze({
  spikes: [],
  totalCount: 0,
  truncated: false,
  buckets: [],
});

const realtimeBinCount = canonicalCatalog.radix.value ** SAROS_REALTIME_PHASE_DEPTH;
const realtimeCursorEpsilonSeconds = 0.000_001;

function resolveRealtimeWindowOptions(
  rawOptions: SarosRealtimeWindowOptions | number,
): ResolvedRealtimeWindowOptions {
  const options = typeof rawOptions === "number" ? { sampleCount: rawOptions } : rawOptions;
  const sampleCount = options.sampleCount ?? 160;
  const visibleSpikeLimit = options.visibleSpikeLimit ?? DEFAULT_REALTIME_VISIBLE_SPIKE_LIMIT;
  if (!Number.isSafeInteger(sampleCount) || sampleCount < 2 || sampleCount > 512) {
    throw new RangeError("Realtime waveform sample count must be an integer from 2 through 512.");
  }
  if (
    !Number.isSafeInteger(visibleSpikeLimit) ||
    visibleSpikeLimit < 8 ||
    visibleSpikeLimit > 4_096
  ) {
    throw new RangeError("Realtime visible Spike limit must be an integer from 8 through 4096.");
  }
  return {
    period: sarosRealtimePeriod(options.period ?? "mili"),
    minimumRarity: sarosRealtimeRarity(options.minimumRarity ?? "triplex"),
    sampleCount,
    visibleSpikeLimit,
  };
}

function activeRealtimeIntervals(
  intervals: readonly SarosInterval[],
  instantEpochSeconds: number,
): readonly SarosInterval[] {
  const bySaros = new Map<number, SarosInterval>();
  for (const interval of intervals) {
    if (
      interval.previous.epochSeconds <= instantEpochSeconds &&
      interval.next.epochSeconds > instantEpochSeconds
    ) {
      bySaros.set(interval.saros, interval);
    }
  }
  return [...bySaros.values()].sort(compareIntervals);
}

function compareIntervals(left: SarosInterval, right: SarosInterval): number {
  if (left.saros !== right.saros) return left.saros - right.saros;
  return left.previous.epochSeconds - right.previous.epochSeconds;
}

function realtimeStride(minimumRepeatLength: number): number {
  if (
    !Number.isSafeInteger(minimumRepeatLength) ||
    minimumRepeatLength < SAROS_REALTIME_MINIMUM_REPEAT_LENGTH ||
    minimumRepeatLength > SAROS_REALTIME_PHASE_DEPTH
  ) {
    throw new RangeError(
      `Realtime repeat length must be ${SAROS_REALTIME_MINIMUM_REPEAT_LENGTH}...${SAROS_REALTIME_PHASE_DEPTH}.`,
    );
  }
  return canonicalCatalog.radix.value ** minimumRepeatLength;
}

function realtimeSegmentBounds(
  index: number,
  instantEpochSeconds: number,
  period: SarosRealtimePeriodDefinition,
): BareRealtimeSegment {
  const startEpochSeconds = index * period.durationSeconds;
  const endEpochSeconds = (index + 1) * period.durationSeconds;
  return {
    index,
    periodId: period.id,
    startEpochSeconds,
    endEpochSeconds,
    durationSeconds: period.durationSeconds,
    progress: clamp((instantEpochSeconds - startEpochSeconds) / period.durationSeconds, 0, 1),
  };
}

function completeRealtimeSegment(
  segment: BareRealtimeSegment,
  visible: RealtimeVisibleSpikes,
  waveformContext: readonly SarosRealtimeSpike[],
  sampleCount: number,
): SarosRealtimeSegment {
  const sortedContext = [...waveformContext].sort(compareRealtimeSpikes);
  const baseSamples = waveformSamples(
    sortedContext.map(realtimeWaveReference),
    segment.startEpochSeconds,
    segment.endEpochSeconds,
    sampleCount,
  );
  return {
    ...segment,
    visibleSpikes: visible.spikes,
    totalSpikeCount: visible.totalCount,
    visibleSpikesTruncated: visible.truncated,
    spikeBuckets: visible.buckets,
    samples: baseSamples.map((sample): SarosRealtimeWaveformSample => {
      const governingSpike = midpointGoverningSpike(sortedContext, sample.epochSeconds);
      return {
        ...sample,
        governingSpikeId: governingSpike?.id ?? null,
        rarityRawValue: governingSpike?.rarityRawValue ?? null,
        semanticColorToken: governingSpike?.semanticColorToken ?? null,
      };
    }),
  };
}

function collectGlobalRealtimeSpikes(
  intervals: readonly SarosInterval[],
  instantEpochSeconds: number,
  count: number,
  direction: RealtimeSearchDirection,
  minimumRepeatLength: number,
): readonly SarosRealtimeSpike[] {
  const cursors = intervals.map((interval) =>
    direction === "past"
      ? previousRealtimeSpike(interval, instantEpochSeconds, minimumRepeatLength)
      : nextRealtimeSpike(interval, instantEpochSeconds, minimumRepeatLength),
  );
  const result: SarosRealtimeSpike[] = [];

  while (result.length < count) {
    let bestIndex = -1;
    for (let index = 0; index < cursors.length; index += 1) {
      const candidate = cursors[index];
      if (candidate === undefined) continue;
      const best = bestIndex < 0 ? undefined : cursors[bestIndex];
      if (
        best === undefined ||
        (direction === "past"
          ? comparePastRealtimeSpikes(candidate, best) < 0
          : compareRealtimeSpikes(candidate, best) < 0)
      ) {
        bestIndex = index;
      }
    }
    if (bestIndex < 0) break;
    const spike = cursors[bestIndex];
    const interval = intervals[bestIndex];
    if (spike === undefined || interval === undefined) break;
    result.push(spike);
    cursors[bestIndex] =
      direction === "past"
        ? previousRealtimeSpike(
            interval,
            spike.unixTimestamp - realtimeCursorEpsilonSeconds,
            minimumRepeatLength,
          )
        : nextRealtimeSpike(interval, spike.unixTimestamp, minimumRepeatLength);
  }

  return result;
}

function realtimeSpikesForSegment(
  intervals: readonly SarosInterval[],
  startEpochSeconds: number,
  endEpochSeconds: number,
  minimumRepeatLength: number,
  visibleSpikeLimit: number,
): RealtimeVisibleSpikes {
  const totalCount = realtimeSpikeCountInRange(
    intervals,
    startEpochSeconds,
    endEpochSeconds,
    minimumRepeatLength,
  );
  if (totalCount <= visibleSpikeLimit) {
    return {
      spikes: enumerateRealtimeSpikesInRange(
        intervals,
        startEpochSeconds,
        endEpochSeconds,
        minimumRepeatLength,
      ),
      totalCount,
      truncated: false,
      buckets: [],
    };
  }

  const duration = endEpochSeconds - startEpochSeconds;
  const buckets: SarosRealtimeSpikeBucket[] = [];
  // Always retain the sparse deepest landmarks (including eclipse boundaries)
  // before allocating the remaining marker budget to temporal buckets.
  const landmarks = enumerateRealtimeSpikesInRange(
    intervals,
    startEpochSeconds,
    endEpochSeconds,
    Math.max(minimumRepeatLength, 9),
  ).slice(0, visibleSpikeLimit);
  const representatives: SarosRealtimeSpike[] = [...landmarks];
  const remainingMarkerBudget = visibleSpikeLimit - landmarks.length;
  const bucketLimit = Math.max(remainingMarkerBudget, 1);
  for (let index = 0; index < bucketLimit; index += 1) {
    const bucketStart = startEpochSeconds + (duration * index) / bucketLimit;
    const bucketEnd = startEpochSeconds + (duration * (index + 1)) / bucketLimit;
    const count = realtimeSpikeCountInRange(intervals, bucketStart, bucketEnd, minimumRepeatLength);
    if (count === 0) continue;
    const representativeSpike =
      remainingMarkerBudget > 0
        ? representativeRealtimeSpike(intervals, bucketStart, bucketEnd, minimumRepeatLength)
        : undefined;
    if (representativeSpike !== undefined) representatives.push(representativeSpike);
    buckets.push({
      startEpochSeconds: bucketStart,
      endEpochSeconds: bucketEnd,
      count,
      ...(representativeSpike === undefined ? {} : { representativeSpike }),
    });
  }
  return {
    spikes: uniqueRealtimeSpikes(representatives).sort(compareRealtimeSpikes),
    totalCount,
    truncated: true,
    buckets,
  };
}

function enumerateRealtimeSpikesInRange(
  intervals: readonly SarosInterval[],
  startEpochSeconds: number,
  endEpochSeconds: number,
  minimumRepeatLength: number,
): readonly SarosRealtimeSpike[] {
  const result: SarosRealtimeSpike[] = [];
  for (const interval of intervals) {
    if (
      interval.previous.epochSeconds >= startEpochSeconds &&
      interval.previous.epochSeconds < endEpochSeconds
    ) {
      result.push(realtimeBoundarySpike(interval, interval.previous));
    }
    let cursor =
      Math.max(startEpochSeconds, interval.previous.epochSeconds) - realtimeCursorEpsilonSeconds;
    const intervalCount = realtimeSpikeCountInRange(
      [interval],
      startEpochSeconds,
      endEpochSeconds,
      minimumRepeatLength,
    );
    for (let count = 0; count <= intervalCount; count += 1) {
      const spike = nextRealtimeSpike(interval, cursor, minimumRepeatLength);
      if (spike === undefined || spike.unixTimestamp >= endEpochSeconds) break;
      if (spike.unixTimestamp >= startEpochSeconds) result.push(spike);
      if (spike.unixTimestamp >= interval.next.epochSeconds) break;
      cursor = spike.unixTimestamp;
    }
  }
  return uniqueRealtimeSpikes(result).sort(compareRealtimeSpikes);
}

function realtimeSpikeCountInRange(
  intervals: readonly SarosInterval[],
  startEpochSeconds: number,
  endEpochSeconds: number,
  minimumRepeatLength: number,
): number {
  if (!(endEpochSeconds > startEpochSeconds)) return 0;
  const boundaryIds = new Set<string>();
  let interiorCount = 0;
  for (const interval of intervals) {
    interiorCount += realtimeInteriorSpikeCount(
      interval,
      startEpochSeconds,
      endEpochSeconds,
      minimumRepeatLength,
    );
    for (const point of [interval.previous, interval.next]) {
      if (point.epochSeconds >= startEpochSeconds && point.epochSeconds < endEpochSeconds) {
        boundaryIds.add(`${interval.saros}:${point.epochSeconds}`);
      }
    }
  }
  return interiorCount + boundaryIds.size;
}

function realtimeInteriorSpikeCount(
  interval: SarosInterval,
  startEpochSeconds: number,
  endEpochSeconds: number,
  minimumRepeatLength: number,
): number {
  const overlapStart = Math.max(startEpochSeconds, interval.previous.epochSeconds);
  const overlapEnd = Math.min(endEpochSeconds, interval.next.epochSeconds);
  if (!(overlapEnd > overlapStart)) return 0;
  const duration = interval.next.epochSeconds - interval.previous.epochSeconds;
  const rawStart = ((overlapStart - interval.previous.epochSeconds) / duration) * realtimeBinCount;
  const rawEnd = ((overlapEnd - interval.previous.epochSeconds) / duration) * realtimeBinCount;
  const firstBin = Math.max(Math.ceil(rawStart - 0.000_001), 1);
  const finalBin = Math.min(Math.ceil(rawEnd - 0.000_001) - 1, realtimeBinCount - 1);
  if (finalBin < firstBin) return 0;

  const stride = realtimeStride(minimumRepeatLength);
  const repunit = (stride - 1) / (canonicalCatalog.radix.value - 1);
  let count = 0;
  for (let digit = 1; digit < canonicalCatalog.radix.value; digit += 1) {
    const offset = digit * repunit;
    const first = firstBin + positiveModulo(offset - firstBin, stride);
    if (first <= finalBin) count += Math.floor((finalBin - first) / stride) + 1;
  }
  return count;
}

function representativeRealtimeSpike(
  intervals: readonly SarosInterval[],
  startEpochSeconds: number,
  endEpochSeconds: number,
  minimumRepeatLength: number,
): SarosRealtimeSpike | undefined {
  // Pick the earliest event from the deepest available suffix. This retains
  // rare landmarks without materializing every Triplex in a Tera window.
  for (
    let repeatLength = SAROS_REALTIME_PHASE_DEPTH;
    repeatLength >= minimumRepeatLength;
    repeatLength -= 1
  ) {
    const spike = nextGlobalRealtimeSpikeInRange(
      intervals,
      startEpochSeconds,
      endEpochSeconds,
      repeatLength,
    );
    if (spike !== undefined) return spike;
  }
  return undefined;
}

function nextGlobalRealtimeSpikeInRange(
  intervals: readonly SarosInterval[],
  startEpochSeconds: number,
  endEpochSeconds: number,
  minimumRepeatLength: number,
): SarosRealtimeSpike | undefined {
  let best: SarosRealtimeSpike | undefined;
  for (const interval of intervals) {
    if (
      interval.previous.epochSeconds >= endEpochSeconds ||
      interval.next.epochSeconds < startEpochSeconds
    ) {
      continue;
    }
    const spike = nextRealtimeSpike(
      interval,
      Math.max(startEpochSeconds, interval.previous.epochSeconds) - realtimeCursorEpsilonSeconds,
      minimumRepeatLength,
    );
    if (
      spike !== undefined &&
      spike.unixTimestamp >= startEpochSeconds &&
      spike.unixTimestamp < endEpochSeconds &&
      (best === undefined || compareRealtimeSpikes(spike, best) < 0)
    ) {
      best = spike;
    }
  }
  return best;
}

function realtimeWaveformBrackets(
  intervals: readonly SarosInterval[],
  startEpochSeconds: number,
  endEpochSeconds: number,
  sampleCount: number,
  minimumRepeatLength: number,
): readonly SarosRealtimeSpike[] {
  const spikes: SarosRealtimeSpike[] = [];
  for (let index = 0; index < sampleCount; index += 1) {
    const position = index / (sampleCount - 1);
    const rawInstant = startEpochSeconds + (endEpochSeconds - startEpochSeconds) * position;
    const instant = Math.min(rawInstant, endEpochSeconds - realtimeCursorEpsilonSeconds);
    const active = activeRealtimeIntervals(intervals, instant);
    if (active.length === 0) continue;
    spikes.push(
      ...collectGlobalRealtimeSpikes(active, instant, 2, "past", minimumRepeatLength),
      ...collectGlobalRealtimeSpikes(active, instant, 2, "future", minimumRepeatLength),
    );
  }
  return uniqueRealtimeSpikes(spikes);
}

function previousRealtimeSpike(
  interval: SarosInterval,
  instantEpochSeconds: number,
  minimumRepeatLength: number,
): SarosRealtimeSpike | undefined {
  if (instantEpochSeconds < interval.previous.epochSeconds) return undefined;
  if (instantEpochSeconds >= interval.next.epochSeconds) {
    return realtimeBoundarySpike(interval, interval.next);
  }
  const binIndex = realtimeBinIndex(interval, instantEpochSeconds);
  let candidateBin = previousRealtimeRepdigitBin(binIndex + 1, minimumRepeatLength);
  let candidate: SarosRealtimeSpike | undefined;
  while (candidateBin !== undefined) {
    const reconstructed = realtimeInteriorSpike(interval, candidateBin);
    if (reconstructed.unixTimestamp <= instantEpochSeconds) {
      candidate = reconstructed;
      break;
    }
    candidateBin = previousRealtimeRepdigitBin(candidateBin - 1, minimumRepeatLength);
  }
  const boundary = realtimeBoundarySpike(interval, interval.previous);
  if (candidate === undefined) return boundary;
  return comparePastRealtimeSpikes(candidate, boundary) <= 0 ? candidate : boundary;
}

function nextRealtimeSpike(
  interval: SarosInterval,
  instantEpochSeconds: number,
  minimumRepeatLength: number,
): SarosRealtimeSpike | undefined {
  if (instantEpochSeconds >= interval.next.epochSeconds) return undefined;
  if (instantEpochSeconds < interval.previous.epochSeconds) {
    return realtimeBoundarySpike(interval, interval.previous);
  }
  const binIndex = realtimeBinIndex(interval, instantEpochSeconds);
  let candidateBin = nextRealtimeRepdigitBin(binIndex, minimumRepeatLength);
  let candidate: SarosRealtimeSpike | undefined;
  while (candidateBin !== undefined) {
    const reconstructed = realtimeInteriorSpike(interval, candidateBin);
    if (reconstructed.unixTimestamp > instantEpochSeconds) {
      candidate = reconstructed;
      break;
    }
    candidateBin = nextRealtimeRepdigitBin(candidateBin, minimumRepeatLength);
  }
  const boundary = realtimeBoundarySpike(interval, interval.next);
  if (candidate === undefined) return boundary;
  return compareRealtimeSpikes(candidate, boundary) <= 0 ? candidate : boundary;
}

function realtimeBinIndex(interval: SarosInterval, instantEpochSeconds: number): number {
  const duration = interval.next.epochSeconds - interval.previous.epochSeconds;
  if (!(duration > 0)) throw new RangeError("Realtime Saros interval must be positive.");
  const phase = clamp(
    (instantEpochSeconds - interval.previous.epochSeconds) / duration,
    0,
    1 - Number.EPSILON,
  );
  return Math.min(Math.floor(phase * realtimeBinCount), realtimeBinCount - 1);
}

function nextRealtimeRepdigitBin(
  afterBinIndex: number,
  minimumRepeatLength: number,
): number | undefined {
  const stride = realtimeStride(minimumRepeatLength);
  const repunit = (stride - 1) / (canonicalCatalog.radix.value - 1);
  const firstFutureBin = afterBinIndex + 1;
  let best: number | undefined;
  for (let digit = 1; digit < canonicalCatalog.radix.value; digit += 1) {
    const offset = digit * repunit;
    const remainder = positiveModulo(firstFutureBin - offset, stride);
    const candidate = remainder === 0 ? firstFutureBin : firstFutureBin + stride - remainder;
    if (candidate > 0 && candidate < realtimeBinCount && (best === undefined || candidate < best)) {
      best = candidate;
    }
  }
  return best;
}

function previousRealtimeRepdigitBin(
  atOrBeforeBinIndex: number,
  minimumRepeatLength: number,
): number | undefined {
  const stride = realtimeStride(minimumRepeatLength);
  const repunit = (stride - 1) / (canonicalCatalog.radix.value - 1);
  let best: number | undefined;
  for (let digit = 1; digit < canonicalCatalog.radix.value; digit += 1) {
    const offset = digit * repunit;
    const candidate = atOrBeforeBinIndex - positiveModulo(atOrBeforeBinIndex - offset, stride);
    if (candidate > 0 && candidate < realtimeBinCount && (best === undefined || candidate > best)) {
      best = candidate;
    }
  }
  return best;
}

function realtimeInteriorSpike(interval: SarosInterval, binIndex: number): SarosRealtimeSpike {
  const duration = interval.next.epochSeconds - interval.previous.epochSeconds;
  const unixTimestamp = interval.previous.epochSeconds + (binIndex / realtimeBinCount) * duration;
  const octalAddress = binIndex
    .toString(canonicalCatalog.radix.value)
    .padStart(SAROS_REALTIME_PHASE_DEPTH, "0");
  return buildRealtimeSpike(interval, unixTimestamp, octalAddress, interval.next);
}

function realtimeBoundarySpike(
  interval: SarosInterval,
  point: SolarEclipsePoint,
): SarosRealtimeSpike {
  return buildRealtimeSpike(
    interval,
    point.epochSeconds,
    String(canonicalCatalog.radix.value - 1).repeat(SAROS_REALTIME_PHASE_DEPTH),
    point,
  );
}

function buildRealtimeSpike(
  interval: SarosInterval,
  unixTimestamp: number,
  octalAddress: string,
  metadataPoint: SolarEclipsePoint,
): SarosRealtimeSpike {
  const repeatLength = trailingNonzeroRepeatLength(octalAddress);
  const mostSignificantGlyphAddress = octalAddress.slice(0, 5);
  const leastSignificantGlyphAddress = octalAddress.slice(5, 10);
  const presentationClassification = classifyRarity(canonicalCatalog, {
    octalAddress: mostSignificantGlyphAddress,
    harmonicDepth: 5,
  });
  const rarityRawValue = presentationClassification.rarityId;
  const rarity = rarityDescriptor(canonicalCatalog, {
    rarityId: rarityRawValue,
    harmonicDepth: 5,
  });
  const family = canonicalCatalog.rarities.families.find(
    (candidate) => candidate.id === rarity.family,
  );
  return {
    id: `${interval.saros}:${unixTimestamp}:${octalAddress}`,
    saros: interval.saros,
    unixTimestamp,
    octalAddress,
    harmonicDepth: SAROS_REALTIME_PHASE_DEPTH,
    mostSignificantGlyphAddress,
    leastSignificantGlyphAddress,
    listGlyphAddress: mostSignificantGlyphAddress,
    repeatLength,
    presentationRepeatLength:
      presentationClassification.order === 0
        ? 0
        : Math.max(5 - (family?.wildcardPrefixCount ?? 5), 0),
    repeatedDigit: presentationClassification.repeatedDigit,
    rarityRawValue,
    rarityTitle: rarity.title,
    rarityFamilyTitle: family?.title ?? rarity.title,
    rarityOrder: rarity.order,
    rarityRank: rarity.rank,
    patternLabel: rarity.patternLabel,
    semanticColorToken: rarity.semanticColorToken,
    digitSemanticColorToken: rarity.digitSemanticColorToken,
    ...pointMetadata(metadataPoint),
    ...(seriesDirection(interval) === undefined
      ? {}
      : { seriesProgressesSouthToNorth: seriesDirection(interval) }),
  };
}

function trailingNonzeroRepeatLength(address: string): number {
  const digit = address.at(-1);
  if (digit === undefined || digit === "0") return 0;
  let length = 0;
  for (let index = address.length - 1; index >= 0 && address[index] === digit; index -= 1) {
    length += 1;
  }
  return length;
}

function realtimeWaveReference(spike: SarosRealtimeSpike): SarosSpikeReference {
  return {
    saros: spike.saros,
    unixTimestamp: spike.unixTimestamp,
    octalAddress: spike.octalAddress,
    harmonicDepth: spike.harmonicDepth,
    rarityRawValue: spike.rarityRawValue,
    ...(spike.gamma === undefined ? {} : { gamma: spike.gamma }),
    ...(spike.magnitude === undefined ? {} : { magnitude: spike.magnitude }),
    ...(spike.eclipseTypeRawValue === undefined
      ? {}
      : { eclipseTypeRawValue: spike.eclipseTypeRawValue }),
    ...(spike.sarosSequence === undefined ? {} : { sarosSequence: spike.sarosSequence }),
    ...(spike.sarosSeriesCount === undefined ? {} : { sarosSeriesCount: spike.sarosSeriesCount }),
    ...(spike.seriesProgressesSouthToNorth === undefined
      ? {}
      : { seriesProgressesSouthToNorth: spike.seriesProgressesSouthToNorth }),
  };
}

function midpointGoverningSpike(
  sortedSpikes: readonly SarosRealtimeSpike[],
  instantEpochSeconds: number,
): SarosRealtimeSpike | undefined {
  let best: SarosRealtimeSpike | undefined;
  for (const spike of sortedSpikes) {
    if (best === undefined) {
      best = spike;
      continue;
    }
    const distance = Math.abs(spike.unixTimestamp - instantEpochSeconds);
    const bestDistance = Math.abs(best.unixTimestamp - instantEpochSeconds);
    if (
      distance < bestDistance ||
      (distance === bestDistance && compareRealtimeSpikes(spike, best) < 0)
    ) {
      best = spike;
    }
  }
  return best;
}

function uniqueRealtimeSpikes(spikes: readonly SarosRealtimeSpike[]): SarosRealtimeSpike[] {
  return [...new Map(spikes.map((spike) => [spike.id, spike])).values()];
}

function compareRealtimeSpikes(left: SarosRealtimeSpike, right: SarosRealtimeSpike): number {
  if (left.unixTimestamp !== right.unixTimestamp) {
    return left.unixTimestamp - right.unixTimestamp;
  }
  if (left.rarityRank !== right.rarityRank) return right.rarityRank - left.rarityRank;
  if (left.saros !== right.saros) return left.saros - right.saros;
  return left.octalAddress < right.octalAddress
    ? -1
    : left.octalAddress > right.octalAddress
      ? 1
      : 0;
}

function comparePastRealtimeSpikes(left: SarosRealtimeSpike, right: SarosRealtimeSpike): number {
  if (left.unixTimestamp !== right.unixTimestamp) {
    return right.unixTimestamp - left.unixTimestamp;
  }
  if (left.rarityRank !== right.rarityRank) return right.rarityRank - left.rarityRank;
  if (left.saros !== right.saros) return left.saros - right.saros;
  return left.octalAddress < right.octalAddress
    ? -1
    : left.octalAddress > right.octalAddress
      ? 1
      : 0;
}

function intervalClock(
  interval: SarosInterval,
  instantEpochSeconds: number,
  harmonicDepth: number,
): ClockReading {
  return clockReading(canonicalCatalog, {
    previousEpochSeconds: interval.previous.epochSeconds,
    nextEpochSeconds: interval.next.epochSeconds,
    instantEpochSeconds,
    harmonicDepth,
  });
}

function eventRarityDescriptors(harmonicDepth: number): readonly RarityDescriptor[] {
  return canonicalCatalog.rarities.families
    .filter((family) => family.order >= 4)
    .flatMap((family) =>
      canonicalCatalog.rarities.digits
        .filter((digit) => digit.digit > 0)
        .map((digit) =>
          rarityDescriptor(canonicalCatalog, {
            rarityId: `${family.id}-${digit.digit}`,
            harmonicDepth,
          }),
        ),
    );
}

function qualifiedFlipBin(
  clock: ClockReading,
  descriptor: RarityDescriptor,
  index: number,
  direction: -1 | 1,
): number | undefined {
  if (descriptor.binStride === null || descriptor.subeventOffset === null) return undefined;
  const stride = descriptor.binStride;
  let bin: number;
  if (direction < 0) {
    const clamped = Math.min(Math.max(index, 0), clock.binCount);
    bin = clamped - positiveModulo(clamped - descriptor.subeventOffset, stride);
  } else {
    bin = index + 1;
    const remainder = positiveModulo(bin - descriptor.subeventOffset, stride);
    if (remainder !== 0) bin += stride - remainder;
  }

  while (bin >= 0 && bin <= clock.binCount) {
    if (bin < clock.binCount) {
      const address = bin.toString(canonicalCatalog.radix.value).padStart(clock.harmonicDepth, "0");
      if (
        classifyRarity(canonicalCatalog, {
          octalAddress: address,
          harmonicDepth: clock.harmonicDepth,
        }).rarityId === descriptor.rarityId
      ) {
        return bin;
      }
    }
    bin += direction * stride;
  }
  return undefined;
}

function interiorSpike(
  interval: SarosInterval,
  clock: ClockReading,
  descriptor: RarityDescriptor,
  binIndex: number,
): SarosSpikeReference {
  const unixTimestamp = Math.trunc(
    clock.previousEpochSeconds +
      (binIndex / clock.binCount) * (clock.nextEpochSeconds - clock.previousEpochSeconds),
  );
  return {
    saros: interval.saros,
    unixTimestamp,
    octalAddress: binIndex
      .toString(canonicalCatalog.radix.value)
      .padStart(clock.harmonicDepth, "0"),
    harmonicDepth: clock.harmonicDepth,
    rarityRawValue: descriptor.rarityId,
    ...pointMetadata(interval.next),
    ...(seriesDirection(interval) === undefined
      ? {}
      : { seriesProgressesSouthToNorth: seriesDirection(interval) }),
  };
}

function boundarySpike(
  interval: SarosInterval,
  point: SolarEclipsePoint,
  harmonicDepth: number,
): SarosSpikeReference {
  return {
    saros: interval.saros,
    unixTimestamp: Math.trunc(point.epochSeconds),
    octalAddress: "7".repeat(harmonicDepth),
    harmonicDepth,
    rarityRawValue: "mythic-7",
    ...pointMetadata(point),
    ...(seriesDirection(interval) === undefined
      ? {}
      : { seriesProgressesSouthToNorth: seriesDirection(interval) }),
  };
}

function pointMetadata(point: SolarEclipsePoint) {
  return {
    ...(point.gamma === undefined ? {} : { gamma: point.gamma }),
    ...(point.magnitude === undefined ? {} : { magnitude: point.magnitude }),
    eclipseTypeRawValue: eclipseType(point.typeCode),
    sarosSequence: point.sequence,
    sarosSeriesCount: point.seriesCount,
  };
}

function seriesDirection(interval: SarosInterval): boolean | undefined {
  const previous = interval.previous.gamma;
  const next = interval.next.gamma;
  if (previous === undefined || next === undefined || previous === next) return undefined;
  return next > previous;
}

function addSpike(map: Map<string, SarosSpikeReference>, spike: SarosSpikeReference): void {
  const key = `${spike.saros}-${spike.unixTimestamp}`;
  const current = map.get(key);
  if (
    current === undefined ||
    rarityRank(spike.rarityRawValue) > rarityRank(current.rarityRawValue)
  ) {
    map.set(key, spike);
  }
}

function nextUpcomingFlip(
  spikes: readonly SarosSpikeReference[],
  instantEpochSeconds: number,
): SarosUpcomingFlip | undefined {
  const spike = spikes
    .filter((candidate) => candidate.unixTimestamp >= instantEpochSeconds)
    .sort((left, right) => {
      const time = left.unixTimestamp - right.unixTimestamp;
      return time !== 0 ? time : rarityRank(right.rarityRawValue) - rarityRank(left.rarityRawValue);
    })[0];
  if (spike === undefined) return undefined;
  const descriptor = rarityDescriptor(canonicalCatalog, {
    rarityId: spike.rarityRawValue,
    harmonicDepth: spike.harmonicDepth,
  });
  return {
    ...spike,
    timeUntilSeconds: spike.unixTimestamp - instantEpochSeconds,
    title: descriptor.title,
    patternLabel: descriptor.patternLabel,
  };
}

interface TemporalComponent {
  readonly spike: SarosSpikeReference;
  readonly previous?: SarosSpikeReference;
  readonly next?: SarosSpikeReference;
  readonly leftBoundary: number;
  readonly rightBoundary: number;
  readonly peakHeight: number;
  readonly ascentAccelerates: boolean;
  readonly descentAccelerates: boolean;
}

interface TemporalWaveMetrics {
  readonly energy: number;
  readonly energyPercent: number;
  readonly slope: number;
  readonly momentum: number;
  readonly directionRawValue: JournalEventContext["directionRawValue"];
  readonly extremumRawValue: JournalEventContext["extremumRawValue"];
  readonly majorPeriodSeconds: number;
}

function temporalWaveMetrics(
  spikes: readonly SarosSpikeReference[],
  instantEpochSeconds: number,
): TemporalWaveMetrics {
  const sorted = [...spikes].sort(compareSpikes);
  const majorPeriodSeconds = Math.max(
    (sorted.at(-1)?.unixTimestamp ?? instantEpochSeconds) -
      (sorted[0]?.unixTimestamp ?? instantEpochSeconds),
    0,
  );
  const components = temporalComponents(sorted);
  const dominant =
    dominantComponent(components, instantEpochSeconds) ??
    nearestComponent(components, instantEpochSeconds);
  if (dominant === undefined) {
    return {
      energy: 0,
      energyPercent: 0,
      slope: 0,
      momentum: 0,
      directionRawValue: "flat",
      extremumRawValue: "none",
      majorPeriodSeconds,
    };
  }

  const energy = totalEnergy(components, instantEpochSeconds);
  const peakHeight = Math.max(dominant.peakHeight, 0.000_000_001);
  const energyPercent = clamp(energy / peakHeight, 0, 1);
  const sarosPulseSeconds = pulseDuration(canonicalCatalog, "saros").seconds;
  const beforeEnergy = totalEnergy(components, instantEpochSeconds - sarosPulseSeconds);
  const afterEnergy = totalEnergy(components, instantEpochSeconds + sarosPulseSeconds);
  const momentum = (afterEnergy - beforeEnergy) / peakHeight;
  const slope = (afterEnergy - beforeEnergy) / (2 * sarosPulseSeconds);
  const energyBin = Math.min(Math.floor(energyPercent * 512), 511);
  const momentumBin = Math.min(Math.floor(clamp(Math.abs(momentum), 0, 1) * 512), 511);
  const isPeak = energyBin >= 504;
  const isValley = !isPeak && energyPercent <= 0.2;
  const directionRawValue =
    isPeak || isValley || momentumBin < 1 ? "flat" : momentum > 0 ? "ascending" : "descending";
  const extremumRawValue = isPeak ? "localMaximum" : isValley ? "localMinimum" : "none";
  return {
    energy,
    energyPercent,
    slope,
    momentum,
    directionRawValue,
    extremumRawValue,
    majorPeriodSeconds,
  };
}

function temporalComponents(spikes: readonly SarosSpikeReference[]): readonly TemporalComponent[] {
  const sorted = [...spikes].sort(compareSpikes);
  return sorted.map((spike, index): TemporalComponent => {
    const previous = previousDistinct(sorted, index);
    const next = nextDistinct(sorted, index);
    const leftGap = Math.max(
      previous === undefined
        ? next === undefined
          ? 86_400
          : next.unixTimestamp - spike.unixTimestamp
        : spike.unixTimestamp - previous.unixTimestamp,
      1,
    );
    const rightGap = Math.max(
      next === undefined ? leftGap : next.unixTimestamp - spike.unixTimestamp,
      1,
    );
    const leftBoundary =
      previous === undefined
        ? spike.unixTimestamp - leftGap / 2
        : midpoint(previous.unixTimestamp, spike.unixTimestamp);
    const rightBoundary =
      next === undefined
        ? spike.unixTimestamp + rightGap / 2
        : midpoint(spike.unixTimestamp, next.unixTimestamp);
    const fallbackSeed = spike.saros + index;
    return {
      spike,
      ...(previous === undefined ? {} : { previous }),
      ...(next === undefined ? {} : { next }),
      leftBoundary,
      rightBoundary,
      peakHeight: peakHeight(spike),
      ascentAccelerates:
        spike.seriesProgressesSouthToNorth ??
        (spike.gamma !== undefined && spike.gamma !== 0 ? spike.gamma > 0 : fallbackSeed % 2 === 0),
      descentAccelerates:
        spike.sarosSequence !== undefined &&
        spike.sarosSeriesCount !== undefined &&
        spike.sarosSeriesCount > 0
          ? spike.sarosSequence >= spike.sarosSeriesCount / 2
          : fallbackSeed % 2 !== 0,
    };
  });
}

function componentEnergy(component: TemporalComponent, instant: number): number {
  if (instant < component.leftBoundary || instant > component.rightBoundary) return 0;
  const spikeTime = component.spike.unixTimestamp;
  let value: number;
  if (instant <= spikeTime) {
    const duration = Math.max(spikeTime - component.leftBoundary, 1);
    const progress = clamp((instant - component.leftBoundary) / duration, 0, 1);
    value = component.ascentAccelerates ? progress ** 2 : 1 - (1 - progress) ** 2;
  } else {
    const duration = Math.max(component.rightBoundary - spikeTime, 1);
    const progress = clamp((instant - spikeTime) / duration, 0, 1);
    value = component.descentAccelerates ? 1 - progress ** 2 : (1 - progress) ** 2;
  }
  return component.peakHeight * clamp(value, 0, 1);
}

function totalEnergy(components: readonly TemporalComponent[], instant: number): number {
  return components.reduce((sum, component) => sum + componentEnergy(component, instant), 0);
}

function dominantComponent(
  components: readonly TemporalComponent[],
  instant: number,
): TemporalComponent | undefined {
  return components
    .filter((component) => instant >= component.leftBoundary && instant <= component.rightBoundary)
    .sort((left, right) => componentEnergy(right, instant) - componentEnergy(left, instant))[0];
}

function nearestComponent(
  components: readonly TemporalComponent[],
  instant: number,
): TemporalComponent | undefined {
  return [...components].sort(
    (left, right) => componentDistance(left, instant) - componentDistance(right, instant),
  )[0];
}

function componentDistance(component: TemporalComponent, instant: number): number {
  if (instant < component.leftBoundary) return component.leftBoundary - instant;
  if (instant > component.rightBoundary) return instant - component.rightBoundary;
  return 0;
}

function peakHeight(spike: SarosSpikeReference): number {
  const order = rarityDescriptor(canonicalCatalog, {
    rarityId: spike.rarityRawValue,
    harmonicDepth: spike.harmonicDepth,
  }).order;
  const base = order >= 6 ? 4 : order === 5 ? 2 : order === 4 ? 1 : order === 3 ? 0.5 : 0.25;
  const magnitude = spike.magnitude === undefined ? 1 : clamp(spike.magnitude, 0.18, 1.8);
  return base * 2.5 * magnitude;
}

function previousDistinct(
  spikes: readonly SarosSpikeReference[],
  index: number,
): SarosSpikeReference | undefined {
  for (let cursor = index - 1; cursor >= 0; cursor -= 1) {
    const candidate = spikes[cursor];
    if (candidate !== undefined && candidate.unixTimestamp !== spikes[index]?.unixTimestamp) {
      return candidate;
    }
  }
  return undefined;
}

function nextDistinct(
  spikes: readonly SarosSpikeReference[],
  index: number,
): SarosSpikeReference | undefined {
  for (let cursor = index + 1; cursor < spikes.length; cursor += 1) {
    const candidate = spikes[cursor];
    if (candidate !== undefined && candidate.unixTimestamp !== spikes[index]?.unixTimestamp) {
      return candidate;
    }
  }
  return undefined;
}

function rarityRank(rarityId: RarityId): number {
  return rarityDescriptor(canonicalCatalog, {
    rarityId,
    harmonicDepth: CANONICAL_CONTEXT_DEPTH,
  }).rank;
}

function compareSpikes(left: SarosSpikeReference, right: SarosSpikeReference): number {
  if (left.unixTimestamp !== right.unixTimestamp) {
    return left.unixTimestamp - right.unixTimestamp;
  }
  if (left.saros !== right.saros) return left.saros - right.saros;
  return rarityRank(right.rarityRawValue) - rarityRank(left.rarityRawValue);
}

function realtimePeriodDefinition(
  id: SarosRealtimePeriodId,
  catalogId: "rollover" | "giga" | "mega" | "kilo" | "saros" | "mili",
  title: string,
): SarosRealtimePeriodDefinition {
  const unit = canonicalCatalog.time.units.find((candidate) => candidate.id === catalogId);
  if (unit === undefined) throw new RangeError(`Missing temporal unit ${catalogId}.`);
  return Object.freeze({
    id,
    title,
    exponent: unit.exponent,
    durationSeconds: pulseDuration(canonicalCatalog, catalogId).seconds,
    semanticColorToken: unit.semanticColorToken,
  });
}

function realtimeRarityDefinition(
  id: SarosRealtimeMinimumRarity,
  familyId: SarosRealtimeRarityDefinition["familyId"],
  minimumRepeatLength: SarosRealtimeRarityDefinition["minimumRepeatLength"],
): SarosRealtimeRarityDefinition {
  const descriptor = rarityDescriptor(canonicalCatalog, {
    rarityId: familyId,
    harmonicDepth: CANONICAL_CONTEXT_DEPTH,
  });
  return Object.freeze({
    id,
    title: descriptor.title,
    familyId,
    minimumRepeatLength,
    semanticColorToken: descriptor.semanticColorToken,
  });
}

function eclipseType(code: number): string {
  if (code >= 0 && code <= 5) return "annularSolar";
  if (code >= 6 && code <= 9) return "hybridSolar";
  if (code >= 10 && code <= 12) return "partialSolar";
  if (code >= 13 && code <= 18) return "totalSolar";
  return "unknown";
}

function pulseImminentUnit(units: readonly SarosPulseUnitReading[]): SarosPulseImminentUnit | null {
  const byId = new Map(units.map((unit) => [unit.id, unit]));
  const tera = byId.get("tera");
  const giga = byId.get("giga");
  const mega = byId.get("mega");
  const kilo = byId.get("kilo");
  const saros = byId.get("saros");
  const mili = byId.get("mili");
  if (
    tera === undefined ||
    giga === undefined ||
    mega === undefined ||
    kilo === undefined ||
    saros === undefined ||
    mili === undefined
  ) {
    throw new RangeError("Saros pulse urgency requires Tera through Milisaros units.");
  }

  if (tera.timeUntilNextSeconds <= mega.exactDurationSeconds) return "tera";
  if (giga.timeUntilNextSeconds <= kilo.exactDurationSeconds) return "giga";
  if (mega.timeUntilNextSeconds <= saros.exactDurationSeconds) return "mega";
  if (kilo.timeUntilNextSeconds <= mili.exactDurationSeconds) return "kilo";
  return null;
}

function pulseTickColor(imminentUnit: SarosPulseImminentUnit | null): SarosPulseTickColor {
  switch (imminentUnit) {
    case "tera":
      return "red";
    case "giga":
      return "yellow";
    case "mega":
      return "purple";
    case "kilo":
      return "blue";
    default:
      return "neutral";
  }
}

function pulseColor(trailingZeroCount: number): SarosPulseReading["color"] {
  if (trailingZeroCount <= 1) return "white";
  if (trailingZeroCount === 2) return "blue";
  if (trailingZeroCount === 3) return "purple";
  if (trailingZeroCount === 4) return "yellow";
  return "red";
}

function positiveFraction(value: number): number {
  return value - Math.floor(value);
}

function positiveModulo(value: number, modulus: number): number {
  const remainder = value % modulus;
  return remainder >= 0 ? remainder : remainder + modulus;
}

function midpoint(left: number, right: number): number {
  return left + (right - left) / 2;
}

function clamp(value: number, minimum: number, maximum: number): number {
  return Math.min(Math.max(value, minimum), maximum);
}
