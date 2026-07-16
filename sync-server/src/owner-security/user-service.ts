import type { QueryResultRow } from "pg";

import type { Principal } from "../auth/principal.js";
import type { Database } from "../db/database.js";
import {
  isoTimestamp,
  OwnerSecurityProblem,
  resourceEtag,
} from "./common.js";
import { executeIdempotentJson, type IdempotentResult } from "./idempotency.js";
import type {
  CreateEncryptionProfileInput,
  EncryptionProfileView,
  UserView,
  Versioned,
} from "./models.js";

interface UserRow extends QueryResultRow {
  readonly id: string;
  readonly login: string;
  readonly display_name: string;
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
    const result = await this.database.query<UserRow>(
      `SELECT id, login, display_name, revision, created_at, updated_at
       FROM users
       WHERE id = $1 AND status = 'active'`,
      [userId],
    );
    const row = result.rows[0];
    if (row === undefined) {
      throw new OwnerSecurityProblem({
        status: 401,
        code: "authentication_invalid",
        detail: "The authenticated user is no longer active.",
      });
    }

    const revision = Number(row.revision);
    return {
      view: {
        id: row.id,
        login: row.login,
        displayName: row.display_name,
        createdAt: isoTimestamp(row.created_at),
        updatedAt: isoTimestamp(row.updated_at),
      },
      etag: resourceEtag("user", row.id, revision),
    };
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

