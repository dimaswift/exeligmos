import { GlyphRenderer } from "@exeligmos/ui";

import { formatAbsoluteTimestamp, type ActivityRecord } from "../activity-feed/model";
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
  const images = record.media.filter((item) => item.contentType.startsWith("image/"));
  const videos = record.media.filter((item) => item.contentType.startsWith("video/"));
  const audio = record.media.filter((item) => item.contentType.startsWith("audio/"));
  const documents = record.media.filter(
    (item) =>
      !item.contentType.startsWith("image/") &&
      !item.contentType.startsWith("video/") &&
      !item.contentType.startsWith("audio/"),
  );
  const timestamp = isPrivate ? record.createdAt : record.occurredAt;

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
            <p className="eyebrow">
              {actor === undefined ? "Encrypted record" : `@${actor.login}`}
            </p>
            <h1>{presentation.temporalTitle}</h1>
            {presentation.waveLabel === undefined ? null : <p>{presentation.waveLabel}</p>}
            {presentation.durationLabel === undefined ? null : (
              <span className={styles.duration}>{presentation.durationLabel}</span>
            )}
          </div>
          {presentation.primaryGlyph === undefined ? null : (
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
            <MediaGallery images={images} videos={videos} audio={audio} documents={documents} />
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
          <time dateTime={timestamp}>{formatAbsoluteTimestamp(timestamp)}</time>
          {actor === undefined ? null : <span>{actor.displayName}</span>}
        </footer>
      </article>
    </main>
  );
}

function MediaGallery({
  images,
  videos,
  audio,
  documents,
}: {
  readonly images: readonly ActivityRecord["media"][number][];
  readonly videos: readonly ActivityRecord["media"][number][];
  readonly audio: readonly ActivityRecord["media"][number][];
  readonly documents: readonly ActivityRecord["media"][number][];
}) {
  if (images.length + videos.length + audio.length + documents.length === 0) return null;
  return (
    <section aria-labelledby="record-media" className={styles.media}>
      <h2 id="record-media">Media</h2>
      {images.length === 0 ? null : (
        <div aria-label="Images" className={styles.imageRail}>
          {images.map((item) => (
            <a href={mediaUrl(item.id)} key={item.id} target="_blank">
              <img alt={item.fileName} decoding="async" loading="lazy" src={mediaUrl(item.id)} />
            </a>
          ))}
        </div>
      )}
      {videos.map((item) => (
        <figure className={styles.player} key={item.id}>
          <video controls playsInline preload="metadata" src={mediaUrl(item.id)} />
          <figcaption>{item.fileName}</figcaption>
        </figure>
      ))}
      {audio.map((item) => (
        <figure className={styles.audioPlayer} key={item.id}>
          <figcaption>{item.fileName}</figcaption>
          <audio controls preload="metadata" src={mediaUrl(item.id)} />
        </figure>
      ))}
      {documents.map((item) => (
        <a className={styles.document} href={mediaUrl(item.id)} key={item.id}>
          Open {item.fileName}
        </a>
      ))}
    </section>
  );
}

function mediaUrl(id: string): string {
  return `/media/${encodeURIComponent(id)}`;
}
