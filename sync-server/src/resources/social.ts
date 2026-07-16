import { createHash, randomUUID } from "node:crypto";

import type { QueryResultRow } from "pg";

import type { Principal } from "../auth/principal.js";
import type { Database, Queryable } from "../db/database.js";
import { HttpProblem } from "../http/problem.js";
import {
  canonicalJson,
  cursorSignature,
  databaseErrorCode,
  decodeCursor,
  encodeCursor,
  executeIdempotentMutation,
  invalidRequest,
  isoDate,
  type MutationResponse,
  parsePageLimit,
  PreconditionFailedProblem,
  requireMatchingEtag,
  translateDatabaseError,
  unprocessable,
} from "./shared.js";

export interface PublicUserSummary {
  readonly id: string;
  readonly login: string;
  readonly displayName: string;
}

export interface SubscriptionTargetUserSummary extends PublicUserSummary {
  readonly status: "active" | "disabled";
}

export interface PublicUserProfile extends PublicUserSummary {
  readonly createdAt: string;
  readonly publicRecordCount: number;
  readonly publicEventCount: number;
  readonly followerCount: number;
}

export interface SubscriptionInput {
  readonly includeRecords?: boolean;
  readonly includeEvents?: boolean;
}

export interface SubscriptionResource {
  readonly id: string;
  readonly userId: string;
  readonly targetUser: SubscriptionTargetUserSummary;
  readonly includeRecords: boolean;
  readonly includeEvents: boolean;
  readonly revision: number;
  readonly createdAt: string;
  readonly updatedAt: string;
}

export interface SubscriptionPage {
  readonly data: readonly SubscriptionResource[];
  readonly hasMore: boolean;
  readonly nextCursor?: string;
}

export interface SubscriptionListQuery {
  readonly cursor?: string;
  readonly limit?: unknown;
}

export type PublicActivityResourceType = "user" | "record" | "event";

export interface PublicActivityItem {
  readonly sequence: number;
  readonly publishedAt: string;
  readonly actor: PublicUserSummary;
  readonly resourceType: PublicActivityResourceType;
  readonly resourceId: string;
  readonly operation: "upsert" | "delete";
  readonly revision: number;
  readonly resourceUrl: string;
}

export interface PublicActivityPage {
  readonly data: readonly PublicActivityItem[];
  readonly nextCursor: string;
  readonly hasMore: boolean;
}

export interface PublicActivityQuery {
  readonly cursor?: string;
  readonly limit?: unknown;
  readonly userId?: string;
  readonly resourceTypes?: readonly string[];
  readonly snapshot?: "latest";
}

interface ProfileRow extends QueryResultRow {
  readonly id: string;
  readonly login: string;
  readonly display_name: string;
  readonly created_at: Date | string;
  readonly public_record_count: string | number;
  readonly public_event_count: string | number;
  readonly follower_count: string | number;
}

interface SubscriptionRow extends QueryResultRow {
  readonly id: string;
  readonly user_id: string;
  readonly target_user_id: string;
  readonly target_login: string;
  readonly target_display_name: string;
  readonly target_status: "active" | "disabled";
  readonly include_records: boolean;
  readonly include_events: boolean;
  readonly revision: string | number;
  readonly created_at: Date | string;
  readonly updated_at: Date | string;
  readonly deleted_at: Date | string | null;
}

interface ActivityRow extends QueryResultRow {
  readonly sequence: string | number;
  readonly published_at: Date | string;
  readonly actor_user_id: string;
  readonly actor_login: string;
  readonly actor_display_name: string;
  readonly resource_type: PublicActivityResourceType;
  readonly resource_id: string;
  readonly operation: "upsert" | "delete";
  readonly revision: string | number;
}

interface HighWaterRow extends QueryResultRow {
  readonly high_water: string | number;
}

const LOGIN_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ACTIVITY_CURSOR_KIND = "public-activity";

export class PublicProfileService {
  constructor(private readonly database: Database) {}

  async getByLogin(login: string): Promise<PublicUserProfile> {
    const normalized = normalizeLogin(login);
    const result = await this.database.query<ProfileRow>(
      `SELECT
         u.id,
         u.login,
         u.display_name,
         u.created_at,
         (SELECT count(*) FROM records r
          WHERE r.user_id = u.id AND r.visibility = 'public' AND r.deleted_at IS NULL)
           AS public_record_count,
         (SELECT count(*) FROM events e
          WHERE e.user_id = u.id AND e.visibility = 'public' AND e.deleted_at IS NULL)
           AS public_event_count,
         (SELECT count(*) FROM subscriptions s
          WHERE s.target_user_id = u.id AND s.deleted_at IS NULL)
           AS follower_count
       FROM users u
       WHERE lower(u.login) = lower($1) AND u.status = 'active'
       LIMIT 1`,
      [normalized],
    );
    const row = result.rows[0];
    if (row === undefined) {
      throw publicUserNotFound();
    }
    return {
      id: row.id,
      login: row.login,
      displayName: row.display_name,
      createdAt: isoDate(row.created_at),
      publicRecordCount: safeCount(row.public_record_count),
      publicEventCount: safeCount(row.public_event_count),
      followerCount: safeCount(row.follower_count),
    };
  }
}

export class SubscriptionService {
  constructor(private readonly database: Database) {}

  async list(principal: Principal, query: SubscriptionListQuery): Promise<SubscriptionPage> {
    const limit = parsePageLimit(query.limit);
    const signature = cursorSignature({ userId: principal.userId });
    const cursor = decodeCursor(query.cursor, "subscriptions", signature);
    const values: unknown[] = [principal.userId];
    const where = ["s.user_id = $1", "s.deleted_at IS NULL"];
    if (cursor !== undefined) {
      values.push(cursor.sort, cursor.id);
      where.push(
        `(s.updated_at, s.id) < ($${values.length - 1}::timestamptz, $${values.length}::uuid)`,
      );
    }
    values.push(limit + 1);
    const result = await this.database.query<SubscriptionRow>(
      `SELECT ${SUBSCRIPTION_COLUMNS}
       FROM subscriptions s
       JOIN users target ON target.id = s.target_user_id
       WHERE ${where.join(" AND ")}
       ORDER BY s.updated_at DESC, s.id DESC
       LIMIT $${values.length}`,
      values,
    );
    const hasMore = result.rows.length > limit;
    const rows = result.rows.slice(0, limit);
    const last = rows.at(-1);
    return {
      data: rows.map(mapSubscription),
      hasMore,
      ...(hasMore && last !== undefined
        ? {
            nextCursor: encodeCursor(
              "subscriptions",
              signature,
              isoDate(last.updated_at),
              last.id,
            ),
          }
        : {}),
    };
  }

  async put(
    principal: Principal,
    targetUserId: string,
    input: SubscriptionInput,
    idempotencyKey: string,
    requestId: string,
  ): Promise<MutationResponse<SubscriptionResource>> {
    assertUuid(targetUserId, "targetUserId");
    const settings = subscriptionSettings(input);
    return this.translate(() =>
      executeIdempotentMutation(
        this.database,
        principal,
        "putSubscription",
        idempotencyKey,
        { targetUserId, settings },
        async (queryable) => {
          if (targetUserId === principal.userId) {
            throw unprocessable("A user cannot subscribe to itself.", "self_subscription");
          }
          await requireActivePublicUser(queryable, targetUserId);
          const existing = await loadSubscription(
            queryable,
            principal.userId,
            targetUserId,
            true,
          );
          let status: 200 | 201 = 200;
          if (existing === undefined) {
            status = 201;
            await queryable.query(
              `INSERT INTO subscriptions (
                 id, user_id, target_user_id, include_records, include_events
               ) VALUES ($1, $2, $3, $4, $5)`,
              [randomUUID(), principal.userId, targetUserId, settings.includeRecords, settings.includeEvents],
            );
          } else if (
            existing.deleted_at !== null ||
            existing.include_records !== settings.includeRecords ||
            existing.include_events !== settings.includeEvents
          ) {
            await queryable.query(
              `UPDATE subscriptions SET
                 include_records = $3,
                 include_events = $4,
                 deleted_at = NULL,
                 updated_at = clock_timestamp()
               WHERE user_id = $1 AND target_user_id = $2`,
              [principal.userId, targetUserId, settings.includeRecords, settings.includeEvents],
            );
          }
          const stored = await loadSubscription(queryable, principal.userId, targetUserId, false);
          if (stored === undefined) {
            throw new Error("Subscription could not be reloaded");
          }
          await writeSocialAudit(
            queryable,
            principal,
            "subscription.put",
            stored.id,
            requestId,
          );
          const resource = mapSubscription(stored);
          return {
            status,
            headers: {
              location: `/v1/subscriptions/${targetUserId}`,
              etag: subscriptionEtag(resource.id, resource.revision),
            },
            body: resource,
          };
        },
      ),
    );
  }

  async delete(
    principal: Principal,
    targetUserId: string,
    ifMatch: string,
    idempotencyKey: string,
    requestId: string,
  ): Promise<MutationResponse<null>> {
    assertUuid(targetUserId, "targetUserId");
    return this.translate(() =>
      executeIdempotentMutation(
        this.database,
        principal,
        "deleteSubscription",
        idempotencyKey,
        { targetUserId, ifMatch },
        async (queryable) => {
          const current = await loadSubscription(queryable, principal.userId, targetUserId, true);
          if (current === undefined || current.deleted_at !== null) {
            throw subscriptionNotFound();
          }
          requireMatchingEtag(
            ifMatch,
            subscriptionEtag(current.id, Number(current.revision)),
          );
          await queryable.query(
            `UPDATE subscriptions
             SET deleted_at = clock_timestamp(), updated_at = clock_timestamp()
             WHERE user_id = $1 AND target_user_id = $2`,
            [principal.userId, targetUserId],
          );
          await writeSocialAudit(
            queryable,
            principal,
            "subscription.delete",
            current.id,
            requestId,
          );
          return { status: 204, headers: {}, body: null };
        },
      ),
    );
  }

  private async translate<Result>(work: () => Promise<Result>): Promise<Result> {
    try {
      return await work();
    } catch (error) {
      if (databaseErrorCode(error) !== undefined) {
        translateDatabaseError(error);
      }
      throw error;
    }
  }
}

export class PublicActivityService {
  constructor(private readonly database: Database) {}

  async listPublic(query: PublicActivityQuery): Promise<PublicActivityPage> {
    return this.list(undefined, query);
  }

  async listFollowing(
    principal: Principal,
    query: PublicActivityQuery,
  ): Promise<PublicActivityPage> {
    return this.list(principal.userId, query);
  }

  private async list(
    subscriberUserId: string | undefined,
    query: PublicActivityQuery,
  ): Promise<PublicActivityPage> {
    const limit = parsePageLimit(query.limit);
    const latestSnapshot = query.snapshot === "latest";
    if (latestSnapshot && query.cursor !== undefined) {
      throw invalidRequest("snapshot=latest cannot be combined with a cursor.");
    }
    if (query.userId !== undefined) {
      assertUuid(query.userId, "userId");
    }
    const resourceTypes = normalizeActivityTypes(query.resourceTypes);
    const signature = activitySignature(subscriberUserId, query.userId, resourceTypes);
    const afterSequence = decodeActivityCursor(query.cursor, signature);

    return this.database.transaction(async (queryable) => {
      await queryable.query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY");
      const highResult = await queryable.query<HighWaterRow>(
        "SELECT COALESCE(max(sequence), 0) AS high_water FROM public_activity",
      );
      const highWater = BigInt(highResult.rows[0]?.high_water ?? 0);
      if (afterSequence > highWater) {
        throw invalidRequest("The public activity cursor is ahead of the feed.", "invalid_cursor");
      }

      const sequenceBoundary = latestSnapshot ? highWater : afterSequence;
      const values: unknown[] = [sequenceBoundary.toString(), resourceTypes];
      const joins = [
        "JOIN users actor ON actor.id = activity.actor_user_id",
        `LEFT JOIN records activity_record
           ON activity.resource_type = 'record'
          AND activity_record.id = activity.resource_id`,
      ];
      const where = [
        `activity.sequence ${latestSnapshot ? "<=" : ">"} $1::bigint`,
        "activity.resource_type = ANY($2::text[])",
        "(activity.resource_type <> 'record' OR activity_record.id IS NOT NULL)",
        "(activity.operation = 'delete' OR actor.status = 'active')",
      ];
      if (subscriberUserId !== undefined) {
        values.push(subscriberUserId);
        joins.push(
          `JOIN subscriptions subscription
             ON subscription.user_id = $${values.length}::uuid
            AND subscription.target_user_id = activity.actor_user_id
            AND subscription.deleted_at IS NULL`,
        );
        where.push(
          `((activity.resource_type = 'user')
             OR (activity.resource_type = 'record' AND subscription.include_records)
             OR (activity.resource_type = 'event' AND subscription.include_events))`,
        );
      }
      if (query.userId !== undefined) {
        values.push(query.userId);
        where.push(`activity.actor_user_id = $${values.length}::uuid`);
      }
      values.push(latestSnapshot ? limit : limit + 1);
      const result = await queryable.query<ActivityRow>(
        `SELECT
           activity.sequence,
           activity.published_at,
           activity.actor_user_id,
           actor.login AS actor_login,
           actor.display_name AS actor_display_name,
           activity.resource_type,
           CASE WHEN activity.resource_type = 'record'
             THEN activity_record.public_id
             ELSE activity.resource_id::text
           END AS resource_id,
           activity.operation,
           activity.revision
         FROM public_activity activity
         ${joins.join("\n")}
         WHERE ${where.join(" AND ")}
         ORDER BY activity.sequence ${latestSnapshot ? "DESC" : "ASC"}
         LIMIT $${values.length}`,
        values,
      );
      const hasMore = !latestSnapshot && result.rows.length > limit;
      const rows = latestSnapshot
        ? [...result.rows].reverse()
        : result.rows.slice(0, limit);
      const last = rows.at(-1);
      const nextSequence = !latestSnapshot && hasMore && last !== undefined
        ? BigInt(last.sequence)
        : highWater;
      return {
        data: rows.map(mapActivity),
        nextCursor: encodeActivityCursor(signature, nextSequence),
        hasMore,
      };
    });
  }
}

const SUBSCRIPTION_COLUMNS = `
  s.id,
  s.user_id,
  s.target_user_id,
  target.login AS target_login,
  target.display_name AS target_display_name,
  target.status AS target_status,
  s.include_records,
  s.include_events,
  s.revision,
  s.created_at,
  s.updated_at,
  s.deleted_at
`;

async function loadSubscription(
  queryable: Queryable,
  userId: string,
  targetUserId: string,
  lock: boolean,
): Promise<SubscriptionRow | undefined> {
  const result = await queryable.query<SubscriptionRow>(
    `SELECT ${SUBSCRIPTION_COLUMNS}
     FROM subscriptions s
     JOIN users target ON target.id = s.target_user_id
     WHERE s.user_id = $1 AND s.target_user_id = $2
     ${lock ? "FOR UPDATE OF s" : ""}`,
    [userId, targetUserId],
  );
  return result.rows[0];
}

export async function loadSubscriptionResourcesForSync(
  queryable: Queryable,
  userId: string,
  ids: readonly string[],
): Promise<ReadonlyMap<string, SubscriptionResource>> {
  if (ids.length === 0) {
    return new Map();
  }
  const result = await queryable.query<SubscriptionRow>(
    `SELECT ${SUBSCRIPTION_COLUMNS}
     FROM subscriptions s
     JOIN users target ON target.id = s.target_user_id
     WHERE s.user_id = $1 AND s.id = ANY($2::uuid[]) AND s.deleted_at IS NULL`,
    [userId, ids],
  );
  return new Map(result.rows.map((row) => [row.id, mapSubscription(row)]));
}

function mapSubscription(row: SubscriptionRow): SubscriptionResource {
  return {
    id: row.id,
    userId: row.user_id,
    targetUser: {
      id: row.target_user_id,
      login: row.target_login,
      displayName: row.target_display_name,
      status: row.target_status,
    },
    includeRecords: row.include_records,
    includeEvents: row.include_events,
    revision: Number(row.revision),
    createdAt: isoDate(row.created_at),
    updatedAt: isoDate(row.updated_at),
  };
}

function mapActivity(row: ActivityRow): PublicActivityItem {
  const sequence = Number(row.sequence);
  if (!Number.isSafeInteger(sequence) || sequence < 1) {
    throw new Error("Public activity sequence exceeds JSON's exact integer range");
  }
  return {
    sequence,
    publishedAt: isoDate(row.published_at),
    actor: {
      id: row.actor_user_id,
      login: row.actor_login,
      displayName: row.actor_display_name,
    },
    resourceType: row.resource_type,
    resourceId: row.resource_id,
    operation: row.operation,
    revision: Number(row.revision),
    resourceUrl: row.resource_type === "user"
      ? `/v1/public/users/${encodeURIComponent(row.actor_login)}`
      : `/v1/public/${row.resource_type}s/${row.resource_id}`,
  };
}

function subscriptionSettings(input: SubscriptionInput): {
  readonly includeRecords: boolean;
  readonly includeEvents: boolean;
} {
  const includeRecords = input.includeRecords ?? true;
  const includeEvents = input.includeEvents ?? true;
  if (!includeRecords && !includeEvents) {
    throw unprocessable(
      "At least one of includeRecords or includeEvents must be true.",
      "empty_subscription",
    );
  }
  return { includeRecords, includeEvents };
}

async function requireActivePublicUser(queryable: Queryable, userId: string): Promise<void> {
  const result = await queryable.query(
    "SELECT 1 FROM users WHERE id = $1 AND status = 'active' FOR SHARE",
    [userId],
  );
  if (result.rowCount === 0) {
    throw publicUserNotFound();
  }
}

async function writeSocialAudit(
  queryable: Queryable,
  principal: Principal,
  action: string,
  entityId: string | undefined,
  requestId: string,
): Promise<void> {
  await queryable.query(
    `INSERT INTO audit_log (
       user_id, actor_type, actor_id, action, entity_type, entity_id, request_id
     ) VALUES ($1, $2, $3, $4, 'subscription', $5, $6)`,
    [principal.userId, principal.kind, principal.actorId, action, entityId ?? null, requestId],
  );
}

function normalizeLogin(value: string): string {
  const normalized = value.trim().toLowerCase();
  if (normalized.length < 3 || normalized.length > 64 || !LOGIN_PATTERN.test(normalized)) {
    throw publicUserNotFound();
  }
  return normalized;
}

function normalizeActivityTypes(values: readonly string[] | undefined): readonly PublicActivityResourceType[] {
  if (values === undefined || values.length === 0) {
    return ["user", "record", "event"];
  }
  const selected = new Set<PublicActivityResourceType>();
  for (const value of values) {
    if (value !== "user" && value !== "record" && value !== "event") {
      throw invalidRequest(`Unsupported public activity resourceType: ${value}.`);
    }
    selected.add(value);
  }
  // A cursor that consumes record/event notifications must also consume actor
  // lifecycle controls. Otherwise it could advance beyond a disable event and
  // retain public resources which are no longer visible.
  if (selected.has("record") || selected.has("event")) {
    selected.add("user");
  }
  return ["user", "record", "event"].filter(
    (value): value is PublicActivityResourceType => selected.has(value as PublicActivityResourceType),
  );
}

function activitySignature(
  subscriberUserId: string | undefined,
  userId: string | undefined,
  resourceTypes: readonly PublicActivityResourceType[],
): string {
  return createHash("sha256")
    .update(canonicalJson({ subscriberUserId, userId, resourceTypes }))
    .digest("base64url");
}

function encodeActivityCursor(signature: string, sequence: bigint): string {
  return Buffer.from(JSON.stringify({
    v: 1,
    kind: ACTIVITY_CURSOR_KIND,
    signature,
    sequence: sequence.toString(),
  }), "utf8").toString("base64url");
}

function decodeActivityCursor(value: string | undefined, expectedSignature: string): bigint {
  if (value === undefined) {
    return 0n;
  }
  try {
    if (value.length > 2_048 || !/^[A-Za-z0-9_-]+$/.test(value)) {
      throw new Error("invalid cursor");
    }
    const parsed = JSON.parse(Buffer.from(value, "base64url").toString("utf8")) as Record<string, unknown>;
    if (
      Object.keys(parsed).length !== 4 ||
      parsed.v !== 1 ||
      parsed.kind !== ACTIVITY_CURSOR_KIND ||
      parsed.signature !== expectedSignature ||
      typeof parsed.sequence !== "string" ||
      !/^(?:0|[1-9][0-9]{0,18})$/.test(parsed.sequence)
    ) {
      throw new Error("invalid cursor");
    }
    const sequence = BigInt(parsed.sequence);
    if (sequence > 9_223_372_036_854_775_807n) {
      throw new Error("invalid cursor");
    }
    return sequence;
  } catch {
    throw invalidRequest(
      "The cursor is malformed or does not belong to this public activity query.",
      "invalid_cursor",
    );
  }
}

function subscriptionEtag(id: string, revision: number): string {
  return `"subscription-${id}-r${revision}"`;
}

function safeCount(value: string | number): number {
  const count = Number(value);
  if (!Number.isSafeInteger(count) || count < 0) {
    throw new Error("Public profile count exceeds JSON's exact integer range");
  }
  return count;
}

function assertUuid(value: string, name: string): void {
  if (!UUID_PATTERN.test(value)) {
    throw invalidRequest(`${name} must be a UUID.`);
  }
}

function publicUserNotFound(): HttpProblem {
  return new HttpProblem({
    status: 404,
    code: "public_user_not_found",
    title: "Not Found",
    type: "urn:exeligmos:problem:public-user-not-found",
    detail: "The requested public user does not exist.",
  });
}

function subscriptionNotFound(): HttpProblem {
  return new HttpProblem({
    status: 404,
    code: "subscription_not_found",
    title: "Not Found",
    type: "urn:exeligmos:problem:subscription-not-found",
    detail: "The requested subscription does not exist.",
  });
}

export { PreconditionFailedProblem };
