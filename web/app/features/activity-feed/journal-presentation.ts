import { createOctalGlyph, type GlyphModel } from "@exeligmos/glyph-core";
import { canonicalTemporalEngine } from "@exeligmos/temporal-core";

import type { ActivityRecord } from "./model";
import { activityPresentationConfig } from "./presentation-config";

export interface JournalSpikePresentation {
  readonly id: string;
  readonly saros: number;
  readonly unixTimestamp: number;
  readonly rarityId: string;
  readonly title: string;
  readonly glyph: GlyphModel;
  readonly isClosest: boolean;
}

export interface JournalRecordPresentation {
  readonly emoji: string;
  readonly text: string;
  readonly temporalTitle: string;
  readonly waveLabel?: string;
  readonly durationLabel?: string;
  readonly primaryGlyph?: GlyphModel;
  readonly spikes: readonly JournalSpikePresentation[];
}

interface JournalContext {
  readonly unixTimestamp?: number;
  readonly energyPercent?: number;
  readonly momentum?: number;
  readonly directionRawValue?: string;
  readonly closestSarosPhase?: JournalPhase;
  readonly spikes?: readonly JournalSpike[];
}

interface JournalPhase {
  readonly saros?: number;
  readonly octalAddress?: string;
  readonly harmonicDepth?: number;
  readonly rarityRawValue?: string;
}

interface JournalSpike extends JournalPhase {
  readonly unixTimestamp?: number;
}

const DEFAULT_EMOJI = "◉";

/** Safely projects the first-party journal payload into app-like feed semantics. */
export function journalRecordPresentation(record: ActivityRecord): JournalRecordPresentation {
  if (record.visibility === "private") {
    return {
      emoji: "◇",
      text: "",
      temporalTitle: "Private record",
      spikes: [],
    };
  }

  const payload = record.payload as Readonly<Record<string, unknown>>;
  const context = objectValue(payload.context) as JournalContext | undefined;
  const instant = finiteNumber(context?.unixTimestamp) ?? Date.parse(record.occurredAt) / 1_000;
  const parsedSpikes = (Array.isArray(context?.spikes) ? context.spikes : [])
    .map((spike) => parseSpike(spike))
    .filter(
      (
        spike,
      ): spike is Required<
        Pick<
          JournalSpike,
          "saros" | "unixTimestamp" | "octalAddress" | "harmonicDepth" | "rarityRawValue"
        >
      > => spike !== undefined,
    );
  const closest = parsedSpikes.reduce<(typeof parsedSpikes)[number] | undefined>((best, spike) => {
    if (best === undefined) return spike;
    return Math.abs(spike.unixTimestamp - instant) < Math.abs(best.unixTimestamp - instant)
      ? spike
      : best;
  }, undefined);
  const phase = parsePhase(context?.closestSarosPhase);
  const spikes = parsedSpikes.map((spike) => {
    const descriptor = safeRarityDescriptor(spike.rarityRawValue, spike.harmonicDepth);
    return {
      id: `${spike.saros}:${spike.unixTimestamp}:${spike.octalAddress}`,
      saros: spike.saros,
      unixTimestamp: spike.unixTimestamp,
      rarityId: descriptor.rarityId,
      title: descriptor.title,
      glyph: createOctalGlyph({
        value: spike.octalAddress,
        depth: activityPresentationConfig.glyphDepth,
        rarityId: descriptor.rarityId,
        accessibilityLabel: `Saros ${spike.saros} ${descriptor.title}`,
      }),
      isClosest: spike === closest,
    };
  });
  const closestDescriptor = closest
    ? safeRarityDescriptor(closest.rarityRawValue, closest.harmonicDepth)
    : safeRarityDescriptor("common", phase?.harmonicDepth ?? 8);

  return {
    emoji: nonBlank(payload.emoji) ?? DEFAULT_EMOJI,
    text: nonBlank(payload.text) ?? "",
    temporalTitle: closestDescriptor.title,
    waveLabel: waveLabel(context),
    durationLabel: durationLabel(record.occurredAt, record.endedAt),
    primaryGlyph:
      phase === undefined
        ? closest === undefined
          ? undefined
          : createOctalGlyph({
              value: closest.octalAddress,
              depth: activityPresentationConfig.glyphDepth,
              rarityId: closestDescriptor.rarityId,
              accessibilityLabel: closestDescriptor.title,
            })
        : createOctalGlyph({
            value: phase.octalAddress,
            depth: activityPresentationConfig.glyphDepth,
            rarityId: phase.rarityRawValue,
            accessibilityLabel: `Saros ${phase.saros} phase`,
          }),
    spikes,
  };
}

function parseSpike(
  value: unknown,
):
  | Required<
      Pick<
        JournalSpike,
        "saros" | "unixTimestamp" | "octalAddress" | "harmonicDepth" | "rarityRawValue"
      >
    >
  | undefined {
  const spike = objectValue(value);
  if (spike === undefined) return undefined;
  const phase = parsePhase(spike);
  const unixTimestamp = finiteNumber(spike.unixTimestamp);
  if (phase === undefined || unixTimestamp === undefined) return undefined;
  return { ...phase, unixTimestamp };
}

function parsePhase(
  value: JournalPhase | Readonly<Record<string, unknown>> | undefined,
):
  | Required<Pick<JournalPhase, "saros" | "octalAddress" | "harmonicDepth" | "rarityRawValue">>
  | undefined {
  if (value === undefined) return undefined;
  const saros = finiteNumber(value.saros);
  const harmonicDepth = finiteNumber(value.harmonicDepth);
  const octalAddress = nonBlank(value.octalAddress);
  const rarityRawValue = nonBlank(value.rarityRawValue) ?? "common";
  if (saros === undefined || harmonicDepth === undefined || octalAddress === undefined)
    return undefined;
  return {
    saros: Math.trunc(saros),
    harmonicDepth: Math.trunc(harmonicDepth),
    octalAddress,
    rarityRawValue,
  };
}

function safeRarityDescriptor(rarityId: string, harmonicDepth: number) {
  try {
    return canonicalTemporalEngine.rarityDescriptor({ rarityId, harmonicDepth });
  } catch {
    return canonicalTemporalEngine.rarityDescriptor({ rarityId: "common", harmonicDepth: 8 });
  }
}

function waveLabel(context: JournalContext | undefined): string | undefined {
  const energy = finiteNumber(context?.energyPercent);
  const momentum = finiteNumber(context?.momentum);
  if (energy !== undefined && energy >= 0.98) return "creeping peak";
  if (energy !== undefined && energy <= 0.2) return "wide valley";
  if (momentum === undefined) return undefined;
  const magnitude = Math.abs(momentum);
  if (magnitude < 0.001) return "flat";
  const direction =
    momentum > 0 || context?.directionRawValue === "ascending" ? "ascent" : "descent";
  const modifier =
    magnitude <= 0.002
      ? "crawling"
      : magnitude <= 0.016
        ? "slow"
        : magnitude <= 0.063
          ? "rapid"
          : direction === "ascent"
            ? "rocketing"
            : "plunging";
  return `${modifier} ${direction}`;
}

function durationLabel(start: string, end?: string): string | undefined {
  if (end === undefined) return undefined;
  const seconds = (Date.parse(end) - Date.parse(start)) / 1_000;
  if (!Number.isFinite(seconds) || seconds <= 1) return undefined;
  const hours = Math.floor(seconds / 3_600);
  const minutes = Math.floor((seconds % 3_600) / 60);
  const remainder = Math.floor(seconds % 60);
  return [
    hours > 0 ? `${hours}h` : "",
    minutes > 0 ? `${minutes}m` : "",
    remainder > 0 ? `${remainder}s` : "",
  ]
    .filter(Boolean)
    .slice(0, 2)
    .join(" ");
}

function objectValue(value: unknown): Readonly<Record<string, unknown>> | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Readonly<Record<string, unknown>>)
    : undefined;
}

function finiteNumber(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function nonBlank(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() !== "" ? value.trim() : undefined;
}
