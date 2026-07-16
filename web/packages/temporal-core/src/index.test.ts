import { describe, expect, it } from "vitest";

import { canonicalCatalog, canonicalConformance } from "@exeligmos/domain-catalog";

import {
  assertCalculationDepth,
  canonicalOctalAddress,
  canonicalTemporalEngine,
  classifyRarity,
  clampPresentationDepth,
  clockReading,
  createTemporalEngine,
  pulseDuration,
  rarityDescriptor,
  rarityOctalAddress,
  resolveRarity,
} from "./index.js";

type TemporalOperation =
  | "clampPresentationDepth"
  | "canonicalOctalAddress"
  | "rarityOctalAddress"
  | "classifyRarity"
  | "rarityDescriptor"
  | "pulseDuration"
  | "clockReading";

interface ConformanceVector {
  readonly id: string;
  readonly operation: string;
  readonly input: Readonly<Record<string, unknown>>;
  readonly expected: unknown;
}

interface ConformanceEnvelope {
  readonly catalogVersion: string;
  readonly floatTolerance: number;
  readonly vectors: readonly ConformanceVector[];
}

const conformance = canonicalConformance as unknown as ConformanceEnvelope;
const temporalOperations = new Set<TemporalOperation>([
  "clampPresentationDepth",
  "canonicalOctalAddress",
  "rarityOctalAddress",
  "classifyRarity",
  "rarityDescriptor",
  "pulseDuration",
  "clockReading",
]);
const temporalVectors = conformance.vectors.filter(
  (vector): vector is ConformanceVector & { readonly operation: TemporalOperation } =>
    temporalOperations.has(vector.operation as TemporalOperation),
);

describe("canonical temporal conformance", () => {
  it("executes every non-glyph temporal and rarity vector", () => {
    expect(temporalVectors).toHaveLength(29);
    expect(conformance.catalogVersion).toBe(canonicalCatalog.catalogVersion);
  });

  it.each(temporalVectors)("$id", (vector) => {
    const actual = executeVector(vector);
    expectConformanceSubset(actual, vector.expected, conformance.floatTolerance, vector.id);
  });
});

describe("depth contracts", () => {
  it("clamps presentation values but strictly validates calculation depths", () => {
    const presentation = canonicalCatalog.harmonics.presentationDepth;
    const calculation = canonicalCatalog.harmonics.calculationDepth;

    expect(clampPresentationDepth(canonicalCatalog, calculation.minimum)).toBe(
      presentation.minimum,
    );
    expect(clampPresentationDepth(canonicalCatalog, calculation.maximum + 100)).toBe(
      presentation.maximum,
    );
    expect(assertCalculationDepth(canonicalCatalog, calculation.minimum)).toBe(calculation.minimum);
    expect(assertCalculationDepth(canonicalCatalog, calculation.maximum)).toBe(calculation.maximum);
    expect(() => assertCalculationDepth(canonicalCatalog, calculation.minimum - 1)).toThrow(
      "outside the calculation range",
    );
    expect(() => assertCalculationDepth(canonicalCatalog, calculation.maximum + 1)).toThrow(
      "outside the calculation range",
    );
  });

  it.each([Number.NaN, Number.POSITIVE_INFINITY, 3.5])(
    "rejects a non-integer presentation depth: %s",
    (value) => {
      expect(() => clampPresentationDepth(canonicalCatalog, value)).toThrow("safe integer");
    },
  );
});

describe("address normalization", () => {
  it("keeps storage and classification directions distinct", () => {
    const depth = canonicalCatalog.harmonics.presentationDepth.minimum;
    const canonical = canonicalOctalAddress(canonicalCatalog, "76", depth, depth);

    expect(canonical).toBe("760");
    expect(
      classifyRarity(canonicalCatalog, {
        octalAddress: "76",
        harmonicDepth: depth,
      }).rarityId,
    ).toBe("epic-6");
    expect(
      classifyRarity(canonicalCatalog, {
        octalAddress: canonical,
        harmonicDepth: depth,
      }).rarityId,
    ).toBe("epic-7");
  });

  it("uses only catalog radix digits and clamps output depth", () => {
    const { minimum, canonical } = canonicalCatalog.harmonics.presentationDepth;
    expect(canonicalOctalAddress(canonicalCatalog, "8x17z", minimum, 1)).toBe("170");
    expect(canonicalOctalAddress(canonicalCatalog, "123456701", canonical, 99)).toBe("12345670");
  });

  it("uses the resolved alias digit for rarity padding", () => {
    const depth = canonicalCatalog.harmonics.presentationDepth.minimum;
    expect(rarityOctalAddress(canonicalCatalog, "1", depth, "saros", depth)).toBe("177");
    expect(rarityOctalAddress(canonicalCatalog, "1", depth, "saros0", depth)).toBe("177");
  });
});

describe("rarity semantics", () => {
  it("resolves declared aliases and rejects invented identifiers", () => {
    expect(resolveRarity(canonicalCatalog, "saros")).toMatchObject({
      rarityId: "mythic-7",
      repeatedDigit: 7,
    });
    expect(resolveRarity(canonicalCatalog, "saros0")).toMatchObject({
      rarityId: "mythic-7",
      repeatedDigit: 7,
    });
    expect(() => resolveRarity(canonicalCatalog, "common-1")).toThrow("Unknown rarity");
    expect(() => resolveRarity(canonicalCatalog, "saros-1")).toThrow("Unknown rarity");
  });

  it("preserves all-zero, trailing-zero, and non-special suffix boundaries", () => {
    const depth = canonicalCatalog.harmonics.presentationDepth.default;

    expect(
      classifyRarity(canonicalCatalog, {
        octalAddress: "0".repeat(depth),
        harmonicDepth: depth,
      }).rarityId,
    ).toBe(canonicalCatalog.rarities.classification.allZeroRarity);
    expect(
      classifyRarity(canonicalCatalog, {
        octalAddress: "1230000",
        harmonicDepth: depth,
      }),
    ).toMatchObject({ rarityId: "rare-7", order: 3, repeatedDigit: 7 });
    expect(
      classifyRarity(canonicalCatalog, {
        octalAddress: "1234111",
        harmonicDepth: depth,
      }).rarityId,
    ).toBe("common");
  });

  it("uses the catalog eclipse rarity override", () => {
    expect(
      classifyRarity(canonicalCatalog, {
        octalAddress: "1234567",
        harmonicDepth: canonicalCatalog.harmonics.presentationDepth.default,
        isEclipse: true,
      }).rarityId,
    ).toBe(canonicalCatalog.rarities.classification.allZeroRarity);
  });

  it("keeps header rank/offset semantics and exact color overrides", () => {
    const depth = canonicalCatalog.harmonics.presentationDepth.default;
    const family = canonicalCatalog.rarities.families.find((candidate) => candidate.id === "rare");
    const header = rarityDescriptor(canonicalCatalog, {
      rarityId: "rare",
      harmonicDepth: depth,
    });
    const subrarity = rarityDescriptor(canonicalCatalog, {
      rarityId: "mythic-7",
      harmonicDepth: depth,
    });
    const override = canonicalCatalog.rarities.colorOverrides.find(
      (candidate) => candidate.rarityId === "mythic-7",
    );

    expect(header).toMatchObject({
      repeatedDigit: 0,
      rank: (family?.order ?? 0) * canonicalCatalog.radix.value,
      subeventOffset: 0,
      isHeader: true,
    });
    expect(header.glyphAddress.endsWith(String(canonicalCatalog.rarities.headerGlyphDigit))).toBe(
      true,
    );
    expect(subrarity.semanticColorToken).toBe(override?.semanticColorToken);
    expect(subrarity.digitSemanticColorToken).not.toBe(subrarity.semanticColorToken);
  });
});

describe("clock and pulse calculations", () => {
  it("uses the catalog formula for every unit", () => {
    for (const unit of canonicalCatalog.time.units) {
      expect(pulseDuration(canonicalCatalog, unit.id).seconds).toBe(
        canonicalCatalog.time.basePeriod.seconds / canonicalCatalog.radix.value ** unit.exponent,
      );
    }
  });

  it("rejects non-finite timestamps and non-positive intervals", () => {
    const input = {
      previousEpochSeconds: 0,
      nextEpochSeconds: 1,
      instantEpochSeconds: 0,
      harmonicDepth: canonicalCatalog.harmonics.calculationDepth.minimum,
    };

    expect(() =>
      clockReading(canonicalCatalog, { ...input, instantEpochSeconds: Number.NaN }),
    ).toThrow("must be finite");
    expect(() => clockReading(canonicalCatalog, { ...input, nextEpochSeconds: 0 })).toThrow(
      "positive finite duration",
    );
    expect(() => clockReading(canonicalCatalog, { ...input, nextEpochSeconds: -1 })).toThrow(
      "positive finite duration",
    );
  });

  it("clamps to endpoint bins while retaining relative countdown behavior", () => {
    const depth = canonicalCatalog.harmonics.calculationDepth.minimum;
    const before = clockReading(canonicalCatalog, {
      previousEpochSeconds: 0,
      nextEpochSeconds: 512,
      instantEpochSeconds: -10,
      harmonicDepth: depth,
    });
    const after = clockReading(canonicalCatalog, {
      previousEpochSeconds: 0,
      nextEpochSeconds: 512,
      instantEpochSeconds: 522,
      harmonicDepth: depth,
    });

    expect(before).toMatchObject({ phase: 0, binIndex: 0 });
    expect(before.timeUntilNextFlip).toBeGreaterThan(0);
    expect(after.binIndex).toBe(after.binCount - 1);
    expect(after.nextFlipEpochSeconds).toBe(512);
    expect(after.timeUntilNextFlip).toBe(-10);
  });
});

describe("engine binding", () => {
  it("exposes immutable catalog diagnostics and the same pure behavior", () => {
    const engine = createTemporalEngine(canonicalCatalog);

    expect(engine).not.toBe(canonicalTemporalEngine);
    expect(engine.catalogVersion).toBe(canonicalCatalog.catalogVersion);
    expect(engine.schemaVersion).toBe(canonicalCatalog.schemaVersion);
    expect(Object.isFrozen(engine)).toBe(true);
    expect(engine.pulseDuration("saros")).toEqual(pulseDuration(canonicalCatalog, "saros"));
  });
});

function executeVector(
  vector: ConformanceVector & { readonly operation: TemporalOperation },
): unknown {
  const input = vector.input;
  switch (vector.operation) {
    case "clampPresentationDepth":
      return {
        value: clampPresentationDepth(canonicalCatalog, requiredNumber(input, "value")),
      };
    case "canonicalOctalAddress":
      return {
        value: canonicalOctalAddress(
          canonicalCatalog,
          requiredString(input, "value"),
          requiredNumber(input, "storedDepth"),
          requiredNumber(input, "outputDepth"),
        ),
      };
    case "rarityOctalAddress":
      return {
        value: rarityOctalAddress(
          canonicalCatalog,
          requiredString(input, "value"),
          requiredNumber(input, "storedDepth"),
          requiredString(input, "rarityId"),
          requiredNumber(input, "outputDepth"),
        ),
      };
    case "classifyRarity":
      return classifyRarity(canonicalCatalog, {
        octalAddress: requiredString(input, "octalAddress"),
        harmonicDepth: requiredNumber(input, "harmonicDepth"),
      });
    case "rarityDescriptor":
      return rarityDescriptor(canonicalCatalog, {
        rarityId: requiredString(input, "rarityId"),
        harmonicDepth: requiredNumber(input, "harmonicDepth"),
      });
    case "pulseDuration":
      return pulseDuration(
        canonicalCatalog,
        requiredString(input, "unitId") as Parameters<typeof pulseDuration>[1],
      );
    case "clockReading":
      return clockReading(canonicalCatalog, {
        previousEpochSeconds: requiredNumber(input, "previousEpochSeconds"),
        nextEpochSeconds: requiredNumber(input, "nextEpochSeconds"),
        instantEpochSeconds: requiredNumber(input, "instantEpochSeconds"),
        harmonicDepth: requiredNumber(input, "harmonicDepth"),
      });
  }
}

function requiredNumber(input: Readonly<Record<string, unknown>>, key: string): number {
  const value = input[key];
  if (typeof value !== "number") {
    throw new TypeError(`Expected numeric vector input ${key}.`);
  }
  return value;
}

function requiredString(input: Readonly<Record<string, unknown>>, key: string): string {
  const value = input[key];
  if (typeof value !== "string") {
    throw new TypeError(`Expected string vector input ${key}.`);
  }
  return value;
}

function expectConformanceSubset(
  actual: unknown,
  expected: unknown,
  tolerance: number,
  path: string,
): void {
  if (expected === null || typeof expected !== "object") {
    if (typeof expected === "number" && typeof actual === "number" && !Number.isInteger(expected)) {
      const scaledTolerance = tolerance * Math.max(1, Math.abs(expected));
      expect(Math.abs(actual - expected), path).toBeLessThanOrEqual(scaledTolerance);
      return;
    }
    expect(actual, path).toBe(expected);
    return;
  }

  if (Array.isArray(expected)) {
    expect(Array.isArray(actual), path).toBe(true);
    const actualArray = actual as readonly unknown[];
    expect(actualArray, path).toHaveLength(expected.length);
    expected.forEach((value, index) => {
      expectConformanceSubset(actualArray[index], value, tolerance, `${path}[${index}]`);
    });
    return;
  }

  expect(actual !== null && typeof actual === "object", path).toBe(true);
  const actualObject = actual as Readonly<Record<string, unknown>>;
  for (const [key, value] of Object.entries(expected)) {
    expect(Object.hasOwn(actualObject, key), `${path}.${key}`).toBe(true);
    expectConformanceSubset(actualObject[key], value, tolerance, `${path}.${key}`);
  }
}
