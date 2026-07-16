import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import { ActivitySnapshot, FeedWorkspace, ResourceLaneGrid } from "./feed-workspace";

describe("feed workspace", () => {
  it("exposes a high-water resume cursor only when the snapshot is caught up", () => {
    const markup = renderToStaticMarkup(
      <ActivitySnapshot
        description="Latest public changes."
        emptyMessage="No changes."
        resumeCursor="opaque-high-water"
        rows={[]}
      />,
    );

    expect(markup).toContain('data-activity-resume-cursor="opaque-high-water"');
    expect(markup).toContain('data-activity-resume-ready="true"');
    expect(markup).toContain("Resume anchor ready");
  });

  it("marks a partial history page as pending and keeps continuation route-owned", () => {
    const markup = renderToStaticMarkup(
      <ActivitySnapshot
        description="Historical changes."
        emptyMessage="No changes."
        nextHref="?activityCursor=opaque-next"
        rows={[]}
      />,
    );

    expect(markup).toContain('data-activity-resume-ready="false"');
    expect(markup).toContain("More history pending");
    expect(markup).toContain("?activityCursor=opaque-next");
  });

  it("renders the shared analytics page and lane grid boundaries", () => {
    const markup = renderToStaticMarkup(
      <FeedWorkspace eyebrow="Network" summary="Summary" title="Global feed">
        <ResourceLaneGrid>
          <section>Records</section>
          <section>Events</section>
        </ResourceLaneGrid>
      </FeedWorkspace>,
    );

    expect(markup).toContain("Global feed");
    expect(markup).toContain("Records");
    expect(markup).toContain("Events");
  });
});
