import { createContext, useContext, useMemo, type ReactNode } from "react";

import {
  DEFAULT_SAROS_PULSE_ANCHOR,
  sarosPulseAnchorInterval,
  sarosPulseTickReading,
  type SarosInterval,
  type SarosPulseTickReading,
} from "@exeligmos/temporal-core";

interface SarosPulseContextValue {
  readonly anchorSaros: number;
  readonly intervals: readonly SarosInterval[];
  readonly observedAt: number;
}

const SarosPulseContext = createContext<SarosPulseContextValue | undefined>(undefined);

export function resolveSarosPulseAnchor(value: unknown): number {
  return sarosPulseAnchorValue(value) ?? DEFAULT_SAROS_PULSE_ANCHOR;
}

export function sarosPulseAnchorValue(value: unknown): number | undefined {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 1 && value <= 180
    ? value
    : undefined;
}

export function SarosPulseProvider({
  anchorSaros = DEFAULT_SAROS_PULSE_ANCHOR,
  children,
  intervals,
  observedAt,
}: SarosPulseContextValue & { readonly children: ReactNode }) {
  const resolvedAnchor = resolveSarosPulseAnchor(anchorSaros);
  const value = useMemo(
    () => ({ anchorSaros: resolvedAnchor, intervals, observedAt }),
    [resolvedAnchor, intervals, observedAt],
  );
  return <SarosPulseContext value={value}>{children}</SarosPulseContext>;
}

export function useSarosPulseContext(): SarosPulseContextValue | undefined {
  return useContext(SarosPulseContext);
}

/** Resolve one static record/header tick from the shell's preloaded eclipse intervals. */
export function useSarosPulseTickAt(
  instantEpochSeconds: number,
  anchorSaros?: number,
): SarosPulseTickReading | undefined {
  const context = useSarosPulseContext();
  const resolvedAnchor = resolveSarosPulseAnchor(anchorSaros ?? context?.anchorSaros);
  const interval = useMemo(
    () =>
      context === undefined || !Number.isFinite(instantEpochSeconds)
        ? undefined
        : sarosPulseAnchorInterval(context.intervals, instantEpochSeconds, resolvedAnchor),
    [context, instantEpochSeconds, resolvedAnchor],
  );
  return useMemo(
    () =>
      interval === undefined ? undefined : sarosPulseTickReading(interval, instantEpochSeconds),
    [instantEpochSeconds, interval],
  );
}
