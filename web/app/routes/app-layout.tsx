import type { Route } from "./+types/app-layout";
import { AppShell } from "~/components/app-shell";
import { authBoundaryMiddleware, readRequestAuth } from "~/lib/auth-boundary.server";

export const middleware: Route.MiddlewareFunction[] = [authBoundaryMiddleware];

export function loader({ context }: Route.LoaderArgs) {
  return { user: readRequestAuth(context).auth.user };
}

export default function AppLayout({ loaderData }: Route.ComponentProps) {
  return <AppShell user={loaderData.user} />;
}
