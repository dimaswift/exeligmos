import { redirect } from "react-router";

import type { AuthSession } from "@exeligmos/api-client";

import { createBackendApiClient, readBackendData } from "./backend.server";
import {
  commitAuthSession,
  destroyAuthSession,
  readAuthSession,
  toStoredAuthSession,
  type StoredAuthSession,
} from "./session.server";

const REFRESH_MARGIN_MS = 30_000;
const REFRESH_FLIGHT_RETENTION_MS = 5_000;
const refreshFlights = new Map<string, Promise<AuthSession>>();

export { BackendRequestError } from "./backend.server";

export interface AuthBoundary {
  readonly auth: StoredAuthSession;
  readonly headers?: Headers;
}

export async function loginWithPassword(login: string, password: string): Promise<AuthSession> {
  const client = createBackendApiClient();
  return readBackendData(
    () => client.POST("/v1/auth/login", { body: { login, password } }),
    "Login failed.",
  );
}

export async function requireAuth(request: Request): Promise<AuthBoundary> {
  const current = await readAuthSession(request);
  if (current === null) {
    throw redirect(loginRedirect(request), {
      headers: { "Set-Cookie": await destroyAuthSession(request) },
    });
  }

  if (current.accessExpiresAt > Date.now() + REFRESH_MARGIN_MS) {
    return { auth: current };
  }

  let refreshed: AuthSession;
  try {
    refreshed = await refreshBackendSession(current.refreshToken);
  } catch {
    throw redirect(loginRedirect(request), {
      headers: { "Set-Cookie": await destroyAuthSession(request) },
    });
  }

  const auth = toStoredAuthSession(refreshed);
  const headers = new Headers({ "Set-Cookie": await commitAuthSession(request, auth) });
  return { auth, headers };
}

export async function revokeBackendSession(auth: StoredAuthSession): Promise<void> {
  const client = createBackendApiClient({ accessToken: auth.accessToken });
  await client.POST("/v1/auth/logout", { body: { refreshToken: auth.refreshToken } });
}

export function assertSameOrigin(request: Request): void {
  const origin = request.headers.get("Origin");
  if (origin !== null && origin !== new URL(request.url).origin) {
    throw new Response("Cross-origin form submission rejected.", { status: 403 });
  }
}

function refreshBackendSession(refreshToken: string): Promise<AuthSession> {
  const existing = refreshFlights.get(refreshToken);
  if (existing !== undefined) {
    return existing;
  }

  const client = createBackendApiClient();
  const flight = readBackendData(
    () => client.POST("/v1/auth/refresh", { body: { refreshToken } }),
    "Session refresh failed.",
  );
  refreshFlights.set(refreshToken, flight);
  const release = () => {
    const timer = setTimeout(() => {
      if (refreshFlights.get(refreshToken) === flight) {
        refreshFlights.delete(refreshToken);
      }
    }, REFRESH_FLIGHT_RETENTION_MS);
    timer.unref();
  };
  void flight.then(release, release);
  return flight;
}

function loginRedirect(request: Request): string {
  const url = new URL(request.url);
  return `/login?returnTo=${encodeURIComponent(`${url.pathname}${url.search}`)}`;
}
