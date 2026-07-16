import type {
  FastifyError,
  FastifyInstance,
  FastifyReply,
  FastifyRequest,
} from "fastify";

import type { Authenticator } from "../auth/principal.js";
import type { Database } from "../db/database.js";
import {
  NOOP_RESOURCE_REQUEST_LIMITER,
  type ResourceRequestLimiter,
} from "../resources/rate-limit.js";
import { RECORD_PUBLIC_ID_SCHEMA_PATTERN } from "../resources/records.js";
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

  app.get(
    "/v1/sync/stats",
    async (request) => {
      const principal = await options.authenticator.authenticate(request, ["sync:read"]);
      await requestLimiter.checkAuthenticatedRead(request, principal);
      return service.stats(principal);
    },
  );

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
      onError: async (request, _reply, error) => {
        logRejectedSyncBatch(request, error);
      },
      schema: {
        headers: idempotencyHeadersSchema,
        body: syncBatchSchema,
      },
    },
    async (request, reply) => {
      const principal = await options.authenticator.authenticate(request, ["sync:write"]);
      await requestLimiter.checkAuthenticatedWrite(request, principal);
      const batch = syncBatchLogSummary(request.body);
      request.log.info(
        {
          event: "sync_batch_received",
          userId: principal.userId,
          actorKind: principal.kind,
          userAgent: boundedLogString(request.headers["user-agent"]),
          clientVersion: clientVersionHeaders(request),
          ...batch,
        },
        "sync batch received",
      );
      const response = await service.applyBatch(
        principal,
        request.body,
        requiredIdempotencyKey(request),
        request.id,
      );
      const failed = response.body.results.filter((result) => result.status === "failed");
      const log = failed.length === 0 ? request.log.info.bind(request.log) : request.log.warn.bind(request.log);
      log(
        {
          event: "sync_batch_completed",
          userId: principal.userId,
          deviceId: request.body.deviceId,
          mutationCount: request.body.mutations.length,
          replayed: response.replayed ?? false,
          results: response.body.results.map((result) => ({
            clientMutationId: result.clientMutationId,
            status: result.status,
            resourceType: result.resourceType,
            resourceId: result.resourceId,
            revision: result.revision,
            problemStatus: result.problem?.status,
            problemCode: result.problem?.code,
            problemDetail: boundedLogString(result.problem?.detail),
          })),
        },
        failed.length === 0 ? "sync batch completed" : "sync batch completed with rejected mutations",
      );
      return sendMutation(reply, response);
    },
  );
}

function logRejectedSyncBatch(request: FastifyRequest, error: FastifyError): void {
  request.log.warn(
    {
      event: "sync_batch_rejected",
      errorCode: error.code,
      statusCode: error.statusCode,
      userAgent: boundedLogString(request.headers["user-agent"]),
      clientVersion: clientVersionHeaders(request),
      ...syncBatchLogSummary(request.body),
      validation: error.validation?.map((issue) => ({
        instancePath: issue.instancePath,
        schemaPath: issue.schemaPath,
        keyword: issue.keyword,
        message: issue.message,
      })),
    },
    "sync batch rejected before processing",
  );
}

function clientVersionHeaders(request: FastifyRequest): Record<string, string> | undefined {
  const entries = ["x-client-version", "x-app-version", "x-ios-version"].flatMap((name) => {
    const value = request.headers[name];
    return typeof value === "string" ? [[name, boundedLogString(value) ?? ""] as const] : [];
  });
  return entries.length === 0 ? undefined : Object.fromEntries(entries);
}

function syncBatchLogSummary(value: unknown): Record<string, unknown> {
  if (!isObject(value)) return { bodyShape: typeof value };
  const mutations = Array.isArray(value.mutations) ? value.mutations : [];
  return {
    deviceId: stringValue(value.deviceId),
    atomic: value.atomic === true,
    mutationCount: mutations.length,
    mutations: mutations.slice(0, 20).map((mutation) => mutationLogSummary(mutation)),
  };
}

function mutationLogSummary(value: unknown): Record<string, unknown> {
  if (!isObject(value)) return { shape: typeof value };
  const kind = stringValue(value.kind);
  const summary: Record<string, unknown> = {
    kind,
    clientMutationId: stringValue(value.clientMutationId),
  };
  if (kind === "upsertRecord" && isObject(value.record)) {
    const rawId = rawStringValue(value.record.id);
    summary.record = {
      id: boundedLogString(rawId),
      idLength: rawId?.length,
      originId: stringValue(value.record.originId),
      visibility: stringValue(value.record.visibility) ?? "public",
      tagCount: arrayLength(value.record.tagIds),
      mediaCount: arrayLength(value.record.mediaIds),
      hasPayload: isObject(value.record.payload),
      hasEncryption: isObject(value.record.encryption),
    };
  } else if (kind === "upsertEvent" && isObject(value.event)) {
    summary.event = { id: stringValue(value.event.id), type: value.event.type };
  } else if (kind === "upsertTag" && isObject(value.tag)) {
    summary.tag = { id: stringValue(value.tag.id) };
  } else if (kind === "delete") {
    summary.delete = {
      resourceType: stringValue(value.resourceType),
      resourceId: stringValue(value.resourceId),
    };
  }
  return summary;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function stringValue(value: unknown): string | undefined {
  return boundedLogString(rawStringValue(value));
}

function rawStringValue(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function boundedLogString(value: string | undefined): string | undefined {
  if (value === undefined || value.length <= 160) return value;
  return `${value.slice(0, 160)}…(${value.length} chars)`;
}

function arrayLength(value: unknown): number {
  return Array.isArray(value) ? value.length : 0;
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
const recordId = {
  type: "string",
  minLength: 5,
  maxLength: 5,
  pattern: RECORD_PUBLIC_ID_SCHEMA_PATTERN,
};
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
    resourceId: { anyOf: [uuid, recordId] },
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
