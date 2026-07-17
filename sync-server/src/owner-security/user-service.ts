import type { QueryResultRow } from "pg";

import type { Principal } from "../auth/principal.js";
import type { Database, Queryable } from "../db/database.js";
import {
  isoTimestamp,
  OwnerSecurityProblem,
  requireMatchingEtag,
  resourceEtag,
} from "./common.js";
import { executeIdempotentJson, type IdempotentResult } from "./idempotency.js";
import type {
  CreateEncryptionProfileInput,
  EncryptionProfileView,
  UpdateUserInput,
  UserView,
  Versioned,
} from "./models.js";

interface UserRow extends QueryResultRow {
  readonly id: string;
  readonly login: string;
  readonly display_name: string;
  readonly saros_anchor: number;
  readonly revision: string | number;
  readonly created_at: Date | string;
  readonly updated_at: Date | string;
}

interface EncryptionProfileRow extends QueryResultRow {
  readonly user_id: string;
  readonly crypto_version: 1;
  readonly key_version: 1;
  readonly key_check: Buffer;
  readonly created_at: Date | string;
}

export class UserSecurityService {
  constructor(private readonly database: Database) {}

  async getCurrentUser(userId: string): Promise<Versioned<UserView>> {
    const row = await findActiveUser(this.database, userId, false);
    if (row === undefined) {
      throw authenticationInvalid();
    }

    return versionedUser(row);
  }

  async updateCurrentUser(options: {
    readonly principal: Principal;
    readonly ifMatch: string | undefined;
    readonly input: UpdateUserInput;
    readonly requestId: string;
  }): Promise<Versioned<UserView>> {
    validateSarosAnchor(options.input.sarosAnchor);

    return this.database.transaction(async (client) => {
      const current = await findActiveUser(
        client,
        options.principal.userId,
        true,
      );
      if (current === undefined) {
        throw authenticationInvalid();
      }
      requireMatchingEtag(userEtag(current), options.ifMatch);

      const result = await client.query<UserRow>(
        `UPDATE users
         SET saros_anchor = $2
         WHERE id = $1 AND status = 'active'
         RETURNING id, login, display_name, saros_anchor, revision, created_at, updated_at`,
        [options.principal.userId, options.input.sarosAnchor],
      );
      const row = result.rows[0];
      if (row === undefined) {
        throw authenticationInvalid();
      }

      await client.query(
        `INSERT INTO audit_log (
           user_id, actor_type, actor_id, action, entity_type, entity_id,
           request_id, metadata
         ) VALUES ($1, $2, $3, 'user.saros_anchor.update', 'user', $1, $4, $5::jsonb)`,
        [
          options.principal.userId,
          options.principal.kind,
          options.principal.actorId,
          options.requestId,
          JSON.stringify({
            previousSarosAnchor: current.saros_anchor,
            sarosAnchor: row.saros_anchor,
          }),
        ],
      );
      return versionedUser(row);
    });
  }

  async getEncryptionProfile(userId: string): Promise<EncryptionProfileView> {
    const result = await this.database.query<EncryptionProfileRow>(
      `SELECT user_id, crypto_version, key_version, key_check, created_at
       FROM user_encryption_profiles
       WHERE user_id = $1`,
      [userId],
    );
    const row = result.rows[0];
    if (row === undefined) {
      throw new OwnerSecurityProblem({
        status: 404,
        code: "encryption_profile_not_found",
        detail: "No encryption recovery profile has been initialized.",
      });
    }
    return encryptionProfileView(row);
  }

  async initializeEncryptionProfile(options: {
    readonly principal: Principal;
    readonly input: CreateEncryptionProfileInput;
    readonly idempotencyKey: string;
    readonly requestId: string;
  }): Promise<IdempotentResult<EncryptionProfileView>> {
    validateEncryptionProfile(options.input);
    const keyCheck = Buffer.from(options.input.keyCheck, "base64");

    return this.database.transaction(async (client) =>
      executeIdempotentJson({
        client,
        principal: options.principal,
        operationId: "initializeEncryptionProfile",
        idempotencyKey: options.idempotencyKey,
        request: options.input,
        execute: async () => {
          const result = await client.query<EncryptionProfileRow>(
            `INSERT INTO user_encryption_profiles (
               user_id, crypto_version, key_version, key_check
             )
             VALUES ($1, 1, 1, $2)
             ON CONFLICT DO NOTHING
             RETURNING user_id, crypto_version, key_version, key_check, created_at`,
            [options.principal.userId, keyCheck],
          );
          const row = result.rows[0];
          if (row === undefined) {
            throw new OwnerSecurityProblem({
              status: 409,
              code: "encryption_profile_already_initialized",
              detail: "Crypto profile v1 is create-once for this user.",
            });
          }

          await client.query(
            `INSERT INTO audit_log (
               user_id, actor_type, actor_id, action, entity_type, entity_id,
               request_id, metadata
             )
             VALUES ($1, $2, $3, 'encryption_profile.initialize', 'user', $1, $4, '{}'::jsonb)`,
            [
              options.principal.userId,
              options.principal.kind,
              options.principal.actorId,
              options.requestId,
            ],
          );

          return {
            status: 201,
            headers: {},
            body: encryptionProfileView(row),
          };
        },
      }),
    );
  }
}

async function findActiveUser(
  queryable: Queryable,
  userId: string,
  forUpdate: boolean,
): Promise<UserRow | undefined> {
  const result = await queryable.query<UserRow>(
    `SELECT id, login, display_name, saros_anchor, revision, created_at, updated_at
     FROM users
     WHERE id = $1 AND status = 'active'
     ${forUpdate ? "FOR UPDATE" : ""}`,
    [userId],
  );
  return result.rows[0];
}

function versionedUser(row: UserRow): Versioned<UserView> {
  return {
    view: {
      id: row.id,
      login: row.login,
      displayName: row.display_name,
      sarosAnchor: row.saros_anchor,
      createdAt: isoTimestamp(row.created_at),
      updatedAt: isoTimestamp(row.updated_at),
    },
    etag: userEtag(row),
  };
}

function userEtag(row: UserRow): string {
  return resourceEtag("user", row.id, Number(row.revision));
}

function validateSarosAnchor(value: number): void {
  if (!Number.isInteger(value) || value < 1 || value > 180) {
    throw new OwnerSecurityProblem({
      status: 422,
      code: "invalid_saros_anchor",
      detail: "sarosAnchor must be an integer from 1 through 180.",
    });
  }
}

function authenticationInvalid(): OwnerSecurityProblem {
  return new OwnerSecurityProblem({
    status: 401,
    code: "authentication_invalid",
    detail: "The authenticated user is no longer active.",
  });
}

function validateEncryptionProfile(input: CreateEncryptionProfileInput): void {
  const bytes = Buffer.from(input.keyCheck, "base64");
  if (
    input.cryptoVersion !== 1 ||
    input.keyVersion !== 1 ||
    !/^[A-Za-z0-9+/]{43}=$/.test(input.keyCheck) ||
    bytes.byteLength !== 32 ||
    bytes.toString("base64") !== input.keyCheck
  ) {
    throw new OwnerSecurityProblem({
      status: 422,
      code: "invalid_encryption_profile",
      detail: "Crypto profile v1 requires a canonical base64-encoded 32-byte key check.",
    });
  }
}

function encryptionProfileView(row: EncryptionProfileRow): EncryptionProfileView {
  return {
    userId: row.user_id,
    cryptoVersion: row.crypto_version,
    keyVersion: row.key_version,
    keyCheck: row.key_check.toString("base64"),
    createdAt: isoTimestamp(row.created_at),
  };
}
