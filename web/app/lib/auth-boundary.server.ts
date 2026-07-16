import { createContext, type MiddlewareFunction, type RouterContextProvider } from "react-router";

import { requireAuth, type AuthBoundary } from "./auth.server";

export type AuthBoundaryResolver = (request: Request) => Promise<AuthBoundary>;

/**
 * Request-scoped authenticated state shared by every loader below the protected layout.
 *
 * Refresh tokens are single use, so nested loaders must consume this context instead of
 * independently calling `requireAuth()` in parallel.
 */
export const authBoundaryContext = createContext<AuthBoundary>();

export function readRequestAuth(context: Readonly<RouterContextProvider>): AuthBoundary {
  return context.get(authBoundaryContext);
}

export function createAuthBoundaryMiddleware(
  resolve: AuthBoundaryResolver = requireAuth,
): MiddlewareFunction<Response> {
  return async ({ context, request }, next) => {
    const boundary = await resolve(request);
    context.set(authBoundaryContext, boundary);

    const response = await next();
    appendBoundaryHeaders(response.headers, boundary.headers);
    return response;
  };
}

export const authBoundaryMiddleware = createAuthBoundaryMiddleware();

function appendBoundaryHeaders(target: Headers, source: Headers | undefined): void {
  if (source === undefined) {
    return;
  }

  for (const [name, value] of source) {
    target.append(name, value);
  }
}
