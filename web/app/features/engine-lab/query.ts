import { canonicalTemporalEngine } from "@exeligmos/temporal-core";

export const DEFAULT_ENGINE_LAB_QUERY = {
  address: "1422222",
  depth: 7,
  previous: "0",
  next: "512",
  instant: "256",
  clockDepth: 3,
} as const;

export interface EngineLabQuery {
  readonly address: string;
  readonly depth: number;
  readonly previous: string;
  readonly next: string;
  readonly instant: string;
  readonly clockDepth: number;
  readonly warnings: readonly string[];
}

/** Parse a reproducible lab state without reading environment, locale, or wall-clock data. */
export function parseEngineLabQuery(requestUrl: string): EngineLabQuery {
  const params = new URL(requestUrl).searchParams;
  const warnings: string[] = [];

  return {
    address: params.has("address")
      ? (params.get("address") ?? "")
      : DEFAULT_ENGINE_LAB_QUERY.address,
    depth: readPresentationDepth(params, warnings),
    previous: params.get("previous") ?? DEFAULT_ENGINE_LAB_QUERY.previous,
    next: params.get("next") ?? DEFAULT_ENGINE_LAB_QUERY.next,
    instant: params.get("instant") ?? DEFAULT_ENGINE_LAB_QUERY.instant,
    clockDepth: readCalculationDepth(params, warnings),
    warnings,
  };
}

function readPresentationDepth(params: URLSearchParams, warnings: string[]): number {
  const raw = params.get("depth");
  if (raw === null) {
    return DEFAULT_ENGINE_LAB_QUERY.depth;
  }
  const value = Number(raw);
  if (!Number.isSafeInteger(value)) {
    warnings.push(
      `Invalid glyph depth “${raw}” was replaced with ${DEFAULT_ENGINE_LAB_QUERY.depth}.`,
    );
    return DEFAULT_ENGINE_LAB_QUERY.depth;
  }
  return canonicalTemporalEngine.clampPresentationDepth(value);
}

function readCalculationDepth(params: URLSearchParams, warnings: string[]): number {
  const raw = params.get("clockDepth");
  if (raw === null) {
    return DEFAULT_ENGINE_LAB_QUERY.clockDepth;
  }
  const value = Number(raw);
  try {
    return canonicalTemporalEngine.assertCalculationDepth(value);
  } catch {
    warnings.push(
      `Invalid clock depth “${raw}” was replaced with ${DEFAULT_ENGINE_LAB_QUERY.clockDepth}.`,
    );
    return DEFAULT_ENGINE_LAB_QUERY.clockDepth;
  }
}
