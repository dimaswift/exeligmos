import type { FastifyInstance, FastifyReply } from "fastify";

import type { Authenticator } from "../auth/principal.js";
import type { Database } from "../db/database.js";
import {
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
      descriptionModel: { type: "string", minLength: 1, maxLength: 120 },
      descriptionPrompt: { type: "string", minLength: 1, maxLength: 4000 },
      embeddingModel: { type: "string", minLength: 1, maxLength: 120 },
      whisperModel: { type: "string", minLength: 1, maxLength: 120 },
    },
  },
} as const;
