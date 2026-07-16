import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import test from "node:test";

import argon2 from "argon2";
import { decodeJwt, decodeProtectedHeader } from "jose";

import {
  AccessTokenCodec,
  InvalidAccessTokenError,
} from "../src/auth/jwt.js";
import { Argon2idPasswordHasher } from "../src/auth/password.js";

test("Argon2id hashes passwords with the production cost profile", async () => {
  const hasher = new Argon2idPasswordHasher();
  const encoded = await hasher.hash("a sufficiently long password");

  assert.match(encoded, /^\$argon2id\$v=19\$m=65536,t=3,p=1\$/);
  assert.equal(await hasher.verify(encoded, "a sufficiently long password"), true);
  assert.equal(await hasher.verify(encoded, "the wrong password"), false);
  assert.equal(await hasher.verify("not-a-phc-string", "a sufficiently long password"), false);
  assert.equal(hasher.needsRehash(encoded), false);
});

test("Argon2 work never exceeds the configured process concurrency", async () => {
  const mutableArgon2 = argon2 as unknown as {
    hash(password: string, options: unknown): Promise<string>;
  };
  const originalHash = mutableArgon2.hash;
  let active = 0;
  let maximumActive = 0;
  let started = 0;
  let completed = 0;
  const releases: Array<() => void> = [];

  mutableArgon2.hash = async (password: string) => {
    active += 1;
    started += 1;
    maximumActive = Math.max(maximumActive, active);
    await new Promise<void>((resolve) => releases.push(resolve));
    active -= 1;
    completed += 1;
    return `controlled:${password}`;
  };

  try {
    const hasher = new Argon2idPasswordHasher(2);
    const operations = [0, 1, 2, 3].map((value) => hasher.hash(`password-${value}`));
    await waitFor(() => started === 2);
    assert.equal(maximumActive, 2);

    while (completed < operations.length) {
      for (const release of releases.splice(0)) {
        release();
      }
      await new Promise<void>((resolve) => setImmediate(resolve));
    }
    assert.deepEqual(await Promise.all(operations), [
      "controlled:password-0",
      "controlled:password-1",
      "controlled:password-2",
      "controlled:password-3",
    ]);
    assert.equal(maximumActive, 2);
  } finally {
    mutableArgon2.hash = originalHash;
  }
});

test("access tokens are Ed25519 JWTs with the required bounded claims", async () => {
  const privateKey = generateKeyPairSync("ed25519").privateKey;
  const codec = new AccessTokenCodec({
    issuer: "https://sync.example.test",
    audience: "exeligmos-test-client",
    keyId: "key-2026-07",
    privateKey,
    accessTokenTtlSeconds: 60,
    clockToleranceSeconds: 0,
  });
  const now = new Date("2026-07-14T10:00:00.000Z");
  const token = await codec.issue(
    {
      userId: "ad8063cc-e668-4bc3-8182-74763dd756fe",
      sessionId: "0d4cc852-c4ef-49ac-9975-a285fb50ad7d",
      role: "user",
    },
    now,
  );

  assert.deepEqual(decodeProtectedHeader(token), {
    alg: "EdDSA",
    typ: "JWT",
    kid: "key-2026-07",
  });
  const decoded = decodeJwt(token);
  assert.equal(decoded.iss, "https://sync.example.test");
  assert.equal(decoded.aud, "exeligmos-test-client");
  assert.equal(decoded.sub, "ad8063cc-e668-4bc3-8182-74763dd756fe");
  assert.equal(decoded.sid, "0d4cc852-c4ef-49ac-9975-a285fb50ad7d");
  assert.equal(decoded.kid, "key-2026-07");
  assert.equal(decoded.exp, decoded.iat! + 60);

  const verified = await codec.verify(token, new Date("2026-07-14T10:00:30.000Z"));
  assert.equal(verified.userId, "ad8063cc-e668-4bc3-8182-74763dd756fe");
  assert.equal(verified.sessionId, "0d4cc852-c4ef-49ac-9975-a285fb50ad7d");

  await assert.rejects(
    codec.verify(token, new Date("2026-07-14T10:01:01.000Z")),
    InvalidAccessTokenError,
  );

  const [header, payload, signature] = token.split(".");
  assert.ok(header && payload && signature);
  const tampered = `${header}.${payload.slice(0, -1)}A.${signature}`;
  await assert.rejects(codec.verify(tampered, now), InvalidAccessTokenError);
});

async function waitFor(predicate: () => boolean): Promise<void> {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (predicate()) {
      return;
    }
    await new Promise<void>((resolve) => setImmediate(resolve));
  }
  throw new Error("Timed out waiting for controlled Argon2 work");
}
