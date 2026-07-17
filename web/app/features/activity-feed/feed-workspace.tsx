import type { ReactNode } from "react";

import styles from "./feed-workspace.module.css";
import {
  ActivityFeedEmpty,
  ActivityFeedList,
  CursorPagination,
  HydratedActivityItem,
} from "./activity-feed";
import type { ActivityReference, HydratedActivityRow } from "./model";

export interface FeedWorkspaceProps {
  readonly eyebrow: string;
  readonly title: string;
  readonly summary: string;
  readonly actions?: ReactNode;
  readonly children: ReactNode;
  readonly className?: string;
}

export function FeedWorkspace({
  eyebrow,
  title,
  summary,
  actions,
  children,
  className,
}: FeedWorkspaceProps) {
  return (
    <div className={joinClassNames(styles.workspace, className)}>
      {title === "" && eyebrow === "" && summary === "" ? null : (
        <header className={styles.pageHeader}>
          <div>
            {eyebrow === "" ? null : <p className="eyebrow">{eyebrow}</p>}
            {title === "" ? null : <h1>{title}</h1>}
            {summary === "" ? null : <p>{summary}</p>}
          </div>
          {actions === undefined ? null : <div className={styles.actions}>{actions}</div>}
        </header>
      )}
      {children}
    </div>
  );
}

export function ResourceLaneGrid({ children }: { readonly children: ReactNode }) {
  return <div className={styles.laneGrid}>{children}</div>;
}

export interface ActivitySnapshotProps {
  readonly rows: readonly HydratedActivityRow[];
  /** Present only when the loaded window reached its repeatable-read high-water mark. */
  readonly resumeCursor?: string;
  readonly title?: string;
  readonly description: string;
  readonly emptyMessage: string;
  readonly nextHref?: string;
  readonly latestHref?: string;
  readonly actorHref?: (row: HydratedActivityRow) => string | undefined;
  readonly resourceHref?: (row: HydratedActivityRow) => string | undefined;
  readonly referenceHref?: (reference: ActivityReference) => string | undefined;
}

/**
 * Latest ordered notification window. The opaque high-water cursor is retained as DOM state for
 * progressive realtime enhancement, but it is never decoded or presented as a page number.
 */
export function ActivitySnapshot({
  rows,
  resumeCursor,
  title = "Latest changes",
  description,
  emptyMessage,
  nextHref,
  latestHref,
  actorHref,
  resourceHref,
  referenceHref,
}: ActivitySnapshotProps) {
  return (
    <section
      aria-labelledby="activity-snapshot-title"
      className={styles.activityPanel}
      data-activity-resume-cursor={resumeCursor}
      data-activity-resume-ready={resumeCursor === undefined ? "false" : "true"}
    >
      <header className={styles.sectionHeader}>
        <div>
          <p className="eyebrow">Ordered activity</p>
          <h2 id="activity-snapshot-title">{title}</h2>
          <p>{description}</p>
        </div>
        <div className={styles.snapshotStatus}>
          <span aria-hidden="true" className={styles.statusDot} />
          {resumeCursor === undefined ? "More history pending" : "Resume anchor ready"}
        </div>
      </header>

      {rows.length === 0 ? (
        <ActivityFeedEmpty message={emptyMessage} />
      ) : (
        <ActivityFeedList>
          {rows.map((row) => (
            <HydratedActivityItem
              actorHref={actorHref?.(row)}
              key={`${row.activity.sequence}:${row.kind}:${row.activity.resourceId}`}
              referenceHref={referenceHref}
              resourceHref={resourceHref?.(row)}
              row={row}
            />
          ))}
        </ActivityFeedList>
      )}

      {nextHref === undefined && latestHref === undefined ? null : (
        <CursorPagination
          ariaLabel="Activity history pages"
          nextHref={nextHref}
          nextLabel="Continue forward"
          pageLabel="Canonical sequence order"
          previousHref={latestHref}
          previousLabel="Return to latest"
        />
      )}
    </section>
  );
}

export function FeedContractNote({ children }: { readonly children: ReactNode }) {
  return (
    <aside className={styles.contractNote}>
      <span aria-hidden="true">i</span>
      <p>{children}</p>
    </aside>
  );
}

function joinClassNames(...values: ReadonlyArray<string | undefined>): string {
  return values.filter((value): value is string => value !== undefined && value !== "").join(" ");
}
