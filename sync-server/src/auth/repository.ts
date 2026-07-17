import type { QueryResultRow } from "pg";

import type { Database, Queryable } from "../db/database.js";
import type { AccountRole } from "./jwt.js";

export type AccountStatus = "active" | "disabled";

export interface AuthUser {
  readonly id: string;
  readonly login: string;
  readonly displayName: string;
  readonly sarosAnchor: number;
  readonly role: AccountRole;
  readonly createdAt: Date;
  readonly updatedAt: Date;
}

export interface PasswordAccount extends AuthUser {
  readonly passwordHash: string;
  readonly status: AccountStatus;
}

export interface SessionIdentity {
  readonly id: string;
  readonly userId: string;
  readonly tokenFamilyId: string;
  readonly deviceId?: string;
  readonly expiresAt: Date;
}

export interface CreateAccountWithSessionInput {
  readonly userId: string;
  readonly login: string;
  readonly displayName: string;
  readonly passwordHash: string;
  readonly sessionId: string;
  readonly tokenFamilyId: string;
  readonly refreshTokenHash: Buffer;
  readonly createdAt: Date;
  readonly expiresAt: Date;
}

export interface CreateSessionInput {
  readonly id: string;
  readonly userId: string;
  readonly tokenFamilyId: string;
  readonly refreshTokenHash: Buffer;
  readonly createdAt: Date;
  readonly expiresAt: Date;
}

export interface RotateSessionInput {
  readonly refreshTokenHash: Buffer;
  readonly replacementSessionId: string;
  readonly replacementRefreshTokenHash: Buffer;
  readonly replacementExpiresAt: Date;
  readonly now: Date;
}

export type RotateSessionResult =
  | {
      readonly kind: "rotated";
      readonly user: AuthUser;
      readonly session: SessionIdentity;
    }
  | { readonly kind: "invalid" }
  | { readonly kind: "reuse" };

export interface ActiveSession {
  readonly userId: string;
  readonly sessionId: string;
  readonly deviceId?: string;
}

export interface AuthRepository {
  createAccountWithSession(
    input: CreateAccountWithSessionInput,
  ): Promise<{ readonly user: AuthUser; readonly session: SessionIdentity }>;
  findAccountByLogin(login: string): Promise<PasswordAccount | undefined>;
  updatePasswordHash(
    userId: string,
    previousHash: string,
    replacementHash: string,
    now: Date,
  ): Promise<void>;
  createSession(input: CreateSessionInput): Promise<SessionIdentity>;
  rotateSession(input: RotateSessionInput): Promise<RotateSessionResult>;
  findActiveSession(
    userId: string,
    sessionId: string,
    now: Date,
  ): Promise<ActiveSession | undefined>;
  revokeSessionFamily(
    userId: string,
    actorSessionId: string,
    refreshTokenHash: Buffer,
    now: Date,
  ): Promise<boolean>;
}

interface AccountRow extends QueryResultRow {
  readonly id: string;
  readonly login: string;
  readonly display_name: string;
  readonly saros_anchor: number;
  readonly password_hash: string;
  readonly role: AccountRole;
  readonly status: AccountStatus;
  readonly created_at: Date;
  readonly updated_at: Date;
}

interface SessionRow extends QueryResultRow {
  readonly id: string;
  readonly user_id: string;
  readonly device_id: string | null;
  readonly token_family_id: string;
  readonly expires_at: Date;
}

interface RefreshLookupRow extends QueryResultRow {
  readonly token_family_id: string;
}

interface RefreshFamilyLookupRow extends RefreshLookupRow {
  readonly user_id: string;
  readonly device_id: string | null;
}

interface RefreshDeviceStateRow extends QueryResultRow {
  readonly revoked_at: Date | null;
}

interface RefreshSessionRow extends AccountRow, SessionRow {
  readonly session_id: string;
  readonly user_id: string;
  readonly device_id: string | null;
  readonly token_family_id: string;
  readonly session_expires_at: Date;
  readonly revoked_at: Date | null;
  readonly revoke_reason: string | null;
}

interface ActiveSessionRow extends QueryResultRow {
  readonly user_id: string;
  readonly session_id: string;
  readonly device_id: string | null;
}

const FAMILY_LOCK_NAMESPACE = 2_026_071_401;

export class PostgresAuthRepository implements AuthRepository {
  constructor(private readonly database: Database) {}

  async createAccountWithSession(
    input: CreateAccountWithSessionInput,
  ): Promise<{ readonly user: AuthUser; readonly session: SessionIdentity }> {
    return this.database.transaction(async (client) => {
      const accountResult = await client.query<AccountRow>(
        `INSERT INTO users (
           id, login, display_name, password_hash, created_at, updated_at
         ) VALUES ($1, $2, $3, $4, $5, $5)
         RETURNING id, login, display_name, saros_anchor, password_hash, role, status,
                   created_at, updated_at`,
        [
          input.userId,
          input.login,
          input.displayName,
          input.passwordHash,
          input.createdAt,
        ],
      );
      const sessionResult = await client.query<SessionRow>(
        `INSERT INTO auth_sessions (
           id, user_id, token_family_id, refresh_token_hash, created_at, expires_at
         ) VALUES ($1, $2, $3, $4, $5, $6)
         RETURNING id, user_id, device_id, token_family_id, expires_at`,
        [
          input.sessionId,
          input.userId,
          input.tokenFamilyId,
          input.refreshTokenHash,
          input.createdAt,
          input.expiresAt,
        ],
      );

      return {
        user: mapUser(requiredRow(accountResult.rows[0])),
        session: mapSession(requiredRow(sessionResult.rows[0])),
      };
    });
  }

  async findAccountByLogin(login: string): Promise<PasswordAccount | undefined> {
    const result = await this.database.query<AccountRow>(
      `SELECT id, login, display_name, saros_anchor, password_hash, role, status,
              created_at, updated_at
       FROM users
       WHERE lower(login) = lower($1)
       LIMIT 1`,
      [login],
    );
    const row = result.rows[0];
    if (row === undefined) {
      return undefined;
    }

    return {
      ...mapUser(row),
      passwordHash: row.password_hash,
      status: row.status,
    };
  }

  async updatePasswordHash(
    userId: string,
    previousHash: string,
    replacementHash: string,
    now: Date,
  ): Promise<void> {
    await this.database.query(
      `UPDATE users
       SET password_hash = $3, updated_at = $4
       WHERE id = $1 AND password_hash = $2`,
      [userId, previousHash, replacementHash, now],
    );
  }

  async createSession(input: CreateSessionInput): Promise<SessionIdentity> {
    const result = await this.database.query<SessionRow>(
      `INSERT INTO auth_sessions (
         id, user_id, token_family_id, refresh_token_hash, created_at, expires_at
       ) VALUES ($1, $2, $3, $4, $5, $6)
       RETURNING id, user_id, device_id, token_family_id, expires_at`,
      [
        input.id,
        input.userId,
        input.tokenFamilyId,
        input.refreshTokenHash,
        input.createdAt,
        input.expiresAt,
      ],
    );

    return mapSession(requiredRow(result.rows[0]));
  }

  async rotateSession(input: RotateSessionInput): Promise<RotateSessionResult> {
    return this.database.transaction(async (client) => {
      const initial = await client.query<RefreshFamilyLookupRow>(
        `SELECT token_family_id, user_id, device_id
         FROM auth_sessions
         WHERE refresh_token_hash = $1`,
        [input.refreshTokenHash],
      );
      const initialSession = initial.rows[0];
      if (initialSession === undefined) {
        return { kind: "invalid" };
      }

      // Lock an attached device before the token family/session. Device
      // revocation takes locks in the same device -> session order, so a
      // successful rotation cannot escape a concurrent revocation transaction.
      if (initialSession.device_id !== null) {
        const device = await client.query<RefreshDeviceStateRow>(
          `SELECT revoked_at
           FROM devices
           WHERE user_id = $1 AND id = $2
           FOR SHARE`,
          [initialSession.user_id, initialSession.device_id],
        );
        if (device.rows[0] === undefined || device.rows[0].revoked_at !== null) {
          await lockTokenFamily(client, initialSession.token_family_id);
          await revokeFamily(
            client,
            initialSession.user_id,
            initialSession.token_family_id,
            input.now,
            "device_revoked",
          );
          return { kind: "invalid" };
        }
      }

      await lockTokenFamily(client, initialSession.token_family_id);
      const result = await client.query<RefreshSessionRow>(
        `SELECT
           u.id, u.login, u.display_name, u.saros_anchor, u.password_hash, u.role, u.status,
           u.created_at, u.updated_at,
           s.id AS session_id, s.user_id, s.device_id, s.token_family_id,
           s.expires_at AS session_expires_at, s.revoked_at, s.revoke_reason
         FROM auth_sessions AS s
         JOIN users AS u ON u.id = s.user_id
         WHERE s.refresh_token_hash = $1
         FOR UPDATE OF s`,
        [input.refreshTokenHash],
      );
      const row = result.rows[0];
      if (row === undefined) {
        return { kind: "invalid" };
      }

      // Session binding can race the initial lookup. Fail closed and let the
      // caller retry rather than rotate without holding the actual device lock.
      if (row.device_id !== initialSession.device_id) {
        return { kind: "invalid" };
      }

      if (row.revoked_at !== null) {
        if (row.revoke_reason === "rotated" || row.revoke_reason === "refresh_token_reuse") {
          await revokeFamily(client, row.user_id, row.token_family_id, input.now, "refresh_token_reuse");
          return { kind: "reuse" };
        }
        return { kind: "invalid" };
      }

      if (asDate(row.session_expires_at).getTime() <= input.now.getTime()) {
        await client.query(
          `UPDATE auth_sessions
           SET revoked_at = $2, revoke_reason = 'expired', last_used_at = $2
           WHERE id = $1 AND revoked_at IS NULL`,
          [row.session_id, input.now],
        );
        return { kind: "invalid" };
      }

      if (row.status !== "active") {
        await revokeFamily(client, row.user_id, row.token_family_id, input.now, "user_disabled");
        return { kind: "invalid" };
      }

      await client.query(
        `UPDATE auth_sessions
         SET revoked_at = $2, revoke_reason = 'rotated', last_used_at = $2
         WHERE id = $1 AND revoked_at IS NULL`,
        [row.session_id, input.now],
      );
      const replacement = await client.query<SessionRow>(
        `INSERT INTO auth_sessions (
           id, user_id, device_id, token_family_id, refresh_token_hash,
           rotated_from_session_id, created_at, expires_at
         ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
         RETURNING id, user_id, device_id, token_family_id, expires_at`,
        [
          input.replacementSessionId,
          row.user_id,
          row.device_id,
          row.token_family_id,
          input.replacementRefreshTokenHash,
          row.session_id,
          input.now,
          input.replacementExpiresAt,
        ],
      );

      return {
        kind: "rotated",
        user: mapUser(row),
        session: mapSession(requiredRow(replacement.rows[0])),
      };
    });
  }

  async findActiveSession(
    userId: string,
    sessionId: string,
    now: Date,
  ): Promise<ActiveSession | undefined> {
    const result = await this.database.query<ActiveSessionRow>(
      `SELECT s.user_id, s.id AS session_id, s.device_id
       FROM auth_sessions AS s
       JOIN users AS u ON u.id = s.user_id
       LEFT JOIN devices AS d
         ON d.user_id = s.user_id AND d.id = s.device_id
       WHERE s.user_id = $1
         AND s.id = $2
         AND s.revoked_at IS NULL
         AND s.expires_at > $3
         AND u.status = 'active'
         AND (s.device_id IS NULL OR d.revoked_at IS NULL)`,
      [userId, sessionId, now],
    );
    const row = result.rows[0];
    if (row === undefined) {
      return undefined;
    }

    return {
      userId: row.user_id,
      sessionId: row.session_id,
      ...(row.device_id === null ? {} : { deviceId: row.device_id }),
    };
  }

  async revokeSessionFamily(
    userId: string,
    actorSessionId: string,
    refreshTokenHash: Buffer,
    now: Date,
  ): Promise<boolean> {
    return this.database.transaction(async (client) => {
      const lookup = await client.query<RefreshLookupRow>(
        `SELECT token_family_id
         FROM auth_sessions
         WHERE user_id = $1 AND refresh_token_hash = $2`,
        [userId, refreshTokenHash],
      );
      const familyId = lookup.rows[0]?.token_family_id;
      if (familyId === undefined) {
        return false;
      }

      await lockTokenFamily(client, familyId);
      const matched = await client.query<RefreshLookupRow>(
        `SELECT target.token_family_id
         FROM auth_sessions AS target
         JOIN auth_sessions AS actor
           ON actor.user_id = target.user_id
          AND actor.token_family_id = target.token_family_id
         WHERE target.user_id = $1
           AND target.refresh_token_hash = $2
           AND actor.id = $3
         LIMIT 1`,
        [userId, refreshTokenHash, actorSessionId],
      );
      if (matched.rows[0] === undefined) {
        return false;
      }

      await revokeFamily(client, userId, familyId, now, "logout");
      return true;
    });
  }
}

async function lockTokenFamily(client: Queryable, familyId: string): Promise<void> {
  await client.query(
    "SELECT pg_advisory_xact_lock(hashtextextended($1::text, $2))",
    [familyId, FAMILY_LOCK_NAMESPACE],
  );
}

async function revokeFamily(
  client: Queryable,
  userId: string,
  familyId: string,
  now: Date,
  reason: string,
): Promise<void> {
  await client.query(
    `UPDATE auth_sessions
     SET revoked_at = COALESCE(revoked_at, $3),
         revoke_reason = CASE WHEN revoked_at IS NULL THEN $4 ELSE revoke_reason END
     WHERE user_id = $1 AND token_family_id = $2`,
    [userId, familyId, now, reason],
  );
}

function mapUser(row: AccountRow): AuthUser {
  return {
    id: row.id,
    login: row.login,
    displayName: row.display_name,
    sarosAnchor: row.saros_anchor,
    role: row.role,
    createdAt: asDate(row.created_at),
    updatedAt: asDate(row.updated_at),
  };
}

function mapSession(row: SessionRow): SessionIdentity {
  return {
    id: row.id,
    userId: row.user_id,
    tokenFamilyId: row.token_family_id,
    ...(row.device_id === null ? {} : { deviceId: row.device_id }),
    expiresAt: asDate(row.expires_at),
  };
}

function requiredRow<Row>(row: Row | undefined): Row {
  if (row === undefined) {
    throw new Error("Database mutation did not return the created row");
  }
  return row;
}

function asDate(value: Date): Date {
  return value instanceof Date ? value : new Date(value);
}
