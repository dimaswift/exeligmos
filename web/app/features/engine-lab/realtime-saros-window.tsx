import { useCallback, useEffect, useMemo, useRef, useState, type CSSProperties } from "react";
import { createPortal } from "react-dom";

import { canonicalCatalog } from "@exeligmos/domain-catalog";
import { createOctalGlyph } from "@exeligmos/glyph-core";
import {
  sarosRealtimeWindow,
  type RarityId,
  type SarosInterval,
  type SarosRealtimeMinimumRarity,
  type SarosRealtimePeriodId,
  type SarosRealtimeSpike,
  type SarosRealtimeWaveformSample,
} from "@exeligmos/temporal-core";
import { GlyphRenderer } from "@exeligmos/ui";

import {
  LowestRaritySelector,
  TemporalPeriodSelector,
  type LowestRarity,
  type TemporalPeriod,
} from "~/components/temporal-selectors";
import styles from "./realtime-saros-window.module.css";

interface RealtimeSarosWindowProps {
  readonly intervals: readonly SarosInterval[];
  readonly observedAt: number;
}

interface WaveMarker {
  readonly count: number;
  readonly key: string;
  readonly spike: SarosRealtimeSpike;
}

const waveWidth = 1_000;
const waveHeight = 190;
const waveBaseline = 166;

export function RealtimeSarosWindow({ intervals, observedAt }: RealtimeSarosWindowProps) {
  const [snapshotInstant, setSnapshotInstant] = useState(observedAt);
  const [period, setPeriod] = useState<SarosRealtimePeriodId>("mili");
  const [minimumRarity, setMinimumRarity] = useState<SarosRealtimeMinimumRarity>("triplex");
  const [expanded, setExpanded] = useState(false);
  const [soundEnabled, setSoundEnabled] = useState(false);
  const [soundError, setSoundError] = useState<string>();
  const [announcement, setAnnouncement] = useState("");
  const audioContextRef = useRef<AudioContext | undefined>(undefined);
  const soundCursorRef = useRef(observedAt);
  const soundSpikesRef = useRef<readonly SarosRealtimeSpike[]>([]);
  const playheadRef = useRef<SVGGElement>(null);
  const windowRef = useRef<HTMLElement>(null);
  const expandButtonRef = useRef<HTMLButtonElement>(null);
  const expansionWasUsedRef = useRef(false);

  const snapshot = useMemo(
    () =>
      sarosRealtimeWindow(intervals, snapshotInstant, {
        minimumRarity,
        period,
        sampleCount: expanded ? 320 : 180,
        visibleSpikeLimit: expanded ? 640 : 240,
      }),
    [expanded, intervals, minimumRarity, period, snapshotInstant],
  );
  const incomingStyle = tokenStyle(snapshot.incomingSpike.semanticColorToken);
  const waveformPaths = useMemo(
    () => coloredWaveformPaths(snapshot.segment.samples),
    [snapshot.segment.samples],
  );
  const waveMarkers = useMemo(() => segmentWaveMarkers(snapshot.segment), [snapshot.segment]);
  // The four-item lookahead is enough for audio because the snapshot refreshes
  // immediately after every crossing. Avoid scanning a Tera window on a 40 ms timer.
  const soundSpikes = useMemo(
    () => uniqueSpikes([...snapshot.pastSpikes, ...snapshot.upcomingSpikes]),
    [snapshot.pastSpikes, snapshot.upcomingSpikes],
  );

  useEffect(() => {
    soundSpikesRef.current = soundSpikes;
  }, [soundSpikes]);

  useEffect(() => {
    const nextSpike = snapshot.upcomingSpikes[0]?.unixTimestamp ?? Number.POSITIVE_INFINITY;
    const nextRefresh = Math.min(snapshot.segment.endEpochSeconds, nextSpike);
    const delay = Math.max((nextRefresh - Date.now() / 1_000) * 1_000 + 24, 24);
    const timer = window.setTimeout(() => setSnapshotInstant(Date.now() / 1_000), delay);
    return () => window.clearTimeout(timer);
  }, [snapshot.segment.endEpochSeconds, snapshot.upcomingSpikes]);

  useEffect(() => {
    let frame = 0;
    const animate = () => {
      const progress = clamp(
        (Date.now() / 1_000 - snapshot.segment.startEpochSeconds) /
          snapshot.segment.durationSeconds,
        0,
        1,
      );
      playheadRef.current?.setAttribute("transform", `translate(${progress * waveWidth} 0)`);
      frame = window.requestAnimationFrame(animate);
    };
    frame = window.requestAnimationFrame(animate);
    return () => window.cancelAnimationFrame(frame);
  }, [snapshot.segment.durationSeconds, snapshot.segment.startEpochSeconds]);

  useEffect(() => {
    if (!expanded) return;
    const previousDocumentOverflow = document.documentElement.style.overflow;
    const previousBodyOverflow = document.body.style.overflow;
    const closeOrTrapFocus = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.preventDefault();
        setExpanded(false);
        return;
      }
      if (event.key !== "Tab") return;
      const focusable = [
        ...(windowRef.current?.querySelectorAll<HTMLElement>(
          'button:not(:disabled), input:not(:disabled), [href], [tabindex]:not([tabindex="-1"])',
        ) ?? []),
      ].filter((element) => !element.hasAttribute("hidden"));
      const first = focusable[0];
      const last = focusable.at(-1);
      if (first === undefined || last === undefined) return;
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    };
    document.documentElement.style.overflow = "hidden";
    document.body.style.overflow = "hidden";
    window.addEventListener("keydown", closeOrTrapFocus);
    expandButtonRef.current?.focus();
    return () => {
      document.documentElement.style.overflow = previousDocumentOverflow;
      document.body.style.overflow = previousBodyOverflow;
      window.removeEventListener("keydown", closeOrTrapFocus);
    };
  }, [expanded]);

  useEffect(() => {
    if (!expanded && expansionWasUsedRef.current) expandButtonRef.current?.focus();
  }, [expanded]);

  useEffect(() => {
    if (!soundEnabled) return;
    const timer = window.setInterval(() => {
      const context = audioContextRef.current;
      const now = Date.now() / 1_000;
      if (
        context === undefined ||
        context.state !== "running" ||
        document.visibilityState !== "visible"
      ) {
        soundCursorRef.current = now;
        return;
      }

      if (now - soundCursorRef.current > 0.5 || soundCursorRef.current > now + 0.25) {
        // A sleeping/hidden tab must resume from now rather than replay stale crossings.
        soundCursorRef.current = now;
      }
      const horizon = now + 0.12;
      const scheduled = soundSpikesRef.current
        .filter(
          (spike) => spike.unixTimestamp > soundCursorRef.current && spike.unixTimestamp <= horizon,
        )
        .sort(compareSpikes);
      for (const spike of scheduled) {
        scheduleSpikeClick(
          context,
          spike,
          context.currentTime + Math.max(spike.unixTimestamp - now, 0.003),
        );
        const announceDelay = Math.max((spike.unixTimestamp - now) * 1_000, 0);
        window.setTimeout(
          () => setAnnouncement(`${spike.rarityTitle}, Saros ${spike.saros}`),
          announceDelay,
        );
      }
      soundCursorRef.current = horizon;
    }, 40);
    return () => window.clearInterval(timer);
  }, [soundEnabled]);

  useEffect(
    () => () => {
      const context = audioContextRef.current;
      audioContextRef.current = undefined;
      if (context !== undefined) void context.close();
    },
    [],
  );

  const toggleSound = useCallback(async () => {
    if (soundEnabled) {
      const context = audioContextRef.current;
      audioContextRef.current = undefined;
      setSoundEnabled(false);
      setSoundError(undefined);
      if (context !== undefined) await context.close();
      return;
    }

    try {
      const context = new AudioContext({ latencyHint: "interactive" });
      audioContextRef.current = context;
      soundCursorRef.current = Date.now() / 1_000;
      setSoundError(undefined);
      setSoundEnabled(true);
      void context.resume().catch(() => {
        if (audioContextRef.current !== context) return;
        audioContextRef.current = undefined;
        setSoundError("This browser could not start realtime spike audio.");
        setSoundEnabled(false);
        void context.close();
      });
    } catch {
      setSoundError("This browser could not start realtime spike audio.");
      setSoundEnabled(false);
    }
  }, [soundEnabled]);

  const changePeriod = useCallback((value: TemporalPeriod) => {
    setPeriod(value);
    setSnapshotInstant(Date.now() / 1_000);
  }, []);
  const changeMinimumRarity = useCallback((value: LowestRarity) => {
    setMinimumRarity(value);
    setSnapshotInstant(Date.now() / 1_000);
  }, []);

  const toggleExpanded = useCallback(() => {
    expansionWasUsedRef.current = true;
    setExpanded((value) => !value);
  }, []);

  const content = (
    <aside
      aria-label="Realtime Saros sliding window"
      aria-modal={expanded || undefined}
      className={`${styles.realtimeWindow} ${expanded ? styles.expanded : ""}`}
      data-expanded={expanded ? "true" : "false"}
      ref={windowRef}
      role={expanded ? "dialog" : undefined}
    >
      <div className={styles.topbar}>
        <div>
          <span className={styles.liveIndicator}>Live</span>
          <strong>Saros window</strong>
        </div>
        <div className={styles.windowActions}>
          <button
            aria-pressed={soundEnabled}
            className={styles.soundToggle}
            onClick={() => void toggleSound()}
            type="button"
          >
            Sound {soundEnabled ? "on" : "off"}
          </button>
          <button
            aria-expanded={expanded}
            aria-label={expanded ? "Close expanded Saros window" : "Expand Saros window"}
            className={styles.expandButton}
            onClick={toggleExpanded}
            ref={expandButtonRef}
            title={expanded ? "Close expanded view" : "Expand to full screen"}
            type="button"
          >
            <span aria-hidden="true">{expanded ? "×" : "↗"}</span>
          </button>
        </div>
      </div>

      <div className={styles.windowControls}>
        <TemporalPeriodSelector onChange={changePeriod} value={period} />
        <LowestRaritySelector onChange={changeMinimumRarity} value={minimumRarity} />
        {soundError === undefined ? null : (
          <p className={styles.soundError} role="alert">
            {soundError}
          </p>
        )}
      </div>

      <header className={styles.windowHeader} style={incomingStyle}>
        <div className={styles.incomingCopy}>
          <span>Incoming Spike</span>
          <strong>{snapshot.incomingSpike.rarityTitle}</strong>
          <small>
            Saros {snapshot.incomingSpike.saros} · {snapshot.incomingSpike.patternLabel}
          </small>
          <LiveCountdown observedAt={observedAt} target={snapshot.incomingSpike.unixTimestamp} />
        </div>
        <div
          aria-label={`Incoming ten-digit octal phase ${snapshot.incomingPhase.octalAddress}`}
          className={styles.phasePair}
        >
          <PhaseHalf
            address={snapshot.incomingPhase.mostSignificantGlyphAddress}
            label="MSB"
            rarityId={snapshot.incomingSpike.rarityRawValue}
          />
          <i aria-hidden="true">·</i>
          <PhaseHalf
            address={snapshot.incomingPhase.leastSignificantGlyphAddress}
            label="LSB"
            rarityId={snapshot.incomingSpike.rarityRawValue}
          />
        </div>
      </header>

      <div className={styles.waveStage}>
        <svg
          aria-label={`${snapshot.period.title} realtime waveform`}
          preserveAspectRatio="none"
          role="img"
          viewBox={`0 0 ${waveWidth} ${waveHeight}`}
        >
          <line
            className={styles.waveBaseline}
            x1="0"
            x2={waveWidth}
            y1={waveBaseline}
            y2={waveBaseline}
          />
          {waveformPaths.map((path) => (
            <path
              className={styles.wavePath}
              d={path.data}
              key={path.key}
              style={tokenStyle(path.semanticColorToken)}
            />
          ))}
          {waveMarkers.map(({ count, key, spike }) => {
            const x =
              ((spike.unixTimestamp - snapshot.segment.startEpochSeconds) /
                snapshot.segment.durationSeconds) *
              waveWidth;
            return (
              <g key={key} style={tokenStyle(spike.semanticColorToken)}>
                <title>{`${count > 1 ? `${count} spikes · ` : ""}${spike.rarityTitle}, Saros ${spike.saros}`}</title>
                <line className={styles.spikeMarker} x1={x} x2={x} y1="10" y2={waveBaseline} />
                <circle className={styles.spikePoint} cx={x} cy="12" r="4" />
              </g>
            );
          })}
          <g className={styles.playheadGroup} ref={playheadRef}>
            <line className={styles.playhead} x1="0" x2="0" y1="0" y2={waveHeight} />
            <circle className={styles.playheadHead} cx="0" cy="8" r="4" />
          </g>
        </svg>
        <div className={styles.windowScale}>
          <time suppressHydrationWarning>
            {formatWindowBoundary(
              snapshot.segment.startEpochSeconds,
              snapshot.segment.durationSeconds,
            )}
          </time>
          <span>
            1 {snapshot.period.title} · {formatDuration(snapshot.segment.durationSeconds)} ·{" "}
            {snapshot.segment.totalSpikeCount} spikes
          </span>
          <time suppressHydrationWarning>
            {formatWindowBoundary(
              snapshot.segment.endEpochSeconds,
              snapshot.segment.durationSeconds,
            )}
          </time>
        </div>
      </div>

      <div className={styles.spikeHistory}>
        <SpikeStack
          currentSpike={snapshot.incomingSpike}
          observedAt={snapshotInstant}
          pastSpikes={snapshot.pastSpikes.slice(0, 2)}
          upcomingSpikes={snapshot.upcomingSpikes.slice(1, 3)}
        />
      </div>
      <span aria-live="polite" className={styles.srAnnouncement}>
        {announcement}
      </span>
    </aside>
  );

  return expanded ? createPortal(content, document.body) : content;
}

function PhaseHalf({
  address,
  label,
  rarityId,
}: {
  readonly address: string;
  readonly label: "MSB" | "LSB";
  readonly rarityId: RarityId;
}) {
  return (
    <div className={styles.phaseHalf}>
      <span>{label}</span>
      <div>
        <GlyphRenderer
          model={createOctalGlyph({
            value: address,
            depth: 5,
            rarityId,
            accessibilityLabel: `${label} phase glyph ${address}`,
          })}
          size="100%"
        />
      </div>
      <code>{address}</code>
    </div>
  );
}

function LiveCountdown({
  observedAt,
  target,
}: {
  readonly observedAt: number;
  readonly target: number;
}) {
  const [instant, setInstant] = useState(observedAt);
  useEffect(() => {
    const timer = window.setInterval(() => setInstant(Date.now() / 1_000), 100);
    return () => window.clearInterval(timer);
  }, []);
  return <time>{formatCountdown(Math.max(target - instant, 0))}</time>;
}

function SpikeStack({
  currentSpike,
  observedAt,
  pastSpikes,
  upcomingSpikes,
}: {
  readonly currentSpike: SarosRealtimeSpike;
  readonly observedAt: number;
  readonly pastSpikes: readonly SarosRealtimeSpike[];
  readonly upcomingSpikes: readonly SarosRealtimeSpike[];
}) {
  const [instant, setInstant] = useState(observedAt);
  useEffect(() => {
    const timer = window.setInterval(() => setInstant(Date.now() / 1_000), 1_000);
    return () => window.clearInterval(timer);
  }, []);

  const items = [
    ...upcomingSpikes
      .map((spike, index) => ({
        key: `upcoming-${spike.id}`,
        relation: `Upcoming +${index + 1}`,
        spike,
      }))
      .reverse(),
    { key: `current-${currentSpike.id}`, relation: "Current", spike: currentSpike },
    ...pastSpikes.map((spike, index) => ({
      key: `past-${spike.id}`,
      relation: `Past −${index + 1}`,
      spike,
    })),
  ];

  return (
    <section className={styles.spikeGroup}>
      <header>
        <strong>Spike sequence</strong>
        <span>future ↑ · past ↓</span>
      </header>
      <ol className={styles.spikeStack}>
        {items.map(({ key, relation, spike }) => {
          const isCurrent = relation === "Current";
          return (
            <li
              aria-current={isCurrent ? "time" : undefined}
              className={`${styles.spikeCard} ${isCurrent ? styles.currentSpikeCard : ""}`}
              data-relation={
                isCurrent ? "current" : relation.startsWith("Upcoming") ? "future" : "past"
              }
              key={key}
              style={tokenStyle(spike.semanticColorToken)}
              title={`${spike.octalAddress} · ${formatPreciseDateTime(spike.unixTimestamp)}`}
            >
              <div className={styles.spikeCardGlyph}>
                <GlyphRenderer
                  model={createOctalGlyph({
                    value: spike.listGlyphAddress,
                    depth: 5,
                    rarityId: spike.rarityRawValue,
                    accessibilityLabel: `${spike.rarityTitle}, Saros ${spike.saros}, phase ${spike.octalAddress}`,
                  })}
                  size="100%"
                />
              </div>
              <div className={styles.spikeCardCopy}>
                <span className={styles.spikeRelation}>{relation}</span>
                <strong>{spike.rarityTitle}</strong>
                <span>
                  Saros {spike.saros} · {spike.listGlyphAddress}
                </span>
              </div>
              <div className={styles.spikeTiming}>
                <time suppressHydrationWarning>{formatSpikeDateTime(spike.unixTimestamp)}</time>
                <span suppressHydrationWarning>
                  {formatRelativeSpikeTime(spike.unixTimestamp - instant)}
                </span>
              </div>
            </li>
          );
        })}
      </ol>
    </section>
  );
}

interface ColoredWaveformPath {
  readonly key: string;
  readonly semanticColorToken: string | null;
  readonly data: string;
}

function coloredWaveformPaths(
  samples: readonly SarosRealtimeWaveformSample[],
): readonly ColoredWaveformPath[] {
  const first = samples[0];
  if (first === undefined || samples.length < 2) return [];
  const maxEnergy = Math.max(...samples.map((sample) => sample.energy), 0.000_001);
  const point = (sample: SarosRealtimeWaveformSample) => {
    const x = sample.position * waveWidth;
    const y = waveBaseline - (sample.energy / maxEnergy) * (waveBaseline - 18);
    return `${x.toFixed(2)},${y.toFixed(2)}`;
  };
  const paths: ColoredWaveformPath[] = [];
  let token = first.semanticColorToken;
  let points: SarosRealtimeWaveformSample[] = [first];

  for (let index = 1; index < samples.length; index += 1) {
    const sample = samples[index];
    const previous = samples[index - 1];
    if (sample === undefined || previous === undefined) continue;
    const nextToken = sample.semanticColorToken;
    if (nextToken !== token) {
      points.push(sample);
      paths.push({
        key: `${paths.length}-${token ?? "common"}`,
        semanticColorToken: token,
        data: points
          .map((candidate, pointIndex) => `${pointIndex === 0 ? "M" : "L"}${point(candidate)}`)
          .join(" "),
      });
      points = [previous, sample];
      token = nextToken;
    } else {
      points.push(sample);
    }
  }
  if (points.length >= 2) {
    paths.push({
      key: `${paths.length}-${token ?? "common"}`,
      semanticColorToken: token,
      data: points
        .map((candidate, pointIndex) => `${pointIndex === 0 ? "M" : "L"}${point(candidate)}`)
        .join(" "),
    });
  }
  return paths;
}

function segmentWaveMarkers(segment: {
  readonly visibleSpikes: readonly SarosRealtimeSpike[];
  readonly visibleSpikesTruncated: boolean;
  readonly spikeBuckets: readonly {
    readonly startEpochSeconds: number;
    readonly count: number;
    readonly representativeSpike?: SarosRealtimeSpike;
  }[];
}): readonly WaveMarker[] {
  if (!segment.visibleSpikesTruncated) {
    return segment.visibleSpikes.map((spike) => ({ count: 1, key: spike.id, spike }));
  }
  return segment.spikeBuckets.flatMap((bucket) => {
    const spike = bucket.representativeSpike;
    return spike === undefined
      ? []
      : [{ count: bucket.count, key: `bucket-${bucket.startEpochSeconds}`, spike }];
  });
}

function scheduleSpikeClick(context: AudioContext, spike: SarosRealtimeSpike, startAt: number) {
  const duration = 0.014;
  const frameCount = Math.max(Math.ceil(duration * context.sampleRate), 1);
  const buffer = context.createBuffer(1, frameCount, context.sampleRate);
  const samples = buffer.getChannelData(0);
  const pitch = Math.sqrt(420 * 2_400);
  const normalizedMagnitude =
    spike.magnitude === undefined
      ? (1 - 0.25) / (1.15 - 0.25)
      : clamp(spike.magnitude, 0, 1.1) / 1.1;
  const gain = 0.25 + normalizedMagnitude * (1.15 - 0.25);

  for (let frame = 0; frame < frameCount; frame += 1) {
    const time = frame / context.sampleRate;
    const envelope = Math.min(time / 0.00055, 1) * Math.exp(-time / 0.0038);
    const fundamental = Math.sin(2 * Math.PI * pitch * time);
    const overtone = 0.2 * Math.sin(2 * Math.PI * pitch * 2.03 * time + Math.PI / 7);
    const transient = 0.07 * Math.sin(2 * Math.PI * pitch * 3.79 * time + Math.PI / 11);
    samples[frame] = 0.19 * gain * envelope * (fundamental + overtone + transient);
  }

  const source = context.createBufferSource();
  source.buffer = buffer;
  source.connect(context.destination);
  source.start(Math.max(startAt, context.currentTime + 0.002));
}

function tokenStyle(token: string | null): CSSProperties {
  const color =
    canonicalCatalog.semanticTokens.colors.find((candidate) => candidate.id === token)
      ?.fallbackSrgb ?? "#fff";
  return { "--temporal-color": color } as CSSProperties;
}

function uniqueSpikes(spikes: readonly SarosRealtimeSpike[]): readonly SarosRealtimeSpike[] {
  return [...new Map(spikes.map((spike) => [spike.id, spike])).values()];
}

function compareSpikes(left: SarosRealtimeSpike, right: SarosRealtimeSpike) {
  if (left.unixTimestamp !== right.unixTimestamp) return left.unixTimestamp - right.unixTimestamp;
  if (left.rarityRank !== right.rarityRank) return right.rarityRank - left.rarityRank;
  return left.saros - right.saros;
}

function formatCountdown(seconds: number) {
  if (seconds >= 86_400) return `in ${(seconds / 86_400).toFixed(2)} d`;
  if (seconds >= 3_600) return `in ${(seconds / 3_600).toFixed(2)} h`;
  if (seconds >= 60) return `in ${(seconds / 60).toFixed(2)} min`;
  return `in ${seconds.toFixed(seconds < 10 ? 2 : 1)} s`;
}

function formatDuration(seconds: number) {
  if (seconds < 60) return `${seconds.toFixed(3)} s`;
  if (seconds < 3_600) return `${Math.floor(seconds / 60)}m ${Math.round(seconds % 60)}s`;
  if (seconds < 86_400) {
    return `${Math.floor(seconds / 3_600)}h ${Math.round((seconds % 3_600) / 60)}m`;
  }
  return `${Math.floor(seconds / 86_400)}d ${Math.round((seconds % 86_400) / 3_600)}h`;
}

function formatWindowBoundary(epochSeconds: number, durationSeconds: number) {
  if (durationSeconds < 86_400) return formatPreciseClock(epochSeconds);
  return new Intl.DateTimeFormat(undefined, {
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    month: "short",
  }).format(new Date(epochSeconds * 1_000));
}

function formatPreciseClock(epochSeconds: number) {
  return new Intl.DateTimeFormat(undefined, {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    fractionalSecondDigits: 3,
  }).format(new Date(epochSeconds * 1_000));
}

function formatSpikeDateTime(epochSeconds: number) {
  return new Intl.DateTimeFormat(undefined, {
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    month: "short",
    second: "2-digit",
  }).format(new Date(epochSeconds * 1_000));
}

function formatRelativeSpikeTime(deltaSeconds: number) {
  const absolute = Math.abs(deltaSeconds);
  if (absolute < 0.5) return "now";
  const distance =
    absolute >= 86_400
      ? `${(absolute / 86_400).toFixed(2)} d`
      : absolute >= 3_600
        ? `${(absolute / 3_600).toFixed(2)} h`
        : absolute >= 60
          ? `${(absolute / 60).toFixed(2)} min`
          : `${absolute.toFixed(absolute < 10 ? 1 : 0)} s`;
  return deltaSeconds > 0 ? `in ${distance}` : `${distance} ago`;
}

function formatPreciseDateTime(epochSeconds: number) {
  return new Date(epochSeconds * 1_000).toISOString();
}

function clamp(value: number, minimum: number, maximum: number) {
  return Math.min(Math.max(value, minimum), maximum);
}
