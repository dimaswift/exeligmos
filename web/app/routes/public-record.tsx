import type { Route } from "./+types/public-record";
import { RecordDetailView } from "~/features/record-detail/record-detail";
import { readPublicRecord } from "~/features/activity-stream/snapshots.server";
import { isRecordPublicId } from "~/lib/record-id";
import { throwRouteError } from "~/lib/route-errors.server";

export const meta: Route.MetaFunction = ({ loaderData }) => [
  { title: `${loaderData?.record.payload.emoji ?? "Record"} · Exeligmos` },
];

export async function loader({ params, request }: Route.LoaderArgs) {
  if (!isRecordPublicId(params.recordId)) {
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
