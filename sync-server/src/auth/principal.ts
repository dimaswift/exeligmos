import type { FastifyRequest } from "fastify";

export const API_KEY_SCOPES = [
  "records:read",
  "records:write",
  "events:read",
  "events:write",
  "tags:read",
  "tags:write",
  "templates:read",
  "templates:write",
  "media:read",
  "media:write",
  "devices:read",
  "subscriptions:read",
  "subscriptions:write",
  "sync:read",
  "sync:write",
] as const;

export type ApiKeyScope = (typeof API_KEY_SCOPES)[number];

export interface Principal {
  readonly kind: "jwt" | "api_key";
  readonly userId: string;
  /** Session ID for JWTs or API-key ID for API keys. */
  readonly actorId: string;
  /** Present for a device-bound API key and optional for a JWT session. */
  readonly deviceId?: string;
  /** Empty for JWTs. JWT account access is not scope-limited. */
  readonly scopes: ReadonlySet<string>;
}

export interface Authenticator {
  authenticate(
    request: FastifyRequest,
    requiredScopes?: readonly ApiKeyScope[] | readonly string[],
  ): Promise<Principal>;
}
