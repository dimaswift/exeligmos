import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import { sarosPulseTickReading, type SarosInterval } from "@exeligmos/temporal-core";

import { LiveSarosPulseClock, SarosPulseGlyphPair } from "./saros-pulse-glyph-pair";

const interval: SarosInterval = {
  saros: 141,
  previous: { epochSeconds: 0, typeCode: 13, sequence: 1, seriesCount: 2 },
  next: { epochSeconds: 8 ** 10, typeCode: 13, sequence: 2, seriesCount: 2 },
};

describe("SarosPulseGlyphPair", () => {
  it("renders the two five-digit glyphs in MSB-first order with one accessible name", () => {
    const reading = sarosPulseTickReading(interval, Number.parseInt("1244444444", 8));
    const markup = renderToStaticMarkup(<SarosPulseGlyphPair reading={reading} size={32} />);

    expect(markup).toContain('aria-label="Saros 141 pulse 12444 44444"');
    expect(markup).toContain('data-pulse-value="1244444444"');
    expect(markup.indexOf('data-glyph-value="12444"')).toBeLessThan(
      markup.indexOf('data-glyph-value="44444"'),
    );
    expect(markup.match(/data-glyph-depth="5"/g)).toHaveLength(2);
  });

  it("exposes the urgency color as a stable presentation attribute", () => {
    const reading = sarosPulseTickReading(interval, 8 ** 4 - 1);
    const markup = renderToStaticMarkup(<SarosPulseGlyphPair decorative reading={reading} />);

    expect(markup).toContain('data-pulse-color="blue"');
    expect(markup).toContain('data-imminent-unit="kilo"');
    expect(markup).toContain('aria-hidden="true"');
  });

  it("uses Saros 141 by default for the live shell clock", () => {
    const markup = renderToStaticMarkup(
      <LiveSarosPulseClock
        intervals={[{ ...interval, saros: 140 }, interval]}
        observedAt={1_000}
      />,
    );

    expect(markup).toContain('data-saros-anchor="141"');
  });
});
