import { Link, NavLink, Outlet } from "react-router";

import styles from "./public-shell.module.css";

export function PublicShell() {
  return (
    <div className={styles.shell}>
      <a className={styles.skipLink} href="#public-content">
        Skip to content
      </a>
      <header className={styles.header}>
        <Link aria-label="Exeligmos public activity" className={styles.brand} to="/explore">
          <span aria-hidden="true" className={styles.brandMark} />
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
  );
}
