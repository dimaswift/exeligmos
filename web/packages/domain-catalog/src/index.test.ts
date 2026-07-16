import { describe, expect, it } from "vitest";

import {
  canonicalCatalog,
  canonicalCatalogSha256,
  canonicalConformance,
  canonicalConformanceSha256,
  rarityFamiliesById,
  resolveEventType,
  semanticColorsById,
  temporalUnitsById,
} from "./index.js";

describe("canonical domain catalog", () => {
  it("exposes generated indexes without redefining catalog values", () => {
    expect(canonicalCatalog.schemaVersion).toBe(1);
    expect(temporalUnitsById.get("saros")?.title).toBe("Saros");
    expect(rarityFamiliesById.get("mythic")?.title).toBe("Nihil");
    expect(canonicalCatalogSha256).toMatch(/^[a-f0-9]{64}$/);
    expect(canonicalConformance.catalogVersion).toBe(canonicalCatalog.catalogVersion);
    expect(canonicalConformance.vectors).toHaveLength(40);
    expect(canonicalConformanceSha256).toMatch(/^[a-f0-9]{64}$/);
    expect(semanticColorsById.get("color.rarity.nihil")?.fallbackSrgb).toBe("#FFCC00");
  });

  it("resolves every canonical event-type conformance vector", () => {
    const vectors = canonicalConformance.vectors.filter(
      (vector) => vector.operation === "eventTypeResolution",
    );
    expect(vectors).toHaveLength(4);
    for (const vector of vectors) {
      const actual = resolveEventType(vector.input.type);
      expect(actual).toMatchObject(vector.expected);
    }
  });

  it("rejects event types outside the signed int32 wire range", () => {
    expect(() => resolveEventType(-1)).toThrow(RangeError);
    expect(() => resolveEventType(2_147_483_648)).toThrow(RangeError);
    expect(() => resolveEventType(1.5)).toThrow(RangeError);
  });
});
