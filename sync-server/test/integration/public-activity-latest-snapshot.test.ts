import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import path from "node:path";
import test from "node:test";

import Fastify from "fastify";
import { Client } from "pg";

import type { Principal } from "../../src/auth/principal.js";
import { createPostgresDatabase } from "../../src/db/database.js";
import { runMigrations } from "../../src/db/migrate.js";
import { registerProblemHandlers } from "../../src/http/problem.js";
import { NOOP_RESOURCE_REQUEST_LIMITER } from "../../src/resources/rate-limit.js";
import { registerSocialRoutes } from "../../src/routes/social.js";
import { testConfig } from "../helpers.js";

const databaseUrl = process.env.TEST_DATABASE_URL?.trim();

test(
  "latest public and following snapshots anchor live resume without changing default replay",
  { skip: databaseUrl === undefined || databaseUrl.length === 0 },
  async () => {
    assert.ok(databaseUrl);
    await runMigrations({
      databaseUrl,
      directory: path.resolve(process.cwd(), "db/migrations"),
    });
    const base = testConfig();
    const database = createPostgresDatabase({ ...base.database, url: databaseUrl });
    const sql = new Client({ connectionString: databaseUrl });
    await sql.connect();

    const followerId = randomUUID();
    const targetId = randomUUID();
    const targetDeviceId = randomUUID();
    const principal: Principal = {
      kind: "jwt",
      userId: followerId,
      actorId: randomUUID(),
      scopes: new Set(),
    };
    const app = Fastify({ logger: false });
    registerProblemHandlers(app);
    await app.register(registerSocialRoutes, {
      database,
      authenticator: { async authenticate() { return principal; } },
      requestLimiter: NOOP_RESOURCE_REQUEST_LIMITER,
    });
    await app.ready();

    try {
      await sql.query(
        `INSERT INTO users (id, login, display_name, password_hash)
         VALUES ($1, $2, 'Follower', 'test'), ($3, $4, 'Sun', 'test')`,
        [
          followerId,
          `snapshot-follower-${randomUUID()}`,
          targetId,
          `snapshot-sun-${randomUUID()}`,
        ],
      );
      await sql.query(
        `INSERT INTO devices (id, user_id, name, kind)
         VALUES ($1, $2, 'Sun agent', 'agent')`,
        [targetDeviceId, targetId],
      );
      await sql.query(
        `INSERT INTO subscriptions (user_id, target_user_id)
         VALUES ($1, $2)`,
        [followerId, targetId],
      );
      await sql.query(
        `INSERT INTO records (id, user_id, device_id, event_at, public_payload)
         VALUES ($1, $2, $3, now() - interval '2 hours', '{"text":"first"}'::jsonb)`,
        [randomUUID(), targetId, targetDeviceId],
      );
      await sql.query(
        `INSERT INTO events (id, user_id, device_id, starts_at, label, type)
         VALUES ($1, $2, $3, now() - interval '1 hour', 'Middle event', 1)`,
        [randomUUID(), targetId, targetDeviceId],
      );
      await sql.query(
        `INSERT INTO records (id, user_id, device_id, event_at, public_payload)
         VALUES ($1, $2, $3, now(), '{"text":"latest"}'::jsonb)`,
        [randomUUID(), targetId, targetDeviceId],
      );

      const initialSequences = await actorSequences(sql, targetId);
      assert.ok(initialSequences.length >= 4);

      const oldest = await app.inject({
        method: "GET",
        url: `/v1/public/activity?userId=${targetId}&limit=1`,
      });
      assert.equal(oldest.statusCode, 200, oldest.body);
      assert.deepEqual(oldest.json<ActivityPage>().data.map((item) => item.sequence), [
        required(initialSequences[0]),
      ]);
      assert.equal(oldest.json<ActivityPage>().hasMore, true);

      const latest = await app.inject({
        method: "GET",
        url: `/v1/public/activity?userId=${targetId}&snapshot=latest&limit=2`,
      });
      assert.equal(latest.statusCode, 200, latest.body);
      const latestPage = latest.json<ActivityPage>();
      assert.equal(latestPage.hasMore, false);
      assert.deepEqual(
        latestPage.data.map((item) => item.sequence),
        initialSequences.slice(-2),
      );
      assertAscending(latestPage.data);

      const conflicting = await app.inject({
        method: "GET",
        url: `/v1/public/activity?userId=${targetId}&snapshot=latest&cursor=${encodeURIComponent(latestPage.nextCursor)}`,
      });
      assert.equal(conflicting.statusCode, 400, conflicting.body);
      assert.equal(conflicting.json().code, "invalid_request");

      const unsupported = await app.inject({
        method: "GET",
        url: `/v1/public/activity?userId=${targetId}&snapshot=oldest`,
      });
      assert.equal(unsupported.statusCode, 400, unsupported.body);
      assert.equal(unsupported.json().code, "validation_error");

      const liveEventId = randomUUID();
      await sql.query(
        `INSERT INTO events (id, user_id, device_id, starts_at, label, type)
         VALUES ($1, $2, $3, now(), 'Live event', 2)`,
        [liveEventId, targetId, targetDeviceId],
      );
      const publicResume = await app.inject({
        method: "GET",
        url: `/v1/public/activity?userId=${targetId}&cursor=${encodeURIComponent(latestPage.nextCursor)}`,
      });
      assert.equal(publicResume.statusCode, 200, publicResume.body);
      const publicResumePage = publicResume.json<ActivityPage>();
      assert.deepEqual(publicResumePage.data.map((item) => item.resourceId), [liveEventId]);

      const following = await app.inject({
        method: "GET",
        url: "/v1/activity?snapshot=latest&limit=2",
      });
      assert.equal(following.statusCode, 200, following.body);
      const followingPage = following.json<ActivityPage>();
      assert.equal(followingPage.hasMore, false);
      assert.equal(followingPage.data.length, 2);
      assertAscending(followingPage.data);
      assert.ok(followingPage.data.every((item) => item.actor.id === targetId));

      const liveRecordId = randomUUID();
      await sql.query(
        `INSERT INTO records (id, user_id, device_id, event_at, public_payload)
         VALUES ($1, $2, $3, now(), '{"text":"live"}'::jsonb)`,
        [liveRecordId, targetId, targetDeviceId],
      );
      const followingResume = await app.inject({
        method: "GET",
        url: `/v1/activity?cursor=${encodeURIComponent(followingPage.nextCursor)}`,
      });
      assert.equal(followingResume.statusCode, 200, followingResume.body);
      assert.deepEqual(
        followingResume.json<ActivityPage>().data.map((item) => item.resourceId),
        [liveRecordId],
      );
    } finally {
      try {
        await sql.query("DELETE FROM users WHERE id = ANY($1::uuid[])", [
          [followerId, targetId],
        ]);
      } finally {
        await app.close();
        await sql.end();
        await database.close();
      }
    }
  },
);

interface ActivityItem {
  readonly sequence: number;
  readonly actor: { readonly id: string };
  readonly resourceId: string;
}

interface ActivityPage {
  readonly data: readonly ActivityItem[];
  readonly nextCursor: string;
  readonly hasMore: boolean;
}

async function actorSequences(sql: Client, userId: string): Promise<number[]> {
  const result = await sql.query<{ sequence: string }>(
    `SELECT sequence::text
     FROM public_activity
     WHERE actor_user_id = $1
     ORDER BY sequence ASC`,
    [userId],
  );
  return result.rows.map((row) => Number(row.sequence));
}

function assertAscending(items: readonly ActivityItem[]): void {
  for (let index = 1; index < items.length; index += 1) {
    assert.ok(
      required(items[index - 1]).sequence < required(items[index]).sequence,
      "activity items must remain in canonical ascending sequence order",
    );
  }
}

function required<Value>(value: Value | undefined): Value {
  if (value === undefined) {
    throw new Error("Expected value");
  }
  return value;
}
