import { GlyphRenderer } from "@fractonica/ui";
import type { ApiSchemas } from "@fractonica/api-client";
import { Form } from "react-router";

import { SarosPulseGlyphPair } from "~/components/saros-pulse-glyph-pair";
import {
  sarosPulseAnchorValue,
  useSarosPulseTickAt,
} from "~/features/temporal/saros-pulse-context";
import { LocalTimestamp, RecordMediaGrid } from "../activity-feed/activity-feed";
import type { ActivityRecord } from "../activity-feed/model";
import { journalRecordPresentation } from "../activity-feed/journal-presentation";

import styles from "./record-detail.module.css";

type DreamRequest = ApiSchemas["DreamRequest"];

export function RecordDetailView({
  record,
  backHref,
  canDream = false,
  dreamError,
  dreamRequest,
}: {
  readonly record: ActivityRecord;
  readonly backHref: string;
  readonly canDream?: boolean;
  readonly dreamError?: string;
  readonly dreamRequest?: DreamRequest | null;
}) {
  const presentation = journalRecordPresentation(record);
  const isPrivate = record.visibility === "private";
  const actor = isPrivate ? undefined : record.author;
  const timestamp = isPrivate ? record.createdAt : record.occurredAt;
  const pulseAnchor =
    actor === undefined ? undefined : sarosPulseAnchorValue(Reflect.get(actor, "sarosAnchor"));
  const pulse = useSarosPulseTickAt(Date.parse(timestamp) / 1_000, pulseAnchor);

  return (
    <main className={styles.page}>
      <a className={styles.back} href={backHref}>
        ← Back to records
      </a>

      <article className={styles.record}>
        <header className={styles.hero}>
          <span aria-hidden="true" className={styles.emoji}>
            {presentation.emoji}
          </span>
          <div className={styles.identity}>
            <h1>{presentation.temporalTitle}</h1>
            {presentation.waveLabel === undefined ? null : <p>{presentation.waveLabel}</p>}
            {presentation.durationLabel === undefined ? null : (
              <span className={styles.duration}>{presentation.durationLabel}</span>
            )}
          </div>
          {pulse !== undefined ? (
            <SarosPulseGlyphPair className={styles.heroPulse} reading={pulse} size="3rem" />
          ) : presentation.primaryGlyph === undefined ? null : (
            <GlyphRenderer
              className={styles.heroGlyph}
              model={presentation.primaryGlyph}
              size={96}
            />
          )}
        </header>

        {presentation.spikes.length === 0 ? null : (
          <section aria-labelledby="saros-context" className={styles.sarosSection}>
            <h2 id="saros-context">Saros context</h2>
            <ul>
              {presentation.spikes.map((spike) => (
                <li className={spike.isClosest ? styles.closest : undefined} key={spike.id}>
                  <GlyphRenderer model={spike.glyph} size={54} />
                  <strong>{spike.saros}</strong>
                  <span>{spike.title}</span>
                </li>
              ))}
            </ul>
          </section>
        )}

        {isPrivate ? (
          <p className={styles.encrypted}>
            ◇ This record is encrypted and cannot be rendered here.
          </p>
        ) : (
          <>
            {presentation.text === "" ? null : <p className={styles.text}>{presentation.text}</p>}
            {record.media.length === 0 ? null : (
              <section aria-labelledby="record-media" className={styles.media}>
                <h2 id="record-media">Media</h2>
                <RecordMediaGrid media={record.media} />
              </section>
            )}
            {record.tags.length === 0 ? null : (
              <ul aria-label="Tags" className={styles.tags}>
                {record.tags.map((tag) => (
                  <li key={tag.id}>
                    {tag.emoji} {tag.name}
                  </li>
                ))}
              </ul>
            )}
            {record.references.length === 0 ? null : (
              <section aria-labelledby="record-references" className={styles.references}>
                <h2 id="record-references">References</h2>
                <ul>
                  {record.references.map((reference) => {
                    const href =
                      reference.targetType === "record"
                        ? `/r/${encodeURIComponent(reference.targetId)}`
                        : `/references/${reference.targetType}/${encodeURIComponent(reference.targetId)}`;
                    return (
                      <li
                        key={`${reference.relation}:${reference.targetType}:${reference.targetId}`}
                      >
                        <a href={href}>
                          <span>{reference.relation}</span>
                          <strong>{reference.targetId}</strong>
                        </a>
                      </li>
                    );
                  })}
                </ul>
              </section>
            )}
          </>
        )}

        {!canDream ? null : (
          <section aria-label="Dream this record" className={styles.dream}>
            <div>
              <strong>{dreamStatusTitle(dreamRequest)}</strong>
              <span>{dreamStatusDetail(dreamRequest)}</span>
              {dreamError === undefined ? null : (
                <span className={styles.dreamError} role="alert">
                  {dreamError}
                </span>
              )}
            </div>
            {dreamRequest?.status === "completed" &&
            dreamRequest.dreamRecordId !== null ? (
              <a href={`/r/${encodeURIComponent(dreamRequest.dreamRecordId)}`}>
                Open dream →
              </a>
            ) : (
              <Form method="post">
                <button
                  disabled={
                    dreamRequest?.status === "queued" ||
                    dreamRequest?.status === "processing"
                  }
                  type="submit"
                >
                  {dreamRequest?.status === "processing"
                    ? "Dreaming…"
                    : dreamRequest?.status === "queued"
                      ? "Dream queued"
                      : "Dream"}
                </button>
              </Form>
            )}
          </section>
        )}

        <footer className={styles.footer}>
          <LocalTimestamp value={timestamp} />
          {actor === undefined ? null : <span>{actor.displayName}</span>}
        </footer>
      </article>
    </main>
  );
}

function dreamStatusTitle(request: DreamRequest | null | undefined): string {
  switch (request?.status) {
    case "queued":
      return "Waiting for Dreamer";
    case "processing":
      return "Dreaming this record";
    case "completed":
      return "Dream created";
    case "failed":
      return "The dream faded";
    default:
      return "Send into the future";
  }
}

function dreamStatusDetail(request: DreamRequest | null | undefined): string {
  switch (request?.status) {
    case "queued":
      return "This record is in the on-demand queue.";
    case "processing":
      return "The Dreamer worker is interpreting it now.";
    case "completed":
      return "Its future echo is ready.";
    case "failed":
      return request.error ?? "You can ask Dreamer to try again.";
    default:
      return "Create a future dream derived from this exact record.";
  }
}
