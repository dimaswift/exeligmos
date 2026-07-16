import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";

import type { Authenticator } from "../auth/principal.js";
import type { Database } from "../db/database.js";
import {
  NOOP_RESOURCE_REQUEST_LIMITER,
  type ResourceRequestLimiter,
} from "../resources/rate-limit.js";
import {
  type PublicActivityQuery,
  PublicActivityService,
  PublicProfileService,
  type SubscriptionInput,
  type SubscriptionListQuery,
  SubscriptionService,
} from "../resources/social.js";
import {
  type MutationResponse,
  PreconditionFailedProblem,
  invalidRequest,
} from "../resources/shared.js";

export interface SocialRoutesOptions {
  readonly database: Database;
  readonly authenticator: Authenticator;
  readonly requestLimiter?: ResourceRequestLimiter;
}

interface LoginPath {
  readonly login: string;
}

interface TargetUserPath {
  readonly targetUserId: string;
}

interface SubscriptionQuerystring {
  readonly cursor?: string;
  readonly limit?: number | string;
}

interface ActivityQuerystring {
  readonly cursor?: string;
  readonly limit?: number | string;
  readonly userId?: string;
  readonly resourceType?: string | readonly string[];
  readonly snapshot?: "latest";
}

export async function registerSocialRoutes(
  app: FastifyInstance,
  options: SocialRoutesOptions,
): Promise<void> {
  const profiles = new PublicProfileService(options.database);
  const subscriptions = new SubscriptionService(options.database);
  const activity = new PublicActivityService(options.database);
  const requestLimiter = options.requestLimiter ?? NOOP_RESOURCE_REQUEST_LIMITER;

  app.get<{ Params: LoginPath }>(
    "/v1/public/users/:login",
    { schema: { params: loginPathSchema } },
    async (request, reply) => {
      await requestLimiter.checkPublicRecordRead(request);
      const profile = await profiles.getByLogin(request.params.login);
      return reply.header("cache-control", "public, max-age=30").send(profile);
    },
  );

  app.get<{ Querystring: SubscriptionQuerystring }>(
    "/v1/subscriptions",
    { schema: { querystring: subscriptionQuerySchema } },
    async (request) => {
      const principal = await options.authenticator.authenticate(request, ["subscriptions:read"]);
      await requestLimiter.checkAuthenticatedRead(request, principal);
      return subscriptions.list(principal, subscriptionQuery(request.query));
    },
  );

  app.put<{ Params: TargetUserPath; Body: SubscriptionInput }>(
    "/v1/subscriptions/:targetUserId",
    {
      schema: {
        params: targetUserPathSchema,
        headers: idempotencyHeadersSchema,
        body: subscriptionInputSchema,
      },
    },
    async (request, reply) => {
      const principal = await options.authenticator.authenticate(request, ["subscriptions:write"]);
      await requestLimiter.checkAuthenticatedWrite(request, principal);
      const response = await subscriptions.put(
        principal,
        request.params.targetUserId,
        request.body,
        requiredHeader(request, "idempotency-key"),
        request.id,
      );
      return sendMutation(reply, response);
    },
  );

  app.delete<{ Params: TargetUserPath }>(
    "/v1/subscriptions/:targetUserId",
    {
      schema: {
        params: targetUserPathSchema,
        headers: conditionalMutationHeadersSchema,
      },
    },
    async (request, reply) =>
      withPreconditionHeader(reply, async () => {
        const principal = await options.authenticator.authenticate(request, ["subscriptions:write"]);
        await requestLimiter.checkAuthenticatedWrite(request, principal);
        const response = await subscriptions.delete(
          principal,
          request.params.targetUserId,
          requiredHeader(request, "if-match"),
          requiredHeader(request, "idempotency-key"),
          request.id,
        );
        return sendMutation(reply, response);
      }),
  );

  app.get<{ Querystring: ActivityQuerystring }>(
    "/v1/public/activity",
    { schema: { querystring: activityQuerySchema } },
    async (request, reply) => {
      await requestLimiter.checkPublicRecordRead(request);
      const page = await activity.listPublic(activityQuery(request.query));
      return reply.header("cache-control", "no-store").send(page);
    },
  );

  app.get<{ Querystring: ActivityQuerystring }>(
    "/v1/activity",
    { schema: { querystring: activityQuerySchema } },
    async (request) => {
      const principal = await options.authenticator.authenticate(request, ["subscriptions:read"]);
      await requestLimiter.checkAuthenticatedRead(request, principal);
      return activity.listFollowing(principal, activityQuery(request.query));
    },
  );
}

function subscriptionQuery(query: SubscriptionQuerystring): SubscriptionListQuery {
  return {
    ...(query.cursor === undefined ? {} : { cursor: query.cursor }),
    ...(query.limit === undefined ? {} : { limit: query.limit }),
  };
}

function activityQuery(query: ActivityQuerystring): PublicActivityQuery {
  const rawTypes = query.resourceType;
  const resourceTypes = rawTypes === undefined
    ? undefined
    : Array.isArray(rawTypes)
    ? rawTypes
    : [rawTypes];
  return {
    ...(query.cursor === undefined ? {} : { cursor: query.cursor }),
    ...(query.limit === undefined ? {} : { limit: query.limit }),
    ...(query.userId === undefined ? {} : { userId: query.userId }),
    ...(resourceTypes === undefined ? {} : { resourceTypes }),
    ...(query.snapshot === undefined ? {} : { snapshot: query.snapshot }),
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
const loginPathSchema = {
  type: "object",
  required: ["login"],
  properties: {
    login: {
      type: "string",
      minLength: 3,
      maxLength: 64,
      pattern: "^[A-Za-z0-9][A-Za-z0-9._-]*$",
    },
  },
  additionalProperties: false,
};
const targetUserPathSchema = {
  type: "object",
  required: ["targetUserId"],
  properties: { targetUserId: uuid },
  additionalProperties: false,
};
const subscriptionInputSchema = {
  type: "object",
  properties: {
    includeRecords: { type: "boolean", default: true },
    includeEvents: { type: "boolean", default: true },
  },
  additionalProperties: false,
};
const subscriptionQuerySchema = {
  type: "object",
  properties: {
    cursor: { type: "string", minLength: 1, maxLength: 2048 },
    limit: { type: "integer", minimum: 1, maximum: 200, default: 50 },
  },
  additionalProperties: false,
};
const activityQuerySchema = {
  type: "object",
  properties: {
    cursor: { type: "string", minLength: 1, maxLength: 2048 },
    limit: { type: "integer", minimum: 1, maximum: 200, default: 50 },
    userId: uuid,
    snapshot: { type: "string", enum: ["latest"] },
    resourceType: {
      type: "array",
      maxItems: 3,
      uniqueItems: true,
      items: { type: "string", enum: ["user", "record", "event"] },
    },
  },
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
