import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";

import type { Authenticator } from "../auth/principal.js";
import type { Database } from "../db/database.js";
import { RESOURCE_METADATA_MAX_BYTES } from "../resources/limits.js";
import {
  NOOP_RESOURCE_REQUEST_LIMITER,
  type ResourceRequestLimiter,
} from "../resources/rate-limit.js";
import {
  type CreateEventInput,
  type EventListQuery,
  EventService,
  type PublicEventListQuery,
  type UpdateEventInput,
} from "../resources/events.js";
import {
  type MutationResponse,
  PreconditionFailedProblem,
  invalidRequest,
  resourceEtag,
} from "../resources/shared.js";

export interface EventRoutesOptions {
  readonly database: Database;
  readonly authenticator: Authenticator;
  /** Omitted by isolated route tests; buildApp injects the shared limiter. */
  readonly requestLimiter?: ResourceRequestLimiter;
}

interface EventPath {
  readonly eventId: string;
}

interface EventQuerystring {
  readonly cursor?: string;
  readonly limit?: string | number;
  readonly deviceId?: string;
  readonly type?: string | number | readonly (string | number)[];
  readonly from?: string;
  readonly to?: string;
  readonly updatedAfter?: string;
  readonly visibility?: "public" | "private";
}

interface PublicEventQuerystring {
  readonly cursor?: string;
  readonly limit?: string | number;
  readonly userId?: string;
  readonly type?: string | number | readonly (string | number)[];
  readonly from?: string;
  readonly to?: string;
}

export async function registerEventRoutes(
  app: FastifyInstance,
  options: EventRoutesOptions,
): Promise<void> {
  registerMergePatchParser(app);
  const service = new EventService(options.database);
  const requestLimiter = options.requestLimiter ?? NOOP_RESOURCE_REQUEST_LIMITER;

  app.get<{ Querystring: EventQuerystring }>(
    "/v1/events",
    { schema: { querystring: eventQuerySchema } },
    async (request) => {
      const principal = await options.authenticator.authenticate(request, ["events:read"]);
      await requestLimiter.checkAuthenticatedRead(request, principal);
      return service.list(principal, eventQuery(request.query));
    },
  );

  app.post<{ Body: CreateEventInput }>(
    "/v1/events",
    { schema: { headers: idempotencyHeadersSchema, body: createEventSchema } },
    async (request, reply) => {
      const principal = await options.authenticator.authenticate(request, ["events:write"]);
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

  app.get<{ Params: EventPath }>(
    "/v1/events/:eventId",
    { schema: { params: eventPathSchema } },
    async (request, reply) => {
      const principal = await options.authenticator.authenticate(request, ["events:read"]);
      await requestLimiter.checkAuthenticatedRead(request, principal);
      const resource = await service.get(principal.userId, request.params.eventId);
      return reply
        .header("etag", resourceEtag("event", resource.id, resource.revision))
        .send(resource);
    },
  );

  app.patch<{ Params: EventPath; Body: UpdateEventInput }>(
    "/v1/events/:eventId",
    {
      schema: {
        params: eventPathSchema,
        headers: conditionalMutationHeadersSchema,
        body: updateEventSchema,
      },
    },
    async (request, reply) =>
      withPreconditionHeader(reply, async () => {
        const principal = await options.authenticator.authenticate(request, ["events:write"]);
        await requestLimiter.checkAuthenticatedWrite(request, principal);
        const response = await service.patch(
          principal,
          request.params.eventId,
          request.body,
          requiredHeader(request, "if-match"),
          requiredHeader(request, "idempotency-key"),
          request.id,
        );
        return sendMutation(reply, response);
      }),
  );

  app.delete<{ Params: EventPath }>(
    "/v1/events/:eventId",
    { schema: { params: eventPathSchema, headers: conditionalMutationHeadersSchema } },
    async (request, reply) =>
      withPreconditionHeader(reply, async () => {
        const principal = await options.authenticator.authenticate(request, ["events:write"]);
        await requestLimiter.checkAuthenticatedWrite(request, principal);
        const response = await service.delete(
          principal,
          request.params.eventId,
          requiredHeader(request, "if-match"),
          requiredHeader(request, "idempotency-key"),
          request.id,
        );
        return sendMutation(reply, response);
      }),
  );

  app.get<{ Querystring: PublicEventQuerystring }>(
    "/v1/public/events",
    { schema: { querystring: publicEventQuerySchema } },
    async (request, reply) => {
      await requestLimiter.checkPublicRecordRead(request);
      const page = await service.listPublic(publicEventQuery(request.query));
      return reply.header("cache-control", "public, max-age=15").send(page);
    },
  );

  app.get<{ Params: EventPath }>(
    "/v1/public/events/:eventId",
    { schema: { params: eventPathSchema } },
    async (request, reply) => {
      await requestLimiter.checkPublicRecordRead(request);
      const resource = await service.getPublic(request.params.eventId);
      return reply
        .header("etag", resourceEtag("event", resource.id, resource.revision))
        .header("cache-control", "public, max-age=15")
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

function eventQuery(query: EventQuerystring): EventListQuery {
  const rawTypes = query.type;
  const types =
    rawTypes === undefined ? undefined : Array.isArray(rawTypes) ? rawTypes : [rawTypes];
  return {
    ...(query.cursor === undefined ? {} : { cursor: query.cursor }),
    ...(query.limit === undefined ? {} : { limit: query.limit }),
    ...(query.deviceId === undefined ? {} : { deviceId: query.deviceId }),
    ...(types === undefined ? {} : { types }),
    ...(query.from === undefined ? {} : { from: query.from }),
    ...(query.to === undefined ? {} : { to: query.to }),
    ...(query.updatedAfter === undefined ? {} : { updatedAfter: query.updatedAfter }),
    ...(query.visibility === undefined ? {} : { visibility: query.visibility }),
  };
}

function publicEventQuery(query: PublicEventQuerystring): PublicEventListQuery {
  const rawTypes = query.type;
  const types = rawTypes === undefined ? undefined : Array.isArray(rawTypes) ? rawTypes : [rawTypes];
  return {
    ...(query.cursor === undefined ? {} : { cursor: query.cursor }),
    ...(query.limit === undefined ? {} : { limit: query.limit }),
    ...(query.userId === undefined ? {} : { userId: query.userId }),
    ...(types === undefined ? {} : { types }),
    ...(query.from === undefined ? {} : { from: query.from }),
    ...(query.to === undefined ? {} : { to: query.to }),
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
const jsonObject = { type: "object", additionalProperties: true };
const metadataObject = {
  ...jsonObject,
  description: `Must serialize to at most ${RESOURCE_METADATA_MAX_BYTES} UTF-8 bytes.`,
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
      targetId: uuid,
    },
    additionalProperties: false,
  },
};
const eventProperties = {
  id: uuid,
  deviceId: uuid,
  startsAt: dateTime,
  endsAt: dateTime,
  label: { type: "string", minLength: 1, maxLength: 256 },
  type: { type: "integer", minimum: 0, maximum: 2_147_483_647 },
  metadata: metadataObject,
  visibility: { type: "string", enum: ["public", "private"] },
  references: referencesSchema,
};
export const createEventSchema = {
  type: "object",
  required: ["deviceId", "startsAt", "label", "type"],
  properties: eventProperties,
  additionalProperties: false,
};
const updateEventSchema = {
  type: "object",
  minProperties: 1,
  properties: {
    deviceId: uuid,
    startsAt: dateTime,
    endsAt: { anyOf: [dateTime, { type: "null" }] },
    label: { type: "string", minLength: 1, maxLength: 256 },
    type: { type: "integer", minimum: 0, maximum: 2_147_483_647 },
    metadata: metadataObject,
    visibility: { type: "string", enum: ["public", "private"] },
    references: referencesSchema,
  },
  additionalProperties: false,
};
const eventPathSchema = {
  type: "object",
  required: ["eventId"],
  properties: { eventId: uuid },
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
const eventQuerySchema = {
  type: "object",
  properties: {
    cursor: { type: "string", minLength: 1, maxLength: 2048 },
    limit: { type: "integer", minimum: 1, maximum: 200, default: 50 },
    deviceId: uuid,
    type: {
      type: "array",
      maxItems: 50,
      items: { type: "integer", minimum: 0, maximum: 2_147_483_647 },
    },
    from: dateTime,
    to: dateTime,
    updatedAfter: dateTime,
    visibility: { type: "string", enum: ["public", "private"] },
  },
  additionalProperties: false,
};
const publicEventQuerySchema = {
  type: "object",
  properties: {
    cursor: { type: "string", minLength: 1, maxLength: 2048 },
    limit: { type: "integer", minimum: 1, maximum: 200, default: 50 },
    userId: uuid,
    type: {
      type: "array",
      maxItems: 50,
      items: { type: "integer", minimum: 0, maximum: 2_147_483_647 },
    },
    from: dateTime,
    to: dateTime,
  },
  additionalProperties: false,
};
