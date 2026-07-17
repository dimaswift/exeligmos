import {
  canonicalCatalog,
  type DomainCatalog,
  type RarityFamily,
  type RarityFamilyId,
  type TemporalUnit,
  type TemporalUnitId,
} from "@exeligmos/domain-catalog";

/** A depth accepted by Saros clock calculations. Clock depths are validated, not clamped. */
export type CalculationDepth = number & { readonly __calculationDepth: unique symbol };

/** A depth accepted by presentation, storage-address, rarity, and glyph-facing APIs. */
export type PresentationDepth = number & { readonly __presentationDepth: unique symbol };

export type RarityDigit = DomainCatalog["rarities"]["digits"][number]["digit"];
export type NonzeroRarityDigit = Exclude<RarityDigit, 0>;
export type NonCommonRarityFamilyId = Exclude<RarityFamilyId, "common">;
export type RarityId = RarityFamilyId | `${NonCommonRarityFamilyId}-${NonzeroRarityDigit}`;
export type RarityAlias = DomainCatalog["rarities"]["aliases"][number]["alias"];
export type RarityInputId = RarityId | RarityAlias | (string & {});
export type SemanticColorToken = DomainCatalog["semanticTokens"]["colors"][number]["id"];

export interface ResolvedRarity {
  readonly requestedId: string;
  readonly rarityId: RarityId;
  readonly family: RarityFamily;
  readonly repeatedDigit: RarityDigit;
}

export interface RarityClassification {
  readonly rarityId: RarityId;
  readonly family: RarityFamilyId;
  readonly order: number;
  readonly repeatedDigit: RarityDigit;
}

export interface ClassifyRarityInput {
  readonly octalAddress: string;
  readonly harmonicDepth: number;
  /** Matches the native clock's explicit eclipse override. */
  readonly isEclipse?: boolean;
}

export interface RarityDescriptorInput {
  readonly rarityId: RarityInputId;
  readonly harmonicDepth: number;
}

/** Complete, presentation-neutral rarity data for analytics and renderers. */
export interface RarityDescriptor {
  readonly rarityId: RarityId;
  readonly family: RarityFamilyId;
  readonly order: number;
  readonly repeatedDigit: RarityDigit;
  readonly rank: number;
  readonly title: string;
  readonly patternLabel: string;
  readonly glyphAddress: string;
  readonly binStride: number | null;
  readonly subeventOffset: number | null;
  readonly symbol: string;
  /** Family color, except for exact catalog overrides such as mythic-7. */
  readonly semanticColorToken: SemanticColorToken;
  /** Separate digit data; it is not the rarity glyph's primary color. */
  readonly digitSemanticColorToken: SemanticColorToken;
  readonly notificationEligible: boolean;
  readonly isHeader: boolean;
}

export interface PulseDuration {
  readonly unitId: TemporalUnitId;
  readonly exponent: number;
  readonly seconds: number;
}

export interface ClockReadingInput {
  readonly previousEpochSeconds: number;
  readonly nextEpochSeconds: number;
  readonly instantEpochSeconds: number;
  readonly harmonicDepth: number;
}

/** A timezone-independent reading inside one supplied temporal interval. */
export interface ClockReading {
  readonly previousEpochSeconds: number;
  readonly nextEpochSeconds: number;
  readonly instantEpochSeconds: number;
  readonly harmonicDepth: CalculationDepth;
  readonly phase: number;
  readonly binCount: number;
  readonly binIndex: number;
  readonly octalAddress: string;
  readonly progressWithinBin: number;
  readonly nextFlipEpochSeconds: number;
  /** Can be negative when the supplied instant is after the interval. */
  readonly timeUntilNextFlip: number;
}

export interface TemporalEngine {
  readonly catalogVersion: string;
  readonly schemaVersion: number;
  readonly clampPresentationDepth: (value: number) => PresentationDepth;
  readonly assertCalculationDepth: (value: number) => CalculationDepth;
  readonly canonicalOctalAddress: (
    value: string,
    storedDepth: number,
    outputDepth?: number,
  ) => string;
  readonly rarityOctalAddress: (
    value: string,
    storedDepth: number,
    rarityId: RarityInputId,
    outputDepth?: number,
  ) => string;
  readonly resolveRarity: (rarityId: RarityInputId) => ResolvedRarity;
  readonly classifyRarity: (input: ClassifyRarityInput) => RarityClassification;
  readonly rarityDescriptor: (input: RarityDescriptorInput) => RarityDescriptor;
  readonly pulseDuration: (unitId: TemporalUnitId) => PulseDuration;
  readonly clockReading: (input: ClockReadingInput) => ClockReading;
}

/**
 * Clamp an integer to the catalog's presentation range. This deliberately differs
 * from clock depths, which must be rejected when unsupported.
 */
export function clampPresentationDepth(catalog: DomainCatalog, value: number): PresentationDepth {
  assertSafeInteger(value, "Presentation depth");
  return clamp(
    value,
    catalog.harmonics.presentationDepth.minimum,
    catalog.harmonics.presentationDepth.maximum,
  ) as PresentationDepth;
}

/** Validate, and brand, an integer calculation depth without changing it. */
export function assertCalculationDepth(catalog: DomainCatalog, value: number): CalculationDepth {
  assertSafeInteger(value, "Harmonic depth");
  const range = catalog.harmonics.calculationDepth;
  if (value < range.minimum || value > range.maximum) {
    throw new RangeError(
      `Harmonic depth ${value} is outside the calculation range ${range.minimum}...${range.maximum}.`,
    );
  }
  return value as CalculationDepth;
}

/**
 * Normalize a persisted address using the storage contract: retain the leftmost
 * radix digits and pad on the right with zeroes.
 */
export function canonicalOctalAddress(
  catalog: DomainCatalog,
  value: string,
  storedDepth: number,
  rawOutputDepth: number = catalog.harmonics.presentationDepth.canonical,
): string {
  const depth = clampPresentationDepth(catalog, storedDepth);
  const outputDepth = clampStorageOutputDepth(catalog, rawOutputDepth);
  const digits = retainRadixDigits(catalog, value);

  if (digits.length >= outputDepth) {
    return digits.slice(0, outputDepth);
  }

  return digits.padEnd(Math.min(depth, outputDepth), "0").padEnd(outputDepth, "0");
}

/**
 * Normalize a persisted rarity address. It has the same leftmost/right-pad
 * contract as canonical storage, but uses a subrarity's repeated digit as padding.
 */
export function rarityOctalAddress(
  catalog: DomainCatalog,
  value: string,
  storedDepth: number,
  rarityId: RarityInputId,
  rawOutputDepth: number = catalog.harmonics.presentationDepth.canonical,
): string {
  const rarity = resolveRarity(catalog, rarityId);
  const depth = clampPresentationDepth(catalog, storedDepth);
  const outputDepth = clampStorageOutputDepth(catalog, rawOutputDepth);
  const digits = retainRadixDigits(catalog, value);

  if (digits.length >= outputDepth) {
    return digits.slice(0, outputDepth);
  }

  const pad = rarity.repeatedDigit > 0 ? String(rarity.repeatedDigit) : "0";
  return digits.padEnd(Math.min(depth, outputDepth), pad).padEnd(outputDepth, pad);
}

/** Resolve canonical rarity IDs and catalog-declared legacy aliases. */
export function resolveRarity(catalog: DomainCatalog, rawId: RarityInputId): ResolvedRarity {
  const requestedId = String(rawId);
  const alias = catalog.rarities.aliases.find((candidate) => candidate.alias === requestedId);
  const rarityId = alias?.target ?? requestedId;

  for (const family of catalog.rarities.families) {
    if (rarityId === family.id) {
      return {
        requestedId,
        rarityId: family.id,
        family,
        repeatedDigit: 0,
      };
    }

    if (family.order === 0) {
      continue;
    }

    for (const digit of catalog.rarities.digits) {
      if (digit.digit > 0 && rarityId === `${family.id}-${digit.digit}`) {
        return {
          requestedId,
          rarityId: rarityId as RarityId,
          family,
          repeatedDigit: digit.digit,
        };
      }
    }
  }

  throw new RangeError(`Unknown rarity ${requestedId}.`);
}

/**
 * Classify a stored clock address using Swift-compatible boundary behavior.
 * Classification retains the leftmost digits but, unlike storage normalization,
 * pads on the left before examining a repeated suffix.
 */
export function classifyRarity(
  catalog: DomainCatalog,
  input: ClassifyRarityInput,
): RarityClassification {
  if (input.isEclipse === true) {
    return classificationFromResolved(
      resolveRarity(catalog, catalog.rarities.classification.allZeroRarity),
    );
  }

  const depth = clampPresentationDepth(catalog, input.harmonicDepth);
  const filtered = retainRadixDigits(catalog, input.octalAddress).slice(0, depth);
  let padded = filtered.padStart(depth, "0");
  let numeric = Number.parseInt(padded, catalog.radix.value) || 0;

  if (numeric === 0) {
    return classificationFromResolved(
      resolveRarity(catalog, catalog.rarities.classification.allZeroRarity),
    );
  }

  // A flip exactly on a positive boundary describes the bin that just completed.
  if (padded.endsWith("0")) {
    numeric -= 1;
    padded = numeric.toString(catalog.radix.value).padStart(depth, "0");
  }

  const lastDigit = padded.at(-1);
  if (lastDigit === undefined || lastDigit === "0") {
    return commonClassification(catalog);
  }

  let suffixLength = 0;
  for (let index = padded.length - 1; index >= 0 && padded[index] === lastDigit; index -= 1) {
    suffixLength += 1;
  }

  const wildcardPrefixCount = depth - suffixLength;
  if (wildcardPrefixCount > catalog.rarities.classification.maximumRecognizedWildcardPrefixCount) {
    return commonClassification(catalog);
  }

  const repeatedDigit = Number(lastDigit) as RarityDigit;
  const family = catalog.rarities.families.find(
    (candidate) => candidate.wildcardPrefixCount === wildcardPrefixCount,
  );
  if (family === undefined || family.order === 0 || repeatedDigit === 0) {
    return commonClassification(catalog);
  }

  return {
    rarityId: `${family.id}-${repeatedDigit}` as RarityId,
    family: family.id,
    order: family.order,
    repeatedDigit,
  };
}

/** Build all catalog-owned rarity labels, addresses, strides, and semantic tokens. */
export function rarityDescriptor(
  catalog: DomainCatalog,
  input: RarityDescriptorInput,
): RarityDescriptor {
  const rarity = resolveRarity(catalog, input.rarityId);
  const depth = clampPresentationDepth(catalog, input.harmonicDepth);
  const { family, repeatedDigit, rarityId } = rarity;
  const digit = digitDefinition(catalog, repeatedDigit);
  const override = catalog.rarities.colorOverrides.find(
    (candidate) => candidate.rarityId === rarityId,
  );

  if (family.order === 0) {
    return {
      rarityId,
      family: family.id,
      order: 0,
      repeatedDigit: 0,
      rank: 0,
      title: family.title,
      patternLabel: family.title,
      glyphAddress: "0".repeat(depth),
      binStride: null,
      subeventOffset: null,
      symbol: family.symbol,
      semanticColorToken: override?.semanticColorToken ?? family.semanticColorToken,
      digitSemanticColorToken: digit.semanticColorToken,
      notificationEligible: family.notificationEligible,
      isHeader: false,
    };
  }

  const suffixLength = Math.max(depth - family.wildcardPrefixCount, 0);
  const isHeader = repeatedDigit === 0;
  const title = isHeader ? family.title : `${digit.prefix} ${family.title}`;
  const patternLabel = isHeader
    ? family.title
    : `${"X".repeat(Math.min(family.wildcardPrefixCount, depth))}${String(repeatedDigit).repeat(
        suffixLength,
      )}`;
  const glyphDigit = isHeader ? catalog.rarities.headerGlyphDigit : repeatedDigit;
  const glyphAddress = `${"0".repeat(
    Math.min(family.wildcardPrefixCount, depth),
  )}${String(glyphDigit).repeat(suffixLength)}`;
  const binStride = suffixLength > 0 ? catalog.radix.value ** suffixLength : null;
  const subeventOffset =
    binStride === null
      ? null
      : isHeader
        ? 0
        : repeatedDigit * ((Math.max(binStride, 1) - 1) / (catalog.radix.value - 1));

  return {
    rarityId,
    family: family.id,
    order: family.order,
    repeatedDigit,
    rank: family.order * catalog.radix.value + repeatedDigit,
    title,
    patternLabel,
    glyphAddress,
    binStride,
    subeventOffset,
    symbol: family.symbol,
    semanticColorToken: override?.semanticColorToken ?? family.semanticColorToken,
    digitSemanticColorToken: digit.semanticColorToken,
    notificationEligible: family.notificationEligible,
    isHeader,
  };
}

/** Return the average duration of a catalog pulse unit, expressed in seconds. */
export function pulseDuration(catalog: DomainCatalog, unitId: TemporalUnitId): PulseDuration {
  const unit = temporalUnit(catalog, unitId);
  return {
    unitId: unit.id,
    exponent: unit.exponent,
    seconds: catalog.time.basePeriod.seconds / catalog.radix.value ** unit.exponent,
  };
}

/**
 * Read a supplied instant inside a supplied interval. No wall clock, timezone, or
 * locale is consulted. Instants before/after the interval clamp to the first/final
 * bin while countdown arithmetic remains relative to the original instant.
 */
export function clockReading(catalog: DomainCatalog, input: ClockReadingInput): ClockReading {
  assertFinite(input.previousEpochSeconds, "Previous epoch seconds");
  assertFinite(input.nextEpochSeconds, "Next epoch seconds");
  assertFinite(input.instantEpochSeconds, "Instant epoch seconds");
  const harmonicDepth = assertCalculationDepth(catalog, input.harmonicDepth);
  const total = input.nextEpochSeconds - input.previousEpochSeconds;

  if (!Number.isFinite(total) || total <= 0) {
    throw new RangeError("Clock interval must have a positive finite duration.");
  }

  const rawPhase = (input.instantEpochSeconds - input.previousEpochSeconds) / total;
  const phase = clamp(rawPhase, 0, 1 - Number.EPSILON);
  const binCount = catalog.radix.value ** harmonicDepth;
  if (!Number.isSafeInteger(binCount)) {
    throw new RangeError(`Bin count ${binCount} is not a safe integer.`);
  }

  const scaled = phase * binCount;
  const binIndex = Math.min(Math.floor(scaled), binCount - 1);
  const progressWithinBin = clamp(scaled - binIndex, 0, 1);
  const nextBinIndex = Math.min(binIndex + 1, binCount);
  const nextFlipEpochSeconds = input.previousEpochSeconds + (nextBinIndex / binCount) * total;

  return {
    previousEpochSeconds: input.previousEpochSeconds,
    nextEpochSeconds: input.nextEpochSeconds,
    instantEpochSeconds: input.instantEpochSeconds,
    harmonicDepth,
    phase,
    binCount,
    binIndex,
    octalAddress: binIndex.toString(catalog.radix.value).padStart(harmonicDepth, "0"),
    progressWithinBin,
    nextFlipEpochSeconds,
    timeUntilNextFlip: nextFlipEpochSeconds - input.instantEpochSeconds,
  };
}

/** Bind the pure operations to one versioned catalog for convenient UI injection. */
export function createTemporalEngine(catalog: DomainCatalog): TemporalEngine {
  return Object.freeze({
    catalogVersion: catalog.catalogVersion,
    schemaVersion: catalog.schemaVersion,
    clampPresentationDepth: (value: number) => clampPresentationDepth(catalog, value),
    assertCalculationDepth: (value: number) => assertCalculationDepth(catalog, value),
    canonicalOctalAddress: (value: string, storedDepth: number, outputDepth?: number) =>
      canonicalOctalAddress(catalog, value, storedDepth, outputDepth),
    rarityOctalAddress: (
      value: string,
      storedDepth: number,
      rarityId: RarityInputId,
      outputDepth?: number,
    ) => rarityOctalAddress(catalog, value, storedDepth, rarityId, outputDepth),
    resolveRarity: (rarityId: RarityInputId) => resolveRarity(catalog, rarityId),
    classifyRarity: (input: ClassifyRarityInput) => classifyRarity(catalog, input),
    rarityDescriptor: (input: RarityDescriptorInput) => rarityDescriptor(catalog, input),
    pulseDuration: (unitId: TemporalUnitId) => pulseDuration(catalog, unitId),
    clockReading: (input: ClockReadingInput) => clockReading(catalog, input),
  });
}

/** The default engine used by the web application. */
export const canonicalTemporalEngine = createTemporalEngine(canonicalCatalog);

export * from "./saros.js";

function clampStorageOutputDepth(catalog: DomainCatalog, value: number): PresentationDepth {
  assertSafeInteger(value, "Storage output depth");
  return clamp(
    value,
    catalog.harmonics.presentationDepth.minimum,
    catalog.harmonics.presentationDepth.canonical,
  ) as PresentationDepth;
}

function classificationFromResolved(rarity: ResolvedRarity): RarityClassification {
  return {
    rarityId: rarity.rarityId,
    family: rarity.family.id,
    order: rarity.family.order,
    repeatedDigit: rarity.repeatedDigit,
  };
}

function commonClassification(catalog: DomainCatalog): RarityClassification {
  const family = catalog.rarities.families.find((candidate) => candidate.order === 0);
  if (family === undefined) {
    throw new RangeError("The catalog does not define a common rarity family.");
  }
  return {
    rarityId: family.id,
    family: family.id,
    order: family.order,
    repeatedDigit: 0,
  };
}

function digitDefinition(catalog: DomainCatalog, digit: RarityDigit) {
  const definition = catalog.rarities.digits.find((candidate) => candidate.digit === digit);
  if (definition === undefined) {
    throw new RangeError(`The catalog does not define rarity digit ${digit}.`);
  }
  return definition;
}

function temporalUnit(catalog: DomainCatalog, unitId: TemporalUnitId): TemporalUnit {
  const unit = catalog.time.units.find((candidate) => candidate.id === unitId);
  if (unit === undefined) {
    throw new RangeError(`Unknown time unit ${unitId}.`);
  }
  return unit;
}

function retainRadixDigits(catalog: DomainCatalog, value: string): string {
  const supported = new Set(catalog.radix.digits);
  return [...value].filter((character) => supported.has(character)).join("");
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

function clamp(value: number, minimum: number, maximum: number): number {
  return Math.min(Math.max(value, minimum), maximum);
}
