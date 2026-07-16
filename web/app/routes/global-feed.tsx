import type { Route } from "./+types/global-feed";
import {
  EventLane,
  FeedContractNote,
  FeedWorkspace,
  RecordLane,
  ResourceLaneGrid,
} from "~/features/activity-feed";
import {
  FeedQueryError,
  feedPageLinks,
  readFeedCursorQuery,
} from "~/features/activity-stream/feed-query.server";
import {
  publicEventCursor,
  publicRecordCursor,
  readPublicEvents,
  readPublicRecords,
  recordPageLimit,
  standardPageLimit,
} from "~/features/activity-stream/snapshots.server";
import { throwRouteError } from "~/lib/route-errors.server";

export const meta: Route.MetaFunction = () => [{ title: "Global feed · Exeligmos" }];

export async function loader({ request, url }: Route.LoaderArgs) {
  try {
    const query = readFeedCursorQuery(request);
    const [records, events] = await Promise.all([
      readPublicRecords({
        cursor:
          query.recordsCursor === undefined ? undefined : publicRecordCursor(query.recordsCursor),
        limit: recordPageLimit(12),
        signal: request.signal,
      }),
      readPublicEvents({
        cursor:
          query.eventsCursor === undefined ? undefined : publicEventCursor(query.eventsCursor),
        limit: standardPageLimit(12),
        signal: request.signal,
      }),
    ]);
    const eventLinks = feedPageLinks(
      url,
      "eventsCursor",
      events.hasMore ? events.nextCursor : undefined,
    );
    const recordLinks = feedPageLinks(
      url,
      "recordsCursor",
      records.hasMore ? records.nextCursor : undefined,
    );
    return {
      events,
      eventsNextHref: eventLinks.nextHref,
      eventsPreviousHref: eventLinks.previousHref,
      records,
      recordsNextHref: recordLinks.nextHref,
      recordsPreviousHref: recordLinks.previousHref,
    };
  } catch (error) {
    if (error instanceof FeedQueryError || error instanceof RangeError) {
      throw new Response(error.message, { status: 400, statusText: "Bad Request" });
    }
    return throwRouteError(error, request, { clearInvalidAuth: true });
  }
}

export default function GlobalFeed({ loaderData }: Route.ComponentProps) {
  return (
    <FeedWorkspace
      actions={<a href="/explore">Open public explorer</a>}
      eyebrow="Network activity"
      summary="Current public records and events across the network, ordered by when they started rather than when they were edited or synchronized."
      title="Global feed"
    >
      <ResourceLaneGrid>
        <RecordLane
          description="Newest record start times across all public accounts."
          emptyMessage="No public records are available yet."
          items={loaderData.records.data.map((record) => ({
            actorHref: `/u/${encodeURIComponent(record.author.login)}`,
            href: `/r/${encodeURIComponent(record.id)}`,
            record,
          }))}
          nextHref={loaderData.recordsNextHref ?? undefined}
          previousHref={loaderData.recordsPreviousHref ?? undefined}
          title="Global records"
        />
        <EventLane
          description="Newest public event start times across the network."
          emptyMessage="No public events are available yet."
          items={loaderData.events.data.map((event) => ({
            actorHref: `/u/${encodeURIComponent(event.author.login)}`,
            event,
          }))}
          nextHref={loaderData.eventsNextHref ?? undefined}
          previousHref={loaderData.eventsPreviousHref ?? undefined}
          title="Global events"
        />
      </ResourceLaneGrid>
      <FeedContractNote>
        Realtime commands can refresh these projections, but they never determine card position. A
        retroactive record stays at its actual start time even when it is uploaded or edited today.
      </FeedContractNote>
    </FeedWorkspace>
  );
}
