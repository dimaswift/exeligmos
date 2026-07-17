import { Link, NavLink, Outlet } from "react-router";

import { DEFAULT_SAROS_PULSE_ANCHOR, type SarosInterval } from "@exeligmos/temporal-core";

import { LiveSarosPulseClock } from "./saros-pulse-glyph-pair";
import { SarosPulseProvider } from "~/features/temporal/saros-pulse-context";
import styles from "./public-shell.module.css";

export function PublicShell({
  sarosWindow,
}: {
  readonly sarosWindow: {
    readonly intervals: readonly SarosInterval[];
    readonly observedAt: number;
  };
}) {
  return (
    <SarosPulseProvider
      anchorSaros={DEFAULT_SAROS_PULSE_ANCHOR}
      intervals={sarosWindow.intervals}
      observedAt={sarosWindow.observedAt}
    >
      <div className={styles.shell}>
        <a className={styles.skipLink} href="#public-content">
          Skip to content
        </a>
        <header className={styles.header}>
          <Link aria-label="Exeligmos public activity" className={styles.brand} to="/explore">
            <LiveSarosPulseClock
              className={styles.brandClock}
              decorative
              intervals={sarosWindow.intervals}
              observedAt={sarosWindow.observedAt}
              size="1.1rem"
            />
            <span>Exeligmos</span>
          </Link>
          <nav aria-label="Public navigation" className={styles.navigation}>
            <NavLink
              className={({ isActive }) => `${styles.navLink} ${isActive ? styles.active : ""}`}
              end
              to="/explore"
            >
              Explore
            </NavLink>
            <Link className={styles.signIn} to="/">
              Workspace
            </Link>
          </nav>
        </header>
        <main className={styles.main} id="public-content">
          <Outlet />
        </main>
        <footer className={styles.footer}>
          <span>Public projections only</span>
          <span>Private payloads never leave their encrypted boundary.</span>
        </footer>
      </div>
    </SarosPulseProvider>
  );
}
