import { describe, expect, it } from "vitest";

import {
  glyphColor,
  normalizeColorPalette,
  normalizeHexColor,
  readableTextColor,
} from "./glyph-colors";
import {
  bezierSegmentsFromPolyline,
  bezierSegmentsPathData,
  bitsToDigit,
  composeArmInstances,
  disconnectedBitIndices,
  digitToBits,
  findGlyphCollisions,
  formatRadixDigits,
  freeformStrokeIsVisible,
  incrementDigits,
  makeCoreShellSegments,
  makeLayout,
  makeStrokeSegments,
  normalizeDigits,
  parseDigitInput,
  parseValueInBase,
  radixForBitWidth,
  segmentPathData,
  segmentIsVisible,
  snapPointToGrid,
  tracedStrokeIsVisible,
  valueToDigits,
} from "./glyph-engine";
import type { FreeformStroke, StrokeSegment, TracedStroke } from "./types";

describe("radix and bit encoding", () => {
  it("maps bit widths to their power-of-two radix", () => {
    expect([3, 4, 5, 8, 16].map(radixForBitWidth)).toEqual([8, 16, 32, 256, 65_536]);
  });

  it("supports and clamps full 16-bit digits", () => {
    const bits = digitToBits(0xa55a, 16);
    expect(bits).toHaveLength(16);
    expect(bitsToDigit(bits)).toBe(0xa55a);
    expect(radixForBitWidth(99)).toBe(65_536);
  });

  it("round-trips MSB-first bit patterns", () => {
    const bits = digitToBits(0xa, 4);
    expect(bits).toEqual([true, false, true, false]);
    expect(bitsToDigit(bits)).toBe(0xa);
  });

  it("parses alphabetic digits through base 32 and numeric tokens above base 36", () => {
    expect(parseDigitInput("face!", 4)).toEqual([15, 10, 12, 14]);
    expect(parseDigitInput("V10", 5)).toEqual([31, 1, 0]);
    expect(parseDigitInput("255 8 64", 8)).toEqual([255, 8, 64]);
  });

  it("pads, truncates, and reverses assembly order deterministically", () => {
    expect(normalizeDigits("ACE", 4, 5, "msb-first")).toEqual([0, 0, 10, 12, 14]);
    expect(normalizeDigits("123456", 4, 4, "lsb-first")).toEqual([6, 5, 4, 3]);
  });

  it("strictly parses values from small and tokenized large bases", () => {
    expect(parseValueInBase("101010", 2)).toBe(42n);
    expect(parseValueInBase("FACE", 16)).toBe(0xFACEn);
    expect(parseValueInBase("1 0 255", 256)).toBe(65_791n);
    expect(parseValueInBase("2", 2)).toBeNull();
    expect(parseValueInBase("256", 256)).toBeNull();
  });

  it("converts integers to target-base digits and formats large-base tokens", () => {
    expect(valueToDigits(255n, 16)).toEqual([15, 15]);
    expect(valueToDigits(255n, 256)).toEqual([255]);
    expect(valueToDigits(0n, 16)).toEqual([0]);
    expect(formatRadixDigits([1, 0, 255], 256)).toBe("1 0 255");
  });

  it("increments fixed-width digit vectors with carry and wraparound", () => {
    expect(incrementDigits([0, 15, 15], 16)).toEqual([1, 0, 0]);
    expect(incrementDigits([15, 15], 16)).toEqual([0, 0]);
  });
});

describe("layouts and stroke recipes", () => {
  it("generates one finite point per bit for every preset", () => {
    for (const preset of ["line", "square", "triangle", "diamond", "orbit"] as const) {
      const points = makeLayout(preset, 8);
      expect(points).toHaveLength(8);
      expect(points.every((point) => Number.isFinite(point.x) && Number.isFinite(point.y))).toBe(
        true,
      );
    }
  });

  it("gates the default ray strokes by their target bits", () => {
    const segments = makeStrokeSegments("rays", 4);
    const bits = digitToBits(0xa, 4);
    expect(segments.map((segment) => segmentIsVisible(segment, bits))).toEqual([
      true,
      false,
      true,
      false,
    ]);
  });

  it("finds bit vertices untouched by visible generated and traced segments", () => {
    const bits = digitToBits(0b0101, 4);
    const generated: readonly StrokeSegment[] = [
      { id: "generated", from: "root", to: 3, condition: "target", curve: "line", bend: 0 },
      { id: "hidden", from: 0, to: 1, condition: "both", curve: "line", bend: 0 },
    ];
    const traced: readonly TracedStroke[] = [
      { id: "manual", digit: 5, from: "core", to: 1, curve: "line", bend: 0 },
    ];
    expect(disconnectedBitIndices(bits, generated, traced, 5)).toEqual([0, 2]);
    expect(disconnectedBitIndices(bits, generated, traced, 4)).toEqual([0, 1, 2]);
  });

  it("detects visually identical digits in an incomplete stroke graph", () => {
    expect(findGlyphCollisions(4, makeStrokeSegments("rays", 4))).toEqual([]);
    expect(findGlyphCollisions(2, [])).toEqual([[0, 1, 2, 3]]);
  });

  it("treats independently activated bends as distinct visible geometry", () => {
    const segments: readonly StrokeSegment[] = [
      { id: "upper", from: 0, to: 1, condition: "source", curve: "hyperbolic", bend: 24 },
      { id: "lower", from: 0, to: 1, condition: "target", curve: "hyperbolic", bend: -24 },
    ];
    expect(findGlyphCollisions(2, segments)).toEqual([]);
  });

  it("builds LSB active chains without wrapping or jumping across gaps", () => {
    expect(makeCoreShellSegments(4, 0b0111, 2).map(({ from, to }) => [from, to])).toEqual([
      ["core", 3],
      [3, 2],
      [2, 1],
      ["root", 2],
    ]);
    expect(makeCoreShellSegments(4, 0b0101, 3).map(({ from, to }) => [from, to])).toEqual([
      ["core", 3],
      ["core", 1],
      ["root", 3],
    ]);
    expect(makeCoreShellSegments(4, 0b1001, 3).map(({ from, to }) => [from, to])).toEqual([
      ["core", 3],
      ["core", 0],
      [2, 1],
      ["root", 3],
    ]);
  });

  it("draws only cyclic shell edges whose two neighboring bits are inactive", () => {
    expect(makeCoreShellSegments(4, 0, 99).map(({ from, to }) => [from, to])).toEqual([
      [0, 3],
      [3, 2],
      [2, 1],
      [1, 0],
      ["root", 3],
    ]);
    expect(makeCoreShellSegments(4, 0b0010, 3).map(({ from, to }) => [from, to])).toEqual([
      ["core", 2],
      [0, 3],
      [1, 0],
      ["root", 3],
    ]);
  });

  it("applies all three rule steps to the first 20 base-256 study digits", () => {
    for (let digit = 0; digit < 20; digit += 1) {
      const bits = digitToBits(digit, 8);
      const segments = makeCoreShellSegments(8, digit, 6);
      const active = segments
        .filter(({ id }) => id.startsWith("core-shell-active-"))
        .map(({ from, to }) => [from, to]);
      const shell = segments
        .filter(({ id }) => id.startsWith("core-shell-inactive-"))
        .map(({ from, to }) => [from, to].sort().join("-"))
        .sort();
      const expectedActive: (string | number)[][] = [];
      let previousActive: number | undefined;

      for (let bit = 7; bit >= 0; bit -= 1) {
        if (!bits[bit]) continue;
        expectedActive.push([previousActive !== undefined && previousActive - bit === 1 ? previousActive : "core", bit]);
        previousActive = bit;
      }

      const expectedShell = Array.from({ length: 8 }, (_, bit) => [bit, (bit + 1) % 8] as const)
        .filter(([from, to]) => !bits[from] && !bits[to])
        .map(([from, to]) => [from, to].sort().join("-"))
        .sort();

      expect(active, `active segments for ${digit}`).toEqual(expectedActive);
      expect(shell, `shell segments for ${digit}`).toEqual(expectedShell);
      expect(segments.at(-1), `root segment for ${digit}`).toMatchObject({ from: "root", to: 6 });
    }
  });

  it("resolves the movable core endpoint in generated paths", () => {
    const segment = makeCoreShellSegments(4, 1, 3)[0];
    expect(segment).toBeDefined();
    expect(segmentPathData(segment!, makeLayout("square", 4), 24, { x: 18, y: -84 }))
      .toContain("M 18 -84 L 56 -136");
  });

  it("keeps all hexadecimal core-shell forms structurally distinct", () => {
    expect(findGlyphCollisions(4, [], [], [], {
      strokePreset: "core-shell",
      bottomBit: 3,
    })).toEqual([]);
  });
});

describe("vertex grids and curved segments", () => {
  it("snaps to square, triangular, and hexagonal lattice vertices", () => {
    expect(snapPointToGrid({ x: 23, y: -29 }, "square", 16)).toEqual({ x: 16, y: -32 });

    const triangular = snapPointToGrid({ x: 9, y: -14 }, "triangular", 16);
    expect(triangular.x).toBeCloseTo(8);
    expect(triangular.y).toBeCloseTo(-8 * Math.sqrt(3));

    const hexagonal = snapPointToGrid({ x: 18, y: -29 }, "hexagonal", 20);
    expect(hexagonal.x).toBeCloseTo(10 * Math.sqrt(3));
    expect(hexagonal.y).toBeCloseTo(-30);
    expect(snapPointToGrid(hexagonal, "hexagonal", 20)).toEqual(hexagonal);
  });

  it("uses a hyperbolic-cosine arch with stable endpoints and signed bend", () => {
    const straight: StrokeSegment = {
      id: "line",
      from: "root",
      to: 0,
      condition: "always",
      curve: "line",
      bend: 0,
    };
    const curved: StrokeSegment = { ...straight, id: "curve", curve: "hyperbolic", bend: 32 };
    const points = [{ x: 100, y: 0 }];
    expect(segmentPathData(straight, points)).toBe("M 0 0 L 100 0");
    const path = segmentPathData(curved, points, 24);
    expect(path.startsWith("M 0 0")).toBe(true);
    expect(path.endsWith("L 100 0")).toBe(true);
    expect(path).toContain("L 50 32");
    expect(segmentPathData({ ...curved, bend: -32 }, points, 24)).toContain("L 50 -32");
  });

  it("converts a hand-drawn polyline into portable cubic Bezier geometry", () => {
    const segments = bezierSegmentsFromPolyline([
      { x: -80, y: -40 },
      { x: -40, y: -100 },
      { x: 0, y: -60 },
      { x: 44, y: -132 },
      { x: 82, y: -72 },
    ], 0.5);
    const path = bezierSegmentsPathData(segments);
    expect(segments.length).toBeGreaterThan(1);
    expect(path.startsWith("M -80 -40 C ")).toBe(true);
    expect(path.endsWith("82 -72")).toBe(true);
  });

  it("assigns each freeform stroke to one exact digit and includes it in collision checks", () => {
    const stroke: FreeformStroke = {
      id: "gesture",
      digit: 2,
      segments: bezierSegmentsFromPolyline([{ x: -40, y: -40 }, { x: 40, y: -90 }]),
    };
    expect(freeformStrokeIsVisible(stroke, 1)).toBe(false);
    expect(freeformStrokeIsVisible(stroke, 2)).toBe(true);
    expect(findGlyphCollisions(2, [], [stroke])).toEqual([[0, 1, 3]]);
  });

  it("assigns traced segments to one exact digit and preserves their curve geometry", () => {
    const stroke: TracedStroke = {
      id: "traced",
      digit: 2,
      from: "root",
      to: 0,
      curve: "hyperbolic",
      bend: -32,
    };
    expect(tracedStrokeIsVisible(stroke, 1)).toBe(false);
    expect(tracedStrokeIsVisible(stroke, 2)).toBe(true);
    expect(segmentPathData(stroke, [{ x: 100, y: 0 }])).toContain("L 50 -32");
    expect(findGlyphCollisions(2, [], [], [stroke])).toEqual([[0, 1, 3]]);
  });
});

describe("multi-digit assembly", () => {
  it("respects start angle and reading direction", () => {
    const clockwise = composeArmInstances({
      digits: [1, 2, 3, 4],
      layout: "radial",
      direction: "clockwise",
      startAngle: -30,
      fanSpread: 120,
      lineSpacing: 140,
    });
    const counterclockwise = composeArmInstances({
      digits: [1, 2, 3, 4],
      layout: "radial",
      direction: "counterclockwise",
      startAngle: -30,
      fanSpread: 120,
      lineSpacing: 140,
    });
    expect(clockwise.map((arm) => arm.rotation)).toEqual([-30, 60, 150, 240]);
    expect(counterclockwise.map((arm) => arm.rotation)).toEqual([-30, -120, -210, -300]);
  });

  it("uses configurable center spacing in line mode and scales wide rows to fit", () => {
    const tight = composeArmInstances({
      digits: [1, 2, 3],
      layout: "linear",
      direction: "clockwise",
      startAngle: 0,
      fanSpread: 120,
      lineSpacing: 60,
    });
    const wide = composeArmInstances({
      digits: [1, 2, 3, 4, 5, 6],
      layout: "linear",
      direction: "clockwise",
      startAngle: 0,
      fanSpread: 120,
      lineSpacing: 280,
    });
    expect(tight.map(({ x }) => x)).toEqual([-60, 0, 60]);
    expect(tight.every(({ scale }) => scale === 1)).toBe(true);
    expect(wide.at(0)?.x).toBeCloseTo(-220);
    expect(wide.at(-1)?.x).toBeCloseTo(220);
    expect(wide[0]?.scale).toBeCloseTo(440 / 1400);
  });
});

describe("glyph colors", () => {
  const settings = {
    colorMode: "single" as const,
    inkColor: "#123456",
    paletteColors: ["#111111", "#222222", "#333333"],
  };

  it("maps single, position, and digit colors through editable settings", () => {
    expect(glyphColor(settings, 8, 17)).toBe("#123456");
    expect(glyphColor({ ...settings, colorMode: "position" }, 4, 17)).toBe("#222222");
    expect(glyphColor({ ...settings, colorMode: "digit" }, 4, 5)).toBe("#333333");
  });

  it("normalizes imported colors and selects readable canvas text", () => {
    expect(normalizeHexColor("#A0b1C2", "#000000")).toBe("#a0b1c2");
    expect(normalizeHexColor("red", "#000000")).toBe("#000000");
    expect(normalizeColorPalette(["#010203", "invalid"])[0]).toBe("#010203");
    expect(readableTextColor("#ffffff")).toBe("#17201c");
    expect(readableTextColor("#000000")).toBe("#f5f6ef");
  });
});
