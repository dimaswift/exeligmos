import type { Route } from "./+types/record-detail";
import { RecordDetailView } from "~/features/record-detail/record-detail";
import { readOwnerRecord } from "~/features/activity-stream/snapshots.server";
import { readRequestAuth } from "~/lib/auth-boundary.server";
import { isRecordPublicId } from "~/lib/record-id";
import { throwRouteError } from "~/lib/route-errors.server";

export const meta: Route.MetaFunction = ({ loaderData }) => [
  {
    title:
      loaderData?.record.visibility === "public"
        ? `${loaderData.record.payload.emoji ?? "Record"} · Exeligmos`
        : "Private record · Exeligmos",
  },
];

export async function loader({ context, params, request }: Route.LoaderArgs) {
  if (!isRecordPublicId(params.recordId)) {
    throw new Response("Record not found.", { status: 404, statusText: "Not Found" });
  }
  try {
    const boundary = readRequestAuth(context);
    return {
      record: await readOwnerRecord(boundary.auth, params.recordId, { signal: request.signal }),
    };
  } catch (error) {
    return throwRouteError(error, request, {
      clearInvalidAuth: true,
      notFoundMessage: "Record not found.",
    });
  }
}

export default function RecordDetail({ loaderData }: Route.ComponentProps) {
  return <RecordDetailView backHref="/feed" record={loaderData.record} />;
}
