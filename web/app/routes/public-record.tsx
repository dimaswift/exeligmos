import type { Route } from "./+types/public-record";
import { RecordDetailView } from "~/features/record-detail/record-detail";
import { readPublicRecord } from "~/features/activity-stream/snapshots.server";
import { throwRouteError } from "~/lib/route-errors.server";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export const meta: Route.MetaFunction = ({ loaderData }) => [
  { title: `${loaderData?.record.payload.emoji ?? "Record"} · Exeligmos` },
];

export async function loader({ params, request }: Route.LoaderArgs) {
  if (!UUID.test(params.recordId)) {
    throw new Response("Record not found.", { status: 404, statusText: "Not Found" });
  }
  try {
    return { record: await readPublicRecord(params.recordId, { signal: request.signal }) };
  } catch (error) {
    return throwRouteError(error, request, { notFoundMessage: "Record not found." });
  }
}

export default function PublicRecord({ loaderData }: Route.ComponentProps) {
  return (
    <RecordDetailView
      backHref={`/u/${encodeURIComponent(loaderData.record.author.login)}`}
      record={loaderData.record}
    />
  );
}
