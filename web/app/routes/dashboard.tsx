import type { Route } from "./+types/dashboard";

import { readSyncStats } from "~/features/activity-stream/snapshots.server";
import { readRequestAuth } from "~/lib/auth-boundary.server";
import { throwRouteError } from "~/lib/route-errors.server";

import styles from "./dashboard.module.css";

export const meta: Route.MetaFunction = () => [{ title: "Analytics · Exeligmos" }];

export async function loader({ context, request }: Route.LoaderArgs) {
  try {
    const boundary = readRequestAuth(context);
    return {
      stats: await readSyncStats(boundary.auth, { signal: request.signal }),
    };
  } catch (error) {
    return throwRouteError(error, request, { clearInvalidAuth: true });
  }
}

export default function Dashboard({ loaderData }: Route.ComponentProps) {
  const { records, media } = loaderData.stats;
  return (
    <main className={styles.dashboard}>
      <h1>Analytics</h1>
      <section aria-labelledby="record-stats" className={styles.section}>
        <h2 id="record-stats">Records</h2>
        <div className={styles.grid}>
          <Stat label="Past Tera" value={records.pastTera} note="1 Tera · 8 Giga" />
          <Stat label="Past Giga" value={records.pastGiga} />
          <Stat label="Past Mega" value={records.pastMega} />
          <Stat label="Total" value={records.total} />
        </div>
      </section>
      <section aria-labelledby="media-stats" className={styles.section}>
        <h2 id="media-stats">Media</h2>
        <div className={styles.grid}>
          <Stat label="Files" value={media.total} />
          <Stat label="Photos" value={media.photo} />
          <Stat label="Videos" value={media.video} />
          <Stat label="Audio" value={media.audio} />
          <Stat label="Storage" value={formatBytes(media.byteLength)} wide />
        </div>
      </section>
    </main>
  );
}

function Stat({
  label,
  value,
  note,
  wide = false,
}: {
  readonly label: string;
  readonly value: number | string;
  readonly note?: string;
  readonly wide?: boolean;
}) {
  return (
    <article className={wide ? `${styles.stat} ${styles.wide}` : styles.stat}>
      <p>{label}</p>
      <strong>{typeof value === "number" ? value.toLocaleString() : value}</strong>
      {note === undefined ? null : <span>{note}</span>}
    </article>
  );
}

function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return "0 B";
  const units = ["B", "KB", "MB", "GB", "TB"] as const;
  const exponent = Math.min(Math.floor(Math.log(bytes) / Math.log(1_024)), units.length - 1);
  const unit = units[exponent] ?? "B";
  const value = bytes / 1_024 ** exponent;
  return `${value.toLocaleString(undefined, { maximumFractionDigits: value >= 10 ? 1 : 2 })} ${unit}`;
}
