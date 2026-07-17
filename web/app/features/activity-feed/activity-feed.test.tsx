import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import type { ApiSchemas } from "@exeligmos/api-client";
import type { SarosInterval } from "@exeligmos/temporal-core";

import { SarosPulseProvider } from "~/features/temporal/saros-pulse-context";

import {
  ActivityChangeNotice,
  ActivityFeedEmpty,
  ActivityFeedNotice,
  CursorPagination,
  EventActivityCard,
  EventLane,
  HydratedActivityItem,
  PublicProfileHeader,
  RecordActivityCard,
  RecordLane,
} from "./activity-feed";
import type { HydratedActivityRow } from "./model";

const actor = {
  id: "10000000-0000-4000-8000-000000000001",
  login: "sun",
  displayName: "The Sun",
  sarosAnchor: 141,
} satisfies ApiSchemas["PublicUserSummary"];

const reference = {
  relation: "observed-by",
  targetType: "user",
  targetUserId: "20000000-0000-4000-8000-000000000002",
  targetId: "20000000-0000-4000-8000-000000000002",
} satisfies ApiSchemas["ResourceReference"];

const record = {
  id: "30000000-0000-4000-8000-000000000003",
  userId: actor.id,
  author: actor,
  visibility: "public",
  occurredAt: "2026-07-15T08:30:00-04:00",
  endedAt: "2026-07-15T12:31:00Z",
  payload: { text: "Solar flare detected", emoji: "☀️" },
  tagIds: ["40000000-0000-4000-8000-000000000004"],
  tags: [
    {
      id: "40000000-0000-4000-8000-000000000004",
      name: "solar",
      emoji: "☀️",
    },
  ],
  media: [
    {
      id: "50000000-0000-4000-8000-000000000005",
      fileName: "flare.jpg",
      contentType: "image/jpeg",
      byteLength: 128,
      sha256: "a".repeat(64),
      createdAt: "2026-07-15T12:32:00Z",
      publicContentUrl: "/v1/public/media/50000000-0000-4000-8000-000000000005",
    },
  ],
  metadata: { strength: "X1", provider: "NOAA" },
  source: {
    kind: "agent",
    provider: "space-weather-agent",
    externalId: "flare-42",
    url: "https://example.test/flares/42",
  },
  references: [reference],
  revision: 2,
  createdAt: "2026-07-15T12:32:00Z",
  updatedAt: "2026-07-15T12:33:00Z",
} satisfies ApiSchemas["PublicRecordProjection"];

const event = {
  id: "60000000-0000-4000-8000-000000000006",
  userId: actor.id,
  author: actor,
  visibility: "public",
  startsAt: "2026-07-15T13:00:00Z",
  label: "Peak radiation",
  type: 0,
  metadata: { instrument: "GOES" },
  references: [reference],
  revision: 1,
  createdAt: "2026-07-15T13:01:00Z",
  updatedAt: "2026-07-15T13:01:00Z",
} satisfies ApiSchemas["PublicEventProjection"];

const recordActivity = {
  sequence: 41,
  publishedAt: "2026-07-15T12:34:00Z",
  actor,
  resourceType: "record",
  resourceId: record.id,
  operation: "upsert",
  revision: 2,
  resourceUrl: `/v1/public/records/${record.id}`,
} satisfies ApiSchemas["PublicActivityItem"] & { resourceType: "record" };

describe("activity presentation", () => {
  it("renders a compact public record without verbose source or metadata", () => {
    const markup = renderToStaticMarkup(
      <RecordActivityCard
        activity={recordActivity}
        actorHref="/u/sun"
        href={`/records/${record.id}`}
        record={record}
        referenceHref={(item) => `/references/${item.targetType}/${item.targetId}`}
      />,
    );

    expect(markup).toContain('data-activity-kind="record"');
    expect(markup).toContain('data-activity-sequence="41"');
    expect(markup).toContain('data-activity-operation="upsert"');
    expect(markup).toContain("Solar flare detected");
    expect(markup).toContain('dateTime="2026-07-15T08:30:00-04:00"');
    expect(markup).not.toContain("The Sun");
    expect(markup).toContain("@sun");
    expect(markup).toContain("observed-by");
    expect(markup).toContain("solar");
    expect(markup).not.toContain("Open record");
    expect(markup).toContain("☀️");
    expect(markup).toContain("/media/50000000-0000-4000-8000-000000000005");
    expect(markup).not.toContain("space-weather-agent");
    expect(markup).not.toContain("flare-42");
    expect(markup).not.toContain("Metadata · 2 fields");
    expect(markup).not.toContain("<svg");
  });

  it("renders canonical temporal names and Saros glyphs from journal context", () => {
    const journalRecord = {
      ...record,
      payload: {
        emoji: "🥳",
        text: "A journal moment",
        context: {
          unixTimestamp: 1_752_580_000,
          energyPercent: 0.99,
          closestSarosPhase: {
            saros: 131,
            octalAddress: "1234567",
            harmonicDepth: 7,
            rarityRawValue: "epic-7",
          },
          spikes: [
            {
              saros: 121,
              unixTimestamp: 1_752_579_000,
              octalAddress: "1211111",
              harmonicDepth: 7,
              rarityRawValue: "rare-7",
            },
            {
              saros: 131,
              unixTimestamp: 1_752_580_001,
              octalAddress: "1234567",
              harmonicDepth: 7,
              rarityRawValue: "epic-7",
            },
          ],
        },
      },
    } satisfies ApiSchemas["PublicRecordProjection"];

    const markup = renderToStaticMarkup(<RecordActivityCard record={journalRecord} />);
    expect(markup).toContain("Omega Duplex");
    expect(markup).toContain("creeping peak");
    expect(markup).toContain("🥳");
    expect(markup).toContain(">121<");
    expect(markup).toContain(">131<");
    expect(markup).toContain("<svg");
    expect(markup).toContain('data-glyph-depth="5"');
    expect(markup).toContain('data-glyph-value="12345"');
    expect(markup).not.toContain('data-glyph-value="34567"');
    expect(markup.match(/A journal moment/g)).toHaveLength(1);
  });

  it("renders the record author's two-glyph Saros pulse in the card header", () => {
    const address = "1244444444";
    const authorAnchor = 142;
    const recordInstant = Date.parse(record.occurredAt) / 1_000;
    const anchoredRecord = {
      ...record,
      author: { ...actor, sarosAnchor: authorAnchor },
    } satisfies ApiSchemas["PublicRecordProjection"];
    const markup = renderToStaticMarkup(
      <SarosPulseProvider
        anchorSaros={141}
        intervals={[
          intervalForAddress(141, recordInstant, "7654321012"),
          intervalForAddress(authorAnchor, recordInstant, address),
        ]}
        observedAt={recordInstant}
      >
        <RecordActivityCard record={anchoredRecord} />
      </SarosPulseProvider>,
    );
    const pulse = pulsePairMarkup(markup, address);

    expect(pulse).toContain(`data-saros-anchor="${authorAnchor}"`);
    expectGlyphOrder(pulse, "12444", "44444");
  });

  it("keeps encrypted records opaque while retaining owner-safe metadata", () => {
    const privateRecord = {
      id: "Prv07",
      originId: "70000000-0000-4000-8000-000000000007",
      userId: actor.id,
      deviceId: "80000000-0000-4000-8000-000000000008",
      visibility: "private",
      revision: 3,
      createdAt: "2026-07-15T14:00:00Z",
      updatedAt: "2026-07-15T14:01:00Z",
      references: [reference],
      encryption: {
        algorithm: "A256GCM",
        cryptoVersion: 1,
        keyVersion: 1,
        nonce: "private-nonce",
        ciphertext: "private-ciphertext",
        contentType: "application/vnd.exeligmos.record+json",
      },
      media: [],
    } satisfies ApiSchemas["PrivateRecord"];
    const markup = renderToStaticMarkup(
      <RecordActivityCard actor={actor} record={privateRecord} />,
    );

    expect(markup).toContain("Private record");
    expect(markup).toContain("Client-encrypted content");
    expect(markup).toContain("observed-by");
    expect(markup).not.toContain("private-ciphertext");
    expect(markup).not.toContain("private-nonce");
  });

  it("renders event identity from the canonical numeric type catalog", () => {
    const markup = renderToStaticMarkup(<EventActivityCard event={event} />);
    expect(markup).toContain('data-activity-kind="event"');
    expect(markup).toContain('data-event-type="0"');
    expect(markup).toContain("Peak radiation");
    expect(markup).toContain("TYPE 0");
    expect(markup).toContain("Event");
    expect(markup).toContain("core");
    expect(markup).toContain("Metadata · 1 fields");
  });

  it("renders hydrated upserts richly and tombstones as identifier-only history", () => {
    const upsertMarkup = renderToStaticMarkup(
      <HydratedActivityItem
        actorHref="/u/sun"
        resourceHref={`/records/${record.id}`}
        row={{ kind: "record", activity: recordActivity, projection: record }}
      />,
    );
    expect(upsertMarkup).toContain("Solar flare detected");

    const deletedActivity = {
      ...recordActivity,
      sequence: 42,
      operation: "delete",
      revision: 3,
    } satisfies ApiSchemas["PublicActivityItem"] & { resourceType: "record" };
    const row = { kind: "record", activity: deletedActivity } satisfies HydratedActivityRow;
    const tombstoneMarkup = renderToStaticMarkup(
      <ActivityChangeNotice resourceHref="/should-not-link" row={row} />,
    );
    expect(tombstoneMarkup).toContain("Public record deleted");
    expect(tombstoneMarkup).toContain("Sequence 42");
    expect(tombstoneMarkup).toContain(recordActivity.resourceUrl);
    expect(tombstoneMarkup).not.toContain("Open record");
  });

  it("renders user lifecycle and missing projection states without fabricated resources", () => {
    const userRow = {
      kind: "user",
      activity: {
        ...recordActivity,
        resourceType: "user",
        resourceId: actor.id,
        resourceUrl: "/v1/public/users/sun",
      },
    } satisfies HydratedActivityRow;
    const userMarkup = renderToStaticMarkup(<HydratedActivityItem row={userRow} />);
    expect(userMarkup).toContain("Public profile published or restored");

    const missingMarkup = renderToStaticMarkup(
      <HydratedActivityItem row={{ kind: "record", activity: recordActivity }} />,
    );
    expect(missingMarkup).toContain("Record update");
    expect(missingMarkup).toContain("public projection was unavailable");
    expect(missingMarkup).not.toContain("Solar flare detected");
  });

  it("renders public profile counts and deterministic membership time", () => {
    const markup = renderToStaticMarkup(
      <PublicProfileHeader
        actions={<a href="/subscribe">Subscribe</a>}
        profile={{
          ...actor,
          createdAt: "2020-02-03T04:05:06Z",
          publicRecordCount: 1234,
          publicEventCount: 56,
          followerCount: 789,
        }}
      />,
    );
    expect(markup).toContain("Public actor");
    expect(markup).toContain("@sun");
    expect(markup).toContain("1,234");
    expect(markup).toContain("03 Feb 2020 · 04:05:06 UTC");
    expect(markup).toContain("Subscribe");
  });

  it("keeps record and event lanes independently paginated", () => {
    const markup = renderToStaticMarkup(
      <div>
        <RecordLane
          items={[{ record }]}
          nextHref="?recordCursor=next"
          previousHref="?recordCursor=previous"
        />
        <EventLane
          items={[{ event }]}
          nextHref="?eventCursor=next"
          previousHref="?eventCursor=previous"
        />
      </div>,
    );
    expect(markup).toContain("Record snapshot");
    expect(markup).toContain("Event snapshot");
    expect(markup).toContain("?recordCursor=next");
    expect(markup).toContain("?eventCursor=next");
    expect(markup).toContain("?recordCursor=previous");
    expect(markup).toContain("?eventCursor=previous");
    expect(markup.match(/rel="prev"/g)).toHaveLength(2);
    expect(markup).toContain("Newer records");
    expect(markup).toContain("Newer events");
    const labelledBy = [...markup.matchAll(/aria-labelledby="([^"]+-lane-title)"/g)].map(
      (match) => match[1],
    );
    expect(new Set(labelledBy).size).toBe(2);
  });

  it("renders accessible empty, error-neutral, and route-owned cursor states", () => {
    const markup = renderToStaticMarkup(
      <div>
        <ActivityFeedEmpty message="Subscribe to actors to build history." />
        <ActivityFeedNotice
          message="The server did not return this page."
          title="History unavailable"
          tone="error"
        />
        <CursorPagination nextHref="?cursor=opaque" />
      </div>,
    );
    expect(markup).toContain("No activity yet");
    expect(markup).toContain('role="alert"');
    expect(markup).toContain('rel="next"');
    expect(markup).toContain("Later changes");
    expect(markup).toContain("Activity history snapshot");
    expect(markup).toContain('aria-disabled="true"');
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
