import { describe, expect, it, vi } from "vitest";

import {
  ACTIVE_JOBS_POLL_INTERVAL_MS,
  IDLE_JOBS_POLL_INTERVAL_MS,
  startJobsPolling,
  type JobsPollingEnvironment,
} from "./jobs-polling";

describe("jobs polling", () => {
  it("uses the active and idle polling intervals", async () => {
    const activeHarness = pollingHarness();
    const activeRefresh = vi.fn(() => Promise.resolve());
    const stopActive = startJobsPolling(
      {
        isActive: () => true,
        isBusy: () => false,
        refresh: activeRefresh,
      },
      activeHarness.environment,
    );

    expect(activeHarness.latest().delay).toBe(ACTIVE_JOBS_POLL_INTERVAL_MS);
    await activeHarness.latest().callback();
    expect(activeRefresh).toHaveBeenCalledTimes(1);
    expect(activeHarness.latest().delay).toBe(ACTIVE_JOBS_POLL_INTERVAL_MS);
    stopActive();

    const idleHarness = pollingHarness();
    const stopIdle = startJobsPolling(
      {
        isActive: () => false,
        isBusy: () => false,
        refresh: () => Promise.resolve(),
      },
      idleHarness.environment,
    );

    expect(idleHarness.latest().delay).toBe(IDLE_JOBS_POLL_INTERVAL_MS);
    stopIdle();
  });

  it("pauses while hidden and refreshes immediately when visible again", async () => {
    const harness = pollingHarness();
    const refresh = vi.fn(() => Promise.resolve());
    const stop = startJobsPolling(
      {
        isActive: () => true,
        isBusy: () => false,
        refresh,
      },
      harness.environment,
    );
    const initial = harness.latest();

    harness.setVisible(false);
    harness.visibilityChanged();
    expect(initial.cancelled).toBe(true);
    expect(refresh).not.toHaveBeenCalled();

    harness.setVisible(true);
    harness.visibilityChanged();
    await flushMicrotasks();
    expect(refresh).toHaveBeenCalledTimes(1);
    expect(harness.latest().delay).toBe(ACTIVE_JOBS_POLL_INTERVAL_MS);
    stop();
  });

  it("never starts an overlapping refresh", async () => {
    const harness = pollingHarness();
    let finishRefresh: (() => void) | undefined;
    const refresh = vi.fn(
      () =>
        new Promise<void>((resolve) => {
          finishRefresh = resolve;
        }),
    );
    const stop = startJobsPolling(
      {
        isActive: () => true,
        isBusy: () => false,
        refresh,
      },
      harness.environment,
    );

    const firstTick = harness.latest().callback();
    expect(refresh).toHaveBeenCalledTimes(1);

    harness.visibilityChanged();
    await flushMicrotasks();
    expect(refresh).toHaveBeenCalledTimes(1);

    await harness.latest().callback();
    expect(refresh).toHaveBeenCalledTimes(1);

    finishRefresh?.();
    await firstTick;
    stop();
  });

  it("continues polling after a transient refresh failure", async () => {
    const harness = pollingHarness();
    const refresh = vi.fn(() => Promise.reject(new Error("temporarily unavailable")));
    const stop = startJobsPolling(
      {
        isActive: () => true,
        isBusy: () => false,
        refresh,
      },
      harness.environment,
    );

    await harness.latest().callback();

    expect(refresh).toHaveBeenCalledTimes(1);
    expect(harness.latest().delay).toBe(ACTIVE_JOBS_POLL_INTERVAL_MS);
    stop();
  });
});

interface ScheduledPoll {
  readonly callback: () => Promise<void>;
  readonly delay: number;
  cancelled: boolean;
}

function pollingHarness() {
  let visible = true;
  let visibilityListener: () => void = () => undefined;
  const scheduled: ScheduledPoll[] = [];
  const environment: JobsPollingEnvironment = {
    isVisible: () => visible,
    schedule: (callback, delay) => {
      const poll = { callback, delay, cancelled: false };
      scheduled.push(poll);
      return poll;
    },
    cancel: (handle) => {
      (handle as ScheduledPoll).cancelled = true;
    },
    onVisibilityChange: (listener) => {
      visibilityListener = listener;
      return () => {
        visibilityListener = () => undefined;
      };
    },
  };
  return {
    environment,
    latest: () => {
      const latest = scheduled.at(-1);
      if (latest === undefined) throw new Error("Expected a scheduled poll.");
      return latest;
    },
    setVisible: (next: boolean) => {
      visible = next;
    },
    visibilityChanged: () => visibilityListener(),
  };
}

async function flushMicrotasks() {
  await Promise.resolve();
  await Promise.resolve();
}
