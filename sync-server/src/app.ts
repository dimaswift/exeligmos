import Fastify, {
  type FastifyBaseLogger,
  type FastifyInstance,
  type FastifyServerOptions,
} from "fastify";

import { BearerAuthenticator } from "./auth/bearer-authenticator.js";
import {
  PostgresAuthAttemptLimiter,
  type AuthAttemptLimiter,
} from "./auth/rate-limit.js";
import { createAuthService } from "./auth/service.js";
import type { ServerConfig } from "./config.js";
import type { Database } from "./db/database.js";
import { registerProblemHandlers } from "./http/problem.js";
import { LocalMediaStorage, type MediaStorage } from "./media/storage.js";
import { registerAuthRoutes } from "./routes/auth.js";
import { registerEventRoutes } from "./routes/events.js";
import { registerHealthRoutes } from "./routes/health.js";
import { registerMediaRoutes } from "./routes/media.js";
import { registerOpenApiRoutes } from "./routes/openapi.js";
import { registerOwnerSecurityRoutes } from "./routes/owner-security.js";
import { registerRecordRoutes } from "./routes/records.js";
import { registerSocialRoutes } from "./routes/social.js";
import { registerSyncRoutes } from "./routes/sync.js";
import { registerTagRoutes } from "./routes/tags.js";
import { registerTemplateRoutes } from "./routes/templates.js";
import {
  PostgresResourceRequestLimiter,
  type ResourceRequestLimiter,
} from "./resources/rate-limit.js";

export interface BuildAppOptions {
  readonly config: ServerConfig;
  readonly database: Database;
  readonly logger?: FastifyBaseLogger;
  /** Override only for deterministic tests or an externally managed limiter. */
  readonly authAttemptLimiter?: AuthAttemptLimiter;
  /** Override only for deterministic tests or an externally managed limiter. */
  readonly resourceRequestLimiter?: ResourceRequestLimiter;
  /** Override only for deterministic tests or externally managed storage. */
  readonly mediaStorage?: MediaStorage;
}

function loggerOptions(
  config: ServerConfig,
): Exclude<FastifyServerOptions["logger"], undefined> {
  if (config.nodeEnv === "test" || config.logLevel === "silent") {
    return false;
  }

  return {
    level: config.logLevel,
    redact: {
      paths: [
        "req.headers.authorization",
        "req.headers.cookie",
        "req.body.password",
        "req.body.refreshToken",
        "req.body.apiKey",
        "res.headers.set-cookie",
      ],
      censor: "[REDACTED]",
    },
  };
}

export function buildApp(options: BuildAppOptions): FastifyInstance {
  const serverOptions: FastifyServerOptions = {
    trustProxy: options.config.trustProxy,
    requestIdHeader: "x-request-id",
    return503OnClosing: true,
    bodyLimit: 1_048_576,
  };

  if (options.logger === undefined) {
    serverOptions.logger = loggerOptions(options.config);
  } else {
    serverOptions.loggerInstance = options.logger;
  }

  const app = Fastify(serverOptions);
  const authService = createAuthService(options.database, options.config.auth);
  const authenticator = new BearerAuthenticator(options.database, authService);
  const authAttemptLimiter = options.authAttemptLimiter ??
    new PostgresAuthAttemptLimiter(options.database);
  const resourceRequestLimiter = options.resourceRequestLimiter ??
    new PostgresResourceRequestLimiter(options.database);
  const mediaStorage = options.mediaStorage ??
    new LocalMediaStorage(options.config.media.storageRoot);
  registerProblemHandlers(app);

  app.addHook("onRequest", async (request, reply) => {
    reply.header("x-request-id", request.id);
  });

  app.addHook("onSend", async (request, reply) => {
    reply.header("x-content-type-options", "nosniff");
    reply.header("x-frame-options", "DENY");
    reply.header("referrer-policy", "no-referrer");

    if (
      request.url.startsWith("/v1/") &&
      !request.url.startsWith("/v1/public/") &&
      !reply.hasHeader("cache-control")
    ) {
      reply.header("cache-control", "no-store");
    }
  });

  app.register(registerHealthRoutes, { database: options.database });
  registerOpenApiRoutes(app);
  app.register(registerAuthRoutes, {
    authService,
    attemptLimiter: authAttemptLimiter,
  });
  app.register(registerOwnerSecurityRoutes, {
    database: options.database,
    authenticator,
    requestLimiter: resourceRequestLimiter,
  });
  app.register(registerRecordRoutes, {
    database: options.database,
    authenticator,
    requestLimiter: resourceRequestLimiter,
  });
  app.register(registerEventRoutes, {
    database: options.database,
    authenticator,
    requestLimiter: resourceRequestLimiter,
  });
  app.register(registerSocialRoutes, {
    database: options.database,
    authenticator,
    requestLimiter: resourceRequestLimiter,
  });
  app.register(registerTagRoutes, {
    database: options.database,
    authenticator,
    requestLimiter: resourceRequestLimiter,
  });
  app.register(registerTemplateRoutes, {
    database: options.database,
    authenticator,
    requestLimiter: resourceRequestLimiter,
  });
  app.register(registerMediaRoutes, {
    database: options.database,
    authenticator,
    requestLimiter: resourceRequestLimiter,
    storage: mediaStorage,
    maxByteLength: options.config.media.maxByteLength,
    uploadTtlMs: options.config.media.uploadTtlMs,
  });
  app.register(registerSyncRoutes, {
    database: options.database,
    authenticator,
    requestLimiter: resourceRequestLimiter,
  });

  app.addHook("onClose", async () => {
    await options.database.close();
  });

  return app;
}
