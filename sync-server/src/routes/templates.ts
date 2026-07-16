import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";

import type { Authenticator } from "../auth/principal.js";
import type { Database } from "../db/database.js";
import {
  PUBLIC_RECORD_PAYLOAD_MAX_BYTES,
  RESOURCE_METADATA_MAX_BYTES,
} from "../resources/limits.js";
import {
  NOOP_RESOURCE_REQUEST_LIMITER,
  type ResourceRequestLimiter,
} from "../resources/rate-limit.js";
import {
  type CreateTemplateInput,
  type TemplateListQuery,
  TemplateService,
  type UpdateTemplateInput,
  templateEtag,
} from "../resources/templates.js";
import {
  type MutationResponse,
  PreconditionFailedProblem,
  invalidRequest,
} from "../resources/shared.js";

export interface TemplateRoutesOptions {
  readonly database: Database;
  readonly authenticator: Authenticator;
  /** Omitted by isolated route tests; buildApp injects the shared limiter. */
  readonly requestLimiter?: ResourceRequestLimiter;
}

interface TemplatePath {
  readonly templateId: string;
}

interface TemplateQuerystring {
  readonly cursor?: string;
  readonly limit?: string | number;
  readonly updatedAfter?: string;
}

interface TemplateVersionQuerystring {
  readonly version?: string | number;
}

export async function registerTemplateRoutes(
  app: FastifyInstance,
  options: TemplateRoutesOptions,
): Promise<void> {
  registerMergePatchParser(app);
  const service = new TemplateService(options.database);
  const requestLimiter = options.requestLimiter ?? NOOP_RESOURCE_REQUEST_LIMITER;

  app.get<{ Querystring: TemplateQuerystring }>(
    "/v1/templates",
    { schema: { querystring: templateQuerySchema } },
    async (request) => {
      const principal = await options.authenticator.authenticate(request, ["templates:read"]);
      await requestLimiter.checkAuthenticatedRead(request, principal);
      return service.list(principal, templateQuery(request.query));
    },
  );

  app.post<{ Body: CreateTemplateInput }>(
    "/v1/templates",
    { schema: { headers: idempotencyHeadersSchema, body: createTemplateSchema } },
    async (request, reply) => {
      const principal = await options.authenticator.authenticate(request, ["templates:write"]);
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

  app.get<{ Params: TemplatePath; Querystring: TemplateVersionQuerystring }>(
    "/v1/templates/:templateId",
    { schema: { params: templatePathSchema, querystring: templateVersionQuerySchema } },
    async (request, reply) => {
      const principal = await options.authenticator.authenticate(request, ["templates:read"]);
      await requestLimiter.checkAuthenticatedRead(request, principal);
      const resource = await service.get(
        principal.userId,
        request.params.templateId,
        request.query.version,
      );
      return reply.header("etag", templateEtag(resource.id, resource.revision)).send(resource);
    },
  );

  app.patch<{ Params: TemplatePath; Body: UpdateTemplateInput }>(
    "/v1/templates/:templateId",
    {
      schema: {
        params: templatePathSchema,
        headers: conditionalMutationHeadersSchema,
        body: updateTemplateSchema,
      },
    },
    async (request, reply) =>
      withPreconditionHeader(reply, async () => {
        const principal = await options.authenticator.authenticate(request, ["templates:write"]);
        await requestLimiter.checkAuthenticatedWrite(request, principal);
        const response = await service.createVersion(
          principal,
          request.params.templateId,
          request.body,
          requiredHeader(request, "if-match"),
          requiredHeader(request, "idempotency-key"),
          request.id,
        );
        return sendMutation(reply, response);
      }),
  );

  app.delete<{ Params: TemplatePath }>(
    "/v1/templates/:templateId",
    { schema: { params: templatePathSchema, headers: conditionalMutationHeadersSchema } },
    async (request, reply) =>
      withPreconditionHeader(reply, async () => {
        const principal = await options.authenticator.authenticate(request, ["templates:write"]);
        await requestLimiter.checkAuthenticatedWrite(request, principal);
        const response = await service.retire(
          principal,
          request.params.templateId,
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

function templateQuery(query: TemplateQuerystring): TemplateListQuery {
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
const payloadObject = {
  type: "object",
  minProperties: 1,
  additionalProperties: true,
  description: `Must serialize to at most ${PUBLIC_RECORD_PAYLOAD_MAX_BYTES} UTF-8 bytes.`,
};
const variableSchemaObject = {
  type: "object",
  minProperties: 1,
  additionalProperties: true,
  description: "JSON Schema 2020-12 used to validate render variables.",
};
const templateProperties = {
  id: uuid,
  name: { type: "string", minLength: 1, maxLength: 120 },
  description: { type: "string", maxLength: 2_000 },
  engine: { type: "string", enum: ["mustache"] },
  body: payloadObject,
  variableSchema: variableSchemaObject,
  metadata: metadataObject,
};

/** Reused verbatim by the synchronization batch route. */
export const createTemplateSchema = {
  type: "object",
  required: ["name", "engine", "body", "variableSchema"],
  properties: templateProperties,
  additionalProperties: false,
};

export const updateTemplateSchema = {
  type: "object",
  minProperties: 1,
  properties: {
    name: templateProperties.name,
    description: { anyOf: [templateProperties.description, { type: "null" }] },
    engine: templateProperties.engine,
    body: payloadObject,
    variableSchema: variableSchemaObject,
    metadata: metadataObject,
  },
  additionalProperties: false,
};

const templatePathSchema = {
  type: "object",
  required: ["templateId"],
  properties: { templateId: uuid },
  additionalProperties: false,
};
const templateVersionQuerySchema = {
  type: "object",
  properties: { version: { type: "integer", minimum: 1, maximum: 2_147_483_647 } },
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
const templateQuerySchema = {
  type: "object",
  properties: {
    cursor: { type: "string", minLength: 1, maxLength: 2048 },
    limit: { type: "integer", minimum: 1, maximum: 200, default: 50 },
    updatedAfter: dateTime,
  },
  additionalProperties: false,
};
