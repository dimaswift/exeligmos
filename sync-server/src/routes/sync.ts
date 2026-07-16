import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";

import type { Authenticator } from "../auth/principal.js";
import type { Database } from "../db/database.js";
import {
  NOOP_RESOURCE_REQUEST_LIMITER,
  type ResourceRequestLimiter,
} from "../resources/rate-limit.js";
import {
  type SyncBatchInput,
  type SyncChangeQuery,
  SYNC_RESOURCE_TYPES,
  SyncService,
} from "../resources/sync.js";
import { invalidRequest, type MutationResponse } from "../resources/shared.js";
import { createEventSchema } from "./events.js";
import { createRecordSchema } from "./records.js";
import { createTagSchema } from "./tags.js";
import { createTemplateSchema } from "./templates.js";

export interface SyncRoutesOptions {
  readonly database: Database;
  readonly authenticator: Authenticator;
  /** Omitted by isolated route tests; buildApp injects the shared limiter. */
  readonly requestLimiter?: ResourceRequestLimiter;
}

interface ChangeQuerystring {
  readonly cursor?: string;
  readonly limit?: string | number;
  readonly resourceType?: string | readonly string[];
}

const SYNC_BATCH_BODY_LIMIT_BYTES = 16_777_216;

export async function registerSyncRoutes(
  app: FastifyInstance,
  options: SyncRoutesOptions,
): Promise<void> {
  const service = new SyncService(options.database);
  const requestLimiter = options.requestLimiter ?? NOOP_RESOURCE_REQUEST_LIMITER;

  app.get<{ Querystring: ChangeQuerystring }>(
    "/v1/sync/changes",
    { schema: { querystring: changeQuerySchema } },
    async (request) => {
      const principal = await options.authenticator.authenticate(request, ["sync:read"]);
      await requestLimiter.checkAuthenticatedRead(request, principal);
      return service.listChanges(principal, changeQuery(request.query));
    },
  );

  app.post<{ Body: SyncBatchInput }>(
    "/v1/sync/batches",
    {
      bodyLimit: SYNC_BATCH_BODY_LIMIT_BYTES,
      schema: {
        headers: idempotencyHeadersSchema,
        body: syncBatchSchema,
      },
    },
    async (request, reply) => {
      const principal = await options.authenticator.authenticate(request, ["sync:write"]);
      await requestLimiter.checkAuthenticatedWrite(request, principal);
      const response = await service.applyBatch(
        principal,
        request.body,
        requiredIdempotencyKey(request),
        request.id,
      );
      return sendMutation(reply, response);
    },
  );
}

function changeQuery(query: ChangeQuerystring): SyncChangeQuery {
  const rawResourceTypes = query.resourceType;
  const resourceTypes = rawResourceTypes === undefined
    ? undefined
    : Array.isArray(rawResourceTypes)
    ? rawResourceTypes
    : [rawResourceTypes];
  return {
    ...(query.cursor === undefined ? {} : { cursor: query.cursor }),
    ...(query.limit === undefined ? {} : { limit: query.limit }),
    ...(resourceTypes === undefined ? {} : { resourceTypes }),
  };
}

function requiredIdempotencyKey(request: FastifyRequest): string {
  const value = request.headers["idempotency-key"];
  if (typeof value !== "string") {
    throw invalidRequest("The idempotency-key header is required.");
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
  return reply.code(response.status).send(response.body);
}

const uuid = { type: "string", format: "uuid" };
const mutationId = {
  type: "string",
  minLength: 8,
  maxLength: 128,
  pattern: "^[A-Za-z0-9._:-]+$",
};
const ifMatch = { type: "string", minLength: 3, maxLength: 200 };
const upsertRecordMutationSchema = {
  type: "object",
  required: ["kind", "clientMutationId", "record"],
  properties: {
    kind: { const: "upsertRecord" },
    clientMutationId: mutationId,
    ifMatch,
    record: createRecordSchema,
  },
  additionalProperties: false,
};
const upsertEventMutationSchema = {
  type: "object",
  required: ["kind", "clientMutationId", "event"],
  properties: {
    kind: { const: "upsertEvent" },
    clientMutationId: mutationId,
    ifMatch,
    event: createEventSchema,
  },
  additionalProperties: false,
};
const upsertTagMutationSchema = {
  type: "object",
  required: ["kind", "clientMutationId", "tag"],
  properties: {
    kind: { const: "upsertTag" },
    clientMutationId: mutationId,
    ifMatch,
    tag: createTagSchema,
  },
  additionalProperties: false,
};
const upsertTemplateMutationSchema = {
  type: "object",
  required: ["kind", "clientMutationId", "template"],
  properties: {
    kind: { const: "upsertTemplate" },
    clientMutationId: mutationId,
    ifMatch,
    template: createTemplateSchema,
  },
  additionalProperties: false,
};
const deleteMutationSchema = {
  type: "object",
  required: ["kind", "clientMutationId", "resourceType", "resourceId", "ifMatch"],
  properties: {
    kind: { const: "delete" },
    clientMutationId: mutationId,
    resourceType: { type: "string", enum: ["record", "event", "tag", "template"] },
    resourceId: uuid,
    ifMatch,
  },
  additionalProperties: false,
};
const syncMutationSchema = {
  oneOf: [
    upsertRecordMutationSchema,
    upsertEventMutationSchema,
    upsertTagMutationSchema,
    upsertTemplateMutationSchema,
    deleteMutationSchema,
  ],
};
const syncBatchSchema = {
  type: "object",
  required: ["deviceId", "mutations"],
  properties: {
    deviceId: uuid,
    atomic: { type: "boolean", default: false },
    mutations: {
      type: "array",
      minItems: 1,
      maxItems: 20,
      items: syncMutationSchema,
    },
  },
  additionalProperties: false,
};
const idempotencyHeadersSchema = {
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
};
const changeQuerySchema = {
  type: "object",
  properties: {
    cursor: { type: "string", minLength: 1, maxLength: 2_048 },
    limit: { type: "integer", minimum: 1, maximum: 200, default: 50 },
    resourceType: {
      type: "array",
      maxItems: SYNC_RESOURCE_TYPES.length,
      uniqueItems: true,
      items: { type: "string", enum: SYNC_RESOURCE_TYPES },
    },
  },
  additionalProperties: false,
};
