import { canonicalCatalog, canonicalConformance } from "@exeligmos/domain-catalog";
import { describe, expect, it } from "vitest";

import {
  clampGlyphDepth,
  createOctalGlyph,
  glyphFrameBounds,
  glyphSocketDigitIndices,
  glyphStyleForRarity,
  normalizeGlyphOctal,
  pathData,
  semanticGlyphStyle,
  splitSemanticGlyphStyle,
  type GlyphStyle,
} from "./index.js";

const supportedDepths = range(
  canonicalCatalog.glyph.supportedDepth.minimum,
  canonicalCatalog.glyph.supportedDepth.maximum,
);

describe("canonical glyph conformance", () => {
  const operations = new Set([
    "clampPresentationDepth",
    "normalizeGlyphOctal",
    "glyphSocketDigitIndices",
    "glyphFrameBounds",
  ]);
  const vectors = canonicalConformance.vectors.filter((vector) => operations.has(vector.operation));

  for (const vector of vectors) {
    it(vector.id, () => {
      const input = vector.input as Record<string, unknown>;
      const actual = (() => {
        switch (vector.operation) {
          case "clampPresentationDepth":
            return { value: clampGlyphDepth(input.value) };
          case "normalizeGlyphOctal":
            return { value: normalizeGlyphOctal(input.value, input.depth) };
          case "glyphSocketDigitIndices":
            return { indices: glyphSocketDigitIndices(input.depth) };
          case "glyphFrameBounds": {
            const frame = glyphFrameBounds(input.depth);
            return {
              width: frame.width,
              height: frame.height,
              aspectRatio: frame.aspectRatio,
            };
          }
          default:
            throw new Error(`Unhandled glyph conformance operation ${vector.operation}`);
        }
      })();
      expect(actual).toMatchObject(vector.expected);
    });
  }

  it("executes every canonical glyph-related vector", () => {
    expect(vectors.map((vector) => vector.id)).toEqual([
      "depth.clamp-low",
      "depth.clamp-default",
      "depth.clamp-high",
      "glyph.normalize-left-pad",
      "glyph.normalize-keeps-rightmost",
      "glyph.socket-order-depth-three",
      "glyph.socket-order-depth-seven",
      "glyph.frame-depth-three",
      "glyph.frame-depth-five",
      "glyph.frame-depth-seven",
    ]);
  });
});

describe("catalog-driven octal geometry", () => {
  it("matches every stable Swift frame", () => {
    expect(supportedDepths.map((depth) => [depth, glyphFrameBounds(depth)])).toEqual([
      [3, { x: -176, y: -200, width: 352, height: 400, aspectRatio: 0.88 }],
      [4, { x: -200, y: -200, width: 400, height: 400, aspectRatio: 1 }],
      [5, { x: -192, y: -200, width: 384, height: 400, aspectRatio: 0.96 }],
      [6, { x: -176, y: -200, width: 352, height: 400, aspectRatio: 0.88 }],
      [7, { x: -200, y: -200, width: 400, height: 400, aspectRatio: 1 }],
      [8, { x: -200, y: -200, width: 400, height: 400, aspectRatio: 1 }],
    ]);
  });

  for (const depth of supportedDepths) {
    describe(`depth ${depth}`, () => {
      for (const digitDefinition of canonicalCatalog.rarities.digits) {
        const digit = digitDefinition.digit;
        it(`renders all sockets for digit ${digit}`, () => {
          const model = createOctalGlyph({
            value: String(digit).repeat(depth),
            depth,
            rarityId: "common",
          });
          const arms = model.paths.filter((path) => path.id.startsWith("arm-"));
          expect(model.viewBox).toEqual(frameTuple(glyphFrameBounds(depth)));
          expect(model.paths[0]?.contours).toHaveLength(2);
          expect(arms).toHaveLength(digit === 0 ? 0 : depth);
          expect(arms.every((path) => path.digit === digit)).toBe(true);
          for (const path of model.paths) {
            expect(pathData(path)).not.toContain("NaN");
            for (const contour of path.contours) {
              for (const point of contour.points) {
                expect(Number.isFinite(point.x) && Number.isFinite(point.y)).toBe(true);
                expect(point.x).toBeGreaterThanOrEqual(model.viewBox[0]);
                expect(point.x).toBeLessThanOrEqual(model.viewBox[0] + model.viewBox[2]);
                expect(point.y).toBeGreaterThanOrEqual(model.viewBox[1]);
                expect(point.y).toBeLessThanOrEqual(model.viewBox[1] + model.viewBox[3]);
              }
            }
          }
        });
      }
    });
  }

  it("retains the exact depth-seven legacy hole as the second even-odd contour", () => {
    const core = createOctalGlyph({ value: "1234567", depth: 7, rarityId: "common" }).paths[0];
    if (core === undefined) {
      throw new Error("The glyph core path is required.");
    }
    expect(core.fillRule).toBe("evenodd");
    expect(core.contours).toHaveLength(2);
    expect(core.contours[1]?.points.map((point) => [point.x, point.y])).toEqual(
      canonicalCatalog.glyph.coreHole.legacyExactPoints,
    );
    expect(pathData(core).match(/\bM\b/g)).toHaveLength(2);
  });

  it("maps split colors by digit index while the core stays secondary", () => {
    const model = createOctalGlyph({
      value: "11111",
      depth: 5,
      style: splitSemanticGlyphStyle("color.digit.1", "color.digit.2", 2),
    });
    expect(model.paths[0]?.colorRole).toBe("secondary");
    expect(
      model.paths.slice(1).map((path) => [path.socketIndex, path.digitIndex, path.colorRole]),
    ).toEqual([
      [0, 0, "primary"],
      [1, 4, "secondary"],
      [2, 3, "secondary"],
      [3, 2, "secondary"],
      [4, 1, "primary"],
    ]);
  });

  it("is deterministic and deeply immutable", () => {
    const left = createOctalGlyph({ value: "7654321", depth: 7, rarityId: "epic-2" });
    const right = createOctalGlyph({ value: "7654321", depth: 7, rarityId: "epic-2" });
    expect(left).toEqual(right);
    expect(left).not.toBe(right);
    expect(Object.isFrozen(left)).toBe(true);
    expect(Object.isFrozen(left.paths)).toBe(true);
    expect(Object.isFrozen(left.paths[0]?.contours[0]?.points)).toBe(true);
  });
});

describe("input and semantic style normalization", () => {
  it("filters malformed values, keeps the rightmost digits, and safely defaults depth", () => {
    expect(normalizeGlyphOctal("🜚a12-87z", "4.9")).toBe("0127");
    expect(normalizeGlyphOctal("abc12345670z", 7)).toBe("2345670");
    expect(
      normalizeGlyphOctal(
        {
          toString: () => {
            throw new Error("bad input");
          },
        },
        NaN,
      ),
    ).toBe("0".repeat(canonicalCatalog.harmonics.presentationDepth.default));
    expect(clampGlyphDepth(-Infinity)).toBe(canonicalCatalog.harmonics.presentationDepth.default);
  });

  it("rejects malformed style objects instead of inventing color defaults", () => {
    const malformed = {
      mode: "split",
      primary: { semanticToken: "not.registered", fallbackSrgb: "transparent" },
      secondary: { semanticToken: "also.invalid", fallbackSrgb: "transparent" },
      splitAfterDigitCount: Number.POSITIVE_INFINITY,
    } as unknown as GlyphStyle;
    expect(() => createOctalGlyph({ value: "111", depth: 3, style: malformed })).toThrow(
      "Unknown glyph semantic color token",
    );
  });

  it("requires an explicit semantic style or rarity", () => {
    expect(() => createOctalGlyph({ value: "111", depth: 3 } as never)).toThrow(
      "require exactly one explicit style or rarityId",
    );
    expect(() =>
      createOctalGlyph({
        value: "111",
        depth: 3,
        rarityId: "common",
        style: semanticGlyphStyle("color.digit.1"),
      } as never),
    ).toThrow("require exactly one explicit style or rarityId");
  });

  it("uses every rarity family token, aliases, and exact color overrides from the catalog", () => {
    for (const family of canonicalCatalog.rarities.families) {
      expect(glyphStyleForRarity(family.id).primary.semanticToken).toBe(family.semanticColorToken);
    }
    for (const alias of canonicalCatalog.rarities.aliases) {
      expect(glyphStyleForRarity(alias.alias).rarityId).toBe(alias.target);
    }
    for (const override of canonicalCatalog.rarities.colorOverrides) {
      expect(glyphStyleForRarity(override.rarityId).primary.semanticToken).toBe(
        override.semanticColorToken,
      );
    }
    expect(glyphStyleForRarity("future-rarity").rarityId).toBe("common");
  });

  it("rejects unknown semantic tokens at the explicit style boundary", () => {
    expect(() => semanticGlyphStyle("color.unregistered")).toThrow(
      "Unknown glyph semantic color token",
    );
  });
});

function range(minimum: number, maximum: number): readonly number[] {
  return Array.from({ length: maximum - minimum + 1 }, (_, index) => minimum + index);
}

function frameTuple(
  frame: ReturnType<typeof glyphFrameBounds>,
): readonly [number, number, number, number] {
  return [frame.x, frame.y, frame.width, frame.height];
}
