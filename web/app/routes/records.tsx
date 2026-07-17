import { data, Form, redirect, useActionData, useNavigation, useSearchParams } from "react-router";

import { GlyphRenderer } from "@exeligmos/ui";

import type { Route } from "./+types/records";
import { journalRecordPresentation } from "~/features/activity-feed/journal-presentation";
import { formatAbsoluteTimestamp } from "~/features/activity-feed/model";
import {
  ownerRecordCursor,
  readOwnerRecords,
  recordPageLimit,
} from "~/features/activity-stream/snapshots.server";
import {
  cleanupManagedMedia,
  createManagedRecord,
  deleteManagedRecord,
  listManagedDevices,
  listManagedTags,
  resolveManagedDevice,
  updateManagedRecord,
  uploadManagedMedia,
  ManagedMutationOutcomeUnknownError,
  type ManagedMedia,
  type ManagedTag,
} from "~/features/management/management.server";
import {
  WEB_ATTACHMENT_MAX_FILE_BYTES,
  WEB_ATTACHMENT_MAX_FILES,
  WEB_ATTACHMENT_MAX_TOTAL_BYTES,
} from "~/features/management/attachment-policy";
import {
  readBoundedFormData,
  RequestBodyTooLargeError,
} from "~/features/management/bounded-form-data.server";
import { recordTemporalContextAt } from "~/features/temporal/solar-engine.server";
import { assertSameOrigin, BackendRequestError } from "~/lib/auth.server";
import { readRequestAuth } from "~/lib/auth-boundary.server";
import { throwRouteError } from "~/lib/route-errors.server";

import styles from "./management.module.css";

export const meta: Route.MetaFunction = () => [{ title: "Records · Exeligmos" }];
const WEB_RECORD_FORM_MAX_BYTES = WEB_ATTACHMENT_MAX_TOTAL_BYTES + 1_024 * 1_024;

export async function loader({ context, request }: Route.LoaderArgs) {
  try {
    const auth = readRequestAuth(context).auth;
    const searchParams = new URL(request.url).searchParams;
    const cursor = searchParams.get("cursor") ?? undefined;
    const selectedDate = validUtcDate(searchParams.get("date"));
    const dateRange = selectedDate === undefined ? undefined : utcDateRange(selectedDate);
    const [records, tags, devices] = await Promise.all([
      readOwnerRecords(auth, {
        cursor: cursor === undefined ? undefined : ownerRecordCursor(cursor),
        limit: recordPageLimit(20),
        ...(dateRange === undefined
          ? {}
          : { occurredAfter: dateRange.start, occurredBefore: dateRange.end }),
        signal: request.signal,
      }),
      listManagedTags(auth, request.signal),
      listManagedDevices(auth, request.signal),
    ]);
    return {
      records,
      tags: tags.data,
      devices: devices.data.filter((device) => device.revokedAt == null),
      createOperationId: crypto.randomUUID(),
      createOccurredAt: new Date().toISOString(),
      selectedDate,
    };
  } catch (error) {
    return throwRouteError(error, request, { clearInvalidAuth: true });
  }
}

export async function action({ context, request }: Route.ActionArgs) {
  assertSameOrigin(request);
  const auth = readRequestAuth(context).auth;
  let form: FormData;
  try {
    form = await readBoundedFormData(request, WEB_RECORD_FORM_MAX_BYTES);
  } catch (error) {
    if (error instanceof RequestBodyTooLargeError) {
      return data(
        { error: "The record form exceeds the 128 MiB attachment limit." },
        { status: 413 },
      );
    }
    throw error;
  }
  const intent = requiredText(form, "intent");
  let submittedOperationId: string | undefined;
  try {
    if (intent === "create") {
      const operationId = requiredUuid(form, "operationId");
      submittedOperationId = operationId;
      const deviceId = await resolveManagedDevice(auth, optionalText(form, "deviceId"));
      const occurredAt = isoDate(form, "occurredAt");
      const endedAt = optionalIsoDate(form, "endedAt");
      const attachments = selectedAttachments(form);
      const completedMedia: ManagedMedia[] = [];
      try {
        for (const [position, attachment] of attachments.entries()) {
          completedMedia.push(
            await uploadManagedMedia(auth, deviceId, attachment, { operationId, position }),
          );
        }
        await createManagedRecord(
          auth,
          {
            originId: operationId,
            deviceId,
            visibility: "public",
            occurredAt,
            ...(endedAt === undefined ? {} : { endedAt }),
            payload: {
              text: optionalText(form, "text"),
              emoji: optionalText(form, "emoji"),
              context: recordTemporalContextAt(Date.parse(occurredAt) / 1_000),
            },
            tagIds: selectedTags(form),
            mediaIds: completedMedia.map((media) => media.id),
            metadata: {},
          },
          operationId,
        );
      } catch (error) {
        // If both idempotent create attempts lost their responses, the record
        // may already own these media objects. Preserve them and let an unchanged
        // retry replay/reconcile the original mutation.
        if (!(error instanceof ManagedMutationOutcomeUnknownError)) {
          await cleanupManagedMedia(auth, completedMedia);
        }
        throw error;
      }
    } else if (intent === "update") {
      const recordId = requiredText(form, "recordId");
      const occurredAt = isoDate(form, "occurredAt");
      await updateManagedRecord(auth, recordId, integer(form, "revision"), {
        deviceId: await resolveManagedDevice(auth, optionalText(form, "deviceId")),
        occurredAt,
        endedAt: optionalIsoDate(form, "endedAt"),
        text: optionalText(form, "text"),
        emoji: optionalText(form, "emoji"),
        tagIds: selectedTags(form),
        context: recordTemporalContextAt(Date.parse(occurredAt) / 1_000),
      });
    } else if (intent === "delete") {
      await deleteManagedRecord(auth, requiredText(form, "recordId"), integer(form, "revision"));
    } else {
      return data({ error: "Unknown record operation." }, { status: 400 });
    }
    return redirect(`/records?saved=${encodeURIComponent(intent)}`);
  } catch (error) {
    if (error instanceof BackendRequestError) {
      return data(
        {
          error: error.message,
          retryOperationId:
            submittedOperationId === undefined
              ? undefined
              : error instanceof ManagedMutationOutcomeUnknownError
                ? submittedOperationId
                : crypto.randomUUID(),
        },
        { status: error.status },
      );
    }
    if (error instanceof Response) throw error;
    return data(
      {
        error: error instanceof Error ? error.message : "Record operation failed.",
        retryOperationId: submittedOperationId === undefined ? undefined : crypto.randomUUID(),
      },
      { status: 400 },
    );
  }
}

export default function Records({ loaderData }: Route.ComponentProps) {
  const actionData = useActionData<typeof action>();
  const navigation = useNavigation();
  const [searchParams] = useSearchParams();
  const busy = navigation.state === "submitting";
  const retryOperationId =
    actionData !== undefined &&
    "retryOperationId" in actionData &&
    typeof actionData.retryOperationId === "string"
      ? actionData.retryOperationId
      : undefined;
  return (
    <main className={styles.page}>
      <header className={styles.header}>
        <div>
          <h1>Records</h1>
          <p>Create and maintain records with their canonical Saros context.</p>
        </div>
      </header>
      {searchParams.has("saved") ? <p className={styles.notice}>Record changes saved.</p> : null}
      {actionData?.error === undefined ? null : (
        <p className={styles.error} role="alert">
          {actionData.error}
        </p>
      )}
      <section className={`${styles.panel} ${styles.recordComposer}`}>
        <div className={styles.composerHeading}>
          <div>
            <h2>New public record</h2>
            <p>Its phase and four contextual spikes are derived from the start time.</p>
          </div>
        </div>
        <RecordForm
          busy={busy}
          defaultOccurredAt={loaderData.createOccurredAt}
          devices={loaderData.devices}
          intent="create"
          operationId={retryOperationId ?? loaderData.createOperationId}
          tags={loaderData.tags}
        />
      </section>
      <div className={styles.recordsToolbar}>
        <div>
          <h2>
            {loaderData.selectedDate === undefined ? "Recent records" : loaderData.selectedDate}
          </h2>
          <p>
            {loaderData.records.data.length} record
            {loaderData.records.data.length === 1 ? "" : "s"} on this page
          </p>
        </div>
        <Form className={styles.dateFilter} method="get">
          <label>
            UTC date
            <input defaultValue={loaderData.selectedDate} name="date" type="date" />
          </label>
          <button className={styles.compactButton} type="submit">
            Show date
          </button>
          {loaderData.selectedDate === undefined ? null : (
            <a className={styles.clearFilter} href="/records">
              Clear
            </a>
          )}
        </Form>
      </div>
      {loaderData.records.data.length === 0 ? (
        <p className={styles.empty}>
          {loaderData.selectedDate === undefined
            ? "No records on this page."
            : "No server-visible records occurred on this UTC date."}
        </p>
      ) : (
        <ul className={styles.recordList}>
          {loaderData.records.data.map((record) => {
            const presentation = journalRecordPresentation(record);
            const text =
              record.visibility === "public"
                ? typeof record.payload.text === "string"
                  ? record.payload.text
                  : ""
                : "Encrypted record";
            return (
              <li className={styles.recordItem} key={record.id}>
                <div className={styles.recordRow}>
                  <div className={styles.recordIdentity}>
                    <span aria-hidden="true" className={styles.recordEmoji}>
                      {presentation.emoji}
                    </span>
                    <div className={styles.recordCopy}>
                      <div className={styles.recordTitleLine}>
                        <h2>{presentation.temporalTitle}</h2>
                        {presentation.waveLabel === undefined ? null : (
                          <span>{presentation.waveLabel}</span>
                        )}
                      </div>
                      <p className={styles.recordExcerpt}>{text || "Untitled record"}</p>
                      <div className={styles.recordFacts}>
                        <time
                          dateTime={
                            record.visibility === "public" ? record.occurredAt : record.createdAt
                          }
                        >
                          {formatAbsoluteTimestamp(
                            record.visibility === "public" ? record.occurredAt : record.createdAt,
                          )}
                        </time>
                        {presentation.durationLabel === undefined ? null : (
                          <span>{presentation.durationLabel}</span>
                        )}
                        <span>{record.media.length} media</span>
                        {record.visibility === "public" ? (
                          <span>{record.tagIds.length} tags</span>
                        ) : null}
                        {record.visibility === "private" ? (
                          <span aria-label="Private">🔒</span>
                        ) : null}
                      </div>
                    </div>
                  </div>
                  <CompactSaros presentation={presentation} />
                  <a
                    aria-label={`Open ${presentation.temporalTitle}`}
                    className={styles.compactButton}
                    href={`/records/${encodeURIComponent(record.id)}`}
                  >
                    Open
                  </a>
                </div>
                <div className={styles.recordControls}>
                  {record.visibility === "public" ? (
                    <details className={styles.recordDetails}>
                      <summary>Edit record</summary>
                      <RecordForm
                        busy={busy}
                        devices={loaderData.devices}
                        intent="update"
                        record={record}
                        tags={loaderData.tags}
                      />
                    </details>
                  ) : (
                    <span className={styles.privateNote}>
                      Encrypted content requires its client key to edit.
                    </span>
                  )}
                  <details className={styles.recordDetails}>
                    <summary>Delete</summary>
                    <Form className={styles.deleteForm} method="post">
                      <input name="intent" type="hidden" value="delete" />
                      <input name="recordId" type="hidden" value={record.id} />
                      <input name="revision" type="hidden" value={record.revision} />
                      <span>Delete {record.id} permanently?</span>
                      <button className={styles.danger} disabled={busy} type="submit">
                        Confirm delete
                      </button>
                    </Form>
                  </details>
                  <span className={styles.recordId}>
                    {record.id} · r{record.revision}
                  </span>
                </div>
              </li>
            );
          })}
        </ul>
      )}
      {loaderData.records.hasMore && loaderData.records.nextCursor !== undefined ? (
        <a
          className={styles.button}
          href={recordPageHref(searchParams, loaderData.records.nextCursor)}
        >
          Older records →
        </a>
      ) : null}
    </main>
  );
}

function RecordForm({
  busy,
  defaultOccurredAt,
  devices,
  intent,
  operationId,
  record,
  tags,
}: {
  readonly busy: boolean;
  readonly defaultOccurredAt?: string;
  readonly devices: Route.ComponentProps["loaderData"]["devices"];
  readonly intent: "create" | "update";
  readonly operationId?: string;
  readonly record?: Extract<
    Route.ComponentProps["loaderData"]["records"]["data"][number],
    { visibility: "public" }
  >;
  readonly tags: readonly ManagedTag[];
}) {
  return (
    <Form
      className={`${styles.form} ${styles.recordForm}`}
      encType="multipart/form-data"
      method="post"
    >
      <input name="intent" type="hidden" value={intent} />
      {intent === "create" ? <input name="operationId" type="hidden" value={operationId} /> : null}
      {record === undefined ? null : (
        <>
          <input name="recordId" type="hidden" value={record.id} />
          <input name="revision" type="hidden" value={record.revision} />
        </>
      )}
      <label>
        Emoji
        <input
          className={styles.emojiInput}
          defaultValue={record?.payload.emoji}
          maxLength={32}
          name="emoji"
          placeholder="◉"
        />
      </label>
      <label>
        Device
        <select defaultValue={record?.deviceId ?? ""} name="deviceId">
          <option value="">
            {devices.length === 0 ? "Register web device automatically" : "Use first active device"}
          </option>
          {devices.map((device) => (
            <option key={device.id} value={device.id}>
              {device.name} · {device.kind}
            </option>
          ))}
        </select>
      </label>
      <label>
        Start date &amp; time (UTC)
        <input
          defaultValue={utcDateTimeInput(record?.occurredAt ?? defaultOccurredAt)}
          name="occurredAt"
          required
          step="1"
          type="datetime-local"
        />
      </label>
      <label>
        End date &amp; time (UTC)
        <input
          defaultValue={utcDateTimeInput(record?.endedAt)}
          name="endedAt"
          step="1"
          type="datetime-local"
        />
      </label>
      <label className={styles.wide}>
        Text
        <textarea
          defaultValue={record?.payload.text}
          maxLength={100000}
          name="text"
          placeholder="What happened?"
          rows={3}
        />
      </label>
      <p className={`${styles.wide} ${styles.temporalHint}`}>
        ◌ Saros phase, rarity, waveform state, and contextual spikes are recalculated from the
        selected start time when this record is saved.
      </p>
      {intent === "create" ? (
        <label className={styles.wide}>
          Images and files
          <input multiple name="attachments" type="file" />
          <small>
            Up to {WEB_ATTACHMENT_MAX_FILES} files, {WEB_ATTACHMENT_MAX_FILE_BYTES / 1_024 / 1_024}
            MiB per file, and 128 MiB total; display order is preserved.
          </small>
        </label>
      ) : null}
      <fieldset className={styles.fieldset}>
        <legend>Tags</legend>
        <div className={styles.tagChoices}>
          {tags.map((tag) => (
            <label className={styles.tagChoice} key={tag.id}>
              <input
                defaultChecked={record?.tagIds.includes(tag.id)}
                name="tagIds"
                type="checkbox"
                value={tag.id}
              />
              {tag.emoji} {tag.name}
            </label>
          ))}
        </div>
      </fieldset>
      <div className={styles.actions}>
        <button className={styles.button} disabled={busy} type="submit">
          {busy ? "Saving…" : intent === "create" ? "Create record" : "Save record"}
        </button>
      </div>
    </Form>
  );
}

function CompactSaros({
  presentation,
}: {
  readonly presentation: ReturnType<typeof journalRecordPresentation>;
}) {
  if (presentation.spikes.length === 0) {
    return <span className={styles.noSaros}>No Saros context</span>;
  }
  const closest = presentation.spikes.find((spike) => spike.isClosest);
  return (
    <div
      aria-label={closest === undefined ? "Saros context" : `Closest spike Saros ${closest.saros}`}
      className={styles.compactSaros}
    >
      {presentation.primaryGlyph === undefined ? null : (
        <span className={styles.phaseGlyph} title="Record phase">
          <GlyphRenderer decorative model={presentation.primaryGlyph} size={38} />
        </span>
      )}
      <ul aria-label="Contextual Saros spikes" className={styles.compactSpikes}>
        {presentation.spikes.map((spike) => (
          <li
            className={spike.isClosest ? styles.closestSpike : undefined}
            key={spike.id}
            title={`${spike.title} · Saros ${spike.saros}`}
          >
            <GlyphRenderer decorative model={spike.glyph} size={24} />
            <span>{spike.saros}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}

function text(form: FormData, name: string) {
  const value = form.get(name);
  return typeof value === "string" ? value : "";
}
function requiredText(form: FormData, name: string) {
  const value = text(form, name).trim();
  if (value === "") throw new Error(`${name} is required.`);
  return value;
}
function requiredUuid(form: FormData, name: string) {
  const value = requiredText(form, name);
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)) {
    throw new Error(`${name} must be a UUID.`);
  }
  return value;
}
function optionalText(form: FormData, name: string) {
  return text(form, name).trim() || undefined;
}
function integer(form: FormData, name: string) {
  const value = Number(text(form, name));
  if (!Number.isInteger(value)) throw new Error(`${name} must be an integer.`);
  return value;
}
function isoDate(form: FormData, name: string) {
  const value = requiredText(form, name);
  const date = new Date(ensureUtcDesignator(value));
  if (!Number.isFinite(date.getTime())) throw new Error(`${name} must be a valid ISO 8601 date.`);
  return date.toISOString();
}
function optionalIsoDate(form: FormData, name: string) {
  const value = optionalText(form, name);
  if (value === undefined) return undefined;
  const date = new Date(ensureUtcDesignator(value));
  if (!Number.isFinite(date.getTime())) throw new Error(`${name} must be a valid ISO 8601 date.`);
  return date.toISOString();
}

function ensureUtcDesignator(value: string): string {
  return /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d{1,3})?)?$/.test(value)
    ? `${value}Z`
    : value;
}

function utcDateTimeInput(value: string | undefined): string | undefined {
  if (value === undefined) return undefined;
  const date = new Date(value);
  return Number.isFinite(date.getTime()) ? date.toISOString().slice(0, 19) : undefined;
}

function validUtcDate(value: string | null): string | undefined {
  if (value === null || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return undefined;
  const instant = new Date(`${value}T00:00:00.000Z`);
  return Number.isFinite(instant.getTime()) && instant.toISOString().startsWith(value)
    ? value
    : undefined;
}

function utcDateRange(value: string) {
  const start = new Date(`${value}T00:00:00.000Z`);
  const end = new Date(start.getTime() + 86_400_000);
  return { start: start.toISOString(), end: end.toISOString() } as const;
}

function recordPageHref(searchParams: URLSearchParams, cursor: string): string {
  const next = new URLSearchParams(searchParams);
  next.delete("saved");
  next.set("cursor", cursor);
  return `/records?${next.toString()}`;
}
function selectedTags(form: FormData) {
  return form.getAll("tagIds").filter((value): value is string => typeof value === "string");
}

function selectedAttachments(form: FormData): File[] {
  const files = form
    .getAll("attachments")
    .filter((value): value is File => value instanceof File && value.name !== "");
  if (files.length > WEB_ATTACHMENT_MAX_FILES) {
    throw new RangeError(`A record can contain at most ${WEB_ATTACHMENT_MAX_FILES} new files.`);
  }
  const total = files.reduce((sum, file) => sum + file.size, 0);
  if (total > WEB_ATTACHMENT_MAX_TOTAL_BYTES) {
    throw new RangeError("Attachments may use at most 128 MiB per record.");
  }
  const empty = files.find((file) => file.size === 0);
  if (empty !== undefined) {
    throw new RangeError(`${empty.name} is empty and cannot be attached.`);
  }
  return files;
}
