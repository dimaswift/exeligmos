import { Form, NavLink, Outlet } from "react-router";

import type { User } from "@exeligmos/api-client";

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

const systemNavigation = [{ to: "/lab/engines", label: "Engine lab" }] as const;

export function AppShell({ user }: { readonly user: User }) {
  return (
    <div className={styles.shell}>
      <aside className={styles.sidebar}>
        <a className={styles.brand} href="/">
          <span aria-hidden="true" className={styles.brandMark} />
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

      <aside aria-label="Inspector" className={styles.inspector}>
        <p className="eyebrow">Inspector</p>
        <h2>Selection</h2>
        <p>
          Records, events, users, and typed references will open here without losing analytical
          context.
        </p>
        <div className={styles.inspectorStatus}>No entity selected</div>
      </aside>
    </div>
  );
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
