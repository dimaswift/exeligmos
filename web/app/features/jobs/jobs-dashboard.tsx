import type { Job, JobCurrentItem, JobPage } from "./jobs.server";
import styles from "./jobs-dashboard.module.css";

export interface JobsDashboardProps {
  readonly jobs: JobPage;
  readonly pollUnavailable?: boolean;
  readonly refreshing?: boolean;
}

export function JobsDashboard({
  jobs,
  pollUnavailable = false,
  refreshing = false,
}: JobsDashboardProps) {
  const activeJob = jobs.data.find((job) => job.activity === "active");
  const totals = aggregateJobs(jobs.data);
  const active = activeJob !== undefined;

  return (
    <section aria-labelledby="jobs-page-title" className={styles.page}>
      <header className={styles.pageHeader}>
        <div>
          <p className="eyebrow">Media ingestion</p>
          <h1 id="jobs-page-title">Jobs</h1>
          <p>THUMB_CAM scans, media processing, and record creation.</p>
        </div>
        <div
          aria-live="polite"
          className={`${styles.workerStatus} ${
            pollUnavailable
              ? styles.workerUnavailable
              : active
                ? styles.workerActive
                : styles.workerIdle
          }`}
          role="status"
        >
          <span aria-hidden="true" className={styles.statusDot} />
          <span>
            {pollUnavailable
              ? "Connection interrupted · showing last update"
              : active
                ? "Worker active"
                : "No active job"}
          </span>
          {refreshing ? (
            <span aria-hidden="true" className={styles.refreshing}>
              refreshing
            </span>
          ) : null}
        </div>
      </header>

      <section aria-label="Visible job totals" className={styles.summaryGrid}>
        <SummaryStat label="Processed media" value={totals.processedItems} />
        <SummaryStat label="Remaining media" value={totals.remainingItems} />
        <SummaryStat label="Records created" value={totals.processedRecords} />
        <SummaryStat
          label="Failed media"
          tone={totals.failures > 0 ? "danger" : "normal"}
          value={totals.failures}
        />
      </section>

      {activeJob === undefined ? (
        <section className={`${styles.panel} ${styles.idlePanel}`}>
          <span aria-hidden="true" className={styles.idleIcon}>
            ◌
          </span>
          <div>
            <h2>No server job is processing</h2>
            <p>
              Newly discovered media appears here after its 4m31s Saros grouping
              window closes.
            </p>
          </div>
        </section>
      ) : (
        <CurrentJob job={activeJob} />
      )}

      <section aria-labelledby="jobs-list-title" className={styles.jobsSection}>
        <header className={styles.sectionHeader}>
          <div>
            <h2 id="jobs-list-title">Queue and recent jobs</h2>
            <p>
              {jobs.data.length} job{jobs.data.length === 1 ? "" : "s"} visible
            </p>
          </div>
        </header>
        {jobs.data.length === 0 ? (
          <p className={styles.empty}>THUMB_CAM has no pending media.</p>
        ) : (
          <ol className={styles.jobList}>
            {jobs.data.map((job) => (
              <JobRow job={job} key={job.id} />
            ))}
          </ol>
        )}
      </section>
    </section>
  );
}

function CurrentJob({ job }: { readonly job: Job }) {
  return (
    <section
      aria-labelledby="current-job-title"
      className={`${styles.panel} ${styles.currentPanel}`}
    >
      <header className={styles.currentHeader}>
        <div>
          <p className={styles.panelEyebrow}>Currently processing</p>
          <h2 id="current-job-title">{sourceLabel(job.source)}</h2>
        </div>
        <StatusBadge processing={job.activity === "active"} status={job.status} />
      </header>
      <JobProgress job={job} prominent />
      <div className={styles.recordProgress}>
        <span>
          <strong>{job.processedRecords}</strong> / {job.totalRecords} records created
        </span>
        {job.failedRecords > 0 ? (
          <span className={styles.dangerText}>{job.failedRecords} failed</span>
        ) : null}
      </div>
      {job.currentItem == null ? null : <CurrentItem item={job.currentItem} />}
    </section>
  );
}

function CurrentItem({ item }: { readonly item: JobCurrentItem }) {
  return (
    <div className={styles.currentItem}>
      <span aria-hidden="true" className={styles.kindEmoji}>
        {kindEmoji(item.kind)}
      </span>
      <div className={styles.currentItemCopy}>
        <div className={styles.itemHeading}>
          <strong>{item.relativePath}</strong>
          <span>{humanize(item.stage)}</span>
        </div>
        <p>
          {humanize(item.kind)} · {humanize(item.status)} ·{" "}
          <time dateTime={item.capturedAt}>{formatTimestamp(item.capturedAt)}</time>
        </p>
        {item.error == null || item.error === "" ? null : (
          <p className={styles.itemError}>{item.error}</p>
        )}
      </div>
    </div>
  );
}

function JobRow({ job }: { readonly job: Job }) {
  return (
    <li className={styles.jobRow}>
      <div className={styles.jobIdentity}>
        <span aria-hidden="true" className={styles.jobIcon}>
          {job.activity === "active" ? "⚙️" : statusEmoji(job.status)}
        </span>
        <div>
          <div className={styles.jobTitleLine}>
            <h3>{sourceLabel(job.source)}</h3>
            <StatusBadge processing={job.activity === "active"} status={job.status} />
          </div>
          <p className={styles.jobMeta}>
            <time dateTime={job.createdAt}>{formatTimestamp(job.createdAt)}</time>
            <span title={job.id}>{shortId(job.id)}</span>
          </p>
        </div>
      </div>
      <JobProgress job={job} />
      <dl className={styles.jobFacts}>
        <div>
          <dt>Media</dt>
          <dd>
            {job.processedItems}/{job.totalItems}
          </dd>
        </div>
        <div>
          <dt>Left</dt>
          <dd>{job.remainingItems}</dd>
        </div>
        <div>
          <dt>Records</dt>
          <dd>
            {job.processedRecords}/{job.totalRecords}
          </dd>
        </div>
        <div className={job.failedItems + job.failedRecords > 0 ? styles.failedFact : undefined}>
          <dt>Failed</dt>
          <dd>{job.failedItems}</dd>
        </div>
      </dl>
      {job.currentItem == null ? null : (
        <>
          <p className={styles.rowCurrentItem}>
            <span aria-hidden="true">{kindEmoji(job.currentItem.kind)}</span>
            <span>{job.currentItem.relativePath}</span>
            <span>{humanize(job.currentItem.stage)}</span>
          </p>
          {job.currentItem.error == null || job.currentItem.error === "" ? null : (
            <p className={styles.rowError}>{job.currentItem.error}</p>
          )}
        </>
      )}
    </li>
  );
}

function JobProgress({
  job,
  prominent = false,
}: {
  readonly job: Job;
  readonly prominent?: boolean;
}) {
  const maximum = Math.max(job.totalItems, 1);
  const value = Math.min(Math.max(job.processedItems, 0), maximum);
  const percentage = job.totalItems === 0 ? 0 : Math.round((value / job.totalItems) * 100);
  return (
    <div
      className={
        prominent ? `${styles.progressBlock} ${styles.progressProminent}` : styles.progressBlock
      }
    >
      <div className={styles.progressLabel}>
        <span>
          {job.processedItems} of {job.totalItems} media processed
        </span>
        <span>{percentage}%</span>
      </div>
      <progress
        aria-label={`${sourceLabel(job.source)}: ${job.processedItems} of ${job.totalItems} media processed`}
        max={maximum}
        value={value}
      />
    </div>
  );
}

function StatusBadge({
  processing,
  status,
}: {
  readonly processing: boolean;
  readonly status: string;
}) {
  const tone = processing ? "active" : statusTone(status);
  return (
    <span className={styles.statusBadge} data-tone={tone}>
      {humanize(status)}
    </span>
  );
}

function SummaryStat({
  label,
  value,
  tone = "normal",
}: {
  readonly label: string;
  readonly value: number;
  readonly tone?: "normal" | "danger";
}) {
  return (
    <article className={styles.summaryStat} data-tone={tone}>
      <span>{label}</span>
      <strong>{value.toLocaleString()}</strong>
    </article>
  );
}

function aggregateJobs(jobs: readonly Job[]) {
  return jobs.reduce(
    (total, job) => ({
      processedItems: total.processedItems + job.processedItems,
      remainingItems: total.remainingItems + job.remainingItems,
      processedRecords: total.processedRecords + job.processedRecords,
      failures: total.failures + job.failedItems,
    }),
    { processedItems: 0, remainingItems: 0, processedRecords: 0, failures: 0 },
  );
}

function statusTone(status: string): "danger" | "done" | "neutral" {
  const normalized = status.toLowerCase();
  if (normalized.includes("fail") || normalized.includes("error")) return "danger";
  if (normalized.includes("complete") || normalized.includes("finish")) return "done";
  return "neutral";
}

function statusEmoji(status: string): string {
  const tone = statusTone(status);
  if (tone === "danger") return "⚠️";
  if (tone === "done") return "✅";
  return "⏳";
}

function kindEmoji(kind: string): string {
  switch (kind.toLowerCase()) {
    case "photo":
    case "image":
      return "📷";
    case "video":
      return "🎥";
    case "audio":
      return "🎙️";
    default:
      return "📎";
  }
}

function humanize(value: string): string {
  const label = value.trim().replaceAll(/[-_]+/g, " ");
  return label === "" ? "Unknown" : `${label.charAt(0).toUpperCase()}${label.slice(1)}`;
}

function shortId(value: string): string {
  return value.length <= 12 ? value : `${value.slice(0, 8)}…`;
}

function sourceLabel(source: Job["source"]): string {
  for (const key of ["volume", "name", "device"] as const) {
    const value = source[key];
    if (typeof value === "string" && value.trim() !== "") return value;
  }
  return "Ingestion device";
}

function formatTimestamp(value: string): string {
  const timestamp = Date.parse(value);
  if (!Number.isFinite(timestamp)) return value;
  const iso = new Date(timestamp).toISOString();
  return `${iso.slice(0, 10)} ${iso.slice(11, 16)} UTC`;
}
