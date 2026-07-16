import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
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
  "HTTP auth, encryption profile, devices, and API keys work together against PostgreSQL",
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
    const cleanup = new Client({ connectionString: databaseUrl });
    await cleanup.connect();
    await app.ready();

    const login = `http-${randomUUID()}`;
    const password = "correct horse battery staple";
    let userId: string | undefined;

    try {
      const registered = await app.inject({
        method: "POST",
        url: "/v1/auth/register",
        payload: { login, password, displayName: "HTTP Integration" },
      });
      assert.equal(registered.statusCode, 201, registered.body);
      assert.equal(registered.headers["cache-control"], "no-store");
      const firstSession = registered.json<SessionBody>();
      userId = firstSession.user.id;
      assert.equal(firstSession.user.login, login.toLowerCase());
      assert.match(firstSession.accessToken, /^eyJ/);
      assert.match(firstSession.refreshToken, /^exr_/);

      const me = await app.inject({
        method: "GET",
        url: "/v1/me",
        headers: bearer(firstSession.accessToken),
      });
      assert.equal(me.statusCode, 200, me.body);
      assert.equal(me.json().id, userId);
      assert.match(me.headers.etag ?? "", /^"user-.+-r1"$/);
      assert.equal(me.headers["cache-control"], "no-store");

      const missingProfile = await app.inject({
        method: "GET",
        url: "/v1/me/encryption-profile",
        headers: bearer(firstSession.accessToken),
      });
      assert.equal(missingProfile.statusCode, 404);

      const keyCheck = Buffer.alloc(32, 7).toString("base64");
      const profileIdempotencyKey = `profile-${randomUUID()}`;
      const profileRequest = {
        method: "POST" as const,
        url: "/v1/me/encryption-profile",
        headers: {
          ...bearer(firstSession.accessToken),
          "idempotency-key": profileIdempotencyKey,
        },
        payload: { cryptoVersion: 1, keyVersion: 1, keyCheck },
      };
      const profile = await app.inject(profileRequest);
      const profileReplay = await app.inject(profileRequest);
      assert.equal(profile.statusCode, 201, profile.body);
      assert.equal(profileReplay.statusCode, 201, profileReplay.body);
      assert.deepEqual(profileReplay.json(), profile.json());
      assert.equal(profile.json().keyCheck, keyCheck);

      const device = await app.inject({
        method: "POST",
        url: "/v1/devices",
        headers: {
          ...bearer(firstSession.accessToken),
          "idempotency-key": `device-${randomUUID()}`,
        },
        payload: {
          name: "HTTP Integration Agent",
          kind: "agent",
          platform: "node",
          appVersion: "2.0-test",
          metadata: { purpose: "phase2" },
        },
      });
      assert.equal(device.statusCode, 201, device.body);
      const deviceBody = device.json<{ id: string }>();
      assert.match(device.headers.etag ?? "", /^"device-.+-r1"$/);

      const boundSession = await app.inject({
        method: "PUT",
        url: `/v1/devices/${deviceBody.id}/current-session`,
        headers: bearer(firstSession.accessToken),
      });
      assert.equal(boundSession.statusCode, 204, boundSession.body);

      const issued = await app.inject({
        method: "POST",
        url: "/v1/api-keys",
        headers: {
          ...bearer(firstSession.accessToken),
          "idempotency-key": `api-key-${randomUUID()}`,
        },
        payload: {
          name: "HTTP Integration Key",
          deviceId: deviceBody.id,
          scopes: [
            "devices:read",
            "records:read",
            "records:write",
            "events:read",
            "events:write",
          ],
        },
      });
      assert.equal(issued.statusCode, 201, issued.body);
      const issuedBody = issued.json<IssuedKeyBody>();
      assert.match(issuedBody.secret, /^exk_/);
      assert.equal(issuedBody.key.deviceId, deviceBody.id);

      const devicesViaKey = await app.inject({
        method: "GET",
        url: "/v1/devices",
        headers: bearer(issuedBody.secret),
      });
      assert.equal(devicesViaKey.statusCode, 200, devicesViaKey.body);
      assert.ok(
        devicesViaKey.json<{ data: Array<{ id: string }> }>().data
          .some((item) => item.id === deviceBody.id),
      );

      const meViaKey = await app.inject({
        method: "GET",
        url: "/v1/me",
        headers: bearer(issuedBody.secret),
      });
      assert.equal(meViaKey.statusCode, 200, meViaKey.body);
      assert.equal(meViaKey.json().id, userId);

      const keyManagementViaKey = await app.inject({
        method: "GET",
        url: "/v1/api-keys",
        headers: bearer(issuedBody.secret),
      });
      assert.equal(keyManagementViaKey.statusCode, 403);
      assert.equal(keyManagementViaKey.json().code, "jwt_required");

      const storedCredentials = await cleanup.query<{
        password_hash: string;
        key_hash: Buffer;
      }>(
        `SELECT users.password_hash, api_keys.key_hash
         FROM users
         JOIN api_keys ON api_keys.user_id = users.id
         WHERE users.id = $1 AND api_keys.id = $2`,
        [userId, issuedBody.key.id],
      );
      const credentials = storedCredentials.rows[0];
      assert.ok(credentials);
      assert.match(credentials.password_hash, /^\$argon2id\$/);
      assert.equal(credentials.password_hash.includes(password), false);
      assert.deepEqual(
        credentials.key_hash,
        createHash("sha256").update(issuedBody.secret, "utf8").digest(),
      );

      const logoutLogin = await app.inject({
        method: "POST",
        url: "/v1/auth/login",
        payload: { login: login.toUpperCase(), password },
      });
      assert.equal(logoutLogin.statusCode, 200, logoutLogin.body);
      const logoutSession = logoutLogin.json<SessionBody>();
      const logoutRequest = {
        method: "POST" as const,
        url: "/v1/auth/logout",
        headers: bearer(logoutSession.accessToken),
        payload: { refreshToken: logoutSession.refreshToken },
      };
      const loggedOut = await app.inject(logoutRequest);
      const logoutRetry = await app.inject(logoutRequest);
      assert.equal(loggedOut.statusCode, 204, loggedOut.body);
      assert.equal(logoutRetry.statusCode, 204, logoutRetry.body);

      const loggedOutSession = await app.inject({
        method: "GET",
        url: "/v1/me",
        headers: bearer(logoutSession.accessToken),
      });
      assert.equal(loggedOutSession.statusCode, 401);

      const rotated = await app.inject({
        method: "POST",
        url: "/v1/auth/refresh",
        payload: { refreshToken: firstSession.refreshToken },
      });
      assert.equal(rotated.statusCode, 200, rotated.body);
      const rotatedSession = rotated.json<SessionBody>();
      assert.notEqual(rotatedSession.refreshToken, firstSession.refreshToken);

      const reuse = await app.inject({
        method: "POST",
        url: "/v1/auth/refresh",
        payload: { refreshToken: firstSession.refreshToken },
      });
      assert.equal(reuse.statusCode, 401);
      assert.equal(reuse.json().code, "invalid_refresh_token");
      assert.match(String(reuse.headers["www-authenticate"] ?? ""), /^Bearer/);

      const revokedDescendant = await app.inject({
        method: "GET",
        url: "/v1/me",
        headers: bearer(rotatedSession.accessToken),
      });
      assert.equal(revokedDescendant.statusCode, 401);
    } finally {
      if (userId !== undefined) {
        await cleanup.query("DELETE FROM users WHERE id = $1", [userId]);
      }
      await app.close();
      await cleanup.end();
    }
  },
);

interface SessionBody {
  readonly accessToken: string;
  readonly refreshToken: string;
  readonly user: { readonly id: string; readonly login: string };
}

interface IssuedKeyBody {
  readonly key: { readonly id: string; readonly deviceId: string };
  readonly secret: string;
}

function bearer(token: string): Readonly<Record<string, string>> {
  return { authorization: `Bearer ${token}` };
}
