import { useId, type CSSProperties, type SVGProps } from "react";

import {
  pathData,
  type GlyphColorRole,
  type GlyphModel,
  type GlyphPaint,
} from "@exeligmos/glyph-core";

export type GlyphColorResolver = (
  role: GlyphColorRole,
  paint: GlyphPaint,
  model: GlyphModel,
) => string;

type ManagedSvgProps =
  | "aria-hidden"
  | "aria-label"
  | "aria-labelledby"
  | "aria-describedby"
  | "children"
  | "height"
  | "role"
  | "viewBox"
  | "width";

export interface GlyphRendererProps extends Omit<SVGProps<SVGSVGElement>, ManagedSvgProps> {
  readonly model: GlyphModel;
  /** Sets both dimensions unless width or height is supplied independently. */
  readonly size?: number | string;
  readonly width?: number | string;
  readonly height?: number | string;
  /** Replaces the catalog label while retaining the normalized value as its description. */
  readonly accessibilityLabel?: string;
  /** Removes the accessible name, description, and role for redundant visual glyphs. */
  readonly decorative?: boolean;
  readonly colorForRole?: GlyphColorResolver;
}

/**
 * Fill-only, server-renderable SVG adapter for immutable glyph-core models.
 * Semantic paints remain overrideable through --glyph-primary/secondary or token variables.
 */
export function GlyphRenderer({
  model,
  size = "1em",
  width,
  height,
  accessibilityLabel,
  decorative = false,
  colorForRole = defaultColorForRole,
  preserveAspectRatio = "xMidYMid meet",
  focusable = false,
  ...svgProps
}: GlyphRendererProps) {
  const reactId = useId();
  const titleId = `${reactId}-glyph-title`;
  const descriptionId = `${reactId}-glyph-value`;
  const normalizedSize = normalizeDimension(size, "1em");
  const resolvedLabel = nonBlank(accessibilityLabel) ?? model.accessibility.label;

  return (
    <svg
      {...svgProps}
      aria-describedby={decorative ? undefined : descriptionId}
      aria-hidden={decorative ? true : undefined}
      aria-labelledby={decorative ? undefined : titleId}
      data-glyph-depth={model.depth}
      data-glyph-value={model.normalizedValue}
      focusable={focusable}
      height={normalizeDimension(height, normalizedSize)}
      preserveAspectRatio={preserveAspectRatio}
      role={decorative ? undefined : "img"}
      viewBox={model.viewBox.join(" ")}
      width={normalizeDimension(width, normalizedSize)}
      xmlns="http://www.w3.org/2000/svg"
    >
      {decorative ? null : <title id={titleId}>{resolvedLabel}</title>}
      {decorative ? null : <desc id={descriptionId}>{model.accessibility.value}</desc>}
      {model.paths.map((path) => (
        <path
          clipRule={path.fillRule}
          d={pathData(path)}
          data-color-role={path.colorRole}
          data-digit={path.digit}
          data-digit-index={path.digitIndex}
          data-glyph-part={path.id}
          data-socket-index={path.socketIndex}
          fill={colorForRole(path.colorRole, model.paints[path.colorRole], model)}
          fillRule={path.fillRule}
          key={path.id}
        />
      ))}
    </svg>
  );
}

export function defaultGlyphColor(role: GlyphColorRole, paint: GlyphPaint): string {
  const semanticVariable = `--exeligmos-${paint.semanticToken.replaceAll(".", "-")}`;
  return `var(--glyph-${role}, var(${semanticVariable}, ${paint.fallbackSrgb}))`;
}

function defaultColorForRole(role: GlyphColorRole, paint: GlyphPaint): string {
  return defaultGlyphColor(role, paint);
}

function normalizeDimension(
  value: number | string | undefined,
  fallback: number | string,
): number | string {
  if (typeof value === "number") {
    return Number.isFinite(value) && value > 0 ? value : fallback;
  }
  if (typeof value === "string") {
    return value.trim() === "" ? fallback : value;
  }
  return fallback;
}

function nonBlank(value: string | undefined): string | null {
  if (value === undefined || value.trim() === "") {
    return null;
  }
  return value.trim();
}

// Keep the imported React style type visible to consumers extending CSS custom properties.
export type GlyphRendererStyle = CSSProperties & Record<`--${string}`, string | number | undefined>;
