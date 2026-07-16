import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import path from "node:path";
import test from "node:test";

import { Client } from "pg";

import type { Principal } from "../../src/auth/principal.js";
import { createPostgresDatabase } from "../../src/db/database.js";
import { runMigrations } from "../../src/db/migrate.js";
import { HttpProblem } from "../../src/http/problem.js";
import { type SyncBatchInput, SyncService } from "../../src/resources/sync.js";
import { testConfig } from "../helpers.js";

const databaseUrl = process.env.TEST_DATABASE_URL?.trim();

test(
  "sync batches are item-idempotent and the ordered feed is tenant, filter, and retention bound",
  { skip: databaseUrl === undefined || databaseUrl.length === 0 },
  async () => {
    assert.ok(databaseUrl);
    await runMigrations({
      databaseUrl,
      directory: path.resolve(process.cwd(), "db/migrations"),
    });
    const sql = new Client({ connectionString: databaseUrl });
    await sql.connect();
    const baseConfig = testConfig();
    const database = createPostgresDatabase({
      ...baseConfig.database,
      url: databaseUrl,
    });
    const service = new SyncService(database);
    const userIds: string[] = [];

    try {
      const owner = await createOwner(sql, `sync-${randomUUID()}`);
      const other = await createOwner(sql, `sync-other-${randomUUID()}`);
      userIds.push(owner.userId, other.userId);
      const principal = jwtPrincipal(owner.userId, owner.deviceId);
      const otherPrincipal = jwtPrincipal(other.userId, other.deviceId);
      const eventId = randomUUID();
      const createAndFail: SyncBatchInput = {
        deviceId: owner.deviceId,
        mutations: [
          {
            kind: "upsertEvent",
            clientMutationId: "sync-event-create-1",
            event: {
              id: eventId,
              deviceId: owner.deviceId,
              startsAt: "2026-07-15T01:00:00Z",
              label: "First sync event",
              type: 1001,
              metadata: { source: "sync-test" },
            },
          },
          {
            kind: "upsertEvent",
            clientMutationId: "sync-event-missing-etag-1",
            event: {
              id: eventId,
              deviceId: owner.deviceId,
              startsAt: "2026-07-15T01:05:00Z",
              label: "Must not replace",
              type: 1002,
            },
          },
        ],
      };

      const first = await service.applyBatch(
        principal,
        createAndFail,
        "sync-batch-first-1",
        "sync-request-first",
      );
      assert.equal(first.status, 200);
      assert.equal(first.body.results[0]?.status, "succeeded");
      assert.equal(first.body.results[0]?.revision, 1);
      assert.equal(first.body.results[1]?.status, "failed");
      assert.equal(first.body.results[1]?.problem?.code, "if_match_required");

      const outerReplay = await service.applyBatch(
        principal,
        createAndFail,
        "sync-batch-first-1",
        "sync-request-outer-replay",
      );
      assert.equal(outerReplay.replayed, true);
      assert.deepEqual(outerReplay.body, first.body);

      const itemReplay = await service.applyBatch(
        principal,
        createAndFail,
        "sync-batch-item-replay-1",
        "sync-request-item-replay",
      );
      assert.deepEqual(itemReplay.body, first.body);
      const eventCount = await sql.query<{ count: string }>(
        "SELECT count(*)::text AS count FROM events WHERE user_id = $1 AND id = $2",
        [owner.userId, eventId],
      );
      assert.equal(eventCount.rows[0]?.count, "1");

      const tagId = randomUUID();
      const templateId = randomUUID();
      const recordId = randomUUID();
      const catalogBatch = await service.applyBatch(
        principal,
        {
          deviceId: owner.deviceId,
          atomic: true,
          mutations: [
            {
              kind: "upsertTag",
              clientMutationId: "sync-tag-create-1",
              tag: { id: tagId, name: "Sync catalog", sortOrder: 10 },
            },
            {
              kind: "upsertTemplate",
              clientMutationId: "sync-template-create-1",
              template: {
                id: templateId,
                name: "Sync template",
                engine: "mustache",
                body: { text: "Observed {{value}}" },
                variableSchema: {
                  type: "object",
                  properties: { value: { type: "string" } },
                  additionalProperties: false,
                },
              },
            },
            {
              kind: "upsertRecord",
              clientMutationId: "sync-record-create-1",
              record: {
                id: recordId,
                deviceId: owner.deviceId,
                occurredAt: "2026-07-15T01:30:00Z",
                payload: { text: "Catalog-linked record" },
                tagIds: [tagId],
              },
            },
          ],
        },
        "sync-catalog-batch-1",
        "sync-request-catalog",
      );
      assert.deepEqual(
        catalogBatch.body.results.map((result) => [
          result.resourceType,
          result.status,
        ]),
        [
          ["tag", "succeeded"],
          ["template", "succeeded"],
          ["record", "succeeded"],
        ],
      );

      const authoritativeRecordUpsert = await service.applyBatch(
        principal,
        {
          deviceId: owner.deviceId,
          mutations: [
            {
              kind: "upsertRecord",
              clientMutationId: "sync-record-authoritative-upsert-1",
              record: {
                id: recordId,
                deviceId: owner.deviceId,
                occurredAt: "2026-07-14T23:00:00Z",
                payload: { text: "Local client is authoritative" },
                tagIds: [tagId],
              },
            },
          ],
        },
        "sync-record-authoritative-batch-1",
        "sync-record-authoritative-request",
      );
      assert.equal(
        authoritativeRecordUpsert.body.results[0]?.status,
        "succeeded",
      );
      const overwrittenRecord = await sql.query<{
        event_at: Date;
        public_payload: { readonly text?: string };
      }>(
        "SELECT event_at, public_payload FROM records WHERE user_id = $1 AND id = $2",
        [owner.userId, recordId],
      );
      assert.equal(
        overwrittenRecord.rows[0]?.public_payload.text,
        "Local client is authoritative",
      );
      assert.equal(
        overwrittenRecord.rows[0]?.event_at.toISOString(),
        "2026-07-14T23:00:00.000Z",
      );

      const catalogFeed = await service.listChanges(principal, {
        resourceTypes: ["tag", "template", "record"],
      });
      assert.deepEqual(
        new Set(
          catalogFeed.data.map(
            (change) => `${change.resourceType}:${change.resourceId}`,
          ),
        ),
        new Set([
          `tag:${tagId}`,
          `template:${templateId}`,
          `record:${recordId}`,
        ]),
      );

      const atomicEventId = randomUUID();
      const atomicMutationId = "sync-atomic-event-create-1";
      await assert.rejects(
        () =>
          service.applyBatch(
            principal,
            {
              deviceId: owner.deviceId,
              atomic: true,
              mutations: [
                {
                  kind: "upsertEvent",
                  clientMutationId: atomicMutationId,
                  event: {
                    id: atomicEventId,
                    deviceId: owner.deviceId,
                    startsAt: "2026-07-15T02:00:00Z",
                    label: "Rolled back event",
                    type: 7,
                  },
                },
                {
                  kind: "delete",
                  clientMutationId: "sync-atomic-missing-delete-1",
                  resourceType: "record",
                  resourceId: randomUUID(),
                  ifMatch: `"record-${randomUUID()}-r1"`,
                },
              ],
            },
            "sync-atomic-batch-1",
            "sync-request-atomic",
          ),
        (error: unknown) =>
          error instanceof HttpProblem &&
          error.status === 409 &&
          error.code === "atomic_sync_batch_failed",
      );
      const atomicState = await sql.query<{
        event_count: string;
        receipt_count: string;
      }>(
        `SELECT
           (SELECT count(*) FROM events WHERE user_id = $1 AND id = $2)::text AS event_count,
           (SELECT count(*) FROM sync_mutation_receipts
             WHERE user_id = $1 AND client_mutation_id = $3)::text AS receipt_count`,
        [owner.userId, atomicEventId, atomicMutationId],
      );
      assert.deepEqual(atomicState.rows[0], {
        event_count: "0",
        receipt_count: "0",
      });

      const firstPage = await service.listChanges(principal, {
        resourceTypes: ["event"],
        limit: 1,
      });
      assert.equal(firstPage.data.length, 1);
      assert.equal(firstPage.data[0]?.resourceType, "event");
      assert.equal(firstPage.data[0]?.operation, "upsert");
      assert.equal(firstPage.data[0]?.resourceId, eventId);
      assert.equal(firstPage.data[0]?.revision, 1);

      const otherFeed = await service.listChanges(otherPrincipal, {
        resourceTypes: ["event"],
      });
      assert.deepEqual(otherFeed.data, []);
      await assert.rejects(
        () =>
          service.listChanges(otherPrincipal, {
            resourceTypes: ["event"],
            cursor: firstPage.nextCursor,
          }),
        isInvalidCursor,
      );
      await assert.rejects(
        () =>
          service.listChanges(principal, {
            resourceTypes: ["record"],
            cursor: firstPage.nextCursor,
          }),
        isInvalidCursor,
      );

      const replacement = await service.applyBatch(
        principal,
        {
          deviceId: owner.deviceId,
          mutations: [
            {
              kind: "upsertEvent",
              clientMutationId: "sync-event-replace-1",
              ifMatch: `"event-${eventId}-r1"`,
              event: {
                id: eventId,
                deviceId: owner.deviceId,
                startsAt: "2026-07-15T01:10:00Z",
                label: "Replaced sync event",
                type: 1003,
                metadata: { replacement: true },
              },
            },
          ],
        },
        "sync-batch-replace-1",
        "sync-request-replace",
      );
      assert.equal(replacement.body.results[0]?.revision, 2);
      const replacementPage = await service.listChanges(principal, {
        resourceTypes: ["event"],
        cursor: firstPage.nextCursor,
      });
      assert.equal(replacementPage.data.length, 1);
      assert.equal(replacementPage.data[0]?.operation, "upsert");
      assert.equal(replacementPage.data[0]?.revision, 2);

      const deletion = await service.applyBatch(
        principal,
        {
          deviceId: owner.deviceId,
          mutations: [
            {
              kind: "delete",
              clientMutationId: "sync-event-delete-1",
              resourceType: "event",
              resourceId: eventId,
              ifMatch: `"event-${eventId}-r2"`,
            },
          ],
        },
        "sync-batch-delete-1",
        "sync-request-delete",
      );
      assert.equal(deletion.body.results[0]?.revision, 3);
      const deletionPage = await service.listChanges(principal, {
        resourceTypes: ["event"],
        cursor: replacementPage.nextCursor,
      });
      assert.equal(deletionPage.data.length, 1);
      assert.equal(deletionPage.data[0]?.operation, "delete");
      assert.equal(deletionPage.data[0]?.revision, 3);
      assert.equal(deletionPage.data[0]?.resource, undefined);
      assert.equal(deletionPage.data[0]?.tombstone?.resourceType, "event");

      const retainedCursor = deletionPage.nextCursor;
      const prunedEventId = randomUUID();
      await service.applyBatch(
        principal,
        {
          deviceId: owner.deviceId,
          mutations: [
            {
              kind: "upsertEvent",
              clientMutationId: "sync-event-pruned-1",
              event: {
                id: prunedEventId,
                deviceId: owner.deviceId,
                startsAt: "2026-07-15T03:00:00Z",
                label: "Pruned sync event change",
                type: 8,
              },
            },
          ],
        },
        "sync-batch-pruned-1",
        "sync-request-pruned",
      );
      await sql.query(
        "DELETE FROM change_log WHERE user_id = $1 AND entity_type = 'event' AND entity_id = $2",
        [owner.userId, prunedEventId],
      );
      await assert.rejects(
        () =>
          service.listChanges(principal, {
            resourceTypes: ["event"],
            cursor: retainedCursor,
          }),
        (error: unknown) =>
          error instanceof HttpProblem &&
          error.status === 410 &&
          error.code === "cursor_expired",
      );
    } finally {
      await database.close();
      if (userIds.length > 0) {
        await sql.query("DELETE FROM users WHERE id = ANY($1::uuid[])", [
          userIds,
        ]);
      }
      await sql.end();
    }
  },
);

async function createOwner(
  sql: Client,
  login: string,
): Promise<{ readonly userId: string; readonly deviceId: string }> {
  const user = await sql.query<{ id: string }>(
    `INSERT INTO users (login, display_name, password_hash)
     VALUES ($1, $1, 'unused-in-sync-test')
     RETURNING id`,
    [login],
  );
  const userId = user.rows[0]?.id;
  assert.ok(userId);
  const device = await sql.query<{ id: string }>(
    `INSERT INTO devices (user_id, name, kind)
     VALUES ($1, 'Sync test device', 'ios')
     RETURNING id`,
    [userId],
  );
  const deviceId = device.rows[0]?.id;
  assert.ok(deviceId);
  return { userId, deviceId };
}

function jwtPrincipal(userId: string, deviceId: string): Principal {
  return {
    kind: "jwt",
    userId,
    actorId: randomUUID(),
    deviceId,
    scopes: new Set(),
  };
}

function isInvalidCursor(error: unknown): boolean {
  return (
    error instanceof HttpProblem &&
    error.status === 400 &&
    error.code === "invalid_cursor"
  );
}
