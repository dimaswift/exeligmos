import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import { SAROS_REALTIME_PHASE_DEPTH, type SarosInterval } from "@exeligmos/temporal-core";

import { RealtimeSarosWindow } from "./realtime-saros-window";

describe("RealtimeSarosWindow", () => {
  it("renders the persistent controls, ten-digit phase, and default Mili waveform", () => {
    const duration = 8 ** SAROS_REALTIME_PHASE_DEPTH + 0.5;
    const interval: SarosInterval = {
      saros: 141,
      previous: { epochSeconds: 0, typeCode: 13, sequence: 1, seriesCount: 2 },
      next: { epochSeconds: duration, typeCode: 13, sequence: 2, seriesCount: 2 },
    };
    const markup = renderToStaticMarkup(
      <RealtimeSarosWindow intervals={[interval]} observedAt={duration / 2} />,
    );

    expect(markup).toContain('aria-label="Realtime Saros sliding window"');
    expect(markup).toContain('aria-label="Temporal period"');
    expect(markup).toContain("Lowest rarity");
    expect(markup).toContain('aria-label="Expand Saros window"');
    expect(markup).toContain('aria-label="Mili realtime waveform"');
    expect(markup).toMatch(/Incoming ten-digit octal phase [0-7]{10}/);
    expect(markup.match(/<li /g)).toHaveLength(5);

    const sequence = ["Upcoming +2", "Upcoming +1", "Current", "Past −1", "Past −2"];
    const sequenceOffsets = sequence.map((label) => markup.indexOf(label));
    expect(sequenceOffsets.every((offset) => offset >= 0)).toBe(true);
    expect(sequenceOffsets).toEqual([...sequenceOffsets].sort((left, right) => left - right));
    expect(markup.match(/aria-current="time"/g)).toHaveLength(1);
    expect(markup).toMatch(/\bago\b/);
    expect(markup).toMatch(/\bin [\d.]+ (?:s|min|h|d)\b/);
  });
});
