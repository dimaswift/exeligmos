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
  MIXED_RADIX_SERIES_ADDRESS_COUNT,
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
const ATLAS_LAYOUT_STORAGE_KEY = "fractonica.mixed-radix.atlas-layout.v1";
const BASES_STORAGE_KEY = "fractonica.mixed-radix.bases-by-socket.v1";
const STACK_OFFSETS_STORAGE_KEY = "fractonica.mixed-radix.stack-offsets.v2";
const STACK_OFFSET_LIMIT = 32;
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
  const liveReading = useMemo(
    () =>
      mixedRadixClockReading({
        previousEpochSeconds: interval.previous.epochSeconds,
        nextEpochSeconds: interval.next.epochSeconds,
        instantEpochSeconds: instant,
        sarosSequence: interval.previous.sequence,
      }),
    [instant, interval],
  );
  const [followingLive, setFollowingLive] = useState(true);
  const [explorerSequence, setExplorerSequence] = useState(liveReading.sarosSequence);
  const [explorerBin, setExplorerBin] = useState(liveReading.binIndex);
  const [significanceDepth, setSignificanceDepth] = useState(1);
  const [viewMode, setViewMode] = useState<"clock" | "atlas" | "timeline" | "basis">("clock");
  const [atlasPhaseOffset, setAtlasPhaseOffset] = useState(
    mixedRadixState(0, interval.previous.sequence).seriesPhaseIndex,
  );
  const storedOffsets = useStoredPair(
    STACK_OFFSETS_STORAGE_KEY,
    "x",
    "y",
    DEFAULT_MIXED_RADIX_STACK_OFFSET_X,
    DEFAULT_MIXED_RADIX_STACK_OFFSET_Y,
  );
  const stackOffsetX = clampNumber(storedOffsets.first, -STACK_OFFSET_LIMIT, STACK_OFFSET_LIMIT);
  const stackOffsetY = clampNumber(storedOffsets.second, -STACK_OFFSET_LIMIT, STACK_OFFSET_LIMIT);
  const basesBySocket = useStoredBases();
  const radices = radicesFromSocketBases(basesBySocket);

  const state = followingLive ? liveReading : mixedRadixState(explorerBin, explorerSequence);
  const digitLayers = mixedRadixSignificanceLayersForBases(
    state.serialBinIndex,
    significanceDepth,
    radices,
  );
  const glyphMetadata = mixedRadixRepdigitMetadata(digitLayers[0] ?? radices.map(() => 0));
  const basisPeriod = leastCommonMultiple(radices);
  const nextBoundary = mixedRadixState(0, state.sarosSequence + 1);

  const setBin = (value: number) => {
    setFollowingLive(false);
    setExplorerBin(Math.min(MIXED_RADIX_SAROS_BIN_COUNT - 1, Math.max(0, Math.trunc(value))));
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
  const setStackOffset = (axis: "x" | "y", rawValue: number) => {
    const value = clampNumber(rawValue, -STACK_OFFSET_LIMIT, STACK_OFFSET_LIMIT);
    const nextX = axis === "x" ? value : stackOffsetX;
    const nextY = axis === "y" ? value : stackOffsetY;
    writeStoredPair(STACK_OFFSETS_STORAGE_KEY, "x", nextX, "y", nextY);
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
      (((state.seriesPhaseIndex * MIXED_RADIX_SAROS_BIN_COUNT + state.binIndex + delta) %
        MIXED_RADIX_SERIES_ADDRESS_COUNT) +
        MIXED_RADIX_SERIES_ADDRESS_COUNT) %
      MIXED_RADIX_SERIES_ADDRESS_COUNT;
    setExplorerSequence(Math.floor(absolute / MIXED_RADIX_SAROS_BIN_COUNT) + 1);
    setExplorerBin(absolute % MIXED_RADIX_SAROS_BIN_COUNT);
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
            </div>

            <div className={styles.mixedReadout}>
              <header>
                <div>
                  <span>Series phase</span>
                  <strong>{state.seriesPhaseIndex.toString().padStart(2, "0")} / 76</strong>
                </div>
                <div>
                  <span>Saros bin</span>
                  <strong>{state.binIndex.toLocaleString()} / 9,359</strong>
                </div>
                <div>
                  <span>Carrier index</span>
                  <strong>{state.serialBinIndex.toLocaleString()}</strong>
                </div>
              </header>

              <div className={styles.mixedProgress}>
                <i
                  style={{
                    width: `${((state.binIndex + (followingLive ? liveReading.progressWithinBin : 0)) / MIXED_RADIX_SAROS_BIN_COUNT) * 100}%`,
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
                    max={MIXED_RADIX_SAROS_BIN_COUNT - 1}
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
                    max={MIXED_RADIX_SAROS_BIN_COUNT - 1}
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
                <button onClick={() => setBin(4_680)} type="button">
                  half · 4,680
                </button>
                <button onClick={() => setBin(9_359)} type="button">
                  edge · 9,359
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
                  <dd>
                    {formatDuration(MEAN_TROPICAL_YEAR_SECONDS / MIXED_RADIX_SAROS_BIN_COUNT)}
                  </dd>
                </div>
              </dl>
            </div>
          </div>

          <MixedRadixConverter
            followingLive={followingLive}
            instant={instant}
            interval={interval}
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
            <span aria-hidden="true">→ 9,360 bins →</span>
            <article>
              <span>Next eclipse offset</span>
              <strong>
                B7 {nextBoundary.base7Offset} · B11 {nextBoundary.base11Offset}
              </strong>
              <small>canonical carrier phase advances by one eclipse</small>
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
              <StackOffsetControls
                onChange={setStackOffset}
                onReset={() => {
                  writeStoredPair(
                    STACK_OFFSETS_STORAGE_KEY,
                    "x",
                    DEFAULT_MIXED_RADIX_STACK_OFFSET_X,
                    "y",
                    DEFAULT_MIXED_RADIX_STACK_OFFSET_Y,
                  );
                }}
                x={stackOffsetX}
                y={stackOffsetY}
              />
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
          interval={interval}
          liveBinIndex={liveReading.binIndex}
          onChooseBin={(binIndex) => {
            setSequence(atlasPhaseOffset + 1);
            setBin(binIndex);
            setViewMode("clock");
          }}
          onSelectPhaseOffset={setAtlasPhaseOffset}
          phaseOffset={atlasPhaseOffset}
          radices={radices}
          significanceDepth={significanceDepth}
          stackOffsetX={stackOffsetX}
          stackOffsetY={stackOffsetY}
        />
      ) : viewMode === "timeline" ? (
        <MixedRadixTimeline
          interval={interval}
          liveBinIndex={liveReading.binIndex}
          liveProgressWithinBin={liveReading.progressWithinBin}
          radices={radices}
          stackOffsetX={stackOffsetX}
          stackOffsetY={stackOffsetY}
        />
      ) : (
        <MixedRadixBasisEditor
          basesBySocket={basesBySocket}
          onChange={setBaseAtSocket}
          onReset={() => writeStoredBases(DEFAULT_BASES_BY_SOCKET)}
          serialBinIndex={state.serialBinIndex}
          stackOffsetX={stackOffsetX}
          stackOffsetY={stackOffsetY}
        />
      )}

      <div className={styles.carrierFacts}>
        <span>
          <strong>9,360</strong> bins / Saros
        </span>
        <span>
          <strong>77</strong> eclipse offsets
        </span>
        <span>
          <strong>{MIXED_RADIX_SERIES_ADDRESS_COUNT.toLocaleString()}</strong> series-addressed bins
        </span>
        <span>
          <strong>9,360₁₀ = 22,220₈</strong>
        </span>
        <span title="Least common multiple of the six selected projection bases.">
          projection repeat <strong>{basisPeriod.toLocaleString()}</strong>
        </span>
      </div>
    </section>
  );
}

function MixedRadixBasisEditor({
  basesBySocket,
  onChange,
  onReset,
  serialBinIndex,
  stackOffsetX,
  stackOffsetY,
}: {
  readonly basesBySocket: readonly number[];
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
            {projectionPeriod >= MIXED_RADIX_SAROS_BIN_COUNT
              ? "P0 is unique within one Saros window"
              : "P0 can resolve to multiple dates in one Saros window"}
          </small>
        </div>
        <GlyphRepdigitMeta metadata={metadata} />
      </div>

      <div className={styles.repdigitLegend}>
        <span data-rarity="common">common · everything else</span>
        <span data-rarity="rare">rare · 3</span>
        <span data-rarity="epic">epic · 4 or 2+2</span>
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

function StackOffsetControls({
  onChange,
  onReset,
  x,
  y,
}: {
  readonly onChange: (axis: "x" | "y", value: number) => void;
  readonly onReset: () => void;
  readonly x: number;
  readonly y: number;
}) {
  return (
    <div className={styles.stackTuning}>
      <header>
        <div>
          <span>Continuation offset</span>
          <small>negative Y pulls the next layer inward</small>
        </div>
        <code>
          X {formatOffset(x)} · Y {formatOffset(y)}
        </code>
      </header>
      <div>
        {(["x", "y"] as const).map((axis) => {
          const value = axis === "x" ? x : y;
          const label = axis.toUpperCase();
          return (
            <label key={axis}>
              <span>{label}</span>
              <input
                aria-label={`Stack continuation ${label} offset`}
                max={STACK_OFFSET_LIMIT}
                min={-STACK_OFFSET_LIMIT}
                onChange={(event) => onChange(axis, Number(event.target.value))}
                step="0.25"
                type="range"
                value={value}
              />
              <input
                aria-label={`Exact stack continuation ${label} offset`}
                max={STACK_OFFSET_LIMIT}
                min={-STACK_OFFSET_LIMIT}
                onInput={(event) => onChange(axis, Number(event.currentTarget.value))}
                step="0.25"
                type="number"
                value={value}
              />
            </label>
          );
        })}
      </div>
      <button onClick={onReset} type="button">
        Reset offsets
      </button>
    </div>
  );
}

function MixedRadixConverter({
  followingLive,
  instant,
  interval,
  onBeginEdit,
  onSelectBin,
  radices,
  state,
}: {
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
  const binStart =
    interval.previous.epochSeconds + (state.binIndex / MIXED_RADIX_SAROS_BIN_COUNT) * duration;
  const binEnd =
    interval.previous.epochSeconds +
    ((state.binIndex + 1) / MIXED_RADIX_SAROS_BIN_COUNT) * duration;
  const displayedInstant = followingLive ? instant : binStart;
  const digits =
    mixedRadixSignificanceLayersForBases(state.serialBinIndex, 1, radices)[0] ??
    radices.map(() => 0);
  const projectionIsUnique = leastCommonMultiple(radices) >= MIXED_RADIX_SAROS_BIN_COUNT;

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
      Math.floor(
        ((epochSeconds - interval.previous.epochSeconds) / duration) * MIXED_RADIX_SAROS_BIN_COUNT,
      ),
      MIXED_RADIX_SAROS_BIN_COUNT - 1,
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
      const matches = mixedRadixBinsForDigits(submittedDigits, state.sarosSequence, radices);
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
            key={`date-${state.sarosSequence}-${state.binIndex}`}
            max={formatDateTimeLocal(interval.next.epochSeconds)}
            min={formatDateTimeLocal(interval.previous.epochSeconds)}
            onInput={(event) => selectDate(event.currentTarget.value)}
            step="1"
            type="datetime-local"
          />
          <small>Dates are quantized to one of the 9,360 exact bins.</small>
        </label>

        <form
          className={styles.converterAddressForm}
          key={`${state.sarosSequence}-${state.binIndex}-${radices.join("-")}`}
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
  readonly place: number;
  readonly startBin: number;
  readonly endBin: number;
  readonly digits: readonly number[];
  readonly metadata: MixedRadixRepdigitMetadata;
}

function MixedRadixTimeline({
  interval,
  liveBinIndex,
  liveProgressWithinBin,
  radices,
  stackOffsetX,
  stackOffsetY,
}: {
  readonly interval: SarosInterval;
  readonly liveBinIndex: number;
  readonly liveProgressWithinBin: number;
  readonly radices: readonly number[];
  readonly stackOffsetX: number;
  readonly stackOffsetY: number;
}) {
  const maximumWindowStart = MIXED_RADIX_SAROS_BIN_COUNT - TIMELINE_WINDOW_BIN_COUNT;
  const liveWindowStart = clampInteger(
    liveBinIndex - Math.floor(TIMELINE_WINDOW_BIN_COUNT / 2),
    0,
    maximumWindowStart,
  );
  const [windowStartOverride, setWindowStartOverride] = useState<number | null>(null);
  const [selectedSegment, setSelectedSegment] = useState<MixedRadixTimelineSegment | null>(null);
  const [hoveredSegment, setHoveredSegment] = useState<MixedRadixTimelineSegment | null>(null);
  const timelineScrollerRef = useRef<HTMLDivElement>(null);
  const windowStart = windowStartOverride ?? liveWindowStart;
  const windowEnd = Math.min(windowStart + TIMELINE_WINDOW_BIN_COUNT, MIXED_RADIX_SAROS_BIN_COUNT);
  const livePosition = liveBinIndex + clampNumber(liveProgressWithinBin, 0, 1);
  const nowFraction =
    livePosition >= windowStart && livePosition <= windowEnd
      ? (livePosition - windowStart) / (windowEnd - windowStart)
      : null;
  const layers = useMemo(
    () =>
      [0, 1, 2].map((place) =>
        buildMixedRadixTimelineSegments(
          windowStart,
          windowEnd,
          place,
          interval.previous.sequence,
          radices,
        ),
      ),
    [interval.previous.sequence, radices, windowEnd, windowStart],
  );
  const activeSegment =
    selectedSegment ??
    layers[0]?.find(
      (segment) => segment.startBin <= liveBinIndex && liveBinIndex < segment.endBin,
    ) ??
    layers[0]?.[0] ??
    null;
  const inspectedSegment = hoveredSegment ?? activeSegment;
  const windowDurationSeconds =
    binStartEpoch(interval, windowEnd) - binStartEpoch(interval, windowStart);

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
          <p className="eyebrow">Three-scale temporal sequence</p>
          <h3 id="mixed-timeline">P0 · P1 · P2 timeline</h3>
          <p>
            Every row shares one scale. Block width is the exact time that address remains active.
          </p>
        </div>
        <div className={styles.timelineRange}>
          <strong>
            bins {windowStart.toLocaleString()}–{(windowEnd - 1).toLocaleString()}
          </strong>
          <time>{formatDisplayDate(binStartEpoch(interval, windowStart))}</time>
          <span>→</span>
          <time>{formatDisplayDate(binStartEpoch(interval, windowEnd))}</time>
          <small>{formatDuration(windowDurationSeconds)}</small>
        </div>
      </header>

      <div className={styles.timelineControls}>
        <button
          disabled={windowStart === 0}
          onClick={() => shiftWindow(-TIMELINE_WINDOW_BIN_COUNT)}
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
          disabled={windowEnd === MIXED_RADIX_SAROS_BIN_COUNT}
          onClick={() => shiftWindow(TIMELINE_WINDOW_BIN_COUNT)}
          type="button"
        >
          Later →
        </button>
        <output aria-live="polite">
          {inspectedSegment === null
            ? "Hover or select a segment"
            : timelineSegmentSummary(inspectedSegment, interval)}
        </output>
      </div>

      <div className={styles.timelineScroller} ref={timelineScrollerRef}>
        <div className={styles.timelineTracks}>
          {layers.map((segments, place) => (
            <div className={styles.timelineRow} key={place}>
              <header>
                <strong>P{place}</strong>
                <span>{place === 0 ? "LSB" : `level ${place + 1}`}</span>
              </header>
              <div className={styles.timelineTrack}>
                {segments.map((segment) => {
                  const durationBins = segment.endBin - segment.startBin;
                  const summary = timelineSegmentSummary(segment, interval);
                  return (
                    <button
                      aria-label={`P${place} ${summary}`}
                      aria-pressed={
                        selectedSegment?.place === segment.place &&
                        selectedSegment.startBin === segment.startBin
                      }
                      data-rarity={segment.metadata.rarity}
                      key={`${place}-${segment.startBin}`}
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
                          radices,
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
                    {place === 0 ? (
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
                radices,
                stackOffsetX,
                stackOffsetY,
                style: RARITY_GLYPH_STYLES[activeSegment.metadata.rarity],
                accessibilityLabel: `Selected P${activeSegment.place} mixed-radix glyph`,
              })}
              size="100%"
            />
          </div>
          <div className={styles.timelineSelectionInfo}>
            <p className="eyebrow">Selected segment · P{activeSegment.place}</p>
            <h4>
              Bins {activeSegment.startBin.toLocaleString()}–
              {(activeSegment.endBin - 1).toLocaleString()}
            </h4>
            <div>
              <time>{formatDisplayDate(binStartEpoch(interval, activeSegment.startBin))}</time>
              <span>→</span>
              <time>{formatDisplayDate(binStartEpoch(interval, activeSegment.endBin))}</time>
            </div>
            <strong>
              {formatDuration(
                binStartEpoch(interval, activeSegment.endBin) -
                  binStartEpoch(interval, activeSegment.startBin),
              )}
            </strong>
            <SpatialAddress digits={activeSegment.digits} radices={radices} />
            <GlyphRepdigitMeta metadata={activeSegment.metadata} />
          </div>
        </article>
      )}
    </section>
  );
}

function MixedRadixAtlas({
  interval,
  liveBinIndex,
  onChooseBin,
  onSelectPhaseOffset,
  phaseOffset,
  radices,
  significanceDepth,
  stackOffsetX,
  stackOffsetY,
}: {
  readonly interval: SarosInterval;
  readonly liveBinIndex: number;
  readonly onChooseBin: (binIndex: number) => void;
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
  const phaseState = mixedRadixState(0, phaseOffset + 1);
  const pageSize = columns * rows;
  const pageCount = Math.ceil(MIXED_RADIX_SAROS_BIN_COUNT / pageSize);
  const livePage = Math.floor(liveBinIndex / pageSize);
  const selectedPage = Math.min(page ?? livePage, pageCount - 1);
  const firstBin = selectedPage * pageSize;
  const lastBin = Math.min(firstBin + pageSize, MIXED_RADIX_SAROS_BIN_COUNT) - 1;
  const duration = interval.next.epochSeconds - interval.previous.epochSeconds;

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
            Bins {firstBin.toLocaleString()}–{lastBin.toLocaleString()} · depth {significanceDepth}{" "}
            · phase P{phaseOffset.toString().padStart(2, "0")}
          </p>
        </div>
        <div className={styles.atlasDateRange}>
          <time>{formatDisplayDate(binStartEpoch(interval, firstBin))}</time>
          <span>→</span>
          <time>{formatDisplayDate(binStartEpoch(interval, lastBin + 1))}</time>
        </div>
      </header>

      <div className={styles.atlasControls}>
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
              const candidate = mixedRadixState(0, offset + 1);
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
          const state = mixedRadixState(binIndex, phaseOffset + 1);
          const layers = mixedRadixSignificanceLayersForBases(
            state.serialBinIndex,
            significanceDepth,
            radices,
          );
          const digits = layers[0] ?? radices.map(() => 0);
          const metadata = mixedRadixRepdigitMetadata(digits);
          const epochSeconds =
            interval.previous.epochSeconds + (binIndex / MIXED_RADIX_SAROS_BIN_COUNT) * duration;
          return (
            <button
              aria-label={`Open Saros bin ${binIndex}, ${formatDisplayDate(epochSeconds)}, ${metadata.rarity}`}
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
              <div className={styles.atlasGlyphs} data-depth={significanceDepth}>
                {layers.map((layerDigits, place) => {
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
                })}
              </div>
              <code>{formatSpatialAddress(digits, radices)}</code>
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
): readonly MixedRadixTimelineSegment[] {
  const segments: MixedRadixTimelineSegment[] = [];
  for (let binIndex = windowStart; binIndex < windowEnd; binIndex += 1) {
    const serialBinIndex = mixedRadixState(binIndex, sarosSequence).serialBinIndex;
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
        place,
        startBin: binIndex,
        endBin: binIndex + 1,
        digits: Object.freeze([...digits]),
        metadata: mixedRadixRepdigitMetadata(digits),
      }),
    );
  }
  return Object.freeze(segments);
}

function timelineSegmentSummary(segment: MixedRadixTimelineSegment, interval: SarosInterval) {
  const durationSeconds =
    binStartEpoch(interval, segment.endBin) - binStartEpoch(interval, segment.startBin);
  return `${formatDuration(durationSeconds)} · ${formatDisplayDate(binStartEpoch(interval, segment.startBin))} → ${formatDisplayDate(binStartEpoch(interval, segment.endBin))}`;
}

function arraysEqual(left: readonly number[], right: readonly number[]) {
  return left.length === right.length && left.every((value, index) => value === right[index]);
}

function formatSpatialAddress(digits: readonly number[], radices: readonly number[]) {
  const values = SOCKET_TO_DIGIT_INDEX.map(
    (digitIndex) => `${digits[digitIndex] ?? 0}_${radices[digitIndex] ?? "?"}`,
  );
  return `${values.slice(0, 3).join("·")} / ${values.slice(3).join("·")}`;
}

function binStartEpoch(interval: SarosInterval, binIndex: number) {
  const duration = interval.next.epochSeconds - interval.previous.epochSeconds;
  return interval.previous.epochSeconds + (binIndex / MIXED_RADIX_SAROS_BIN_COUNT) * duration;
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

function formatOffset(value: number) {
  return value
    .toFixed(2)
    .replace(/\.00$/, "")
    .replace(/(\.\d)0$/, "$1");
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
