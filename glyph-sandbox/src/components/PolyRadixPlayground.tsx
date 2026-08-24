import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import {
  analyzeComposite,
  analyzeTemporal,
  DEFAULT_PHASE_TOLERANCE,
  eventFilterLabel,
  scanStructuralEvents,
  TEMPORAL_FRAMES,
  UINT16_MAX,
  wrapUint16,
} from "../poly-radix/analysis";
import type {
  EventFilterId,
  EventFilterMode,
  StructuralEvent,
} from "../poly-radix/types";
import type { SandboxConfig } from "../types";
import { PolyRadixGlyph } from "./PolyRadixGlyph";
import type {
  PolyGlyphDebugOptions,
  PolyGlyphSelection,
} from "./PolyRadixGlyph";

interface PolyRadixPlaygroundProps {
  readonly armConfig: SandboxConfig;
  readonly onOpenFoundry: () => void;
}

const VALUE_STORAGE_KEY = "glyph-foundry.poly-radix.value.v1";
const BASES_STORAGE_KEY = "glyph-foundry.poly-radix.bases.v1";
const DEFAULT_BASE_ORDER = Object.freeze([8, 13, 9, 11]);
const EVENT_FILTERS: readonly EventFilterId[] = [
  "binary-palindrome",
  "binary-symmetry",
  "repdigit",
  "radix-palindrome",
  "repeated-block",
  "residue-conjunction",
  "phase-conjunction",
];

const DEFAULT_DEBUG: PolyGlyphDebugOptions = {
  scaffold: false,
  bitIndexes: false,
  radixLabels: true,
  residueValues: true,
  orientation: false,
  boundingGeometry: false,
};

export function PolyRadixPlayground({ armConfig, onOpenFoundry }: PolyRadixPlaygroundProps) {
  const [value, setValue] = useState(loadStoredValue);
  const [radices, setRadices] = useState<readonly number[]>(loadStoredRadices);
  const [stepSize, setStepSize] = useState(1);
  const [speed, setSpeed] = useState(5);
  const [playing, setPlaying] = useState(false);
  const [showDecimal, setShowDecimal] = useState(true);
  const [debug, setDebug] = useState<PolyGlyphDebugOptions>(DEFAULT_DEBUG);
  const [selection, setSelection] = useState<PolyGlyphSelection>({ kind: "core" });
  const [wrappedRadices, setWrappedRadices] = useState<readonly number[]>([]);
  const [phaseTolerance, setPhaseTolerance] = useState(DEFAULT_PHASE_TOLERANCE);
  const [eventMode, setEventMode] = useState<EventFilterMode>("or");
  const [eventFilters, setEventFilters] = useState<ReadonlySet<EventFilterId>>(
    () => new Set(["binary-symmetry", "repdigit", "residue-conjunction"]),
  );
  const [events, setEvents] = useState<readonly StructuralEvent[]>([]);
  const [scanRequested, setScanRequested] = useState(0);
  const [scanning, setScanning] = useState(false);
  const svgRef = useRef<SVGSVGElement>(null);
  const analysis = useMemo(
    () => analyzeComposite(value, radices, phaseTolerance),
    [phaseTolerance, radices, value],
  );
  const temporal = useMemo(
    () => TEMPORAL_FRAMES.map((frame) => analyzeTemporal(value, frame)),
    [value],
  );

  useEffect(() => {
    localStorage.setItem(VALUE_STORAGE_KEY, String(value));
  }, [value]);

  useEffect(() => {
    localStorage.setItem(BASES_STORAGE_KEY, JSON.stringify(radices));
    setEvents([]);
  }, [radices]);

  const advance = useCallback((delta: number) => {
    setValue((current) => {
      const next = wrapUint16(current + delta);
      if (delta > 0) {
        setWrappedRadices(radices.filter((radix) => next % radix < current % radix));
      } else if (delta < 0) {
        setWrappedRadices(radices.filter((radix) => next % radix > current % radix));
      }
      return next;
    });
  }, [radices]);

  useEffect(() => {
    if (!playing) return;
    const timer = window.setInterval(() => advance(stepSize), 1000 / speed);
    return () => window.clearInterval(timer);
  }, [advance, playing, speed, stepSize]);

  useEffect(() => {
    if (wrappedRadices.length === 0) return;
    const timer = window.setTimeout(() => setWrappedRadices([]), 420);
    return () => window.clearTimeout(timer);
  }, [wrappedRadices]);

  useEffect(() => {
    if (scanRequested === 0) return;
    setScanning(true);
    const timer = window.setTimeout(() => {
      const nextEvents = scanStructuralEvents(radices, eventFilters, eventMode, phaseTolerance);
      setEvents(nextEvents);
      setScanning(false);
    }, 30);
    return () => window.clearTimeout(timer);
  }, [eventFilters, eventMode, phaseTolerance, radices, scanRequested]);

  const setDirectValue = (next: number) => {
    setPlaying(false);
    setWrappedRadices([]);
    setValue(Math.min(UINT16_MAX, Math.max(0, Math.trunc(next))));
  };

  const toggleEventFilter = (filter: EventFilterId) => {
    setEventFilters((current) => {
      const next = new Set(current);
      if (next.has(filter)) next.delete(filter);
      else next.add(filter);
      return next;
    });
  };

  const updateRadix = (index: number, rawValue: number) => {
    const radix = Math.min(64, Math.max(2, Math.trunc(rawValue)));
    if (radices.some((candidate, candidateIndex) => candidateIndex !== index && candidate === radix)) return;
    setRadices((current) => current.map((candidate, candidateIndex) => candidateIndex === index ? radix : candidate));
  };

  const moveRadix = (index: number, direction: -1 | 1) => {
    const target = index + direction;
    if (target < 0 || target >= radices.length) return;
    setRadices((current) => {
      const next = [...current];
      [next[index], next[target]] = [next[target] ?? next[index] ?? 2, next[index] ?? next[target] ?? 2];
      return next;
    });
  };

  const removeRadix = (index: number) => {
    if (radices.length <= 2) return;
    const removed = radices[index];
    setRadices((current) => current.filter((_, candidateIndex) => candidateIndex !== index));
    if (selection.kind === "radix" && selection.radix === removed) setSelection({ kind: "core" });
  };

  const addRadix = () => {
    if (radices.length >= 6) return;
    const radix = Array.from({ length: 63 }, (_, index) => index + 2).find((candidate) => !radices.includes(candidate));
    if (radix !== undefined) setRadices((current) => [...current, radix]);
  };

  const jumpEvent = (direction: 1 | -1) => {
    if (events.length === 0) return;
    const next = direction > 0
      ? events.find((event) => event.value > value) ?? events[0]
      : [...events].reverse().find((event) => event.value < value) ?? events.at(-1);
    if (next !== undefined) setDirectValue(next.value);
  };

  const downloadSvg = () => {
    const svg = svgRef.current;
    if (svg === null) return;
    const serialized = new XMLSerializer().serializeToString(svg);
    const blob = new Blob([`<?xml version="1.0" encoding="UTF-8"?>\n${serialized}`], { type: "image/svg+xml" });
    const href = URL.createObjectURL(blob);
    const anchor = document.createElement("a");
    anchor.href = href;
    anchor.download = `poly-radix-${analysis.binary.fixedWord}.svg`;
    anchor.click();
    URL.revokeObjectURL(href);
  };

  return (
    <div className="poly-app">
      <header className="poly-topbar">
        <button className="poly-brand" onClick={() => window.scrollTo({ top: 0, behavior: "smooth" })} type="button">
          <span className="poly-brand-orbit" aria-hidden="true">✣</span>
          <span><strong>Poly-Radix Orrery</strong><small>simultaneous numerical projections</small></span>
        </button>
        <div className="poly-basis-badge" aria-label={`Radix basis ${radices.join(", ")}, clockwise from top`}>
          <span>RADIX BASIS</span><strong>{radices.join(" · ")}</strong>
        </div>
        <nav className="poly-header-actions" aria-label="Poly-radix actions">
          <button className="quiet-button" onClick={() => setShowDecimal((current) => !current)} type="button">
            {showDecimal ? "Hide decimal" : "Show decimal"}
          </button>
          <button className="quiet-button" onClick={onOpenFoundry} type="button">Arm Foundry</button>
          <button className="primary-button" onClick={downloadSvg} type="button">Download SVG</button>
        </nav>
      </header>

      <main className="poly-main">
        <section className="poly-control-deck" aria-label="Number explorer controls">
          <div className="poly-control-heading">
            <p className="eyebrow">Number explorer</p>
            <h1>One state, {radices.length + 1} simultaneous views.</h1>
          </div>
          <div className="poly-value-controls">
            {showDecimal ? (
              <label className="poly-number-input">
                <span>Unsigned state</span>
                <input
                  aria-label="Unsigned 16-bit integer"
                  max={UINT16_MAX}
                  min="0"
                  onChange={(event) => setDirectValue(Number(event.target.value))}
                  type="number"
                  value={value}
                />
              </label>
            ) : (
              <div className="poly-decimal-hidden"><span>Decimal reference hidden</span><strong>16-bit state remains exact</strong></div>
            )}
            <div className="poly-hex-reference">
              <span>HEX</span><strong>{value.toString(16).toUpperCase().padStart(4, "0")}</strong>
            </div>
          </div>
          <input
            aria-label="16-bit state slider"
            className="poly-state-slider"
            max={UINT16_MAX}
            min="0"
            onChange={(event) => setDirectValue(Number(event.target.value))}
            type="range"
            value={value}
          />
          <div className="poly-transport">
            <button aria-label="Previous structural event" disabled={events.length === 0} onClick={() => jumpEvent(-1)} type="button">◇←</button>
            <button aria-label="Decrement value" onClick={() => advance(-stepSize)} type="button">−</button>
            <button
              aria-pressed={playing}
              className="poly-play-button"
              onClick={() => setPlaying((current) => !current)}
              type="button"
            >
              {playing ? "Pause" : "Play"}
            </button>
            <button aria-label="Increment value" onClick={() => advance(stepSize)} type="button">+</button>
            <button aria-label="Next structural event" disabled={events.length === 0} onClick={() => jumpEvent(1)} type="button">→◇</button>
            <label><span>Step</span><input aria-label="Step size" max="4096" min="1" onChange={(event) => setStepSize(Math.max(1, Number(event.target.value)))} type="number" value={stepSize} /></label>
            <label><span>Speed</span><input aria-label="Playback speed" max="60" min="0.25" onChange={(event) => setSpeed(Number(event.target.value))} step="0.25" type="number" value={speed} /><small>/s</small></label>
            <button aria-label="Random 16-bit state" onClick={() => setDirectValue(Math.floor(Math.random() * 65_536))} type="button">Random</button>
          </div>
          <div className="poly-speed-presets" aria-label="Playback speed presets">
            {[1, 5, 10, 30, 60].map((preset) => (
              <button aria-pressed={speed === preset} key={preset} onClick={() => setSpeed(preset)} type="button">{preset}/s</button>
            ))}
          </div>
        </section>

        <section className="poly-stage-grid">
          <article className="poly-canvas-card">
            <header>
              <div><p className="eyebrow light">Compound phase instrument</p><h2>{analysis.binary.fixedWord}</h2></div>
              <div className="poly-live-stats"><span>Q {analysis.supercycleIndex}</span><span>R {analysis.outerPhase}</span><span>{analysis.resonanceScore.toFixed(2)} resonance</span></div>
            </header>
            <div className="poly-canvas-stage">
              <PolyRadixGlyph
                ref={svgRef}
                analysis={analysis}
                armConfig={armConfig}
                debug={debug}
                onSelect={setSelection}
                wrappedRadices={wrappedRadices}
              />
              <div className="poly-supercycle-meter" title={`${analysis.outerPhase} of ${analysis.lcm}`}>
                <span style={{ width: `${analysis.outerPhase / analysis.lcm * 100}%` }} />
              </div>
            </div>
          </article>

          <aside className="poly-inspector">
            <section className="poly-panel poly-inspection-panel">
              <header><p className="eyebrow">Glyph inspector</p><span>click any part</span></header>
              <SelectionDetails analysis={analysis} selection={selection} />
            </section>

            <section className="poly-panel">
              <header><p className="eyebrow">Debug overlay</p><span>semantic SVG</span></header>
              <div className="poly-debug-grid">
                {(Object.keys(debug) as Array<keyof PolyGlyphDebugOptions>).map((key) => (
                  <label key={key}>
                    <input
                      checked={debug[key]}
                      onChange={(event) => setDebug((current) => ({ ...current, [key]: event.target.checked }))}
                      type="checkbox"
                    />
                    <span>{debugLabel(key)}</span>
                  </label>
                ))}
              </div>
            </section>

            <section className="poly-panel poly-basis-editor">
              <header><p className="eyebrow">Base composition</p><span>clockwise from top</span></header>
              <ol>
                {radices.map((radix, index) => (
                  <li key={radix}>
                    <span>{positionLabel(index, radices.length)}</span>
                    <label>
                      <small>Base</small>
                      <input
                        aria-label={`Base at position ${index + 1}`}
                        max="64"
                        min="2"
                        onChange={(event) => updateRadix(index, Number(event.target.value))}
                        type="number"
                        value={radix}
                      />
                    </label>
                    <button aria-label={`Move base ${radix} earlier`} disabled={index === 0} onClick={() => moveRadix(index, -1)} type="button">↑</button>
                    <button aria-label={`Move base ${radix} later`} disabled={index === radices.length - 1} onClick={() => moveRadix(index, 1)} type="button">↓</button>
                    <button aria-label={`Remove base ${radix}`} disabled={radices.length <= 2} onClick={() => removeRadix(index)} type="button">×</button>
                  </li>
                ))}
              </ol>
              <div className="poly-basis-editor-actions">
                <button disabled={radices.length >= 6} onClick={addRadix} type="button">+ base</button>
                <button onClick={() => setRadices(DEFAULT_BASE_ORDER)} type="button">Reset order</button>
              </div>
            </section>

            <section className="poly-panel poly-cycle-panel">
              <header><p className="eyebrow">Outer supercycle</p><span>{analysis.lcm.toLocaleString()} states</span></header>
              <div className="poly-cycle-value"><strong>{analysis.outerPhase.toLocaleString()}</strong><span>/ {analysis.lcm.toLocaleString()}</span></div>
              <dl>
                <div><dt>cycle index Q</dt><dd>{analysis.supercycleIndex}</dd></div>
                <div><dt>product</dt><dd>{analysis.product.toLocaleString()}</dd></div>
                <div><dt>basis</dt><dd>{analysis.lcm === analysis.product ? "pairwise coprime" : "contains overlap"}</dd></div>
              </dl>
            </section>
          </aside>
        </section>

        <section className="poly-analysis-grid">
          <article className="poly-analysis-card poly-radix-table-card">
            <header><div><p className="eyebrow">Radix projections</p><h2>Residue is phase. Representation is morphology.</h2></div></header>
            <div className="poly-radix-table" role="table" aria-label="Selected base analyses">
              <div className="poly-table-head" role="row"><span>Base</span><span>Residue</span><span>Phase</span><span>Full representation</span><span>Structure</span></div>
              {analysis.radices.map((radix) => (
                <button key={radix.radix} onClick={() => setSelection({ kind: "radix", radix: radix.radix })} role="row" type="button">
                  <strong role="cell">{radix.radix}</strong>
                  <span role="cell">{radix.residue}</span>
                  <span role="cell">{formatPercent(radix.normalizedPhase)}</span>
                  <code role="cell">{radix.representation}<sub>{radix.radix}</sub></code>
                  <span className="poly-badges" role="cell">
                    {radix.isRepdigit ? <em>repdigit ×{radix.repdigitLength}</em> : null}
                    {radix.isPalindrome ? <em>palindrome</em> : null}
                    {radix.repeatCount > 1 ? <em>period {radix.minimalPeriod}</em> : null}
                    {!radix.isRepdigit && !radix.isPalindrome && radix.repeatCount === 1 ? <i>—</i> : null}
                  </span>
                </button>
              ))}
            </div>
          </article>

          <article className="poly-analysis-card poly-binary-card">
            <header><div><p className="eyebrow">Binary morphology</p><h2>Fixed word + significant word</h2></div></header>
            <div className="poly-binary-words"><code>{analysis.binary.fixedWord}</code><code>{analysis.binary.significantWord}</code></div>
            <dl className="poly-metric-list">
              <div><dt>Popcount</dt><dd>{analysis.binary.popcount}</dd></div>
              <div><dt>Fixed rotation period</dt><dd>{analysis.binary.rotationalPeriod}</dd></div>
              <div><dt>Significant period</dt><dd>{analysis.binary.significantPeriod}</dd></div>
              <div><dt>Reflection axes</dt><dd>{analysis.binary.reflectionAxes.length}</dd></div>
              <div><dt>Fixed palindrome</dt><dd>{yesNo(analysis.binary.fixedPalindrome)}</dd></div>
              <div><dt>Significant palindrome</dt><dd>{yesNo(analysis.binary.significantPalindrome)}</dd></div>
              <div><dt>Alternating</dt><dd>{yesNo(analysis.binary.significantAlternating)}</dd></div>
              <div><dt>16-bit complement</dt><dd>{analysis.binary.complement.toString(16).toUpperCase().padStart(4, "0")}</dd></div>
            </dl>
          </article>

          <article className="poly-analysis-card poly-conjunction-card">
            <header><div><p className="eyebrow">Cross-base resonance</p><h2>Conjunctions</h2></div></header>
            <label className="poly-tolerance-control"><span>Phase tolerance</span><strong>{phaseTolerance.toFixed(3)}</strong><input aria-label="Phase conjunction tolerance" max="0.25" min="0" onChange={(event) => setPhaseTolerance(Number(event.target.value))} step="0.005" type="range" value={phaseTolerance} /></label>
            <div className="poly-conjunction-groups">
              {analysis.equalDigitGroups.length === 0 ? <p>No equal residue values.</p> : analysis.equalDigitGroups.map((group) => <div key={group.residue}><strong>r = {group.residue}</strong><span>bases {group.radices.join(" · ")}</span></div>)}
              {analysis.phaseConjunctions.length === 0 ? <p>No phase pairs within tolerance.</p> : analysis.phaseConjunctions.map((pair) => <div key={pair.radices.join("-")}><strong>{pair.radices.join(" ↔ ")}</strong><span>distance {pair.distance.toFixed(4)}</span></div>)}
            </div>
          </article>
        </section>

        <section className="poly-temporal-section">
          <header><div><p className="eyebrow">Temporal frames</p><h2>The same 16-bit phase inside three cycles.</h2></div><span>f = {temporal[0]?.normalizedPhase.toFixed(8)}</span></header>
          <div className="poly-temporal-grid">
            {temporal.map((frame) => (
              <article key={frame.frame.id}>
                <header><strong>{frame.frame.label}</strong><span>{frame.frame.days.toLocaleString(undefined, { maximumFractionDigits: 7 })} days</span></header>
                <div className="poly-temporal-orbit"><span style={{ transform: `rotate(${frame.degrees}deg)` }}><i /></span><strong>{frame.degrees.toFixed(3)}°</strong></div>
                <dl>
                  <div><dt>elapsed</dt><dd>{formatDays(frame.elapsedDays)}</dd></div>
                  <div><dt>remaining</dt><dd>{formatDays(frame.remainingDays)}</dd></div>
                  <div><dt>one bin</dt><dd>{formatDuration(frame.binDurationSeconds)}</dd></div>
                </dl>
              </article>
            ))}
          </div>
        </section>

        <section className="poly-event-section">
          <header>
            <div><p className="eyebrow">Event scanner</p><h2>Search all 65,536 states for structural events.</h2></div>
            <div className="poly-event-actions">
              <div className="poly-mode-toggle" aria-label="Event filter logic">
                <button aria-pressed={eventMode === "or"} onClick={() => setEventMode("or")} type="button">OR</button>
                <button aria-pressed={eventMode === "and"} onClick={() => setEventMode("and")} type="button">AND</button>
              </div>
              <button className="primary-button" disabled={eventFilters.size === 0 || scanning} onClick={() => setScanRequested((current) => current + 1)} type="button">
                {scanning ? "Scanning…" : "Scan 65,536"}
              </button>
            </div>
          </header>
          <div className="poly-event-filters">
            {EVENT_FILTERS.map((filter) => (
              <label key={filter}><input checked={eventFilters.has(filter)} onChange={() => toggleEventFilter(filter)} type="checkbox" /><span>{eventFilterLabel(filter)}</span></label>
            ))}
          </div>
          <div className="poly-event-results">
            <header><strong>{events.length === 0 ? "No scan results yet" : `${events.length.toLocaleString()} events`}</strong><span>{events.length > 80 ? "showing first 80" : "click a state to inspect"}</span></header>
            <div>
              {events.slice(0, 80).map((event) => (
                <button aria-pressed={event.value === value} key={event.value} onClick={() => setDirectValue(event.value)} type="button">
                  <strong>{event.value.toString(16).toUpperCase().padStart(4, "0")}</strong>
                  {showDecimal ? <span>{event.value}</span> : null}
                  <small>{event.labels.slice(0, 3).join(" · ")}</small>
                </button>
              ))}
            </div>
          </div>
        </section>

        <footer className="poly-footer">
          <p>
            <strong>Invariant:</strong> one unsigned 16-bit number. <strong>Projections:</strong> one main 16-bit Foundry glyph plus ordered residue glyphs in bases {radices.join(", ")}.
            {` Every glyph derives from the current ${armConfig.layoutPreset} / ${armConfig.strokePreset} Foundry grammar; exact-width custom geometry is reused directly.`}
          </p>
          <button className="quiet-button" onClick={onOpenFoundry} type="button">Edit the shared arm grammar in Glyph Foundry →</button>
        </footer>
      </main>
    </div>
  );
}

function SelectionDetails({ analysis, selection }: {
  readonly analysis: ReturnType<typeof analyzeComposite>;
  readonly selection: PolyGlyphSelection;
}) {
  if (selection.kind === "bit") {
    const state = analysis.binary.fixedBits[selection.bitIndex] ?? 0;
    return <div className="poly-selected-detail"><span>Main glyph bit</span><strong>Bit {selection.bitIndex}</strong><dl><div><dt>weight</dt><dd>{2 ** selection.bitIndex}</dd></div><div><dt>state</dt><dd>{state}</dd></div><div><dt>role</dt><dd>{selection.bitIndex === 0 ? "LSB" : selection.bitIndex === 15 ? "MSB" : "fixed-width bit"}</dd></div></dl></div>;
  }
  if (selection.kind === "radix") {
    const radix = analysis.radices.find((candidate) => candidate.radix === selection.radix);
    if (radix === undefined) return null;
    return <div className="poly-selected-detail"><span>Radix arm</span><strong>Base {radix.radix}</strong><dl><div><dt>residue</dt><dd>{radix.residue}</dd></div><div><dt>phase</dt><dd>{radix.residue}/{radix.radix}</dd></div><div><dt>full form</dt><dd>{radix.representation}<sub>{radix.radix}</sub></dd></div><div><dt>digit sum</dt><dd>{radix.digitSum}</dd></div><div><dt>diversity</dt><dd>{radix.uniqueDigitCount}</dd></div><div><dt>runs</dt><dd>{radix.runs.map((run) => `${run.digit}×${run.length}`).join(" ")}</dd></div></dl></div>;
  }
  return <div className="poly-selected-detail"><span>Main Foundry glyph</span><strong>Exact 16-bit state</strong><dl><div><dt>word</dt><dd>{analysis.binary.fixedWord}</dd></div><div><dt>popcount</dt><dd>{analysis.binary.popcount}</dd></div><div><dt>rotation</dt><dd>period {analysis.binary.rotationalPeriod}</dd></div><div><dt>reflections</dt><dd>{analysis.binary.reflectionAxes.length}</dd></div><div><dt>cyclic runs</dt><dd>{analysis.binary.cyclicRuns.map((run) => `${run.digit}×${run.length}`).join(" ")}</dd></div></dl></div>;
}

function loadStoredValue(): number {
  try {
    return wrapUint16(Number(localStorage.getItem(VALUE_STORAGE_KEY) ?? 73));
  } catch {
    return 73;
  }
}

function loadStoredRadices(): readonly number[] {
  try {
    const parsed: unknown = JSON.parse(localStorage.getItem(BASES_STORAGE_KEY) ?? "null");
    if (!Array.isArray(parsed)) return DEFAULT_BASE_ORDER;
    const radices = parsed
      .filter((value): value is number => typeof value === "number" && Number.isInteger(value) && value >= 2 && value <= 64)
      .filter((value, index, values) => values.indexOf(value) === index)
      .slice(0, 6);
    return radices.length >= 2 ? radices : DEFAULT_BASE_ORDER;
  } catch {
    return DEFAULT_BASE_ORDER;
  }
}

function positionLabel(index: number, count: number): string {
  if (count === 4) return ["Top", "Right", "Bottom", "Left"][index] ?? `#${index + 1}`;
  const degrees = Math.round(index * 360 / count);
  return index === 0 ? "Top · 0°" : `#${index + 1} · ${degrees}°`;
}

function debugLabel(key: keyof PolyGlyphDebugOptions): string {
  switch (key) {
    case "scaffold": return "scaffold + nodes";
    case "bitIndexes": return "bit indexes";
    case "radixLabels": return "radix labels";
    case "residueValues": return "residue values";
    case "orientation": return "orientation";
    case "boundingGeometry": return "bounds";
  }
}

function formatDuration(seconds: number): string {
  if (seconds < 60) return `${seconds.toFixed(1)} s`;
  if (seconds < 3600) return `${(seconds / 60).toFixed(1)} min`;
  return `${(seconds / 3600).toFixed(2)} h`;
}

function formatDays(days: number): string {
  if (days < 1) return formatDuration(days * 86_400);
  return `${days.toLocaleString(undefined, { maximumFractionDigits: 4 })} d`;
}

function formatPercent(value: number): string {
  return `${(value * 100).toFixed(2)}%`;
}

function yesNo(value: boolean): string {
  return value ? "yes" : "no";
}
