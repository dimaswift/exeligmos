import type { Route } from "./+types/public-feed";
import {
  EventLane,
  FeedContractNote,
  FeedWorkspace,
  RecordLane,
  ResourceLaneGrid,
} from "~/features/activity-feed";
import {
  FeedQueryError,
  feedCursorHref,
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

export const meta: Route.MetaFunction = () => [
  { title: "Explore public activity · Exeligmos" },
  {
    name: "description",
    content: "Current public records and events from the Exeligmos network.",
  },
];

export async function loader({ request, url }: Route.LoaderArgs) {
  try {
    const query = readFeedCursorQuery(request);
    const [records, events] = await Promise.all([
      readPublicRecords({
        cursor:
          query.recordsCursor === undefined ? undefined : publicRecordCursor(query.recordsCursor),
        limit: recordPageLimit(8),
        signal: request.signal,
      }),
      readPublicEvents({
        cursor:
          query.eventsCursor === undefined ? undefined : publicEventCursor(query.eventsCursor),
        limit: standardPageLimit(8),
        signal: request.signal,
      }),
    ]);
    return {
      events,
      eventsNextHref:
        events.hasMore && events.nextCursor !== undefined
          ? feedCursorHref(url, "eventsCursor", events.nextCursor)
          : null,
      records,
      recordsNextHref:
        records.hasMore && records.nextCursor !== undefined
          ? feedCursorHref(url, "recordsCursor", records.nextCursor)
          : null,
    };
  } catch (error) {
    if (error instanceof FeedQueryError || error instanceof RangeError) {
      throw new Response(error.message, { status: 400, statusText: "Bad Request" });
    }
    return throwRouteError(error, request);
  }
}

export default function PublicFeed({ loaderData }: Route.ComponentProps) {
  return (
    <FeedWorkspace
      actions={<a href="/login?returnTo=%2Ffeed%2Fglobal">Open analytics workspace</a>}
      eyebrow="Public network"
      summary="Inspect current public record and event projections across accounts. Each lane owns its cursor, so dense desktop exploration remains deterministic and shareable."
      title="Explore Exeligmos"
    >
      <ResourceLaneGrid>
        <RecordLane
          description="Newest public occurrences across the network."
          emptyMessage="No public records are available yet."
          items={loaderData.records.data.map((record) => ({
            actorHref: `/u/${encodeURIComponent(record.author.login)}`,
            href: `/r/${encodeURIComponent(record.id)}`,
            record,
          }))}
          nextHref={loaderData.recordsNextHref}
          title="Public records"
        />
        <EventLane
          description="Newest public event intervals across the network."
          emptyMessage="No public events are available yet."
          items={loaderData.events.data.map((event) => ({
            actorHref: `/u/${encodeURIComponent(event.author.login)}`,
            event,
          }))}
          nextHref={loaderData.eventsNextHref}
          title="Public events"
        />
      </ResourceLaneGrid>
      <FeedContractNote>
        These are authoritative current projections, not a replay of the activity outbox. Updates
        and deletions therefore cannot leave stale cards in the snapshot.
      </FeedContractNote>
    </FeedWorkspace>
  );
}
