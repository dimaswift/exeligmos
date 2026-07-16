import type { Route } from "./+types/following-feed";
import {
  ActivitySnapshot,
  FeedContractNote,
  FeedWorkspace,
  type ActivityReference,
  type HydratedActivityRow,
} from "~/features/activity-feed";
import {
  FeedQueryError,
  feedCursorHref,
  readFeedCursorQuery,
} from "~/features/activity-stream/feed-query.server";
import {
  activityHistoryCursor,
  hydrateActivityPage,
  readFollowingActivity,
  standardPageLimit,
} from "~/features/activity-stream/snapshots.server";
import { readRequestAuth } from "~/lib/auth-boundary.server";
import { throwRouteError } from "~/lib/route-errors.server";

export const meta: Route.MetaFunction = () => [{ title: "Following activity · Exeligmos" }];

export async function loader({ context, request, url }: Route.LoaderArgs) {
  try {
    const boundary = readRequestAuth(context);
    const query = readFeedCursorQuery(request);
    const page = await readFollowingActivity(boundary.auth, {
      cursor:
        query.activityCursor === undefined
          ? undefined
          : activityHistoryCursor(query.activityCursor),
      limit: standardPageLimit(20),
      signal: request.signal,
    });
    const hydrated = await hydrateActivityPage(page, { signal: request.signal });
    return {
      latestHref:
        query.activityCursor === undefined
          ? null
          : feedCursorHref(url, "activityCursor", undefined),
      nextHref: page.hasMore ? feedCursorHref(url, "activityCursor", page.nextCursor) : null,
      page: hydrated,
      resumeCursor: page.hasMore ? null : page.nextCursor,
    };
  } catch (error) {
    if (error instanceof FeedQueryError || error instanceof RangeError) {
      throw new Response(error.message, { status: 400, statusText: "Bad Request" });
    }
    return throwRouteError(error, request, { clearInvalidAuth: true });
  }
}

export default function FollowingFeed({ loaderData }: Route.ComponentProps) {
  const referenceHref = (reference: ActivityReference) =>
    `/references/${reference.targetType}/${encodeURIComponent(reference.targetId)}`;
  return (
    <FeedWorkspace
      actions={<a href="/explore">Discover public actors</a>}
      eyebrow="Subscriptions"
      summary="Latest public changes from accounts you subscribe to, including automated publishers such as @sun. Subscription record/event filters are enforced by the backend before hydration."
      title="Following feed"
    >
      <ActivitySnapshot
        actorHref={(row) => `/u/${encodeURIComponent(row.activity.actor.login)}`}
        description="Latest bounded following window, kept in canonical sequence order for deterministic resume."
        emptyMessage="Your subscriptions have not published matching public activity yet."
        latestHref={loaderData.latestHref ?? undefined}
        nextHref={loaderData.nextHref ?? undefined}
        referenceHref={referenceHref}
        resourceHref={activityResourceHref}
        resumeCursor={loaderData.resumeCursor ?? undefined}
        rows={loaderData.page.data}
        title="Latest subscribed changes"
      />
      <FeedContractNote>
        Following grants no additional read access. Cards hydrate only from the same public
        projections available anonymously, and user lifecycle controls can invalidate an actor's
        visible resources.
      </FeedContractNote>
    </FeedWorkspace>
  );
}

function activityResourceHref(row: HydratedActivityRow): string {
  if (row.kind === "user") return `/u/${encodeURIComponent(row.activity.actor.login)}`;
  if (row.kind === "record") return `/r/${encodeURIComponent(row.activity.resourceId)}`;
  return `/references/event/${encodeURIComponent(row.activity.resourceId)}`;
}
