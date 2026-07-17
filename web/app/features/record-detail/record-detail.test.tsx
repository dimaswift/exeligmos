import { renderToStaticMarkup } from "react-dom/server";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

import type { SarosInterval } from "@exeligmos/temporal-core";

import { SarosPulseProvider } from "~/features/temporal/saros-pulse-context";
import { LocalTimestamp } from "../activity-feed/activity-feed";
import type { ActivityRecord } from "../activity-feed/model";

import { RecordDetailView } from "./record-detail";

const originalTimezone = process.env.TZ;
const occurredAt = "2026-07-15T12:30:00Z";

const record = {
  id: "Local",
  userId: "10000000-0000-4000-8000-000000000001",
  author: {
    id: "10000000-0000-4000-8000-000000000001",
    login: "sun",
    displayName: "The Sun",
    sarosAnchor: 142,
  },
  visibility: "public",
  occurredAt,
  payload: { text: "A local-time record", emoji: "☀️" },
  tagIds: [],
  tags: [],
  media: [],
  metadata: {},
  source: { kind: "client", provider: "record-detail-test" },
  references: [],
  revision: 1,
  createdAt: "2026-07-15T12:31:00Z",
  updatedAt: "2026-07-15T12:31:00Z",
} as ActivityRecord;

describe("record detail timestamps", () => {
  beforeAll(() => {
    process.env.TZ = "America/New_York";
  });

  afterAll(() => {
    process.env.TZ = originalTimezone;
  });

  it("renders the record date in the viewer's local time instead of UTC", () => {
    const markup = renderToStaticMarkup(<RecordDetailView backHref="/feed" record={record} />);

    expect(markup).toContain('dateTime="2026-07-15T12:30:00Z"');
    expect(markup).toContain("Jul 15, 2026, 8:30:00 AM");
    expect(markup).not.toContain("12:30:00 UTC");
  });

  it("marks local output as hydration-safe", () => {
    const timestamp = LocalTimestamp({ value: occurredAt });

    expect(timestamp.props).toMatchObject({
      dateTime: occurredAt,
      suppressHydrationWarning: true,
    });
  });

  it("renders the author's two-glyph Saros pulse in the detail header", () => {
    const address = "7654321012";
    const instant = Date.parse(occurredAt) / 1_000;
    const markup = renderToStaticMarkup(
      <SarosPulseProvider
        anchorSaros={141}
        intervals={[
          intervalForAddress(141, instant, "1244444444"),
          intervalForAddress(142, instant, address),
        ]}
        observedAt={instant}
      >
        <RecordDetailView backHref="/feed" record={record} />
      </SarosPulseProvider>,
    );
    const pulse = pulsePairMarkup(markup, address);

    expect(pulse).toContain('data-saros-anchor="142"');
    expectGlyphOrder(pulse, "76543", "21012");
  });
});

function intervalForAddress(
  saros: number,
  instantEpochSeconds: number,
  address: string,
): SarosInterval {
  const previousEpochSeconds = instantEpochSeconds - Number.parseInt(address, 8) - 0.25;
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

function pulsePairMarkup(markup: string, address: string): string {
  const markerIndex = markup.indexOf(`data-pulse-value="${address}"`);
  expect(markerIndex).toBeGreaterThanOrEqual(0);
  const start = markup.lastIndexOf("<span", markerIndex);
  const end = markup.indexOf("</span>", markerIndex);
  expect(start).toBeGreaterThanOrEqual(0);
  expect(end).toBeGreaterThan(markerIndex);
  return markup.slice(start, end + "</span>".length);
}

function expectGlyphOrder(markup: string, mostSignificant: string, leastSignificant: string) {
  const msbIndex = markup.indexOf(`data-glyph-value="${mostSignificant}"`);
  const lsbIndex = markup.indexOf(`data-glyph-value="${leastSignificant}"`);
  expect(msbIndex).toBeGreaterThanOrEqual(0);
  expect(lsbIndex).toBeGreaterThan(msbIndex);
}
