import { canonicalCatalog } from "@exeligmos/domain-catalog";

import type { GlyphPaint, GlyphStyle } from "./types.js";

const colors = canonicalCatalog.semanticTokens.colors;
const commonFamily =
  canonicalCatalog.rarities.families.find((family) => family.id === "common") ??
  canonicalCatalog.rarities.families[0];

if (commonFamily === undefined) {
  throw new Error("The canonical catalog must define a default rarity family.");
}

/** Creates a catalog-backed paint. Unknown tokens fail at the construction boundary. */
export function semanticGlyphPaint(semanticToken: string): GlyphPaint {
  const color = colors.find((candidate) => candidate.id === semanticToken);
  if (color === undefined) {
    throw new RangeError(`Unknown glyph semantic color token: ${semanticToken}`);
  }
  return Object.freeze({
    semanticToken: color.id,
    fallbackSrgb: color.fallbackSrgb,
  });
}

export function semanticGlyphStyle(semanticToken: string): GlyphStyle {
  const paint = semanticGlyphPaint(semanticToken);
  return freezeStyle({
    mode: "single",
    primary: paint,
    secondary: paint,
    splitAfterDigitCount: null,
  });
}

export function splitSemanticGlyphStyle(
  primarySemanticToken: string,
  secondarySemanticToken: string,
  splitAfterDigitCount: number,
): GlyphStyle {
  return freezeStyle({
    mode: "split",
    primary: semanticGlyphPaint(primarySemanticToken),
    secondary: semanticGlyphPaint(secondarySemanticToken),
    splitAfterDigitCount: normalizeSplit(splitAfterDigitCount),
  });
}

/**
 * Resolves aliases and rarity color overrides solely from the canonical catalog.
 * Unknown input degrades to the catalog's common rarity instead of crashing a feed.
 */
export function glyphStyleForRarity(rawRarityId: unknown): GlyphStyle {
  const rarityId = resolveRarityId(rawRarityId);
  const family = canonicalCatalog.rarities.families.find(
    (candidate) => rarityId === candidate.id || rarityId.startsWith(`${candidate.id}-`),
  );
  const resolvedFamily = family ?? commonFamily;
  const override = canonicalCatalog.rarities.colorOverrides.find(
    (candidate) => candidate.rarityId === rarityId,
  );
  const paint = semanticGlyphPaint(
    override?.semanticColorToken ?? resolvedFamily.semanticColorToken,
  );
  return freezeStyle({
    mode: "single",
    primary: paint,
    secondary: paint,
    splitAfterDigitCount: null,
    rarityId: family === undefined ? commonFamily.id : rarityId,
  });
}

export function normalizeGlyphStyle(style: GlyphStyle, depth: number): GlyphStyle {
  const primary = semanticGlyphPaint(style.primary.semanticToken);
  const secondary = semanticGlyphPaint(style.secondary.semanticToken);

  if (style.mode !== "split" || style.splitAfterDigitCount === null) {
    return freezeStyle({
      mode: "single",
      primary,
      secondary: primary,
      splitAfterDigitCount: null,
      ...(style.rarityId === undefined ? {} : { rarityId: style.rarityId }),
    });
  }

  const split = Math.min(normalizeSplit(style.splitAfterDigitCount), depth);
  return freezeStyle({
    mode: "split",
    primary,
    secondary,
    splitAfterDigitCount: split,
    ...(style.rarityId === undefined ? {} : { rarityId: style.rarityId }),
  });
}

function resolveRarityId(value: unknown): string {
  const raw = safeString(value).trim();
  const alias = canonicalCatalog.rarities.aliases.find((candidate) => candidate.alias === raw);
  const candidate = alias?.target ?? raw;
  const digitStrings = new Set(
    canonicalCatalog.rarities.digits
      .map((definition) => definition.digit)
      .filter((digit) => digit > 0)
      .map(String),
  );

  for (const family of canonicalCatalog.rarities.families) {
    if (candidate === family.id) {
      return candidate;
    }
    const prefix = `${family.id}-`;
    if (
      family.id !== commonFamily.id &&
      candidate.startsWith(prefix) &&
      digitStrings.has(candidate.slice(prefix.length))
    ) {
      return candidate;
    }
  }
  return commonFamily.id;
}

function normalizeSplit(value: number): number {
  return Number.isFinite(value) ? Math.max(0, Math.trunc(value)) : 0;
}

function safeString(value: unknown): string {
  try {
    if (typeof value === "string") {
      return value;
    }
    if (typeof value === "number" || typeof value === "bigint" || typeof value === "boolean") {
      return String(value);
    }
    if (typeof value === "symbol") {
      return value.description ?? "";
    }
    return "";
  } catch {
    return "";
  }
}

function freezeStyle(style: GlyphStyle): GlyphStyle {
  return Object.freeze(style);
}
