export const FEED_CURSOR_KEYS = ["recordsCursor", "eventsCursor", "activityCursor"] as const;

export type FeedCursorKey = (typeof FEED_CURSOR_KEYS)[number];

export interface FeedCursorQuery {
  readonly recordsCursor?: string;
  readonly eventsCursor?: string;
  readonly activityCursor?: string;
}

export class FeedQueryError extends Error {
  public constructor(message: string) {
    super(message);
    this.name = "FeedQueryError";
  }
}

/** Reads independent opaque cursors without interpreting or normalizing their contents. */
export function readFeedCursorQuery(request: Request): FeedCursorQuery {
  const url = new URL(request.url);
  return Object.fromEntries(
    FEED_CURSOR_KEYS.flatMap((key) => {
      const values = url.searchParams.getAll(key);
      if (values.length > 1) {
        throw new FeedQueryError(`${key} may be supplied only once.`);
      }
      const value = values[0];
      if (value === undefined) {
        return [];
      }
      if (value.length < 1 || value.length > 2_048) {
        throw new FeedQueryError(`${key} must contain 1 to 2048 characters.`);
      }
      return [[key, value] as const];
    }),
  );
}

/** Replaces only one lane's cursor and preserves every other serialized filter/cursor. */
export function feedCursorHref(
  location: Request | URL,
  key: FeedCursorKey,
  cursor: string | undefined,
): string {
  const url = location instanceof URL ? new URL(location) : new URL(location.url);
  if (cursor === undefined) {
    url.searchParams.delete(key);
  } else {
    if (cursor.length < 1 || cursor.length > 2_048) {
      throw new FeedQueryError(`${key} must contain 1 to 2048 characters.`);
    }
    url.searchParams.set(key, cursor);
  }
  const query = url.searchParams.toString();
  return `${url.pathname}${query === "" ? "" : `?${query}`}`;
}

export function hasFeedCursor(query: FeedCursorQuery): boolean {
  return FEED_CURSOR_KEYS.some((key) => query[key] !== undefined);
}
