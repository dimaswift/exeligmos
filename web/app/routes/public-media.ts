import type { Route } from "./+types/public-media";
import { backendApiBaseUrl } from "~/lib/backend.server";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const FORWARDED_HEADERS = [
  "Accept-Ranges",
  "Cache-Control",
  "Content-Length",
  "Content-Range",
  "Content-Type",
  "ETag",
  "Last-Modified",
  "X-Content-SHA256",
] as const;

/** Same-origin streaming bridge for public record media, including byte ranges. */
export async function loader({ params, request }: Route.LoaderArgs) {
  if (!UUID.test(params.mediaId)) {
    throw new Response("Media not found.", { status: 404, statusText: "Not Found" });
  }
  const headers = new Headers();
  const range = request.headers.get("Range");
  if (range !== null) headers.set("Range", range);

  const response = await fetch(
    new URL(`/v1/public/media/${encodeURIComponent(params.mediaId)}/content`, backendApiBaseUrl()),
    { headers, signal: request.signal },
  );
  if (!response.ok && response.status !== 206) {
    throw new Response(response.status === 404 ? "Media not found." : "Media is unavailable.", {
      status: response.status,
      statusText: response.statusText,
    });
  }
  const forwarded = new Headers();
  for (const name of FORWARDED_HEADERS) {
    const value = response.headers.get(name);
    if (value !== null) forwarded.set(name, value);
  }
  forwarded.set("X-Content-Type-Options", "nosniff");
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers: forwarded,
  });
}
