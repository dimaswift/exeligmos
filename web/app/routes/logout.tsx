import { redirect } from "react-router";

import type { Route } from "./+types/logout";
import { assertSameOrigin, revokeBackendSession } from "~/lib/auth.server";
import { destroyAuthSession, readAuthSession } from "~/lib/session.server";

export function loader() {
  return redirect("/");
}

export async function action({ request }: Route.ActionArgs) {
  assertSameOrigin(request);
  const auth = await readAuthSession(request);
  if (auth !== null) {
    try {
      await revokeBackendSession(auth);
    } catch {
      // Local sign-out must still complete if the backend is temporarily unavailable.
    }
  }
  return redirect("/login", {
    headers: { "Set-Cookie": await destroyAuthSession(request) },
  });
}
