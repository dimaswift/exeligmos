import type { ApiPaths, ApiSchemas } from "@exeligmos/api-client";

import {
  BackendRequestError,
  createBackendApiClient,
  readBackendData,
  type BackendConnectionOptions,
} from "../../lib/backend.server";
import type { StoredAuthSession } from "../../lib/session.server";

import type { ActivityCursor } from "./model";

type PublicRecordQuery = NonNullable<ApiPaths["/v1/public/records"]["get"]["parameters"]["query"]>;
type PublicEventQuery = NonNullable<ApiPaths["/v1/public/events"]["get"]["parameters"]["query"]>;
type OwnerRecordQuery = NonNullable<ApiPaths["/v1/records"]["get"]["parameters"]["query"]>;
type OwnerEventQuery = NonNullable<ApiPaths["/v1/events"]["get"]["parameters"]["query"]>;
type PublicActivityQuery = NonNullable<
  ApiPaths["/v1/public/activity"]["get"]["parameters"]["query"]
>;

export type PublicUserProfile = ApiSchemas["PublicUserProfile"];
export type PublicRecord = ApiSchemas["PublicRecordProjection"];
export type PublicEvent = ApiSchemas["PublicEventProjection"];
export type OwnerRecord = ApiSchemas["Record"];
export type OwnerEvent = ApiSchemas["Event"];
export type PublicActivityItem = ApiSchemas["PublicActivityItem"];
export type PublicActivityResourceType = ApiSchemas["PublicActivityResourceType"];

export type PublicRecordCursor = string & { readonly __publicRecordCursor: unique symbol };
export type PublicEventCursor = string & { readonly __publicEventCursor: unique symbol };
export type OwnerRecordCursor = string & { readonly __ownerRecordCursor: unique symbol };
export type OwnerEventCursor = string & { readonly __ownerEventCursor: unique symbol };
export type RecordPageLimit = number & { readonly __recordPageLimit: unique symbol };
export type StandardPageLimit = number & { readonly __standardPageLimit: unique symbol };

export type PublicRecordPage = Readonly<
  Omit<ApiSchemas["PublicRecordProjectionPage"], "nextCursor"> & {
    readonly nextCursor?: PublicRecordCursor;
  }
>;
export type PublicEventPage = Readonly<
  Omit<ApiSchemas["PublicEventPage"], "nextCursor"> & {
    readonly nextCursor?: PublicEventCursor;
  }
>;
export type OwnerRecordPage = Readonly<
  Omit<ApiSchemas["RecordPage"], "nextCursor"> & { readonly nextCursor?: OwnerRecordCursor }
>;
export type OwnerEventPage = Readonly<
  Omit<ApiSchemas["EventPage"], "nextCursor"> & { readonly nextCursor?: OwnerEventCursor }
>;
export type ActivityPage = Readonly<
  Omit<ApiSchemas["PublicActivityPage"], "nextCursor"> & {
    readonly nextCursor: ActivityCursor;
  }
>;
export type ActivityHistoryPage = ActivityPage;

interface SnapshotRequestContext extends BackendConnectionOptions {
  readonly signal?: AbortSignal;
}

/** Access-only authorization. This boundary cannot see or rotate a refresh token. */
export type SnapshotAuthorization = Readonly<Pick<StoredAuthSession, "accessToken" | "user">>;

export type PublicRecordSnapshotOptions = Readonly<
  SnapshotRequestContext &
    Omit<PublicRecordQuery, "cursor" | "limit"> & {
      readonly cursor?: PublicRecordCursor;
      readonly limit?: RecordPageLimit;
    }
>;
export type PublicEventSnapshotOptions = Readonly<
  SnapshotRequestContext &
    Omit<PublicEventQuery, "cursor" | "limit"> & {
      readonly cursor?: PublicEventCursor;
      readonly limit?: StandardPageLimit;
    }
>;
export type OwnerRecordSnapshotOptions = Readonly<
  SnapshotRequestContext &
    Omit<OwnerRecordQuery, "cursor" | "limit"> & {
      readonly cursor?: OwnerRecordCursor;
      readonly limit?: RecordPageLimit;
    }
>;
export type OwnerEventSnapshotOptions = Readonly<
  SnapshotRequestContext &
    Omit<OwnerEventQuery, "cursor" | "limit"> & {
      readonly cursor?: OwnerEventCursor;
      readonly limit?: StandardPageLimit;
    }
>;
export type ActivityHistoryOptions = Readonly<
  SnapshotRequestContext &
    Pick<PublicActivityQuery, "resourceType"> & {
      readonly cursor?: ActivityCursor;
      readonly limit?: StandardPageLimit;
    }
>;

export interface PublicUserSnapshot {
  readonly profile: PublicUserProfile;
  readonly records: PublicRecordPage;
  readonly events: PublicEventPage;
}

export interface OwnerSnapshot {
  readonly records: OwnerRecordPage;
  readonly events: OwnerEventPage;
}

export interface PublicUserSnapshotOptions extends SnapshotRequestContext {
  readonly records?: Omit<PublicRecordSnapshotOptions, keyof SnapshotRequestContext | "userId">;
  readonly events?: Omit<PublicEventSnapshotOptions, keyof SnapshotRequestContext | "userId">;
}

export interface OwnerSnapshotOptions extends SnapshotRequestContext {
  readonly records?: Omit<OwnerRecordSnapshotOptions, keyof SnapshotRequestContext>;
  readonly events?: Omit<OwnerEventSnapshotOptions, keyof SnapshotRequestContext>;
}

export function publicRecordCursor(value: string): PublicRecordCursor {
  return opaqueCursor(value, "public record cursor") as PublicRecordCursor;
}

export function publicEventCursor(value: string): PublicEventCursor {
  return opaqueCursor(value, "public event cursor") as PublicEventCursor;
}

export function ownerRecordCursor(value: string): OwnerRecordCursor {
  return opaqueCursor(value, "owner record cursor") as OwnerRecordCursor;
}

export function ownerEventCursor(value: string): OwnerEventCursor {
  return opaqueCursor(value, "owner event cursor") as OwnerEventCursor;
}

export function activityHistoryCursor(value: string): ActivityCursor {
  return opaqueCursor(value, "activity history cursor") as ActivityCursor;
}

export function recordPageLimit(value: number): RecordPageLimit {
  return boundedLimit(value, 25, "record page limit") as RecordPageLimit;
}

export function standardPageLimit(value: number): StandardPageLimit {
  return boundedLimit(value, 200, "page limit") as StandardPageLimit;
}

export async function readPublicProfile(
  login: string,
  options: SnapshotRequestContext = {},
): Promise<PublicUserProfile> {
  const client = publicClient(options);
  return readBackendData(
    () =>
      client.GET("/v1/public/users/{login}", {
        params: { path: { login } },
        signal: options.signal,
      }),
    `Could not load public profile @${login}.`,
  );
}

export async function readPublicRecord(
  recordId: string,
  options: SnapshotRequestContext = {},
): Promise<PublicRecord> {
  const client = publicClient(options);
  return readBackendData(
    () =>
      client.GET("/v1/public/records/{recordId}", {
        params: { path: { recordId } },
        signal: options.signal,
      }),
    "Could not load the public record.",
  );
}

export async function readPublicEvent(
  eventId: string,
  options: SnapshotRequestContext = {},
): Promise<PublicEvent> {
  const client = publicClient(options);
  return readBackendData(
    () =>
      client.GET("/v1/public/events/{eventId}", {
        params: { path: { eventId } },
        signal: options.signal,
      }),
    "Could not load the public event.",
  );
}

export async function readPublicRecords(
  options: PublicRecordSnapshotOptions = {},
): Promise<PublicRecordPage> {
  const { cursor, limit, signal, baseUrl, fetch, ...filters } = options;
  const client = createBackendApiClient({ baseUrl, fetch });
  const page = await readBackendData(
    () =>
      client.GET("/v1/public/records", {
        params: { query: { ...filters, cursor, limit } },
        signal,
      }),
    "Could not load public records.",
  );
  return publicRecordPage(page);
}

export async function readPublicEvents(
  options: PublicEventSnapshotOptions = {},
): Promise<PublicEventPage> {
  const { cursor, limit, signal, baseUrl, fetch, ...filters } = options;
  const client = createBackendApiClient({ baseUrl, fetch });
  const page = await readBackendData(
    () =>
      client.GET("/v1/public/events", {
        params: { query: { ...filters, cursor, limit } },
        signal,
      }),
    "Could not load public events.",
  );
  return publicEventPage(page);
}

export async function readOwnerRecords(
  auth: SnapshotAuthorization,
  options: OwnerRecordSnapshotOptions = {},
): Promise<OwnerRecordPage> {
  const { cursor, limit, signal, baseUrl, fetch, ...filters } = options;
  const client = createBackendApiClient({ baseUrl, fetch, accessToken: auth.accessToken });
  const page = await readBackendData(
    () =>
      client.GET("/v1/records", {
        params: { query: { ...filters, cursor, limit } },
        signal,
      }),
    "Could not load your records.",
  );
  return ownerRecordPage(page);
}

export async function readOwnerRecord(
  auth: SnapshotAuthorization,
  recordId: string,
  options: SnapshotRequestContext = {},
): Promise<OwnerRecord> {
  const client = createBackendApiClient({
    baseUrl: options.baseUrl,
    fetch: options.fetch,
    accessToken: auth.accessToken,
  });
  return readBackendData(
    () =>
      client.GET("/v1/records/{recordId}", {
        params: { path: { recordId } },
        signal: options.signal,
      }),
    "Could not load the record.",
  );
}

export async function readOwnerEvents(
  auth: SnapshotAuthorization,
  options: OwnerEventSnapshotOptions = {},
): Promise<OwnerEventPage> {
  const { cursor, limit, signal, baseUrl, fetch, ...filters } = options;
  const client = createBackendApiClient({ baseUrl, fetch, accessToken: auth.accessToken });
  const page = await readBackendData(
    () =>
      client.GET("/v1/events", {
        params: { query: { ...filters, cursor, limit } },
        signal,
      }),
    "Could not load your events.",
  );
  return ownerEventPage(page);
}

/** Loads the latest public record/event collections. Activity history is not a substitute. */
export async function readPublicUserSnapshot(
  login: string,
  options: PublicUserSnapshotOptions = {},
): Promise<PublicUserSnapshot> {
  const context = requestContext(options);
  const profile = await readPublicProfile(login, context);
  const [records, events] = await Promise.all([
    readPublicRecords({ ...options.records, ...context, userId: profile.id }),
    readPublicEvents({ ...options.events, ...context, userId: profile.id }),
  ]);
  return { profile, records, events };
}

/** Loads the authenticated owner's latest records and events using independent cursors. */
export async function readOwnerSnapshot(
  auth: SnapshotAuthorization,
  options: OwnerSnapshotOptions = {},
): Promise<OwnerSnapshot> {
  const context = requestContext(options);
  const [records, events] = await Promise.all([
    readOwnerRecords(auth, { ...options.records, ...context }),
    readOwnerEvents(auth, { ...options.events, ...context }),
  ]);
  return { records, events };
}

/** Oldest-first identifier history for one public actor; it is not a latest-resource snapshot. */
export function readPublicUserActivityHistory(
  userId: string,
  options: ActivityHistoryOptions = {},
): Promise<ActivityHistoryPage> {
  return readActivityHistory("public", undefined, userId, options);
}

/** Latest public notifications for one actor on first load, then oldest-forward after the cursor. */
export function readPublicUserActivity(
  userId: string,
  options: ActivityHistoryOptions = {},
): Promise<ActivityPage> {
  return readActivityHistory("public", undefined, userId, options, options.cursor === undefined);
}

/** Oldest-first public identifier history for the signed-in actor only. */
export function readPublicSelfActivityHistory(
  auth: SnapshotAuthorization,
  options: ActivityHistoryOptions = {},
): Promise<ActivityHistoryPage> {
  return readActivityHistory("public", undefined, auth.user.id, options);
}

/** Latest public notifications for the signed-in actor; private owner data is not included. */
export function readPublicSelfActivity(
  auth: SnapshotAuthorization,
  options: ActivityHistoryOptions = {},
): Promise<ActivityPage> {
  return readActivityHistory(
    "public",
    undefined,
    auth.user.id,
    options,
    options.cursor === undefined,
  );
}

/** Oldest-first global public identifier history. */
export function readGlobalActivityHistory(
  options: ActivityHistoryOptions = {},
): Promise<ActivityHistoryPage> {
  return readActivityHistory("public", undefined, undefined, options);
}

/** Latest global notifications on first load, then oldest-forward after the returned cursor. */
export function readGlobalActivity(options: ActivityHistoryOptions = {}): Promise<ActivityPage> {
  return readActivityHistory("public", undefined, undefined, options, options.cursor === undefined);
}

/** Oldest-first identifier history from current subscriptions. */
export function readFollowingActivityHistory(
  auth: SnapshotAuthorization,
  options: ActivityHistoryOptions = {},
): Promise<ActivityHistoryPage> {
  return readActivityHistory("following", auth.accessToken, undefined, options);
}

/** Latest following notifications on first load, then oldest-forward after the returned cursor. */
export function readFollowingActivity(
  auth: SnapshotAuthorization,
  options: ActivityHistoryOptions = {},
): Promise<ActivityPage> {
  return readActivityHistory(
    "following",
    auth.accessToken,
    undefined,
    options,
    options.cursor === undefined,
  );
}

type UpsertActivity<TType extends PublicActivityResourceType> = PublicActivityItem & {
  readonly operation: "upsert";
  readonly resourceType: TType;
};

type TypedActivity<TType extends PublicActivityResourceType> = PublicActivityItem & {
  readonly resourceType: TType;
};

export type HydratedActivityEntry =
  | {
      readonly kind: "user";
      readonly activity: TypedActivity<"user">;
      readonly projection?: PublicUserProfile;
    }
  | {
      readonly kind: "record";
      readonly activity: TypedActivity<"record">;
      readonly projection?: PublicRecord;
    }
  | {
      readonly kind: "event";
      readonly activity: TypedActivity<"event">;
      readonly projection?: PublicEvent;
    };

export type HydratedActivityHistoryPage = Readonly<
  Omit<ActivityHistoryPage, "data"> & { readonly data: readonly HydratedActivityEntry[] }
>;

export interface ActivityHydrationOptions extends SnapshotRequestContext {
  /** Worker count is constrained to 1...16. */
  readonly concurrency?: number;
}

/**
 * Resolves upserts through generated typed routes selected by type and ID. The server-supplied
 * resourceUrl is deliberately never fetched. Deletes remain explicit tombstones.
 */
export async function hydrateActivityHistory(
  page: ActivityHistoryPage,
  options: ActivityHydrationOptions = {},
): Promise<HydratedActivityHistoryPage> {
  if (page.data.length > 200) {
    throw new RangeError("Activity hydration accepts at most 200 items.");
  }
  const concurrency = boundedLimit(options.concurrency ?? 6, 16, "hydration concurrency");
  const output = new Array<HydratedActivityEntry>(page.data.length);
  const records = new Map<string, Promise<PublicRecord>>();
  const events = new Map<string, Promise<PublicEvent>>();
  const users = new Map<string, Promise<PublicUserProfile>>();
  let nextIndex = 0;

  const hydrate = async (activity: PublicActivityItem): Promise<HydratedActivityEntry> => {
    if (activity.operation === "delete") {
      return activityWithoutProjection(activity);
    }
    const context = requestContext(options);
    switch (activity.resourceType) {
      case "record": {
        const resource = await allowMissing(
          cached(records, activity.resourceId, () =>
            readPublicRecord(activity.resourceId, context),
          ),
        );
        if (resource === undefined) {
          return { kind: "record", activity: activity as UpsertActivity<"record"> };
        }
        assertResourceIdentity(activity, resource.id);
        return {
          kind: "record",
          activity: activity as UpsertActivity<"record">,
          projection: resource,
        };
      }
      case "event": {
        const resource = await allowMissing(
          cached(events, activity.resourceId, () => readPublicEvent(activity.resourceId, context)),
        );
        if (resource === undefined) {
          return { kind: "event", activity: activity as UpsertActivity<"event"> };
        }
        assertResourceIdentity(activity, resource.id);
        return {
          kind: "event",
          activity: activity as UpsertActivity<"event">,
          projection: resource,
        };
      }
      case "user": {
        const resource = await allowMissing(
          cached(users, activity.actor.login, () =>
            readPublicProfile(activity.actor.login, context),
          ),
        );
        if (resource === undefined) {
          return { kind: "user", activity: activity as UpsertActivity<"user"> };
        }
        assertResourceIdentity(activity, resource.id);
        return { kind: "user", activity: activity as UpsertActivity<"user">, projection: resource };
      }
    }
  };

  const worker = async () => {
    while (nextIndex < page.data.length) {
      const index = nextIndex++;
      output[index] = await hydrate(page.data[index]!);
    }
  };
  await Promise.all(
    Array.from({ length: Math.min(concurrency, page.data.length) }, async () => worker()),
  );
  return { ...page, data: output };
}

export const hydrateActivityPage = hydrateActivityHistory;

async function readActivityHistory(
  scope: "public" | "following",
  accessToken: string | undefined,
  userId: string | undefined,
  options: ActivityHistoryOptions,
  latest = false,
): Promise<ActivityHistoryPage> {
  const { cursor, limit, resourceType, signal, baseUrl, fetch } = options;
  const normalizedTypes = normalizeResourceTypes(resourceType);
  const client = createBackendApiClient({ baseUrl, fetch, accessToken });
  const path = scope === "public" ? "/v1/public/activity" : "/v1/activity";
  const page = await readBackendData(
    () =>
      client.GET(path, {
        params: {
          query: {
            cursor,
            limit,
            resourceType: normalizedTypes,
            userId,
            snapshot: latest ? "latest" : undefined,
          },
        },
        signal,
      }),
    `Could not load ${scope} activity history.`,
  );
  return activityHistoryPage(page);
}

function activityWithoutProjection(activity: PublicActivityItem): HydratedActivityEntry {
  switch (activity.resourceType) {
    case "record":
      return { kind: "record", activity: activity as TypedActivity<"record"> };
    case "event":
      return { kind: "event", activity: activity as TypedActivity<"event"> };
    case "user":
      return { kind: "user", activity: activity as TypedActivity<"user"> };
  }
}

async function allowMissing<T>(promise: Promise<T>): Promise<T | undefined> {
  try {
    return await promise;
  } catch (error) {
    if (error instanceof BackendRequestError && error.status === 404) {
      return undefined;
    }
    throw error;
  }
}

function publicClient(options: BackendConnectionOptions) {
  return createBackendApiClient({ baseUrl: options.baseUrl, fetch: options.fetch });
}

function requestContext(options: SnapshotRequestContext): SnapshotRequestContext {
  return { baseUrl: options.baseUrl, fetch: options.fetch, signal: options.signal };
}

function opaqueCursor(value: string, label: string): string {
  if (value.length < 1 || value.length > 2_048) {
    throw new RangeError(`${label} must contain 1 to 2048 characters.`);
  }
  return value;
}

function boundedLimit(value: number, maximum: number, label: string): number {
  if (!Number.isSafeInteger(value) || value < 1 || value > maximum) {
    throw new RangeError(`${label} must be an integer from 1 through ${maximum}.`);
  }
  return value;
}

function normalizeResourceTypes(
  values: PublicActivityQuery["resourceType"],
): PublicActivityResourceType[] | undefined {
  if (values === undefined || values.length === 0) {
    return undefined;
  }
  const allowed = new Set<PublicActivityResourceType>(["user", "record", "event"]);
  const unique = [...new Set(values)];
  if (unique.some((value) => !allowed.has(value))) {
    throw new RangeError("Activity resourceType contains an unsupported value.");
  }
  return unique;
}

function publicRecordPage(page: ApiSchemas["PublicRecordProjectionPage"]): PublicRecordPage {
  return {
    ...page,
    nextCursor: page.nextCursor === undefined ? undefined : publicRecordCursor(page.nextCursor),
  };
}

function publicEventPage(page: ApiSchemas["PublicEventPage"]): PublicEventPage {
  return {
    ...page,
    nextCursor: page.nextCursor === undefined ? undefined : publicEventCursor(page.nextCursor),
  };
}

function ownerRecordPage(page: ApiSchemas["RecordPage"]): OwnerRecordPage {
  return {
    ...page,
    nextCursor: page.nextCursor === undefined ? undefined : ownerRecordCursor(page.nextCursor),
  };
}

function ownerEventPage(page: ApiSchemas["EventPage"]): OwnerEventPage {
  return {
    ...page,
    nextCursor: page.nextCursor === undefined ? undefined : ownerEventCursor(page.nextCursor),
  };
}

function activityHistoryPage(page: ApiSchemas["PublicActivityPage"]): ActivityHistoryPage {
  try {
    return { ...page, nextCursor: activityHistoryCursor(page.nextCursor) };
  } catch {
    throw new BackendRequestError("The backend returned an invalid activity cursor.", 502);
  }
}

function cached<TKey, TValue>(
  cache: Map<TKey, Promise<TValue>>,
  key: TKey,
  read: () => Promise<TValue>,
): Promise<TValue> {
  const existing = cache.get(key);
  if (existing !== undefined) {
    return existing;
  }
  const value = read();
  cache.set(key, value);
  return value;
}

function assertResourceIdentity(activity: PublicActivityItem, actualId: string): void {
  if (activity.resourceId !== actualId) {
    throw new BackendRequestError(
      `Hydrated ${activity.resourceType} did not match its activity resource ID.`,
      502,
    );
  }
}
