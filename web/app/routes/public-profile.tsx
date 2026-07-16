import type { Route } from "./+types/public-profile";
import {
  FeedContractNote,
  EventLane,
  PublicProfileHeader,
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
  readPublicUserSnapshot,
  recordPageLimit,
  standardPageLimit,
} from "~/features/activity-stream/snapshots.server";
import { throwRouteError } from "~/lib/route-errors.server";

import styles from "./feed-routes.module.css";

const PUBLIC_LOGIN = /^[A-Za-z0-9][A-Za-z0-9._-]{2,63}$/;

export const meta: Route.MetaFunction = ({ loaderData, params }) => [
  { title: `@${loaderData.snapshot.profile.login ?? params.login} · Exeligmos` },
  {
    name: "description",
    content: `Public records and events from ${loaderData.snapshot.profile.displayName}.`,
  },
];

export async function loader({ request, params, url }: Route.LoaderArgs) {
  if (!PUBLIC_LOGIN.test(params.login)) {
    throw new Response("Public profile not found.", { status: 404, statusText: "Not Found" });
  }

  try {
    const query = readFeedCursorQuery(request);
    const snapshot = await readPublicUserSnapshot(params.login, {
      events: {
        cursor:
          query.eventsCursor === undefined ? undefined : publicEventCursor(query.eventsCursor),
        limit: standardPageLimit(6),
      },
      records: {
        cursor:
          query.recordsCursor === undefined ? undefined : publicRecordCursor(query.recordsCursor),
        limit: recordPageLimit(6),
      },
      signal: request.signal,
    });
    return {
      eventsNextHref:
        snapshot.events.hasMore && snapshot.events.nextCursor !== undefined
          ? feedCursorHref(url, "eventsCursor", snapshot.events.nextCursor)
          : null,
      recordsNextHref:
        snapshot.records.hasMore && snapshot.records.nextCursor !== undefined
          ? feedCursorHref(url, "recordsCursor", snapshot.records.nextCursor)
          : null,
      snapshot,
    };
  } catch (error) {
    if (error instanceof FeedQueryError || error instanceof RangeError) {
      throw new Response(error.message, { status: 400, statusText: "Bad Request" });
    }
    return throwRouteError(error, request, { notFoundMessage: "Public profile not found." });
  }
}

export default function PublicProfile({ loaderData }: Route.ComponentProps) {
  const { snapshot } = loaderData;
  return (
    <div className={styles.profilePage}>
      <PublicProfileHeader
        actions={
          <div className={styles.profileActions}>
            <a href="/explore">Explore public activity</a>
            <a href="/feed/following">Open workspace to follow</a>
          </div>
        }
        profile={snapshot.profile}
      />
      <ResourceLaneGrid>
        <RecordLane
          description="Current public projections, ordered by occurrence time."
          emptyMessage={`@${snapshot.profile.login} has no public records.`}
          items={snapshot.records.data.map((record) => ({
            actorHref: `/u/${encodeURIComponent(record.author.login)}`,
            href: `/r/${encodeURIComponent(record.id)}`,
            record,
          }))}
          nextHref={loaderData.recordsNextHref}
          title="Public records"
        />
        <EventLane
          description="Current public events, ordered by start time."
          emptyMessage={`@${snapshot.profile.login} has no public events.`}
          items={snapshot.events.data.map((event) => ({
            actorHref: `/u/${encodeURIComponent(event.author.login)}`,
            event,
          }))}
          nextHref={loaderData.eventsNextHref}
          title="Public events"
        />
      </ResourceLaneGrid>
      <FeedContractNote>
        This page is built from explicit public projections. Device provenance, encrypted payloads,
        and owner-only media URLs are never requested by this route.
      </FeedContractNote>
    </div>
  );
}
