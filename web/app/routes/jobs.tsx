import { useFetcher } from "react-router";

import type { Route } from "./+types/jobs";
import type { loader as jobsPollLoader } from "./jobs-poll";
import { JobsDashboard } from "~/features/jobs/jobs-dashboard";
import { useJobsPolling } from "~/features/jobs/jobs-polling";
import { readJobs } from "~/features/jobs/jobs.server";
import { readRequestAuth } from "~/lib/auth-boundary.server";
import { throwRouteError } from "~/lib/route-errors.server";

export const meta: Route.MetaFunction = () => [{ title: "Jobs · Fractonica" }];

export async function loader({ context, request }: Route.LoaderArgs) {
  try {
    const auth = readRequestAuth(context).auth;
    return {
      jobs: await readJobs(auth, { signal: request.signal }),
    };
  } catch (error) {
    return throwRouteError(error, request, { clearInvalidAuth: true });
  }
}

export default function Jobs({ loaderData }: Route.ComponentProps) {
  const fetcher = useFetcher<typeof jobsPollLoader>();
  const jobs = fetcher.data?.jobs ?? loaderData.jobs;
  const active = jobs.data.some((job) => job.activity === "active");
  useJobsPolling(active, fetcher.state !== "idle", () => fetcher.load("/jobs/poll"));

  return (
    <JobsDashboard
      jobs={jobs}
      pollUnavailable={fetcher.data?.unavailable === true}
      refreshing={fetcher.state !== "idle"}
    />
  );
}
