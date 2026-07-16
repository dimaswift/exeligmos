import { createApiClient, type ApiClientOptions, type ApiSchemas } from "@exeligmos/api-client";

export type BackendProblem = ApiSchemas["Problem"];

export interface BackendConnectionOptions {
  /** Overrides API_BASE_URL. Intended for tests and explicitly configured deployments. */
  readonly baseUrl?: string;
  readonly fetch?: typeof globalThis.fetch;
}

interface BackendResult<TData> {
  readonly data?: TData;
  readonly error?: unknown;
  readonly response: Response;
}

interface BackendRequestErrorOptions {
  readonly cause?: unknown;
  readonly problem?: BackendProblem;
  readonly requestId?: string;
  readonly retryAfterSeconds?: number;
}

/** A serializable API failure boundary with the original generated Problem when available. */
export class BackendRequestError extends Error {
  public readonly problem?: BackendProblem;
  public readonly requestId?: string;
  public readonly retryAfterSeconds?: number;

  public constructor(
    message: string,
    public readonly status: number,
    options: BackendRequestErrorOptions = {},
  ) {
    super(message, { cause: options.cause });
    this.name = "BackendRequestError";
    this.problem = options.problem;
    this.requestId = options.requestId;
    this.retryAfterSeconds = options.retryAfterSeconds;
  }

  public get code(): string | undefined {
    return this.problem?.code;
  }
}

export function backendApiBaseUrl(configured = process.env.API_BASE_URL): string {
  const value = configured ?? "http://127.0.0.1:8788";
  try {
    return new URL(value).toString().replace(/\/$/, "");
  } catch {
    throw new Error("API_BASE_URL must be an absolute URL.");
  }
}

/**
 * Creates a generated OpenAPI client. Supplying an access token never grants this helper authority
 * to refresh it; refresh rotation remains owned by the app-layout authentication boundary.
 */
export function createBackendApiClient(
  options: BackendConnectionOptions & Pick<ApiClientOptions, "accessToken"> = {},
) {
  return createApiClient({
    baseUrl: backendApiBaseUrl(options.baseUrl),
    accessToken: options.accessToken,
    fetch: options.fetch,
  });
}

/** Executes one generated-client read and normalizes HTTP and transport failures. */
export async function readBackendData<TData>(
  operation: () => Promise<BackendResult<TData>>,
  fallback: string,
): Promise<TData> {
  let result: BackendResult<TData>;
  try {
    result = await operation();
  } catch (cause) {
    throw new BackendRequestError(fallback, 502, { cause });
  }

  if (result.data !== undefined) {
    return result.data;
  }
  throw backendRequestError(result.error, result.response, fallback);
}

export function backendRequestError(
  value: unknown,
  response: Response,
  fallback: string,
): BackendRequestError {
  const problem = isBackendProblem(value) ? value : undefined;
  const requestId = problem?.requestId ?? response.headers.get("X-Request-Id") ?? undefined;
  const retryAfterSeconds = retryAfter(response.headers.get("Retry-After"));
  return new BackendRequestError(problemMessage(problem, fallback), response.status, {
    problem,
    requestId,
    retryAfterSeconds,
  });
}

function isBackendProblem(value: unknown): value is BackendProblem {
  if (typeof value !== "object" || value === null) {
    return false;
  }
  return (
    typeof Reflect.get(value, "type") === "string" &&
    typeof Reflect.get(value, "title") === "string" &&
    typeof Reflect.get(value, "status") === "number" &&
    typeof Reflect.get(value, "code") === "string" &&
    typeof Reflect.get(value, "requestId") === "string"
  );
}

function problemMessage(problem: BackendProblem | undefined, fallback: string): string {
  if (problem?.detail !== undefined && problem.detail.trim() !== "") {
    return problem.detail;
  }
  if (problem?.title !== undefined && problem.title.trim() !== "") {
    return problem.title;
  }
  return fallback;
}

function retryAfter(value: string | null): number | undefined {
  if (value === null || !/^\d+$/.test(value)) {
    return undefined;
  }
  const seconds = Number(value);
  return Number.isSafeInteger(seconds) ? seconds : undefined;
}
