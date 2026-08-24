import type { Route } from "./+types/history";
import { HistoryExplorer } from "~/features/history/history";
import { parseHistoryQuery, searchHistory } from "~/features/history/history.server";

export const meta: Route.MetaFunction = () => [
  { title: "History · Fractonica" },
  {
    name: "description",
    content: "Query historical events by text, filters, Saros series, radix, and phase address.",
  },
];

export function loader({ request }: Route.LoaderArgs) {
  return searchHistory(parseHistoryQuery(request.url));
}

export default function History({ loaderData }: Route.ComponentProps) {
  return <HistoryExplorer result={loaderData} />;
}
