import type {
  FastifyInstance,
  FastifyReply,
  FastifyRequest,
} from "fastify";

import {
  API_KEY_SCOPES,
  type ApiKeyScope,
  type Authenticator,
  type Principal,
} from "../auth/principal.js";
import type { Database } from "../db/database.js";
import { ApiKeyService, type ApiKeyServiceOptions } from "../owner-security/api-key-service.js";
import {
  assertIdempotencyKey,
  OwnerSecurityProblem,
} from "../owner-security/common.js";
import { DeviceService } from "../owner-security/device-service.js";
import type {
  CreateApiKeyInput,
  CreateDeviceInput,
  CreateEncryptionProfileInput,
  UpdateDeviceInput,
} from "../owner-security/models.js";
import { UserSecurityService } from "../owner-security/user-service.js";
import {
  NOOP_RESOURCE_REQUEST_LIMITER,
  type ResourceRequestLimiter,
} from "../resources/rate-limit.js";

export interface OwnerSecurityRoutesOptions {
  readonly database: Database;
  readonly authenticator: Authenticator;
  readonly apiKeys?: ApiKeyServiceOptions;
  /** Omitted by isolated route tests; buildApp injects the shared limiter. */
  readonly requestLimiter?: ResourceRequestLimiter;
}

interface ListQuery {
  readonly cursor?: string;
  readonly limit?: number;
}

interface DeviceParams {
  readonly deviceId: string;
}

interface ApiKeyParams {
  readonly apiKeyId: string;
}

interface IdempotencyHeaders {
  readonly "idempotency-key"?: string;
}

interface IfMatchHeaders {
  readonly "if-match"?: string;
}

export async function registerOwnerSecurityRoutes(
  app: FastifyInstance,
  options: OwnerSecurityRoutesOptions,
): Promise<void> {
  const users = new UserSecurityService(options.database);
  const devices = new DeviceService(options.database);
  const apiKeys = new ApiKeyService(options.database, options.apiKeys);
  const requestLimiter = options.requestLimiter ?? NOOP_RESOURCE_REQUEST_LIMITER;

  app.get("/v1/me", async (request, reply) =>
    withOwnerSecurityErrors(reply, async () => {
      const principal = await options.authenticator.authenticate(request);
      await requestLimiter.checkAuthenticatedRead(request, principal);
      const result = await users.getCurrentUser(principal.userId);
      return reply.header("etag", result.etag).send(result.view);
    }),
  );

  app.get("/v1/me/encryption-profile", async (request, reply) =>
    withOwnerSecurityErrors(reply, async () => {
      const principal = await authenticateJwt(options.authenticator, request);
      await requestLimiter.checkAuthenticatedRead(request, principal);
      return reply.send(await users.getEncryptionProfile(principal.userId));
    }),
  );

  app.post<{
    Body: CreateEncryptionProfileInput;
    Headers: IdempotencyHeaders;
  }>(
    "/v1/me/encryption-profile",
    { schema: encryptionProfileCreateSchema },
    async (request, reply) =>
      withOwnerSecurityErrors(reply, async () => {
        const principal = await authenticateJwt(options.authenticator, request);
        await requestLimiter.checkAuthenticatedWrite(request, principal);
        const result = await users.initializeEncryptionProfile({
          principal,
          input: request.body,
          idempotencyKey: assertIdempotencyKey(request.headers["idempotency-key"]),
          requestId: request.id,
        });
        applyHeaders(reply, result.headers);
        return reply.status(result.status).send(result.body);
      }),
  );

  app.get<{ Querystring: ListQuery }>(
    "/v1/devices",
    { schema: listSchema },
    async (request, reply) =>
      withOwnerSecurityErrors(reply, async () => {
        const principal = await options.authenticator.authenticate(request, ["devices:read"]);
        await requestLimiter.checkAuthenticatedRead(request, principal);
        return reply.send(
          await devices.list({
            userId: principal.userId,
            ...(request.query.cursor === undefined ? {} : { cursor: request.query.cursor }),
            ...(request.query.limit === undefined ? {} : { limit: request.query.limit }),
          }),
        );
      }),
  );

  app.post<{
    Body: CreateDeviceInput;
    Headers: IdempotencyHeaders;
  }>(
    "/v1/devices",
    { schema: createDeviceSchema },
    async (request, reply) =>
      withOwnerSecurityErrors(reply, async () => {
        const principal = await authenticateJwt(options.authenticator, request);
        await requestLimiter.checkAuthenticatedWrite(request, principal);
        const result = await devices.register({
          principal,
          input: request.body,
          idempotencyKey: assertIdempotencyKey(request.headers["idempotency-key"]),
          requestId: request.id,
        });
        applyHeaders(reply, result.headers);
        return reply.status(result.status).send(result.body);
      }),
  );

  app.get<{ Params: DeviceParams }>(
    "/v1/devices/:deviceId",
    { schema: deviceParamsSchema },
    async (request, reply) =>
      withOwnerSecurityErrors(reply, async () => {
        const principal = await options.authenticator.authenticate(request, ["devices:read"]);
        await requestLimiter.checkAuthenticatedRead(request, principal);
        const result = await devices.get(principal.userId, request.params.deviceId);
        return reply.header("etag", result.etag).send(result.view);
      }),
  );

  app.patch<{
    Params: DeviceParams;
    Headers: IfMatchHeaders;
    Body: UpdateDeviceInput;
  }>(
    "/v1/devices/:deviceId",
    { schema: updateDeviceSchema },
    async (request, reply) =>
      withOwnerSecurityErrors(reply, async () => {
        const principal = await authenticateJwt(options.authenticator, request);
        await requestLimiter.checkAuthenticatedWrite(request, principal);
        const result = await devices.update({
          principal,
          deviceId: request.params.deviceId,
          ifMatch: request.headers["if-match"],
          input: request.body,
          requestId: request.id,
        });
        return reply.header("etag", result.etag).send(result.view);
      }),
  );

  app.delete<{ Params: DeviceParams; Headers: IfMatchHeaders }>(
    "/v1/devices/:deviceId",
    { schema: deleteDeviceSchema },
    async (request, reply) =>
      withOwnerSecurityErrors(reply, async () => {
        const principal = await authenticateJwt(options.authenticator, request);
        await requestLimiter.checkAuthenticatedWrite(request, principal);
        await devices.revoke({
          principal,
          deviceId: request.params.deviceId,
          ifMatch: request.headers["if-match"],
          requestId: request.id,
        });
        return reply.status(204).send();
      }),
  );

  app.put<{ Params: DeviceParams }>(
    "/v1/devices/:deviceId/current-session",
    { schema: deviceParamsSchema },
    async (request, reply) =>
      withOwnerSecurityErrors(reply, async () => {
        const principal = await authenticateJwt(options.authenticator, request);
        await requestLimiter.checkAuthenticatedWrite(request, principal);
        await devices.bindCurrentSession({
          principal,
          deviceId: request.params.deviceId,
          requestId: request.id,
        });
        return reply.status(204).send();
      }),
  );

  app.get<{ Querystring: ListQuery }>(
    "/v1/api-keys",
    { schema: listSchema },
    async (request, reply) =>
      withOwnerSecurityErrors(reply, async () => {
        const principal = await authenticateJwt(options.authenticator, request);
        await requestLimiter.checkAuthenticatedRead(request, principal);
        return reply.send(
          await apiKeys.list({
            userId: principal.userId,
            ...(request.query.cursor === undefined ? {} : { cursor: request.query.cursor }),
            ...(request.query.limit === undefined ? {} : { limit: request.query.limit }),
          }),
        );
      }),
  );

  app.post<{ Body: CreateApiKeyInput; Headers: IdempotencyHeaders }>(
    "/v1/api-keys",
    { schema: createApiKeySchema },
    async (request, reply) =>
      withOwnerSecurityErrors(reply, async () => {
        const principal = await authenticateJwt(options.authenticator, request);
        await requestLimiter.checkAuthenticatedWrite(request, principal);
        const result = await apiKeys.create({
          principal,
          input: request.body,
          idempotencyKey: assertIdempotencyKey(request.headers["idempotency-key"]),
          requestId: request.id,
        });
        return reply
          .status(201)
          .header("etag", result.etag)
          .header("location", result.location)
          .send({ key: result.key, secret: result.secret });
      }),
  );

  app.get<{ Params: ApiKeyParams }>(
    "/v1/api-keys/:apiKeyId",
    { schema: apiKeyParamsSchema },
    async (request, reply) =>
      withOwnerSecurityErrors(reply, async () => {
        const principal = await authenticateJwt(options.authenticator, request);
        await requestLimiter.checkAuthenticatedRead(request, principal);
        const result = await apiKeys.get(principal.userId, request.params.apiKeyId);
        return reply.header("etag", result.etag).send(result.view);
      }),
  );

  app.delete<{ Params: ApiKeyParams }>(
    "/v1/api-keys/:apiKeyId",
    { schema: apiKeyParamsSchema },
    async (request, reply) =>
      withOwnerSecurityErrors(reply, async () => {
        const principal = await authenticateJwt(options.authenticator, request);
        await requestLimiter.checkAuthenticatedWrite(request, principal);
        await apiKeys.revoke({
          principal,
          apiKeyId: request.params.apiKeyId,
          requestId: request.id,
        });
        return reply.status(204).send();
      }),
  );
}

async function authenticateJwt(
  authenticator: Authenticator,
  request: FastifyRequest,
): Promise<Principal> {
  const principal = await authenticator.authenticate(request);
  if (principal.kind !== "jwt") {
    throw new OwnerSecurityProblem({
      status: 403,
      code: "jwt_required",
      detail: "This operation requires an authenticated user session.",
    });
  }
  return principal;
}

async function withOwnerSecurityErrors<Result>(
  reply: FastifyReply,
  work: () => Promise<Result>,
): Promise<Result> {
  try {
    return await work();
  } catch (error) {
    if (error instanceof OwnerSecurityProblem && error.etag !== undefined) {
      reply.header("etag", error.etag);
    }
    throw error;
  }
}

function applyHeaders(reply: FastifyReply, headers: Readonly<Record<string, string>>): void {
  for (const [name, value] of Object.entries(headers)) {
    reply.header(name, value);
  }
}

const UUID_SCHEMA = { type: "string", format: "uuid" } as const;
const IDEMPOTENCY_HEADER_SCHEMA = {
  type: "object",
  required: ["idempotency-key"],
  properties: {
    "idempotency-key": {
      type: "string",
      minLength: 8,
      maxLength: 255,
      pattern: "^[\\x21-\\x7E]+$",
    },
  },
} as const;
const IF_MATCH_HEADER_SCHEMA = {
  type: "object",
  required: ["if-match"],
  properties: { "if-match": { type: "string", minLength: 3, maxLength: 200 } },
} as const;
const DEVICE_PARAMS = {
  type: "object",
  required: ["deviceId"],
  properties: { deviceId: UUID_SCHEMA },
  additionalProperties: false,
} as const;
const API_KEY_PARAMS = {
  type: "object",
  required: ["apiKeyId"],
  properties: { apiKeyId: UUID_SCHEMA },
  additionalProperties: false,
} as const;

const listSchema = {
  querystring: {
    type: "object",
    properties: {
      cursor: { type: "string", minLength: 1, maxLength: 2048 },
      limit: { type: "integer", minimum: 1, maximum: 200, default: 50 },
    },
    additionalProperties: false,
  },
} as const;
const deviceParamsSchema = { params: DEVICE_PARAMS } as const;
const apiKeyParamsSchema = { params: API_KEY_PARAMS } as const;
const encryptionProfileCreateSchema = {
  headers: IDEMPOTENCY_HEADER_SCHEMA,
  body: {
    type: "object",
    required: ["cryptoVersion", "keyVersion", "keyCheck"],
    properties: {
      cryptoVersion: { type: "integer", const: 1 },
      keyVersion: { type: "integer", const: 1 },
      keyCheck: {
        type: "string",
        minLength: 44,
        maxLength: 44,
        pattern: "^[A-Za-z0-9+/]{43}=$",
      },
    },
    additionalProperties: false,
  },
} as const;
const createDeviceSchema = {
  headers: IDEMPOTENCY_HEADER_SCHEMA,
  body: {
    type: "object",
    required: ["name", "kind"],
    properties: {
      id: UUID_SCHEMA,
      name: { type: "string", minLength: 1, maxLength: 120 },
      kind: { type: "string", enum: ["ios", "macos", "web", "agent", "server", "other"] },
      platform: { type: "string", minLength: 1, maxLength: 80 },
      appVersion: { type: "string", minLength: 1, maxLength: 80 },
      metadata: { type: "object", additionalProperties: true, default: {} },
    },
    additionalProperties: false,
  },
} as const;
const updateDeviceSchema = {
  params: DEVICE_PARAMS,
  headers: IF_MATCH_HEADER_SCHEMA,
  body: {
    type: "object",
    minProperties: 1,
    properties: {
      name: { type: "string", minLength: 1, maxLength: 120 },
      platform: { type: "string", minLength: 1, maxLength: 80 },
      appVersion: { type: "string", minLength: 1, maxLength: 80 },
      metadata: { type: "object", additionalProperties: true },
    },
    additionalProperties: false,
  },
} as const;
const deleteDeviceSchema = { params: DEVICE_PARAMS, headers: IF_MATCH_HEADER_SCHEMA } as const;
const createApiKeySchema = {
  headers: IDEMPOTENCY_HEADER_SCHEMA,
  body: {
    type: "object",
    required: ["name", "deviceId", "scopes"],
    properties: {
      name: { type: "string", minLength: 1, maxLength: 120 },
      deviceId: UUID_SCHEMA,
      scopes: {
        type: "array",
        minItems: 1,
        uniqueItems: true,
        items: { type: "string", enum: API_KEY_SCOPES },
      },
      expiresAt: { type: "string", format: "date-time" },
    },
    additionalProperties: false,
  },
} as const;

// Keep the imported scope type visible in generated declarations for route consumers.
export type OwnerSecurityApiKeyScope = ApiKeyScope;
