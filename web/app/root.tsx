import {
  isRouteErrorResponse,
  Links,
  Meta,
  Outlet,
  Scripts,
  ScrollRestoration,
} from "react-router";

import type { Route } from "./+types/root";
import "./styles/tokens.css";
import "./styles/global.css";

export const meta: Route.MetaFunction = () => [
  { title: "Exeligmos" },
  {
    name: "description",
    content: "A temporal analytics workspace for records, events, and relationships.",
  },
];

export function Layout({ children }: { readonly children: React.ReactNode }) {
  return (
    <html lang="en">
      <head>
        <meta charSet="utf-8" />
        <meta content="width=device-width, initial-scale=1" name="viewport" />
        <link href="/favicon.svg" rel="icon" type="image/svg+xml" />
        <Meta />
        <Links />
      </head>
      <body>
        {children}
        <ScrollRestoration />
        <Scripts />
      </body>
    </html>
  );
}

export default function Root() {
  return <Outlet />;
}

export function ErrorBoundary({ error }: Route.ErrorBoundaryProps) {
  let title = "Unexpected error";
  let detail = "The request could not be completed.";

  if (isRouteErrorResponse(error)) {
    title = error.status === 404 ? "Page not found" : `${error.status} ${error.statusText}`;
    detail = typeof error.data === "string" ? error.data : detail;
  } else if (import.meta.env.DEV && error instanceof Error) {
    detail = error.message;
  }

  return (
    <main className="error-page">
      <p className="eyebrow">Exeligmos</p>
      <h1>{title}</h1>
      <p>{detail}</p>
      <a href="/">Return to the workspace</a>
    </main>
  );
}
