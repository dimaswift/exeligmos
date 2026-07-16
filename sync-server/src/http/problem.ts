import { STATUS_CODES } from "node:http";

import type { FastifyError, FastifyReply, FastifyRequest } from "fastify";

export interface ProblemDocument {
  readonly type: string;
  readonly title: string;
  readonly status: number;
  readonly code: string;
  readonly detail?: string;
  readonly instance: string;
  readonly requestId: string;
  readonly [extension: string]: unknown;
}

export interface HttpProblemOptions {
  readonly status: number;
  readonly code?: string;
  readonly title?: string;
  readonly type?: string;
  readonly detail?: string;
  readonly extensions?: Readonly<Record<string, unknown>>;
  readonly headers?: Readonly<Record<string, string>>;
}

export class HttpProblem extends Error {
  readonly status: number;
  readonly code: string | undefined;
  readonly title: string;
  readonly type: string;
  readonly extensions: Readonly<Record<string, unknown>>;
  readonly headers: Readonly<Record<string, string>>;

  constructor(options: HttpProblemOptions) {
    const title = options.title ?? STATUS_CODES[options.status] ?? "Error";
    super(options.detail ?? title);
    this.name = "HttpProblem";
    this.status = options.status;
    this.code = options.code;
    this.title = title;
    this.type = options.type ?? "about:blank";
    this.extensions = options.extensions ?? {};
    this.headers = options.headers ?? {};
  }
}

function requestInstance(request: FastifyRequest): string {
  return request.url.split("?", 1)[0] || "/";
}

function problemDocument(
  request: FastifyRequest,
  options: HttpProblemOptions,
): ProblemDocument {
  const title = options.title ?? STATUS_CODES[options.status] ?? "Error";
  const code = options.code ?? defaultProblemCode(options.status);
  const extensions = { ...options.extensions };

  if (options.status === 422 && !Object.hasOwn(extensions, "errors")) {
    extensions.errors = [
      {
        path: "",
        code,
        message: options.detail ?? title,
      },
    ];
  }

  return {
    ...extensions,
    type: options.type ?? "about:blank",
    title,
    status: options.status,
    code,
    ...(options.detail === undefined ? {} : { detail: options.detail }),
    instance: requestInstance(request),
    requestId: request.id,
  };
}

function defaultProblemCode(status: number): string {
  switch (status) {
    case 400:
      return "bad_request";
    case 401:
      return "unauthorized";
    case 403:
      return "forbidden";
    case 404:
      return "not_found";
    case 409:
      return "conflict";
    case 412:
      return "precondition_failed";
    case 413:
      return "payload_too_large";
    case 422:
      return "unprocessable_content";
    case 429:
      return "too_many_requests";
    case 503:
      return "service_unavailable";
    default:
      return status >= 500 ? "internal_error" : "http_error";
  }
}

export function sendProblem(
  request: FastifyRequest,
  reply: FastifyReply,
  options: HttpProblemOptions,
): FastifyReply {
  for (const [name, value] of Object.entries(options.headers ?? {})) {
    reply.header(name, value);
  }
  if (options.status === 401) {
    reply.header("www-authenticate", 'Bearer realm="exeligmos"');
  }

  return reply
    .status(options.status)
    .type("application/problem+json")
    .send(problemDocument(request, options));
}

function isValidationError(
  error: FastifyError,
): error is FastifyError & { validation: readonly unknown[] } {
  return Array.isArray(error.validation);
}

interface ValidationIssue {
  readonly instancePath?: unknown;
  readonly keyword?: unknown;
  readonly params?: unknown;
  readonly message?: unknown;
}

function validationFieldErrors(validation: readonly unknown[]): readonly {
  readonly path: string;
  readonly code: string;
  readonly message: string;
}[] {
  return validation.slice(0, 100).map((value) => {
    const issue = isObject(value) ? value as ValidationIssue : {};
    const keyword = typeof issue.keyword === "string" ? issue.keyword : "invalid";
    const instancePath = typeof issue.instancePath === "string" ? issue.instancePath : "";
    const params = isObject(issue.params) ? issue.params : {};
    const property = keyword === "required" && typeof params.missingProperty === "string"
      ? params.missingProperty
      : keyword === "additionalProperties" && typeof params.additionalProperty === "string"
      ? params.additionalProperty
      : undefined;
    const path = property === undefined
      ? instancePath
      : `${instancePath}/${escapeJsonPointer(property)}`;

    return {
      path,
      code: `schema_${keyword.replaceAll(/[^a-zA-Z0-9_]/g, "_").toLowerCase()}`,
      message: typeof issue.message === "string"
        ? sentenceCase(issue.message)
        : "The value does not match the expected schema.",
    };
  });
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function escapeJsonPointer(value: string): string {
  return value.replaceAll("~", "~0").replaceAll("/", "~1");
}

function sentenceCase(value: string): string {
  return value.length === 0 ? value : `${value[0]?.toUpperCase()}${value.slice(1)}`;
}

function isClientError(error: FastifyError): boolean {
  return (
    typeof error.statusCode === "number" &&
    error.statusCode >= 400 &&
    error.statusCode < 500
  );
}

function isDatabaseTimeout(error: FastifyError): boolean {
  if (!("code" in error)) {
    return false;
  }
  return error.code === "57014" || error.code === "55P03";
}

function isUnsupportedDatabaseText(error: FastifyError): boolean {
  if (!("code" in error)) {
    return false;
  }
  return error.code === "22P05" || error.code === "22021";
}

function isInvalidDatabaseJson(error: FastifyError): boolean {
  return "code" in error &&
    error.code === "22P02" &&
    "routine" in error &&
    String(error.routine).startsWith("json_");
}

export function registerProblemHandlers(app: {
  setErrorHandler(
    handler: (
      error: FastifyError | HttpProblem,
      request: FastifyRequest,
      reply: FastifyReply,
    ) => unknown,
  ): unknown;
  setNotFoundHandler(
    handler: (request: FastifyRequest, reply: FastifyReply) => unknown,
  ): unknown;
}): void {
  app.setNotFoundHandler((request, reply) =>
    sendProblem(request, reply, {
      status: 404,
      title: "Not Found",
      detail: "The requested resource does not exist.",
    }),
  );

  app.setErrorHandler((error, request, reply) => {
    if (error instanceof HttpProblem) {
      return sendProblem(request, reply, {
        status: error.status,
        ...(error.code !== undefined
          ? { code: error.code }
          : error.type.startsWith("urn:exeligmos:problem:")
          ? {
              code: error.type
                .slice("urn:exeligmos:problem:".length)
                .replaceAll("-", "_"),
            }
          : {}),
        title: error.title,
        type: error.type,
        detail: error.message,
        extensions: error.extensions,
        headers: error.headers,
      });
    }

    if (isValidationError(error)) {
      return sendProblem(request, reply, {
        status: 400,
        code: "validation_error",
        title: "Bad Request",
        type: "urn:exeligmos:problem:validation",
        detail: "The request did not match the expected schema.",
        extensions: { errors: validationFieldErrors(error.validation) },
      });
    }

    if (isDatabaseTimeout(error)) {
      return sendProblem(request, reply, {
        status: 503,
        code: "database_timeout",
        title: "Service Unavailable",
        type: "urn:exeligmos:problem:database-timeout",
        detail: "The database could not complete the request within its safety deadline.",
        headers: { "retry-after": "1" },
      });
    }

    if (isUnsupportedDatabaseText(error)) {
      return sendProblem(request, reply, {
        status: 422,
        code: "invalid_text",
        title: "Unprocessable Content",
        type: "urn:exeligmos:problem:invalid-text",
        detail: "The request contains text that PostgreSQL cannot represent.",
      });
    }

    if (isInvalidDatabaseJson(error)) {
      return sendProblem(request, reply, {
        status: 422,
        code: "invalid_json",
        title: "Unprocessable Content",
        type: "urn:exeligmos:problem:invalid-json",
        detail: "JSON strings and object keys must contain PostgreSQL-compatible Unicode text.",
      });
    }

    if (isClientError(error)) {
      return sendProblem(request, reply, {
        status: error.statusCode as number,
        detail: error.message,
      });
    }

    request.log.error({ err: error }, "unhandled request error");
    return sendProblem(request, reply, {
      status: 500,
      title: "Internal Server Error",
      detail: "An unexpected error occurred.",
    });
  });
}
