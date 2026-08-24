/**
 * Experimental Saros carrier used by System Lab.
 *
 * Array order follows the six-arm socket mapping through glyphSocketDigitIndices:
 * top B11, top-right B13, bottom-right B5, bottom B7, bottom-left B8, top-left B9.
 */
export const MIXED_RADIX_BASES = Object.freeze([11, 9, 8, 7, 5, 13] as const);

export const MIXED_RADIX_MAX_SIGNIFICANCE_DEPTH = 8;

/** One exact eclipse-to-eclipse Saros interval is divided into this many bins. */
export const MIXED_RADIX_SAROS_BIN_COUNT = 9_360;

/** Base 7 and base 11 return to their eclipse-boundary offsets after 77 Saros intervals. */
export const MIXED_RADIX_SERIES_PHASE_COUNT = 7 * 11;

/** Addressed states when the series phase is retained as part of the carrier. */
export const MIXED_RADIX_SERIES_ADDRESS_COUNT =
  MIXED_RADIX_SAROS_BIN_COUNT * MIXED_RADIX_SERIES_PHASE_COUNT;

/** The raw six-residue tuple repeats twice inside the complete 77-Saros carrier. */
export const MIXED_RADIX_RESIDUE_PERIOD = 360_360;

/** Mean tropical year, used only for the secondary year-scale clock preview. */
export const MEAN_TROPICAL_YEAR_SECONDS = 365.2422 * 86_400;

export interface MixedRadixState {
  readonly binIndex: number;
  readonly binCount: number;
  readonly sarosSequence: number;
  readonly seriesPhaseIndex: number;
  readonly serialBinIndex: number;
  readonly digits: readonly number[];
  readonly radices: typeof MIXED_RADIX_BASES;
  readonly address: string;
  readonly base7Offset: number;
  readonly base11Offset: number;
  readonly residueCycle: number;
}

export interface MixedRadixClockInput {
  /** Defaults to the canonical 9,360-bin Saros partition. */
  readonly binCount?: number;
  readonly previousEpochSeconds: number;
  readonly nextEpochSeconds: number;
  readonly instantEpochSeconds: number;
  /** Solar data numbers the first eclipse in a series as 1. */
  readonly sarosSequence: number;
}

export interface MixedRadixClockReading extends MixedRadixState {
  readonly previousEpochSeconds: number;
  readonly nextEpochSeconds: number;
  readonly instantEpochSeconds: number;
  readonly phase: number;
  readonly progressWithinBin: number;
  readonly binDurationSeconds: number;
  readonly nextFlipEpochSeconds: number;
  readonly timeUntilNextFlip: number;
}

export type MixedRadixRepdigitRarity = "common" | "rare" | "epic" | "legendary" | "mythic";

export interface MixedRadixRepdigitMetadata {
  readonly rarity: MixedRadixRepdigitRarity;
  readonly pattern: string;
  readonly groups: readonly {
    readonly digit: number;
    readonly count: number;
    readonly effectiveCount: number;
  }[];
  readonly zeroBonus: boolean;
  readonly bilateral: boolean;
}

/** Build one mixed-radix state from an eclipse sequence and a bin inside that Saros. */
export function mixedRadixState(
  rawBinIndex: number,
  rawSarosSequence: number,
  rawBinCount: number = MIXED_RADIX_SAROS_BIN_COUNT,
): MixedRadixState {
  assertSafeInteger(rawBinIndex, "Mixed-radix bin index");
  assertSafeInteger(rawSarosSequence, "Saros sequence");
  if (rawSarosSequence < 1) {
    throw new RangeError("Saros sequence must start at 1.");
  }

  const binCount = normalizeBinCount(rawBinCount);
  const binIndex = modulo(rawBinIndex, binCount);
  const seriesPhaseIndex = modulo(rawSarosSequence - 1, MIXED_RADIX_SERIES_PHASE_COUNT);
  const seriesBoundaryIndex = seriesPhaseIndex * binCount;
  const serialBinIndex = seriesBoundaryIndex + binIndex;
  const digits = mixedRadixSignificanceLayers(serialBinIndex, 1)[0] ?? Object.freeze([]);

  return Object.freeze({
    binIndex,
    binCount,
    sarosSequence: rawSarosSequence,
    seriesPhaseIndex,
    serialBinIndex,
    digits,
    radices: MIXED_RADIX_BASES,
    address: formatMixedRadixAddress(digits, MIXED_RADIX_BASES),
    base7Offset: seriesBoundaryIndex % 7,
    base11Offset: seriesBoundaryIndex % 11,
    residueCycle: Math.floor(serialBinIndex / MIXED_RADIX_RESIDUE_PERIOD),
  });
}

/**
 * Return simultaneous positional projections, least-significant set first.
 * Each radix has its own place value: floor(n / base^place) mod base.
 */
export function mixedRadixSignificanceLayers(
  serialBinIndex: number,
  rawDepth: number,
): readonly (readonly number[])[] {
  return mixedRadixSignificanceLayersForBases(serialBinIndex, rawDepth, MIXED_RADIX_BASES);
}

/** Project the carrier into an ordered, caller-selected set of bases. */
export function mixedRadixSignificanceLayersForBases(
  serialBinIndex: number,
  rawDepth: number,
  rawBases: readonly number[],
): readonly (readonly number[])[] {
  assertSafeInteger(serialBinIndex, "Mixed-radix serial bin index");
  assertSafeInteger(rawDepth, "Mixed-radix significance depth");
  if (serialBinIndex < 0) {
    throw new RangeError("Mixed-radix serial bin index cannot be negative.");
  }
  if (rawDepth < 1 || rawDepth > MIXED_RADIX_MAX_SIGNIFICANCE_DEPTH) {
    throw new RangeError(
      `Mixed-radix significance depth must be 1...${MIXED_RADIX_MAX_SIGNIFICANCE_DEPTH}.`,
    );
  }
  const bases = normalizeProjectionBases(rawBases);
  return Object.freeze(
    Array.from({ length: rawDepth }, (_, place) =>
      Object.freeze(bases.map((base) => Math.floor(serialBinIndex / base ** place) % base)),
    ),
  );
}

/** Resolve a least-significant six-wheel address inside one selected Saros interval. */
export function mixedRadixBinForDigits(
  rawDigits: readonly number[],
  rawSarosSequence: number,
  rawBases: readonly number[] = MIXED_RADIX_BASES,
  rawBinCount: number = MIXED_RADIX_SAROS_BIN_COUNT,
): number | null {
  return mixedRadixBinsForDigits(rawDigits, rawSarosSequence, rawBases, rawBinCount)[0] ?? null;
}

/** Resolve every matching bin, exposing collisions for experimental basis sets. */
export function mixedRadixBinsForDigits(
  rawDigits: readonly number[],
  rawSarosSequence: number,
  rawBases: readonly number[] = MIXED_RADIX_BASES,
  rawBinCount: number = MIXED_RADIX_SAROS_BIN_COUNT,
): readonly number[] {
  assertSafeInteger(rawSarosSequence, "Saros sequence");
  if (rawSarosSequence < 1) {
    throw new RangeError("Saros sequence must start at 1.");
  }
  const bases = normalizeProjectionBases(rawBases);
  const binCount = normalizeBinCount(rawBinCount);
  if (rawDigits.length !== bases.length) {
    throw new RangeError(`Mixed-radix address must contain ${bases.length} digits.`);
  }
  rawDigits.forEach((digit, index) => {
    const radix = bases[index] ?? 0;
    if (!Number.isSafeInteger(digit) || digit < 0 || digit >= radix) {
      throw new RangeError(`Digit ${digit} is outside base ${radix}.`);
    }
  });

  const matches: number[] = [];
  const seriesPhaseIndex = modulo(rawSarosSequence - 1, MIXED_RADIX_SERIES_PHASE_COUNT);
  for (let binIndex = 0; binIndex < binCount; binIndex += 1) {
    const serialBinIndex = seriesPhaseIndex * binCount + binIndex;
    if (bases.every((base, index) => serialBinIndex % base === rawDigits[index])) {
      matches.push(binIndex);
    }
  }
  return Object.freeze(matches);
}

/** Classify repetition among the six digits currently visible on one glyph. */
export function mixedRadixRepdigitMetadata(
  rawDigits: readonly number[],
): MixedRadixRepdigitMetadata {
  if (rawDigits.length !== 6) {
    throw new RangeError("Repdigit classification requires exactly six visible digits.");
  }
  const counts = new Map<number, number>();
  rawDigits.forEach((digit) => {
    assertSafeInteger(digit, "Mixed-radix visible digit");
    if (digit < 0) {
      throw new RangeError("Mixed-radix visible digits cannot be negative.");
    }
    counts.set(digit, (counts.get(digit) ?? 0) + 1);
  });
  const groups = [...counts.entries()]
    .map(([digit, count]) =>
      Object.freeze({ digit, count, effectiveCount: count + (digit === 0 ? 1 : 0) }),
    )
    .sort((left, right) => right.count - left.count || left.digit - right.digit);
  const rawRarity = repdigitRarityForFrequencies(groups.map((group) => group.count));
  const zeroAdjustedRarity = repdigitRarityForFrequencies(
    groups.map((group) => group.effectiveCount),
  );
  const [, topLeft, bottomLeft, , bottomRight, topRight] = rawDigits;
  const bilateral =
    (topLeft === topRight && bottomLeft === bottomRight) ||
    (bottomRight === topLeft && bottomLeft === topRight);
  const rarity = highestRepdigitRarity(
    rawRarity,
    zeroAdjustedRarity,
    bilateral ? "legendary" : "common",
  );
  const repeatedGroups = groups.filter((group) => group.effectiveCount >= 2);
  const pattern =
    repeatedGroups.length === 0
      ? "none"
      : repeatedGroups
          .map((group) => group.effectiveCount)
          .sort((left, right) => left - right)
          .join("+");
  return Object.freeze({
    rarity,
    pattern,
    groups: Object.freeze(groups),
    zeroBonus: groups.some((group) => group.digit === 0),
    bilateral,
  });
}

/** Read the mixed-radix carrier inside one actual eclipse-to-eclipse interval. */
export function mixedRadixClockReading(input: MixedRadixClockInput): MixedRadixClockReading {
  assertFinite(input.previousEpochSeconds, "Previous eclipse epoch");
  assertFinite(input.nextEpochSeconds, "Next eclipse epoch");
  assertFinite(input.instantEpochSeconds, "Clock instant");
  if (!(input.nextEpochSeconds > input.previousEpochSeconds)) {
    throw new RangeError("Next eclipse epoch must be later than the previous eclipse epoch.");
  }

  const duration = input.nextEpochSeconds - input.previousEpochSeconds;
  const binCount = normalizeBinCount(input.binCount ?? MIXED_RADIX_SAROS_BIN_COUNT);
  const rawPhase = (input.instantEpochSeconds - input.previousEpochSeconds) / duration;
  const phase = Math.max(0, Math.min(rawPhase, 1));
  const scaledBin = phase * binCount;
  const binIndex = Math.min(Math.floor(scaledBin), binCount - 1);
  const progressWithinBin = phase >= 1 ? 1 : scaledBin - binIndex;
  const nextBinIndex = Math.min(binIndex + 1, binCount);
  const nextFlipEpochSeconds = input.previousEpochSeconds + (nextBinIndex / binCount) * duration;

  return Object.freeze({
    ...mixedRadixState(binIndex, input.sarosSequence, binCount),
    previousEpochSeconds: input.previousEpochSeconds,
    nextEpochSeconds: input.nextEpochSeconds,
    instantEpochSeconds: input.instantEpochSeconds,
    phase,
    progressWithinBin,
    binDurationSeconds: duration / binCount,
    nextFlipEpochSeconds,
    timeUntilNextFlip: nextFlipEpochSeconds - input.instantEpochSeconds,
  });
}

/** Frequency of one score position when a complete residue cycle fills one Saros day. */
export function mixedRadixSarosDayTickFrequency(
  sarosDayDurationSeconds: number,
  rawTickCount: number = MIXED_RADIX_RESIDUE_PERIOD,
): number {
  assertFinite(sarosDayDurationSeconds, "Saros day duration");
  if (sarosDayDurationSeconds <= 0) {
    throw new RangeError("Saros day duration must be positive.");
  }
  assertFinite(rawTickCount, "Saros day score tick count");
  const tickCount = Math.trunc(rawTickCount);
  if (tickCount <= 0) {
    throw new RangeError("Saros day score tick count must be positive.");
  }
  const frequency = tickCount / sarosDayDurationSeconds;
  if (!Number.isFinite(frequency)) {
    throw new RangeError("Saros day score frequency is too large.");
  }
  return frequency;
}

export function formatMixedRadixAddress(
  digits: readonly number[],
  radices: readonly number[],
): string {
  if (digits.length !== radices.length) {
    throw new RangeError("Mixed-radix digits and bases must have the same length.");
  }
  return digits.map((digit, index) => `${digit}_${radices[index] ?? "?"}`).join(" · ");
}

function modulo(value: number, modulus: number): number {
  return ((value % modulus) + modulus) % modulus;
}

function normalizeProjectionBases(rawBases: readonly number[]): readonly number[] {
  if (rawBases.length === 0) {
    throw new RangeError("Mixed-radix projection must contain at least one base.");
  }
  const bases = rawBases.map((base) => {
    if (!Number.isSafeInteger(base) || base < 2 || base > 64) {
      throw new RangeError("Mixed-radix projection bases must be integers from 2 through 64.");
    }
    return base;
  });
  return Object.freeze(bases);
}

function normalizeBinCount(rawBinCount: number): number {
  assertSafeInteger(rawBinCount, "Mixed-radix bin count");
  if (rawBinCount < 1) {
    throw new RangeError("Mixed-radix bin count must be at least 1.");
  }
  if (rawBinCount > Math.floor(Number.MAX_SAFE_INTEGER / MIXED_RADIX_SERIES_PHASE_COUNT)) {
    throw new RangeError("Mixed-radix bin count is too large to address safely.");
  }
  return rawBinCount;
}

function repdigitRarityForFrequencies(rawFrequencies: readonly number[]): MixedRadixRepdigitRarity {
  const frequencies = [...rawFrequencies].sort((left, right) => right - left);
  const largest = frequencies[0] ?? 0;
  const tripleCount = frequencies.filter((count) => count === 3).length;
  const pairCount = frequencies.filter((count) => count === 2).length;
  if (largest >= 6 || tripleCount >= 2) return "mythic";
  if (largest >= 5 || (tripleCount >= 1 && pairCount >= 1)) return "legendary";
  if (largest >= 3) return "epic";
  if (pairCount >= 2) return "rare";
  return "common";
}

function highestRepdigitRarity(
  ...rarities: readonly MixedRadixRepdigitRarity[]
): MixedRadixRepdigitRarity {
  const order: readonly MixedRadixRepdigitRarity[] = [
    "common",
    "rare",
    "epic",
    "legendary",
    "mythic",
  ];
  return rarities.reduce(
    (highest, rarity) => (order.indexOf(rarity) > order.indexOf(highest) ? rarity : highest),
    "common",
  );
}

function assertSafeInteger(value: number, label: string): void {
  if (!Number.isSafeInteger(value)) {
    throw new RangeError(`${label} must be a safe integer.`);
  }
}

function assertFinite(value: number, label: string): void {
  if (!Number.isFinite(value)) {
    throw new RangeError(`${label} must be finite.`);
  }
}
