import { useEffect, useMemo, useRef, useState, useSyncExternalStore, type FormEvent } from "react";

import {
  createMixedRadixGlyph,
  DEFAULT_MIXED_RADIX_STACK_OFFSET_X,
  DEFAULT_MIXED_RADIX_STACK_OFFSET_Y,
  semanticGlyphStyle,
  type GlyphStyle,
} from "@fractonica/glyph-core";
import {
  MEAN_TROPICAL_YEAR_SECONDS,
  MIXED_RADIX_BASES,
  MIXED_RADIX_MAX_SIGNIFICANCE_DEPTH,
  MIXED_RADIX_SAROS_BIN_COUNT,
  MIXED_RADIX_SERIES_PHASE_COUNT,
  mixedRadixBinsForDigits,
  mixedRadixClockReading,
  mixedRadixRepdigitMetadata,
  mixedRadixSignificanceLayersForBases,
  mixedRadixState,
  type MixedRadixRepdigitMetadata,
  type MixedRadixRepdigitRarity,
  type MixedRadixState,
  type SarosInterval,
} from "@fractonica/temporal-core";
import { GlyphRenderer } from "@fractonica/ui";

import styles from "~/routes/engine-lab.module.css";

interface MixedRadixEpochProps {
  readonly instant: number;
  readonly interval?: SarosInterval;
  readonly intervals: readonly SarosInterval[];
  readonly onSelectSaros: (saros: number) => void;
}

const GLYPH_STYLE = semanticGlyphStyle("color.rarity.common");
const RARITY_GLYPH_STYLES: Readonly<Record<MixedRadixRepdigitRarity, GlyphStyle>> = Object.freeze({
  common: GLYPH_STYLE,
  rare: semanticGlyphStyle("color.rarity.duplex"),
  epic: semanticGlyphStyle("color.rarity.simplex"),
  legendary: semanticGlyphStyle("color.rarity.nihil"),
  mythic: semanticGlyphStyle("color.rarity.mythic-omega"),
});
const STACK_SPECIMENS = [7, 8, 9, 10, 11, 12] as const;
const SOCKET_TO_DIGIT_INDEX = [0, 5, 4, 3, 2, 1] as const;
const DEFAULT_BASES_BY_SOCKET = [11, 13, 5, 7, 8, 9] as const;
const SOCKET_LABELS = ["top", "top right", "bottom right", "bottom", "bottom left", "top left"];
const AVAILABLE_BASES = Array.from({ length: 63 }, (_, index) => index + 2);
const ATLAS_MAX_COLUMNS = 8;
const ATLAS_MAX_ROWS = 8;
const TIMELINE_WINDOW_BIN_COUNT = 42;
const DEEP_RARITY_SIGNIFICANCE_DEPTH = 6;
const ATLAS_LAYOUT_STORAGE_KEY = "fractonica.mixed-radix.atlas-layout.v1";
const BIN_COUNT_STORAGE_KEY = "fractonica.mixed-radix.bin-count.v1";
const BASES_STORAGE_KEY = "fractonica.mixed-radix.bases-by-socket.v1";
const EXPERIMENTAL_BIN_COUNT_MAX = 1_000_000;
const PERSISTENT_SETTINGS_EVENT = "fractonica-mixed-radix-settings";

export function MixedRadixEpoch({
  instant,
  interval,
  intervals,
  onSelectSaros,
}: MixedRadixEpochProps) {
  if (interval === undefined) return null;
  return (
    <MixedRadixEpochContent
      instant={instant}
      interval={interval}
      intervals={intervals}
      onSelectSaros={onSelectSaros}
    />
  );
}

function MixedRadixEpochContent({
  instant,
  interval,
  intervals,
  onSelectSaros,
}: Required<MixedRadixEpochProps>) {
  const binCount = useStoredInteger(
    BIN_COUNT_STORAGE_KEY,
    MIXED_RADIX_SAROS_BIN_COUNT,
    1,
    EXPERIMENTAL_BIN_COUNT_MAX,
  );
  const liveReading = useMemo(
    () =>
      mixedRadixClockReading({
        binCount,
        previousEpochSeconds: interval.previous.epochSeconds,
        nextEpochSeconds: interval.next.epochSeconds,
        instantEpochSeconds: instant,
        sarosSequence: interval.previous.sequence,
      }),
    [binCount, instant, interval],
  );
  const [followingLive, setFollowingLive] = useState(true);
  const [explorerSequence, setExplorerSequence] = useState(liveReading.sarosSequence);
  const [explorerBin, setExplorerBin] = useState(liveReading.binIndex);
  const [significanceDepth, setSignificanceDepth] = useState(1);
  const [compositionMode, setCompositionMode] = useState<"wide" | "deep">("wide");
  const [deepBaseDigitIndex, setDeepBaseDigitIndex] = useState<number>(SOCKET_TO_DIGIT_INDEX[0]);
  const [viewMode, setViewMode] = useState<"clock" | "atlas" | "timeline" | "basis">("clock");
  const [atlasPhaseOffset, setAtlasPhaseOffset] = useState(
    mixedRadixState(0, interval.previous.sequence, binCount).seriesPhaseIndex,
  );
  const stackOffsetX = DEFAULT_MIXED_RADIX_STACK_OFFSET_X;
  const stackOffsetY = DEFAULT_MIXED_RADIX_STACK_OFFSET_Y;
  const basesBySocket = useStoredBases();
  const radices = radicesFromSocketBases(basesBySocket);

  const state = followingLive
    ? liveReading
    : mixedRadixState(Math.min(explorerBin, binCount - 1), explorerSequence, binCount);
  const digitLayers = mixedRadixSignificanceLayersForBases(
    state.serialBinIndex,
    significanceDepth,
    radices,
  );
  const glyphMetadata = mixedRadixRepdigitMetadata(digitLayers[0] ?? radices.map(() => 0));
  const basisPeriod = leastCommonMultiple(radices);
  const nextBoundary = mixedRadixState(0, state.sarosSequence + 1, binCount);
  const seriesAddressCount = binCount * MIXED_RADIX_SERIES_PHASE_COUNT;

  const setBin = (value: number) => {
    setFollowingLive(false);
    setExplorerBin(Math.min(binCount - 1, Math.max(0, Math.trunc(value))));
  };
  const setSequence = (value: number) => {
    setFollowingLive(false);
    setExplorerSequence(Math.min(MIXED_RADIX_SERIES_PHASE_COUNT, Math.max(1, Math.trunc(value))));
  };
  const setDepth = (value: number) => {
    setSignificanceDepth(
      Math.min(MIXED_RADIX_MAX_SIGNIFICANCE_DEPTH, Math.max(1, Math.trunc(value))),
    );
  };
  const setBaseAtSocket = (socketIndex: number, base: number) => {
    const next = [...basesBySocket];
    const previousBase = next[socketIndex];
    const occupiedSocket = next.indexOf(base);
    if (occupiedSocket >= 0 && occupiedSocket !== socketIndex && previousBase !== undefined) {
      next[occupiedSocket] = previousBase;
    }
    next[socketIndex] = base;
    writeStoredBases(next);
  };
  const step = (delta: number) => {
    setFollowingLive(false);
    const absolute =
      (((state.seriesPhaseIndex * binCount + state.binIndex + delta) % seriesAddressCount) +
        seriesAddressCount) %
      seriesAddressCount;
    setExplorerSequence(Math.floor(absolute / binCount) + 1);
    setExplorerBin(absolute % binCount);
  };

  return (
    <section aria-labelledby="mixed-radix-epoch" className={`${styles.panel} ${styles.mixedPanel}`}>
      <div className={styles.sectionHeading}>
        <div>
          <p className="eyebrow">Experimental carrier · Saros {interval.saros}</p>
          <h2 id="mixed-radix-epoch">Mixed-radix epoch</h2>
          <p>
            Six simultaneous residue wheels on an editable spatial map; the carrier retains its
            base-7/base-11 eclipse phase pair.
          </p>
        </div>
        <div className={styles.mixedHeaderActions}>
          <label className={styles.sarosPicker}>
            <span>Saros series</span>
            <select
              aria-label="Saros series"
              onChange={(event) => onSelectSaros(Number(event.target.value))}
              value={interval.saros}
            >
              {[...intervals]
                .sort((left, right) => left.saros - right.saros)
                .map((candidate) => (
                  <option key={candidate.saros} value={candidate.saros}>
                    Saros {candidate.saros}
                  </option>
                ))}
            </select>
          </label>
          <div className={styles.binCountControl}>
            <label>
              <span>Bins per Saros</span>
              <input
                aria-label="Bins per Saros"
                max={EXPERIMENTAL_BIN_COUNT_MAX}
                min="1"
                onChange={(event) =>
                  writeStoredInteger(
                    BIN_COUNT_STORAGE_KEY,
                    Number(event.target.value),
                    1,
                    EXPERIMENTAL_BIN_COUNT_MAX,
                  )
                }
                step="1"
                type="number"
                value={binCount}
              />
            </label>
            <div>
              <strong>{formatDuration(liveReading.binDurationSeconds)} / bin</strong>
              <small>{seriesAddressCount.toLocaleString()} carrier states</small>
            </div>
            <button
              disabled={binCount === MIXED_RADIX_SAROS_BIN_COUNT}
              onClick={() =>
                writeStoredInteger(
                  BIN_COUNT_STORAGE_KEY,
                  MIXED_RADIX_SAROS_BIN_COUNT,
                  1,
                  EXPERIMENTAL_BIN_COUNT_MAX,
                )
              }
              type="button"
            >
              Reset 9,360
            </button>
          </div>
          <div aria-label="Mixed-radix view" className={styles.viewSwitcher} role="group">
            <button
              aria-pressed={viewMode === "clock"}
              onClick={() => {
                setFollowingLive(true);
                setViewMode("clock");
              }}
              type="button"
            >
              Clock
            </button>
            <button
              aria-pressed={viewMode === "atlas"}
              onClick={() => setViewMode("atlas")}
              type="button"
            >
              Atlas
            </button>
            <button
              aria-pressed={viewMode === "timeline"}
              onClick={() => setViewMode("timeline")}
              type="button"
            >
              Timeline
            </button>
            <button
              aria-pressed={viewMode === "basis"}
              onClick={() => setViewMode("basis")}
              type="button"
            >
              Basis
            </button>
          </div>
          <span className={styles.status}>
            {followingLive ? "following live interval" : "exploring carrier"}
          </span>
        </div>
      </div>

      {viewMode === "clock" ? (
        <>
          <div className={styles.mixedStage}>
            <div className={styles.mixedGlyphColumn}>
              <div className={styles.mixedDepthToolbar}>
                <div>
                  <span>Significance depth</span>
                  <strong>{significanceDepth}</strong>
                  <small>LSB first</small>
                </div>
                <MixedRadixCompositionSwitch
                  onChange={setCompositionMode}
                  value={compositionMode}
                />
                <div className={styles.mixedDepthControls}>
                  <button
                    aria-label="Decrease significance depth"
                    disabled={significanceDepth === 1}
                    onClick={() => setDepth(significanceDepth - 1)}
                    type="button"
                  >
                    −
                  </button>
                  <input
                    aria-label="Mixed-radix significance depth"
                    max={MIXED_RADIX_MAX_SIGNIFICANCE_DEPTH}
                    min="1"
                    onChange={(event) => setDepth(Number(event.target.value))}
                    type="range"
                    value={significanceDepth}
                  />
                  <button
                    aria-label="Increase significance depth"
                    disabled={significanceDepth === MIXED_RADIX_MAX_SIGNIFICANCE_DEPTH}
                    onClick={() => setDepth(significanceDepth + 1)}
                    type="button"
                  >
                    +
                  </button>
                </div>
              </div>
              {compositionMode === "wide" ? (
                <div className={styles.mixedGlyphDepth} data-depth={significanceDepth}>
                  {digitLayers.map((digits, place) => (
                    <figure className={styles.mixedGlyphLayer} key={place}>
                      <figcaption>
                        <strong>P{place}</strong>
                        <span>
                          {place === 0 ? "least-significant set" : `significance set ${place + 1}`}
                        </span>
                      </figcaption>
                      <div className={styles.mixedGlyph}>
                        <GlyphRenderer
                          model={createMixedRadixGlyph({
                            digits,
                            radices,
                            stackOffsetX,
                            stackOffsetY,
                            style: GLYPH_STYLE,
                            accessibilityLabel: `Saros ${interval.saros} mixed-radix significance set ${place + 1}`,
                          })}
                          size="100%"
                        />
                      </div>
                      <SpatialAddress digits={digits} radices={radices} />
                      {place === 0 ? <GlyphRepdigitMeta metadata={glyphMetadata} /> : null}
                    </figure>
                  ))}
                </div>
              ) : (
                <div className={styles.mixedDeepComposition}>
                  <DeepMixedRadixGlyphs
                    accessibilityPrefix={`Saros ${interval.saros}`}
                    digitLayers={digitLayers}
                    radices={radices}
                    stackOffsetX={stackOffsetX}
                    stackOffsetY={stackOffsetY}
                  />
                  <GlyphRepdigitMeta metadata={glyphMetadata} />
                </div>
              )}
            </div>

            <div className={styles.mixedReadout}>
              <header>
                <div>
                  <span>Series phase</span>
                  <strong>{state.seriesPhaseIndex.toString().padStart(2, "0")} / 76</strong>
                </div>
                <div>
                  <span>Saros bin</span>
                  <strong>
                    {state.binIndex.toLocaleString()} / {(binCount - 1).toLocaleString()}
                  </strong>
                </div>
                <div>
                  <span>Carrier index</span>
                  <strong>{state.serialBinIndex.toLocaleString()}</strong>
                </div>
              </header>

              <div className={styles.mixedProgress}>
                <i
                  style={{
                    width: `${((state.binIndex + (followingLive ? liveReading.progressWithinBin : 0)) / binCount) * 100}%`,
                  }}
                />
              </div>

              <div className={styles.mixedControls}>
                <button
                  aria-label="Previous mixed-radix bin"
                  onClick={() => step(-1)}
                  type="button"
                >
                  −
                </button>
                <label>
                  <span>Bin inside Saros</span>
                  <input
                    aria-label="Mixed-radix bin inside Saros"
                    max={binCount - 1}
                    min="0"
                    onChange={(event) => setBin(Number(event.target.value))}
                    type="range"
                    value={state.binIndex}
                  />
                </label>
                <button aria-label="Next mixed-radix bin" onClick={() => step(1)} type="button">
                  +
                </button>
              </div>

              <div className={styles.mixedInputs}>
                <label>
                  <span>Eclipse sequence</span>
                  <input
                    aria-label="Eclipse sequence carrier phase"
                    max={MIXED_RADIX_SERIES_PHASE_COUNT}
                    min="1"
                    onChange={(event) => setSequence(Number(event.target.value))}
                    type="number"
                    value={state.seriesPhaseIndex + 1}
                  />
                </label>
                <label>
                  <span>Exact bin</span>
                  <input
                    aria-label="Exact mixed-radix bin"
                    max={binCount - 1}
                    min="0"
                    onChange={(event) => setBin(Number(event.target.value))}
                    type="number"
                    value={state.binIndex}
                  />
                </label>
                <button
                  className={styles.followButton}
                  disabled={followingLive}
                  onClick={() => setFollowingLive(true)}
                  type="button"
                >
                  Follow live
                </button>
              </div>

              <div className={styles.mixedPresets}>
                <button onClick={() => setBin(0)} type="button">
                  alignment · 0
                </button>
                <button onClick={() => setBin(Math.floor(binCount / 2))} type="button">
                  half · {Math.floor(binCount / 2).toLocaleString()}
                </button>
                <button onClick={() => setBin(binCount - 1)} type="button">
                  edge · {(binCount - 1).toLocaleString()}
                </button>
              </div>

              <dl className={styles.mixedTiming}>
                <div>
                  <dt>Exact Saros bin</dt>
                  <dd>{formatDuration(liveReading.binDurationSeconds)}</dd>
                </div>
                <div>
                  <dt>Next live change</dt>
                  <dd>{formatDuration(Math.max(0, liveReading.timeUntilNextFlip))}</dd>
                </div>
                <div>
                  <dt>Year-scale bin</dt>
                  <dd>{formatDuration(MEAN_TROPICAL_YEAR_SECONDS / binCount)}</dd>
                </div>
              </dl>
            </div>
          </div>

          <MixedRadixSubPeriod
            binCount={binCount}
            compositionMode={compositionMode}
            digitDepth={significanceDepth}
            followingLive={followingLive}
            outerBinDurationSeconds={liveReading.binDurationSeconds}
            outerBinIndex={state.binIndex}
            outerProgress={followingLive ? liveReading.progressWithinBin : 0}
            radices={radices}
            stackOffsetX={stackOffsetX}
            stackOffsetY={stackOffsetY}
          />

          <MixedRadixConverter
            binCount={binCount}
            followingLive={followingLive}
            instant={instant}
            interval={interval}
            key={`converter-${binCount}`}
            onBeginEdit={() => setFollowingLive(false)}
            onSelectBin={setBin}
            radices={radices}
            state={state}
          />

          <div className={styles.alignmentStrip}>
            <article>
              <span>Current eclipse offset</span>
              <strong>
                B7 {state.base7Offset} · B11 {state.base11Offset}
              </strong>
              <small>sequence {state.seriesPhaseIndex + 1}</small>
            </article>
            <span aria-hidden="true">→ {binCount.toLocaleString()} bins →</span>
            <article>
              <span>Next eclipse offset</span>
              <strong>
                B7 {nextBoundary.base7Offset} · B11 {nextBoundary.base11Offset}
              </strong>
              <small>carrier phase advances by one eclipse</small>
            </article>
          </div>

          <div className={styles.stackGrammar}>
            <div>
              <p className="eyebrow">Higher-base arm grammar</p>
              <h3>Seven becomes the anchor; the next octal layer grows outward.</h3>
              <p>
                Value 8 is seven plus a one-stroke continuation. Every new layer overlaps the
                previous tip by a full arm thickness, hiding the seam inside the seven-arm body.
              </p>
            </div>
            <div className={styles.stackSpecimens}>
              {STACK_SPECIMENS.map((digit) => (
                <figure key={digit}>
                  <GlyphRenderer
                    decorative
                    model={createMixedRadixGlyph({
                      digits: [0, 0, 0, 0, 0, digit],
                      radices: MIXED_RADIX_BASES,
                      stackOffsetX,
                      stackOffsetY,
                      style: GLYPH_STYLE,
                    })}
                    size="100%"
                  />
                  <figcaption>{digit}</figcaption>
                </figure>
              ))}
            </div>
          </div>
        </>
      ) : viewMode === "atlas" ? (
        <MixedRadixAtlas
          binCount={binCount}
          compositionMode={compositionMode}
          deepBaseDigitIndex={deepBaseDigitIndex}
          interval={interval}
          liveBinIndex={liveReading.binIndex}
          onCompositionModeChange={setCompositionMode}
          onChooseBin={(binIndex) => {
            setSequence(atlasPhaseOffset + 1);
            setBin(binIndex);
            setViewMode("clock");
          }}
          onDeepBaseChange={setDeepBaseDigitIndex}
          onSelectPhaseOffset={setAtlasPhaseOffset}
          phaseOffset={atlasPhaseOffset}
          radices={radices}
          significanceDepth={significanceDepth}
          stackOffsetX={stackOffsetX}
          stackOffsetY={stackOffsetY}
        />
      ) : viewMode === "timeline" ? (
        <MixedRadixTimeline
          binCount={binCount}
          compositionMode={compositionMode}
          deepBaseDigitIndex={deepBaseDigitIndex}
          interval={interval}
          liveBinIndex={liveReading.binIndex}
          liveProgressWithinBin={liveReading.progressWithinBin}
          onCompositionModeChange={setCompositionMode}
          onDeepBaseChange={setDeepBaseDigitIndex}
          radices={radices}
          stackOffsetX={stackOffsetX}
          stackOffsetY={stackOffsetY}
        />
      ) : (
        <MixedRadixBasisEditor
          basesBySocket={basesBySocket}
          binCount={binCount}
          onChange={setBaseAtSocket}
          onReset={() => writeStoredBases(DEFAULT_BASES_BY_SOCKET)}
          serialBinIndex={state.serialBinIndex}
          stackOffsetX={stackOffsetX}
          stackOffsetY={stackOffsetY}
        />
      )}

      <div className={styles.carrierFacts}>
        <span>
          <strong>{binCount.toLocaleString()}</strong> bins / Saros
        </span>
        <span>
          <strong>77</strong> eclipse offsets
        </span>
        <span>
          <strong>{seriesAddressCount.toLocaleString()}</strong> series-addressed bins
        </span>
        <span>
          <strong>
            {binCount.toLocaleString()}₁₀ = {binCount.toString(8)}₈
          </strong>
        </span>
        <span title="Least common multiple of the six selected projection bases.">
          projection repeat <strong>{basisPeriod.toLocaleString()}</strong>
        </span>
      </div>
    </section>
  );
}

function MixedRadixCompositionSwitch({
  onChange,
  value,
}: {
  readonly onChange: (value: "wide" | "deep") => void;
  readonly value: "wide" | "deep";
}) {
  return (
    <div
      aria-label="Mixed-radix composition"
      className={styles.mixedCompositionSwitch}
      role="group"
    >
      <button aria-pressed={value === "wide"} onClick={() => onChange("wide")} type="button">
        Wide
      </button>
      <button aria-pressed={value === "deep"} onClick={() => onChange("deep")} type="button">
        Deep
      </button>
    </div>
  );
}

function DeepBasePicker({
  accessibilityLabel,
  digitIndex,
  onChange,
  radices,
}: {
  readonly accessibilityLabel: string;
  readonly digitIndex: number;
  readonly onChange: (digitIndex: number) => void;
  readonly radices: readonly number[];
}) {
  return (
    <label className={styles.deepBasePicker}>
      <span>Deep base</span>
      <select
        aria-label={accessibilityLabel}
        onChange={(event) => onChange(Number(event.target.value))}
        value={digitIndex}
      >
        {SOCKET_TO_DIGIT_INDEX.map((candidateDigitIndex, socketIndex) => (
          <option key={candidateDigitIndex} value={candidateDigitIndex}>
            B{radices[candidateDigitIndex]} · {SOCKET_LABELS[socketIndex]}
          </option>
        ))}
      </select>
    </label>
  );
}

function DeepMixedRadixGlyphs({
  accessibilityPrefix,
  compact = false,
  digitLayers,
  radices,
  stackOffsetX,
  stackOffsetY,
}: {
  readonly accessibilityPrefix: string;
  readonly compact?: boolean;
  readonly digitLayers: readonly (readonly number[])[];
  readonly radices: readonly number[];
  readonly stackOffsetX: number;
  readonly stackOffsetY: number;
}) {
  const renderedDepth = Math.max(3, digitLayers.length);
  return (
    <div
      className={`${styles.mixedDeepGrid} ${compact ? styles.mixedDeepGridCompact : ""}`}
      data-depth={digitLayers.length}
    >
      {SOCKET_TO_DIGIT_INDEX.map((digitIndex, socketIndex) => {
        const radix = radices[digitIndex] ?? 2;
        const visibleDigits = deepDigitsForLayers(digitLayers, digitIndex);
        const glyphDigits = renderableDeepDigits(visibleDigits, renderedDepth);
        const glyphRadices = glyphDigits.map(() => radix);
        return (
          <figure data-socket={socketIndex} key={digitIndex}>
            <figcaption>
              <strong>B{radix}</strong>
              <span>{SOCKET_LABELS[socketIndex]}</span>
            </figcaption>
            <div>
              <GlyphRenderer
                model={createMixedRadixGlyph({
                  digits: glyphDigits,
                  radices: glyphRadices,
                  stackOffsetX,
                  stackOffsetY,
                  style: GLYPH_STYLE,
                  accessibilityLabel: `${accessibilityPrefix}, base ${radix}, ${visibleDigits.map((digit, place) => `P${place} ${digit}`).join(", ")}`,
                })}
                size="100%"
              />
            </div>
            <code>{visibleDigits.map((digit, place) => `P${place} ${digit}`).join(" · ")}</code>
          </figure>
        );
      })}
    </div>
  );
}

function MixedRadixSubPeriod({
  binCount,
  compositionMode,
  digitDepth,
  followingLive,
  outerBinDurationSeconds,
  outerBinIndex,
  outerProgress,
  radices,
  stackOffsetX,
  stackOffsetY,
}: {
  readonly binCount: number;
  readonly compositionMode: "wide" | "deep";
  readonly digitDepth: number;
  readonly followingLive: boolean;
  readonly outerBinDurationSeconds: number;
  readonly outerBinIndex: number;
  readonly outerProgress: number;
  readonly radices: readonly number[];
  readonly stackOffsetX: number;
  readonly stackOffsetY: number;
}) {
  const normalizedProgress = clampNumber(outerProgress, 0, 1);
  const scaledSubBin = normalizedProgress * binCount;
  const subBinIndex = Math.min(Math.floor(scaledSubBin), binCount - 1);
  const progressWithinSubBin = normalizedProgress >= 1 ? 1 : scaledSubBin - subBinIndex;
  const subBinDurationSeconds = outerBinDurationSeconds / binCount;
  const timeUntilNextSubBin = followingLive
    ? subBinDurationSeconds * (1 - progressWithinSubBin)
    : subBinDurationSeconds;
  const digitLayers = mixedRadixSignificanceLayersForBases(subBinIndex, digitDepth, radices);
  const metadata = mixedRadixRepdigitMetadata(digitLayers[0] ?? radices.map(() => 0));

  return (
    <section aria-labelledby="mixed-sub-period" className={styles.subPeriod}>
      <header>
        <div>
          <p className="eyebrow">Nested {binCount.toLocaleString()}-step carrier</p>
          <h3 id="mixed-sub-period">Saros day + Saros second</h3>
          <p>
            Each {formatDuration(outerBinDurationSeconds)} Saros day is divided into{" "}
            {binCount.toLocaleString()} Saros seconds using the same bases, significance depth, and{" "}
            {compositionMode} composition.
          </p>
        </div>
        <div className={styles.subPeriodStats}>
          <article>
            <span>Saros day</span>
            <strong>#{outerBinIndex.toLocaleString()}</strong>
            <small>{formatDuration(outerBinDurationSeconds)}</small>
          </article>
          <article>
            <span>Saros second</span>
            <strong>
              {subBinIndex.toLocaleString()} / {(binCount - 1).toLocaleString()}
            </strong>
            <small>{formatDuration(subBinDurationSeconds)}</small>
          </article>
          <article>
            <span>Next second</span>
            <strong>{formatDuration(timeUntilNextSubBin)}</strong>
            <small>
              {followingLive ? `${Math.round(progressWithinSubBin * 100)}% elapsed` : "day start"}
            </small>
          </article>
        </div>
      </header>

      <div aria-label="Progress through current Saros day" className={styles.subPeriodProgress}>
        <i style={{ width: `${normalizedProgress * 100}%` }} />
      </div>

      {compositionMode === "wide" ? (
        <div className={styles.subPeriodWide} data-depth={digitDepth}>
          {digitLayers.map((digits, place) => (
            <figure key={place}>
              <figcaption>
                <strong>P{place}</strong>
                <span>{place === 0 ? "sub-period LSB" : `sub-period level ${place + 1}`}</span>
              </figcaption>
              <div>
                <GlyphRenderer
                  model={createMixedRadixGlyph({
                    digits,
                    radices,
                    stackOffsetX,
                    stackOffsetY,
                    style: GLYPH_STYLE,
                    accessibilityLabel: `Saros second ${subBinIndex}, significance set ${place + 1}`,
                  })}
                  size="100%"
                />
              </div>
              <code>{formatSpatialAddress(digits, radices)}</code>
            </figure>
          ))}
        </div>
      ) : (
        <DeepMixedRadixGlyphs
          accessibilityPrefix={`Saros second ${subBinIndex}`}
          compact
          digitLayers={digitLayers}
          radices={radices}
          stackOffsetX={stackOffsetX}
          stackOffsetY={stackOffsetY}
        />
      )}
      <GlyphRepdigitMeta metadata={metadata} />
    </section>
  );
}

function MixedRadixBasisEditor({
  basesBySocket,
  binCount,
  onChange,
  onReset,
  serialBinIndex,
  stackOffsetX,
  stackOffsetY,
}: {
  readonly basesBySocket: readonly number[];
  readonly binCount: number;
  readonly onChange: (socketIndex: number, base: number) => void;
  readonly onReset: () => void;
  readonly serialBinIndex: number;
  readonly stackOffsetX: number;
  readonly stackOffsetY: number;
}) {
  const radices = radicesFromSocketBases(basesBySocket);
  const digits =
    mixedRadixSignificanceLayersForBases(serialBinIndex, 1, radices)[0] ?? radices.map(() => 0);
  const metadata = mixedRadixRepdigitMetadata(digits);
  const projectionPeriod = leastCommonMultiple(radices);

  return (
    <section aria-labelledby="mixed-basis-editor" className={styles.basisEditor}>
      <header>
        <div>
          <p className="eyebrow">Spatial projection</p>
          <h3 id="mixed-basis-editor">Base set + arm locations</h3>
          <p>
            Choose a unique base from 2–64 at each vertex. Choosing an occupied base swaps the two
            arms; choosing a new base replaces the current one.
          </p>
        </div>
        <button onClick={onReset} type="button">
          Reset canonical basis
        </button>
      </header>

      <div className={styles.basisCanvas}>
        <svg aria-hidden="true" viewBox="0 0 100 100">
          <polygon points="50,8 86,29 86,71 50,92 14,71 14,29" />
        </svg>
        {basesBySocket.map((base, socketIndex) => (
          <label data-socket={socketIndex} key={socketIndex}>
            <span>{SOCKET_LABELS[socketIndex]}</span>
            <select
              aria-label={`Base at ${SOCKET_LABELS[socketIndex]} arm`}
              onChange={(event) => onChange(socketIndex, Number(event.target.value))}
              value={base}
            >
              {AVAILABLE_BASES.map((candidate) => (
                <option key={candidate} value={candidate}>
                  Base {candidate}
                </option>
              ))}
            </select>
          </label>
        ))}
        <div className={styles.basisPreview}>
          <GlyphRenderer
            model={createMixedRadixGlyph({
              digits,
              radices,
              stackOffsetX,
              stackOffsetY,
              style: GLYPH_STYLE,
              accessibilityLabel: "Configured mixed-radix basis preview",
            })}
            size="100%"
          />
        </div>
      </div>

      <div className={styles.basisSummary}>
        <div>
          <span>Clockwise from top</span>
          <code>{basesBySocket.map((base) => `B${base}`).join(" · ")}</code>
        </div>
        <div>
          <span>Projection repeat</span>
          <strong>{projectionPeriod.toLocaleString()} bins</strong>
          <small>
            {projectionPeriod >= binCount
              ? "P0 is unique within one Saros window"
              : "P0 can resolve to multiple dates in one Saros window"}
          </small>
        </div>
        <GlyphRepdigitMeta metadata={metadata} />
      </div>

      <div className={styles.repdigitLegend}>
        <span data-rarity="common">common · everything else</span>
        <span data-rarity="rare">rare · 2+2</span>
        <span data-rarity="epic">epic · 3–4</span>
        <span data-rarity="legendary">legendary · 5 or 2+3</span>
        <span data-rarity="mythic">mythic · 6 or 3+3</span>
      </div>
    </section>
  );
}

function GlyphRepdigitMeta({ metadata }: { readonly metadata: MixedRadixRepdigitMetadata }) {
  const repeatedGroups = metadata.groups.filter((group) => group.effectiveCount >= 2);
  const summary =
    repeatedGroups.length === 0
      ? "no repeated digits"
      : repeatedGroups
          .map((group) =>
            group.effectiveCount === group.count
              ? `${group.digit}×${group.count}`
              : `${group.digit}×${group.count} (+1)`,
          )
          .join(" · ");
  const modifiers = [metadata.zeroBonus ? "zero +1" : null, metadata.bilateral ? "bilateral" : null]
    .filter((modifier): modifier is string => modifier !== null)
    .join(" · ");
  return (
    <div className={styles.glyphMeta} data-rarity={metadata.rarity} title={summary}>
      <strong>{metadata.rarity}</strong>
      <span>
        pattern {metadata.pattern}
        {modifiers === "" ? "" : ` · ${modifiers}`}
      </span>
      <code>{summary}</code>
    </div>
  );
}

function MixedRadixConverter({
  binCount,
  followingLive,
  instant,
  interval,
  onBeginEdit,
  onSelectBin,
  radices,
  state,
}: {
  readonly binCount: number;
  readonly followingLive: boolean;
  readonly instant: number;
  readonly interval: SarosInterval;
  readonly onBeginEdit: () => void;
  readonly onSelectBin: (binIndex: number) => void;
  readonly radices: readonly number[];
  readonly state: MixedRadixState;
}) {
  const [message, setMessage] = useState<string | null>(null);
  const duration = interval.next.epochSeconds - interval.previous.epochSeconds;
  const binStart = interval.previous.epochSeconds + (state.binIndex / binCount) * duration;
  const binEnd = interval.previous.epochSeconds + ((state.binIndex + 1) / binCount) * duration;
  const displayedInstant = followingLive ? instant : binStart;
  const digits =
    mixedRadixSignificanceLayersForBases(state.serialBinIndex, 1, radices)[0] ??
    radices.map(() => 0);
  const projectionIsUnique = leastCommonMultiple(radices) >= binCount;

  const selectDate = (rawValue: string) => {
    onBeginEdit();
    const epochSeconds = new Date(rawValue).getTime() / 1_000;
    if (
      !Number.isFinite(epochSeconds) ||
      epochSeconds < interval.previous.epochSeconds ||
      epochSeconds >= interval.next.epochSeconds
    ) {
      setMessage("Choose a date inside the selected eclipse-to-eclipse Saros window.");
      return;
    }
    const binIndex = Math.min(
      Math.floor(((epochSeconds - interval.previous.epochSeconds) / duration) * binCount),
      binCount - 1,
    );
    onSelectBin(binIndex);
    setMessage(`Date quantized to Saros bin ${binIndex.toLocaleString()}.`);
  };

  const resolveAddress = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    onBeginEdit();
    const formData = new FormData(event.currentTarget);
    const submittedDigits = radices.map((_, digitIndex) =>
      Number(formData.get(`digit-${digitIndex}`)),
    );
    try {
      const matches = mixedRadixBinsForDigits(
        submittedDigits,
        state.sarosSequence,
        radices,
        binCount,
      );
      const binIndex = matches[0];
      if (binIndex === undefined) {
        setMessage("That P0 address does not occur inside this selected Saros window.");
        return;
      }
      onSelectBin(binIndex);
      setMessage(
        matches.length === 1
          ? `Address resolves to Saros bin ${binIndex.toLocaleString()}.`
          : `Address occurs in ${matches.length.toLocaleString()} bins; showing the first, ${binIndex.toLocaleString()}.`,
      );
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "The address is invalid.");
    }
  };

  return (
    <section aria-labelledby="mixed-converter" className={styles.converter}>
      <header>
        <div>
          <p className="eyebrow">Selected Saros window</p>
          <h3 id="mixed-converter">Date ↔ address</h3>
        </div>
        <code>
          eclipse {interval.previous.sequence} → {interval.next.sequence} · carrier P
          {state.seriesPhaseIndex.toString().padStart(2, "0")}
        </code>
      </header>
      <div className={styles.converterGrid}>
        <label className={styles.converterDate}>
          <span>Date and time</span>
          <input
            defaultValue={formatDateTimeLocal(displayedInstant)}
            key={`date-${binCount}-${state.sarosSequence}-${state.binIndex}`}
            max={formatDateTimeLocal(interval.next.epochSeconds)}
            min={formatDateTimeLocal(interval.previous.epochSeconds)}
            onInput={(event) => selectDate(event.currentTarget.value)}
            step="1"
            type="datetime-local"
          />
          <small>Dates are quantized to one of the {binCount.toLocaleString()} exact bins.</small>
        </label>

        <form
          className={styles.converterAddressForm}
          key={`${binCount}-${state.sarosSequence}-${state.binIndex}-${radices.join("-")}`}
          onSubmit={resolveAddress}
        >
          <span>P0 address · spatial order</span>
          <div className={styles.converterDigits}>
            {SOCKET_TO_DIGIT_INDEX.map((digitIndex, socketIndex) => {
              const radix = radices[digitIndex] ?? 2;
              return (
                <label key={socketIndex}>
                  <span>B{radix}</span>
                  <input
                    aria-label={`Converter base ${radix} digit`}
                    defaultValue={digits[digitIndex] ?? 0}
                    max={radix - 1}
                    min="0"
                    name={`digit-${digitIndex}`}
                    required
                    type="number"
                  />
                </label>
              );
            })}
          </div>
          <button type="submit">Find date</button>
        </form>
      </div>
      <div aria-live="polite" className={styles.converterResult}>
        <span>
          {message ??
            (projectionIsUnique
              ? "P0 is unique inside the selected Saros window."
              : "This projection can map one P0 address to multiple dates.")}
        </span>
        <time dateTime={new Date(binStart * 1_000).toISOString()}>
          {formatDisplayDate(binStart)} → {formatDisplayDate(binEnd)}
        </time>
      </div>
    </section>
  );
}

interface MixedRadixTimelineSegment {
  readonly binCount: number;
  readonly compositionMode: "wide" | "deep";
  readonly deepBaseDigitIndex: number | null;
  readonly place: number;
  readonly startBin: number;
  readonly endBin: number;
  readonly digits: readonly number[];
  readonly radices: readonly number[];
  readonly metadata: MixedRadixRepdigitMetadata;
}

function MixedRadixTimeline({
  binCount,
  compositionMode,
  deepBaseDigitIndex,
  interval,
  liveBinIndex,
  liveProgressWithinBin,
  onCompositionModeChange,
  onDeepBaseChange,
  radices,
  stackOffsetX,
  stackOffsetY,
}: {
  readonly binCount: number;
  readonly compositionMode: "wide" | "deep";
  readonly deepBaseDigitIndex: number;
  readonly interval: SarosInterval;
  readonly liveBinIndex: number;
  readonly liveProgressWithinBin: number;
  readonly onCompositionModeChange: (value: "wide" | "deep") => void;
  readonly onDeepBaseChange: (digitIndex: number) => void;
  readonly radices: readonly number[];
  readonly stackOffsetX: number;
  readonly stackOffsetY: number;
}) {
  const windowBinCount = Math.min(TIMELINE_WINDOW_BIN_COUNT, binCount);
  const maximumWindowStart = Math.max(0, binCount - windowBinCount);
  const liveWindowStart = clampInteger(
    liveBinIndex - Math.floor(windowBinCount / 2),
    0,
    maximumWindowStart,
  );
  const [windowStartOverride, setWindowStartOverride] = useState<number | null>(null);
  const [selectedSegment, setSelectedSegment] = useState<MixedRadixTimelineSegment | null>(null);
  const [hoveredSegment, setHoveredSegment] = useState<MixedRadixTimelineSegment | null>(null);
  const timelineScrollerRef = useRef<HTMLDivElement>(null);
  const windowStart = clampInteger(windowStartOverride ?? liveWindowStart, 0, maximumWindowStart);
  const windowEnd = Math.min(windowStart + windowBinCount, binCount);
  const livePosition = liveBinIndex + clampNumber(liveProgressWithinBin, 0, 1);
  const nowFraction =
    livePosition >= windowStart && livePosition <= windowEnd
      ? (livePosition - windowStart) / (windowEnd - windowStart)
      : null;
  const deepRadix = radices[deepBaseDigitIndex] ?? 2;
  const layers = useMemo(() => {
    if (compositionMode === "deep") {
      return [
        buildDeepMixedRadixTimelineSegments(
          windowStart,
          windowEnd,
          interval.previous.sequence,
          radices,
          deepBaseDigitIndex,
          binCount,
        ),
      ];
    }
    return [0, 1, 2].map((place) =>
      buildMixedRadixTimelineSegments(
        windowStart,
        windowEnd,
        place,
        interval.previous.sequence,
        radices,
        binCount,
      ),
    );
  }, [
    compositionMode,
    binCount,
    deepBaseDigitIndex,
    interval.previous.sequence,
    radices,
    windowEnd,
    windowStart,
  ]);
  const segmentMatchesProjection = (segment: MixedRadixTimelineSegment | null) =>
    segment !== null &&
    segment.compositionMode === compositionMode &&
    segment.binCount === binCount &&
    segment.deepBaseDigitIndex === (compositionMode === "deep" ? deepBaseDigitIndex : null);
  const projectedSelectedSegment = segmentMatchesProjection(selectedSegment)
    ? selectedSegment
    : null;
  const projectedHoveredSegment = segmentMatchesProjection(hoveredSegment) ? hoveredSegment : null;
  const activeSegment =
    projectedSelectedSegment ??
    layers[0]?.find(
      (segment) => segment.startBin <= liveBinIndex && liveBinIndex < segment.endBin,
    ) ??
    layers[0]?.[0] ??
    null;
  const inspectedSegment = projectedHoveredSegment ?? activeSegment;
  const windowDurationSeconds =
    binStartEpoch(interval, windowEnd, binCount) - binStartEpoch(interval, windowStart, binCount);

  useEffect(() => {
    const scroller = timelineScrollerRef.current;
    if (scroller === null || liveBinIndex < windowStart || liveBinIndex >= windowEnd) return;
    const frame = window.requestAnimationFrame(() => {
      const liveSegmentCenter = (liveBinIndex + 0.5 - windowStart) / (windowEnd - windowStart);
      scroller.scrollLeft = Math.max(
        0,
        liveSegmentCenter * scroller.scrollWidth - scroller.clientWidth / 2,
      );
    });
    return () => window.cancelAnimationFrame(frame);
  }, [liveBinIndex, windowEnd, windowStart]);

  const shiftWindow = (delta: number) => {
    setWindowStartOverride(clampInteger(windowStart + delta, 0, maximumWindowStart));
    setSelectedSegment(null);
    setHoveredSegment(null);
  };

  return (
    <section aria-labelledby="mixed-timeline" className={styles.timeline}>
      <header className={styles.timelineHeader}>
        <div>
          <p className="eyebrow">
            {compositionMode === "wide"
              ? "Three-scale temporal sequence"
              : "Single-base temporal sequence"}
          </p>
          <h3 id="mixed-timeline">
            {compositionMode === "wide" ? "P0 · P1 · P2 timeline" : `B${deepRadix} deep timeline`}
          </h3>
          <p>
            {compositionMode === "wide"
              ? "Every row shares one scale. Block width is the exact time that address remains active."
              : `Each block is one B${deepRadix} glyph containing P0–P5. Color uses the same repdigit rarity rules across those six visible digits.`}
          </p>
        </div>
        <div className={styles.timelineRange}>
          <strong>
            bins {windowStart.toLocaleString()}–{(windowEnd - 1).toLocaleString()}
          </strong>
          <time>{formatDisplayDate(binStartEpoch(interval, windowStart, binCount))}</time>
          <span>→</span>
          <time>{formatDisplayDate(binStartEpoch(interval, windowEnd, binCount))}</time>
          <small>{formatDuration(windowDurationSeconds)}</small>
        </div>
      </header>

      <div className={styles.timelineControls}>
        <div className={styles.timelineProjectionControls}>
          <MixedRadixCompositionSwitch onChange={onCompositionModeChange} value={compositionMode} />
          {compositionMode === "deep" ? (
            <DeepBasePicker
              accessibilityLabel="Timeline deep base"
              digitIndex={deepBaseDigitIndex}
              onChange={onDeepBaseChange}
              radices={radices}
            />
          ) : null}
        </div>
        <button
          disabled={windowStart === 0}
          onClick={() => shiftWindow(-windowBinCount)}
          type="button"
        >
          ← Earlier
        </button>
        <button
          disabled={windowStartOverride === null}
          onClick={() => {
            setWindowStartOverride(null);
            setSelectedSegment(null);
            setHoveredSegment(null);
          }}
          type="button"
        >
          Center live
        </button>
        <button
          disabled={windowEnd === binCount}
          onClick={() => shiftWindow(windowBinCount)}
          type="button"
        >
          Later →
        </button>
        <output aria-live="polite">
          {inspectedSegment === null
            ? "Hover or select a segment"
            : timelineSegmentSummary(inspectedSegment, interval, binCount)}
        </output>
      </div>

      <div className={styles.timelineScroller} ref={timelineScrollerRef}>
        <div className={styles.timelineTracks} data-composition={compositionMode}>
          {layers.map((segments, rowIndex) => (
            <div className={styles.timelineRow} key={`${compositionMode}-${rowIndex}-${deepRadix}`}>
              <header>
                <strong>{compositionMode === "wide" ? `P${rowIndex}` : `B${deepRadix}`}</strong>
                <span>
                  {compositionMode === "wide"
                    ? rowIndex === 0
                      ? "LSB"
                      : `level ${rowIndex + 1}`
                    : "P0–P5"}
                </span>
              </header>
              <div className={styles.timelineTrack}>
                {segments.map((segment) => {
                  const durationBins = segment.endBin - segment.startBin;
                  const summary = timelineSegmentSummary(segment, interval, binCount);
                  return (
                    <button
                      aria-label={`${compositionMode === "wide" ? `P${segment.place}` : `B${deepRadix} P0 through P5`} ${summary}, ${segment.metadata.rarity}`}
                      aria-pressed={
                        projectedSelectedSegment?.place === segment.place &&
                        projectedSelectedSegment.startBin === segment.startBin
                      }
                      data-rarity={segment.metadata.rarity}
                      key={`${compositionMode}-${deepRadix}-${segment.place}-${segment.startBin}`}
                      onBlur={() => setHoveredSegment(null)}
                      onClick={() => setSelectedSegment(segment)}
                      onFocus={() => setHoveredSegment(segment)}
                      onPointerEnter={() => setHoveredSegment(segment)}
                      onPointerLeave={() => setHoveredSegment(null)}
                      style={{
                        width: `${(durationBins / (windowEnd - windowStart)) * 100}%`,
                      }}
                      title={summary}
                      type="button"
                    >
                      <GlyphRenderer
                        decorative
                        model={createMixedRadixGlyph({
                          digits: segment.digits,
                          radices: segment.radices,
                          stackOffsetX,
                          stackOffsetY,
                          style: RARITY_GLYPH_STYLES[segment.metadata.rarity],
                        })}
                        size="100%"
                      />
                    </button>
                  );
                })}
                {nowFraction === null ? null : (
                  <i
                    aria-hidden="true"
                    className={styles.timelineNowTick}
                    style={{ left: `${nowFraction * 100}%` }}
                  >
                    {rowIndex === 0 ? (
                      <span>now {Math.round(liveProgressWithinBin * 100)}%</span>
                    ) : null}
                  </i>
                )}
              </div>
            </div>
          ))}
        </div>
      </div>

      {activeSegment === null ? null : (
        <article className={styles.timelineSelection} data-rarity={activeSegment.metadata.rarity}>
          <div className={styles.timelineSelectionGlyph}>
            <GlyphRenderer
              model={createMixedRadixGlyph({
                digits: activeSegment.digits,
                radices: activeSegment.radices,
                stackOffsetX,
                stackOffsetY,
                style: RARITY_GLYPH_STYLES[activeSegment.metadata.rarity],
                accessibilityLabel:
                  activeSegment.compositionMode === "wide"
                    ? `Selected P${activeSegment.place} mixed-radix glyph`
                    : `Selected base ${deepRadix} deep glyph, P0 through P5`,
              })}
              size="100%"
            />
          </div>
          <div className={styles.timelineSelectionInfo}>
            <p className="eyebrow">
              Selected segment ·{" "}
              {activeSegment.compositionMode === "wide"
                ? `P${activeSegment.place}`
                : `Deep B${deepRadix}`}
            </p>
            <h4>
              Bins {activeSegment.startBin.toLocaleString()}–
              {(activeSegment.endBin - 1).toLocaleString()}
            </h4>
            <div>
              <time>
                {formatDisplayDate(binStartEpoch(interval, activeSegment.startBin, binCount))}
              </time>
              <span>→</span>
              <time>
                {formatDisplayDate(binStartEpoch(interval, activeSegment.endBin, binCount))}
              </time>
            </div>
            <strong>
              {formatDuration(
                binStartEpoch(interval, activeSegment.endBin, binCount) -
                  binStartEpoch(interval, activeSegment.startBin, binCount),
              )}
            </strong>
            {activeSegment.compositionMode === "wide" ? (
              <SpatialAddress digits={activeSegment.digits} radices={activeSegment.radices} />
            ) : (
              <code className={styles.deepAddress}>
                {formatDeepAddress(activeSegment.digits, deepRadix)}
              </code>
            )}
            <GlyphRepdigitMeta metadata={activeSegment.metadata} />
          </div>
        </article>
      )}
    </section>
  );
}

function MixedRadixAtlas({
  binCount,
  compositionMode,
  deepBaseDigitIndex,
  interval,
  liveBinIndex,
  onCompositionModeChange,
  onChooseBin,
  onDeepBaseChange,
  onSelectPhaseOffset,
  phaseOffset,
  radices,
  significanceDepth,
  stackOffsetX,
  stackOffsetY,
}: {
  readonly binCount: number;
  readonly compositionMode: "wide" | "deep";
  readonly deepBaseDigitIndex: number;
  readonly interval: SarosInterval;
  readonly liveBinIndex: number;
  readonly onCompositionModeChange: (value: "wide" | "deep") => void;
  readonly onChooseBin: (binIndex: number) => void;
  readonly onDeepBaseChange: (digitIndex: number) => void;
  readonly onSelectPhaseOffset: (phaseOffset: number) => void;
  readonly phaseOffset: number;
  readonly radices: readonly number[];
  readonly significanceDepth: number;
  readonly stackOffsetX: number;
  readonly stackOffsetY: number;
}) {
  const storedLayout = useStoredPair(ATLAS_LAYOUT_STORAGE_KEY, "columns", "rows", 4, 4);
  const columns = clampInteger(storedLayout.first, 1, ATLAS_MAX_COLUMNS);
  const rows = clampInteger(storedLayout.second, 1, ATLAS_MAX_ROWS);
  const [page, setPage] = useState<number | null>(null);
  const phaseState = mixedRadixState(0, phaseOffset + 1, binCount);
  const pageSize = columns * rows;
  const pageCount = Math.ceil(binCount / pageSize);
  const livePage = Math.floor(liveBinIndex / pageSize);
  const selectedPage = Math.min(page ?? livePage, pageCount - 1);
  const firstBin = selectedPage * pageSize;
  const lastBin = Math.min(firstBin + pageSize, binCount) - 1;
  const duration = interval.next.epochSeconds - interval.previous.epochSeconds;
  const deepRadix = radices[deepBaseDigitIndex] ?? 2;

  const setLayout = (nextColumns: number, nextRows: number) => {
    const normalizedColumns = clampInteger(nextColumns, 1, ATLAS_MAX_COLUMNS);
    const normalizedRows = clampInteger(nextRows, 1, ATLAS_MAX_ROWS);
    setPage(null);
    writeStoredPair(ATLAS_LAYOUT_STORAGE_KEY, "columns", normalizedColumns, "rows", normalizedRows);
  };
  const setSelectedPage = (value: number) => {
    setPage(clampInteger(value, 0, pageCount - 1));
  };

  return (
    <section aria-labelledby="mixed-atlas" className={styles.atlas}>
      <header className={styles.atlasPrintHeader}>
        <div>
          <p className="eyebrow">Printable temporal atlas</p>
          <h3 id="mixed-atlas">
            Saros {interval.saros} · page {selectedPage + 1}
          </h3>
          <p>
            Bins {firstBin.toLocaleString()}–{lastBin.toLocaleString()} · depth{" "}
            {compositionMode === "deep" ? DEEP_RARITY_SIGNIFICANCE_DEPTH : significanceDepth} ·
            phase P{phaseOffset.toString().padStart(2, "0")} ·{" "}
            {compositionMode === "wide" ? "Wide" : `Deep B${deepRadix}`}
          </p>
        </div>
        <div className={styles.atlasDateRange}>
          <time>{formatDisplayDate(binStartEpoch(interval, firstBin, binCount))}</time>
          <span>→</span>
          <time>{formatDisplayDate(binStartEpoch(interval, lastBin + 1, binCount))}</time>
        </div>
      </header>

      <div className={styles.atlasControls}>
        <div className={styles.atlasProjectionControls}>
          <span>Composition</span>
          <MixedRadixCompositionSwitch onChange={onCompositionModeChange} value={compositionMode} />
          {compositionMode === "deep" ? (
            <DeepBasePicker
              accessibilityLabel="Atlas deep base"
              digitIndex={deepBaseDigitIndex}
              onChange={onDeepBaseChange}
              radices={radices}
            />
          ) : null}
        </div>
        <div className={styles.atlasLayoutInputs}>
          <label>
            <span>Columns</span>
            <input
              max={ATLAS_MAX_COLUMNS}
              min="1"
              onChange={(event) => setLayout(Number(event.target.value), rows)}
              type="number"
              value={columns}
            />
          </label>
          <span>×</span>
          <label>
            <span>Rows</span>
            <input
              max={ATLAS_MAX_ROWS}
              min="1"
              onChange={(event) => setLayout(columns, Number(event.target.value))}
              type="number"
              value={rows}
            />
          </label>
        </div>
        <label className={styles.atlasPhasePicker}>
          <span>Phase offset</span>
          <select
            aria-label="Atlas phase offset"
            onChange={(event) => {
              onSelectPhaseOffset(Number(event.target.value));
              setPage(null);
            }}
            value={phaseOffset}
          >
            {Array.from({ length: MIXED_RADIX_SERIES_PHASE_COUNT }, (_, offset) => {
              const candidate = mixedRadixState(0, offset + 1, binCount);
              return (
                <option key={offset} value={offset}>
                  P{offset.toString().padStart(2, "0")} · B7 {candidate.base7Offset} · B11{" "}
                  {candidate.base11Offset}
                </option>
              );
            })}
          </select>
          <small>
            B7 {phaseState.base7Offset} · B11 {phaseState.base11Offset}
          </small>
        </label>
        <div className={styles.atlasPagination}>
          <button
            aria-label="Previous atlas page"
            disabled={selectedPage === 0}
            onClick={() => setSelectedPage(selectedPage - 1)}
            type="button"
          >
            ←
          </button>
          <label>
            <span>Page</span>
            <input
              aria-label="Atlas page"
              max={pageCount}
              min="1"
              onChange={(event) => setSelectedPage(Number(event.target.value) - 1)}
              type="number"
              value={selectedPage + 1}
            />
            <small>/ {pageCount.toLocaleString()}</small>
          </label>
          <button
            aria-label="Next atlas page"
            disabled={selectedPage >= pageCount - 1}
            onClick={() => setSelectedPage(selectedPage + 1)}
            type="button"
          >
            →
          </button>
        </div>
        <button
          className={styles.atlasLiveButton}
          disabled={page === null}
          onClick={() => setPage(null)}
          type="button"
        >
          Present page
        </button>
        <button className={styles.atlasPrintButton} onClick={() => window.print()} type="button">
          Print selected page
        </button>
      </div>

      <div
        className={styles.atlasGrid}
        style={{
          gridTemplateColumns: `repeat(${columns}, minmax(0, 1fr))`,
          gridTemplateRows: `repeat(${rows}, minmax(0, 1fr))`,
        }}
      >
        {Array.from({ length: Math.max(lastBin - firstBin + 1, 0) }, (_, offset) => {
          const binIndex = firstBin + offset;
          const state = mixedRadixState(binIndex, phaseOffset + 1, binCount);
          const layers = mixedRadixSignificanceLayersForBases(
            state.serialBinIndex,
            significanceDepth,
            radices,
          );
          const deepLayers =
            compositionMode === "deep"
              ? mixedRadixSignificanceLayersForBases(
                  state.serialBinIndex,
                  DEEP_RARITY_SIGNIFICANCE_DEPTH,
                  radices,
                )
              : layers;
          const digits = layers[0] ?? radices.map(() => 0);
          const deepDigits = deepDigitsForLayers(deepLayers, deepBaseDigitIndex);
          const deepGlyphDigits = renderableDeepDigits(deepDigits);
          const metadata = mixedRadixRepdigitMetadata(
            compositionMode === "wide" ? digits : deepDigits,
          );
          const epochSeconds = interval.previous.epochSeconds + (binIndex / binCount) * duration;
          return (
            <button
              aria-label={`Open Saros bin ${binIndex}, ${formatDisplayDate(epochSeconds)}, ${compositionMode === "deep" ? `base ${deepRadix}, ` : ""}${metadata.rarity}`}
              className={styles.atlasCell}
              data-rarity={metadata.rarity}
              key={binIndex}
              onClick={() => onChooseBin(binIndex)}
              type="button"
            >
              <header>
                <strong>#{binIndex.toLocaleString()}</strong>
                <time dateTime={new Date(epochSeconds * 1_000).toISOString()}>
                  {formatDisplayDate(epochSeconds)}
                </time>
              </header>
              <div
                className={styles.atlasGlyphs}
                data-composition={compositionMode}
                data-depth={significanceDepth}
              >
                {compositionMode === "wide" ? (
                  layers.map((layerDigits, place) => {
                    const layerMetadata = mixedRadixRepdigitMetadata(layerDigits);
                    return (
                      <GlyphRenderer
                        accessibilityLabel={`Bin ${binIndex}, significance set ${place + 1}, ${layerMetadata.rarity}`}
                        key={place}
                        model={createMixedRadixGlyph({
                          digits: layerDigits,
                          radices,
                          stackOffsetX,
                          stackOffsetY,
                          style: RARITY_GLYPH_STYLES[layerMetadata.rarity],
                        })}
                        size="100%"
                      />
                    );
                  })
                ) : (
                  <GlyphRenderer
                    accessibilityLabel={`Bin ${binIndex}, base ${deepRadix}, P0 through P${DEEP_RARITY_SIGNIFICANCE_DEPTH - 1}, ${metadata.rarity}`}
                    model={createMixedRadixGlyph({
                      digits: deepGlyphDigits,
                      radices: deepGlyphDigits.map(() => deepRadix),
                      stackOffsetX,
                      stackOffsetY,
                      style: RARITY_GLYPH_STYLES[metadata.rarity],
                    })}
                    size="100%"
                  />
                )}
              </div>
              <code>
                {compositionMode === "wide"
                  ? formatSpatialAddress(digits, radices)
                  : formatDeepAddress(deepDigits, deepRadix)}
              </code>
            </button>
          );
        })}
      </div>
    </section>
  );
}

function SpatialAddress({
  digits,
  radices,
}: {
  readonly digits: readonly number[];
  readonly radices: readonly number[];
}) {
  return (
    <div
      aria-label={SOCKET_TO_DIGIT_INDEX.map(
        (digitIndex, socketIndex) =>
          `${SOCKET_LABELS[socketIndex]} ${digits[digitIndex] ?? 0}_${radices[digitIndex] ?? "?"}`,
      ).join(" · ")}
      className={styles.mixedAddress}
    >
      {SOCKET_TO_DIGIT_INDEX.map((digitIndex, socketIndex) => {
        const radix = radices[digitIndex] ?? 2;
        const digit = digits[digitIndex] ?? 0;
        return (
          <div
            data-direction={radix === 7 ? "forward" : radix === 11 ? "backward" : undefined}
            key={socketIndex}
          >
            <span>
              B{radix}
              {radix === 7 ? " ↗" : radix === 11 ? " ↘" : ""}
            </span>
            <strong>{digit}</strong>
          </div>
        );
      })}
    </div>
  );
}

function buildMixedRadixTimelineSegments(
  windowStart: number,
  windowEnd: number,
  place: number,
  sarosSequence: number,
  radices: readonly number[],
  binCount: number,
): readonly MixedRadixTimelineSegment[] {
  const segments: MixedRadixTimelineSegment[] = [];
  const segmentRadices = Object.freeze([...radices]);
  for (let binIndex = windowStart; binIndex < windowEnd; binIndex += 1) {
    const serialBinIndex = mixedRadixState(binIndex, sarosSequence, binCount).serialBinIndex;
    const digits =
      mixedRadixSignificanceLayersForBases(serialBinIndex, place + 1, radices)[place] ??
      radices.map(() => 0);
    const previous = segments.at(-1);
    if (previous !== undefined && arraysEqual(previous.digits, digits)) {
      segments[segments.length - 1] = Object.freeze({
        ...previous,
        endBin: binIndex + 1,
      });
      continue;
    }
    segments.push(
      Object.freeze({
        binCount,
        compositionMode: "wide",
        deepBaseDigitIndex: null,
        place,
        startBin: binIndex,
        endBin: binIndex + 1,
        digits: Object.freeze([...digits]),
        radices: segmentRadices,
        metadata: mixedRadixRepdigitMetadata(digits),
      }),
    );
  }
  return Object.freeze(segments);
}

function buildDeepMixedRadixTimelineSegments(
  windowStart: number,
  windowEnd: number,
  sarosSequence: number,
  radices: readonly number[],
  deepBaseDigitIndex: number,
  binCount: number,
): readonly MixedRadixTimelineSegment[] {
  const segments: MixedRadixTimelineSegment[] = [];
  const radix = radices[deepBaseDigitIndex] ?? 2;
  const segmentRadices = Object.freeze(
    Array.from({ length: DEEP_RARITY_SIGNIFICANCE_DEPTH }, () => radix),
  );
  for (let binIndex = windowStart; binIndex < windowEnd; binIndex += 1) {
    const serialBinIndex = mixedRadixState(binIndex, sarosSequence, binCount).serialBinIndex;
    const digits = deepDigitsForLayers(
      mixedRadixSignificanceLayersForBases(serialBinIndex, DEEP_RARITY_SIGNIFICANCE_DEPTH, radices),
      deepBaseDigitIndex,
    );
    const previous = segments.at(-1);
    if (previous !== undefined && arraysEqual(previous.digits, digits)) {
      segments[segments.length - 1] = Object.freeze({
        ...previous,
        endBin: binIndex + 1,
      });
      continue;
    }
    segments.push(
      Object.freeze({
        binCount,
        compositionMode: "deep",
        deepBaseDigitIndex,
        place: 0,
        startBin: binIndex,
        endBin: binIndex + 1,
        digits: Object.freeze([...digits]),
        radices: segmentRadices,
        metadata: mixedRadixRepdigitMetadata(digits),
      }),
    );
  }
  return Object.freeze(segments);
}

function timelineSegmentSummary(
  segment: MixedRadixTimelineSegment,
  interval: SarosInterval,
  binCount: number,
) {
  const durationSeconds =
    binStartEpoch(interval, segment.endBin, binCount) -
    binStartEpoch(interval, segment.startBin, binCount);
  return `${formatDuration(durationSeconds)} · ${formatDisplayDate(binStartEpoch(interval, segment.startBin, binCount))} → ${formatDisplayDate(binStartEpoch(interval, segment.endBin, binCount))}`;
}

function arraysEqual(left: readonly number[], right: readonly number[]) {
  return left.length === right.length && left.every((value, index) => value === right[index]);
}

function deepDigitsForLayers(digitLayers: readonly (readonly number[])[], digitIndex: number) {
  return digitLayers.map((digits) => digits[digitIndex] ?? 0);
}

function renderableDeepDigits(digits: readonly number[], minimumDepth = 3) {
  return Array.from({ length: Math.max(minimumDepth, digits.length) }, (_, place) =>
    Math.trunc(digits[place] ?? 0),
  );
}

function formatDeepAddress(digits: readonly number[], radix: number) {
  return `B${radix} · ${digits.map((digit, place) => `P${place} ${digit}`).join(" · ")}`;
}

function formatSpatialAddress(digits: readonly number[], radices: readonly number[]) {
  const values = SOCKET_TO_DIGIT_INDEX.map(
    (digitIndex) => `${digits[digitIndex] ?? 0}_${radices[digitIndex] ?? "?"}`,
  );
  return `${values.slice(0, 3).join("·")} / ${values.slice(3).join("·")}`;
}

function binStartEpoch(interval: SarosInterval, binIndex: number, binCount: number) {
  const duration = interval.next.epochSeconds - interval.previous.epochSeconds;
  return interval.previous.epochSeconds + (binIndex / binCount) * duration;
}

function formatDateTimeLocal(epochSeconds: number) {
  const date = new Date(epochSeconds * 1_000);
  const pad = (value: number) => String(value).padStart(2, "0");
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
}

function formatDisplayDate(epochSeconds: number) {
  return new Intl.DateTimeFormat(undefined, {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(new Date(epochSeconds * 1_000));
}

function clampInteger(value: number, minimum: number, maximum: number) {
  if (!Number.isFinite(value)) return minimum;
  return Math.min(maximum, Math.max(minimum, Math.trunc(value)));
}

function clampNumber(value: number, minimum: number, maximum: number) {
  if (!Number.isFinite(value)) return 0;
  const clamped = Math.min(maximum, Math.max(minimum, value));
  return Object.is(clamped, -0) ? 0 : clamped;
}

function radicesFromSocketBases(basesBySocket: readonly number[]) {
  const radices = Array.from({ length: SOCKET_TO_DIGIT_INDEX.length }, () => 2);
  SOCKET_TO_DIGIT_INDEX.forEach((digitIndex, socketIndex) => {
    radices[digitIndex] = basesBySocket[socketIndex] ?? DEFAULT_BASES_BY_SOCKET[socketIndex] ?? 2;
  });
  return Object.freeze(radices);
}

function leastCommonMultiple(values: readonly number[]) {
  return values.reduce(
    (result, value) => (result * value) / greatestCommonDivisor(result, value),
    1,
  );
}

function greatestCommonDivisor(left: number, right: number) {
  let a = Math.abs(Math.trunc(left));
  let b = Math.abs(Math.trunc(right));
  while (b !== 0) {
    const remainder = a % b;
    a = b;
    b = remainder;
  }
  return Math.max(a, 1);
}

function useStoredInteger(
  storageKey: string,
  defaultValue: number,
  minimum: number,
  maximum: number,
) {
  const rawValue = useSyncExternalStore(
    subscribePersistentSettings,
    () => readStorageValue(storageKey),
    () => null,
  );
  if (rawValue === null) return defaultValue;
  const value = Number(rawValue);
  return Number.isSafeInteger(value) ? clampInteger(value, minimum, maximum) : defaultValue;
}

function writeStoredInteger(
  storageKey: string,
  rawValue: number,
  minimum: number,
  maximum: number,
) {
  if (typeof window === "undefined") return;
  const value = clampInteger(rawValue, minimum, maximum);
  try {
    window.localStorage.setItem(storageKey, String(value));
    window.dispatchEvent(new Event(PERSISTENT_SETTINGS_EVENT));
  } catch {
    // Storage is a convenience for the lab; private mode must not block the controls.
  }
}

function useStoredBases(): readonly number[] {
  const rawValue = useSyncExternalStore(
    subscribePersistentSettings,
    () => readStorageValue(BASES_STORAGE_KEY),
    () => null,
  );
  if (rawValue === null) return DEFAULT_BASES_BY_SOCKET;
  try {
    const parsed = JSON.parse(rawValue) as unknown;
    if (!Array.isArray(parsed) || parsed.length !== SOCKET_TO_DIGIT_INDEX.length) {
      return DEFAULT_BASES_BY_SOCKET;
    }
    const bases = parsed.map(Number);
    if (
      bases.some((base) => !Number.isSafeInteger(base) || base < 2 || base > 64) ||
      new Set(bases).size !== bases.length
    ) {
      return DEFAULT_BASES_BY_SOCKET;
    }
    return bases;
  } catch {
    return DEFAULT_BASES_BY_SOCKET;
  }
}

function writeStoredBases(basesBySocket: readonly number[]) {
  if (typeof window === "undefined") return;
  try {
    window.localStorage.setItem(BASES_STORAGE_KEY, JSON.stringify(basesBySocket));
    window.dispatchEvent(new Event(PERSISTENT_SETTINGS_EVENT));
  } catch {
    // Storage is a convenience for the lab; private mode must not block the controls.
  }
}

function useStoredPair(
  storageKey: string,
  firstKey: string,
  secondKey: string,
  defaultFirst: number,
  defaultSecond: number,
) {
  const rawValue = useSyncExternalStore(
    subscribePersistentSettings,
    () => readStorageValue(storageKey),
    () => null,
  );
  if (rawValue === null) return { first: defaultFirst, second: defaultSecond };
  try {
    const parsed = JSON.parse(rawValue) as unknown;
    if (parsed === null || typeof parsed !== "object") {
      return { first: defaultFirst, second: defaultSecond };
    }
    const record = parsed as Record<string, unknown>;
    const first = Number(record[firstKey]);
    const second = Number(record[secondKey]);
    return Number.isFinite(first) && Number.isFinite(second)
      ? { first, second }
      : { first: defaultFirst, second: defaultSecond };
  } catch {
    return { first: defaultFirst, second: defaultSecond };
  }
}

function subscribePersistentSettings(onStoreChange: () => void) {
  window.addEventListener("storage", onStoreChange);
  window.addEventListener(PERSISTENT_SETTINGS_EVENT, onStoreChange);
  return () => {
    window.removeEventListener("storage", onStoreChange);
    window.removeEventListener(PERSISTENT_SETTINGS_EVENT, onStoreChange);
  };
}

function readStorageValue(storageKey: string) {
  try {
    return window.localStorage.getItem(storageKey);
  } catch {
    return null;
  }
}

function writeStoredPair(
  storageKey: string,
  firstKey: string,
  firstValue: number,
  secondKey: string,
  secondValue: number,
) {
  if (typeof window === "undefined") return;
  try {
    window.localStorage.setItem(
      storageKey,
      JSON.stringify({ [firstKey]: firstValue, [secondKey]: secondValue }),
    );
    window.dispatchEvent(new Event(PERSISTENT_SETTINGS_EVENT));
  } catch {
    // Storage is a convenience for the lab; private mode must not block the controls.
  }
}

function formatDuration(rawSeconds: number) {
  const seconds = Math.max(0, rawSeconds);
  if (seconds >= 86_400) return `${(seconds / 86_400).toFixed(2)} d`;
  if (seconds >= 3_600) return `${(seconds / 3_600).toFixed(2)} h`;
  if (seconds >= 60) return `${(seconds / 60).toFixed(1)} min`;
  return `${seconds.toFixed(1)} s`;
}
