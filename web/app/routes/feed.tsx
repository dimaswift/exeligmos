import type { Route } from "./+types/feed";
import {
  EventLane,
  FeedContractNote,
  FeedWorkspace,
  RecordLane,
  ResourceLaneGrid,
  type ActivityReference,
} from "~/features/activity-feed";
import {
  FeedQueryError,
  feedPageLinks,
  readFeedCursorQuery,
} from "~/features/activity-stream/feed-query.server";
import {
  ownerEventCursor,
  ownerRecordCursor,
  readOwnerSnapshot,
  recordPageLimit,
  standardPageLimit,
} from "~/features/activity-stream/snapshots.server";
import { readRequestAuth } from "~/lib/auth-boundary.server";
import { throwRouteError } from "~/lib/route-errors.server";

export const meta: Route.MetaFunction = () => [{ title: "My feed · Exeligmos" }];

export async function loader({ context, request, url }: Route.LoaderArgs) {
  try {
    const boundary = readRequestAuth(context);
    const query = readFeedCursorQuery(request);
    const snapshot = await readOwnerSnapshot(boundary.auth, {
      events: {
        cursor: query.eventsCursor === undefined ? undefined : ownerEventCursor(query.eventsCursor),
        limit: standardPageLimit(8),
      },
      records: {
        cursor:
          query.recordsCursor === undefined ? undefined : ownerRecordCursor(query.recordsCursor),
        limit: recordPageLimit(8),
      },
      signal: request.signal,
    });
    const eventLinks = feedPageLinks(
      url,
      "eventsCursor",
      snapshot.events.hasMore ? snapshot.events.nextCursor : undefined,
    );
    const recordLinks = feedPageLinks(
      url,
      "recordsCursor",
      snapshot.records.hasMore ? snapshot.records.nextCursor : undefined,
    );
    return {
      eventsNextHref: eventLinks.nextHref,
      eventsPreviousHref: eventLinks.previousHref,
      owner: boundary.auth.user,
      recordsNextHref: recordLinks.nextHref,
      recordsPreviousHref: recordLinks.previousHref,
      snapshot,
    };
  } catch (error) {
    if (error instanceof FeedQueryError || error instanceof RangeError) {
      throw new Response(error.message, { status: 400, statusText: "Bad Request" });
    }
    return throwRouteError(error, request, { clearInvalidAuth: true });
  }
}

export default function Feed({ loaderData }: Route.ComponentProps) {
  const referenceHref = (reference: ActivityReference) =>
    `/references/${reference.targetType}/${encodeURIComponent(reference.targetId)}`;
  return (
    <FeedWorkspace
      eyebrow="Personal activity"
      summary="Your complete owner projections, including client-encrypted private records. Records and events remain separate lanes because the API gives each its own stable ordering and cursor."
      title="My feed"
    >
      <ResourceLaneGrid>
        <RecordLane
          description="Ordered by record start time; private payloads stay encrypted."
          emptyMessage="You have no records yet."
          items={loaderData.snapshot.records.data.map((record) => ({
            actorHref: `/u/${encodeURIComponent(loaderData.owner.login)}`,
            href: `/records/${encodeURIComponent(record.id)}`,
            record,
          }))}
          nextHref={loaderData.recordsNextHref}
          previousHref={loaderData.recordsPreviousHref}
          referenceHref={referenceHref}
          title="My records"
        />
        <EventLane
          description="Ordered by event start time with full owner metadata."
          emptyMessage="You have no events yet."
          items={loaderData.snapshot.events.data.map((event) => ({
            actorHref: `/u/${encodeURIComponent(loaderData.owner.login)}`,
            event,
          }))}
          nextHref={loaderData.eventsNextHref}
          previousHref={loaderData.eventsPreviousHref}
          referenceHref={referenceHref}
          title="My events"
        />
      </ResourceLaneGrid>
      <FeedContractNote>
        There is intentionally no fabricated combined cursor: owner records and events have
        different canonical sort keys. Browser back/forward retains both independent positions.
      </FeedContractNote>
    </FeedWorkspace>
  );
}
