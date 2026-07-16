import type { ApiSchemas } from "@exeligmos/api-client";

export type ActivityActor = ApiSchemas["PublicUserSummary"];
export type ActivityReference = ApiSchemas["ResourceReference"];
export type ActivityRecord = ApiSchemas["Record"] | ApiSchemas["PublicRecordProjection"];
export type ActivityEvent = ApiSchemas["Event"] | ApiSchemas["PublicEventProjection"];
export type PublicActivityRecord = ApiSchemas["PublicRecordProjection"];
export type PublicActivityEvent = ApiSchemas["PublicEventProjection"];
export type ActivityChange = ApiSchemas["PublicActivityItem"];
export type PublicProfile = ApiSchemas["PublicUserProfile"];

export type RecordActivityChange = ActivityChange & { readonly resourceType: "record" };
export type EventActivityChange = ActivityChange & { readonly resourceType: "event" };
export type UserActivityChange = ActivityChange & { readonly resourceType: "user" };

/**
 * One canonical activity notification plus its optional public projection. Deletes and
 * user lifecycle controls deliberately carry no generated entity body.
 */
export type HydratedActivityRow =
  | {
      readonly kind: "record";
      readonly activity: RecordActivityChange;
      readonly projection?: PublicActivityRecord;
    }
  | {
      readonly kind: "event";
      readonly activity: EventActivityChange;
      readonly projection?: PublicActivityEvent;
    }
  | {
      readonly kind: "user";
      readonly activity: UserActivityChange;
      /** May be retained by the data boundary; lifecycle presentation remains a compact notice. */
      readonly projection?: PublicProfile;
    };

export type ActivityResource =
  | {
      readonly kind: "record";
      readonly record: ActivityRecord;
      /** Supplies the actor when an encrypted owner projection intentionally omits it. */
      readonly actor?: ActivityActor;
      readonly activity?: RecordActivityChange;
    }
  | {
      readonly kind: "event";
      readonly event: ActivityEvent;
      readonly actor?: ActivityActor;
      readonly activity?: EventActivityChange;
    };

const MONTHS = [
  "Jan",
  "Feb",
  "Mar",
  "Apr",
  "May",
  "Jun",
  "Jul",
  "Aug",
  "Sep",
  "Oct",
  "Nov",
  "Dec",
] as const;

/**
 * Formats an API date-time with a fixed UTC representation. It intentionally avoids
 * locale- and wall-clock-dependent output so server markup hydrates without drift.
 */
export function formatAbsoluteTimestamp(value: string): string {
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) {
    return "Invalid timestamp";
  }

  const month = MONTHS[date.getUTCMonth()];
  if (month === undefined) {
    return "Invalid timestamp";
  }

  return `${pad(date.getUTCDate())} ${month} ${date.getUTCFullYear()} · ${pad(
    date.getUTCHours(),
  )}:${pad(date.getUTCMinutes())}:${pad(date.getUTCSeconds())} UTC`;
}

export function formatTimestampRange(start: string, end?: string): string {
  const formattedStart = formatAbsoluteTimestamp(start);
  if (end === undefined) {
    return formattedStart;
  }
  return `${formattedStart} – ${formatAbsoluteTimestamp(end)}`;
}

/** Primary domain time for ordering or display, never the current wall clock. */
export function activityResourceTimestamp(resource: ActivityResource): string {
  if (resource.kind === "event") {
    return resource.event.startsAt;
  }
  return resource.record.visibility === "public"
    ? resource.record.occurredAt
    : resource.record.createdAt;
}

export function activityResourceKey(resource: ActivityResource): string {
  const id = resource.kind === "record" ? resource.record.id : resource.event.id;
  return `${resource.kind}:${id}`;
}

export function activityResourceActor(resource: ActivityResource): ActivityActor | undefined {
  if (resource.actor !== undefined) {
    return resource.actor;
  }
  if (resource.kind === "event") {
    return resource.event.author;
  }
  return resource.record.visibility === "public" ? resource.record.author : undefined;
}

export function isValidTimestamp(value: string): boolean {
  return Number.isFinite(new Date(value).getTime());
}

/** Stable, key-sorted display for JSON metadata supplied by the API. */
export function formatMetadata(value: Readonly<Record<string, unknown>>): string {
  return JSON.stringify(sortJsonValue(value), null, 2);
}

function sortJsonValue(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map((item) => sortJsonValue(item));
  }
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>)
        .sort(([left], [right]) => left.localeCompare(right, "en"))
        .map(([key, nested]) => [key, sortJsonValue(nested)]),
    );
  }
  return value;
}

function pad(value: number): string {
  return String(value).padStart(2, "0");
}
