import { useEffect } from "react";
import { Form, NavLink, Outlet, useRevalidator } from "react-router";

import type { User } from "@exeligmos/api-client";
import type { SarosInterval } from "@exeligmos/temporal-core";

import { LiveSarosPulseClock } from "./saros-pulse-glyph-pair";
import { RealtimeSarosWindow } from "~/features/engine-lab/realtime-saros-window";
import {
  resolveSarosPulseAnchor,
  SarosPulseProvider,
} from "~/features/temporal/saros-pulse-context";
import styles from "./app-shell.module.css";

const primaryNavigation = [
  { to: "/", label: "Analytics", end: true },
  { to: "/feed", label: "My feed", end: true },
  { to: "/feed/following", label: "Following" },
  { to: "/feed/global", label: "Global" },
] as const;

const dataNavigation = [
  { to: "/records", label: "Records" },
  { to: "/events", label: "Events" },
  { to: "/tags", label: "Tags" },
] as const;

const systemNavigation = [{ to: "/lab/engines", label: "System lab" }] as const;

interface AppShellProps {
  readonly sarosWindow: {
    readonly intervals: readonly SarosInterval[];
    readonly observedAt: number;
  };
  readonly user: User;
}

export function AppShell({ sarosWindow, user }: AppShellProps) {
  useSarosIntervalBoundaryRevalidation(sarosWindow.intervals);
  const anchorSaros = resolveSarosPulseAnchor(Reflect.get(user, "sarosAnchor"));

  return (
    <SarosPulseProvider
      anchorSaros={anchorSaros}
      intervals={sarosWindow.intervals}
      observedAt={sarosWindow.observedAt}
    >
      <div className={styles.shell}>
        <aside className={styles.sidebar}>
          <a aria-label="Exeligmos analytics" className={styles.brand} href="/">
            <LiveSarosPulseClock
              anchorSaros={anchorSaros}
              className={styles.brandClock}
              decorative
              intervals={sarosWindow.intervals}
              observedAt={sarosWindow.observedAt}
              size="1.2rem"
            />
            <span>Exeligmos</span>
          </a>

          <nav aria-label="Workspace" className={styles.navigation}>
            <NavGroup items={primaryNavigation} label="Workspace" />
            <NavGroup items={dataNavigation} label="Data" />
            <NavGroup items={systemNavigation} label="System" />
          </nav>

          <div className={styles.account}>
            <span className={styles.accountName}>{user.displayName}</span>
            <span className={styles.accountLogin}>@{user.login}</span>
            <Form action="/logout" method="post">
              <button className={styles.logout} type="submit">
                Sign out
              </button>
            </Form>
          </div>
        </aside>

        <main className={styles.main}>
          <Outlet />
        </main>

        <div className={styles.inspector}>
          <RealtimeSarosWindow
            intervals={sarosWindow.intervals}
            observedAt={sarosWindow.observedAt}
          />
        </div>
      </div>
    </SarosPulseProvider>
  );
}

function useSarosIntervalBoundaryRevalidation(intervals: readonly SarosInterval[]) {
  const { revalidate } = useRevalidator();

  useEffect(() => {
    const nextBoundary = Math.min(...intervals.map((interval) => interval.next.epochSeconds));
    if (!Number.isFinite(nextBoundary)) return;

    let cancelled = false;
    let timer: number | undefined;
    const schedule = () => {
      if (cancelled) return;
      const delay = nextBoundary * 1_000 - Date.now();
      if (delay <= 0) {
        void revalidate();
        return;
      }
      timer = window.setTimeout(schedule, Math.min(delay + 50, 2_000_000_000));
    };

    schedule();
    return () => {
      cancelled = true;
      if (timer !== undefined) window.clearTimeout(timer);
    };
  }, [intervals, revalidate]);
}

function NavGroup({
  items,
  label,
}: {
  readonly items: ReadonlyArray<{
    readonly to: string;
    readonly label: string;
    readonly end?: true;
  }>;
  readonly label: string;
}) {
  return (
    <section aria-label={label} className={styles.navGroup}>
      <span className={styles.navGroupTitle}>{label}</span>
      {items.map((item) => (
        <NavLink
          className={({ isActive }) => `${styles.navLink} ${isActive ? styles.navLinkActive : ""}`}
          end={item.end}
          key={item.to}
          to={item.to}
        >
          {item.label}
        </NavLink>
      ))}
    </section>
  );
}
