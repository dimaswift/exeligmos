import { redirect } from "react-router";

import { BackendRequestError } from "./backend.server";
import { destroyAuthSession } from "./session.server";

export interface RouteErrorOptions {
  readonly clearInvalidAuth?: boolean;
  readonly notFoundMessage?: string;
}

/** Preserves API status/retry diagnostics while keeping generated Problem bodies server-side. */
export async function throwRouteError(
  error: unknown,
  request: Request,
  options: RouteErrorOptions = {},
): Promise<never> {
  if (!(error instanceof BackendRequestError)) {
    throw error;
  }

  if (error.status === 401 && options.clearInvalidAuth === true) {
    const url = new URL(request.url);
    const returnTo = `${url.pathname}${url.search}`;
    throw redirect(`/login?returnTo=${encodeURIComponent(returnTo)}`, {
      headers: { "Set-Cookie": await destroyAuthSession(request) },
    });
  }

  const headers = new Headers();
  if (error.requestId !== undefined) {
    headers.set("X-Request-Id", error.requestId);
  }
  if (error.retryAfterSeconds !== undefined) {
    headers.set("Retry-After", String(error.retryAfterSeconds));
  }
  const message =
    error.status === 404 && options.notFoundMessage !== undefined
      ? options.notFoundMessage
      : error.message;
  throw new Response(message, {
    headers,
    status: normalizeHttpStatus(error.status),
    statusText: statusText(error.status),
  });
}

function normalizeHttpStatus(status: number): number {
  return Number.isInteger(status) && status >= 400 && status <= 599 ? status : 502;
}

function statusText(status: number): string {
  switch (status) {
    case 400:
      return "Bad Request";
    case 401:
      return "Unauthorized";
    case 403:
      return "Forbidden";
    case 404:
      return "Not Found";
    case 409:
      return "Conflict";
    case 429:
      return "Too Many Requests";
    case 503:
      return "Service Unavailable";
    default:
      return "Bad Gateway";
  }
}
