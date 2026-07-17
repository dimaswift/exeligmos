import type { Route } from "./+types/app-layout";
import { AppShell } from "~/components/app-shell";
import { realtimeSarosIntervalsAt } from "~/features/temporal/solar-engine.server";
import { authBoundaryMiddleware, readRequestAuth } from "~/lib/auth-boundary.server";

export const middleware: Route.MiddlewareFunction[] = [authBoundaryMiddleware];

export function loader({ context }: Route.LoaderArgs) {
  const observedAt = Date.now() / 1_000;
  return {
    user: readRequestAuth(context).auth.user,
    sarosWindow: {
      observedAt,
      intervals: realtimeSarosIntervalsAt(observedAt),
    },
  };
}

export default function AppLayout({ loaderData }: Route.ComponentProps) {
  return <AppShell sarosWindow={loaderData.sarosWindow} user={loaderData.user} />;
}
