export type GlyphColorRole = "primary" | "secondary";

export interface GlyphPoint {
  readonly x: number;
  readonly y: number;
}

export interface GlyphContour {
  readonly points: readonly GlyphPoint[];
}

export interface GlyphPaint {
  readonly semanticToken: string;
  readonly fallbackSrgb: string;
}

export interface GlyphStyle {
  readonly mode: "single" | "split";
  readonly primary: GlyphPaint;
  readonly secondary: GlyphPaint;
  readonly splitAfterDigitCount: number | null;
  readonly rarityId?: string;
}

/** A fill-only SVG path. Multiple contours are kept in one path for even-odd holes. */
export interface GlyphPath {
  readonly id: string;
  readonly contours: readonly GlyphContour[];
  readonly colorRole: GlyphColorRole;
  readonly fillRule: "nonzero" | "evenodd";
  readonly socketIndex?: number;
  readonly digitIndex?: number;
  readonly digit?: number;
  /** Present on stacked higher-base arms. */
  readonly layerIndex?: number;
  /** Octal geometry used by this layer (0...7). */
  readonly layerDigit?: number;
  /** Radix declared for this socket by a mixed-radix glyph. */
  readonly radix?: number;
}

export interface GlyphFrameBounds {
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
  readonly aspectRatio: number;
}

export interface GlyphAccessibility {
  readonly label: string;
  readonly value: string;
}

export interface GlyphModel {
  readonly kind: "octal" | "mixed-radix";
  readonly depth: number;
  readonly normalizedValue: string;
  readonly viewBox: readonly [x: number, y: number, width: number, height: number];
  readonly aspectRatio: number;
  readonly paths: readonly GlyphPath[];
  readonly paints: Readonly<Record<GlyphColorRole, GlyphPaint>>;
  readonly accessibility: GlyphAccessibility;
}

interface OctalGlyphInput {
  readonly value: unknown;
  readonly depth?: unknown;
  readonly accessibilityLabel?: string;
}

/** Color semantics must be explicit until the canonical catalog defines a glyph default. */
export type CreateOctalGlyphOptions = OctalGlyphInput &
  (
    | {
        readonly style: GlyphStyle;
        readonly rarityId?: never;
      }
    | {
        readonly rarityId: unknown;
        readonly style?: never;
      }
  );

interface MixedRadixGlyphInput {
  /** Digits and radices are both supplied most-significant carrier first. */
  readonly digits: readonly number[];
  readonly radices: readonly number[];
  /** Lateral continuation adjustment in glyph geometry units. */
  readonly stackOffsetX?: number;
  /** Outward continuation adjustment in glyph geometry units; negative values pull inward. */
  readonly stackOffsetY?: number;
  readonly accessibilityLabel?: string;
}

/** Color semantics stay explicit while the mixed-radix grammar is experimental. */
export type CreateMixedRadixGlyphOptions = MixedRadixGlyphInput &
  (
    | {
        readonly style: GlyphStyle;
        readonly rarityId?: never;
      }
    | {
        readonly rarityId: unknown;
        readonly style?: never;
      }
  );
