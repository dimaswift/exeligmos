import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";

import type { Authenticator } from "../auth/principal.js";
import type { Database } from "../db/database.js";
import {
  PRIVATE_RECORD_CIPHERTEXT_BASE64_MAX_LENGTH,
  PUBLIC_RECORD_PAYLOAD_MAX_BYTES,
  RECORD_PAGE_DEFAULT_LIMIT,
  RECORD_PAGE_MAX_LIMIT,
  RESOURCE_METADATA_MAX_BYTES,
} from "../resources/limits.js";
import {
  NOOP_RESOURCE_REQUEST_LIMITER,
  type ResourceRequestLimiter,
} from "../resources/rate-limit.js";
import {
  type CreateRecordInput,
  type OwnerRecordListQuery,
  type PublicRecordListQuery,
  RECORD_PUBLIC_ID_SCHEMA_PATTERN,
  RecordService,
  type ReplaceRecordInput,
  type UpdateRecordInput,
} from "../resources/records.js";
import {
  type MutationResponse,
  PreconditionFailedProblem,
  invalidRequest,
  resourceEtag,
} from "../resources/shared.js";

export interface RecordRoutesOptions {
  readonly database: Database;
  readonly authenticator: Authenticator;
  /** Omitted by isolated route tests; buildApp injects the shared limiter. */
  readonly requestLimiter?: ResourceRequestLimiter;
}

interface RecordPath {
  readonly recordId: string;
}

interface OwnerQuerystring {
  readonly cursor?: string;
  readonly limit?: string | number;
  readonly visibility?: "public" | "private";
  readonly deviceId?: string;
  readonly tagId?: string;
  readonly occurredAfter?: string;
  readonly occurredBefore?: string;
  readonly updatedAfter?: string;
  readonly sourceProvider?: string;
  readonly sourceExternalId?: string;
}

interface PublicQuerystring {
  readonly cursor?: string;
  readonly limit?: string | number;
  readonly occurredAfter?: string;
  readonly occurredBefore?: string;
  readonly userId?: string;
  readonly tagId?: string;
}

export async function registerRecordRoutes(
  app: FastifyInstance,
  options: RecordRoutesOptions,
): Promise<void> {
  registerMergePatchParser(app);
  const service = new RecordService(options.database);
  const requestLimiter = options.requestLimiter ?? NOOP_RESOURCE_REQUEST_LIMITER;

  app.get<{ Querystring: OwnerQuerystring }>(
    "/v1/records",
    { schema: { querystring: ownerRecordQuerySchema } },
    async (request) => {
      const principal = await options.authenticator.authenticate(request, ["records:read"]);
      await requestLimiter.checkAuthenticatedRead(request, principal);
      return service.listOwner(principal, ownerQuery(request.query));
    },
  );

  app.post<{ Body: CreateRecordInput }>(
    "/v1/records",
    { schema: { headers: idempotencyHeadersSchema, body: createRecordSchema } },
    async (request, reply) => {
      const principal = await options.authenticator.authenticate(request, ["records:write"]);
      await requestLimiter.checkAuthenticatedWrite(request, principal);
      const response = await service.create(
        principal,
        request.body,
        requiredHeader(request, "idempotency-key"),
        request.id,
      );
      return sendMutation(reply, response);
    },
  );

  app.get<{ Params: RecordPath }>(
    "/v1/records/:recordId",
    { schema: { params: recordPathSchema } },
    async (request, reply) => {
      const principal = await options.authenticator.authenticate(request, ["records:read"]);
      await requestLimiter.checkAuthenticatedRead(request, principal);
      const resource = await service.getOwner(principal.userId, request.params.recordId);
      return reply
        .header("etag", resourceEtag("record", resource.id, resource.revision))
        .send(resource);
    },
  );

  app.put<{ Params: RecordPath; Body: ReplaceRecordInput }>(
    "/v1/records/:recordId",
    {
      schema: {
        params: recordPathSchema,
        headers: conditionalMutationHeadersSchema,
        body: createRecordSchema,
      },
    },
    async (request, reply) =>
      withPreconditionHeader(reply, async () => {
        const principal = await options.authenticator.authenticate(request, ["records:write"]);
        await requestLimiter.checkAuthenticatedWrite(request, principal);
        const response = await service.replace(
          principal,
          request.params.recordId,
          request.body,
          requiredHeader(request, "if-match"),
          requiredHeader(request, "idempotency-key"),
          request.id,
        );
        return sendMutation(reply, response);
      }),
  );

  app.patch<{ Params: RecordPath; Body: UpdateRecordInput }>(
    "/v1/records/:recordId",
    {
      schema: {
        params: recordPathSchema,
        headers: conditionalMutationHeadersSchema,
        body: updateRecordSchema,
      },
    },
    async (request, reply) =>
      withPreconditionHeader(reply, async () => {
        const principal = await options.authenticator.authenticate(request, ["records:write"]);
        await requestLimiter.checkAuthenticatedWrite(request, principal);
        const response = await service.patch(
          principal,
          request.params.recordId,
          request.body,
          requiredHeader(request, "if-match"),
          requiredHeader(request, "idempotency-key"),
          request.id,
        );
        return sendMutation(reply, response);
      }),
  );

  app.delete<{ Params: RecordPath }>(
    "/v1/records/:recordId",
    { schema: { params: recordPathSchema, headers: conditionalMutationHeadersSchema } },
    async (request, reply) =>
      withPreconditionHeader(reply, async () => {
        const principal = await options.authenticator.authenticate(request, ["records:write"]);
        await requestLimiter.checkAuthenticatedWrite(request, principal);
        const response = await service.delete(
          principal,
          request.params.recordId,
          requiredHeader(request, "if-match"),
          requiredHeader(request, "idempotency-key"),
          request.id,
        );
        return sendMutation(reply, response);
      }),
  );

  app.get<{ Querystring: PublicQuerystring }>(
    "/v1/public/records",
    { schema: { querystring: publicRecordQuerySchema } },
    async (request, reply) => {
      await requestLimiter.checkPublicRecordRead(request);
      const page = await service.listPublic(publicQuery(request.query));
      return reply.header("cache-control", "public, max-age=30").send(page);
    },
  );

  app.get<{ Params: RecordPath }>(
    "/v1/public/records/:recordId",
    { schema: { params: recordPathSchema } },
    async (request, reply) => {
      await requestLimiter.checkPublicRecordRead(request);
      const resource = await service.getPublic(request.params.recordId);
      return reply
        .header("etag", resourceEtag("record", resource.id, resource.revision))
        .header("cache-control", "public, max-age=30")
        .send(resource);
    },
  );
}

function registerMergePatchParser(app: FastifyInstance): void {
  app.addContentTypeParser(
    "application/merge-patch+json",
    { parseAs: "string" },
    (_request, body, done) => {
      try {
        done(null, JSON.parse(String(body)) as unknown);
      } catch (error) {
        done(error as Error);
      }
    },
  );
}

function ownerQuery(query: OwnerQuerystring): OwnerRecordListQuery {
  return {
    ...(query.cursor === undefined ? {} : { cursor: query.cursor }),
    ...(query.limit === undefined ? {} : { limit: query.limit }),
    ...(query.visibility === undefined ? {} : { visibility: query.visibility }),
    ...(query.deviceId === undefined ? {} : { deviceId: query.deviceId }),
    ...(query.tagId === undefined ? {} : { tagId: query.tagId }),
    ...(query.occurredAfter === undefined ? {} : { occurredAfter: query.occurredAfter }),
    ...(query.occurredBefore === undefined ? {} : { occurredBefore: query.occurredBefore }),
    ...(query.updatedAfter === undefined ? {} : { updatedAfter: query.updatedAfter }),
    ...(query.sourceProvider === undefined ? {} : { sourceProvider: query.sourceProvider }),
    ...(query.sourceExternalId === undefined
      ? {}
      : { sourceExternalId: query.sourceExternalId }),
  };
}

function publicQuery(query: PublicQuerystring): PublicRecordListQuery {
  return {
    ...(query.cursor === undefined ? {} : { cursor: query.cursor }),
    ...(query.limit === undefined ? {} : { limit: query.limit }),
    ...(query.occurredAfter === undefined ? {} : { occurredAfter: query.occurredAfter }),
    ...(query.occurredBefore === undefined ? {} : { occurredBefore: query.occurredBefore }),
    ...(query.userId === undefined ? {} : { userId: query.userId }),
    ...(query.tagId === undefined ? {} : { tagId: query.tagId }),
  };
}

function requiredHeader(request: FastifyRequest, name: "if-match" | "idempotency-key"): string {
  const value = request.headers[name];
  if (typeof value !== "string") {
    throw invalidRequest(`The ${name} header is required.`);
  }
  return value;
}

function sendMutation<Body>(
  reply: FastifyReply,
  response: MutationResponse<Body>,
): FastifyReply {
  for (const [name, value] of Object.entries(response.headers)) {
    reply.header(name, value);
  }
  if (response.status === 204) {
    return reply.code(204).send();
  }
  return reply.code(response.status).send(response.body);
}

async function withPreconditionHeader<Result>(
  reply: FastifyReply,
  work: () => Promise<Result>,
): Promise<Result> {
  try {
    return await work();
  } catch (error) {
    if (error instanceof PreconditionFailedProblem) {
      reply.header("etag", error.currentEtag);
    }
    throw error;
  }
}

const uuid = { type: "string", format: "uuid" };
const recordId = {
  type: "string",
  minLength: 5,
  maxLength: 5,
  pattern: RECORD_PUBLIC_ID_SCHEMA_PATTERN,
};
const dateTime = { type: "string", format: "date-time" };
const jsonObject = { type: "object", additionalProperties: true };
const metadataObject = {
  ...jsonObject,
  description: `Must serialize to at most ${RESOURCE_METADATA_MAX_BYTES} UTF-8 bytes.`,
};
const payloadObject = {
  ...jsonObject,
  minProperties: 1,
  description: `Must serialize to at most ${PUBLIC_RECORD_PAYLOAD_MAX_BYTES} UTF-8 bytes.`,
};
const idArray = {
  type: "array",
  maxItems: 200,
  uniqueItems: true,
  items: uuid,
};
const referencesSchema = {
  type: "array",
  maxItems: 200,
  items: {
    type: "object",
    required: ["targetType", "targetUserId", "targetId"],
    properties: {
      relation: {
        type: "string",
        minLength: 1,
        maxLength: 64,
        pattern: "^[A-Za-z][A-Za-z0-9._:-]{0,63}$",
      },
      targetType: { type: "string", enum: ["user", "record", "event"] },
      targetUserId: uuid,
      targetId: { anyOf: [uuid, recordId] },
    },
    additionalProperties: false,
  },
};
const sourceSchema = {
  type: "object",
  required: ["kind", "provider"],
  properties: {
    kind: { type: "string", enum: ["client", "agent", "import", "server"] },
    provider: {
      type: "string",
      minLength: 1,
      maxLength: 64,
      pattern: "^[A-Za-z0-9][A-Za-z0-9._-]*$",
    },
    externalId: { type: "string", minLength: 1, maxLength: 256 },
    url: { type: "string", format: "uri", maxLength: 2048 },
    metadata: metadataObject,
  },
  additionalProperties: false,
};
const encryptionSchema = {
  type: "object",
  required: ["algorithm", "cryptoVersion", "keyVersion", "nonce", "ciphertext", "contentType"],
  properties: {
    algorithm: { const: "A256GCM" },
    cryptoVersion: { const: 1 },
    keyVersion: { const: 1 },
    nonce: {
      type: "string",
      minLength: 16,
      maxLength: 16,
      pattern: "^[A-Za-z0-9+/]{16}$",
    },
    ciphertext: {
      type: "string",
      minLength: 24,
      maxLength: PRIVATE_RECORD_CIPHERTEXT_BASE64_MAX_LENGTH,
    },
    contentType: { const: "application/vnd.exeligmos.record+json" },
  },
  additionalProperties: false,
};
const renderSchema = {
  type: "object",
  required: ["templateId", "variables"],
  properties: {
    templateId: uuid,
    version: { type: "integer", minimum: 1 },
    variables: jsonObject,
  },
  additionalProperties: false,
};
const publicInputProperties = {
  id: recordId,
  originId: uuid,
  deviceId: uuid,
  visibility: { const: "public" },
  occurredAt: dateTime,
  endedAt: dateTime,
  payload: payloadObject,
  render: renderSchema,
  tagIds: idArray,
  mediaIds: idArray,
  metadata: metadataObject,
  source: sourceSchema,
  references: referencesSchema,
};
const publicRecordInputSchema = {
  type: "object",
  required: ["deviceId", "occurredAt"],
  properties: publicInputProperties,
  allOf: [
    {
      oneOf: [
        { required: ["payload"], not: { required: ["render"] } },
        { required: ["render"], not: { required: ["payload"] } },
      ],
    },
  ],
  additionalProperties: false,
};
const privateRecordInputSchema = {
  type: "object",
  required: ["id", "originId", "deviceId", "visibility", "encryption"],
  properties: {
    id: recordId,
    originId: uuid,
    deviceId: uuid,
    visibility: { const: "private" },
    encryption: encryptionSchema,
    mediaIds: idArray,
    references: referencesSchema,
  },
  additionalProperties: false,
};
export const createRecordSchema = {
  oneOf: [publicRecordInputSchema, privateRecordInputSchema],
};
const publicPatchSchema = {
  type: "object",
  required: ["visibility"],
  minProperties: 2,
  properties: {
    visibility: { const: "public" },
    deviceId: uuid,
    occurredAt: dateTime,
    endedAt: { anyOf: [dateTime, { type: "null" }] },
    payload: payloadObject,
    tagIds: idArray,
    mediaIds: idArray,
    metadata: metadataObject,
    source: { anyOf: [sourceSchema, { type: "null" }] },
    references: referencesSchema,
  },
  additionalProperties: false,
};
const privatePatchSchema = {
  type: "object",
  required: ["visibility", "encryption"],
  minProperties: 2,
  properties: {
    visibility: { const: "private" },
    deviceId: uuid,
    encryption: encryptionSchema,
    mediaIds: idArray,
    references: referencesSchema,
  },
  additionalProperties: false,
};
const updateRecordSchema = { oneOf: [publicPatchSchema, privatePatchSchema] };
const recordPathSchema = {
  type: "object",
  required: ["recordId"],
  properties: { recordId },
  additionalProperties: false,
};
const idempotencyHeaderProperty = {
  type: "string",
  minLength: 8,
  maxLength: 255,
  pattern: "^[\\x21-\\x7E]+$",
};
const idempotencyHeadersSchema = {
  type: "object",
  required: ["idempotency-key"],
  properties: { "idempotency-key": idempotencyHeaderProperty },
};
const conditionalMutationHeadersSchema = {
  type: "object",
  required: ["idempotency-key", "if-match"],
  properties: {
    "idempotency-key": idempotencyHeaderProperty,
    "if-match": { type: "string", minLength: 3, maxLength: 200 },
  },
};
const ownerRecordQuerySchema = {
  type: "object",
  properties: {
    cursor: { type: "string", minLength: 1, maxLength: 2048 },
    limit: {
      type: "integer",
      minimum: 1,
      maximum: RECORD_PAGE_MAX_LIMIT,
      default: RECORD_PAGE_DEFAULT_LIMIT,
    },
    visibility: { type: "string", enum: ["public", "private"] },
    deviceId: uuid,
    tagId: uuid,
    occurredAfter: dateTime,
    occurredBefore: dateTime,
    updatedAfter: dateTime,
    sourceProvider: { type: "string", minLength: 1, maxLength: 64 },
    sourceExternalId: { type: "string", minLength: 1, maxLength: 256 },
  },
  additionalProperties: false,
};
const publicRecordQuerySchema = {
  type: "object",
  properties: {
    cursor: { type: "string", minLength: 1, maxLength: 2048 },
    limit: {
      type: "integer",
      minimum: 1,
      maximum: RECORD_PAGE_MAX_LIMIT,
      default: RECORD_PAGE_DEFAULT_LIMIT,
    },
    occurredAfter: dateTime,
    occurredBefore: dateTime,
    userId: uuid,
    tagId: uuid,
  },
  additionalProperties: false,
};
