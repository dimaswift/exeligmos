import { useEffect, useMemo, useState, type CSSProperties } from "react";

import { canonicalCatalog } from "@exeligmos/domain-catalog";
import { createOctalGlyph } from "@exeligmos/glyph-core";
import {
  canonicalTemporalEngine,
  repdigitPeriodSeconds,
  sarosSystemSnapshot,
  waveformSamples,
  type RarityDescriptor,
  type SarosGridReading,
  type SarosInterval,
  type SarosPulseReading,
  type SarosSpikeReference,
} from "@exeligmos/temporal-core";
import { GlyphRenderer } from "@exeligmos/ui";

import styles from "~/routes/engine-lab.module.css";

interface LiveSystemLabProps {
  readonly observedAt: number;
  readonly harmonicDepth: number;
  readonly intervals: readonly SarosInterval[];
  readonly solarData: {
    readonly schemaVersion: number;
    readonly sourceSha256: string;
    readonly seriesCount: number;
    readonly eclipseCount: number;
  };
}

export function LiveSystemLab({
  harmonicDepth,
  intervals,
  observedAt,
  solarData,
}: LiveSystemLabProps) {
  const [snapshotInstant, setSnapshotInstant] = useState(observedAt);
  const [selectedSaros, setSelectedSaros] = useState<number | null>(null);

  useEffect(() => {
    const timer = window.setInterval(() => setSnapshotInstant(Date.now() / 1_000), 5_000);
    return () => window.clearInterval(timer);
  }, []);

  const snapshot = useMemo(
    () => sarosSystemSnapshot(intervals, snapshotInstant, harmonicDepth),
    [harmonicDepth, intervals, snapshotInstant],
  );
  const selected =
    snapshot.grid.find((reading) => reading.saros === selectedSaros) ??
    snapshot.grid.find((reading) => reading.saros === snapshot.nearestUpcomingFlip?.saros) ??
    snapshot.grid[0];
  const closestSpike = closestContextSpike(snapshot.context.spikes, snapshotInstant);
  const eventRarity =
    closestSpike === undefined
      ? undefined
      : canonicalTemporalEngine.rarityDescriptor({
          rarityId: closestSpike.rarityRawValue,
          harmonicDepth,
        });
  const phaseRarity =
    snapshot.context.closestSarosPhase === undefined
      ? undefined
      : canonicalTemporalEngine.rarityDescriptor({
          rarityId: snapshot.context.closestSarosPhase.rarityRawValue,
          harmonicDepth: snapshot.context.closestSarosPhase.harmonicDepth,
        });
  const mega = canonicalTemporalEngine.pulseDuration("mega").seconds;
  const waveStart = snapshotInstant - mega;
  const waveEnd = snapshotInstant + mega;
  const wavePoints = useMemo(
    () => waveformSamples(snapshot.context.spikes, waveStart, waveEnd, 220),
    [snapshot.context.spikes, waveEnd, waveStart],
  );

  return (
    <div className={styles.page}>
      <header className={styles.header}>
        <div>
          <p className="eyebrow">Realtime temporal engine</p>
          <h1>System lab</h1>
          <p className={styles.lede}>
            The same eclipse intervals, octal clock, repdigit rules, pulse, and four-spike context
            used by the native app and web-created records.
          </p>
        </div>
        <LiveClock observedAt={observedAt} />
      </header>

      <section aria-labelledby="temporal-now" className={`${styles.panel} ${styles.nowPanel}`}>
        <div className={styles.sectionHeading}>
          <div>
            <p className="eyebrow">Current state</p>
            <h2 id="temporal-now">{eventRarity?.title ?? "No active temporal event"}</h2>
            <p>{formatWaveLabel(snapshot.context)}</p>
          </div>
          <span className={styles.status}>depth {harmonicDepth}</span>
        </div>

        <div className={styles.nowGrid}>
          <div className={styles.nowSummaryRow}>
            <PrimaryPhase
              address={snapshot.context.closestSarosPhase?.octalAddress}
              depth={harmonicDepth}
              rarity={phaseRarity}
              saros={snapshot.context.closestSarosPhase?.saros}
            />
            <PulseOverview pulse={snapshot.pulse} />
            <UpcomingFlip flip={snapshot.nearestUpcomingFlip} observedAt={snapshotInstant} />
          </div>
          <ContextStrip instant={snapshotInstant} spikes={snapshot.context.spikes} />
        </div>
      </section>

      <section aria-labelledby="waveform" className={styles.panel}>
        <div className={styles.sectionHeading}>
          <div>
            <p className="eyebrow">Two Mega Saros window</p>
            <h2 id="waveform">Waveform</h2>
          </div>
          <div className={styles.waveMetrics}>
            <span>E {formatOctalMetric(snapshot.context.energyPercent)}</span>
            <span>M {formatSignedOctalMetric(snapshot.context.momentum)}</span>
          </div>
        </div>
        <TemporalWaveform
          end={waveEnd}
          points={wavePoints}
          spikes={snapshot.context.spikes}
          start={waveStart}
        />
      </section>

      <section aria-labelledby="saros-grid" className={styles.panel}>
        <div className={styles.sectionHeading}>
          <div>
            <p className="eyebrow">40 active solar series</p>
            <h2 id="saros-grid">Saros Grid</h2>
          </div>
          <span className={styles.status}>5 × 8 · updates every 5 seconds</span>
        </div>
        <div className={styles.sarosGridScroller}>
          <div className={styles.sarosGrid}>
            {snapshot.grid.map((reading) => (
              <SarosCell
                highlighted={reading.saros === snapshot.nearestUpcomingFlip?.saros}
                key={reading.saros}
                onSelect={() => setSelectedSaros(reading.saros)}
                reading={reading}
                selected={reading.saros === selected?.saros}
              />
            ))}
          </div>
        </div>
      </section>

      <section aria-labelledby="repdigit-periods" className={styles.panel}>
        <div className={styles.sectionHeading}>
          <div>
            <p className="eyebrow">Causal event cadence</p>
            <h2 id="repdigit-periods">Repdigit periods</h2>
          </div>
          <span className={styles.status}>Alpha → Omega</span>
        </div>
        <RepdigitPeriods depth={harmonicDepth} interval={selectedInterval(intervals, selected)} />
      </section>

      <section aria-labelledby="octal-periods" className={styles.panel}>
        <div className={styles.sectionHeading}>
          <div>
            <p className="eyebrow">Nested phase clock</p>
            <h2 id="octal-periods">Octal periods</h2>
          </div>
          <span className={styles.status}>actual interval durations</span>
        </div>
        {selected?.pulse === undefined ? null : <OctalPeriods pulse={selected.pulse} />}
      </section>

      <details className={`${styles.panel} ${styles.diagnostics}`}>
        <summary>Engine diagnostics and provenance</summary>
        <dl>
          <div>
            <dt>Catalog</dt>
            <dd>{canonicalCatalog.catalogVersion}</dd>
          </div>
          <div>
            <dt>Solar dataset</dt>
            <dd>
              {solarData.seriesCount} series · {solarData.eclipseCount.toLocaleString()} eclipses
            </dd>
          </div>
          <div>
            <dt>Dataset SHA-256</dt>
            <dd>{solarData.sourceSha256}</dd>
          </div>
          <div>
            <dt>Schema</dt>
            <dd>{solarData.schemaVersion}</dd>
          </div>
        </dl>
      </details>
    </div>
  );
}

function LiveClock({ observedAt }: { readonly observedAt: number }) {
  const instant = useLiveSecond(observedAt);
  return (
    <div className={styles.liveClock}>
      <span className={styles.liveBadge}>Live</span>
      <time dateTime={new Date(instant * 1_000).toISOString()} suppressHydrationWarning>
        {formatLocalDateTime(instant)}
      </time>
      <code>{formatUtcTime(instant)} UTC</code>
    </div>
  );
}

function useLiveSecond(observedAt: number) {
  const [instant, setInstant] = useState(observedAt);
  useEffect(() => {
    const update = () => setInstant(Date.now() / 1_000);
    update();
    const timer = window.setInterval(update, 1_000);
    return () => window.clearInterval(timer);
  }, []);
  return instant;
}

function PrimaryPhase({
  address,
  depth,
  rarity,
  saros,
}: {
  readonly address?: string;
  readonly depth: number;
  readonly rarity?: RarityDescriptor;
  readonly saros?: number;
}) {
  if (address === undefined) return null;
  const glyph = createOctalGlyph({ value: address, depth, rarityId: rarity?.rarityId ?? "common" });
  return (
    <article className={styles.primaryPhase} style={rarityStyle(rarity)}>
      <div className={styles.primaryGlyph}>
        <GlyphRenderer model={glyph} size="100%" />
      </div>
      <div>
        <span>Closest series phase</span>
        <strong>Saros {saros}</strong>
        <code>{address}</code>
      </div>
    </article>
  );
}

function ContextStrip({
  instant,
  spikes,
}: {
  readonly instant: number;
  readonly spikes: readonly SarosSpikeReference[];
}) {
  const closest = closestContextSpike(spikes, instant);
  return (
    <div aria-label="Four contextual Saros spikes" className={styles.contextStrip}>
      {spikes.map((spike) => {
        const rarity = canonicalTemporalEngine.rarityDescriptor({
          rarityId: spike.rarityRawValue,
          harmonicDepth: spike.harmonicDepth,
        });
        return (
          <article
            className={spike === closest ? styles.contextSpikeClosest : styles.contextSpike}
            key={`${spike.saros}-${spike.unixTimestamp}`}
            style={rarityStyle(rarity)}
          >
            <GlyphRenderer
              model={createOctalGlyph({
                value: spike.octalAddress,
                depth: spike.harmonicDepth,
                rarityId: spike.rarityRawValue,
              })}
              size="100%"
            />
            <strong>{spike.saros}</strong>
            <time dateTime={new Date(spike.unixTimestamp * 1_000).toISOString()}>
              {formatRelative(spike.unixTimestamp - instant)}
            </time>
          </article>
        );
      })}
    </div>
  );
}

function PulseOverview({ pulse }: { readonly pulse?: SarosPulseReading }) {
  if (pulse === undefined) return null;
  return (
    <article className={styles.pulseOverview} data-pulse-color={pulse.color}>
      <div>
        <GlyphRenderer
          model={createOctalGlyph({
            value: pulse.octalAddress,
            depth: pulse.glyphDepth,
            rarityId: "common",
          })}
          size="100%"
        />
      </div>
      <span>Pulse · Saros {pulse.saros}</span>
      <code>{pulse.octalAddress}</code>
    </article>
  );
}

function UpcomingFlip({
  flip,
  observedAt,
}: {
  readonly flip: ReturnType<typeof sarosSystemSnapshot>["nearestUpcomingFlip"];
  readonly observedAt: number;
}) {
  if (flip === undefined) return null;
  return <UpcomingFlipContent flip={flip} observedAt={observedAt} />;
}

function UpcomingFlipContent({
  flip,
  observedAt,
}: {
  readonly flip: NonNullable<ReturnType<typeof sarosSystemSnapshot>["nearestUpcomingFlip"]>;
  readonly observedAt: number;
}) {
  const instant = useLiveSecond(observedAt);
  const rarity = canonicalTemporalEngine.rarityDescriptor({
    rarityId: flip.rarityRawValue,
    harmonicDepth: flip.harmonicDepth,
  });
  return (
    <article className={styles.upcoming} style={rarityStyle(rarity)}>
      <span>Next global flip</span>
      <strong>{flip.title}</strong>
      <code>
        Saros {flip.saros} · {flip.patternLabel}
      </code>
      <b>{formatDuration(flip.unixTimestamp - instant)}</b>
    </article>
  );
}

function TemporalWaveform({
  end,
  points,
  spikes,
  start,
}: {
  readonly end: number;
  readonly points: readonly { readonly position: number; readonly energy: number }[];
  readonly spikes: readonly SarosSpikeReference[];
  readonly start: number;
}) {
  const width = 1_000;
  const height = 220;
  const maxEnergy = Math.max(...points.map((point) => point.energy), 0.000_001);
  const path = points
    .map((point, index) => {
      const x = point.position * width;
      const y = height - 20 - (point.energy / maxEnergy) * (height - 44);
      return `${index === 0 ? "M" : "L"}${x.toFixed(2)},${y.toFixed(2)}`;
    })
    .join(" ");
  const visibleSpikes = spikes.filter(
    (spike) => spike.unixTimestamp >= start && spike.unixTimestamp <= end,
  );
  return (
    <div className={styles.waveStage}>
      <svg
        aria-label="Live temporal waveform"
        preserveAspectRatio="none"
        viewBox={`0 0 ${width} ${height}`}
      >
        <defs>
          <linearGradient id="wave-fill" x1="0" x2="0" y1="0" y2="1">
            <stop offset="0" stopColor="var(--color-accent)" stopOpacity=".4" />
            <stop offset="1" stopColor="var(--color-accent)" stopOpacity="0" />
          </linearGradient>
        </defs>
        <path className={styles.waveArea} d={`${path} L${width},${height} L0,${height} Z`} />
        <path className={styles.waveLine} d={path} />
        {visibleSpikes.map((spike) => {
          const x = ((spike.unixTimestamp - start) / (end - start)) * width;
          return (
            <circle
              className={styles.waveSpike}
              cx={x}
              cy={16}
              key={`${spike.saros}-${spike.unixTimestamp}`}
              r={4}
            />
          );
        })}
        <line className={styles.nowLine} x1={width / 2} x2={width / 2} y1={0} y2={height} />
      </svg>
      <div className={styles.waveScale}>
        <time suppressHydrationWarning>{formatClock(start)}</time>
        <span>now</span>
        <time suppressHydrationWarning>{formatClock(end)}</time>
      </div>
    </div>
  );
}

function SarosCell({
  highlighted,
  onSelect,
  reading,
  selected,
}: {
  readonly highlighted: boolean;
  readonly onSelect: () => void;
  readonly reading: SarosGridReading;
  readonly selected: boolean;
}) {
  return (
    <button
      aria-label={`Saros ${reading.saros}, phase ${reading.clock.octalAddress}`}
      className={`${styles.sarosCell} ${highlighted ? styles.sarosCellHighlighted : ""} ${selected ? styles.sarosCellSelected : ""}`}
      onClick={onSelect}
      style={rarityStyle(reading.rarity)}
      type="button"
    >
      <GlyphRenderer
        model={createOctalGlyph({
          value: reading.clock.octalAddress,
          depth: reading.clock.harmonicDepth,
          rarityId: reading.rarity.rarityId,
        })}
        size="100%"
      />
      <span>{reading.saros}</span>
    </button>
  );
}

function RepdigitPeriods({
  depth,
  interval,
}: {
  readonly depth: number;
  readonly interval?: SarosInterval;
}) {
  const intervalDuration =
    interval === undefined
      ? canonicalCatalog.time.basePeriod.seconds
      : interval.next.epochSeconds - interval.previous.epochSeconds;
  const averageDuration = canonicalCatalog.time.basePeriod.seconds;
  const families = canonicalCatalog.rarities.families.filter(
    (family) => family.order >= 3 && family.wildcardPrefixCount < depth,
  );
  return (
    <div className={styles.repdigitGrid}>
      {families.map((family) => {
        const suffixLength = Math.max(depth - family.wildcardPrefixCount, 0);
        return (
          <article
            className={styles.repdigitCard}
            key={family.id}
            style={semanticStyle(family.semanticColorToken)}
          >
            <header>
              <div>
                <span>Order {family.order}</span>
                <h3>{family.title}</h3>
              </div>
              <code>
                {"X".repeat(family.wildcardPrefixCount)}
                {"7".repeat(suffixLength)}
              </code>
            </header>
            <div className={styles.repdigitVariants}>
              {canonicalCatalog.rarities.digits
                .filter((digit) => digit.digit > 0)
                .map((digit) => {
                  const rarityId = `${family.id}-${digit.digit}`;
                  const exactPeriod = repdigitPeriodSeconds({
                    basePeriodSeconds: intervalDuration,
                    harmonicDepth: depth,
                    wildcardPrefixCount: family.wildcardPrefixCount,
                    repeatedDigit: digit.digit,
                  });
                  const averagePeriod = repdigitPeriodSeconds({
                    basePeriodSeconds: averageDuration,
                    harmonicDepth: depth,
                    wildcardPrefixCount: family.wildcardPrefixCount,
                    repeatedDigit: digit.digit,
                  });
                  return (
                    <div
                      key={digit.digit}
                      title={`${digit.prefix} ${family.title}: ${formatDuration(exactPeriod)} in the selected Saros interval; ${formatDuration(averagePeriod)} average`}
                    >
                      <GlyphRenderer
                        model={createOctalGlyph({
                          value:
                            "0".repeat(family.wildcardPrefixCount) +
                            String(digit.digit).repeat(suffixLength),
                          depth,
                          rarityId,
                        })}
                        size="100%"
                      />
                      <span>{digit.prefix}</span>
                      <strong>{formatDuration(exactPeriod)}</strong>
                      <small>avg {formatDuration(averagePeriod)}</small>
                    </div>
                  );
                })}
            </div>
            <p className={styles.repdigitFormula}>digit × R{suffixLength}</p>
          </article>
        );
      })}
    </div>
  );
}

function OctalPeriods({ pulse }: { readonly pulse: SarosPulseReading }) {
  return (
    <div className={styles.octalPeriods}>
      {pulse.units.map((unit) => (
        <article key={unit.id}>
          <header>
            <span>{unit.title}</span>
            <strong>{unit.digit ?? "↻"}</strong>
          </header>
          <div className={styles.progressTrack}>
            <i style={{ width: `${unit.progress * 100}%` }} />
          </div>
          <dl>
            <div>
              <dt>Exact</dt>
              <dd>{formatDuration(unit.exactDurationSeconds)}</dd>
            </div>
            <div>
              <dt>Next</dt>
              <dd>{formatDuration(unit.timeUntilNextSeconds)}</dd>
            </div>
            <div>
              <dt>Average</dt>
              <dd>{formatDuration(unit.averageDurationSeconds)}</dd>
            </div>
          </dl>
        </article>
      ))}
    </div>
  );
}

function selectedInterval(
  intervals: readonly SarosInterval[],
  selected: SarosGridReading | undefined,
) {
  return selected === undefined
    ? intervals[0]
    : intervals.find((interval) => interval.saros === selected.saros);
}

function closestContextSpike(spikes: readonly SarosSpikeReference[], instant: number) {
  return spikes.reduce<SarosSpikeReference | undefined>((best, spike) => {
    if (best === undefined) return spike;
    return Math.abs(spike.unixTimestamp - instant) < Math.abs(best.unixTimestamp - instant)
      ? spike
      : best;
  }, undefined);
}

function formatWaveLabel(context: {
  readonly energyPercent: number;
  readonly momentum: number;
  readonly majorPeriodSeconds: number;
}) {
  const energyBin = Math.min(
    Math.floor(Math.max(0, Math.min(context.energyPercent, 1)) * 512),
    511,
  );
  const momentumBin = Math.min(
    Math.floor(Math.max(0, Math.min(Math.abs(context.momentum), 1)) * 512),
    511,
  );
  if (energyBin >= 504)
    return `${momentumBin <= 1 ? "creeping" : momentumBin <= 8 ? "gradual" : momentumBin <= 32 ? "sharp" : "exploding"} peak`;
  if (context.energyPercent <= 0.2) {
    const saros = canonicalTemporalEngine.pulseDuration("saros").seconds;
    const kilo = canonicalTemporalEngine.pulseDuration("kilo").seconds;
    const mega = canonicalTemporalEngine.pulseDuration("mega").seconds;
    const modifier =
      context.majorPeriodSeconds <= saros
        ? "gorge"
        : context.majorPeriodSeconds <= kilo
          ? "narrow"
          : context.majorPeriodSeconds <= mega
            ? "wide"
            : "vast";
    return `${modifier} valley`;
  }
  if (momentumBin < 1) return "flat";
  if (context.momentum > 0)
    return `${momentumBin <= 1 ? "crawling" : momentumBin <= 8 ? "slow" : momentumBin <= 32 ? "rapid" : "rocketing"} ascent`;
  return `${momentumBin <= 1 ? "creeping" : momentumBin <= 8 ? "gradual" : momentumBin <= 32 ? "rapid" : "plunging"} descent`;
}

function rarityStyle(rarity: RarityDescriptor | undefined): CSSProperties {
  return rarity === undefined ? {} : semanticStyle(rarity.semanticColorToken);
}

function semanticStyle(token: string): CSSProperties {
  const color =
    canonicalCatalog.semanticTokens.colors.find((candidate) => candidate.id === token)
      ?.fallbackSrgb ?? "#fff";
  return { "--temporal-color": color } as CSSProperties;
}

function formatLocalDateTime(epochSeconds: number) {
  return new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "medium" }).format(
    new Date(epochSeconds * 1_000),
  );
}

function formatUtcTime(epochSeconds: number) {
  return new Date(epochSeconds * 1_000).toISOString().slice(11, 19);
}

function formatClock(epochSeconds: number) {
  return new Intl.DateTimeFormat(undefined, { hour: "2-digit", minute: "2-digit" }).format(
    new Date(epochSeconds * 1_000),
  );
}

function formatOctalMetric(value: number) {
  return Math.min(Math.floor(Math.max(0, Math.min(value, 1)) * 512), 511)
    .toString(8)
    .padStart(3, "0");
}

function formatSignedOctalMetric(value: number) {
  const sign = value > 0 ? "+" : value < 0 ? "−" : "";
  return `${sign}${formatOctalMetric(Math.abs(value))}`;
}

function formatRelative(seconds: number) {
  return seconds >= 0 ? `in ${formatDuration(seconds)}` : `${formatDuration(-seconds)} ago`;
}

function formatDuration(rawSeconds: number) {
  const seconds = Math.max(rawSeconds, 0);
  if (seconds >= 86_400) return `${(seconds / 86_400).toFixed(seconds >= 864_000 ? 1 : 2)} d`;
  if (seconds >= 3_600) return `${(seconds / 3_600).toFixed(2)} h`;
  if (seconds >= 60) return `${(seconds / 60).toFixed(2)} min`;
  return `${seconds.toFixed(seconds < 10 ? 2 : 1)} s`;
}
