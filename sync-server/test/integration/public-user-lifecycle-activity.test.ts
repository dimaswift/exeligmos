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
import { registerRecordRoutes } from "../../src/routes/records.js";
import { registerSocialRoutes } from "../../src/routes/social.js";
import { testConfig } from "../helpers.js";

const databaseUrl = process.env.TEST_DATABASE_URL?.trim();

test(
  "disable and re-enable emit durable user controls through record-filtered cursors",
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
    const targetLogin = `sun-${randomUUID()}`;
    const principal: Principal = {
      kind: "jwt",
      userId: followerId,
      actorId: randomUUID(),
      scopes: new Set(),
    };
    const app = Fastify({ logger: false });
    registerProblemHandlers(app);
    const options = {
      database,
      authenticator: { async authenticate() { return principal; } },
      requestLimiter: NOOP_RESOURCE_REQUEST_LIMITER,
    };
    await app.register(registerRecordRoutes, options);
    await app.register(registerSocialRoutes, options);
    await app.ready();

    try {
      await sql.query(
        `INSERT INTO users (id, login, display_name, password_hash)
         VALUES ($1, $2, 'Follower', 'test'), ($3, $4, 'Sun', 'test')`,
        [followerId, `follower-${randomUUID()}`, targetId, targetLogin],
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
      const createdRecord = await sql.query<{ public_id: string }>(
        `INSERT INTO records (user_id, device_id, event_at, public_payload)
         VALUES ($1, $2, now(), '{"text":"public solar activity"}'::jsonb)
         RETURNING public_id`,
        [targetId, targetDeviceId],
      );
      const recordId = required(createdRecord.rows[0]?.public_id);

      const initial = await app.inject({
        method: "GET",
        url: "/v1/activity?resourceType=record",
      });
      assert.equal(initial.statusCode, 200, initial.body);
      const initialCursor = required(initial.json().nextCursor as string | undefined);

      await sql.query(
        `UPDATE users
         SET status = 'disabled', disabled_at = clock_timestamp()
         WHERE id = $1`,
        [targetId],
      );

      const disabled = await app.inject({
        method: "GET",
        url: `/v1/activity?resourceType=record&cursor=${encodeURIComponent(initialCursor)}`,
      });
      assert.equal(disabled.statusCode, 200, disabled.body);
      assert.deepEqual(disabled.json().data, [{
        sequence: disabled.json().data[0]?.sequence,
        publishedAt: disabled.json().data[0]?.publishedAt,
        actor: { id: targetId, login: targetLogin, displayName: "Sun", sarosAnchor: 141 },
        resourceType: "user",
        resourceId: targetId,
        operation: "delete",
        revision: 2,
        resourceUrl: `/v1/public/users/${targetLogin}`,
      }]);
      assert.ok(Number.isSafeInteger(disabled.json().data[0]?.sequence));
      assert.match(disabled.json().data[0]?.publishedAt ?? "", /^\d{4}-\d{2}-\d{2}T/);
      assert.equal("payload" in disabled.json().data[0], false);
      assert.equal((await app.inject({
        method: "GET",
        url: `/v1/public/users/${targetLogin}`,
      })).statusCode, 404);
      assert.equal((await app.inject({
        method: "GET",
        url: `/v1/public/records/${recordId}`,
      })).statusCode, 404);

      const disabledCursor = required(disabled.json().nextCursor as string | undefined);
      await sql.query(
        `UPDATE users SET status = 'active', disabled_at = NULL WHERE id = $1`,
        [targetId],
      );

      const restored = await app.inject({
        method: "GET",
        url: `/v1/activity?resourceType=record&cursor=${encodeURIComponent(disabledCursor)}`,
      });
      assert.equal(restored.statusCode, 200, restored.body);
      assert.equal(restored.json().data.length, 1);
      assert.equal(restored.json().data[0]?.resourceType, "user");
      assert.equal(restored.json().data[0]?.resourceId, targetId);
      assert.equal(restored.json().data[0]?.operation, "upsert");
      assert.equal(restored.json().data[0]?.revision, 3);
      assert.equal(restored.json().data[0]?.resourceUrl, `/v1/public/users/${targetLogin}`);
      assert.equal((await app.inject({
        method: "GET",
        url: `/v1/public/users/${targetLogin}`,
      })).statusCode, 200);
      assert.equal((await app.inject({
        method: "GET",
        url: `/v1/public/records/${recordId}`,
      })).statusCode, 200);
    } finally {
      try {
        await sql.query("DELETE FROM users WHERE id = ANY($1::uuid[])", [[followerId, targetId]]);
      } finally {
        await app.close();
        await sql.end();
        await database.close();
      }
    }
  },
);

function required(value: string | undefined): string {
  if (value === undefined) {
    throw new Error("Expected value");
  }
  return value;
}
