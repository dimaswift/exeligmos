export const FEED_CURSOR_KEYS = ["recordsCursor", "eventsCursor", "activityCursor"] as const;
const FEED_HISTORY_KEYS = {
  recordsCursor: "recordsHistory",
  eventsCursor: "eventsHistory",
  activityCursor: "activityHistory",
} as const;
const MAX_CURSOR_HISTORY = 50;
const MAX_HISTORY_LENGTH = 8_192;

export type FeedCursorKey = (typeof FEED_CURSOR_KEYS)[number];

export interface FeedCursorQuery {
  readonly recordsCursor?: string;
  readonly eventsCursor?: string;
  readonly activityCursor?: string;
}

export interface FeedPageLinks {
  readonly nextHref: string | null;
  readonly previousHref: string | null;
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

/**
 * Builds reversible keyset-pagination links. APIs expose only an "older"
 * cursor, so the URL carries a bounded stack of cursors needed to return to
 * newer pages without server-side session state.
 */
export function feedPageLinks(
  location: Request | URL,
  key: FeedCursorKey,
  nextCursor: string | undefined,
): FeedPageLinks {
  const url = location instanceof URL ? new URL(location) : new URL(location.url);
  const historyKey = FEED_HISTORY_KEYS[key];
  const history = readHistory(url, historyKey);
  const currentCursor = readSingleCursor(url, key);
  if (currentCursor === undefined && history.length > 0) {
    throw new FeedQueryError(`${historyKey} requires ${key}.`);
  }

  if (nextCursor !== undefined) {
    validateCursor(nextCursor, key);
  }

  return {
    nextHref:
      nextCursor === undefined
        ? null
        : pageHref(
            url,
            key,
            nextCursor,
            historyKey,
            currentCursor === undefined ? history : [...history, currentCursor],
          ),
    previousHref:
      currentCursor === undefined
        ? null
        : pageHref(url, key, history.at(-1), historyKey, history.slice(0, -1)),
  };
}

export function hasFeedCursor(query: FeedCursorQuery): boolean {
  return FEED_CURSOR_KEYS.some((key) => query[key] !== undefined);
}

function pageHref(
  source: URL,
  cursorKey: FeedCursorKey,
  cursor: string | undefined,
  historyKey: string,
  history: readonly string[],
): string {
  const url = new URL(source);
  if (cursor === undefined) url.searchParams.delete(cursorKey);
  else url.searchParams.set(cursorKey, cursor);
  if (history.length === 0) url.searchParams.delete(historyKey);
  else url.searchParams.set(historyKey, Buffer.from(JSON.stringify(history)).toString("base64url"));
  const query = url.searchParams.toString();
  return `${url.pathname}${query === "" ? "" : `?${query}`}`;
}

function readHistory(url: URL, key: string): readonly string[] {
  const values = url.searchParams.getAll(key);
  if (values.length > 1) throw new FeedQueryError(`${key} may be supplied only once.`);
  const encoded = values[0];
  if (encoded === undefined) return [];
  if (encoded.length < 1 || encoded.length > MAX_HISTORY_LENGTH) {
    throw new FeedQueryError(`${key} is invalid.`);
  }
  try {
    const parsed = JSON.parse(Buffer.from(encoded, "base64url").toString("utf8")) as unknown;
    if (
      !Array.isArray(parsed) ||
      parsed.length > MAX_CURSOR_HISTORY ||
      parsed.some(
        (cursor) => typeof cursor !== "string" || cursor.length < 1 || cursor.length > 2_048,
      )
    ) {
      throw new Error("invalid history");
    }
    return parsed as readonly string[];
  } catch {
    throw new FeedQueryError(`${key} is invalid.`);
  }
}

function readSingleCursor(url: URL, key: FeedCursorKey): string | undefined {
  const values = url.searchParams.getAll(key);
  if (values.length > 1) throw new FeedQueryError(`${key} may be supplied only once.`);
  const cursor = values[0];
  if (cursor !== undefined) validateCursor(cursor, key);
  return cursor;
}

function validateCursor(cursor: string, key: FeedCursorKey): void {
  if (cursor.length < 1 || cursor.length > 2_048) {
    throw new FeedQueryError(`${key} must contain 1 to 2048 characters.`);
  }
}
