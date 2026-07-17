import { data, Form, redirect, useActionData, useNavigation, useSearchParams } from "react-router";

import type { Route } from "./+types/tags";
import {
  createManagedTag,
  deleteManagedTag,
  listManagedTags,
  updateManagedTag,
} from "~/features/management/management.server";
import { assertSameOrigin, BackendRequestError } from "~/lib/auth.server";
import { readRequestAuth } from "~/lib/auth-boundary.server";
import { throwRouteError } from "~/lib/route-errors.server";

import styles from "./management.module.css";

export const meta: Route.MetaFunction = () => [{ title: "Tags · Exeligmos" }];

export async function loader({ context, request }: Route.LoaderArgs) {
  try {
    const auth = readRequestAuth(context).auth;
    return { tags: (await listManagedTags(auth, request.signal)).data };
  } catch (error) {
    return throwRouteError(error, request, { clearInvalidAuth: true });
  }
}

export async function action({ context, request }: Route.ActionArgs) {
  assertSameOrigin(request);
  const auth = readRequestAuth(context).auth;
  const form = await request.formData();
  const intent = text(form, "intent");
  try {
    if (intent === "create") {
      await createManagedTag(auth, {
        name: requiredText(form, "name"),
        ...(optionalText(form, "color") === undefined
          ? {}
          : { color: optionalText(form, "color") }),
        ...(optionalText(form, "emoji") === undefined
          ? {}
          : { emoji: optionalText(form, "emoji") }),
        sortOrder: integer(form, "sortOrder"),
        metadata: {},
      });
    } else if (intent === "update") {
      const tagId = requiredText(form, "tagId");
      await updateManagedTag(auth, tagId, integer(form, "revision"), {
        name: requiredText(form, "name"),
        color: optionalText(form, "color") ?? null,
        emoji: optionalText(form, "emoji") ?? null,
        sortOrder: integer(form, "sortOrder"),
      });
    } else if (intent === "delete") {
      await deleteManagedTag(auth, requiredText(form, "tagId"), integer(form, "revision"));
    } else {
      return data({ error: "Unknown tag operation." }, { status: 400 });
    }
    return redirect(`/tags?saved=${encodeURIComponent(intent)}`);
  } catch (error) {
    if (error instanceof BackendRequestError) {
      return data({ error: error.message }, { status: error.status });
    }
    if (error instanceof Response) throw error;
    return data(
      { error: error instanceof Error ? error.message : "Tag operation failed." },
      { status: 400 },
    );
  }
}

export default function Tags({ loaderData }: Route.ComponentProps) {
  const actionData = useActionData<typeof action>();
  const navigation = useNavigation();
  const [searchParams] = useSearchParams();
  const busy = navigation.state === "submitting";
  return (
    <main className={styles.page}>
      <header className={styles.header}>
        <div>
          <h1>Tags</h1>
          <p>Create and maintain the taxonomy used by records.</p>
        </div>
      </header>
      {searchParams.has("saved") ? <p className={styles.notice}>Tag changes saved.</p> : null}
      {actionData?.error === undefined ? null : (
        <p className={styles.error} role="alert">
          {actionData.error}
        </p>
      )}
      <section className={styles.panel}>
        <h2>New tag</h2>
        <TagForm busy={busy} intent="create" />
      </section>
      {loaderData.tags.length === 0 ? (
        <p className={styles.empty}>No tags yet.</p>
      ) : (
        <ul className={styles.list}>
          {loaderData.tags.map((tag) => (
            <li className={styles.item} key={tag.id}>
              <div className={styles.itemHeader}>
                <div className={styles.identity}>
                  <span className={styles.emoji}>{tag.emoji ?? "#"}</span>
                  <div>
                    <h2>{tag.name}</h2>
                    <p className={styles.meta}>
                      order {tag.sortOrder} · revision {tag.revision}
                    </p>
                  </div>
                </div>
                {tag.color === undefined ? null : (
                  <span
                    aria-label={tag.color}
                    style={{ background: tag.color, borderRadius: "50%", width: 18, height: 18 }}
                  />
                )}
              </div>
              <details>
                <summary>Edit tag</summary>
                <TagForm busy={busy} intent="update" tag={tag} />
              </details>
              <details>
                <summary>Delete tag</summary>
                <Form method="post">
                  <input name="intent" type="hidden" value="delete" />
                  <input name="tagId" type="hidden" value={tag.id} />
                  <input name="revision" type="hidden" value={tag.revision} />
                  <button className={styles.danger} disabled={busy} type="submit">
                    Delete permanently
                  </button>
                </Form>
              </details>
            </li>
          ))}
        </ul>
      )}
    </main>
  );
}

function TagForm({
  busy,
  intent,
  tag,
}: {
  readonly busy: boolean;
  readonly intent: "create" | "update";
  readonly tag?: Route.ComponentProps["loaderData"]["tags"][number];
}) {
  return (
    <Form className={styles.form} method="post">
      <input name="intent" type="hidden" value={intent} />
      {tag === undefined ? null : (
        <>
          <input name="tagId" type="hidden" value={tag.id} />
          <input name="revision" type="hidden" value={tag.revision} />
        </>
      )}
      <label>
        Name
        <input defaultValue={tag?.name} maxLength={80} name="name" required />
      </label>
      <label>
        Emoji
        <input defaultValue={tag?.emoji} maxLength={32} name="emoji" />
      </label>
      <label>
        Color
        <input defaultValue={tag?.color ?? "#8bd7c1"} name="color" pattern="#[0-9A-Fa-f]{6}" />
      </label>
      <label>
        Sort order
        <input defaultValue={tag?.sortOrder ?? 0} name="sortOrder" step="1" type="number" />
      </label>
      <div className={styles.actions}>
        <button className={styles.button} disabled={busy} type="submit">
          {busy ? "Saving…" : intent === "create" ? "Create tag" : "Save tag"}
        </button>
      </div>
    </Form>
  );
}

function text(form: FormData, name: string) {
  const value = form.get(name);
  return typeof value === "string" ? value : "";
}
function requiredText(form: FormData, name: string) {
  const value = text(form, name).trim();
  if (value === "") throw new Error(`${name} is required.`);
  return value;
}
function optionalText(form: FormData, name: string) {
  return text(form, name).trim() || undefined;
}
function integer(form: FormData, name: string) {
  const value = Number(text(form, name));
  if (!Number.isInteger(value)) throw new Error(`${name} must be an integer.`);
  return value;
}
