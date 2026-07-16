import assert from "node:assert/strict";
import test from "node:test";

import type { QueryResultRow } from "pg";

import type {
  Database,
  DatabaseReadiness,
  DatabaseResult,
  Queryable,
} from "../src/db/database.js";
import { normalizeReferences } from "../src/resources/references.js";
import {
  loadSubscriptionResourcesForSync,
  PublicActivityService,
  PublicProfileService,
} from "../src/resources/social.js";

const userId = "e42b4fde-8baf-4b95-8bc8-5395b68d0dd2";
const recordId = "2ea5377d-6251-459d-9f6e-3f48e07763a1";
const eventId = "20a78723-c33e-4794-a036-5da69a15e8bf";

test("typed references default their relation and reject ambiguous user targets", () => {
  assert.deepEqual(
    normalizeReferences([{ targetType: "user", targetUserId: userId, targetId: userId }]),
    [{ relation: "reference", targetType: "user", targetUserId: userId, targetId: userId }],
  );
  assert.throws(
    () => normalizeReferences([{ targetType: "user", targetUserId: userId, targetId: recordId }]),
    (error: unknown) => problemCode(error) === "invalid_references",
  );
  assert.throws(
    () => normalizeReferences([
      { relation: "mentions", targetType: "record", targetUserId: userId, targetId: recordId },
      { relation: "mentions", targetType: "record", targetUserId: userId, targetId: recordId },
    ]),
    (error: unknown) => problemCode(error) === "invalid_references",
  );
});

test("public profile lookup exposes only stable public projection and counts", async () => {
  const database = new ScriptedDatabase([
    {
      rows: [{
        id: userId,
        login: "sun",
        display_name: "Sun",
        created_at: "2026-07-15T00:00:00Z",
        public_record_count: "4",
        public_event_count: "7",
        follower_count: "2",
      }],
      rowCount: 1,
    },
  ]);
  const profile = await new PublicProfileService(database).getByLogin("SUN");
  assert.deepEqual(profile, {
    id: userId,
    login: "sun",
    displayName: "Sun",
    createdAt: "2026-07-15T00:00:00.000Z",
    publicRecordCount: 4,
    publicEventCount: 7,
    followerCount: 2,
  });
  assert.match(database.queries[0]?.text ?? "", /u\.status = 'active'/);
  assert.equal(JSON.stringify(profile).includes("password"), false);
});

test("public activity advances a durable high-water cursor without embedding payloads", async () => {
  const database = new ScriptedDatabase([
    { rows: [], rowCount: 0 },
    { rows: [{ high_water: "12" }], rowCount: 1 },
    {
      rows: [{
        sequence: "11",
        published_at: "2026-07-15T10:00:00Z",
        actor_user_id: userId,
        actor_login: "sun",
        actor_display_name: "Sun",
        resource_type: "record",
        resource_id: recordId,
        operation: "upsert",
        revision: "3",
      }],
      rowCount: 1,
    },
  ]);
  const page = await new PublicActivityService(database).listPublic({ limit: 10 });
  assert.equal(page.hasMore, false);
  assert.equal(page.data[0]?.resourceUrl, `/v1/public/records/${recordId}`);
  assert.equal("payload" in (page.data[0] ?? {}), false);
  assert.ok(page.nextCursor.length > 10);
  assert.match(database.queries[2]?.text ?? "", /ORDER BY activity\.sequence ASC/);
});

test("latest activity snapshot returns the newest window in canonical order and resumes live", async () => {
  const database = new ScriptedDatabase([
    { rows: [], rowCount: 0 },
    { rows: [{ high_water: "15" }], rowCount: 1 },
    {
      rows: [
        activityRow("14", "record", recordId),
        activityRow("13", "event", eventId),
      ],
      rowCount: 2,
    },
    { rows: [], rowCount: 0 },
    { rows: [{ high_water: "16" }], rowCount: 1 },
    {
      rows: [activityRow("16", "event", eventId)],
      rowCount: 1,
    },
  ]);
  const service = new PublicActivityService(database);

  const snapshot = await service.listPublic({
    limit: 2,
    resourceTypes: ["record", "event"],
    snapshot: "latest",
  });

  assert.deepEqual(snapshot.data.map((item) => item.sequence), [13, 14]);
  assert.equal(snapshot.hasMore, false);
  assert.match(database.queries[2]?.text ?? "", /activity\.sequence <= \$1::bigint/);
  assert.match(database.queries[2]?.text ?? "", /ORDER BY activity\.sequence DESC/);
  assert.equal(database.queries[2]?.values?.at(-1), 2);

  const resumed = await service.listPublic({
    cursor: snapshot.nextCursor,
    limit: 2,
    resourceTypes: ["record", "event"],
  });

  assert.deepEqual(resumed.data.map((item) => item.sequence), [16]);
  assert.equal(resumed.hasMore, false);
  assert.equal(database.queries[5]?.values?.[0], "15");
  assert.match(database.queries[5]?.text ?? "", /ORDER BY activity\.sequence ASC/);

  await assert.rejects(
    service.listPublic({ cursor: snapshot.nextCursor, snapshot: "latest" }),
    (error: unknown) => problemCode(error) === "invalid_request",
  );
});

test("sync retains subscriptions when the target user is disabled", async () => {
  const subscriptionId = "f8c788f6-95e5-4c4f-b5f7-03a32d05917d";
  const database = new ScriptedDatabase([{
    rows: [{
      id: subscriptionId,
      user_id: userId,
      target_user_id: "0a391589-b751-4196-a922-e4df3bf1b80b",
      target_login: "sun",
      target_display_name: "Sun",
      target_status: "disabled",
      include_records: true,
      include_events: false,
      revision: "2",
      created_at: "2026-07-15T00:00:00Z",
      updated_at: "2026-07-15T01:00:00Z",
      deleted_at: null,
    }],
    rowCount: 1,
  }]);

  const resources = await loadSubscriptionResourcesForSync(
    database,
    userId,
    [subscriptionId],
  );

  assert.equal(resources.get(subscriptionId)?.targetUser.status, "disabled");
  assert.doesNotMatch(database.queries[0]?.text ?? "", /target\.status = 'active'/);
});

class ScriptedDatabase implements Database {
  readonly queries: Array<{ readonly text: string; readonly values?: readonly unknown[] }> = [];

  constructor(private readonly results: DatabaseResult<QueryResultRow>[]) {}

  async checkReadiness(): Promise<DatabaseReadiness> {
    return { ready: true, database: "up", pgvector: "up", latencyMs: 0 };
  }

  async query<Row extends QueryResultRow = QueryResultRow>(
    text: string,
    values?: readonly unknown[],
  ): Promise<DatabaseResult<Row>> {
    this.queries.push({ text, ...(values === undefined ? {} : { values }) });
    const result = this.results.shift();
    if (result === undefined) {
      throw new Error(`Unexpected query: ${text}`);
    }
    return result as DatabaseResult<Row>;
  }

  async transaction<Result>(work: (client: Queryable) => Promise<Result>): Promise<Result> {
    return work(this);
  }

  async close(): Promise<void> {}
}

function problemCode(error: unknown): unknown {
  return typeof error === "object" && error !== null && "code" in error ? error.code : undefined;
}

function activityRow(
  sequence: string,
  resourceType: "record" | "event",
  resourceId: string,
): QueryResultRow {
  return {
    sequence,
    published_at: "2026-07-15T10:00:00Z",
    actor_user_id: userId,
    actor_login: "sun",
    actor_display_name: "Sun",
    resource_type: resourceType,
    resource_id: resourceId,
    operation: "upsert",
    revision: "1",
  };
}
