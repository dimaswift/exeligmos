import { data, Form, redirect, useActionData, useNavigation, useSearchParams } from "react-router";

import type { Route } from "./+types/login";
import { assertSameOrigin, BackendRequestError, loginWithPassword } from "~/lib/auth.server";
import { safeReturnTo } from "~/lib/navigation";
import { commitAuthSession, readAuthSession, toStoredAuthSession } from "~/lib/session.server";
import styles from "./login.module.css";

export const meta: Route.MetaFunction = () => [{ title: "Sign in · Exeligmos" }];

export async function loader({ request }: Route.LoaderArgs) {
  const auth = await readAuthSession(request);
  if (auth !== null) {
    const url = new URL(request.url);
    throw redirect(safeReturnTo(url.searchParams.get("returnTo")));
  }
  return null;
}

export async function action({ request }: Route.ActionArgs) {
  assertSameOrigin(request);
  const form = await request.formData();
  const login = form.get("login");
  const password = form.get("password");
  const returnTo = safeReturnTo(form.get("returnTo"));

  if (
    typeof login !== "string" ||
    typeof password !== "string" ||
    login === "" ||
    password === ""
  ) {
    return data({ error: "Enter both login and password." }, { status: 400 });
  }

  try {
    const backendSession = await loginWithPassword(login, password);
    const auth = toStoredAuthSession(backendSession);
    return redirect(returnTo, {
      headers: { "Set-Cookie": await commitAuthSession(request, auth) },
    });
  } catch (error) {
    if (error instanceof BackendRequestError) {
      const status = error.status >= 400 && error.status < 500 ? error.status : 502;
      return data({ error: error.message }, { status });
    }
    return data({ error: "The authentication service is unavailable." }, { status: 502 });
  }
}

export default function Login() {
  const actionData = useActionData<typeof action>();
  const navigation = useNavigation();
  const [searchParams] = useSearchParams();
  const pending = navigation.state === "submitting";

  return (
    <main className={styles.page}>
      <section className={styles.introduction}>
        <p className="eyebrow">Exeligmos analytics</p>
        <h1>Inspect time as data.</h1>
        <p>
          A desktop workspace for records, events, temporal patterns, and the relationships between
          them.
        </p>
        <a href="/explore">Explore the public feed</a>
      </section>

      <section className={styles.card}>
        <p className="eyebrow">Private workspace</p>
        <h2>Sign in</h2>
        <Form action="/login" method="post">
          <input name="returnTo" type="hidden" value={safeReturnTo(searchParams.get("returnTo"))} />
          <label>
            Login
            <input autoComplete="username" name="login" required type="text" />
          </label>
          <label>
            Password
            <input autoComplete="current-password" name="password" required type="password" />
          </label>
          {actionData?.error === undefined ? null : (
            <p aria-live="polite" className={styles.error} role="alert">
              {actionData.error}
            </p>
          )}
          <button disabled={pending} type="submit">
            {pending ? "Signing in…" : "Sign in"}
          </button>
        </Form>
      </section>
    </main>
  );
}
