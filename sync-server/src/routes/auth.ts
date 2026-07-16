import rateLimit from "@fastify/rate-limit";
import type {
  FastifyInstance,
  FastifyReply,
  FastifyRequest,
} from "fastify";

import type { Principal } from "../auth/principal.js";
import type { AuthAttemptLimiter } from "../auth/rate-limit.js";
import type {
  AuthSessionResponse,
  LoginInput,
  RegisterInput,
} from "../auth/service.js";
import { HttpProblem } from "../http/problem.js";

const BEARER_CHALLENGE = 'Bearer realm="exeligmos"';

export interface AuthRouteService {
  register(input: RegisterInput): Promise<AuthSessionResponse>;
  login(input: LoginInput): Promise<AuthSessionResponse>;
  refresh(refreshToken: string): Promise<AuthSessionResponse>;
  logout(principal: Principal, refreshToken: string): Promise<void>;
  authenticate(request: FastifyRequest): Promise<Principal>;
  authenticateForLogout(request: FastifyRequest): Promise<Principal>;
}

export interface AuthRouteOptions {
  readonly authService: AuthRouteService;
  readonly attemptLimiter?: AuthAttemptLimiter;
}

interface RegisterBody {
  readonly login: string;
  readonly password: string;
  readonly displayName?: string;
  readonly inviteCode?: string;
}

interface LoginBody {
  readonly login: string;
  readonly password: string;
}

interface RefreshBody {
  readonly refreshToken: string;
}

const loginNameSchema = {
  type: "string",
  minLength: 3,
  maxLength: 64,
  pattern: "^[A-Za-z0-9][A-Za-z0-9._-]*$",
} as const;

const passwordSchema = {
  type: "string",
  minLength: 12,
  maxLength: 1_024,
} as const;

const refreshTokenSchema = {
  type: "string",
  minLength: 32,
  maxLength: 2_048,
} as const;

const userSchema = {
  type: "object",
  additionalProperties: false,
  required: ["id", "login", "displayName", "createdAt", "updatedAt"],
  properties: {
    id: { type: "string", format: "uuid" },
    login: loginNameSchema,
    displayName: { type: "string", minLength: 1, maxLength: 120 },
    createdAt: { type: "string", format: "date-time" },
    updatedAt: { type: "string", format: "date-time" },
  },
} as const;

const authSessionSchema = {
  type: "object",
  additionalProperties: false,
  required: [
    "tokenType",
    "accessToken",
    "expiresIn",
    "refreshToken",
    "refreshExpiresIn",
    "user",
  ],
  properties: {
    tokenType: { const: "Bearer" },
    accessToken: { type: "string", minLength: 32 },
    expiresIn: { type: "integer", minimum: 1 },
    refreshToken: { type: "string", minLength: 32 },
    refreshExpiresIn: { type: "integer", minimum: 1 },
    user: userSchema,
  },
} as const;

export async function registerAuthRoutes(
  app: FastifyInstance,
  options: AuthRouteOptions,
): Promise<void> {
  await app.register(rateLimit, {
    global: false,
    hook: "onRequest",
    cache: 10_000,
  });

  app.post<{ Body: RegisterBody }>(
    "/v1/auth/register",
    {
      config: {
        rateLimit: {
          max: 5,
          timeWindow: "1 hour",
          groupId: "auth-register",
        },
      },
      schema: {
        body: {
          type: "object",
          additionalProperties: false,
          required: ["login", "password"],
          properties: {
            login: loginNameSchema,
            password: passwordSchema,
            displayName: { type: "string", minLength: 1, maxLength: 120 },
            inviteCode: { type: "string", minLength: 1, maxLength: 200 },
          },
        },
        response: { 201: authSessionSchema },
      },
      preHandler: async (request) =>
        options.attemptLimiter?.checkRegistration(request, request.body.login),
    },
    async (request, reply) => {
      const session = await options.authService.register(request.body);
      return reply
        .header("cache-control", "no-store")
        .header("pragma", "no-cache")
        .header("location", "/v1/me")
        .status(201)
        .send(session);
    },
  );

  app.post<{ Body: LoginBody }>(
    "/v1/auth/login",
    {
      config: {
        rateLimit: {
          max: 10,
          timeWindow: "15 minutes",
          groupId: "auth-login",
        },
      },
      schema: {
        body: {
          type: "object",
          additionalProperties: false,
          required: ["login", "password"],
          properties: {
            login: loginNameSchema,
            password: passwordSchema,
          },
        },
        response: { 200: authSessionSchema },
      },
      preHandler: async (request) =>
        options.attemptLimiter?.checkLogin(request, request.body.login),
    },
    async (request, reply) => withBearerChallenge(reply, async () => {
      const session = await options.authService.login(request.body);
      return reply
        .header("cache-control", "no-store")
        .header("pragma", "no-cache")
        .send(session);
    }),
  );

  app.post<{ Body: RefreshBody }>(
    "/v1/auth/refresh",
    {
      config: {
        rateLimit: {
          max: 30,
          timeWindow: "1 minute",
          groupId: "auth-refresh",
        },
      },
      schema: {
        body: {
          type: "object",
          additionalProperties: false,
          required: ["refreshToken"],
          properties: { refreshToken: refreshTokenSchema },
        },
        response: { 200: authSessionSchema },
      },
      preHandler: async (request) => options.attemptLimiter?.checkRefresh(request),
    },
    async (request, reply) => withBearerChallenge(reply, async () => {
      const session = await options.authService.refresh(request.body.refreshToken);
      return reply
        .header("cache-control", "no-store")
        .header("pragma", "no-cache")
        .send(session);
    }),
  );

  app.post<{ Body: RefreshBody }>(
    "/v1/auth/logout",
    {
      schema: {
        body: {
          type: "object",
          additionalProperties: false,
          required: ["refreshToken"],
          properties: { refreshToken: refreshTokenSchema },
        },
      },
    },
    async (request, reply) => withBearerChallenge(reply, async () => {
      const principal = await options.authService.authenticateForLogout(request);
      await options.authService.logout(principal, request.body.refreshToken);
      return reply.status(204).send();
    }),
  );
}

async function withBearerChallenge<Result>(
  reply: FastifyReply,
  operation: () => Promise<Result>,
): Promise<Result> {
  try {
    return await operation();
  } catch (error) {
    if (error instanceof HttpProblem && error.status === 401) {
      reply.header("www-authenticate", BEARER_CHALLENGE);
    }
    throw error;
  }
}
