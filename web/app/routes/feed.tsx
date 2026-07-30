import type { Route } from "./+types/feed";
import { FeedWorkspace, RecordLane, type ActivityReference } from "~/features/activity-feed";
import {
  FeedQueryError,
  feedPageLinks,
  readFeedCursorQuery,
  readRecordTimeQuery,
} from "~/features/activity-stream/feed-query.server";
import {
  ownerRecordCursor,
  readOwnerRecords,
  recordPageLimit,
} from "~/features/activity-stream/snapshots.server";
import { readRequestAuth } from "~/lib/auth-boundary.server";
import { throwRouteError } from "~/lib/route-errors.server";

import styles from "./feed-routes.module.css";

export const meta: Route.MetaFunction = () => [{ title: "My feed · Fractonica" }];

export async function loader({ context, request, url }: Route.LoaderArgs) {
  try {
    const boundary = readRequestAuth(context);
    const query = readFeedCursorQuery(request);
    const time = readRecordTimeQuery(request);
    const records = await readOwnerRecords(boundary.auth, {
      cursor:
        query.recordsCursor === undefined ? undefined : ownerRecordCursor(query.recordsCursor),
      limit: recordPageLimit(8),
      ...(time.mode === "future"
        ? { occurredAfter: time.boundary }
        : { occurredBefore: time.boundary }),
      signal: request.signal,
    });
    const pageUrl = new URL(url);
    pageUrl.searchParams.set("time", time.mode);
    pageUrl.searchParams.set("at", time.boundary);
    const recordLinks = feedPageLinks(
      pageUrl,
      "recordsCursor",
      records.hasMore ? records.nextCursor : undefined,
    );
    return {
      owner: boundary.auth.user,
      recordsNextHref: recordLinks.nextHref,
      recordsPreviousHref: recordLinks.previousHref,
      records,
      time,
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
    reference.targetType === "record"
      ? `/r/${encodeURIComponent(reference.targetId)}`
      : `/references/${reference.targetType}/${encodeURIComponent(reference.targetId)}`;
  return (
    <FeedWorkspace eyebrow="" summary="" title="My feed">
      <nav aria-label="Record time" className={styles.routeActions}>
        <a
          aria-current={loaderData.time.mode === "past" ? "page" : undefined}
          className={loaderData.time.mode === "past" ? styles.activeAction : undefined}
          href="/feed"
        >
          Past
        </a>
        <a
          aria-current={loaderData.time.mode === "future" ? "page" : undefined}
          className={loaderData.time.mode === "future" ? styles.activeAction : undefined}
          href="/feed?time=future"
        >
          Future
        </a>
      </nav>
      <RecordLane
        emptyMessage="You have no records yet."
        items={loaderData.records.data.map((record) => ({
          actorHref: `/u/${encodeURIComponent(loaderData.owner.login)}`,
          href: `/records/${encodeURIComponent(record.id)}`,
          record,
        }))}
        nextHref={loaderData.recordsNextHref}
        previousHref={loaderData.recordsPreviousHref}
        referenceHref={referenceHref}
      />
    </FeedWorkspace>
  );
}
