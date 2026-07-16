import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";

import type { Authenticator } from "../auth/principal.js";
import type { Database } from "../db/database.js";
import { RESOURCE_METADATA_MAX_BYTES } from "../resources/limits.js";
import {
  NOOP_RESOURCE_REQUEST_LIMITER,
  type ResourceRequestLimiter,
} from "../resources/rate-limit.js";
import {
  type CreateTagInput,
  type TagListQuery,
  TagService,
  type UpdateTagInput,
  tagEtag,
} from "../resources/tags.js";
import {
  type MutationResponse,
  PreconditionFailedProblem,
  invalidRequest,
} from "../resources/shared.js";

export interface TagRoutesOptions {
  readonly database: Database;
  readonly authenticator: Authenticator;
  /** Omitted by isolated route tests; buildApp injects the shared limiter. */
  readonly requestLimiter?: ResourceRequestLimiter;
}

interface TagPath {
  readonly tagId: string;
}

interface TagQuerystring {
  readonly cursor?: string;
  readonly limit?: string | number;
  readonly updatedAfter?: string;
}

export async function registerTagRoutes(
  app: FastifyInstance,
  options: TagRoutesOptions,
): Promise<void> {
  registerMergePatchParser(app);
  const service = new TagService(options.database);
  const requestLimiter = options.requestLimiter ?? NOOP_RESOURCE_REQUEST_LIMITER;

  app.get<{ Querystring: TagQuerystring }>(
    "/v1/tags",
    { schema: { querystring: tagQuerySchema } },
    async (request) => {
      const principal = await options.authenticator.authenticate(request, ["tags:read"]);
      await requestLimiter.checkAuthenticatedRead(request, principal);
      return service.list(principal, tagQuery(request.query));
    },
  );

  app.post<{ Body: CreateTagInput }>(
    "/v1/tags",
    { schema: { headers: idempotencyHeadersSchema, body: createTagSchema } },
    async (request, reply) => {
      const principal = await options.authenticator.authenticate(request, ["tags:write"]);
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

  app.get<{ Params: TagPath }>(
    "/v1/tags/:tagId",
    { schema: { params: tagPathSchema } },
    async (request, reply) => {
      const principal = await options.authenticator.authenticate(request, ["tags:read"]);
      await requestLimiter.checkAuthenticatedRead(request, principal);
      const resource = await service.get(principal.userId, request.params.tagId);
      return reply.header("etag", tagEtag(resource.id, resource.revision)).send(resource);
    },
  );

  app.patch<{ Params: TagPath; Body: UpdateTagInput }>(
    "/v1/tags/:tagId",
    {
      schema: {
        params: tagPathSchema,
        headers: conditionalMutationHeadersSchema,
        body: updateTagSchema,
      },
    },
    async (request, reply) =>
      withPreconditionHeader(reply, async () => {
        const principal = await options.authenticator.authenticate(request, ["tags:write"]);
        await requestLimiter.checkAuthenticatedWrite(request, principal);
        const response = await service.patch(
          principal,
          request.params.tagId,
          request.body,
          requiredHeader(request, "if-match"),
          requiredHeader(request, "idempotency-key"),
          request.id,
        );
        return sendMutation(reply, response);
      }),
  );

  app.delete<{ Params: TagPath }>(
    "/v1/tags/:tagId",
    { schema: { params: tagPathSchema, headers: conditionalMutationHeadersSchema } },
    async (request, reply) =>
      withPreconditionHeader(reply, async () => {
        const principal = await options.authenticator.authenticate(request, ["tags:write"]);
        await requestLimiter.checkAuthenticatedWrite(request, principal);
        const response = await service.delete(
          principal,
          request.params.tagId,
          requiredHeader(request, "if-match"),
          requiredHeader(request, "idempotency-key"),
          request.id,
        );
        return sendMutation(reply, response);
      }),
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

function tagQuery(query: TagQuerystring): TagListQuery {
  return {
    ...(query.cursor === undefined ? {} : { cursor: query.cursor }),
    ...(query.limit === undefined ? {} : { limit: query.limit }),
    ...(query.updatedAfter === undefined ? {} : { updatedAfter: query.updatedAfter }),
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
const dateTime = { type: "string", format: "date-time" };
const metadataObject = {
  type: "object",
  additionalProperties: true,
  description: `Must serialize to at most ${RESOURCE_METADATA_MAX_BYTES} UTF-8 bytes.`,
};
const tagProperties = {
  id: uuid,
  name: { type: "string", minLength: 1, maxLength: 120 },
  color: { type: "string", pattern: "^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$" },
  emoji: { type: "string", maxLength: 32 },
  sortOrder: {
    type: "integer",
    minimum: -2_147_483_648,
    maximum: 2_147_483_647,
  },
  metadata: metadataObject,
};

/** Reused verbatim by the synchronization batch route. */
export const createTagSchema = {
  type: "object",
  required: ["name"],
  properties: tagProperties,
  additionalProperties: false,
};

export const updateTagSchema = {
  type: "object",
  minProperties: 1,
  properties: {
    name: tagProperties.name,
    color: { anyOf: [tagProperties.color, { type: "null" }] },
    emoji: { anyOf: [tagProperties.emoji, { type: "null" }] },
    sortOrder: tagProperties.sortOrder,
    metadata: metadataObject,
  },
  additionalProperties: false,
};

const tagPathSchema = {
  type: "object",
  required: ["tagId"],
  properties: { tagId: uuid },
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
const tagQuerySchema = {
  type: "object",
  properties: {
    cursor: { type: "string", minLength: 1, maxLength: 2048 },
    limit: { type: "integer", minimum: 1, maximum: 200, default: 50 },
    updatedAfter: dateTime,
  },
  additionalProperties: false,
};
