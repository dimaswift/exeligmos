import { index, layout, route, type RouteConfig } from "@react-router/dev/routes";

export default [
  route("login", "routes/login.tsx"),
  route("logout", "routes/logout.tsx"),
  route("media/:mediaId", "routes/public-media.ts"),
  layout("routes/public-layout.tsx", [
    route("explore", "routes/public-feed.tsx"),
    route("r/:recordId", "routes/public-record.tsx"),
    route("u/:login", "routes/public-profile.tsx"),
  ]),
  layout("routes/app-layout.tsx", [
    index("routes/dashboard.tsx"),
    route("feed", "routes/feed.tsx"),
    route("feed/following", "routes/following-feed.tsx"),
    route("feed/global", "routes/global-feed.tsx"),
    route("records", "routes/records.tsx"),
    route("records/:recordId", "routes/record-detail.tsx"),
    route("events", "routes/events.tsx"),
    route("tags", "routes/tags.tsx"),
    route("lab/engines", "routes/engine-lab.tsx"),
    route("references/:entityType/:entityId", "routes/reference-inspector.tsx"),
  ]),
] satisfies RouteConfig;
