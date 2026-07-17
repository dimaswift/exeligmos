import type { Route } from "./+types/feed";
import { FeedWorkspace, RecordLane, type ActivityReference } from "~/features/activity-feed";
import {
  FeedQueryError,
  feedPageLinks,
  readFeedCursorQuery,
} from "~/features/activity-stream/feed-query.server";
import {
  ownerRecordCursor,
  readOwnerRecords,
  recordPageLimit,
} from "~/features/activity-stream/snapshots.server";
import { readRequestAuth } from "~/lib/auth-boundary.server";
import { throwRouteError } from "~/lib/route-errors.server";

export const meta: Route.MetaFunction = () => [{ title: "My feed · Exeligmos" }];

export async function loader({ context, request, url }: Route.LoaderArgs) {
  try {
    const boundary = readRequestAuth(context);
    const query = readFeedCursorQuery(request);
    const records = await readOwnerRecords(boundary.auth, {
      cursor:
        query.recordsCursor === undefined ? undefined : ownerRecordCursor(query.recordsCursor),
      limit: recordPageLimit(8),
      signal: request.signal,
    });
    const recordLinks = feedPageLinks(
      url,
      "recordsCursor",
      records.hasMore ? records.nextCursor : undefined,
    );
    return {
      owner: boundary.auth.user,
      recordsNextHref: recordLinks.nextHref,
      recordsPreviousHref: recordLinks.previousHref,
      records,
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
    <FeedWorkspace eyebrow="" summary="" title="My feed">
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
