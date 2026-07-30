import { data, Form, redirect, useActionData, useNavigation, useSearchParams } from "react-router";

import type { Route } from "./+types/workers";
import { readWorkers, updateWorker } from "~/features/workers/workers.server";
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
        pollIntervalMs: positiveNumber(form, "pollIntervalMs"),
        descriptionProvider: provider(form, "descriptionProvider"),
        descriptionBaseUrl: required(form, "descriptionBaseUrl"),
        descriptionModel: required(form, "descriptionModel"),
        descriptionPrompt: required(form, "descriptionPrompt"),
        embeddingProvider: provider(form, "embeddingProvider"),
        embeddingBaseUrl: required(form, "embeddingBaseUrl"),
        embeddingModel: required(form, "embeddingModel"),
        whisperModel: required(form, "whisperModel"),
        imageGenerationEnabled: form.get("imageGenerationEnabled") === "on",
        imageProvider: "mlx-studio",
        imageBaseUrl: required(form, "imageBaseUrl"),
        imageModel: required(form, "imageModel"),
        imageSize: required(form, "imageSize"),
        imageSteps: positiveNumber(form, "imageSteps"),
        imageGuidance: nonNegativeNumber(form, "imageGuidance"),
        imageTimeoutMs: positiveNumber(form, "imageTimeoutMs"),
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
        <p className={styles.error} role="alert">
          {actionData.error}
        </p>
      )}
      {loaderData.workers.length === 0 ? (
        <section className={styles.empty}>
          <h2>No registered workers</h2>
          <p>
            Run <code>npm run configure</code> in the THUMB_CAM worker folder.
          </p>
        </section>
      ) : (
        <div className={styles.grid}>
          {loaderData.workers.map((worker) => (
            <article className={styles.card} key={worker.deviceId}>
              <header className={styles.cardHeader}>
                <span className={styles.icon}>{worker.type === "dreamer" ? "💭" : "📷"}</span>
                <div>
                  <h2>{worker.name}</h2>
                  <p>
                    {worker.type === "dreamer" ? "Dream synthesis" : worker.config.mountName}
                    {" · "}
                    {worker.config.enabled ? "enabled" : "disabled"}
                  </p>
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
                    {worker.type === "dreamer"
                      ? "Create future dream records"
                      : "Process media when the volume is mounted"}
                  </label>
                  {worker.type === "thumb-cam" ? (
                    <label>
                      Volume name
                      <input
                        defaultValue={worker.config.mountName}
                        maxLength={80}
                        name="mountName"
                        required
                      />
                    </label>
                  ) : (
                    <input name="mountName" type="hidden" value={worker.config.mountName} />
                  )}
                  <div className={styles.fields}>
                    <label>
                      Poll interval (ms)
                      <input
                        defaultValue={worker.config.pollIntervalMs}
                        min={100}
                        name="pollIntervalMs"
                        required
                        type="number"
                      />
                    </label>
                    <label>
                      Description provider
                      <select
                        defaultValue={worker.config.descriptionProvider}
                        name="descriptionProvider"
                      >
                        <option value="ollama">Ollama</option>
                        <option value="speshu">SpeShu</option>
                      </select>
                    </label>
                    <label>
                      Description model
                      <input
                        defaultValue={worker.config.descriptionModel}
                        name="descriptionModel"
                        required
                      />
                    </label>
                    <label>
                      Description API URL
                      <input
                        defaultValue={worker.config.descriptionBaseUrl}
                        name="descriptionBaseUrl"
                        required
                        type="url"
                      />
                    </label>
                    <label>
                      Embedding provider
                      <select
                        defaultValue={worker.config.embeddingProvider}
                        name="embeddingProvider"
                      >
                        <option value="ollama">Ollama</option>
                        <option disabled value="speshu">
                          SpeShu (no embeddings API)
                        </option>
                      </select>
                    </label>
                    <label>
                      Embedding model
                      <input
                        defaultValue={worker.config.embeddingModel}
                        name="embeddingModel"
                        required
                      />
                    </label>
                    <label>
                      Embedding API URL
                      <input
                        defaultValue={worker.config.embeddingBaseUrl}
                        name="embeddingBaseUrl"
                        required
                        type="url"
                      />
                    </label>
                    {worker.type === "thumb-cam" ? (
                      <label>
                        MLX Whisper model
                        <input
                          defaultValue={worker.config.whisperModel}
                          name="whisperModel"
                          required
                        />
                      </label>
                    ) : (
                      <input name="whisperModel" type="hidden" value={worker.config.whisperModel} />
                    )}
                    <label>
                      Image model
                      <input defaultValue={worker.config.imageModel} name="imageModel" required />
                    </label>
                    <label>
                      MLX Studio URL
                      <input
                        defaultValue={worker.config.imageBaseUrl}
                        name="imageBaseUrl"
                        required
                        type="url"
                      />
                    </label>
                    <label>
                      Image size
                      <input
                        defaultValue={worker.config.imageSize}
                        name="imageSize"
                        pattern="[1-9][0-9]{1,4}x[1-9][0-9]{1,4}"
                        required
                      />
                    </label>
                    <label>
                      Steps
                      <input
                        defaultValue={worker.config.imageSteps}
                        min={1}
                        name="imageSteps"
                        required
                        type="number"
                      />
                    </label>
                    <label>
                      Guidance
                      <input
                        defaultValue={worker.config.imageGuidance}
                        min={0}
                        name="imageGuidance"
                        required
                        step="any"
                        type="number"
                      />
                    </label>
                    <label>
                      Image timeout (ms)
                      <input
                        defaultValue={worker.config.imageTimeoutMs}
                        min={1}
                        name="imageTimeoutMs"
                        required
                        type="number"
                      />
                    </label>
                  </div>
                  <label className={styles.toggle}>
                    <input
                      defaultChecked={worker.config.imageGenerationEnabled}
                      name="imageGenerationEnabled"
                      type="checkbox"
                    />
                    Generate and attach an MLX Studio image
                  </label>
                  <label>
                    Description prompt
                    <textarea
                      defaultValue={worker.config.descriptionPrompt}
                      maxLength={4000}
                      name="descriptionPrompt"
                      required
                      rows={4}
                    />
                  </label>
                  <button disabled={busy} type="submit">
                    {busy ? "Saving…" : "Save settings"}
                  </button>
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
  return (
    <div>
      <dt>{label}</dt>
      <dd>{value.toLocaleString()}</dd>
    </div>
  );
}

function provider(form: FormData, name: string): "ollama" | "speshu" {
  const value = required(form, name);
  if (value !== "ollama" && value !== "speshu") {
    throw new Error(`${name} must be ollama or speshu.`);
  }
  return value;
}

function required(form: FormData, name: string): string {
  const value = form.get(name);
  if (typeof value !== "string" || value.trim() === "") {
    throw new Error(`${name} is required.`);
  }
  return value.trim();
}

function positiveNumber(form: FormData, name: string): number {
  const value = Number(required(form, name));
  if (!Number.isFinite(value) || value <= 0) {
    throw new Error(`${name} must be positive.`);
  }
  return value;
}

function nonNegativeNumber(form: FormData, name: string): number {
  const value = Number(required(form, name));
  if (!Number.isFinite(value) || value < 0) {
    throw new Error(`${name} must not be negative.`);
  }
  return value;
}

function formatDate(value: string): string {
  return new Intl.DateTimeFormat(undefined, {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(new Date(value));
}
