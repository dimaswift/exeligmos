import { Children, useId, useRef, useState, type ReactNode } from "react";

import { resolveEventType } from "@exeligmos/domain-catalog";
import type { SarosPulseTickReading } from "@exeligmos/temporal-core";
import { GlyphRenderer } from "@exeligmos/ui";

import { SarosPulseGlyphPair } from "~/components/saros-pulse-glyph-pair";
import {
  sarosPulseAnchorValue,
  useSarosPulseTickAt,
} from "~/features/temporal/saros-pulse-context";
import styles from "./activity-feed.module.css";
import { journalRecordPresentation } from "./journal-presentation";
import {
  activityResourceActor,
  formatAbsoluteTimestamp,
  formatMetadata,
  isValidTimestamp,
  type ActivityActor,
  type ActivityChange,
  type ActivityEvent,
  type ActivityRecord,
  type ActivityReference,
  type ActivityResource,
  type EventActivityChange,
  type HydratedActivityRow,
  type PublicProfile,
  type RecordActivityChange,
} from "./model";

export interface ActivityResourceCardProps {
  readonly resource: ActivityResource;
  readonly href?: string;
  readonly actorHref?: string;
  readonly referenceHref?: (reference: ActivityReference) => string | undefined;
  readonly headingLevel?: 2 | 3 | 4;
  readonly className?: string;
}

export interface RecordActivityCardProps extends Omit<ActivityResourceCardProps, "resource"> {
  readonly record: ActivityRecord;
  readonly actor?: ActivityActor;
  readonly activity?: RecordActivityChange;
}

export interface EventActivityCardProps extends Omit<ActivityResourceCardProps, "resource"> {
  readonly event: ActivityEvent;
  readonly actor?: ActivityActor;
  readonly activity?: EventActivityChange;
}

export interface HydratedActivityItemProps {
  readonly row: HydratedActivityRow;
  /** Browser-facing detail URL derived by the route, not the API resource URL. */
  readonly resourceHref?: string;
  readonly actorHref?: string;
  readonly referenceHref?: (reference: ActivityReference) => string | undefined;
  readonly headingLevel?: 2 | 3 | 4;
  readonly className?: string;
}

/**
 * Renders one ordered public-activity row without pretending identifier-only tombstones
 * are still live resources. Projection hydration remains a server/data-layer concern.
 */
export function HydratedActivityItem({
  row,
  resourceHref,
  actorHref,
  referenceHref,
  headingLevel,
  className,
}: HydratedActivityItemProps) {
  if (
    row.kind === "record" &&
    row.activity.operation === "upsert" &&
    row.projection !== undefined
  ) {
    return (
      <RecordActivityCard
        activity={row.activity}
        actor={row.activity.actor}
        actorHref={actorHref}
        className={className}
        headingLevel={headingLevel}
        href={resourceHref}
        record={row.projection}
        referenceHref={referenceHref}
      />
    );
  }
  if (row.kind === "event" && row.activity.operation === "upsert" && row.projection !== undefined) {
    return (
      <EventActivityCard
        activity={row.activity}
        actor={row.activity.actor}
        actorHref={actorHref}
        className={className}
        event={row.projection}
        headingLevel={headingLevel}
        href={resourceHref}
        referenceHref={referenceHref}
      />
    );
  }
  return (
    <ActivityChangeNotice
      actorHref={actorHref}
      className={className}
      resourceHref={resourceHref}
      row={row}
    />
  );
}

export function ActivityResourceCard(props: ActivityResourceCardProps) {
  return props.resource.kind === "record" ? (
    <RecordCard {...props} resource={props.resource} />
  ) : (
    <EventCard {...props} resource={props.resource} />
  );
}

export function RecordActivityCard({ record, actor, activity, ...props }: RecordActivityCardProps) {
  return <ActivityResourceCard {...props} resource={{ kind: "record", record, actor, activity }} />;
}

export function EventActivityCard({ event, actor, activity, ...props }: EventActivityCardProps) {
  return <ActivityResourceCard {...props} resource={{ kind: "event", event, actor, activity }} />;
}

function RecordCard({
  resource,
  href,
  actorHref,
  referenceHref,
  headingLevel = 3,
  className,
}: ActivityResourceCardProps & {
  readonly resource: Extract<ActivityResource, { kind: "record" }>;
}) {
  const titleId = `${useId()}-record-title`;
  const { record } = resource;
  const actor = activityResourceActor(resource);
  const isPrivate = record.visibility === "private";
  const payload = isPrivate ? undefined : record.payload;
  const presentation = journalRecordPresentation(record);
  const timestamp = isPrivate ? record.createdAt : record.occurredAt;
  const endedAt = isPrivate ? undefined : record.endedAt;
  const references = record.references;
  const pulseAnchor =
    actor === undefined ? undefined : sarosPulseAnchorValue(Reflect.get(actor, "sarosAnchor"));
  const pulse = useSarosPulseTickAt(Date.parse(timestamp) / 1_000, pulseAnchor);

  return (
    <article
      aria-labelledby={titleId}
      className={joinClassNames(styles.card, styles.recordCard, className)}
      data-activity-kind="record"
      data-activity-operation={resource.activity?.operation}
      data-activity-sequence={resource.activity?.sequence}
      data-activity-url={resource.activity?.resourceUrl}
      data-visibility={record.visibility}
    >
      <RecordHeader
        glyph={presentation.primaryGlyph}
        href={href}
        marker={presentation.emoji}
        pulse={pulse}
        privateRecord={isPrivate}
        headingLevel={headingLevel}
        title={presentation.temporalTitle}
        titleId={titleId}
        waveLabel={presentation.waveLabel}
      />

      <div className={styles.content}>
        <SarosStrip presentation={presentation} />

        {isPrivate ? (
          <p className={styles.encryptedNotice}>
            <span aria-hidden="true">◇</span>
            Client-encrypted content
          </p>
        ) : payload === undefined ? null : (
          <RecordBody payload={payload} />
        )}

        {!isPrivate ? <RecordMediaStrip media={record.media} /> : null}

        {!isPrivate && record.tags.length > 0 ? (
          <ul aria-label="Tags" className={styles.chipList}>
            {record.tags.map((tag) => (
              <li className={styles.tag} key={tag.id}>
                {tag.emoji === undefined ? null : <span aria-hidden="true">{tag.emoji}</span>}
                {tag.name}
              </li>
            ))}
          </ul>
        ) : null}

        <ReferenceList referenceHref={referenceHref} references={references} />
      </div>

      <footer className={styles.recordFooter}>
        <RecordDateRange duration={presentation.durationLabel} end={endedAt} start={timestamp} />
        <ActorHandle actor={actor} href={actorHref} />
      </footer>
    </article>
  );
}

function RecordHeader({
  glyph,
  href,
  marker,
  pulse,
  privateRecord,
  headingLevel,
  title,
  titleId,
  waveLabel,
}: {
  readonly glyph: ReturnType<typeof journalRecordPresentation>["primaryGlyph"];
  readonly href?: string;
  readonly marker: string;
  readonly pulse?: SarosPulseTickReading;
  readonly privateRecord: boolean;
  readonly headingLevel: 2 | 3 | 4;
  readonly title: string;
  readonly titleId: string;
  readonly waveLabel?: string;
}) {
  const content = (
    <>
      <span aria-hidden="true" className={styles.kindMark}>
        {marker}
      </span>
      <div className={styles.recordHeaderIdentity}>
        <RecordHeaderHeading headingLevel={headingLevel} id={titleId}>
          {title}
        </RecordHeaderHeading>
        {waveLabel === undefined ? null : <p className={styles.waveLabel}>{waveLabel}</p>}
      </div>
      <span className={styles.recordHeaderGlyph}>
        {pulse === undefined ? (
          glyph === undefined ? null : (
            <GlyphRenderer decorative model={glyph} size={52} />
          )
        ) : (
          <SarosPulseGlyphPair
            className={styles.recordHeaderPulse}
            decorative
            reading={pulse}
            size="2.35rem"
          />
        )}
        {privateRecord ? (
          <span aria-label="Private record" className={styles.lock}>
            🔒
          </span>
        ) : null}
      </span>
    </>
  );
  return (
    <header className={styles.header}>
      {href === undefined ? (
        content
      ) : (
        <a className={styles.headerLink} href={href}>
          {content}
        </a>
      )}
    </header>
  );
}

function RecordHeaderHeading({
  children,
  headingLevel,
  id,
}: {
  readonly children: ReactNode;
  readonly headingLevel: 2 | 3 | 4;
  readonly id: string;
}) {
  if (headingLevel === 2)
    return (
      <h2 className={styles.recordHeaderTitle} id={id}>
        {children}
      </h2>
    );
  if (headingLevel === 4)
    return (
      <h4 className={styles.recordHeaderTitle} id={id}>
        {children}
      </h4>
    );
  return (
    <h3 className={styles.recordHeaderTitle} id={id}>
      {children}
    </h3>
  );
}

function ActorHandle({ actor, href }: { readonly actor?: ActivityActor; readonly href?: string }) {
  if (actor === undefined) return null;
  const content = `@${actor.login}`;
  return href === undefined ? (
    <span className={styles.footerHandle}>{content}</span>
  ) : (
    <a className={styles.footerHandle} href={href}>
      {content}
    </a>
  );
}

function RecordDateRange({
  start,
  end,
  duration,
}: {
  readonly start: string;
  readonly end?: string;
  readonly duration?: string;
}) {
  const startTime = Date.parse(start);
  const endTime = end === undefined ? Number.NaN : Date.parse(end);
  const oneSaros = 568_971_743.04 / 8 ** 7;
  const showRange = Number.isFinite(endTime) && endTime - startTime >= oneSaros * 1_000;
  return (
    <span className={styles.recordDate}>
      <LocalTimestamp value={start} />
      {showRange && end !== undefined ? (
        <>
          <span aria-hidden="true"> – </span>
          <LocalTimestamp value={end} />
        </>
      ) : null}
      {duration === undefined ? null : <span className={styles.recordDuration}> · {duration}</span>}
    </span>
  );
}

export function LocalTimestamp({ value }: { readonly value: string }) {
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) return <span>Invalid timestamp</span>;
  return (
    <time dateTime={value} suppressHydrationWarning>
      {new Intl.DateTimeFormat(undefined, {
        dateStyle: "medium",
        timeStyle: "medium",
      }).format(date)}
    </time>
  );
}

function EventCard({
  resource,
  href,
  actorHref,
  referenceHref,
  headingLevel = 3,
  className,
}: ActivityResourceCardProps & {
  readonly resource: Extract<ActivityResource, { kind: "event" }>;
}) {
  const titleId = `${useId()}-event-title`;
  const { event } = resource;
  const actor = activityResourceActor(resource);
  const eventType = resolveEventType(event.type);
  const deviceId = "deviceId" in event ? event.deviceId : undefined;

  return (
    <article
      aria-labelledby={titleId}
      className={joinClassNames(styles.card, styles.eventCard, className)}
      data-activity-kind="event"
      data-activity-operation={resource.activity?.operation}
      data-activity-sequence={resource.activity?.sequence}
      data-activity-url={resource.activity?.resourceUrl}
      data-event-type={event.type}
      data-visibility={event.visibility}
    >
      <CardHeader
        activity={resource.activity}
        actor={actor}
        actorHref={actorHref}
        end={event.endsAt}
        kind="Event"
        marker="E"
        start={event.startsAt}
        visibility={event.visibility}
      />

      <div className={styles.content}>
        <CardHeading headingLevel={headingLevel} href={href} id={titleId}>
          {event.label}
        </CardHeading>
        <p className={styles.typeLine}>
          <span className={styles.typeCode}>TYPE {event.type}</span>
          <span>{eventType.label}</span>
          <span className={styles.namespace}>{eventType.namespace}</span>
        </p>

        <ReferenceList referenceHref={referenceHref} references={event.references} />
        <MetadataDetails metadata={event.metadata} />
      </div>

      <CardFooter
        activity={resource.activity}
        createdAt={event.createdAt}
        deviceId={deviceId}
        revision={event.revision}
        updatedAt={event.updatedAt}
      />
    </article>
  );
}

function CardHeader({
  activity,
  actor,
  actorHref,
  end,
  kind,
  marker,
  start,
  visibility,
}: {
  readonly activity?: ActivityChange;
  readonly actor?: ActivityActor;
  readonly actorHref?: string;
  readonly end?: string;
  readonly kind: "Record" | "Event";
  readonly marker: string;
  readonly start: string;
  readonly visibility: "public" | "private";
}) {
  return (
    <header className={styles.header}>
      <span aria-hidden="true" className={styles.kindMark}>
        {marker}
      </span>
      <div className={styles.byline}>
        <div className={styles.actorLine}>
          <span className={styles.kindLabel}>{kind}</span>
          <span aria-hidden="true">·</span>
          <Actor actor={actor} href={actorHref} />
        </div>
        <TimestampRange end={end} start={start} />
      </div>
      <div className={styles.badges}>
        {activity === undefined ? null : (
          <span
            className={styles.operation}
            title={`Published ${formatAbsoluteTimestamp(activity.publishedAt)}`}
          >
            {activity.operation === "upsert" ? "Updated" : "Deleted"}
          </span>
        )}
        <span className={visibility === "private" ? styles.privateBadge : styles.publicBadge}>
          {visibility}
        </span>
      </div>
    </header>
  );
}

function Actor({ actor, href }: { readonly actor?: ActivityActor; readonly href?: string }) {
  if (actor === undefined) {
    return <span className={styles.unknownActor}>Private owner</span>;
  }
  const content = (
    <>
      <span className={styles.actorName}>{actor.displayName}</span>
      <span className={styles.actorLogin}>@{actor.login}</span>
    </>
  );
  return href === undefined ? (
    <span className={styles.actor}>{content}</span>
  ) : (
    <a className={styles.actor} href={href}>
      {content}
    </a>
  );
}

function TimestampRange({ start, end }: { readonly start: string; readonly end?: string }) {
  return (
    <p className={styles.timeRange}>
      <Timestamp value={start} />
      {end === undefined ? null : (
        <>
          <span aria-hidden="true"> → </span>
          <Timestamp value={end} />
        </>
      )}
    </p>
  );
}

function Timestamp({ value }: { readonly value: string }) {
  const label = formatAbsoluteTimestamp(value);
  return isValidTimestamp(value) ? <time dateTime={value}>{label}</time> : <span>{label}</span>;
}

function CardHeading({
  children,
  headingLevel,
  href,
  id,
}: {
  readonly children: ReactNode;
  readonly headingLevel: 2 | 3 | 4;
  readonly href?: string;
  readonly id: string;
}) {
  const content = href === undefined ? children : <a href={href}>{children}</a>;
  if (headingLevel === 2) {
    return (
      <h2 className={styles.title} id={id}>
        {content}
      </h2>
    );
  }
  if (headingLevel === 4) {
    return (
      <h4 className={styles.title} id={id}>
        {content}
      </h4>
    );
  }
  return (
    <h3 className={styles.title} id={id}>
      {content}
    </h3>
  );
}

function RecordBody({
  payload,
}: {
  readonly payload: Exclude<ActivityRecord, { visibility: "private" }>["payload"];
}) {
  const text = typeof payload.text === "string" ? payload.text.trim() : "";
  return text === "" ? null : (
    <div className={styles.recordBody}>
      <p>{text}</p>
    </div>
  );
}

function SarosStrip({
  presentation,
}: {
  readonly presentation: ReturnType<typeof journalRecordPresentation>;
}) {
  if (presentation.spikes.length === 0) return null;
  return (
    <ul aria-label="Saros context" className={styles.sarosStrip}>
      {presentation.spikes.map((spike) => (
        <li className={spike.isClosest ? styles.closestSaros : undefined} key={spike.id}>
          <GlyphRenderer decorative model={spike.glyph} size={34} />
          <span>{spike.saros}</span>
        </li>
      ))}
    </ul>
  );
}

function RecordMediaStrip({
  media,
}: {
  readonly media: Exclude<ActivityRecord, { visibility: "private" }>["media"];
}) {
  return <RecordMediaGrid media={media} variant="compact" />;
}

type RecordMediaItem = ActivityRecord["media"][number];

export function RecordMediaGrid({
  media,
  variant = "detail",
}: {
  readonly media: readonly RecordMediaItem[];
  readonly variant?: "compact" | "detail";
}) {
  const visualMedia = media.filter(
    (item) => item.contentType.startsWith("image/") || item.contentType.startsWith("video/"),
  );
  const [viewerIndex, setViewerIndex] = useState<number | undefined>();
  const displayed = variant === "compact" ? media.slice(0, 4) : media;
  if (media.length === 0) return null;
  return (
    <>
      <div
        aria-label="Record media"
        className={variant === "compact" ? styles.mediaStrip : styles.mediaGrid}
      >
        {displayed.map((item) => {
          const url = `/media/${encodeURIComponent(item.id)}`;
          if (item.contentType.startsWith("image/") || item.contentType.startsWith("video/")) {
            const visualIndex = visualMedia.findIndex((candidate) => candidate.id === item.id);
            return (
              <button
                className={styles.mediaButton}
                key={item.id}
                onClick={() => setViewerIndex(visualIndex)}
                type="button"
              >
                {item.contentType.startsWith("image/") ? (
                  <img alt={item.fileName} decoding="async" loading="lazy" src={url} />
                ) : (
                  <span className={styles.videoThumbnail}>
                    <video aria-hidden="true" muted playsInline preload="metadata" src={url} />
                    <span aria-hidden="true">▶</span>
                    <span className={styles.visuallyHidden}>{item.fileName}</span>
                  </span>
                )}
              </button>
            );
          }
          if (item.contentType.startsWith("audio/")) {
            return <AudioTile item={item} key={item.id} url={url} />;
          }
          return (
            <a className={styles.mediaTile} href={url} key={item.id} title={item.fileName}>
              ↗
            </a>
          );
        })}
        {variant !== "compact" || media.length <= 4 ? null : (
          <span className={styles.mediaOverflow}>+{media.length - 4}</span>
        )}
      </div>
      {viewerIndex === undefined ? null : (
        <MediaViewer
          initialIndex={viewerIndex}
          media={visualMedia}
          onClose={() => setViewerIndex(undefined)}
        />
      )}
    </>
  );
}

function AudioTile({
  item,
  url,
}: {
  readonly item: { readonly fileName: string };
  readonly url: string;
}) {
  const audio = useRef<HTMLAudioElement>(null);
  const [playing, setPlaying] = useState(false);
  const toggle = () => {
    const player = audio.current;
    if (player === null) return;
    if (playing) {
      player.pause();
      player.currentTime = 0;
      setPlaying(false);
    } else {
      void player
        .play()
        .then(() => setPlaying(true))
        .catch(() => setPlaying(false));
    }
  };
  return (
    <button
      aria-label={`${playing ? "Stop" : "Play"} ${item.fileName}`}
      className={`${styles.mediaTile} ${styles.mediaButton}`}
      onClick={toggle}
      type="button"
    >
      <audio onEnded={() => setPlaying(false)} preload="none" ref={audio} src={url} />
      {playing ? "■" : "♪"}
    </button>
  );
}

function MediaViewer({
  media,
  initialIndex,
  onClose,
}: {
  readonly media: readonly RecordMediaItem[];
  readonly initialIndex: number;
  readonly onClose: () => void;
}) {
  const [index, setIndex] = useState(initialIndex);
  const item = media[index];
  if (item === undefined) return null;
  const previous = () => setIndex((current) => (current - 1 + media.length) % media.length);
  const next = () => setIndex((current) => (current + 1) % media.length);
  return (
    <div
      aria-label="Media preview"
      aria-modal="true"
      className={styles.gallery}
      onClick={(event) => {
        if (event.currentTarget === event.target) onClose();
      }}
      role="dialog"
    >
      <button
        aria-label="Close preview"
        className={styles.galleryClose}
        onClick={onClose}
        type="button"
      >
        ×
      </button>
      {media.length > 1 ? (
        <button
          aria-label="Previous media"
          className={`${styles.galleryArrow} ${styles.galleryPrevious}`}
          onClick={(event) => {
            event.stopPropagation();
            previous();
          }}
          type="button"
        >
          ‹
        </button>
      ) : null}
      <figure className={styles.galleryCurrent} onClick={(event) => event.stopPropagation()}>
        {item.contentType.startsWith("video/") ? (
          <video autoPlay controls playsInline src={`/media/${encodeURIComponent(item.id)}`} />
        ) : (
          <img alt={item.fileName} onClick={next} src={`/media/${encodeURIComponent(item.id)}`} />
        )}
        <figcaption>
          {index + 1} / {media.length} · {item.fileName}
        </figcaption>
      </figure>
      {media.length > 1 ? (
        <button
          aria-label="Next media"
          className={`${styles.galleryArrow} ${styles.galleryNext}`}
          onClick={(event) => {
            event.stopPropagation();
            next();
          }}
          type="button"
        >
          ›
        </button>
      ) : null}
    </div>
  );
}

function ReferenceList({
  referenceHref,
  references,
}: {
  readonly referenceHref?: (reference: ActivityReference) => string | undefined;
  readonly references: readonly ActivityReference[];
}) {
  if (references.length === 0) {
    return null;
  }
  return (
    <div className={styles.references}>
      <span className={styles.subheading}>References</span>
      <ul>
        {references.map((reference, index) => {
          const href = referenceHref?.(reference);
          const content = (
            <>
              <span className={styles.relation}>{reference.relation}</span>
              <span>{reference.targetType}</span>
              <code title={reference.targetId}>{compactIdentifier(reference.targetId)}</code>
              <span className={styles.targetOwner} title={reference.targetUserId}>
                owner {compactIdentifier(reference.targetUserId)}
              </span>
            </>
          );
          return (
            <li
              key={`${reference.targetType}:${reference.targetId}:${reference.relation}:${index}`}
            >
              {href === undefined ? content : <a href={href}>{content}</a>}
            </li>
          );
        })}
      </ul>
    </div>
  );
}

function MetadataDetails({ metadata }: { readonly metadata?: Readonly<Record<string, unknown>> }) {
  if (metadata === undefined || Object.keys(metadata).length === 0) {
    return null;
  }
  return (
    <details className={styles.metadata}>
      <summary>Metadata · {Object.keys(metadata).length} fields</summary>
      <pre>{formatMetadata(metadata)}</pre>
    </details>
  );
}

function CardFooter({
  activity,
  createdAt,
  deviceId,
  mediaCount,
  revision,
  templateVersion,
  updatedAt,
}: {
  readonly activity?: ActivityChange;
  readonly createdAt: string;
  readonly deviceId?: string;
  readonly mediaCount?: number;
  readonly revision: number;
  readonly templateVersion?: number;
  readonly updatedAt: string;
}) {
  return (
    <footer className={styles.footer}>
      {activity === undefined ? null : (
        <span data-publication-sequence={activity.sequence}>
          Published <Timestamp value={activity.publishedAt} /> · Sequence {activity.sequence}
        </span>
      )}
      <span
        title={`Created ${formatAbsoluteTimestamp(createdAt)} · Updated ${formatAbsoluteTimestamp(updatedAt)}`}
      >
        Revision {revision}
      </span>
      {deviceId === undefined ? null : (
        <span title={deviceId}>Device {compactIdentifier(deviceId)}</span>
      )}
      {mediaCount === undefined ? null : <span>{mediaCount} media</span>}
      {templateVersion === undefined ? null : <span>Template v{templateVersion}</span>}
    </footer>
  );
}

export interface ActivityChangeNoticeProps {
  readonly row: HydratedActivityRow;
  readonly resourceHref?: string;
  readonly actorHref?: string;
  readonly className?: string;
}

/** Compact lifecycle/tombstone rendering for canonical identifier-only notifications. */
export function ActivityChangeNotice({
  row,
  resourceHref,
  actorHref,
  className,
}: ActivityChangeNoticeProps) {
  const titleId = `${useId()}-activity-change-title`;
  const { activity } = row;
  const isDelete = activity.operation === "delete";
  const title = lifecycleTitle(row);
  return (
    <article
      aria-labelledby={titleId}
      className={joinClassNames(styles.card, styles.lifecycleCard, className)}
      data-activity-kind={row.kind}
      data-activity-operation={activity.operation}
      data-activity-sequence={activity.sequence}
      data-activity-url={activity.resourceUrl}
    >
      <div className={styles.lifecycleBody}>
        <span aria-hidden="true" className={styles.lifecycleMark}>
          {isDelete ? "−" : "+"}
        </span>
        <div>
          <p className={styles.lifecycleActor}>
            <Actor actor={activity.actor} href={actorHref} />
          </p>
          <h3 id={titleId}>{title}</h3>
          <p className={styles.lifecycleMeta}>
            <Timestamp value={activity.publishedAt} />
            <span aria-hidden="true"> · </span>
            <span>Sequence {activity.sequence}</span>
            <span aria-hidden="true"> · </span>
            <code title={activity.resourceId}>{compactIdentifier(activity.resourceId)}</code>
          </p>
          {!isDelete && row.kind !== "user" && row.projection === undefined ? (
            <p className={styles.hydrationNote}>
              The public projection was unavailable in this snapshot.
            </p>
          ) : null}
          <p className={styles.resourceUrl} title={activity.resourceUrl}>
            API resource <code>{activity.resourceUrl}</code>
          </p>
        </div>
        {resourceHref === undefined || isDelete ? null : (
          <a className={styles.lifecycleLink} href={resourceHref}>
            Open {row.kind}
          </a>
        )}
      </div>
    </article>
  );
}

export interface PublicProfileHeaderProps {
  readonly profile: PublicProfile;
  readonly actions?: ReactNode;
  readonly className?: string;
}

export function PublicProfileHeader({ profile, actions, className }: PublicProfileHeaderProps) {
  const titleId = `${useId()}-profile-title`;
  const initial = profile.displayName.trim().at(0)?.toUpperCase() ?? "@";
  return (
    <header
      aria-labelledby={titleId}
      className={joinClassNames(styles.profile, className)}
      data-public-profile={profile.id}
    >
      <div aria-hidden="true" className={styles.avatar}>
        {initial}
      </div>
      <div className={styles.profileIdentity}>
        <p className="eyebrow">Public actor</p>
        <h1 id={titleId}>{profile.displayName}</h1>
        <p className={styles.profileLogin}>@{profile.login}</p>
        <p className={styles.profileSince}>
          Public since <Timestamp value={profile.createdAt} />
        </p>
      </div>
      <dl className={styles.stats}>
        <div>
          <dt>Records</dt>
          <dd>{profile.publicRecordCount.toLocaleString("en")}</dd>
        </div>
        <div>
          <dt>Events</dt>
          <dd>{profile.publicEventCount.toLocaleString("en")}</dd>
        </div>
        <div>
          <dt>Followers</dt>
          <dd>{profile.followerCount.toLocaleString("en")}</dd>
        </div>
      </dl>
      {actions === undefined ? null : <div className={styles.profileActions}>{actions}</div>}
    </header>
  );
}

export function ActivityFeedList({
  children,
  className,
}: {
  readonly children: ReactNode;
  readonly className?: string;
}) {
  return (
    <ol className={joinClassNames(styles.feedList, className)}>
      {Children.map(children, (child) => (
        <li>{child}</li>
      ))}
    </ol>
  );
}

export interface RecordLaneItem {
  readonly record: ActivityRecord;
  readonly href?: string;
  readonly actorHref?: string;
}

export interface EventLaneItem {
  readonly event: ActivityEvent;
  readonly href?: string;
  readonly actorHref?: string;
}

interface ResourceLaneProps {
  readonly title?: string;
  readonly description?: string;
  readonly nextHref?: string | null;
  readonly previousHref?: string | null;
  readonly referenceHref?: (reference: ActivityReference) => string | undefined;
  readonly className?: string;
}

export interface RecordLaneProps extends ResourceLaneProps {
  readonly items: readonly RecordLaneItem[];
  readonly emptyMessage?: string;
}

export interface EventLaneProps extends ResourceLaneProps {
  readonly items: readonly EventLaneItem[];
  readonly emptyMessage?: string;
}

/** Authoritative record projection lane with its own independent cursor links. */
export function RecordLane({
  items,
  title = "Records",
  description,
  emptyMessage = "No records are available in this lane.",
  nextHref,
  previousHref,
  referenceHref,
  className,
}: RecordLaneProps) {
  const titleId = `${useId()}-record-lane-title`;
  return (
    <section aria-labelledby={titleId} className={joinClassNames(styles.lane, className)}>
      <LaneHeader count={items.length} description={description} id={titleId} title={title} />
      {items.length === 0 ? (
        <ActivityFeedEmpty message={emptyMessage} title="No records" />
      ) : (
        <ActivityFeedList>
          {items.map((item) => (
            <RecordActivityCard
              actorHref={item.actorHref}
              headingLevel={3}
              href={item.href}
              key={item.record.id}
              record={item.record}
              referenceHref={referenceHref}
            />
          ))}
        </ActivityFeedList>
      )}
      {nextHref === undefined && previousHref === undefined ? null : (
        <CursorPagination
          ariaLabel="Record pages"
          nextHref={nextHref}
          nextLabel="Older records"
          pageLabel="Record snapshot"
          previousHref={previousHref}
          previousLabel="Newer records"
        />
      )}
    </section>
  );
}

/** Authoritative event projection lane with its own independent cursor links. */
export function EventLane({
  items,
  title = "Events",
  description,
  emptyMessage = "No events are available in this lane.",
  nextHref,
  previousHref,
  referenceHref,
  className,
}: EventLaneProps) {
  const titleId = `${useId()}-event-lane-title`;
  return (
    <section aria-labelledby={titleId} className={joinClassNames(styles.lane, className)}>
      <LaneHeader count={items.length} description={description} id={titleId} title={title} />
      {items.length === 0 ? (
        <ActivityFeedEmpty message={emptyMessage} title="No events" />
      ) : (
        <ActivityFeedList>
          {items.map((item) => (
            <EventActivityCard
              actorHref={item.actorHref}
              event={item.event}
              headingLevel={3}
              href={item.href}
              key={item.event.id}
              referenceHref={referenceHref}
            />
          ))}
        </ActivityFeedList>
      )}
      {nextHref === undefined && previousHref === undefined ? null : (
        <CursorPagination
          ariaLabel="Event pages"
          nextHref={nextHref}
          nextLabel="Older events"
          pageLabel="Event snapshot"
          previousHref={previousHref}
          previousLabel="Newer events"
        />
      )}
    </section>
  );
}

function LaneHeader({
  count,
  description,
  id,
  title,
}: {
  readonly count: number;
  readonly description?: string;
  readonly id: string;
  readonly title: string;
}) {
  return (
    <header className={styles.laneHeader}>
      <div>
        <h2 id={id}>{title}</h2>
        {description === undefined ? null : <p>{description}</p>}
      </div>
      <span>{count} loaded</span>
    </header>
  );
}

export interface ActivityFeedEmptyProps {
  readonly title?: string;
  readonly message: string;
  readonly action?: ReactNode;
  readonly className?: string;
}

export function ActivityFeedEmpty({
  title = "No activity yet",
  message,
  action,
  className,
}: ActivityFeedEmptyProps) {
  const titleId = `${useId()}-empty-title`;
  return (
    <section
      aria-labelledby={titleId}
      className={joinClassNames(styles.state, styles.emptyState, className)}
    >
      <span aria-hidden="true" className={styles.stateMark}>
        ○
      </span>
      <div>
        <h2 id={titleId}>{title}</h2>
        <p>{message}</p>
      </div>
      {action === undefined ? null : <div className={styles.stateAction}>{action}</div>}
    </section>
  );
}

export interface ActivityFeedNoticeProps {
  readonly title: string;
  readonly message: string;
  readonly tone?: "neutral" | "error";
  readonly action?: ReactNode;
  readonly className?: string;
}

export function ActivityFeedNotice({
  title,
  message,
  tone = "neutral",
  action,
  className,
}: ActivityFeedNoticeProps) {
  const titleId = `${useId()}-notice-title`;
  return (
    <section
      aria-labelledby={titleId}
      className={joinClassNames(
        styles.state,
        tone === "error" ? styles.errorState : undefined,
        className,
      )}
      role={tone === "error" ? "alert" : "status"}
    >
      <span aria-hidden="true" className={styles.stateMark}>
        {tone === "error" ? "!" : "i"}
      </span>
      <div>
        <h2 id={titleId}>{title}</h2>
        <p>{message}</p>
      </div>
      {action === undefined ? null : <div className={styles.stateAction}>{action}</div>}
    </section>
  );
}

export interface CursorPaginationProps {
  readonly nextHref?: string | null;
  readonly previousHref?: string | null;
  readonly nextLabel?: string;
  readonly previousLabel?: string;
  readonly pageLabel?: string;
  readonly ariaLabel?: string;
  readonly className?: string;
}

export function CursorPagination({
  nextHref,
  previousHref,
  nextLabel = "Later changes",
  previousLabel = "Earlier changes",
  pageLabel = "Activity history snapshot",
  ariaLabel = "Activity history pages",
  className,
}: CursorPaginationProps) {
  return (
    <nav aria-label={ariaLabel} className={joinClassNames(styles.pagination, className)}>
      <PaginationDirection direction="previous" href={previousHref} label={previousLabel} />
      <span aria-current="page" className={styles.pageLabel}>
        {pageLabel}
      </span>
      <PaginationDirection direction="next" href={nextHref} label={nextLabel} />
    </nav>
  );
}

function PaginationDirection({
  direction,
  href,
  label,
}: {
  readonly direction: "previous" | "next";
  readonly href?: string | null;
  readonly label: string;
}) {
  const arrow = direction === "previous" ? "←" : "→";
  const content = direction === "previous" ? `${arrow} ${label}` : `${label} ${arrow}`;
  return href === undefined || href === null ? (
    <span aria-disabled="true" className={styles.paginationDisabled}>
      {content}
    </span>
  ) : (
    <a href={href} rel={direction === "previous" ? "prev" : "next"}>
      {content}
    </a>
  );
}

function lifecycleTitle(row: HydratedActivityRow): string {
  if (row.kind === "user") {
    return row.activity.operation === "delete"
      ? "Public profile became unavailable"
      : "Public profile published or restored";
  }
  if (row.activity.operation === "delete") {
    return `Public ${row.kind} deleted`;
  }
  return `${row.kind === "record" ? "Record" : "Event"} update`;
}

function compactIdentifier(value: string): string {
  return value.length <= 12 ? value : `${value.slice(0, 8)}…`;
}

function joinClassNames(...values: ReadonlyArray<string | undefined>): string {
  return values.filter((value): value is string => value !== undefined && value !== "").join(" ");
}
