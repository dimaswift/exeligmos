import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import path from "node:path";
import test from "node:test";

import { Client } from "pg";

import { buildApp } from "../../src/app.js";
import { NOOP_AUTH_ATTEMPT_LIMITER } from "../../src/auth/rate-limit.js";
import { NOOP_RESOURCE_REQUEST_LIMITER } from "../../src/resources/rate-limit.js";
import { createPostgresDatabase } from "../../src/db/database.js";
import { runMigrations } from "../../src/db/migrate.js";
import { testConfig } from "../helpers.js";

const databaseUrl = process.env.TEST_DATABASE_URL?.trim();

test(
  "record and event HTTP APIs preserve tenancy, privacy, concurrency, and agent attribution",
  { skip: databaseUrl === undefined || databaseUrl.length === 0 },
  async () => {
    assert.ok(databaseUrl);
    await runMigrations({
      databaseUrl,
      directory: path.resolve(process.cwd(), "db/migrations"),
    });

    const baseConfig = testConfig();
    const config = {
      ...baseConfig,
      database: { ...baseConfig.database, url: databaseUrl },
    };
    const database = createPostgresDatabase(config.database);
    const app = buildApp({
      config,
      database,
      authAttemptLimiter: NOOP_AUTH_ATTEMPT_LIMITER,
      resourceRequestLimiter: NOOP_RESOURCE_REQUEST_LIMITER,
    });
    const sql = new Client({ connectionString: databaseUrl });
    await sql.connect();
    await app.ready();

    let userId: string | undefined;
    let otherUserId: string | undefined;
    try {
      const owner = await register(app, `resources-${randomUUID()}`);
      userId = owner.userId;
      const other = await register(app, `resources-other-${randomUUID()}`);
      otherUserId = other.userId;

      const profile = await app.inject({
        method: "POST",
        url: "/v1/me/encryption-profile",
        headers: mutationHeaders(owner.accessToken, `profile-${randomUUID()}`),
        payload: {
          cryptoVersion: 1,
          keyVersion: 1,
          keyCheck: Buffer.alloc(32, 5).toString("base64"),
        },
      });
      assert.equal(profile.statusCode, 201, profile.body);

      const device = await createDevice(
        app,
        owner.accessToken,
        "Resource Agent",
      );
      const otherDevice = await createDevice(
        app,
        owner.accessToken,
        "Other Agent",
      );
      const otherUserDevice = await createDevice(
        app,
        other.accessToken,
        "No Profile Agent",
      );
      const apiKey = await issueApiKey(app, owner.accessToken, device.id, [
        "records:read",
        "records:write",
        "events:read",
        "events:write",
      ]);
      const recordsOnlyKey = await issueApiKey(
        app,
        owner.accessToken,
        device.id,
        ["records:read", "records:write"],
      );

      const template = await sql.query<{ id: string }>(
        `INSERT INTO templates (
           user_id, name, body, variable_schema, metadata
         ) VALUES ($1, 'Solar event', $2::jsonb, $3::jsonb, '{}'::jsonb)
         RETURNING id`,
        [
          userId,
          JSON.stringify({
            text: "Solar flare {{class}}",
            context: { strength: "{{strength}}" },
          }),
          JSON.stringify({
            type: "object",
            required: ["class", "strength"],
            properties: {
              class: { type: "string" },
              strength: { type: "integer", minimum: 1 },
            },
            additionalProperties: false,
          }),
        ],
      );
      const templateId = template.rows[0]?.id;
      assert.ok(templateId);
      await sql.query(
        `INSERT INTO template_versions (user_id, template_id, version, body, variable_schema)
         SELECT user_id, id, version, body, variable_schema
         FROM templates WHERE id = $1`,
        [templateId],
      );

      const publicIdempotencyKey = `record-public-${randomUUID()}`;
      const publicRequest = {
        method: "POST" as const,
        url: "/v1/records",
        headers: mutationHeaders(apiKey, publicIdempotencyKey),
        payload: {
          deviceId: device.id,
          occurredAt: "2026-07-14T16:42:00Z",
          payload: {
            text: "Public agent record",
            context: { keep: 1, remove: 2 },
          },
          metadata: { source: "integration", preserve: true },
          source: {
            kind: "agent",
            provider: "phase2-test",
            externalId: `public-${randomUUID()}`,
          },
        },
      };
      const publicRecord = await app.inject(publicRequest);
      const publicReplay = await app.inject(publicRequest);
      assert.equal(publicRecord.statusCode, 201, publicRecord.body);
      assert.equal(publicReplay.statusCode, 201, publicReplay.body);
      assert.deepEqual(publicReplay.json(), publicRecord.json());
      const publicBody = publicRecord.json<RecordBody>();
      assert.equal(publicBody.visibility, "public");
      assert.equal(publicBody.deviceId, device.id);
      assert.equal(
        publicRecord.headers.location,
        `/v1/records/${publicBody.id}`,
      );
      const publicEtag = requiredResponseHeader(publicRecord.headers.etag);

      const rendered = await app.inject({
        method: "POST",
        url: "/v1/records",
        headers: mutationHeaders(apiKey, `record-render-${randomUUID()}`),
        payload: {
          deviceId: device.id,
          occurredAt: "2026-07-14T17:00:00+00:00",
          render: {
            templateId,
            variables: { class: "X1.7", strength: 17 },
          },
        },
      });
      assert.equal(rendered.statusCode, 201, rendered.body);
      assert.deepEqual(rendered.json().payload, {
        text: "Solar flare X1.7",
        context: { strength: 17 },
      });
      assert.deepEqual(rendered.json().template, { templateId, version: 1 });

      const invalidVariables = await app.inject({
        method: "POST",
        url: "/v1/records",
        headers: mutationHeaders(
          apiKey,
          `record-invalid-render-${randomUUID()}`,
        ),
        payload: {
          deviceId: device.id,
          occurredAt: "2026-07-14T17:01:00Z",
          render: { templateId, variables: { class: "X1.7" } },
        },
      });
      assert.equal(invalidVariables.statusCode, 422, invalidVariables.body);
      assert.equal(invalidVariables.json().code, "template_variables_invalid");
      assert.ok(
        invalidVariables
          .json<{ errors: Array<{ path: string }> }>()
          .errors.some((error) => error.path === "/render/variables/strength"),
      );

      const invalidTemplate = await sql.query<{ id: string }>(
        `INSERT INTO templates (user_id, name, body, variable_schema)
         VALUES ($1, 'Invalid schema', '{"text":"{{value}}"}'::jsonb,
           '{"type":"not-a-json-schema-type"}'::jsonb)
         RETURNING id`,
        [userId],
      );
      const invalidTemplateId = invalidTemplate.rows[0]?.id;
      assert.ok(invalidTemplateId);
      await sql.query(
        `INSERT INTO template_versions (user_id, template_id, version, body, variable_schema)
         SELECT user_id, id, version, body, variable_schema
         FROM templates WHERE id = $1`,
        [invalidTemplateId],
      );
      const invalidStoredSchema = await app.inject({
        method: "POST",
        url: "/v1/records",
        headers: mutationHeaders(
          apiKey,
          `record-invalid-schema-${randomUUID()}`,
        ),
        payload: {
          deviceId: device.id,
          occurredAt: "2026-07-14T17:02:00Z",
          render: { templateId: invalidTemplateId, variables: { value: "x" } },
        },
      });
      assert.equal(
        invalidStoredSchema.statusCode,
        422,
        invalidStoredSchema.body,
      );
      assert.equal(invalidStoredSchema.json().code, "invalid_template_schema");

      const retroactive = await app.inject({
        method: "POST",
        url: "/v1/records",
        headers: mutationHeaders(apiKey, `record-retroactive-${randomUUID()}`),
        payload: {
          deviceId: device.id,
          occurredAt: "2020-01-01T00:00:00Z",
          payload: { text: "Created later, happened earlier" },
        },
      });
      assert.equal(retroactive.statusCode, 201, retroactive.body);

      const firstPage = await app.inject({
        method: "GET",
        url: "/v1/records?limit=1",
        headers: bearer(apiKey),
      });
      assert.equal(firstPage.statusCode, 200, firstPage.body);
      const firstPageBody = firstPage.json<PageBody>();
      assert.equal(firstPageBody.data.length, 1);
      assert.equal(firstPageBody.data[0]?.id, rendered.json().id);
      assert.equal(firstPageBody.hasMore, true);
      assert.ok(firstPageBody.nextCursor);
      const secondPage = await app.inject({
        method: "GET",
        url: `/v1/records?limit=1&cursor=${encodeURIComponent(firstPageBody.nextCursor)}`,
        headers: bearer(apiKey),
      });
      assert.equal(secondPage.statusCode, 200, secondPage.body);
      assert.equal(secondPage.json<PageBody>().data.length, 1);

      const anonymousPublic = await app.inject({
        method: "GET",
        url: `/v1/public/records/${publicBody.id}`,
      });
      assert.equal(anonymousPublic.statusCode, 200, anonymousPublic.body);
      assert.equal("deviceId" in anonymousPublic.json(), false);
      assert.equal(
        anonymousPublic.headers["cache-control"],
        "public, max-age=30",
      );

      const otherTenantPublic = await app.inject({
        method: "GET",
        url: `/v1/records/${publicBody.id}`,
        headers: bearer(other.accessToken),
      });
      assert.equal(otherTenantPublic.statusCode, 404);

      const privateId = randomUUID();
      const privateRecord = await app.inject({
        method: "POST",
        url: "/v1/records",
        headers: mutationHeaders(apiKey, `record-private-${randomUUID()}`),
        payload: {
          id: privateId,
          deviceId: device.id,
          visibility: "private",
          encryption: {
            algorithm: "A256GCM",
            cryptoVersion: 1,
            keyVersion: 1,
            nonce: Buffer.alloc(12, 1).toString("base64"),
            ciphertext: Buffer.alloc(32, 2).toString("base64"),
            contentType: "application/vnd.exeligmos.record+json",
          },
        },
      });
      assert.equal(privateRecord.statusCode, 201, privateRecord.body);
      assert.equal(privateRecord.json().visibility, "private");
      assert.equal("occurredAt" in privateRecord.json(), false);
      assert.equal("metadata" in privateRecord.json(), false);
      const privateEtag = requiredResponseHeader(privateRecord.headers.etag);

      const anonymousPrivate = await app.inject({
        method: "GET",
        url: `/v1/public/records/${privateId}`,
      });
      assert.equal(anonymousPrivate.statusCode, 404);
      const otherTenantPrivate = await app.inject({
        method: "GET",
        url: `/v1/records/${privateId}`,
        headers: bearer(other.accessToken),
      });
      assert.equal(otherTenantPrivate.statusCode, 404);

      const privateWithoutProfile = await app.inject({
        method: "POST",
        url: "/v1/records",
        headers: mutationHeaders(
          other.accessToken,
          `private-no-profile-${randomUUID()}`,
        ),
        payload: {
          id: randomUUID(),
          deviceId: otherUserDevice.id,
          visibility: "private",
          encryption: {
            algorithm: "A256GCM",
            cryptoVersion: 1,
            keyVersion: 1,
            nonce: Buffer.alloc(12, 3).toString("base64"),
            ciphertext: Buffer.alloc(32, 4).toString("base64"),
            contentType: "application/vnd.exeligmos.record+json",
          },
        },
      });
      assert.equal(
        privateWithoutProfile.statusCode,
        422,
        privateWithoutProfile.body,
      );
      assert.equal(
        privateWithoutProfile.json().code,
        "encryption_profile_required",
      );

      const wrongDevice = await app.inject({
        method: "POST",
        url: "/v1/events",
        headers: mutationHeaders(apiKey, `wrong-device-${randomUUID()}`),
        payload: {
          deviceId: otherDevice.id,
          startsAt: "2026-07-14T18:00:00Z",
          label: "Wrong device",
          type: 1,
        },
      });
      assert.equal(wrongDevice.statusCode, 403, wrongDevice.body);
      assert.equal(wrongDevice.json().code, "device_binding_mismatch");

      const missingScope = await app.inject({
        method: "POST",
        url: "/v1/events",
        headers: mutationHeaders(
          recordsOnlyKey,
          `missing-scope-${randomUUID()}`,
        ),
        payload: {
          deviceId: device.id,
          startsAt: "2026-07-14T18:00:00Z",
          label: "Missing scope",
          type: 1,
        },
      });
      assert.equal(missingScope.statusCode, 403, missingScope.body);
      assert.equal(missingScope.json().code, "insufficient_scope");

      const patched = await app.inject({
        method: "PATCH",
        url: `/v1/records/${publicBody.id}`,
        headers: {
          ...mutationHeaders(apiKey, `record-patch-${randomUUID()}`),
          "if-match": publicEtag,
          "content-type": "application/merge-patch+json",
        },
        payload: {
          visibility: "public",
          payload: { text: "Patched", context: { remove: null, add: 3 } },
          metadata: { source: null, added: true },
        },
      });
      assert.equal(patched.statusCode, 200, patched.body);
      assert.equal(patched.json().revision, 2);
      assert.deepEqual(patched.json().payload, {
        text: "Patched",
        context: { keep: 1, add: 3 },
      });
      assert.deepEqual(patched.json().metadata, {
        preserve: true,
        added: true,
      });
      const patchedEtag = requiredResponseHeader(patched.headers.etag);

      const stalePatch = await app.inject({
        method: "PATCH",
        url: `/v1/records/${publicBody.id}`,
        headers: {
          ...mutationHeaders(apiKey, `record-stale-${randomUUID()}`),
          "if-match": publicEtag,
          "content-type": "application/merge-patch+json",
        },
        payload: { visibility: "public", metadata: { stale: true } },
      });
      assert.equal(stalePatch.statusCode, 412, stalePatch.body);
      assert.equal(stalePatch.headers.etag, patchedEtag);

      const eventIdempotencyKey = `event-${randomUUID()}`;
      const eventRequest = {
        method: "POST" as const,
        url: "/v1/events",
        headers: mutationHeaders(apiKey, eventIdempotencyKey),
        payload: {
          deviceId: device.id,
          startsAt: "2026-07-14T18:10:00Z",
          endsAt: "2026-07-14T18:20:00Z",
          label: "X1.7 solar flare",
          type: 1001,
          metadata: { provider: "phase2-test" },
        },
      };
      const event = await app.inject(eventRequest);
      const eventReplay = await app.inject(eventRequest);
      assert.equal(event.statusCode, 201, event.body);
      assert.deepEqual(eventReplay.json(), event.json());
      const eventBody = event.json<{ id: string }>();
      const eventEtag = requiredResponseHeader(event.headers.etag);

      const eventList = await app.inject({
        method: "GET",
        url: "/v1/events?type=1001&from=2026-07-14T18%3A15%3A00Z&to=2026-07-14T19%3A00%3A00Z",
        headers: bearer(apiKey),
      });
      assert.equal(eventList.statusCode, 200, eventList.body);
      assert.deepEqual(
        eventList.json<PageBody>().data.map((item) => item.id),
        [eventBody.id],
      );

      const eventPatch = await app.inject({
        method: "PATCH",
        url: `/v1/events/${eventBody.id}`,
        headers: {
          ...mutationHeaders(apiKey, `event-patch-${randomUUID()}`),
          "if-match": eventEtag,
          "content-type": "application/merge-patch+json",
        },
        payload: { label: "X1.7 solar flare updated", endsAt: null },
      });
      assert.equal(eventPatch.statusCode, 200, eventPatch.body);
      assert.equal(eventPatch.json().endsAt, undefined);

      const eventDelete = await app.inject({
        method: "DELETE",
        url: `/v1/events/${eventBody.id}`,
        headers: {
          ...mutationHeaders(apiKey, `event-delete-${randomUUID()}`),
          "if-match": requiredResponseHeader(eventPatch.headers.etag),
        },
      });
      assert.equal(eventDelete.statusCode, 204, eventDelete.body);
      const deletedEvent = await app.inject({
        method: "GET",
        url: `/v1/events/${eventBody.id}`,
        headers: bearer(apiKey),
      });
      assert.equal(deletedEvent.statusCode, 404);

      const privateDelete = await app.inject({
        method: "DELETE",
        url: `/v1/records/${privateId}`,
        headers: {
          ...mutationHeaders(apiKey, `record-private-delete-${randomUUID()}`),
          "if-match": privateEtag,
        },
      });
      assert.equal(privateDelete.statusCode, 204, privateDelete.body);

      const privateTombstone = await sql.query<{
        revision: string;
        deleted: boolean;
        cipher_algorithm: string | null;
        crypto_version: number | null;
        key_version: number | null;
        nonce: Buffer | null;
        ciphertext: Buffer | null;
        encrypted_content_type: string | null;
        live_snapshot: Record<string, unknown>;
        tombstone_snapshot: Record<string, unknown>;
        operation: string;
        change_revision: string;
      }>(
        `SELECT
           r.revision,
           r.deleted_at IS NOT NULL AS deleted,
           r.cipher_algorithm,
           r.crypto_version,
           r.key_version,
           r.nonce,
           r.ciphertext,
           r.encrypted_content_type,
           live.snapshot AS live_snapshot,
           tombstone.snapshot AS tombstone_snapshot,
           cl.operation,
           cl.revision AS change_revision
         FROM records AS r
         JOIN record_revisions AS live
           ON live.record_id = r.id AND live.revision = 1
         JOIN record_revisions AS tombstone
           ON tombstone.record_id = r.id AND tombstone.revision = r.revision
         JOIN change_log AS cl
           ON cl.entity_type = 'record'
          AND cl.entity_id = r.id
          AND cl.revision = r.revision
         WHERE r.id = $1`,
        [privateId],
      );
      const privateTombstoneRow = privateTombstone.rows[0];
      assert.ok(privateTombstoneRow);
      assert.equal(Number(privateTombstoneRow.revision), 2);
      assert.equal(privateTombstoneRow.deleted, true);
      assert.deepEqual(
        [
          privateTombstoneRow.cipher_algorithm,
          privateTombstoneRow.crypto_version,
          privateTombstoneRow.key_version,
          privateTombstoneRow.nonce,
          privateTombstoneRow.ciphertext,
          privateTombstoneRow.encrypted_content_type,
        ],
        [null, null, null, null, null, null],
      );
      assert.equal(typeof privateTombstoneRow.live_snapshot.nonce, "string");
      assert.equal(
        typeof privateTombstoneRow.live_snapshot.ciphertext,
        "string",
      );
      assert.equal(privateTombstoneRow.tombstone_snapshot.nonce, null);
      assert.equal(privateTombstoneRow.tombstone_snapshot.ciphertext, null);
      assert.equal(privateTombstoneRow.operation, "delete");
      assert.equal(Number(privateTombstoneRow.change_revision), 2);
      const deletedPrivate = await app.inject({
        method: "GET",
        url: `/v1/records/${privateId}`,
        headers: bearer(apiKey),
      });
      assert.equal(deletedPrivate.statusCode, 404);

      const recordDelete = await app.inject({
        method: "DELETE",
        url: `/v1/records/${publicBody.id}`,
        headers: {
          ...mutationHeaders(apiKey, `record-delete-${randomUUID()}`),
          "if-match": patchedEtag,
        },
      });
      assert.equal(recordDelete.statusCode, 204, recordDelete.body);

      const publicTombstone = await sql.query<{
        revision: string;
        deleted: boolean;
        public_payload: Record<string, unknown>;
        tombstone_payload: Record<string, unknown>;
        operation: string;
        change_revision: string;
      }>(
        `SELECT
           r.revision,
           r.deleted_at IS NOT NULL AS deleted,
           r.public_payload,
           rr.snapshot -> 'public_payload' AS tombstone_payload,
           cl.operation,
           cl.revision AS change_revision
         FROM records AS r
         JOIN record_revisions AS rr
           ON rr.record_id = r.id AND rr.revision = r.revision
         JOIN change_log AS cl
           ON cl.entity_type = 'record'
          AND cl.entity_id = r.id
          AND cl.revision = r.revision
         WHERE r.id = $1`,
        [publicBody.id],
      );
      const publicTombstoneRow = publicTombstone.rows[0];
      assert.ok(publicTombstoneRow);
      assert.equal(Number(publicTombstoneRow.revision), 3);
      assert.equal(publicTombstoneRow.deleted, true);
      assert.deepEqual(publicTombstoneRow.public_payload, {
        text: "Patched",
        context: { keep: 1, add: 3 },
      });
      assert.deepEqual(
        publicTombstoneRow.tombstone_payload,
        publicTombstoneRow.public_payload,
      );
      assert.equal(publicTombstoneRow.operation, "delete");
      assert.equal(Number(publicTombstoneRow.change_revision), 3);

      const deletedOwnerRecord = await app.inject({
        method: "GET",
        url: `/v1/records/${publicBody.id}`,
        headers: bearer(apiKey),
      });
      assert.equal(deletedOwnerRecord.statusCode, 404);
      const deletedPublicRecord = await app.inject({
        method: "GET",
        url: `/v1/public/records/${publicBody.id}`,
      });
      assert.equal(deletedPublicRecord.statusCode, 404);

      const audits = await sql.query<{
        action: string;
        actor_type: string;
        actor_id: string;
      }>(
        `SELECT action, actor_type, actor_id
         FROM audit_log
         WHERE user_id = $1 AND action IN (
           'record.create', 'record.update', 'record.delete',
           'event.create', 'event.update', 'event.delete'
         )`,
        [userId],
      );
      assert.ok(audits.rows.length >= 8);
      assert.ok(audits.rows.every((row) => row.actor_type === "api_key"));
      assert.ok(audits.rows.every((row) => row.actor_id.length > 0));
    } finally {
      for (const id of [userId, otherUserId]) {
        if (id !== undefined) {
          await sql.query("DELETE FROM audit_log WHERE user_id = $1", [id]);
          await sql.query("DELETE FROM users WHERE id = $1", [id]);
        }
      }
      await app.close();
      await sql.end();
    }
  },
);

interface Registration {
  readonly accessToken: string;
  readonly userId: string;
}

interface RecordBody {
  readonly id: string;
  readonly deviceId: string;
  readonly visibility: "public" | "private";
}

interface PageBody {
  readonly data: ReadonlyArray<{ readonly id: string }>;
  readonly hasMore: boolean;
  readonly nextCursor: string;
}

async function register(
  app: ReturnType<typeof buildApp>,
  login: string,
): Promise<Registration> {
  const response = await app.inject({
    method: "POST",
    url: "/v1/auth/register",
    payload: {
      login,
      password: "correct horse battery staple",
      displayName: login,
    },
  });
  assert.equal(response.statusCode, 201, response.body);
  const body = response.json<{ accessToken: string; user: { id: string } }>();
  return { accessToken: body.accessToken, userId: body.user.id };
}

async function createDevice(
  app: ReturnType<typeof buildApp>,
  accessToken: string,
  name: string,
): Promise<{ readonly id: string }> {
  const response = await app.inject({
    method: "POST",
    url: "/v1/devices",
    headers: mutationHeaders(accessToken, `device-${randomUUID()}`),
    payload: { name, kind: "agent" },
  });
  assert.equal(response.statusCode, 201, response.body);
  return response.json<{ id: string }>();
}

async function issueApiKey(
  app: ReturnType<typeof buildApp>,
  accessToken: string,
  deviceId: string,
  scopes: readonly string[],
): Promise<string> {
  const response = await app.inject({
    method: "POST",
    url: "/v1/api-keys",
    headers: mutationHeaders(accessToken, `api-key-${randomUUID()}`),
    payload: { name: `Key ${randomUUID()}`, deviceId, scopes },
  });
  assert.equal(response.statusCode, 201, response.body);
  return response.json<{ secret: string }>().secret;
}

function bearer(token: string): Readonly<Record<string, string>> {
  return { authorization: `Bearer ${token}` };
}

function mutationHeaders(
  token: string,
  key: string,
): Readonly<Record<string, string>> {
  return { ...bearer(token), "idempotency-key": key };
}

function requiredResponseHeader(value: string | string[] | undefined): string {
  if (typeof value !== "string") {
    assert.fail("Expected a single response header value");
  }
  return value;
}
