import { data, Form, redirect, useActionData, useNavigation, useSearchParams } from "react-router";

import type { Route } from "./+types/workers";
import {
  readWorkers,
  updateWorker,
} from "~/features/workers/workers.server";
import { assertSameOrigin, BackendRequestError } from "~/lib/auth.server";
import { readRequestAuth } from "~/lib/auth-boundary.server";
import { throwRouteError } from "~/lib/route-errors.server";

import styles from "./workers.module.css";

export const meta: Route.MetaFunction = () => [{ title: "Workers · Fractonica" }];

export async function loader({ context, request }: Route.LoaderArgs) {
  try {
    return {
      workers: await readWorkers(readRequestAuth(context).auth, request.signal),
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
        mountName: required(form, "mountName"),
        descriptionModel: required(form, "descriptionModel"),
        descriptionPrompt: required(form, "descriptionPrompt"),
        embeddingModel: required(form, "embeddingModel"),
        whisperModel: required(form, "whisperModel"),
      },
    );
    return redirect("/workers?saved=1");
  } catch (error) {
    if (error instanceof BackendRequestError) {
      return data({ error: error.message }, { status: error.status });
    }
    if (error instanceof Response) throw error;
    return data(
      { error: error instanceof Error ? error.message : "Worker update failed." },
      { status: 400 },
    );
  }
}

export default function Workers({ loaderData }: Route.ComponentProps) {
  const actionData = useActionData<typeof action>();
  const navigation = useNavigation();
  const [search] = useSearchParams();
  const busy = navigation.state === "submitting";
  return (
    <main className={styles.page}>
      <header className={styles.header}>
        <div>
          <p className="eyebrow">Automation</p>
          <h1>Workers</h1>
          <p>Registered capture devices, live settings, and lifetime output.</p>
        </div>
      </header>
      {search.has("saved") ? <p className={styles.notice}>Worker settings saved.</p> : null}
      {actionData?.error === undefined ? null : (
        <p className={styles.error} role="alert">{actionData.error}</p>
      )}
      {loaderData.workers.length === 0 ? (
        <section className={styles.empty}>
          <h2>No registered workers</h2>
          <p>Run <code>npm run configure</code> in the THUMB_CAM worker folder.</p>
        </section>
      ) : (
        <div className={styles.grid}>
          {loaderData.workers.map((worker) => (
            <article className={styles.card} key={worker.deviceId}>
              <header className={styles.cardHeader}>
                <span className={styles.icon}>📷</span>
                <div>
                  <h2>{worker.name}</h2>
                  <p>{worker.config.mountName} · {worker.config.enabled ? "enabled" : "disabled"}</p>
                </div>
                <span className={worker.config.enabled ? styles.enabled : styles.disabled}>
                  {worker.config.enabled ? "ON" : "OFF"}
                </span>
              </header>
              <dl className={styles.stats}>
                <Stat label="Records" value={worker.stats.records} />
                <Stat label="Media" value={worker.stats.media} />
                <Stat label="Jobs" value={worker.stats.jobs} />
                <Stat label="Failed" value={worker.stats.failedMedia} />
              </dl>
              <p className={styles.lastSeen}>
                Last seen: {worker.lastSeenAt === null ? "never" : formatDate(worker.lastSeenAt)}
              </p>
              <details className={styles.editor}>
                <summary>Edit worker</summary>
                <Form className={styles.form} method="post">
                  <input name="deviceId" type="hidden" value={worker.deviceId} />
                  <input name="revision" type="hidden" value={worker.revision} />
                  <label className={styles.toggle}>
                    <input defaultChecked={worker.config.enabled} name="enabled" type="checkbox" />
                    Process media when the volume is mounted
                  </label>
                  <label>
                    Volume name
                    <input defaultValue={worker.config.mountName} maxLength={80} name="mountName" required />
                  </label>
                  <div className={styles.fields}>
                    <label>
                      Description model
                      <input defaultValue={worker.config.descriptionModel} name="descriptionModel" required />
                    </label>
                    <label>
                      Embedding model
                      <input defaultValue={worker.config.embeddingModel} name="embeddingModel" required />
                    </label>
                    <label>
                      Whisper model
                      <input defaultValue={worker.config.whisperModel} name="whisperModel" required />
                    </label>
                  </div>
                  <label>
                    Description prompt
                    <textarea defaultValue={worker.config.descriptionPrompt} maxLength={4000} name="descriptionPrompt" required rows={4} />
                  </label>
                  <button disabled={busy} type="submit">{busy ? "Saving…" : "Save settings"}</button>
                </Form>
              </details>
            </article>
          ))}
        </div>
      )}
    </main>
  );
}

function Stat({ label, value }: { readonly label: string; readonly value: number }) {
  return <div><dt>{label}</dt><dd>{value.toLocaleString()}</dd></div>;
}

function required(form: FormData, name: string): string {
  const value = form.get(name);
  if (typeof value !== "string" || value.trim() === "") {
    throw new Error(`${name} is required.`);
  }
  return value.trim();
}

function formatDate(value: string): string {
  return new Intl.DateTimeFormat(undefined, {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(new Date(value));
}
