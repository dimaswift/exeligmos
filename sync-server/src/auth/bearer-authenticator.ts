import { createHash } from "node:crypto";

import type { FastifyRequest } from "fastify";
import type { QueryResultRow } from "pg";

import type { Database } from "../db/database.js";
import { HttpProblem } from "../http/problem.js";
import type {
  ApiKeyScope,
  Authenticator,
  Principal,
} from "./principal.js";

interface ApiKeyPrincipalRow extends QueryResultRow {
  readonly id: string;
  readonly user_id: string;
  readonly device_id: string;
  readonly scopes: string[];
}

const API_KEY_MAX_LENGTH = 512;

/** Dispatches one Bearer credential to JWT or opaque API-key authentication. */
export class BearerAuthenticator implements Authenticator {
  constructor(
    private readonly database: Database,
    private readonly jwtAuthenticator: Authenticator,
  ) {}

  async authenticate(
    request: FastifyRequest,
    requiredScopes: readonly ApiKeyScope[] | readonly string[] = [],
  ): Promise<Principal> {
    const token = readBearerToken(request);
    if (!token.startsWith("exk_")) {
      return this.jwtAuthenticator.authenticate(request, requiredScopes);
    }

    if (token.length > API_KEY_MAX_LENGTH) {
      throw unauthorized();
    }

    const tokenHash = createHash("sha256").update(token, "utf8").digest();
    const result = await this.database.query<ApiKeyPrincipalRow>(
      `SELECT api_keys.id, api_keys.user_id, api_keys.device_id, api_keys.scopes
       FROM api_keys
       JOIN users ON users.id = api_keys.user_id
       JOIN devices
         ON devices.user_id = api_keys.user_id
        AND devices.id = api_keys.device_id
       WHERE api_keys.key_hash = $1
         AND api_keys.revoked_at IS NULL
         AND (api_keys.expires_at IS NULL OR api_keys.expires_at > now())
         AND users.status = 'active'
         AND devices.revoked_at IS NULL`,
      [tokenHash],
    );
    const row = result.rows[0];
    if (row === undefined) {
      throw unauthorized();
    }

    const scopes = new Set(row.scopes);
    const missingScopes = requiredScopes.filter((scope) => !scopes.has(scope));
    if (missingScopes.length > 0) {
      throw new HttpProblem({
        status: 403,
        code: "insufficient_scope",
        type: "urn:exeligmos:problem:insufficient-scope",
        detail: "The API key does not grant every scope required by this operation.",
        extensions: { requiredScopes: missingScopes },
      });
    }

    // Avoid a write hotspot while retaining useful operational activity data.
    await this.database.query(
      `UPDATE api_keys
       SET last_used_at = now()
       WHERE id = $1
         AND (last_used_at IS NULL OR last_used_at < now() - interval '5 minutes')`,
      [row.id],
    );

    return {
      kind: "api_key",
      userId: row.user_id,
      actorId: row.id,
      deviceId: row.device_id,
      scopes,
    };
  }
}

function readBearerToken(request: FastifyRequest): string {
  const authorization = request.headers.authorization;
  if (authorization === undefined) {
    throw unauthorized();
  }

  const match = /^Bearer ([^\s]+)$/i.exec(authorization);
  if (match?.[1] === undefined) {
    throw unauthorized();
  }

  return match[1];
}

function unauthorized(): HttpProblem {
  return new HttpProblem({
    status: 401,
    code: "invalid_token",
    type: "urn:exeligmos:problem:invalid-token",
    detail: "A valid Bearer credential is required.",
  });
}

