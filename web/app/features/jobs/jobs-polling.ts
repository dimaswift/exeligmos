import { useEffect, useEffectEvent } from "react";

export const ACTIVE_JOBS_POLL_INTERVAL_MS = 2_000;
export const IDLE_JOBS_POLL_INTERVAL_MS = 10_000;

export interface JobsPollingOptions {
  readonly isActive: () => boolean;
  readonly isBusy: () => boolean;
  readonly refresh: () => Promise<void>;
}

export interface JobsPollingEnvironment {
  readonly isVisible: () => boolean;
  readonly schedule: (callback: () => Promise<void>, delayMilliseconds: number) => unknown;
  readonly cancel: (handle: unknown) => void;
  readonly onVisibilityChange: (listener: () => void) => () => void;
}

const browserPollingEnvironment: JobsPollingEnvironment = {
  isVisible: () => document.visibilityState !== "hidden",
  schedule: (callback, delayMilliseconds) =>
    window.setTimeout(() => {
      void callback();
    }, delayMilliseconds),
  cancel: (handle) => window.clearTimeout(handle as number),
  onVisibilityChange: (listener) => {
    document.addEventListener("visibilitychange", listener);
    return () => document.removeEventListener("visibilitychange", listener);
  },
};

export function startJobsPolling(
  options: JobsPollingOptions,
  environment: JobsPollingEnvironment = browserPollingEnvironment,
): () => void {
  let stopped = false;
  let inFlight = false;
  let timer: unknown;

  const clearTimer = () => {
    if (timer === undefined) return;
    environment.cancel(timer);
    timer = undefined;
  };

  const schedule = () => {
    clearTimer();
    if (stopped || !environment.isVisible()) return;
    const delay = options.isActive() ? ACTIVE_JOBS_POLL_INTERVAL_MS : IDLE_JOBS_POLL_INTERVAL_MS;
    timer = environment.schedule(tick, delay);
  };

  const refresh = async () => {
    if (stopped || inFlight || options.isBusy() || !environment.isVisible()) return;
    inFlight = true;
    try {
      await options.refresh();
    } finally {
      inFlight = false;
    }
  };

  async function tick() {
    timer = undefined;
    try {
      await refresh();
    } catch {
      // Keep the last successful snapshot and continue after transient failures.
    } finally {
      schedule();
    }
  }

  const visibilityChanged = () => {
    clearTimer();
    if (!environment.isVisible() || stopped) return;
    void (async () => {
      try {
        await refresh();
      } catch {
        // The regular poll will retry when the backend is available again.
      } finally {
        schedule();
      }
    })();
  };

  const unsubscribeVisibility = environment.onVisibilityChange(visibilityChanged);
  schedule();

  return () => {
    stopped = true;
    clearTimer();
    unsubscribeVisibility();
  };
}

export function useJobsPolling(active: boolean, busy: boolean, refresh: () => Promise<void>): void {
  const isBusy = useEffectEvent(() => busy);
  const refreshLatest = useEffectEvent(refresh);

  useEffect(
    () =>
      startJobsPolling({
        isActive: () => active,
        isBusy,
        refresh: refreshLatest,
      }),
    [active],
  );
}
