import type { Route } from "./+types/engine-lab";
import { LiveSystemLab } from "~/features/engine-lab/live-system-lab";
import { parseEngineLabQuery } from "~/features/engine-lab/query";
import {
  activeSarosIntervals,
  solarTemporalDataMetadata,
} from "~/features/temporal/solar-engine.server";

export const meta: Route.MetaFunction = () => [
  { title: "System lab · Exeligmos" },
  {
    name: "description",
    content: "Realtime Saros Grid, waveform, repdigit periods, and octal pulse inspection.",
  },
];

export function loader({ request }: Route.LoaderArgs) {
  const observedAt = Date.now() / 1_000;
  const query = parseEngineLabQuery(request.url);
  return {
    observedAt,
    harmonicDepth: query.depth,
    intervals: activeSarosIntervals(observedAt),
    solarData: solarTemporalDataMetadata,
  };
}

export default function EngineLab({ loaderData }: Route.ComponentProps) {
  return <LiveSystemLab {...loaderData} />;
}
