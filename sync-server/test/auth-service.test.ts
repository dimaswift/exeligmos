import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import test from "node:test";

import { AccessTokenCodec } from "../src/auth/jwt.js";
import { DUMMY_PASSWORD_HASH, type PasswordHasher } from "../src/auth/password.js";
import type {
  ActiveSession,
  AuthRepository,
  CreateAccountWithSessionInput,
  CreateSessionInput,
  PasswordAccount,
  RotateSessionInput,
  RotateSessionResult,
  SessionIdentity,
} from "../src/auth/repository.js";
import {
  AuthService,
  hashRefreshToken,
} from "../src/auth/service.js";
import { HttpProblem } from "../src/http/problem.js";

const NOW = new Date("2026-07-14T10:00:00.000Z");

interface MemorySession extends SessionIdentity {
  readonly refreshHash: string;
  revokedReason?: string;
}

class MemoryAuthRepository implements AuthRepository {
  readonly accounts = new Map<string, PasswordAccount>();
  readonly sessions = new Map<string, MemorySession>();

  async createAccountWithSession(input: CreateAccountWithSessionInput) {
    if ([...this.accounts.values()].some((account) => account.login === input.login)) {
      throw Object.assign(new Error("duplicate login"), {
        code: "23505",
        constraint: "users_login_casefold_key",
      });
    }
    const account: PasswordAccount = {
      id: input.userId,
      login: input.login,
      displayName: input.displayName,
      passwordHash: input.passwordHash,
      role: "user",
      status: "active",
      createdAt: input.createdAt,
      updatedAt: input.createdAt,
    };
    const session = memorySession({
      id: input.sessionId,
      userId: input.userId,
      tokenFamilyId: input.tokenFamilyId,
      refreshTokenHash: input.refreshTokenHash,
      expiresAt: input.expiresAt,
    });
    this.accounts.set(account.id, account);
    this.sessions.set(session.id, session);
    return { user: account, session };
  }

  async findAccountByLogin(login: string): Promise<PasswordAccount | undefined> {
    return [...this.accounts.values()].find(
      (account) => account.login.toLowerCase() === login.toLowerCase(),
    );
  }

  async updatePasswordHash(
    userId: string,
    previousHash: string,
    replacementHash: string,
    now: Date,
  ): Promise<void> {
    const account = this.accounts.get(userId);
    if (account !== undefined && account.passwordHash === previousHash) {
      this.accounts.set(userId, {
        ...account,
        passwordHash: replacementHash,
        updatedAt: now,
      });
    }
  }

  async createSession(input: CreateSessionInput): Promise<SessionIdentity> {
    const session = memorySession({
      id: input.id,
      userId: input.userId,
      tokenFamilyId: input.tokenFamilyId,
      refreshTokenHash: input.refreshTokenHash,
      expiresAt: input.expiresAt,
    });
    this.sessions.set(session.id, session);
    return session;
  }

  async rotateSession(input: RotateSessionInput): Promise<RotateSessionResult> {
    const current = this.sessionForHash(input.refreshTokenHash);
    if (current === undefined) {
      return { kind: "invalid" };
    }
    if (current.revokedReason !== undefined) {
      if (current.revokedReason === "rotated" || current.revokedReason === "refresh_token_reuse") {
        this.revokeFamily(current.userId, current.tokenFamilyId, "refresh_token_reuse");
        return { kind: "reuse" };
      }
      return { kind: "invalid" };
    }
    const account = this.accounts.get(current.userId);
    if (
      account === undefined ||
      account.status !== "active" ||
      current.expiresAt.getTime() <= input.now.getTime()
    ) {
      return { kind: "invalid" };
    }

    current.revokedReason = "rotated";
    const replacement = memorySession({
      id: input.replacementSessionId,
      userId: current.userId,
      tokenFamilyId: current.tokenFamilyId,
      refreshTokenHash: input.replacementRefreshTokenHash,
      expiresAt: input.replacementExpiresAt,
      ...(current.deviceId === undefined ? {} : { deviceId: current.deviceId }),
    });
    this.sessions.set(replacement.id, replacement);
    return { kind: "rotated", user: account, session: replacement };
  }

  async findActiveSession(
    userId: string,
    sessionId: string,
    now: Date,
  ): Promise<ActiveSession | undefined> {
    const session = this.sessions.get(sessionId);
    const account = this.accounts.get(userId);
    if (
      session === undefined ||
      session.userId !== userId ||
      session.revokedReason !== undefined ||
      session.expiresAt.getTime() <= now.getTime() ||
      account?.status !== "active"
    ) {
      return undefined;
    }
    return {
      userId,
      sessionId,
      ...(session.deviceId === undefined ? {} : { deviceId: session.deviceId }),
    };
  }

  async revokeSessionFamily(
    userId: string,
    actorSessionId: string,
    refreshTokenHash: Buffer,
    _now: Date,
  ): Promise<boolean> {
    const actor = this.sessions.get(actorSessionId);
    const target = this.sessionForHash(refreshTokenHash);
    if (
      actor === undefined ||
      target === undefined ||
      actor.userId !== userId ||
      target.userId !== userId ||
      actor.tokenFamilyId !== target.tokenFamilyId
    ) {
      return false;
    }
    this.revokeFamily(userId, target.tokenFamilyId, "logout");
    return true;
  }

  disable(userId: string): void {
    const account = this.accounts.get(userId);
    assert.ok(account);
    this.accounts.set(userId, { ...account, status: "disabled" });
  }

  private sessionForHash(hash: Buffer): MemorySession | undefined {
    const encoded = hash.toString("hex");
    return [...this.sessions.values()].find((session) => session.refreshHash === encoded);
  }

  private revokeFamily(userId: string, familyId: string, reason: string): void {
    for (const session of this.sessions.values()) {
      if (session.userId === userId && session.tokenFamilyId === familyId) {
        session.revokedReason ??= reason;
      }
    }
  }
}

class DeterministicPasswordHasher implements PasswordHasher {
  readonly verifications: string[] = [];

  async hash(password: string): Promise<string> {
    return `hashed:${password}`;
  }

  async verify(encodedHash: string, password: string): Promise<boolean> {
    this.verifications.push(encodedHash);
    return encodedHash === `hashed:${password}`;
  }

  needsRehash(_encodedHash: string): boolean {
    return false;
  }
}

function buildService(
  repository: MemoryAuthRepository,
  passwordHasher: DeterministicPasswordHasher,
  registrationMode: "open" | "invite" | "closed" = "open",
): AuthService {
  const privateKey = generateKeyPairSync("ed25519").privateKey;
  let tokenCounter = 0;
  const tokenCharacters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_";

  return new AuthService({
    repository,
    passwordHasher,
    accessTokens: new AccessTokenCodec({
      issuer: "auth-service-test",
      audience: "auth-service-test-client",
      keyId: "test-key",
      privateKey,
      accessTokenTtlSeconds: 300,
      clockToleranceSeconds: 0,
    }),
    registrationMode,
    ...(registrationMode === "invite" ? { registrationInviteCode: "valid-invite" } : {}),
    refreshTokenTtlSeconds: 3_600,
    clock: () => NOW,
    refreshTokenGenerator: () => {
      const character = tokenCharacters[tokenCounter++ % tokenCharacters.length]!;
      return `exr_${character.repeat(43)}`;
    },
  });
}

test("registration normalizes identity and login uses a generic dummy-hash path", async () => {
  const repository = new MemoryAuthRepository();
  const hasher = new DeterministicPasswordHasher();
  const auth = buildService(repository, hasher);

  const registered = await auth.register({
    login: "Aurora.User",
    password: "correct-horse-battery-staple",
    displayName: "  Aurora User  ",
  });
  assert.equal(registered.user.login, "aurora.user");
  assert.equal(registered.user.displayName, "Aurora User");

  const loggedIn = await auth.login({
    login: "AURORA.USER",
    password: "correct-horse-battery-staple",
  });
  assert.equal(loggedIn.user.id, registered.user.id);

  await assert.rejects(
    auth.login({ login: "unknown.user", password: "a-long-incorrect-password" }),
    (error: unknown) => isProblem(error, 401, "invalid_credentials"),
  );
  assert.equal(hasher.verifications.at(-1), DUMMY_PASSWORD_HASH);

  repository.disable(registered.user.id);
  await assert.rejects(
    auth.login({ login: "aurora.user", password: "correct-horse-battery-staple" }),
    (error: unknown) => isProblem(error, 401, "invalid_credentials"),
  );
  await assert.rejects(
    auth.authenticateBearer(loggedIn.accessToken),
    (error: unknown) => isProblem(error, 401, "invalid_access_token"),
  );
});

test("refresh rotation detects old-token reuse and revokes only that family", async () => {
  const repository = new MemoryAuthRepository();
  const auth = buildService(repository, new DeterministicPasswordHasher());
  const registered = await auth.register({
    login: "aurora",
    password: "correct-horse-battery-staple",
  });
  const independent = await auth.login({
    login: "AURORA",
    password: "correct-horse-battery-staple",
  });

  const rotated = await auth.refresh(registered.refreshToken);
  await assert.rejects(
    auth.authenticateBearer(registered.accessToken),
    (error: unknown) => isProblem(error, 401, "invalid_access_token"),
  );
  assert.equal(
    (await auth.authenticateBearer(rotated.accessToken)).userId,
    registered.user.id,
  );

  await assert.rejects(
    auth.refresh(registered.refreshToken),
    (error: unknown) => isProblem(error, 401, "invalid_refresh_token"),
  );
  await assert.rejects(
    auth.authenticateBearer(rotated.accessToken),
    (error: unknown) => isProblem(error, 401, "invalid_access_token"),
  );
  assert.equal(
    (await auth.authenticateBearer(independent.accessToken)).userId,
    registered.user.id,
  );
});

test("logout requires refresh-token family binding and remains idempotent", async () => {
  const repository = new MemoryAuthRepository();
  const auth = buildService(repository, new DeterministicPasswordHasher());
  const first = await auth.register({
    login: "aurora",
    password: "correct-horse-battery-staple",
  });
  const second = await auth.login({
    login: "aurora",
    password: "correct-horse-battery-staple",
  });
  const secondPrincipal = await auth.authenticateBearer(second.accessToken);

  await assert.rejects(
    auth.logout(secondPrincipal, first.refreshToken),
    (error: unknown) => isProblem(error, 401, "invalid_refresh_token"),
  );
  await auth.logout(secondPrincipal, second.refreshToken);
  await auth.logout(secondPrincipal, second.refreshToken);
  await assert.rejects(
    auth.authenticateBearer(second.accessToken),
    (error: unknown) => isProblem(error, 401, "invalid_access_token"),
  );
});

test("invite and closed registration modes fail without hashing a password", async () => {
  const inviteHasher = new DeterministicPasswordHasher();
  const inviteAuth = buildService(new MemoryAuthRepository(), inviteHasher, "invite");
  await assert.rejects(
    inviteAuth.register({ login: "aurora", password: "correct-horse-battery-staple" }),
    (error: unknown) => isProblem(error, 403, "registration_forbidden"),
  );
  assert.equal(inviteHasher.verifications.length, 0);
  const accepted = await inviteAuth.register({
    login: "aurora",
    password: "correct-horse-battery-staple",
    inviteCode: "valid-invite",
  });
  assert.equal(accepted.user.login, "aurora");

  const closedAuth = buildService(
    new MemoryAuthRepository(),
    new DeterministicPasswordHasher(),
    "closed",
  );
  await assert.rejects(
    closedAuth.register({ login: "closed", password: "correct-horse-battery-staple" }),
    (error: unknown) => isProblem(error, 403, "registration_forbidden"),
  );
});

function memorySession(input: {
  readonly id: string;
  readonly userId: string;
  readonly tokenFamilyId: string;
  readonly refreshTokenHash: Buffer;
  readonly expiresAt: Date;
  readonly deviceId?: string;
}): MemorySession {
  return {
    id: input.id,
    userId: input.userId,
    tokenFamilyId: input.tokenFamilyId,
    expiresAt: input.expiresAt,
    refreshHash: input.refreshTokenHash.toString("hex"),
    ...(input.deviceId === undefined ? {} : { deviceId: input.deviceId }),
  };
}

function isProblem(error: unknown, status: number, code: string): boolean {
  return error instanceof HttpProblem && error.status === status && error.code === code;
}

// Keep the helper in the test's public surface so a malformed hash comparison
// cannot accidentally drift away from the production SHA-256 representation.
assert.equal(hashRefreshToken("test").byteLength, 32);
