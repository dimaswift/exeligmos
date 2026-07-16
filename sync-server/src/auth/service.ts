import {
  createHash,
  randomBytes,
  randomUUID,
  timingSafeEqual,
} from "node:crypto";

import type { FastifyRequest } from "fastify";

import type { AuthConfig, RegistrationMode } from "../config.js";
import type { Database } from "../db/database.js";
import { HttpProblem } from "../http/problem.js";
import type { Authenticator, Principal } from "./principal.js";
import {
  AccessTokenCodec,
  InvalidAccessTokenError,
} from "./jwt.js";
import {
  type AuthRepository,
  type AuthUser,
  PostgresAuthRepository,
} from "./repository.js";
import {
  Argon2idPasswordHasher,
  DUMMY_PASSWORD_HASH,
  type PasswordHasher,
} from "./password.js";

const LOGIN_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const REFRESH_TOKEN_PATTERN = /^exr_[A-Za-z0-9_-]{43}$/;

export interface PublicUser {
  readonly id: string;
  readonly login: string;
  readonly displayName: string;
  readonly createdAt: string;
  readonly updatedAt: string;
}

export interface AuthSessionResponse {
  readonly tokenType: "Bearer";
  readonly accessToken: string;
  readonly expiresIn: number;
  readonly refreshToken: string;
  readonly refreshExpiresIn: number;
  readonly user: PublicUser;
}

export interface RegisterInput {
  readonly login: string;
  readonly password: string;
  readonly displayName?: string;
  readonly inviteCode?: string;
}

export interface LoginInput {
  readonly login: string;
  readonly password: string;
}

export interface AuthServiceOptions {
  readonly repository: AuthRepository;
  readonly passwordHasher: PasswordHasher;
  readonly accessTokens: AccessTokenCodec;
  readonly registrationMode: RegistrationMode;
  readonly registrationInviteCode?: string;
  readonly refreshTokenTtlSeconds: number;
  readonly clock?: () => Date;
  readonly idGenerator?: () => string;
  readonly refreshTokenGenerator?: () => string;
}

/** Password authentication, rotating sessions, and JWT request authentication. */
export class AuthService implements Authenticator {
  private readonly clock: () => Date;
  private readonly idGenerator: () => string;
  private readonly refreshTokenGenerator: () => string;

  constructor(private readonly options: AuthServiceOptions) {
    this.clock = options.clock ?? (() => new Date());
    this.idGenerator = options.idGenerator ?? randomUUID;
    this.refreshTokenGenerator = options.refreshTokenGenerator ?? createRefreshToken;
  }

  async register(input: RegisterInput): Promise<AuthSessionResponse> {
    this.assertRegistrationAllowed(input.inviteCode);
    const login = normalizeRegistrationLogin(input.login);
    assertPassword(input.password);
    const displayName = normalizeDisplayName(input.displayName ?? login);
    const passwordHash = await this.options.passwordHasher.hash(input.password);
    const now = this.clock();
    const refreshExpiresAt = addSeconds(now, this.options.refreshTokenTtlSeconds);
    const refreshToken = this.refreshTokenGenerator();
    const userId = this.idGenerator();
    const sessionId = this.idGenerator();
    const tokenFamilyId = this.idGenerator();

    try {
      const created = await this.options.repository.createAccountWithSession({
        userId,
        login,
        displayName,
        passwordHash,
        sessionId,
        tokenFamilyId,
        refreshTokenHash: hashRefreshToken(refreshToken),
        createdAt: now,
        expiresAt: refreshExpiresAt,
      });
      return this.issueSession(created.user, created.session.id, refreshToken, now);
    } catch (error) {
      if (isLoginConflict(error)) {
        throw new HttpProblem({
          status: 409,
          code: "login_conflict",
          title: "Conflict",
          type: "https://api.exeligmos.app/problems/login-conflict",
          detail: "That login is already registered.",
        });
      }
      throw error;
    }
  }

  async login(input: LoginInput): Promise<AuthSessionResponse> {
    const login = normalizeLoginForLookup(input.login);
    const account = login === undefined
      ? undefined
      : await this.options.repository.findAccountByLogin(login);
    const passwordMatches = await this.options.passwordHasher.verify(
      account?.passwordHash ?? DUMMY_PASSWORD_HASH,
      input.password,
    );

    if (account === undefined || !passwordMatches || account.status !== "active") {
      throw invalidCredentialsProblem();
    }

    if (this.options.passwordHasher.needsRehash(account.passwordHash)) {
      const replacementHash = await this.options.passwordHasher.hash(input.password);
      await this.options.repository.updatePasswordHash(
        account.id,
        account.passwordHash,
        replacementHash,
        this.clock(),
      );
    }

    const now = this.clock();
    const refreshToken = this.refreshTokenGenerator();
    const session = await this.options.repository.createSession({
      id: this.idGenerator(),
      userId: account.id,
      tokenFamilyId: this.idGenerator(),
      refreshTokenHash: hashRefreshToken(refreshToken),
      createdAt: now,
      expiresAt: addSeconds(now, this.options.refreshTokenTtlSeconds),
    });

    return this.issueSession(account, session.id, refreshToken, now);
  }

  async refresh(refreshToken: string): Promise<AuthSessionResponse> {
    if (!isRefreshToken(refreshToken)) {
      throw invalidRefreshTokenProblem();
    }

    const now = this.clock();
    const replacementRefreshToken = this.refreshTokenGenerator();
    const result = await this.options.repository.rotateSession({
      refreshTokenHash: hashRefreshToken(refreshToken),
      replacementSessionId: this.idGenerator(),
      replacementRefreshTokenHash: hashRefreshToken(replacementRefreshToken),
      replacementExpiresAt: addSeconds(now, this.options.refreshTokenTtlSeconds),
      now,
    });
    if (result.kind !== "rotated") {
      throw invalidRefreshTokenProblem();
    }

    return this.issueSession(
      result.user,
      result.session.id,
      replacementRefreshToken,
      now,
    );
  }

  async logout(principal: Principal, refreshToken: string): Promise<void> {
    if (principal.kind !== "jwt" || !isRefreshToken(refreshToken)) {
      throw invalidRefreshTokenProblem();
    }

    const revoked = await this.options.repository.revokeSessionFamily(
      principal.userId,
      principal.actorId,
      hashRefreshToken(refreshToken),
      this.clock(),
    );
    if (!revoked) {
      throw invalidRefreshTokenProblem();
    }
  }

  async authenticate(
    request: FastifyRequest,
    _requiredScopes?: readonly string[],
  ): Promise<Principal> {
    const authorization = request.headers.authorization;
    const match = authorization?.match(/^Bearer ([^\s,]+)$/i);
    if (match?.[1] === undefined) {
      throw invalidAccessTokenProblem();
    }

    return this.authenticateBearer(match[1]);
  }

  /**
   * Verifies the signed JWT without requiring its session to remain active.
   * This is intentionally exposed only to logout, where the matching refresh
   * family is checked before any state change, so a lost 204 can be retried.
   */
  async authenticateForLogout(request: FastifyRequest): Promise<Principal> {
    const authorization = request.headers.authorization;
    const match = authorization?.match(/^Bearer ([^\s,]+)$/i);
    if (match?.[1] === undefined) {
      throw invalidAccessTokenProblem();
    }

    const claims = await this.verifyAccessToken(match[1]);
    return {
      kind: "jwt",
      userId: claims.userId,
      actorId: claims.sessionId,
      scopes: new Set<string>(),
    };
  }

  async authenticateBearer(token: string): Promise<Principal> {
    const claims = await this.verifyAccessToken(token);

    const session = await this.options.repository.findActiveSession(
      claims.userId,
      claims.sessionId,
      this.clock(),
    );
    if (session === undefined) {
      throw invalidAccessTokenProblem();
    }

    return {
      kind: "jwt",
      userId: session.userId,
      actorId: session.sessionId,
      ...(session.deviceId === undefined ? {} : { deviceId: session.deviceId }),
      scopes: new Set<string>(),
    };
  }

  private async verifyAccessToken(token: string) {
    try {
      return await this.options.accessTokens.verify(token, this.clock());
    } catch (error) {
      if (error instanceof InvalidAccessTokenError) {
        throw invalidAccessTokenProblem();
      }
      throw error;
    }
  }

  private assertRegistrationAllowed(inviteCode: string | undefined): void {
    if (this.options.registrationMode === "open") {
      return;
    }

    if (
      this.options.registrationMode === "invite" &&
      this.options.registrationInviteCode !== undefined &&
      secretStringsEqual(inviteCode ?? "", this.options.registrationInviteCode)
    ) {
      return;
    }

    throw new HttpProblem({
      status: 403,
      code: "registration_forbidden",
      title: "Forbidden",
      type: "https://api.exeligmos.app/problems/registration-forbidden",
      detail: "Registration is not available with the supplied credentials.",
    });
  }

  private async issueSession(
    user: AuthUser,
    sessionId: string,
    refreshToken: string,
    now: Date,
  ): Promise<AuthSessionResponse> {
    const accessToken = await this.options.accessTokens.issue(
      { userId: user.id, sessionId, role: user.role },
      now,
    );

    return {
      tokenType: "Bearer",
      accessToken,
      expiresIn: this.options.accessTokens.expiresInSeconds,
      refreshToken,
      refreshExpiresIn: this.options.refreshTokenTtlSeconds,
      user: publicUser(user),
    };
  }
}

export function createAuthService(database: Database, config: AuthConfig): AuthService {
  return new AuthService({
    repository: new PostgresAuthRepository(database),
    passwordHasher: new Argon2idPasswordHasher(config.argon2MaxConcurrency),
    accessTokens: AccessTokenCodec.fromConfig(config),
    registrationMode: config.registrationMode,
    ...(config.registrationInviteCode === undefined
      ? {}
      : { registrationInviteCode: config.registrationInviteCode }),
    refreshTokenTtlSeconds: config.refreshTokenTtlSeconds,
  });
}

export function createRefreshToken(): string {
  return `exr_${randomBytes(32).toString("base64url")}`;
}

export function hashRefreshToken(token: string): Buffer {
  return createHash("sha256").update(token, "utf8").digest();
}

function isRefreshToken(token: string): boolean {
  return REFRESH_TOKEN_PATTERN.test(token);
}

function normalizeRegistrationLogin(login: string): string {
  const normalized = login.trim().toLowerCase();
  if (
    normalized.length < 3 ||
    normalized.length > 64 ||
    !LOGIN_PATTERN.test(normalized)
  ) {
    throw invalidRegistrationProblem("The login is invalid.");
  }
  return normalized;
}

function normalizeLoginForLookup(login: string): string | undefined {
  const normalized = login.trim().toLowerCase();
  return normalized.length >= 3 &&
    normalized.length <= 64 &&
    LOGIN_PATTERN.test(normalized)
    ? normalized
    : undefined;
}

function normalizeDisplayName(displayName: string): string {
  const normalized = displayName.trim();
  if (normalized.length < 1 || normalized.length > 120) {
    throw invalidRegistrationProblem("The display name is invalid.");
  }
  return normalized;
}

function assertPassword(password: string): void {
  if (password.length < 12 || password.length > 1_024) {
    throw invalidRegistrationProblem("The password must contain 12 to 1024 characters.");
  }
}

function publicUser(user: AuthUser): PublicUser {
  return {
    id: user.id,
    login: user.login,
    displayName: user.displayName,
    createdAt: user.createdAt.toISOString(),
    updatedAt: user.updatedAt.toISOString(),
  };
}

function addSeconds(date: Date, seconds: number): Date {
  return new Date(date.getTime() + seconds * 1_000);
}

function secretStringsEqual(left: string, right: string): boolean {
  const leftHash = createHash("sha256").update(left, "utf8").digest();
  const rightHash = createHash("sha256").update(right, "utf8").digest();
  return timingSafeEqual(leftHash, rightHash);
}

function isLoginConflict(error: unknown): boolean {
  return (
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    error.code === "23505" &&
    "constraint" in error &&
    error.constraint === "users_login_casefold_key"
  );
}

function invalidCredentialsProblem(): HttpProblem {
  return new HttpProblem({
    status: 401,
    code: "invalid_credentials",
    title: "Unauthorized",
    type: "https://api.exeligmos.app/problems/invalid-credentials",
    detail: "The login or password is incorrect.",
  });
}

function invalidRefreshTokenProblem(): HttpProblem {
  return new HttpProblem({
    status: 401,
    code: "invalid_refresh_token",
    title: "Unauthorized",
    type: "https://api.exeligmos.app/problems/invalid-refresh-token",
    detail: "The refresh token is invalid, expired, or revoked.",
  });
}

function invalidAccessTokenProblem(): HttpProblem {
  return new HttpProblem({
    status: 401,
    code: "invalid_access_token",
    title: "Unauthorized",
    type: "https://api.exeligmos.app/problems/invalid-access-token",
    detail: "The access token is missing, invalid, expired, or revoked.",
  });
}

function invalidRegistrationProblem(detail: string): HttpProblem {
  return new HttpProblem({
    status: 422,
    code: "invalid_registration",
    title: "Unprocessable Content",
    type: "https://api.exeligmos.app/problems/invalid-registration",
    detail,
  });
}
