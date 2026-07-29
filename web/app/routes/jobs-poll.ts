import type { Route } from "./+types/jobs-poll";
import { readJobs } from "~/features/jobs/jobs.server";
import { readRequestAuth } from "~/lib/auth-boundary.server";
import { BackendRequestError } from "~/lib/backend.server";
import { throwRouteError } from "~/lib/route-errors.server";

export async function loader({ context, request }: Route.LoaderArgs) {
  try {
    const auth = readRequestAuth(context).auth;
    return {
      jobs: await readJobs(auth, { signal: request.signal }),
      unavailable: false,
    };
  } catch (error) {
    if (isTransientPollFailure(error)) {
      return {
        jobs: null,
        unavailable: true,
      };
    }
    return throwRouteError(error, request, { clearInvalidAuth: true });
  }
}

function isTransientPollFailure(error: unknown): boolean {
  return error instanceof BackendRequestError && (error.status === 429 || error.status >= 500);
}
