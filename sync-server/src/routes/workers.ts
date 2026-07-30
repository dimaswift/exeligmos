import type { FastifyInstance, FastifyReply } from "fastify";

import type { Authenticator } from "../auth/principal.js";
import type { Database } from "../db/database.js";
import {
  type DreamerRuntime,
  type WorkerConfigPatch,
  WorkerService,
} from "../resources/workers.js";
import {
  NOOP_RESOURCE_REQUEST_LIMITER,
  type ResourceRequestLimiter,
} from "../resources/rate-limit.js";
import {
  PreconditionFailedProblem,
  resourceEtag,
} from "../resources/shared.js";

export interface WorkerRoutesOptions {
  readonly database: Database;
  readonly authenticator: Authenticator;
  readonly requestLimiter?: ResourceRequestLimiter;
}

export async function registerWorkerRoutes(
  app: FastifyInstance,
  options: WorkerRoutesOptions,
): Promise<void> {
  const service = new WorkerService(options.database);
  const limiter = options.requestLimiter ?? NOOP_RESOURCE_REQUEST_LIMITER;

  app.get("/workers", async (request) => {
    const principal = await options.authenticator.authenticate(request);
    await limiter.checkAuthenticatedRead(request, principal);
    return service.list(principal.userId);
  });

  app.get("/workers/current", async (request, reply) => {
    const principal = await options.authenticator.authenticate(request, ["jobs:read"]);
    await limiter.checkAuthenticatedRead(request, principal);
    const worker = await service.current(principal);
    return reply
      .header("etag", resourceEtag("worker", worker.deviceId, worker.revision))
      .send(worker);
  });

  app.post<{ Params: { recordId: string } }>(
    "/workers/current/dreamed/:recordId",
    {
      schema: {
        params: {
          type: "object",
          required: ["recordId"],
          properties: {
            recordId: {
              type: "string",
              minLength: 5,
              maxLength: 5,
              pattern: "^[A-Za-z0-9_-]{5}$",
            },
          },
          additionalProperties: false,
        },
      },
    },
    async (request, reply) => {
      const principal = await options.authenticator.authenticate(request, [
        "records:write",
      ]);
      await limiter.checkAuthenticatedWrite(request, principal);
      await service.markDreamed(principal, request.params.recordId);
      return reply.code(204).send();
    },
  );

  app.put<{ Body: DreamerRuntime }>(
    "/workers/current/dreamer-runtime",
    { schema: dreamerRuntimeSchema },
    async (request, reply) => {
      const principal = await options.authenticator.authenticate(request, [
        "records:write",
      ]);
      await limiter.checkAuthenticatedWrite(request, principal);
      await service.updateDreamerRuntime(principal, request.body);
      return reply.code(204).send();
    },
  );

  app.get<{ Params: { recordId: string } }>(
    "/records/:recordId/dream",
    { schema: { params: recordDreamPathSchema } },
    async (request) => {
      const principal = await options.authenticator.authenticate(request);
      await limiter.checkAuthenticatedRead(request, principal);
      return {
        request: await service.readDreamRequest(
          principal,
          request.params.recordId,
        ),
      };
    },
  );

  app.post<{ Params: { recordId: string } }>(
    "/records/:recordId/dream",
    { schema: { params: recordDreamPathSchema } },
    async (request, reply) => {
      const principal = await options.authenticator.authenticate(request);
      await limiter.checkAuthenticatedWrite(request, principal);
      const dream = await service.scheduleDreamRequest(
        principal,
        request.params.recordId,
      );
      return reply.code(dream.status === "queued" ? 202 : 200).send(dream);
    },
  );

  app.post(
    "/workers/current/dream-requests/claim",
    async (request) => {
      const principal = await options.authenticator.authenticate(request, [
        "records:write",
      ]);
      await limiter.checkAuthenticatedWrite(request, principal);
      return { request: await service.claimDreamRequest(principal) };
    },
  );

  app.post<{
    Params: { jobId: string };
    Body: { dreamRecordId: string };
  }>(
    "/workers/current/dream-requests/:jobId/complete",
    { schema: dreamRequestCompleteSchema },
    async (request, reply) => {
      const principal = await options.authenticator.authenticate(request, [
        "records:write",
      ]);
      await limiter.checkAuthenticatedWrite(request, principal);
      await service.completeDreamRequest(
        principal,
        request.params.jobId,
        request.body.dreamRecordId,
      );
      return reply.code(204).send();
    },
  );

  app.post<{ Params: { jobId: string }; Body: { error: string } }>(
    "/workers/current/dream-requests/:jobId/fail",
    { schema: dreamRequestFailSchema },
    async (request, reply) => {
      const principal = await options.authenticator.authenticate(request, [
        "records:write",
      ]);
      await limiter.checkAuthenticatedWrite(request, principal);
      await service.failDreamRequest(
        principal,
        request.params.jobId,
        request.body.error,
      );
      return reply.code(204).send();
    },
  );

  app.patch<{
    Params: { deviceId: string };
    Headers: { "if-match"?: string };
    Body: WorkerConfigPatch;
  }>(
    "/workers/:deviceId",
    { schema: workerPatchSchema },
    async (request, reply) =>
      withEtag(reply, async () => {
        const principal = await options.authenticator.authenticate(request);
        await limiter.checkAuthenticatedWrite(request, principal);
        const ifMatch = request.headers["if-match"];
        if (ifMatch === undefined) {
          throw new Error("if-match is required by route validation");
        }
        const worker = await service.update(
          principal,
          request.params.deviceId,
          ifMatch,
          request.body,
        );
        return reply
          .header("etag", resourceEtag("worker", worker.deviceId, worker.revision))
          .send(worker);
      }),
  );
}

async function withEtag<Result>(
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

const workerPatchSchema = {
  params: {
    type: "object",
    required: ["deviceId"],
    properties: { deviceId: { type: "string", format: "uuid" } },
    additionalProperties: false,
  },
  headers: {
    type: "object",
    required: ["if-match"],
    properties: { "if-match": { type: "string", minLength: 3, maxLength: 200 } },
  },
  body: {
    type: "object",
    minProperties: 1,
    additionalProperties: false,
    properties: {
      enabled: { type: "boolean" },
      mountName: { type: "string", minLength: 1, maxLength: 80, pattern: "^[^/\\\\]+$" },
      pollIntervalMs: { type: "integer", minimum: 100, maximum: 86400000 },
      descriptionProvider: { type: "string", enum: ["ollama", "speshu"] },
      descriptionBaseUrl: { type: "string", format: "uri", maxLength: 2048 },
      descriptionModel: { type: "string", minLength: 1, maxLength: 120 },
      descriptionPrompt: { type: "string", minLength: 1, maxLength: 4000 },
      embeddingProvider: { type: "string", enum: ["ollama", "speshu"] },
      embeddingBaseUrl: { type: "string", format: "uri", maxLength: 2048 },
      embeddingModel: { type: "string", minLength: 1, maxLength: 120 },
      whisperModel: { type: "string", minLength: 1, maxLength: 120 },
      imageGenerationEnabled: { type: "boolean" },
      imageProvider: { type: "string", enum: ["mlx-studio"] },
      imageBaseUrl: { type: "string", format: "uri", maxLength: 2048 },
      imageModel: { type: "string", minLength: 1, maxLength: 120 },
      imagePromptReference: { type: "string", minLength: 1, maxLength: 4000 },
      imageSize: { type: "string", pattern: "^[1-9][0-9]{1,4}x[1-9][0-9]{1,4}$" },
      imageSteps: { type: "integer", minimum: 1, maximum: 200 },
      imageGuidance: { type: "number", minimum: 0, maximum: 100 },
      imageTimeoutMs: { type: "integer", minimum: 1, maximum: 600000 },
    },
  },
} as const;

const dreamerRuntimeSchema = {
  body: {
    type: "object",
    required: [
      "state",
      "nextRolloverAt",
      "saros",
      "scheduleId",
      "startedAt",
      "sourceRecordId",
      "message",
    ],
    additionalProperties: false,
    properties: {
      state: {
        type: "string",
        enum: ["disabled", "waiting", "creating", "error"],
      },
      nextRolloverAt: {
        anyOf: [{ type: "string", format: "date-time" }, { type: "null" }],
      },
      saros: {
        anyOf: [
          { type: "integer", minimum: 1, maximum: 999 },
          { type: "null" },
        ],
      },
      scheduleId: {
        anyOf: [
          { type: "string", minLength: 1, maxLength: 120 },
          { type: "null" },
        ],
      },
      startedAt: {
        anyOf: [{ type: "string", format: "date-time" }, { type: "null" }],
      },
      sourceRecordId: {
        anyOf: [
          {
            type: "string",
            minLength: 5,
            maxLength: 5,
            pattern: "^[A-Za-z0-9_-]{5}$",
          },
          { type: "null" },
        ],
      },
      message: {
        anyOf: [
          { type: "string", minLength: 1, maxLength: 2000 },
          { type: "null" },
        ],
      },
    },
  },
} as const;

const recordDreamPathSchema = {
  type: "object",
  required: ["recordId"],
  additionalProperties: false,
  properties: {
    recordId: {
      type: "string",
      minLength: 5,
      maxLength: 5,
      pattern: "^[A-Za-z0-9_-]{5}$",
    },
  },
} as const;

const dreamRequestJobPathSchema = {
  type: "object",
  required: ["jobId"],
  additionalProperties: false,
  properties: { jobId: { type: "string", format: "uuid" } },
} as const;

const dreamRequestCompleteSchema = {
  params: dreamRequestJobPathSchema,
  body: {
    type: "object",
    required: ["dreamRecordId"],
    additionalProperties: false,
    properties: {
      dreamRecordId: {
        type: "string",
        minLength: 5,
        maxLength: 5,
        pattern: "^[A-Za-z0-9_-]{5}$",
      },
    },
  },
} as const;

const dreamRequestFailSchema = {
  params: dreamRequestJobPathSchema,
  body: {
    type: "object",
    required: ["error"],
    additionalProperties: false,
    properties: {
      error: { type: "string", minLength: 1, maxLength: 4000 },
    },
  },
} as const;
