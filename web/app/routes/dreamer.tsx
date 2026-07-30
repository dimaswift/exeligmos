import { useEffect, useState } from "react";
import {
  data,
  Form,
  Link,
  redirect,
  useActionData,
  useNavigation,
  useSearchParams,
} from "react-router";

import { upcomingSarosRollovers } from "@fractonica/temporal-core";

import type { Route } from "./+types/dreamer";
import {
  ownerRecordCursor,
  readOwnerRecords,
  recordPageLimit,
  type OwnerRecord,
} from "~/features/activity-stream/snapshots.server";
import { activeSarosIntervals } from "~/features/temporal/solar-engine.server";
import { readWorkers, updateWorker } from "~/features/workers/workers.server";
import { assertSameOrigin, BackendRequestError } from "~/lib/auth.server";
import { readRequestAuth } from "~/lib/auth-boundary.server";
import { throwRouteError } from "~/lib/route-errors.server";

import styles from "./dreamer.module.css";

export const meta: Route.MetaFunction = () => [
  { title: "Dreamer · Fractonica" },
];

export async function loader({ context, request }: Route.LoaderArgs) {
  try {
    const auth = readRequestAuth(context).auth;
    const observedAt = Date.now() / 1_000;
    const [workers, dreams] = await Promise.all([
      readWorkers(auth, request.signal),
      readAllDreams(auth, request.signal),
    ]);
    return {
      dreamer: workers.find((worker) => worker.type === "dreamer") ?? null,
      dreams,
      observedAt,
      rollovers: upcomingSarosRollovers(
        activeSarosIntervals(observedAt),
        observedAt,
      ),
    };
  } catch (error) {
    return throwRouteError(error, request, { clearInvalidAuth: true });
  }
}

export async function action({ context, request }: Route.ActionArgs) {
  assertSameOrigin(request);
  const form = await request.formData();
  try {
    await updateWorker(
      readRequestAuth(context).auth,
      required(form, "deviceId"),
      Number(required(form, "revision")),
      {
        enabled: form.get("enabled") === "on",
        imagePromptReference: required(form, "imagePromptReference"),
      },
    );
    return redirect("/dreamer?saved=1");
  } catch (error) {
    if (error instanceof BackendRequestError) {
      return data({ error: error.message }, { status: error.status });
    }
    if (error instanceof Response) throw error;
    return data(
      {
        error:
          error instanceof Error ? error.message : "Dreamer update failed.",
      },
      { status: 400 },
    );
  }
}

export default function Dreamer({ loaderData }: Route.ComponentProps) {
  const { dreamer, dreams, rollovers } = loaderData;
  const actionData = useActionData<typeof action>();
  const navigation = useNavigation();
  const [search] = useSearchParams();
  const next = rollovers[0];
  const runtime = dreamer?.runtime;
  const creating = dreamer?.config.enabled === true && runtime?.state === "creating";
  const nextAt =
    runtime?.nextRolloverAt ??
    (next === undefined
      ? null
      : new Date(next.epochSeconds * 1_000).toISOString());

  return (
    <main className={styles.page}>
      <header className={styles.hero}>
        <div>
          <p className="eyebrow">Scheduled imagination</p>
          <h1>Dreamer</h1>
          <p>
            One future dream at each native Tera rollover, sourced from the
            oldest untouched record carrying that Saros spike.
          </p>
        </div>
        <div className={styles.status}>
          <span className={creating ? styles.live : styles.statusIcon}>
            {creating ? "◉" : "💭"}
          </span>
          <strong>
            {dreamer === null
              ? "Not installed"
              : !dreamer.config.enabled
                ? "Dreamer is off"
                : creating
                  ? "A dream is being created now"
                  : "Next dream"}
          </strong>
          {creating ? (
            <span>
              Saros {runtime?.saros ?? next?.saros}
              {runtime?.sourceRecordId === null ||
              runtime?.sourceRecordId === undefined ? null : (
                <>
                  {" · "}
                  <Link to={`/r/${runtime.sourceRecordId}`}>
                    source {runtime.sourceRecordId}
                  </Link>
                </>
              )}
            </span>
          ) : nextAt === null ? (
            <span>No active rollover is available.</span>
          ) : (
            <>
              <time dateTime={nextAt}>{formatDate(nextAt)}</time>
              <Countdown target={nextAt} />
            </>
          )}
          {runtime?.state === "error" && runtime.message !== null ? (
            <span className={styles.runtimeError}>{runtime.message}</span>
          ) : null}
        </div>
      </header>

      {search.has("saved") ? (
        <p className={styles.notice}>Dreamer settings saved.</p>
      ) : null}
      {actionData?.error === undefined ? null : (
        <p className={styles.error} role="alert">
          {actionData.error}
        </p>
      )}

      {dreamer === null ? (
        <section className={styles.panel}>
          <h2>Dreamer is not registered</h2>
          <p>Run the Dreamer configure script, then return to this page.</p>
        </section>
      ) : (
        <section className={styles.panel}>
          <div className={styles.panelHeading}>
            <div>
              <h2>Creative direction</h2>
              <p>
                This example is injected as a structural and stylistic reference
                when the language agent writes the scene prompt.
              </p>
            </div>
            <span
              className={
                dreamer.config.enabled ? styles.enabled : styles.disabled
              }
            >
              {dreamer.config.enabled ? "ON" : "OFF"}
            </span>
          </div>
          <Form className={styles.form} method="post">
            <input name="deviceId" type="hidden" value={dreamer.deviceId} />
            <input name="revision" type="hidden" value={dreamer.revision} />
            <label className={styles.toggle}>
              <input
                defaultChecked={dreamer.config.enabled}
                name="enabled"
                type="checkbox"
              />
              Create dreams at scheduled Tera rollovers
            </label>
            <label>
              Image prompt reference
              <textarea
                defaultValue={dreamer.config.imagePromptReference}
                maxLength={4000}
                name="imagePromptReference"
                required
                rows={4}
              />
            </label>
            <button
              className={styles.primary}
              disabled={navigation.state === "submitting"}
              type="submit"
            >
              {navigation.state === "submitting"
                ? "Saving…"
                : "Save Dreamer"}
            </button>
          </Form>
        </section>
      )}

      <section className={styles.panel}>
        <div className={styles.panelHeading}>
          <div>
            <h2>Upcoming Tera sequence</h2>
            <p>
              One next <code>000000</code> rollover for every currently active
              Saros series.
            </p>
          </div>
          <span className={styles.count}>{rollovers.length} rollovers</span>
        </div>
        <ol className={styles.schedule}>
          {rollovers.map((rollover, index) => {
            const at = new Date(rollover.epochSeconds * 1_000).toISOString();
            return (
              <li key={rollover.id}>
                <span className={styles.ordinal}>
                  {String(index + 1).padStart(2, "0")}
                </span>
                <strong>Saros {rollover.saros}</strong>
                <code>{rollover.octalAddress}</code>
                <time dateTime={at}>{formatDate(at)}</time>
                <Countdown compact target={at} />
              </li>
            );
          })}
        </ol>
      </section>

      <section className={styles.panel}>
        <div className={styles.panelHeading}>
          <div>
            <h2>Dream records</h2>
            <p>Every future record generated by this worker.</p>
          </div>
          <span className={styles.count}>{dreams.length} dreams</span>
        </div>
        {dreams.length === 0 ? (
          <p className={styles.empty}>No dreams have been created yet.</p>
        ) : (
          <div className={styles.dreams}>
            {dreams.map((record) => {
              const payload = "payload" in record ? record.payload : undefined;
              const occurredAt =
                "occurredAt" in record ? record.occurredAt : record.createdAt;
              return (
                <article key={record.id}>
                  <span className={styles.emoji}>
                    {payload?.emoji ?? "💭"}
                  </span>
                  <div>
                    <div className={styles.dreamMeta}>
                      <time dateTime={occurredAt}>
                        {formatDate(occurredAt)}
                      </time>
                      <code>{record.id}</code>
                    </div>
                    <p>{payload?.text ?? "An untitled dream."}</p>
                    <Link to={`/r/${record.id}`}>Open dream →</Link>
                  </div>
                </article>
              );
            })}
          </div>
        )}
      </section>
    </main>
  );
}

function Countdown({
  compact = false,
  target,
}: {
  readonly compact?: boolean;
  readonly target: string;
}) {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const timer = window.setInterval(() => setNow(Date.now()), 1_000);
    return () => window.clearInterval(timer);
  }, []);
  const remaining = Math.max(0, Date.parse(target) - now);
  return (
    <span className={compact ? styles.compactCountdown : styles.countdown}>
      {formatDuration(remaining)}
    </span>
  );
}

async function readAllDreams(
  auth: Parameters<typeof readOwnerRecords>[0],
  signal: AbortSignal,
): Promise<readonly OwnerRecord[]> {
  const records: OwnerRecord[] = [];
  let cursor: string | undefined;
  do {
    const page = await readOwnerRecords(auth, {
      sourceProvider: "dreamer",
      limit: recordPageLimit(25),
      ...(cursor === undefined
        ? {}
        : { cursor: ownerRecordCursor(cursor) }),
      signal,
    });
    records.push(...page.data);
    cursor = page.hasMore ? page.nextCursor : undefined;
  } while (cursor !== undefined);
  return records;
}

function required(form: FormData, key: string): string {
  const value = form.get(key);
  if (typeof value !== "string" || value.trim() === "") {
    throw new Error(`${key} is required.`);
  }
  return value.trim();
}

function formatDate(value: string): string {
  return new Intl.DateTimeFormat(undefined, {
    dateStyle: "medium",
    timeStyle: "medium",
  }).format(new Date(value));
}

function formatDuration(milliseconds: number): string {
  const totalSeconds = Math.ceil(milliseconds / 1_000);
  const days = Math.floor(totalSeconds / 86_400);
  const hours = Math.floor((totalSeconds % 86_400) / 3_600);
  const minutes = Math.floor((totalSeconds % 3_600) / 60);
  const seconds = totalSeconds % 60;
  return [
    ...(days === 0 ? [] : [`${days}d`]),
    `${String(hours).padStart(2, "0")}h`,
    `${String(minutes).padStart(2, "0")}m`,
    `${String(seconds).padStart(2, "0")}s`,
  ].join(" ");
}
