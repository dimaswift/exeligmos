import { canonicalConformance, resolveEventType } from "@exeligmos/domain-catalog";
import {
  glyphFrameBounds,
  glyphSocketDigitIndices,
  normalizeGlyphOctal,
} from "@exeligmos/glyph-core";
import { canonicalTemporalEngine } from "@exeligmos/temporal-core";

export type CanonicalConformanceVector = (typeof canonicalConformance.vectors)[number];

export interface ConformanceResult {
  readonly id: string;
  readonly operation: CanonicalConformanceVector["operation"];
  readonly passed: boolean;
  readonly expected: unknown;
  readonly actual: unknown;
}

/**
 * Execute the language-neutral vectors through the same production functions used
 * by routes and renderers. This is intentionally deterministic and safe during SSR.
 */
export function runCanonicalConformance(): readonly ConformanceResult[] {
  return canonicalConformance.vectors.map((vector) => {
    try {
      const actual = executeVector(vector);
      return {
        id: vector.id,
        operation: vector.operation,
        passed: expectedSubsetMatches(vector.expected, actual, canonicalConformance.floatTolerance),
        expected: vector.expected,
        actual,
      };
    } catch (error: unknown) {
      return {
        id: vector.id,
        operation: vector.operation,
        passed: false,
        expected: vector.expected,
        actual: {
          error: error instanceof Error ? error.message : "Unknown conformance error",
        },
      };
    }
  });
}

function executeVector(vector: CanonicalConformanceVector): unknown {
  switch (vector.operation) {
    case "clampPresentationDepth":
      return {
        value: canonicalTemporalEngine.clampPresentationDepth(vector.input.value),
      };
    case "canonicalOctalAddress":
      return {
        value: canonicalTemporalEngine.canonicalOctalAddress(
          vector.input.value,
          vector.input.storedDepth,
          vector.input.outputDepth,
        ),
      };
    case "rarityOctalAddress":
      return {
        value: canonicalTemporalEngine.rarityOctalAddress(
          vector.input.value,
          vector.input.storedDepth,
          vector.input.rarityId,
          vector.input.outputDepth,
        ),
      };
    case "normalizeGlyphOctal":
      return {
        value: normalizeGlyphOctal(vector.input.value, vector.input.depth),
      };
    case "classifyRarity":
      return canonicalTemporalEngine.classifyRarity(vector.input);
    case "rarityDescriptor":
      return canonicalTemporalEngine.rarityDescriptor(vector.input);
    case "pulseDuration":
      return canonicalTemporalEngine.pulseDuration(vector.input.unitId);
    case "clockReading":
      return canonicalTemporalEngine.clockReading(vector.input);
    case "glyphSocketDigitIndices":
      return {
        indices: glyphSocketDigitIndices(vector.input.depth),
      };
    case "glyphFrameBounds":
      return glyphFrameBounds(vector.input.depth);
    case "eventTypeResolution":
      return resolveEventType(vector.input.type);
    default:
      return assertUnreachable(vector);
  }
}

function expectedSubsetMatches(expected: unknown, actual: unknown, tolerance: number): boolean {
  if (typeof expected === "number") {
    if (typeof actual !== "number" || !Number.isFinite(actual)) {
      return false;
    }
    if (Number.isInteger(expected)) {
      return Object.is(expected, actual);
    }
    const scale = Math.max(1, Math.abs(expected));
    return Math.abs(expected - actual) <= tolerance * scale;
  }

  if (Array.isArray(expected)) {
    return (
      Array.isArray(actual) &&
      expected.length === actual.length &&
      expected.every((item, index) => expectedSubsetMatches(item, actual[index], tolerance))
    );
  }

  if (isRecord(expected)) {
    return (
      isRecord(actual) &&
      Object.entries(expected).every(([key, value]) =>
        expectedSubsetMatches(value, actual[key], tolerance),
      )
    );
  }

  return Object.is(expected, actual);
}

function isRecord(value: unknown): value is Readonly<Record<string, unknown>> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function assertUnreachable(value: never): never {
  throw new Error(`Unsupported conformance vector: ${JSON.stringify(value)}`);
}
