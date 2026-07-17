import { useEffect, useMemo, useState } from "react";

import { createOctalGlyph } from "@exeligmos/glyph-core";
import {
  DEFAULT_SAROS_PULSE_ANCHOR,
  sarosPulseAnchorInterval,
  sarosPulseTickReading,
  type SarosInterval,
  type SarosPulseTickReading,
} from "@exeligmos/temporal-core";
import { GlyphRenderer } from "@exeligmos/ui";

import styles from "./saros-pulse-glyph-pair.module.css";

export interface SarosPulseGlyphPairProps {
  readonly reading: SarosPulseTickReading;
  readonly size?: number | string;
  readonly className?: string;
  readonly decorative?: boolean;
}

export interface LiveSarosPulseClockProps extends Omit<SarosPulseGlyphPairProps, "reading"> {
  readonly intervals: readonly SarosInterval[];
  readonly observedAt: number;
  readonly anchorSaros?: number;
}

/** Render the canonical two-glyph Saros pulse in explicit MSB-to-LSB order. */
export function SarosPulseGlyphPair({
  reading,
  size = "1em",
  className,
  decorative = false,
}: SarosPulseGlyphPairProps) {
  const glyphs = useMemo(
    () => [
      createOctalGlyph({
        value: reading.mostSignificantGlyphAddress,
        depth: 5,
        rarityId: "common",
        accessibilityLabel: "Most-significant Saros pulse phase",
      }),
      createOctalGlyph({
        value: reading.leastSignificantGlyphAddress,
        depth: 5,
        rarityId: "common",
        accessibilityLabel: "Least-significant Saros pulse phase",
      }),
    ],
    [reading.leastSignificantGlyphAddress, reading.mostSignificantGlyphAddress],
  );
  const label = `Saros ${reading.saros} pulse ${reading.mostSignificantGlyphAddress} ${reading.leastSignificantGlyphAddress}`;

  return (
    <span
      aria-hidden={decorative ? true : undefined}
      aria-label={decorative ? undefined : label}
      className={`${styles.pair}${className === undefined ? "" : ` ${className}`}`}
      data-imminent-unit={reading.imminentUnit ?? "none"}
      data-pulse-color={reading.color}
      data-pulse-value={reading.octalAddress}
      data-saros-anchor={reading.saros}
      role={decorative ? undefined : "img"}
    >
      {glyphs.map((glyph, index) => (
        <GlyphRenderer
          className={styles.glyph}
          decorative
          key={`${index}:${glyph.normalizedValue}`}
          model={glyph}
          size={size}
        />
      ))}
    </span>
  );
}

/**
 * A hydrated clock for shell chrome. Fixed-time record views should call
 * `sarosPulseTickReading` and render `SarosPulseGlyphPair` directly.
 */
export function LiveSarosPulseClock({
  intervals,
  observedAt,
  anchorSaros = DEFAULT_SAROS_PULSE_ANCHOR,
  ...pairProps
}: LiveSarosPulseClockProps) {
  const [instant, setInstant] = useState(observedAt);
  const interval = useMemo(
    () => sarosPulseAnchorInterval(intervals, instant, anchorSaros),
    [anchorSaros, instant, intervals],
  );
  const reading = useMemo(
    () => (interval === undefined ? undefined : sarosPulseTickReading(interval, instant)),
    [instant, interval],
  );

  useEffect(() => {
    setInstant(observedAt);
  }, [observedAt]);

  useEffect(() => {
    if (reading === undefined) return;
    const delay = clamp(
      (reading.nextTickEpochSeconds - Date.now() / 1_000) * 1_000 + 18,
      24,
      1_000,
    );
    const timer = window.setTimeout(() => setInstant(Date.now() / 1_000), delay);
    return () => window.clearTimeout(timer);
  }, [reading]);

  return reading === undefined ? null : <SarosPulseGlyphPair {...pairProps} reading={reading} />;
}

function clamp(value: number, minimum: number, maximum: number): number {
  return Math.min(Math.max(value, minimum), maximum);
}
