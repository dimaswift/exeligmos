import type { Route } from "./+types/public-layout";
import { PublicShell } from "~/components/public-shell";
import { realtimeSarosIntervalsAt } from "~/features/temporal/solar-engine.server";

export function loader() {
  const observedAt = Date.now() / 1_000;
  return {
    sarosWindow: {
      observedAt,
      intervals: realtimeSarosIntervalsAt(observedAt),
    },
  };
}

export default function PublicLayout({ loaderData }: Route.ComponentProps) {
  return <PublicShell sarosWindow={loaderData.sarosWindow} />;
}
