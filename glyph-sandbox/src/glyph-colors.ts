import type { ColorMode } from "./types";

export const DEFAULT_INK_COLOR = "#d9ff57";
export const DEFAULT_CANVAS_COLOR = "#17201c";
export const DEFAULT_COLOR_PALETTE: readonly string[] = Object.freeze([
  "#d9ff57",
  "#7ce7da",
  "#b8a0ff",
  "#ff9a78",
  "#f8d065",
  "#86a9ff",
]);

export interface GlyphColorSettings {
  readonly colorMode: ColorMode;
  readonly inkColor: string;
  readonly paletteColors: readonly string[];
}

export function normalizeHexColor(value: unknown, fallback: string): string {
  return typeof value === "string" && /^#[0-9a-f]{6}$/iu.test(value) ? value.toLowerCase() : fallback;
}

export function normalizeColorPalette(value: unknown): readonly string[] {
  const source = Array.isArray(value) ? value : [];
  return Object.freeze(DEFAULT_COLOR_PALETTE.map((fallback, index) => (
    normalizeHexColor(source[index], fallback)
  )));
}

export function glyphColor(settings: GlyphColorSettings, index: number, digit: number): string {
  const palette = settings.paletteColors.length > 0 ? settings.paletteColors : DEFAULT_COLOR_PALETTE;
  if (settings.colorMode === "position") {
    return palette[positiveModulo(index, palette.length)] ?? DEFAULT_INK_COLOR;
  }
  if (settings.colorMode === "digit") {
    return palette[positiveModulo(digit, palette.length)] ?? DEFAULT_INK_COLOR;
  }
  return normalizeHexColor(settings.inkColor, DEFAULT_INK_COLOR);
}

export function readableTextColor(background: string): string {
  const normalized = normalizeHexColor(background, DEFAULT_CANVAS_COLOR);
  const red = Number.parseInt(normalized.slice(1, 3), 16) / 255;
  const green = Number.parseInt(normalized.slice(3, 5), 16) / 255;
  const blue = Number.parseInt(normalized.slice(5, 7), 16) / 255;
  const luminance = 0.2126 * linearChannel(red) + 0.7152 * linearChannel(green) + 0.0722 * linearChannel(blue);
  return luminance > 0.42 ? "#17201c" : "#f5f6ef";
}

function positiveModulo(value: number, divisor: number): number {
  return ((Math.trunc(value) % divisor) + divisor) % divisor;
}

function linearChannel(value: number): number {
  return value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4;
}
