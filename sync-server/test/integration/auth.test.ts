import assert from "node:assert/strict";
import { generateKeyPairSync, randomUUID } from "node:crypto";
import path from "node:path";
import test from "node:test";

import type { QueryResultRow } from "pg";

import type { AuthConfig } from "../../src/config.js";
import { createPostgresDatabase } from "../../src/db/database.js";
import { runMigrations } from "../../src/db/migrate.js";
import { HttpProblem } from "../../src/http/problem.js";
import {
  createAuthService,
  hashRefreshToken,
} from "../../src/auth/service.js";

const databaseUrl = process.env.TEST_DATABASE_URL?.trim();

interface StoredCredentialRow extends QueryResultRow {
  readonly password_hash: string;
  readonly refresh_hash: string;
  readonly token_family_id: string;
}

interface FamilyStateRow extends QueryResultRow {
  readonly session_count: string;
  readonly active_count: string;
}

test(
  "password sessions rotate once, detect reuse, and revoke only their family",
  { skip: databaseUrl === undefined || databaseUrl.length === 0 },
  async () => {
    assert.ok(databaseUrl);
    await runMigrations({
      databaseUrl,
      directory: path.resolve(process.cwd(), "db/migrations"),
    });
    const database = createPostgresDatabase({
      url: databaseUrl,
      poolMax: 4,
      connectionTimeoutMs: 2_000,
      idleTimeoutMs: 5_000,
      readinessTimeoutMs: 1_000,
      statementTimeoutMs: 5_000,
      lockTimeoutMs: 1_000,
      idleInTransactionSessionTimeoutMs: 5_000,
    });
    const privateKey = generateKeyPairSync("ed25519")
      .privateKey.export({ format: "der", type: "pkcs8" })
      .toString("base64");
    const authConfig: AuthConfig = {
      registrationMode: "open",
      jwtIssuer: "exeligmos-integration",
      jwtAudience: "exeligmos-integration-client",
      jwtKeyId: "integration-key",
      jwtPrivateKeyPkcs8Base64: privateKey,
      accessTokenTtlSeconds: 300,
      refreshTokenTtlSeconds: 3_600,
      argon2MaxConcurrency: 2,
    };
    const auth = createAuthService(database, authConfig);
    const login = `auth-${randomUUID()}`;
    const password = "integration-password-is-long";
    let userId: string | undefined;

    try {
      const registered = await auth.register({
        login: login.toUpperCase(),
        password,
        displayName: " Integration User ",
      });
      userId = registered.user.id;
      assert.equal(registered.user.login, login);
      assert.equal(registered.user.displayName, "Integration User");
      assert.equal(registered.tokenType, "Bearer");
      assert.match(registered.refreshToken, /^exr_[A-Za-z0-9_-]{43}$/);

      const stored = await database.query<StoredCredentialRow>(
        `SELECT u.password_hash,
                encode(s.refresh_token_hash, 'hex') AS refresh_hash,
                s.token_family_id
         FROM users AS u
         JOIN auth_sessions AS s ON s.user_id = u.id
         WHERE u.id = $1 AND s.id = $2`,
        [userId, (await auth.authenticateBearer(registered.accessToken)).actorId],
      );
      const registeredFamilyId = stored.rows[0]?.token_family_id;
      assert.ok(registeredFamilyId);
      assert.match(stored.rows[0]?.password_hash ?? "", /^\$argon2id\$/);
      assert.notEqual(stored.rows[0]?.password_hash, password);
      assert.equal(
        stored.rows[0]?.refresh_hash,
        hashRefreshToken(registered.refreshToken).toString("hex"),
      );

      await assert.rejects(
        auth.login({ login, password: "a-different-long-password" }),
        (error: unknown) => isProblem(error, 401, "invalid_credentials"),
      );
      const loggedIn = await auth.login({ login: login.toUpperCase(), password });
      const loginPrincipal = await auth.authenticateBearer(loggedIn.accessToken);
      assert.equal(loginPrincipal.userId, userId);

      const rotated = await auth.refresh(registered.refreshToken);
      await assert.rejects(
        auth.authenticateBearer(registered.accessToken),
        (error: unknown) => isProblem(error, 401, "invalid_access_token"),
      );
      assert.equal((await auth.authenticateBearer(rotated.accessToken)).userId, userId);

      await assert.rejects(
        auth.refresh(registered.refreshToken),
        (error: unknown) => isProblem(error, 401, "invalid_refresh_token"),
      );
      await assert.rejects(
        auth.authenticateBearer(rotated.accessToken),
        (error: unknown) => isProblem(error, 401, "invalid_access_token"),
      );

      const familyState = await database.query<FamilyStateRow>(
        `SELECT count(*)::text AS session_count,
                count(*) FILTER (WHERE revoked_at IS NULL)::text AS active_count
         FROM auth_sessions
         WHERE user_id = $1 AND token_family_id = $2`,
        [userId, registeredFamilyId],
      );
      assert.equal(familyState.rows[0]?.session_count, "2");
      assert.equal(familyState.rows[0]?.active_count, "0");

      // Reuse revocation is family-local; an independent login remains valid.
      assert.equal((await auth.authenticateBearer(loggedIn.accessToken)).actorId, loginPrincipal.actorId);

      const deviceBound = await auth.login({ login, password });
      const deviceBoundPrincipal = await auth.authenticateBearer(deviceBound.accessToken);
      const revokedDeviceId = randomUUID();
      await database.query(
        `INSERT INTO devices (id, user_id, name, kind)
         VALUES ($1, $2, 'Revoked refresh test', 'other')`,
        [revokedDeviceId, userId],
      );
      await database.query(
        `UPDATE auth_sessions SET device_id = $3
         WHERE user_id = $1 AND id = $2`,
        [userId, deviceBoundPrincipal.actorId, revokedDeviceId],
      );
      await database.query(
        "UPDATE devices SET revoked_at = clock_timestamp() WHERE user_id = $1 AND id = $2",
        [userId, revokedDeviceId],
      );
      await assert.rejects(
        auth.refresh(deviceBound.refreshToken),
        (error: unknown) => isProblem(error, 401, "invalid_refresh_token"),
      );

      await auth.logout(loginPrincipal, loggedIn.refreshToken);
      await auth.logout(loginPrincipal, loggedIn.refreshToken);
      await assert.rejects(
        auth.authenticateBearer(loggedIn.accessToken),
        (error: unknown) => isProblem(error, 401, "invalid_access_token"),
      );
    } finally {
      if (userId !== undefined) {
        await database.query("DELETE FROM users WHERE id = $1", [userId]);
      }
      await database.close();
    }
  },
);

function isProblem(error: unknown, status: number, code: string): boolean {
  return error instanceof HttpProblem && error.status === status && error.code === code;
}
