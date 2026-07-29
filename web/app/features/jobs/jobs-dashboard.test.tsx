import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import { JobsDashboard } from "./jobs-dashboard";
import type { Job, JobCurrentItem } from "./jobs.server";

describe("jobs dashboard", () => {
  it("renders active progress and the current media stage compactly", () => {
    const markup = renderToStaticMarkup(
      <JobsDashboard
        jobs={{
          hasMore: false,
          data: [
            job({
              activity: "active",
              totalItems: 4,
              processedItems: 2,
              remainingItems: 2,
              totalRecords: 2,
              processedRecords: 1,
              currentItem: item({
                relativePath: "PHOTO/IMG_0042.JPG",
                kind: "photo",
                stage: "describing",
                status: "processing",
                capturedAt: "2026-07-29T10:03:00.000Z",
              }),
            }),
          ],
        }}
      />,
    );

    expect(markup).toContain("Worker active");
    expect(markup).toContain("2 of 4 media processed");
    expect(markup).toContain("1</strong> / 2 records created");
    expect(markup).toContain("PHOTO/IMG_0042.JPG");
    expect(markup).toContain("Describing");
    expect(markup).toContain("📷");
    expect(markup).toContain('max="4"');
    expect(markup).toContain('value="2"');
  });

  it("shows idle and empty states without inventing queued work", () => {
    const markup = renderToStaticMarkup(<JobsDashboard jobs={{ data: [], hasMore: false }} />);

    expect(markup).toContain("No active job");
    expect(markup).toContain("No server job is processing");
    expect(markup).toContain("4m31s Saros grouping window");
    expect(markup).toContain("THUMB_CAM has no pending media.");
    expect(markup).toContain("0 jobs visible");
  });

  it("surfaces failed counts and the current item error", () => {
    const markup = renderToStaticMarkup(
      <JobsDashboard
        jobs={{
          hasMore: false,
          data: [
            job({
              status: "failed",
              failedItems: 2,
              failedRecords: 1,
              remainingItems: 0,
              currentItem: item({
                relativePath: "AUDIO/REC_0007.WAV",
                kind: "audio",
                stage: "speech_to_text",
                status: "failed",
                capturedAt: "2026-07-29T10:03:00.000Z",
                error: "Whisper could not decode the recording.",
              }),
            }),
          ],
        }}
      />,
    );

    expect(markup).toContain("No active job");
    expect(markup).toContain(">2</strong>");
    expect(markup).toContain("Whisper could not decode the recording.");
    expect(markup).toContain("Speech to text");
    expect(markup).toContain("🎙️");
    expect(markup).toContain('data-tone="danger"');
  });

  it("keeps the last snapshot visible when polling is temporarily unavailable", () => {
    const markup = renderToStaticMarkup(
      <JobsDashboard
        jobs={{ data: [job({ activity: "active" })], hasMore: false }}
        pollUnavailable
      />,
    );

    expect(markup).toContain("Connection interrupted · showing last update");
    expect(markup).toContain("1 of 3 media processed");
  });
});

function job(overrides: Partial<Job> = {}): Job {
  return {
    id: "01234567-89ab-cdef-0123-456789abcdef",
    userId: "11111111-1111-4111-8111-111111111111",
    deviceId: "22222222-2222-4222-8222-222222222222",
    source: { volume: "THUMB_CAM" },
    config: {},
    status: "processing",
    activity: "idle",
    totalItems: 3,
    processedItems: 1,
    failedItems: 0,
    remainingItems: 2,
    totalRecords: 1,
    processedRecords: 0,
    failedRecords: 0,
    remainingRecords: 1,
    currentItem: null,
    revision: 1,
    createdAt: "2026-07-29T10:00:00.000Z",
    startedAt: "2026-07-29T10:00:01.000Z",
    updatedAt: "2026-07-29T10:01:00.000Z",
    ...overrides,
  };
}

function item(overrides: Partial<JobCurrentItem> = {}): JobCurrentItem {
  return {
    id: "33333333-3333-4333-8333-333333333333",
    sourceKey: "a".repeat(64),
    groupKey: "b".repeat(64),
    relativePath: "PHOTO/IMG_0001.JPG",
    kind: "photo",
    capturedAt: "2026-07-29T10:00:00.000Z",
    byteLength: 1_024,
    contentSha256: "c".repeat(64),
    status: "processing",
    stage: "processing",
    createdAt: "2026-07-29T10:00:00.000Z",
    updatedAt: "2026-07-29T10:00:01.000Z",
    ...overrides,
  };
}
