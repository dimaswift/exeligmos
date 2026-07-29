import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";

import type { Authenticator } from "../auth/principal.js";
import type { Database } from "../db/database.js";
import {
  type CreateIngestionJobInput,
  type IngestionJobListQuery,
  IngestionJobService,
  type IngestionJobStatus,
  type UpdateIngestionItemInput,
} from "../resources/jobs.js";
import {
  NOOP_RESOURCE_REQUEST_LIMITER,
  type ResourceRequestLimiter,
} from "../resources/rate-limit.js";
import {
  invalidRequest,
  type MutationResponse,
  PreconditionFailedProblem,
  resourceEtag,
} from "../resources/shared.js";

export interface IngestionJobRoutesOptions {
  readonly database: Database;
  readonly authenticator: Authenticator;
  readonly requestLimiter?: ResourceRequestLimiter;
}

interface JobPath {
  readonly jobId: string;
}

interface JobItemPath extends JobPath {
  readonly itemId: string;
}

interface JobQuerystring {
  readonly cursor?: string;
  readonly limit?: string | number;
  readonly status?: IngestionJobStatus;
  readonly activity?: "active";
  readonly deviceId?: string;
}

export async function registerIngestionJobRoutes(
  app: FastifyInstance,
  options: IngestionJobRoutesOptions,
): Promise<void> {
  const service = new IngestionJobService(options.database);
  const requestLimiter =
    options.requestLimiter ?? NOOP_RESOURCE_REQUEST_LIMITER;

  app.get<{ Querystring: JobQuerystring }>(
    "/jobs",
    { schema: { querystring: jobQuerySchema } },
    async (request) => {
      const principal = await options.authenticator.authenticate(request, [
        "jobs:read",
      ]);
      await requestLimiter.checkAuthenticatedRead(request, principal);
      return service.list(principal, jobQuery(request.query));
    },
  );

  app.post<{ Body: CreateIngestionJobInput }>(
    "/jobs",
    {
      bodyLimit: 2_097_152,
      schema: {
        headers: idempotencyHeadersSchema,
        body: createJobSchema,
      },
    },
    async (request, reply) => {
      const principal = await options.authenticator.authenticate(request, [
        "jobs:write",
      ]);
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

  app.get<{ Params: JobPath }>(
    "/jobs/:jobId",
    { schema: { params: jobPathSchema } },
    async (request, reply) => {
      const principal = await options.authenticator.authenticate(request, [
        "jobs:read",
      ]);
      await requestLimiter.checkAuthenticatedRead(request, principal);
      const resource = await service.get(principal, request.params.jobId);
      return reply
        .header("etag", resourceEtag("job", resource.id, resource.revision))
        .send(resource);
    },
  );

  app.patch<{
    Params: JobItemPath;
    Body: UpdateIngestionItemInput;
  }>(
    "/jobs/:jobId/items/:itemId",
    {
      schema: {
        params: jobItemPathSchema,
        headers: conditionalMutationHeadersSchema,
        body: updateJobItemSchema,
      },
    },
    async (request, reply) =>
      withPreconditionHeader(reply, async () => {
        const principal = await options.authenticator.authenticate(request, [
          "jobs:write",
        ]);
        await requestLimiter.checkAuthenticatedWrite(request, principal);
        const response = await service.updateItem(
          principal,
          request.params.jobId,
          request.params.itemId,
          request.body,
          requiredHeader(request, "if-match"),
          requiredHeader(request, "idempotency-key"),
          request.id,
        );
        return sendMutation(reply, response);
      }),
  );
}

function jobQuery(query: JobQuerystring): IngestionJobListQuery {
  return {
    ...(query.cursor === undefined ? {} : { cursor: query.cursor }),
    ...(query.limit === undefined ? {} : { limit: query.limit }),
    ...(query.status === undefined ? {} : { status: query.status }),
    ...(query.activity === undefined ? {} : { activity: query.activity }),
    ...(query.deviceId === undefined ? {} : { deviceId: query.deviceId }),
  };
}

function requiredHeader(
  request: FastifyRequest,
  name: "if-match" | "idempotency-key",
): string {
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
const sha256 = { type: "string", pattern: "^[a-f0-9]{64}$" };
const lifecycleToken = {
  type: "string",
  minLength: 1,
  maxLength: 64,
  pattern: "^[a-z][a-z0-9_-]*$",
};
const idempotencyHeadersSchema = {
  type: "object",
  required: ["idempotency-key"],
  properties: {
    "idempotency-key": {
      type: "string",
      minLength: 8,
      maxLength: 255,
      pattern: "^[\\x21-\\x7e]+$",
    },
  },
};
const conditionalMutationHeadersSchema = {
  type: "object",
  required: ["if-match", "idempotency-key"],
  properties: {
    "if-match": { type: "string", minLength: 3, maxLength: 200 },
    "idempotency-key": idempotencyHeadersSchema.properties["idempotency-key"],
  },
};
const jobPathSchema = {
  type: "object",
  required: ["jobId"],
  properties: { jobId: uuid },
  additionalProperties: false,
};
const jobItemPathSchema = {
  type: "object",
  required: ["jobId", "itemId"],
  properties: { jobId: uuid, itemId: uuid },
  additionalProperties: false,
};
const jobQuerySchema = {
  type: "object",
  properties: {
    cursor: { type: "string", minLength: 1, maxLength: 2048 },
    limit: { type: "integer", minimum: 1, maximum: 200 },
    status: {
      type: "string",
      enum: ["queued", "processing", "completed", "failed"],
    },
    activity: {
      type: "string",
      enum: ["active"],
    },
    deviceId: uuid,
  },
  additionalProperties: false,
};
const itemDeclarationSchema = {
  type: "object",
  required: [
    "sourceKey",
    "groupKey",
    "relativePath",
    "kind",
    "capturedAt",
    "byteLength",
    "contentSha256",
  ],
  properties: {
    sourceKey: sha256,
    groupKey: sha256,
    relativePath: {
      type: "string",
      minLength: 1,
      maxLength: 1024,
    },
    kind: { type: "string", enum: ["photo", "video", "audio"] },
    capturedAt: { type: "string", format: "date-time" },
    byteLength: {
      type: "integer",
      minimum: 1,
      maximum: 5_368_709_120,
    },
    contentSha256: sha256,
  },
  additionalProperties: false,
};
const createJobSchema = {
  type: "object",
  required: ["deviceId", "source", "config", "items"],
  properties: {
    deviceId: uuid,
    source: { type: "object", additionalProperties: true },
    config: { type: "object", additionalProperties: true },
    items: {
      type: "array",
      minItems: 1,
      maxItems: 1000,
      items: itemDeclarationSchema,
    },
  },
  additionalProperties: false,
};
const updateJobItemSchema = {
  type: "object",
  required: ["status"],
  minProperties: 1,
  properties: {
    status: {
      type: "string",
      enum: ["processing", "completed", "failed"],
    },
    stage: lifecycleToken,
    outputMode: lifecycleToken,
    uploadId: uuid,
    mediaId: uuid,
    recordId: {
      type: "string",
      minLength: 5,
      maxLength: 5,
      pattern: "^[A-Za-z0-9_-]{5}$",
    },
    error: { type: "string", minLength: 1, maxLength: 4000 },
  },
  allOf: [
    {
      if: { properties: { status: { const: "failed" } } },
      then: { required: ["error"] },
      else: { not: { required: ["error"] } },
    },
  ],
  additionalProperties: false,
};
