import { GlyphRenderer } from "@exeligmos/ui";

import { SarosPulseGlyphPair } from "~/components/saros-pulse-glyph-pair";
import {
  sarosPulseAnchorValue,
  useSarosPulseTickAt,
} from "~/features/temporal/saros-pulse-context";
import { LocalTimestamp, RecordMediaGrid } from "../activity-feed/activity-feed";
import type { ActivityRecord } from "../activity-feed/model";
import { journalRecordPresentation } from "../activity-feed/journal-presentation";

import styles from "./record-detail.module.css";

export function RecordDetailView({
  record,
  backHref,
}: {
  readonly record: ActivityRecord;
  readonly backHref: string;
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
          </>
        )}

        <footer className={styles.footer}>
          <LocalTimestamp value={timestamp} />
          {actor === undefined ? null : <span>{actor.displayName}</span>}
        </footer>
      </article>
    </main>
  );
}
