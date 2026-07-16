import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import test from "node:test";

import { ConfigError, loadConfig } from "../src/config.js";

const jwtPrivateKey = generateKeyPairSync("ed25519")
  .privateKey.export({ format: "der", type: "pkcs8" })
  .toString("base64");

test("loadConfig applies safe defaults and parses database settings", () => {
  const config = loadConfig({
    DATABASE_URL: "postgresql://user:secret@db:5432/exeligmos",
    AUTH_JWT_PRIVATE_KEY_BASE64: jwtPrivateKey,
    NODE_ENV: "production",
    PORT: "9000",
    TRUST_PROXY_HOPS: "1",
    DB_POOL_MAX: "20",
  });

  assert.equal(config.nodeEnv, "production");
  assert.equal(config.host, "0.0.0.0");
  assert.equal(config.port, 9000);
  assert.equal(config.trustProxy, 1);
  assert.equal(config.auth.registrationMode, "open");
  assert.equal(config.auth.jwtKeyId, "primary");
  assert.equal(config.auth.accessTokenTtlSeconds, 900);
  assert.equal(config.auth.refreshTokenTtlSeconds, 2_592_000);
  assert.equal(config.auth.argon2MaxConcurrency, 2);
  assert.equal(config.database.poolMax, 20);
  assert.equal(config.database.readinessTimeoutMs, 2_000);
  assert.equal(config.database.statementTimeoutMs, 15_000);
  assert.equal(config.database.lockTimeoutMs, 5_000);
  assert.equal(config.database.idleInTransactionSessionTimeoutMs, 15_000);
  assert.equal(config.media.storageRoot, "var/media");
  assert.equal(config.media.maxByteLength, 5_368_709_120);
  assert.equal(config.media.uploadTtlMs, 86_400_000);
});

test("loadConfig reports all invalid values without leaking the database URL", () => {
  const secretUrl = "https://user:do-not-print@example.com/db";

  assert.throws(
    () =>
      loadConfig({
        DATABASE_URL: secretUrl,
        AUTH_JWT_PRIVATE_KEY_BASE64: jwtPrivateKey,
        PORT: "70000",
        TRUST_PROXY_HOPS: "11",
        DB_POOL_MAX: "0",
        MEDIA_MAX_BYTE_LENGTH: "5368709121",
        MEDIA_UPLOAD_TTL_SECONDS: "59",
      }),
    (error: unknown) => {
      assert.ok(error instanceof ConfigError);
      assert.match(error.message, /DATABASE_URL/);
      assert.match(error.message, /PORT/);
      assert.match(error.message, /TRUST_PROXY_HOPS/);
      assert.match(error.message, /DB_POOL_MAX/);
      assert.match(error.message, /MEDIA_MAX_BYTE_LENGTH/);
      assert.match(error.message, /MEDIA_UPLOAD_TTL_SECONDS/);
      assert.equal(error.message.includes(secretUrl), false);
      assert.equal(error.message.includes("do-not-print"), false);
      return true;
    },
  );
});

test("loadConfig requires DATABASE_URL", () => {
  assert.throws(
    () => loadConfig({ NODE_ENV: "test", AUTH_JWT_PRIVATE_KEY_BASE64: jwtPrivateKey }),
    (error: unknown) =>
      error instanceof ConfigError && error.issues.includes("DATABASE_URL is required"),
  );
});

test("loadConfig requires a valid Ed25519 signing key", () => {
  assert.throws(
    () =>
      loadConfig({
        DATABASE_URL: "postgresql://user:secret@db:5432/exeligmos",
        AUTH_JWT_PRIVATE_KEY_BASE64: Buffer.from("not a private key").toString("base64"),
      }),
    (error: unknown) =>
      error instanceof ConfigError &&
      error.issues.some((issue) => issue.includes("PKCS#8 private key")),
  );
});

test("loadConfig requires an invite code only in invite registration mode", () => {
  assert.throws(
    () =>
      loadConfig({
        DATABASE_URL: "postgresql://user:secret@db:5432/exeligmos",
        AUTH_JWT_PRIVATE_KEY_BASE64: jwtPrivateKey,
        AUTH_REGISTRATION_MODE: "invite",
      }),
    (error: unknown) =>
      error instanceof ConfigError &&
      error.issues.includes("AUTH_REGISTRATION_INVITE_CODE is required in invite mode"),
  );

  const config = loadConfig({
    DATABASE_URL: "postgresql://user:secret@db:5432/exeligmos",
    AUTH_JWT_PRIVATE_KEY_BASE64: jwtPrivateKey,
    AUTH_REGISTRATION_MODE: "invite",
    AUTH_REGISTRATION_INVITE_CODE: "a-long-deployment-invite",
  });
  assert.equal(config.auth.registrationMode, "invite");
  assert.equal(config.auth.registrationInviteCode, "a-long-deployment-invite");
});
