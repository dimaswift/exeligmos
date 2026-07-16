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
import { registerEventRoutes } from "../../src/routes/events.js";
import { registerRecordRoutes } from "../../src/routes/records.js";
import { registerSocialRoutes } from "../../src/routes/social.js";
import { loadSubscriptionResourcesForSync } from "../../src/resources/social.js";
import { testConfig } from "../helpers.js";

const databaseUrl = process.env.TEST_DATABASE_URL?.trim();

test(
  "public profiles, subscriptions, references, public events, and activity preserve privacy",
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

    const ownerId = randomUUID();
    const sunId = randomUUID();
    const ownerDeviceId = randomUUID();
    const sunDeviceId = randomUUID();
    const principal: Principal = {
      kind: "jwt",
      userId: ownerId,
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
    await app.register(registerEventRoutes, options);
    await app.register(registerSocialRoutes, options);
    await app.ready();

    try {
      await sql.query(
        `INSERT INTO users (id, login, display_name, password_hash)
         VALUES ($1, $2, 'Owner', 'test'), ($3, $4, 'Sun', 'test')`,
        [ownerId, `owner-${randomUUID()}`, sunId, `sun-${randomUUID()}`],
      );
      await sql.query(
        `INSERT INTO devices (id, user_id, name, kind)
         VALUES ($1, $2, 'Owner web', 'web'), ($3, $4, 'Sun agent', 'agent')`,
        [ownerDeviceId, ownerId, sunDeviceId, sunId],
      );
      const tag = await sql.query<{ id: string }>(
        `INSERT INTO tags (user_id, name, emoji, color)
         VALUES ($1, 'Solar flare', '☀️', '#FFAA00') RETURNING id`,
        [sunId],
      );
      const sunRecord = await sql.query<{ id: string }>(
        `INSERT INTO records (user_id, device_id, event_at, public_payload)
         VALUES ($1, $2, now(), '{"text":"X flare"}'::jsonb) RETURNING id`,
        [sunId, sunDeviceId],
      );
      const sunRecordId = required(sunRecord.rows[0]?.id);
      await sql.query(
        "INSERT INTO record_tags (user_id, record_id, tag_id) VALUES ($1, $2, $3)",
        [sunId, sunRecordId, required(tag.rows[0]?.id)],
      );
      const sunEvent = await sql.query<{ id: string }>(
        `INSERT INTO events (user_id, device_id, starts_at, label, type)
         VALUES ($1, $2, now(), 'Solar flare', 1001) RETURNING id`,
        [sunId, sunDeviceId],
      );
      const sunEventId = required(sunEvent.rows[0]?.id);
      const privateSunEvent = await sql.query<{ id: string }>(
        `INSERT INTO events (user_id, device_id, visibility, starts_at, label, type)
         VALUES ($1, $2, 'private', now(), 'Internal forecast', 1002) RETURNING id`,
        [sunId, sunDeviceId],
      );

      const sunLogin = (await sql.query<{ login: string }>(
        "SELECT login FROM users WHERE id = $1",
        [sunId],
      )).rows[0]?.login;
      const profile = await app.inject({ method: "GET", url: `/v1/public/users/${sunLogin}` });
      assert.equal(profile.statusCode, 200, profile.body);
      assert.equal(profile.json().publicRecordCount, 1);
      assert.equal(profile.json().publicEventCount, 1);

      const publicRecord = await app.inject({
        method: "GET",
        url: `/v1/public/records/${sunRecordId}`,
      });
      assert.equal(publicRecord.statusCode, 200, publicRecord.body);
      assert.equal(publicRecord.json().author.id, sunId);
      assert.equal(publicRecord.json().tags[0]?.name, "Solar flare");
      assert.equal("deviceId" in publicRecord.json(), false);

      const publicEvent = await app.inject({
        method: "GET",
        url: `/v1/public/events/${sunEventId}`,
      });
      assert.equal(publicEvent.statusCode, 200, publicEvent.body);
      assert.equal(publicEvent.json().author.id, sunId);
      assert.equal("deviceId" in publicEvent.json(), false);
      assert.equal((await app.inject({
        method: "GET",
        url: `/v1/public/events/${required(privateSunEvent.rows[0]?.id)}`,
      })).statusCode, 404);

      const subscribed = await app.inject({
        method: "PUT",
        url: `/v1/subscriptions/${sunId}`,
        headers: { "idempotency-key": `subscribe-${randomUUID()}` },
        payload: { includeRecords: true, includeEvents: true },
      });
      assert.equal(subscribed.statusCode, 201, subscribed.body);
      assert.equal(subscribed.json().targetUser.id, sunId);
      assert.equal(subscribed.json().targetUser.status, "active");

      const following = await app.inject({ method: "GET", url: "/v1/activity" });
      assert.equal(following.statusCode, 200, following.body);
      assert.deepEqual(
        new Set(following.json().data.map((item: { resourceType: string }) => item.resourceType)),
        new Set(["user", "record", "event"]),
      );
      assert.ok(following.json().data.every((item: object) => !("payload" in item)));

      const referenced = await app.inject({
        method: "POST",
        url: "/v1/records",
        headers: { "idempotency-key": `reference-${randomUUID()}` },
        payload: {
          deviceId: ownerDeviceId,
          occurredAt: new Date().toISOString(),
          payload: { text: "Solar response" },
          references: [
            { targetType: "user", targetUserId: sunId, targetId: sunId },
            { relation: "mentions", targetType: "record", targetUserId: sunId, targetId: sunRecordId },
            { relation: "causedBy", targetType: "event", targetUserId: sunId, targetId: sunEventId },
          ],
        },
      });
      assert.equal(referenced.statusCode, 201, referenced.body);
      assert.equal(referenced.json().references.length, 3);

      const privateTarget = await sql.query<{ id: string }>(
        `INSERT INTO records (
           user_id, device_id, visibility, cipher_algorithm, crypto_version,
           key_version, nonce, ciphertext, encrypted_content_type
         ) VALUES ($1, $2, 'private', 'A256GCM', 1, 1, $3, $4,
           'application/vnd.exeligmos.record+json') RETURNING id`,
        [ownerId, ownerDeviceId, Buffer.alloc(12, 1), Buffer.alloc(16, 2)],
      );
      const leaked = await app.inject({
        method: "POST",
        url: "/v1/records",
        headers: { "idempotency-key": `private-reference-${randomUUID()}` },
        payload: {
          deviceId: ownerDeviceId,
          occurredAt: new Date().toISOString(),
          payload: { text: "Must roll back" },
          references: [{
            targetType: "record",
            targetUserId: ownerId,
            targetId: required(privateTarget.rows[0]?.id),
          }],
        },
      });
      assert.equal(leaked.statusCode, 422, leaked.body);

      await sql.query(
        "UPDATE users SET status = 'disabled', disabled_at = now() WHERE id = $1",
        [sunId],
      );
      const disabledTargetSubscriptions = await app.inject({
        method: "GET",
        url: "/v1/subscriptions",
      });
      assert.equal(disabledTargetSubscriptions.statusCode, 200, disabledTargetSubscriptions.body);
      assert.equal(disabledTargetSubscriptions.json().data.length, 1);
      assert.equal(disabledTargetSubscriptions.json().data[0]?.targetUser.status, "disabled");

      const syncResources = await loadSubscriptionResourcesForSync(
        database,
        ownerId,
        [subscribed.json().id],
      );
      assert.equal(syncResources.get(subscribed.json().id)?.targetUser.status, "disabled");

      const deletedSubscription = await app.inject({
        method: "DELETE",
        url: `/v1/subscriptions/${sunId}`,
        headers: {
          "if-match": required(subscribed.headers.etag),
          "idempotency-key": `unsubscribe-${randomUUID()}`,
        },
      });
      assert.equal(deletedSubscription.statusCode, 204, deletedSubscription.body);
      const subscriptionsAfterDelete = await app.inject({
        method: "GET",
        url: "/v1/subscriptions",
      });
      assert.equal(subscriptionsAfterDelete.statusCode, 200, subscriptionsAfterDelete.body);
      assert.equal(subscriptionsAfterDelete.json().data.length, 0);
    } finally {
      try {
        await sql.query("DELETE FROM users WHERE id = ANY($1::uuid[])", [[ownerId, sunId]]);
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
    throw new Error("Expected database identifier");
  }
  return value;
}
