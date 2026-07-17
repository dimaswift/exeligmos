import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import type { SarosInterval } from "@exeligmos/temporal-core";

import { SarosPulseGlyphPair } from "~/components/saros-pulse-glyph-pair";
import { SarosPulseProvider, useSarosPulseTickAt } from "./saros-pulse-context";

const targetAddress = "1244444444";
const intervalStart = 1_500_000_000;
const instant = intervalStart + Number.parseInt(targetAddress, 8);

describe("SarosPulseProvider", () => {
  it("selects the historical interval for the configured anchor and renders MSB first", () => {
    const intervals = [
      intervalFrom(141, intervalStart - 8 ** 10),
      intervalFrom(141, intervalStart),
      intervalForAddress(142, instant, "7654321012"),
    ];
    const markup = renderToStaticMarkup(
      <SarosPulseProvider anchorSaros={141} intervals={intervals} observedAt={instant}>
        <PulseProbe instantEpochSeconds={instant} />
      </SarosPulseProvider>,
    );

    expect(markup).toContain('data-saros-anchor="141"');
    expect(markup).toContain(`data-pulse-value="${targetAddress}"`);
    expectGlyphOrder(markup, "12444", "44444");
  });

  it("allows a record author anchor to override the signed-in user's anchor", () => {
    const authorAddress = "7654321012";
    const intervals = [
      intervalFrom(141, intervalStart),
      intervalForAddress(142, instant, authorAddress),
    ];
    const markup = renderToStaticMarkup(
      <SarosPulseProvider anchorSaros={141} intervals={intervals} observedAt={instant}>
        <PulseProbe anchorSaros={142} instantEpochSeconds={instant} />
      </SarosPulseProvider>,
    );

    expect(markup).toContain('data-saros-anchor="142"');
    expect(markup).toContain(`data-pulse-value="${authorAddress}"`);
    expectGlyphOrder(markup, "76543", "21012");
  });
});

function PulseProbe({
  anchorSaros,
  instantEpochSeconds,
}: {
  readonly anchorSaros?: number;
  readonly instantEpochSeconds: number;
}) {
  const reading = useSarosPulseTickAt(instantEpochSeconds, anchorSaros);
  return reading === undefined ? null : <SarosPulseGlyphPair reading={reading} />;
}

function intervalForAddress(saros: number, recordInstant: number, address: string): SarosInterval {
  return intervalFrom(saros, recordInstant - Number.parseInt(address, 8) - 0.25);
}

function intervalFrom(saros: number, previousEpochSeconds: number): SarosInterval {
  return {
    saros,
    previous: {
      epochSeconds: previousEpochSeconds,
      typeCode: 13,
      sequence: 1,
      seriesCount: 2,
    },
    next: {
      epochSeconds: previousEpochSeconds + 8 ** 10,
      typeCode: 13,
      sequence: 2,
      seriesCount: 2,
    },
  };
}

function expectGlyphOrder(markup: string, mostSignificant: string, leastSignificant: string) {
  const msbIndex = markup.indexOf(`data-glyph-value="${mostSignificant}"`);
  const lsbIndex = markup.indexOf(`data-glyph-value="${leastSignificant}"`);
  expect(msbIndex).toBeGreaterThanOrEqual(0);
  expect(lsbIndex).toBeGreaterThan(msbIndex);
}
