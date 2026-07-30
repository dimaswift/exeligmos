import { data, redirect, useActionData } from "react-router";

import type { Route } from "./+types/record-detail";
import { RecordDetailView } from "~/features/record-detail/record-detail";
import { readOwnerRecord } from "~/features/activity-stream/snapshots.server";
import {
  readRecordDreamRequest,
  scheduleRecordDream,
} from "~/features/workers/workers.server";
import { assertSameOrigin, BackendRequestError } from "~/lib/auth.server";
import { readRequestAuth } from "~/lib/auth-boundary.server";
import { isRecordPublicId } from "~/lib/record-id";
import { throwRouteError } from "~/lib/route-errors.server";

export const meta: Route.MetaFunction = ({ loaderData }) => [
  {
    title:
      loaderData?.record.visibility === "public"
        ? `${loaderData.record.payload.emoji ?? "Record"} · Fractonica`
        : "Private record · Fractonica",
  },
];

export async function loader({ context, params, request }: Route.LoaderArgs) {
  if (!isRecordPublicId(params.recordId)) {
    throw new Response("Record not found.", { status: 404, statusText: "Not Found" });
  }
  try {
    const boundary = readRequestAuth(context);
    const [record, dreamRequest] = await Promise.all([
      readOwnerRecord(boundary.auth, params.recordId, {
        signal: request.signal,
      }),
      readRecordDreamRequest(
        boundary.auth,
        params.recordId,
        request.signal,
      ),
    ]);
    return {
      record,
      dreamRequest,
    };
  } catch (error) {
    return throwRouteError(error, request, {
      clearInvalidAuth: true,
      notFoundMessage: "Record not found.",
    });
  }
}

export async function action({ context, params, request }: Route.ActionArgs) {
  assertSameOrigin(request);
  if (!isRecordPublicId(params.recordId)) {
    throw new Response("Record not found.", {
      status: 404,
      statusText: "Not Found",
    });
  }
  try {
    const dream = await scheduleRecordDream(
      readRequestAuth(context).auth,
      params.recordId,
    );
    return redirect(
      `/records/${encodeURIComponent(params.recordId)}?dream=${dream.status}`,
    );
  } catch (error) {
    if (error instanceof BackendRequestError) {
      return data({ error: error.message }, { status: error.status });
    }
    if (error instanceof Response) throw error;
    return data(
      {
        error:
          error instanceof Error ? error.message : "Could not schedule dream.",
      },
      { status: 400 },
    );
  }
}

export default function RecordDetail({ loaderData }: Route.ComponentProps) {
  const actionData = useActionData<typeof action>();
  return (
    <RecordDetailView
      backHref="/feed"
      canDream={loaderData.record.visibility === "public"}
      dreamError={actionData?.error}
      dreamRequest={loaderData.dreamRequest}
      record={loaderData.record}
    />
  );
}
