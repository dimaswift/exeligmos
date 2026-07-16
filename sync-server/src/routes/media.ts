import type {
  FastifyInstance,
  FastifyReply,
  FastifyRequest,
} from "fastify";

import type { Authenticator } from "../auth/principal.js";
import type { Database } from "../db/database.js";
import type { MediaStorage } from "../media/storage.js";
import {
  type CreateMediaUploadInput,
  DEFAULT_MEDIA_UPLOAD_TTL_MS,
  MAX_MEDIA_BYTE_LENGTH,
  type MediaDownload,
  MediaService,
} from "../resources/media.js";
import {
  NOOP_RESOURCE_REQUEST_LIMITER,
  type ResourceRequestLimiter,
} from "../resources/rate-limit.js";
import {
  invalidRequest,
  type MutationResponse,
  PreconditionFailedProblem,
} from "../resources/shared.js";

export interface MediaRoutesOptions {
  readonly database: Database;
  readonly authenticator: Authenticator;
  readonly storage: MediaStorage;
  readonly requestLimiter?: ResourceRequestLimiter;
  readonly maxByteLength?: number;
  readonly uploadTtlMs?: number;
}

interface UploadPath {
  readonly uploadId: string;
}

interface MediaPath {
  readonly mediaId: string;
}

interface BinaryBody extends AsyncIterable<Uint8Array | string> {}

export async function registerMediaRoutes(
  app: FastifyInstance,
  options: MediaRoutesOptions,
): Promise<void> {
  registerBinaryStreamParser(app);
  const requestLimiter = options.requestLimiter ?? NOOP_RESOURCE_REQUEST_LIMITER;
  const maxByteLength = options.maxByteLength ?? MAX_MEDIA_BYTE_LENGTH;
  const service = new MediaService(options.database, options.storage, {
    maxByteLength,
    uploadTtlMs: options.uploadTtlMs ?? DEFAULT_MEDIA_UPLOAD_TTL_MS,
  });

  app.post<{ Body: CreateMediaUploadInput }>(
    "/v1/media-upload-sessions",
    {
      schema: {
        headers: idempotencyHeadersSchema,
        body: createMediaUploadSchema(maxByteLength),
      },
    },
    async (request, reply) => {
      const principal = await options.authenticator.authenticate(request, ["media:write"]);
      await requestLimiter.checkAuthenticatedWrite(request, principal);
      const response = await service.createUpload(
        principal,
        request.body,
        requiredHeader(request, "idempotency-key"),
        request.id,
      );
      return sendMutation(reply, response);
    },
  );

  app.get<{ Params: UploadPath }>(
    "/v1/media-upload-sessions/:uploadId",
    { schema: { params: uploadPathSchema } },
    async (request) => {
      const principal = await options.authenticator.authenticate(request, ["media:write"]);
      await requestLimiter.checkAuthenticatedRead(request, principal);
      return service.getUpload(principal, request.params.uploadId);
    },
  );

  app.delete<{ Params: UploadPath }>(
    "/v1/media-upload-sessions/:uploadId",
    { schema: { params: uploadPathSchema } },
    async (request, reply) => {
      const principal = await options.authenticator.authenticate(request, ["media:write"]);
      await requestLimiter.checkAuthenticatedWrite(request, principal);
      await service.abortUpload(principal, request.params.uploadId, request.id);
      return reply.code(204).send();
    },
  );

  app.put<{ Params: UploadPath; Body: BinaryBody }>(
    "/v1/media-upload-sessions/:uploadId/content",
    {
      schema: {
        params: uploadPathSchema,
        headers: uploadContentHeadersSchema(maxByteLength),
      },
    },
    async (request, reply) => {
      const principal = await options.authenticator.authenticate(request, ["media:write"]);
      await requestLimiter.checkAuthenticatedWrite(request, principal);
      await service.receiveUpload(
        principal,
        request.params.uploadId,
        request.body,
        requiredIntegerHeader(request, "content-length"),
        requiredHeader(request, "x-content-sha256"),
        request.id,
      );
      return reply.code(204).send();
    },
  );

  app.post<{ Params: UploadPath }>(
    "/v1/media-upload-sessions/:uploadId/complete",
    {
      schema: {
        params: uploadPathSchema,
        headers: idempotencyHeadersSchema,
      },
    },
    async (request, reply) => {
      const principal = await options.authenticator.authenticate(request, ["media:write"]);
      await requestLimiter.checkAuthenticatedWrite(request, principal);
      const response = await service.completeUpload(
        principal,
        request.params.uploadId,
        requiredHeader(request, "idempotency-key"),
        request.id,
      );
      return sendMutation(reply, response);
    },
  );

  app.get<{ Params: MediaPath }>(
    "/v1/media/:mediaId",
    { schema: { params: mediaPathSchema } },
    async (request, reply) => {
      const principal = await options.authenticator.authenticate(request, ["media:read"]);
      await requestLimiter.checkAuthenticatedRead(request, principal);
      const resource = await service.getOwner(principal.userId, request.params.mediaId);
      return reply
        .header("etag", `"media-${resource.id}-r${resource.revision}"`)
        .send(resource);
    },
  );

  app.delete<{ Params: MediaPath }>(
    "/v1/media/:mediaId",
    {
      schema: {
        params: mediaPathSchema,
        headers: conditionalMutationHeadersSchema,
      },
    },
    async (request, reply) =>
      withPreconditionHeader(reply, async () => {
        const principal = await options.authenticator.authenticate(request, ["media:write"]);
        await requestLimiter.checkAuthenticatedWrite(request, principal);
        const response = await service.delete(
          principal,
          request.params.mediaId,
          requiredHeader(request, "if-match"),
          requiredHeader(request, "idempotency-key"),
          request.id,
        );
        return sendMutation(reply, response);
      }),
  );

  app.get<{ Params: MediaPath }>(
    "/v1/media/:mediaId/content",
    { schema: { params: mediaPathSchema } },
    async (request, reply) => {
      const principal = await options.authenticator.authenticate(request, ["media:read"]);
      await requestLimiter.checkAuthenticatedRead(request, principal);
      return sendDownload(
        reply,
        await service.downloadOwner(principal.userId, request.params.mediaId),
        false,
      );
    },
  );

  app.get<{ Params: MediaPath }>(
    "/v1/public/media/:mediaId/content",
    { schema: { params: mediaPathSchema } },
    async (request, reply) => {
      await requestLimiter.checkPublicRecordRead(request);
      return sendDownload(
        reply,
        await service.downloadPublic(request.params.mediaId),
        true,
      );
    },
  );
}

function registerBinaryStreamParser(app: FastifyInstance): void {
  if (app.hasContentTypeParser("application/octet-stream")) {
    return;
  }
  app.addContentTypeParser(
    "application/octet-stream",
    (_request, payload, done) => done(null, payload),
  );
}

function sendDownload(
  reply: FastifyReply,
  download: MediaDownload,
  publicDownload: boolean,
): FastifyReply {
  reply
    .header("content-type", download.contentType)
    .header("content-length", String(download.byteLength))
    .header("etag", download.etag)
    .header("x-content-sha256", download.sha256)
    // A public upload may legitimately be HTML or SVG. If a media URL is
    // navigated as a document, keep that untrusted content in a unique sandbox
    // with no script/network privileges under the API origin.
    .header("content-security-policy", "sandbox; default-src 'none'");
  if (publicDownload) {
    reply.header("cache-control", "public, max-age=31536000, immutable");
  }
  return reply.send(download.stream);
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

function requiredHeader(
  request: FastifyRequest,
  name: "idempotency-key" | "if-match" | "x-content-sha256",
): string {
  const value = request.headers[name];
  if (typeof value !== "string") {
    throw invalidRequest(`The ${name} header is required.`);
  }
  return value;
}

function requiredIntegerHeader(request: FastifyRequest, name: "content-length"): number {
  const value = request.headers[name];
  const normalized = typeof value === "number" ? String(value) : value;
  if (typeof normalized !== "string" || !/^\d+$/.test(normalized)) {
    throw invalidRequest(`The ${name} header must be a positive integer.`);
  }
  const parsed = Number(normalized);
  if (!Number.isSafeInteger(parsed) || parsed < 1) {
    throw invalidRequest(`The ${name} header must be a positive integer.`);
  }
  return parsed;
}

const uuid = { type: "string", format: "uuid" };
const uploadPathSchema = {
  type: "object",
  required: ["uploadId"],
  properties: { uploadId: uuid },
  additionalProperties: false,
};
const mediaPathSchema = {
  type: "object",
  required: ["mediaId"],
  properties: { mediaId: uuid },
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
const encryptionSchema = {
  type: "object",
  required: ["algorithm", "cryptoVersion", "keyVersion", "nonce"],
  properties: {
    algorithm: { const: "A256GCM" },
    cryptoVersion: { const: 1 },
    keyVersion: { const: 1 },
    nonce: { type: "string", minLength: 16, maxLength: 16, pattern: "^[A-Za-z0-9+/]{16}$" },
    plaintextContentType: {
      type: "string",
      minLength: 3,
      maxLength: 255,
      pattern: "^[A-Za-z0-9][A-Za-z0-9.+_-]{0,126}/[A-Za-z0-9][A-Za-z0-9.+_-]{0,126}$",
    },
  },
  additionalProperties: false,
};

function createMediaUploadSchema(maxByteLength: number): Record<string, unknown> {
  return {
    type: "object",
    required: ["deviceId", "fileName", "contentType", "byteLength", "sha256"],
    properties: {
      mediaId: uuid,
      deviceId: uuid,
      fileName: { type: "string", minLength: 1, maxLength: 255, pattern: "^[^/\\\\]+$" },
      contentType: {
        type: "string",
        minLength: 3,
        maxLength: 255,
        pattern: "^[A-Za-z0-9][A-Za-z0-9.+_-]{0,126}/[A-Za-z0-9][A-Za-z0-9.+_-]{0,126}$",
      },
      byteLength: { type: "integer", minimum: 1, maximum: maxByteLength },
      sha256: { type: "string", pattern: "^[a-f0-9]{64}$" },
      encryption: encryptionSchema,
    },
    allOf: [
      {
        if: { required: ["encryption"] },
        then: { required: ["mediaId"] },
      },
    ],
    additionalProperties: false,
  };
}

function uploadContentHeadersSchema(maxByteLength: number): Record<string, unknown> {
  return {
    type: "object",
    required: ["content-length", "x-content-sha256"],
    properties: {
      "content-length": {
        type: "integer",
        minimum: 1,
        maximum: maxByteLength,
      },
      "x-content-sha256": { type: "string", pattern: "^[a-f0-9]{64}$" },
    },
  };
}
