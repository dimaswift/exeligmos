import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import { BitPatternEditor } from "./components/BitPatternEditor";
import { GlyphAtlas } from "./components/GlyphAtlas";
import { bitSignature, GlyphCanvas } from "./components/GlyphCanvas";
import { PrintTemplate } from "./components/PrintTemplate";
import { SpecimenGrid } from "./components/SpecimenGrid";
import {
  DEFAULT_CANVAS_COLOR,
  DEFAULT_COLOR_PALETTE,
  DEFAULT_INK_COLOR,
  glyphColor,
  normalizeColorPalette,
  normalizeHexColor,
  readableTextColor,
} from "./glyph-colors";
import {
  bezierSegmentsFromPolyline,
  clampBitWidth,
  clampGridSpacing,
  DEFAULT_CORE_POINT,
  digitToBits,
  endpointLabel,
  formatAddress,
  formatDigit,
  makeLayout,
  makeStrokeSegments,
  MAX_BIT_WIDTH,
  normalizeDigits,
  radixForBitWidth,
  segmentIsVisible,
  snapPointsToGrid,
} from "./glyph-engine";
import type {
  AssemblyLayout,
  BezierSegment,
  ColorMode,
  CoreStyle,
  Endpoint,
  FreeformStroke,
  InputDirection,
  LayoutPreset,
  Point,
  ReadingDirection,
  SandboxConfig,
  StrokeCondition,
  StrokePreset,
  StrokeSegment,
  TracedStroke,
} from "./types";

const STORAGE_KEY = "glyph-foundry.config.v1";
const DEFAULT_CONFIG: SandboxConfig = {
  version: 8,
  bitWidth: 4,
  layoutPreset: "square",
  points: makeLayout("square", 4),
  corePoint: DEFAULT_CORE_POINT,
  bottomBit: 3,
  vertexGrid: "square",
  snapToGrid: true,
  gridSpacing: 16,
  strokePreset: "weave",
  segments: makeStrokeSegments("weave", 4),
  tracedStrokes: [],
  freeformStrokes: [],
  address: "FACE01",
  digitCount: 6,
  inputDirection: "msb-first",
  assemblyLayout: "radial",
  readingDirection: "clockwise",
  startAngle: 0,
  fanSpread: 150,
  lineSpacing: 140,
  coreStyle: "ring",
  strokeWidth: 8,
  rounded: true,
  colorMode: "single",
  inkColor: DEFAULT_INK_COLOR,
  canvasColor: DEFAULT_CANVAS_COLOR,
  paletteColors: DEFAULT_COLOR_PALETTE,
  showGuides: false,
  showDisconnectedBitDots: false,
};

const LAYOUT_OPTIONS: readonly { readonly value: Exclude<LayoutPreset, "custom">; readonly label: string }[] = [
  { value: "line", label: "Bit line" },
  { value: "square", label: "2×2 / grid" },
  { value: "triangle", label: "Triangle + center" },
  { value: "diamond", label: "Diamond" },
  { value: "orbit", label: "Orbit" },
];

const STROKE_OPTIONS: readonly {
  readonly value: Exclude<StrokePreset, "custom">;
  readonly label: string;
  readonly note: string;
}[] = [
  { value: "rays", label: "Rays", note: "Each on-bit grows from the root." },
  { value: "trace", label: "Trace", note: "Each bit reveals the path leading to it." },
  { value: "weave", label: "Weave", note: "Rays plus bridges between adjacent on-bits." },
  { value: "circuit", label: "Circuit", note: "A chained loop responds to either endpoint." },
  { value: "core-shell", label: "Core + shell", note: "LSB active chains, cyclic inactive shell, and a root stem." },
];

function App() {
  const [config, setConfig] = useState<SandboxConfig>(loadConfig);
  const [sampleDigit, setSampleDigit] = useState(() => Math.min(10, radixForBitWidth(config.bitWidth) - 1));
  const [toast, setToast] = useState<string | null>(null);
  const [printOpen, setPrintOpen] = useState(false);
  const [atlasOpen, setAtlasOpen] = useState(false);
  const svgRef = useRef<SVGSVGElement>(null);
  const importRef = useRef<HTMLInputElement>(null);
  const radix = radixForBitWidth(config.bitWidth);
  const canvasForeground = readableTextColor(config.canvasColor);
  const closePrint = useCallback(() => setPrintOpen(false), []);
  const closeAtlas = useCallback(() => setAtlasOpen(false), []);
  const digits = useMemo(
    () => normalizeDigits(config.address, config.bitWidth, config.digitCount, config.inputDirection),
    [config.address, config.bitWidth, config.digitCount, config.inputDirection],
  );
  const selectedFreeformStrokes = useMemo(
    () => config.freeformStrokes.filter((stroke) => stroke.digit === sampleDigit),
    [config.freeformStrokes, sampleDigit],
  );

  useEffect(() => {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(config));
  }, [config]);

  useEffect(() => {
    if (toast === null) return;
    const timer = window.setTimeout(() => setToast(null), 2200);
    return () => window.clearTimeout(timer);
  }, [toast]);

  const patchConfig = (patch: Partial<SandboxConfig>) => {
    setConfig((current) => ({ ...current, ...patch }));
  };

  const changeBitWidth = (rawWidth: number) => {
    const bitWidth = clampBitWidth(rawWidth);
    const points = config.layoutPreset === "custom"
      ? resizeCustomPoints(config.points, bitWidth)
      : makeLayout(config.layoutPreset, bitWidth);
    const segments = config.strokePreset === "custom"
      ? resizeCustomSegments(config.segments, bitWidth)
      : makeStrokeSegments(config.strokePreset, bitWidth);
    patchConfig({
      bitWidth,
      bottomBit: Math.min(config.bottomBit, bitWidth - 1),
      points,
      segments,
      tracedStrokes: resizeTracedStrokes(config.tracedStrokes, bitWidth),
      freeformStrokes: resizeFreeformStrokes(config.freeformStrokes, bitWidth),
    });
    setSampleDigit((current) => Math.min(current, radixForBitWidth(bitWidth) - 1));
  };

  const changeLayout = (layoutPreset: Exclude<LayoutPreset, "custom">) => {
    patchConfig({ layoutPreset, points: makeLayout(layoutPreset, config.bitWidth) });
  };

  const changeStrokePreset = (strokePreset: Exclude<StrokePreset, "custom">) => {
    patchConfig({ strokePreset, segments: makeStrokeSegments(strokePreset, config.bitWidth) });
  };

  const updateSegment = (id: string, patch: Partial<StrokeSegment>) => {
    patchConfig({
      strokePreset: "custom",
      segments: config.segments.map((segment) =>
        segment.id === id ? { ...segment, ...patch } : segment,
      ),
    });
  };

  const addSegment = () => {
    const id = `custom-${Date.now()}-${config.segments.length}`;
    patchConfig({
      strokePreset: "custom",
      segments: [
        ...config.segments,
        { id, from: "root", to: 0, condition: "target", curve: "line", bend: 0 },
      ],
    });
  };

  const addTracedStroke = (from: Endpoint, to: Endpoint): string => {
    const id = `trace-${Date.now()}-${config.tracedStrokes.length}`;
    patchConfig({
      tracedStrokes: [...config.tracedStrokes, {
        id,
        digit: sampleDigit,
        from,
        to,
        curve: "line",
        bend: 0,
      }],
    });
    return id;
  };

  const updateTracedStroke = (id: string, patch: Partial<TracedStroke>) => {
    patchConfig({
      tracedStrokes: config.tracedStrokes.map((stroke) =>
        stroke.id === id ? { ...stroke, ...patch } : stroke,
      ),
    });
  };

  const removeTracedStroke = (id: string) => {
    patchConfig({
      tracedStrokes: config.tracedStrokes.filter((stroke) => stroke.id !== id),
    });
  };

  const undoTracedStroke = () => {
    const tracedStrokes = [...config.tracedStrokes];
    for (let index = tracedStrokes.length - 1; index >= 0; index -= 1) {
      if (tracedStrokes[index]?.digit !== sampleDigit) continue;
      tracedStrokes.splice(index, 1);
      patchConfig({ tracedStrokes });
      return;
    }
  };

  const addFreeformStroke = (points: readonly Point[]) => {
    const segments = bezierSegmentsFromPolyline(points);
    if (segments.length === 0) return;
    const id = `freeform-${Date.now()}-${config.freeformStrokes.length}`;
    patchConfig({
      freeformStrokes: [...config.freeformStrokes, { id, digit: sampleDigit, segments }],
    });
  };

  const undoFreeformStroke = () => {
    const freeformStrokes = [...config.freeformStrokes];
    for (let index = freeformStrokes.length - 1; index >= 0; index -= 1) {
      if (freeformStrokes[index]?.digit !== sampleDigit) continue;
      freeformStrokes.splice(index, 1);
      patchConfig({ freeformStrokes });
      return;
    }
  };

  const clearManualStrokes = () => {
    const count = config.tracedStrokes.length + config.freeformStrokes.length;
    if (count === 0) return;
    if (!window.confirm(`Remove all ${count} manual Trace and Freeform ${count === 1 ? "stroke" : "strokes"}?`)) return;
    patchConfig({ tracedStrokes: [], freeformStrokes: [] });
    setToast("All manual strokes cleared");
  };

  const randomizeAddress = () => {
    const values = Array.from({ length: config.digitCount }, () =>
      Math.floor(Math.random() * radix),
    );
    patchConfig({ address: formatAddress(values, config.bitWidth) });
  };

  const copyConfig = async () => {
    try {
      await navigator.clipboard.writeText(JSON.stringify(config, null, 2));
      setToast("Configuration copied");
    } catch {
      downloadText("glyph-foundry-config.json", JSON.stringify(config, null, 2), "application/json");
      setToast("Configuration downloaded");
    }
  };

  const downloadSvg = () => {
    const svg = svgRef.current;
    if (svg === null) return;
    const serialized = new XMLSerializer().serializeToString(svg);
    downloadText(
      `glyph-${formatAddress(digits, config.bitWidth) || "untitled"}.svg`,
      `<?xml version="1.0" encoding="UTF-8"?>\n${serialized}`,
      "image/svg+xml",
    );
    setToast("SVG downloaded");
  };

  const importConfig = async (file: File | undefined) => {
    if (file === undefined) return;
    try {
      const parsed: unknown = JSON.parse(await file.text());
      setConfig(normalizeImportedConfig(parsed));
      setToast("Configuration imported");
    } catch {
      setToast("That configuration could not be read");
    } finally {
      if (importRef.current !== null) importRef.current.value = "";
    }
  };

  const reset = () => {
    setConfig(DEFAULT_CONFIG);
    setSampleDigit(10);
    setToast("Hexadecimal defaults restored");
  };

  return (
    <div className="app-shell">
      <header className="topbar">
        <a className="brand" href="#top" aria-label="Glyph Foundry home">
          <BrandMark />
          <span>
            <strong>Glyph Foundry</strong>
            <small>bit-driven symbol laboratory</small>
          </span>
        </a>
        <div className="system-badge" aria-label={`${config.bitWidth} bits, base ${radix}`}>
          <span>{config.bitWidth} bits</span>
          <strong>BASE {radix}</strong>
        </div>
        <nav className="header-actions" aria-label="Configuration actions">
          <input
            ref={importRef}
            accept="application/json,.json"
            className="visually-hidden"
            onChange={(event) => void importConfig(event.target.files?.[0])}
            type="file"
          />
          <button className="quiet-button" onClick={() => importRef.current?.click()} type="button">
            Import
          </button>
          <button className="quiet-button" onClick={() => void copyConfig()} type="button">
            Export config
          </button>
          <button className="quiet-button" onClick={() => setPrintOpen(true)} type="button">
            Print template
          </button>
          <button className="quiet-button" onClick={() => setAtlasOpen(true)} type="button">
            Preview atlas
          </button>
          <button className="primary-button" onClick={downloadSvg} type="button">
            Download SVG
          </button>
        </nav>
      </header>

      <div className="workspace" id="top">
        <aside className="control-rail">
          <div className="rail-intro">
            <p className="eyebrow">System controls</p>
            <h1>Build a visual grammar from bits.</h1>
            <p>Change one rule at a time. Every panel updates the same generator immediately.</p>
          </div>

          <ControlSection number="01" title="Digit system">
            <Field label="Bits per digit" value={`${config.bitWidth} bits → base ${radix}`}>
              <input
                aria-label="Bits per digit"
                max={MAX_BIT_WIDTH}
                min="2"
                onChange={(event) => changeBitWidth(Number(event.target.value))}
                type="range"
                value={config.bitWidth}
              />
              <div className="range-labels">
                <span>2</span>
                <span>3 = octal</span>
                <span>4 = hex</span>
                <span>5 = base 32</span>
                <span>8 = base 256</span>
                <span>16 = base 65,536</span>
              </div>
            </Field>
            <Field
              label="Composite value"
              value={`${config.inputDirection === "msb-first" ? "MSB" : "LSB"} first${radix > 36 ? " · decimal tokens" : ""}`}
            >
              <div className="address-row">
                <input
                  aria-label="Composite value"
                  className="text-input address-input"
                  onChange={(event) => patchConfig({ address: event.target.value.toUpperCase() })}
                  spellCheck="false"
                  value={config.address}
                />
                <button aria-label="Randomize value" className="icon-button" onClick={randomizeAddress} type="button">
                  ↻
                </button>
              </div>
              <p className="field-hint">
                {radix > 36
                  ? `Use values 0–${radix - 1}, separated by spaces.`
                  : `Available digits: 0–${formatDigit(radix - 1, config.bitWidth)}.`}
              </p>
            </Field>
            <Field label="Digits in glyph" value={String(config.digitCount)}>
              <input
                aria-label="Digits in glyph"
                max="12"
                min="1"
                onChange={(event) => patchConfig({ digitCount: Number(event.target.value) })}
                type="range"
                value={config.digitCount}
              />
            </Field>
          </ControlSection>

          <ControlSection number="02" title="Assembly">
            <Field label="Composition">
              <SegmentedControl
                label="Composition"
                onChange={(value) => patchConfig({ assemblyLayout: value as AssemblyLayout })}
                options={[
                  ["radial", "Radial"],
                  ["fan", "Fan"],
                  ["stack", "Stack"],
                  ["linear", "Line"],
                ]}
                value={config.assemblyLayout}
              />
            </Field>
            <Field label="Input significance">
              <SegmentedControl
                label="Input significance"
                onChange={(value) => patchConfig({ inputDirection: value as InputDirection })}
                options={[
                  ["msb-first", "MSB first"],
                  ["lsb-first", "LSB first"],
                ]}
                value={config.inputDirection}
              />
            </Field>
            <Field label="Socket direction">
              <SegmentedControl
                label="Socket direction"
                onChange={(value) => patchConfig({ readingDirection: value as ReadingDirection })}
                options={[
                  ["clockwise", "Clockwise"],
                  ["counterclockwise", "Counter"],
                ]}
                value={config.readingDirection}
              />
            </Field>
            <Field label="Start angle" value={`${config.startAngle}°`}>
              <input
                aria-label="Start angle"
                max="180"
                min="-180"
                onChange={(event) => patchConfig({ startAngle: Number(event.target.value) })}
                type="range"
                value={config.startAngle}
              />
            </Field>
            {config.assemblyLayout === "fan" ? (
              <Field label="Fan spread" value={`${config.fanSpread}°`}>
                <input
                  aria-label="Fan spread"
                  max="320"
                  min="30"
                  onChange={(event) => patchConfig({ fanSpread: Number(event.target.value) })}
                  type="range"
                  value={config.fanSpread}
                />
              </Field>
            ) : null}
            {config.assemblyLayout === "linear" ? (
              <Field label="Line spacing" value={`${config.lineSpacing} units`}>
                <input
                  aria-label="Line spacing"
                  max="280"
                  min="40"
                  onChange={(event) => patchConfig({ lineSpacing: Number(event.target.value) })}
                  step="4"
                  type="range"
                  value={config.lineSpacing}
                />
              </Field>
            ) : null}
            <Field label="Glyph hub">
              <select
                aria-label="Glyph hub style"
                className="select-input"
                onChange={(event) => patchConfig({ coreStyle: event.target.value as CoreStyle })}
                value={config.coreStyle}
              >
                <option value="ring">Ring</option>
                <option value="polygon">Digit polygon</option>
                <option value="dot">Dot</option>
                <option value="none">None</option>
              </select>
            </Field>
          </ControlSection>

          <ControlSection number="03" title="Ink">
            <Field label="Stroke width" value={`${config.strokeWidth}px`}>
              <input
                aria-label="Stroke width"
                max="18"
                min="2"
                onChange={(event) => patchConfig({ strokeWidth: Number(event.target.value) })}
                type="range"
                value={config.strokeWidth}
              />
            </Field>
            <Field label="Color mapping">
              <select
                aria-label="Color mapping"
                className="select-input"
                onChange={(event) => patchConfig({ colorMode: event.target.value as ColorMode })}
                value={config.colorMode}
              >
                <option value="single">Single ink</option>
                <option value="position">By arm position</option>
                <option value="digit">By digit value</option>
              </select>
            </Field>
            <div className="color-settings-grid">
              <ColorControl
                label="Single ink"
                onChange={(inkColor) => patchConfig({ inkColor })}
                value={config.inkColor}
              />
              <ColorControl
                label="Canvas"
                onChange={(canvasColor) => patchConfig({ canvasColor })}
                value={config.canvasColor}
              />
            </div>
            <div className="palette-settings">
              <header>
                <span>Position / digit palette</span>
                <button onClick={() => patchConfig({ paletteColors: DEFAULT_COLOR_PALETTE })} type="button">Reset</button>
              </header>
              <div>
                {config.paletteColors.map((color, index) => (
                  <ColorControl
                    compact
                    key={index}
                    label={`Palette ${index + 1}`}
                    onChange={(nextColor) => patchConfig({
                      paletteColors: config.paletteColors.map((current, currentIndex) => (
                        currentIndex === index ? nextColor : current
                      )),
                    })}
                    value={color}
                  />
                ))}
              </div>
            </div>
            <label className="switch-row">
              <input
                checked={config.rounded}
                onChange={(event) => patchConfig({ rounded: event.target.checked })}
                type="checkbox"
              />
              <span>Rounded stroke ends</span>
            </label>
            <label className="switch-row">
              <input
                checked={config.showGuides}
                onChange={(event) => patchConfig({ showGuides: event.target.checked })}
                type="checkbox"
              />
              <span>Show bit guides in composite</span>
            </label>
            <label className="switch-row">
              <input
                checked={config.showDisconnectedBitDots}
                onChange={(event) => patchConfig({ showDisconnectedBitDots: event.target.checked })}
                type="checkbox"
              />
              <span>Dot disconnected bits</span>
            </label>
          </ControlSection>

          <button className="reset-button" onClick={reset} type="button">
            Reset hexadecimal defaults
          </button>
        </aside>

        <main className="laboratory">
          <section className="hero-grid" aria-labelledby="composite-title">
            <article
              className="canvas-card"
              style={{
                "--canvas-bg": config.canvasColor,
                "--canvas-fg": canvasForeground,
                "--canvas-ink": config.inkColor,
              } as React.CSSProperties}
            >
              <header className="card-header canvas-header">
                <div>
                  <p className="eyebrow light">Live composite</p>
                  <h2 id="composite-title">{formatAddress(digits, config.bitWidth)}</h2>
                </div>
                <div className="canvas-stats">
                  <span>{config.digitCount} arms</span>
                  <span>{config.assemblyLayout}</span>
                  <span>{config.readingDirection === "clockwise" ? "CW" : "CCW"}</span>
                </div>
              </header>
              <div className="canvas-stage">
                <GlyphCanvas
                  ref={svgRef}
                  className="main-glyph"
                  config={config}
                  digits={digits}
                  title={`Base ${radix} glyph ${formatAddress(digits, config.bitWidth)}`}
                />
                <div className="canvas-coordinate top">0°</div>
                <div className="canvas-coordinate bottom">
                  {config.inputDirection === "msb-first" ? "MSB" : "LSB"}{" "}
                  {config.readingDirection === "clockwise" ? "↻" : "↺"}{" "}
                  {config.inputDirection === "msb-first" ? "LSB" : "MSB"}
                </div>
              </div>
            </article>

            <article className="pattern-card">
              <header className="card-header">
                <div>
                  <p className="eyebrow">Arm studio</p>
                  <h2>
                    {formatDigit(sampleDigit, config.bitWidth)} <span>{bitSignature(sampleDigit, config.bitWidth)}</span>
                  </h2>
                </div>
                <span className="drag-callout">move / trace / draw</span>
              </header>
              <BitPatternEditor
                bitWidth={config.bitWidth}
                bottomBit={config.bottomBit}
                corePoint={config.corePoint}
                digit={sampleDigit}
                freeformStrokes={config.freeformStrokes}
                gridSpacing={config.gridSpacing}
                gridType={config.vertexGrid}
                onDigitChange={setSampleDigit}
                onFreeformAdd={addFreeformStroke}
                onFreeformUndo={undoFreeformStroke}
                onCorePointChange={(corePoint) => patchConfig({ corePoint })}
                onPointsChange={(points) => patchConfig({ points, layoutPreset: "custom" })}
                onTracedStrokeAdd={addTracedStroke}
                onTracedStrokeRemove={removeTracedStroke}
                onTracedStrokeUndo={undoTracedStroke}
                onTracedStrokeUpdate={updateTracedStroke}
                points={config.points}
                rounded={config.rounded}
                segments={config.segments}
                showDisconnectedBitDots={config.showDisconnectedBitDots}
                strokeColor={glyphColor(config, 0, sampleDigit)}
                strokePreset={config.strokePreset}
                tracedStrokes={config.tracedStrokes}
                snapToGrid={config.snapToGrid}
                strokeWidth={config.strokeWidth}
              />
              <div
                className="bit-toggles"
                aria-label="Sample bit pattern"
                style={{ gridTemplateColumns: `repeat(${Math.min(config.bitWidth, 8)}, minmax(32px, 1fr))` }}
              >
                {Array.from({ length: config.bitWidth }, (_, index) => {
                  const power = 2 ** (config.bitWidth - index - 1);
                  const active = (sampleDigit & power) !== 0;
                  return (
                    <button
                      key={index}
                      aria-label={`Bit ${index}, value ${power}`}
                      aria-pressed={active}
                      onClick={() => setSampleDigit((current) => current ^ power)}
                      type="button"
                    >
                      <small>B{index}</small>
                      <strong>{active ? "1" : "0"}</strong>
                      <span>{power}</span>
                    </button>
                  );
                })}
              </div>
            </article>
          </section>

          <section className="rule-workbench" aria-labelledby="geometry-title">
            <header className="section-heading">
              <div>
                <p className="eyebrow">Geometry + grammar</p>
                <h2 id="geometry-title">Shape the nibble, then define its strokes.</h2>
              </div>
              <p>Generated rules respond to bits. Trace and Freeform add strokes to one chosen digit.</p>
            </header>

            <div className="workbench-grid">
              <article className="tool-card">
                <div className="tool-card-title">
                  <span>1</span>
                  <div>
                    <h3>Bit geometry</h3>
                    <p>{config.layoutPreset === "custom" ? "Custom — dragged by hand" : "Choose a starting structure"}</p>
                  </div>
                </div>
                <div className="preset-grid layout-presets">
                  {LAYOUT_OPTIONS.map((option) => (
                    <button
                      key={option.value}
                      aria-pressed={config.layoutPreset === option.value}
                      onClick={() => changeLayout(option.value)}
                      type="button"
                    >
                      <LayoutIcon count={config.bitWidth} preset={option.value} />
                      <span>{option.label}</span>
                    </button>
                  ))}
                </div>
                <div className="grid-settings">
                  <div className="control-heading">
                    <span>Vertex lattice</span>
                    <small>{config.gridSpacing} unit spacing</small>
                  </div>
                  <div className="segmented-control grid-type-control" aria-label="Vertex grid type">
                    {(["square", "triangular", "hexagonal"] as const).map((gridType) => (
                      <button
                        aria-pressed={config.vertexGrid === gridType}
                        key={gridType}
                        onClick={() => patchConfig({ vertexGrid: gridType })}
                        type="button"
                      >
                        {gridType === "triangular" ? "Triangle" : gridType === "hexagonal" ? "Hexagon" : "Square"}
                      </button>
                    ))}
                  </div>
                  <label className="range-row compact-range">
                    <span>Grid spacing</span>
                    <input
                      aria-label="Grid spacing"
                      max="40"
                      min="6"
                      onChange={(event) => patchConfig({ gridSpacing: clampGridSpacing(event.target.value) })}
                      step="1"
                      type="range"
                      value={config.gridSpacing}
                    />
                    <output>{config.gridSpacing}</output>
                  </label>
                  <div className="snap-actions">
                    <label className="check-row">
                      <input
                        checked={config.snapToGrid}
                        onChange={(event) => patchConfig({ snapToGrid: event.target.checked })}
                        type="checkbox"
                      />
                      Snap while dragging
                    </label>
                    <button
                      className="small-button"
                      onClick={() => {
                        const snapped = snapPointsToGrid(
                          [...config.points, config.corePoint],
                          config.vertexGrid,
                          config.gridSpacing,
                        );
                        patchConfig({
                          corePoint: snapped.at(-1) ?? config.corePoint,
                          layoutPreset: "custom",
                          points: snapped.slice(0, config.points.length),
                        });
                      }}
                      type="button"
                    >
                      Snap all now
                    </button>
                  </div>
                </div>
              </article>

              <article className="tool-card">
                <div className="tool-card-title">
                  <span>2</span>
                  <div>
                    <h3>Generated recipe</h3>
                    <p>{config.strokePreset === "custom" ? "Custom generated rules" : "Start with a reusable bit rule"}</p>
                  </div>
                </div>
                <div className="recipe-list">
                  {STROKE_OPTIONS.map((option) => (
                    <button
                      key={option.value}
                      aria-pressed={config.strokePreset === option.value}
                      onClick={() => changeStrokePreset(option.value)}
                      type="button"
                    >
                      <span className="recipe-radio" />
                      <span>
                        <strong>{option.label}</strong>
                        <small>{option.note}</small>
                      </span>
                    </button>
                  ))}
                </div>
                {config.strokePreset === "core-shell" ? (
                  <div className="core-shell-settings">
                    <label>
                      <span>Root bit</span>
                      <select
                        aria-label="Root bit for root stem"
                        onChange={(event) => patchConfig({ bottomBit: Number(event.target.value) })}
                        value={config.bottomBit}
                      >
                        {Array.from({ length: config.bitWidth }, (_, index) => (
                          <option key={index} value={index}>B{index} · value {2 ** (config.bitWidth - index - 1)}</option>
                        ))}
                      </select>
                    </label>
                    <ol>
                      <li>From the LSB, chain adjacent active bits; every gap restarts at Core.</li>
                      <li>Connect only adjacent inactive bits around the cycle, including MSB ↔ LSB.</li>
                      <li>Always connect Root to the selected root bit.</li>
                    </ol>
                    <p>Drag the violet Core node in the Arm studio.</p>
                  </div>
                ) : null}
              </article>

              <article className="tool-card segment-card">
                <div className="tool-card-title segment-title">
                  <span>3</span>
                  <div>
                    <h3>Generated stroke rules</h3>
                    <p>Reusable across every digit. Manual Trace and Freeform strokes stay on the canvas above.</p>
                  </div>
                  <div className="segment-title-actions">
                    {config.tracedStrokes.length + config.freeformStrokes.length > 0 ? (
                      <button className="small-button clear-manual-button" onClick={clearManualStrokes} type="button">
                        Clear manual ({config.tracedStrokes.length + config.freeformStrokes.length})
                      </button>
                    ) : null}
                    {config.strokePreset === "core-shell" ? null : (
                      <button className="small-button" onClick={addSegment} type="button">
                        + stroke
                      </button>
                    )}
                  </div>
                </div>
                {config.strokePreset === "core-shell" ? (
                  <div className="dynamic-rule-note">
                    <strong>Calculated independently for every digit.</strong>
                    <span>The current sample produces its strokes directly from the active and inactive bit sets.</span>
                  </div>
                ) : <div className="segment-table" role="group" aria-label="Generated stroke rules">
                  {config.segments.map((segment, index) => (
                    <div className="segment-row" key={segment.id}>
                      <span className="segment-number">{String(index + 1).padStart(2, "0")}</span>
                      <EndpointSelect
                        bitWidth={config.bitWidth}
                        label={`Stroke ${index + 1} start`}
                        onChange={(from) => updateSegment(segment.id, { from })}
                        value={segment.from}
                      />
                      <span className="arrow">→</span>
                      <EndpointSelect
                        bitWidth={config.bitWidth}
                        label={`Stroke ${index + 1} end`}
                        onChange={(to) => updateSegment(segment.id, { to })}
                        value={segment.to}
                      />
                      <select
                        aria-label={`Stroke ${index + 1} activation`}
                        className="condition-select"
                        onChange={(event) => updateSegment(segment.id, { condition: event.target.value as StrokeCondition })}
                        value={segment.condition}
                      >
                        <option value="target">end bit on</option>
                        <option value="source">start bit on</option>
                        <option value="both">both on</option>
                        <option value="either">either on</option>
                        <option value="always">always</option>
                      </select>
                      <select
                        aria-label={`Stroke ${index + 1} geometry`}
                        className="curve-select"
                        onChange={(event) => {
                          const curve = event.target.value as StrokeSegment["curve"];
                          updateSegment(segment.id, {
                            curve,
                            bend: curve === "hyperbolic" && segment.bend === 0 ? 32 : segment.bend,
                          });
                        }}
                        value={segment.curve}
                      >
                        <option value="line">straight</option>
                        <option value="hyperbolic">hyperbolic</option>
                      </select>
                      <button
                        aria-label={`Remove stroke ${index + 1}`}
                        className="delete-button"
                        onClick={() => patchConfig({
                          strokePreset: "custom",
                          segments: config.segments.filter((candidate) => candidate.id !== segment.id),
                        })}
                        type="button"
                      >
                        ×
                      </button>
                      {segment.curve === "hyperbolic" ? (
                        <label className="segment-bend-control">
                          <span>Bend</span>
                          <input
                            aria-label={`Stroke ${index + 1} curve bend`}
                            max="120"
                            min="-120"
                            onChange={(event) => updateSegment(segment.id, { bend: Number(event.target.value) })}
                            step="2"
                            type="range"
                            value={segment.bend}
                          />
                          <output>{segment.bend > 0 ? "+" : ""}{segment.bend}</output>
                        </label>
                      ) : null}
                    </div>
                  ))}
                </div>}
                <div className="freeform-rules" role="group" aria-label="Freeform Bezier strokes">
                  <div className="freeform-rules-header">
                    <div>
                      <strong>Digit {formatDigit(sampleDigit, config.bitWidth)} stroke set</strong>
                      <small>Freeform Béziers belonging only to this digit.</small>
                    </div>
                    <span>{selectedFreeformStrokes.length}</span>
                  </div>
                  {selectedFreeformStrokes.length === 0 ? (
                    <p className="freeform-empty">Choose Freeform above and draw while digit {formatDigit(sampleDigit, config.bitWidth)} is selected.</p>
                  ) : (
                    <div className="freeform-list">
                      {selectedFreeformStrokes.map((stroke, index) => (
                        <div className="freeform-row" key={stroke.id}>
                          <span className="segment-number">F{String(index + 1).padStart(2, "0")}</span>
                          <span className="freeform-kind">{stroke.segments.length} cubic {stroke.segments.length === 1 ? "segment" : "segments"}</span>
                          <span className="freeform-digit-badge">Digit {formatDigit(stroke.digit, config.bitWidth)}</span>
                          <button
                            aria-label={`Remove freeform stroke ${index + 1}`}
                            className="delete-button"
                            onClick={() => patchConfig({
                              freeformStrokes: config.freeformStrokes.filter((candidate) => candidate.id !== stroke.id),
                            })}
                            type="button"
                          >
                            ×
                          </button>
                        </div>
                      ))}
                    </div>
                  )}
                </div>
              </article>
            </div>
          </section>

          <section className="specimen-section" aria-labelledby="specimens-title">
            <header className="section-heading">
              <div>
                <p className="eyebrow">System proof</p>
                <h2 id="specimens-title">Digit specimens</h2>
              </div>
              <p>Scan for collisions and weak forms. Select any specimen to load it into the arm studio.</p>
            </header>
            <SpecimenGrid
              bitWidth={config.bitWidth}
              bottomBit={config.bottomBit}
              corePoint={config.corePoint}
              freeformStrokes={config.freeformStrokes}
              colorMode={config.colorMode}
              inkColor={config.inkColor}
              onSelect={setSampleDigit}
              points={config.points}
              paletteColors={config.paletteColors}
              rounded={config.rounded}
              segments={config.segments}
              strokePreset={config.strokePreset}
              tracedStrokes={config.tracedStrokes}
              selectedDigit={sampleDigit}
              showDisconnectedBitDots={config.showDisconnectedBitDots}
              strokeWidth={config.strokeWidth}
            />
          </section>

          <footer className="lab-footer">
            <p>
              <strong>Generator state:</strong> {config.bitWidth} bits · base {radix} · {config.points.length} bit vertices + core · {config.strokePreset === "core-shell" ? "dynamic core-shell rule" : `${config.segments.length} graph strokes`} · {config.tracedStrokes.length} traced · {config.freeformStrokes.length} freeform · {config.digitCount} arms
            </p>
            <button onClick={() => void copyConfig()} type="button">Copy portable JSON ↗</button>
          </footer>
        </main>
      </div>
      {printOpen ? <PrintTemplate config={config} onClose={closePrint} /> : null}
      {atlasOpen ? <GlyphAtlas config={config} onClose={closeAtlas} /> : null}
      {toast === null ? null : <div className="toast" role="status">{toast}</div>}
    </div>
  );
}

function ControlSection({
  number,
  title,
  children,
}: {
  readonly number: string;
  readonly title: string;
  readonly children: React.ReactNode;
}) {
  return (
    <section className="control-section">
      <header><span>{number}</span><h2>{title}</h2></header>
      {children}
    </section>
  );
}

function Field({
  label,
  value,
  children,
}: {
  readonly label: string;
  readonly value?: string;
  readonly children: React.ReactNode;
}) {
  return (
    <div className="field">
      <div className="field-label"><span>{label}</span>{value === undefined ? null : <strong>{value}</strong>}</div>
      {children}
    </div>
  );
}

function SegmentedControl({
  label,
  options,
  value,
  onChange,
}: {
  readonly label: string;
  readonly options: readonly (readonly [string, string])[];
  readonly value: string;
  readonly onChange: (value: string) => void;
}) {
  return (
    <div className="segmented-control" role="group" aria-label={label}>
      {options.map(([optionValue, optionLabel]) => (
        <button
          key={optionValue}
          aria-pressed={value === optionValue}
          onClick={() => onChange(optionValue)}
          type="button"
        >
          {optionLabel}
        </button>
      ))}
    </div>
  );
}

function EndpointSelect({
  bitWidth,
  label,
  value,
  onChange,
}: {
  readonly bitWidth: number;
  readonly label: string;
  readonly value: Endpoint;
  readonly onChange: (value: Endpoint) => void;
}) {
  const endpoints: Endpoint[] = ["root", "core", ...Array.from({ length: bitWidth }, (_, index) => index)];
  return (
    <select
      aria-label={label}
      onChange={(event) => {
        const value = event.target.value;
        onChange(value === "root" || value === "core" ? value : Number(value));
      }}
      value={String(value)}
    >
      {endpoints.map((endpoint) => (
        <option key={String(endpoint)} value={String(endpoint)}>{endpointLabel(endpoint)}</option>
      ))}
    </select>
  );
}

function LayoutIcon({ count, preset }: { readonly count: number; readonly preset: Exclude<LayoutPreset, "custom"> }) {
  const points = makeLayout(preset, count);
  return (
    <svg aria-hidden="true" viewBox="-90 -170 180 150">
      {points.map((point, index) => <circle key={index} cx={point.x} cy={point.y} r="7" />)}
    </svg>
  );
}

function BrandMark() {
  return (
    <svg aria-hidden="true" className="brand-mark" viewBox="0 0 40 40">
      <circle cx="20" cy="20" r="4" />
      <path d="M20 16V3M24 20h13M20 24v13M16 20H3M23 17l8-8M23 23l8 8M17 23l-8 8M17 17L9 9" />
    </svg>
  );
}

function resizeCustomPoints(points: readonly Point[], bitWidth: number): readonly Point[] {
  const fallback = makeLayout("square", bitWidth);
  return Array.from({ length: bitWidth }, (_, index) => points[index] ?? fallback[index] ?? { x: 0, y: -80 });
}

function resizeCustomSegments(segments: readonly StrokeSegment[], bitWidth: number): readonly StrokeSegment[] {
  const valid = (endpoint: Endpoint) => endpoint === "root" || endpoint === "core" || endpoint < bitWidth;
  const filtered = segments.filter((segment) => valid(segment.from) && valid(segment.to));
  return filtered.length > 0 ? filtered : makeStrokeSegments("rays", bitWidth);
}

function resizeTracedStrokes(
  strokes: readonly TracedStroke[],
  bitWidth: number,
): readonly TracedStroke[] {
  const radix = radixForBitWidth(bitWidth);
  const endpointValid = (endpoint: Endpoint) => endpoint === "root" || endpoint === "core" || endpoint < bitWidth;
  return strokes.filter((stroke) =>
    stroke.digit >= 0
    && stroke.digit < radix
    && endpointValid(stroke.from)
    && endpointValid(stroke.to),
  );
}

function resizeFreeformStrokes(
  strokes: readonly FreeformStroke[],
  bitWidth: number,
): readonly FreeformStroke[] {
  const radix = radixForBitWidth(bitWidth);
  return strokes.filter((stroke) => stroke.digit >= 0 && stroke.digit < radix);
}

function loadConfig(): SandboxConfig {
  try {
    const stored = localStorage.getItem(STORAGE_KEY);
    return stored === null ? DEFAULT_CONFIG : normalizeImportedConfig(JSON.parse(stored));
  } catch {
    return DEFAULT_CONFIG;
  }
}

function normalizeImportedConfig(value: unknown): SandboxConfig {
  if (value === null || typeof value !== "object") throw new TypeError("Expected a configuration object");
  const input = value as Partial<SandboxConfig>;
  const bitWidth = clampBitWidth(input.bitWidth);
  const layoutPreset = isOneOf(input.layoutPreset, ["line", "square", "triangle", "diamond", "orbit", "custom"] as const)
    ? input.layoutPreset
    : DEFAULT_CONFIG.layoutPreset;
  const rawPoints = Array.isArray(input.points)
    ? input.points.filter(isPoint).slice(0, bitWidth)
    : [];
  const points = rawPoints.length === bitWidth
    ? rawPoints
    : makeLayout(layoutPreset === "custom" ? "square" : layoutPreset, bitWidth);
  const rawSegments = Array.isArray(input.segments)
    ? input.segments
      .map((segment) => parseStrokeSegment(segment, bitWidth))
      .filter((segment): segment is StrokeSegment => segment !== null)
    : [];
  const strokePreset = isOneOf(input.strokePreset, ["rays", "trace", "weave", "circuit", "core-shell", "custom"] as const)
    ? input.strokePreset
    : DEFAULT_CONFIG.strokePreset;
  const hasExplicitTracedStrokes = Array.isArray(input.tracedStrokes);
  const tracedStrokes = hasExplicitTracedStrokes
    ? input.tracedStrokes
      .slice(0, 512)
      .map((stroke) => parseTracedStroke(stroke, bitWidth))
      .filter((stroke): stroke is TracedStroke => stroke !== null)
    : rawSegments
      .filter((segment) => segment.id.startsWith("trace-"))
      .flatMap((segment) => migrateLegacyTracedStroke(segment, bitWidth));
  const baseSegments = hasExplicitTracedStrokes
    ? rawSegments
    : rawSegments.filter((segment) => !segment.id.startsWith("trace-"));
  const freeformStrokes = Array.isArray(input.freeformStrokes)
    ? input.freeformStrokes
      .slice(0, 64)
      .flatMap((stroke) => parseFreeformStroke(stroke, bitWidth))
    : [];

  return {
    version: 8,
    bitWidth,
    layoutPreset,
    points,
    corePoint: isPoint(input.corePoint) ? input.corePoint : DEFAULT_CORE_POINT,
    bottomBit: Math.trunc(clampNumber(input.bottomBit, 0, bitWidth - 1, bitWidth - 1)),
    vertexGrid: isOneOf(input.vertexGrid, ["square", "triangular", "hexagonal"] as const)
      ? input.vertexGrid
      : DEFAULT_CONFIG.vertexGrid,
    snapToGrid: typeof input.snapToGrid === "boolean" ? input.snapToGrid : DEFAULT_CONFIG.snapToGrid,
    gridSpacing: clampGridSpacing(input.gridSpacing),
    strokePreset,
    segments: baseSegments.length > 0
      ? baseSegments
      : makeStrokeSegments(strokePreset === "custom" ? "rays" : strokePreset, bitWidth),
    tracedStrokes,
    freeformStrokes,
    address: typeof input.address === "string" ? input.address : DEFAULT_CONFIG.address,
    digitCount: clampNumber(input.digitCount, 1, 12, DEFAULT_CONFIG.digitCount),
    inputDirection: isOneOf(input.inputDirection, ["msb-first", "lsb-first"] as const) ? input.inputDirection : DEFAULT_CONFIG.inputDirection,
    assemblyLayout: isOneOf(input.assemblyLayout, ["radial", "fan", "stack", "linear"] as const) ? input.assemblyLayout : DEFAULT_CONFIG.assemblyLayout,
    readingDirection: isOneOf(input.readingDirection, ["clockwise", "counterclockwise"] as const) ? input.readingDirection : DEFAULT_CONFIG.readingDirection,
    startAngle: clampNumber(input.startAngle, -180, 180, DEFAULT_CONFIG.startAngle),
    fanSpread: clampNumber(input.fanSpread, 30, 320, DEFAULT_CONFIG.fanSpread),
    lineSpacing: clampNumber(input.lineSpacing, 40, 280, DEFAULT_CONFIG.lineSpacing),
    coreStyle: isOneOf(input.coreStyle, ["ring", "polygon", "dot", "none"] as const) ? input.coreStyle : DEFAULT_CONFIG.coreStyle,
    strokeWidth: clampNumber(input.strokeWidth, 2, 18, DEFAULT_CONFIG.strokeWidth),
    rounded: typeof input.rounded === "boolean" ? input.rounded : DEFAULT_CONFIG.rounded,
    colorMode: isOneOf(input.colorMode, ["single", "position", "digit"] as const) ? input.colorMode : DEFAULT_CONFIG.colorMode,
    inkColor: normalizeHexColor(input.inkColor, DEFAULT_CONFIG.inkColor),
    canvasColor: normalizeHexColor(input.canvasColor, DEFAULT_CONFIG.canvasColor),
    paletteColors: normalizeColorPalette(input.paletteColors),
    showGuides: typeof input.showGuides === "boolean" ? input.showGuides : DEFAULT_CONFIG.showGuides,
    showDisconnectedBitDots: typeof input.showDisconnectedBitDots === "boolean"
      ? input.showDisconnectedBitDots
      : DEFAULT_CONFIG.showDisconnectedBitDots,
  };
}

function ColorControl({
  label,
  value,
  compact = false,
  onChange,
}: {
  readonly label: string;
  readonly value: string;
  readonly compact?: boolean;
  readonly onChange: (color: string) => void;
}) {
  return (
    <label className={`color-control ${compact ? "compact" : ""}`}>
      <span>{compact ? String(Number(label.split(" ").at(-1) ?? "0")).padStart(2, "0") : label}</span>
      <input
        aria-label={`${label} color`}
        onChange={(event) => onChange(event.target.value)}
        type="color"
        value={value}
      />
      {compact ? null : <output>{value.toUpperCase()}</output>}
    </label>
  );
}

function isPoint(value: unknown): value is Point {
  if (value === null || typeof value !== "object") return false;
  const point = value as Partial<Point>;
  return typeof point.x === "number" && Number.isFinite(point.x) && typeof point.y === "number" && Number.isFinite(point.y);
}

function parseStrokeSegment(value: unknown, bitWidth: number): StrokeSegment | null {
  if (value === null || typeof value !== "object") return null;
  const segment = value as Partial<StrokeSegment>;
  const endpointValid = (endpoint: unknown) => endpoint === "root"
    || endpoint === "core"
    || (typeof endpoint === "number" && Number.isInteger(endpoint) && endpoint >= 0 && endpoint < bitWidth);
  if (typeof segment.id !== "string"
    || !endpointValid(segment.from)
    || !endpointValid(segment.to)
    || !isOneOf(segment.condition, ["target", "source", "both", "either", "always"] as const)) {
    return null;
  }
  const curve = isOneOf(segment.curve, ["line", "hyperbolic"] as const) ? segment.curve : "line";
  return {
    id: segment.id,
    from: segment.from as Endpoint,
    to: segment.to as Endpoint,
    condition: segment.condition,
    curve,
    bend: curve === "hyperbolic" ? clampNumber(segment.bend, -120, 120, 32) : 0,
  };
}

function parseTracedStroke(value: unknown, bitWidth: number): TracedStroke | null {
  if (value === null || typeof value !== "object") return null;
  const stroke = value as Partial<TracedStroke>;
  const radix = radixForBitWidth(bitWidth);
  const endpointValid = (endpoint: unknown) => endpoint === "root"
    || endpoint === "core"
    || (typeof endpoint === "number" && Number.isInteger(endpoint) && endpoint >= 0 && endpoint < bitWidth);
  if (typeof stroke.id !== "string"
    || typeof stroke.digit !== "number"
    || !Number.isInteger(stroke.digit)
    || stroke.digit < 0
    || stroke.digit >= radix
    || !endpointValid(stroke.from)
    || !endpointValid(stroke.to)) {
    return null;
  }
  const curve = isOneOf(stroke.curve, ["line", "hyperbolic"] as const) ? stroke.curve : "line";
  return {
    id: stroke.id,
    digit: stroke.digit,
    from: stroke.from as Endpoint,
    to: stroke.to as Endpoint,
    curve,
    bend: curve === "hyperbolic" ? clampNumber(stroke.bend, -120, 120, 32) : 0,
  };
}

function migrateLegacyTracedStroke(
  segment: StrokeSegment,
  bitWidth: number,
): readonly TracedStroke[] {
  return Array.from({ length: radixForBitWidth(bitWidth) }, (_, digit) => digit)
    .filter((digit) => segmentIsVisible(segment, digitToBits(digit, bitWidth)))
    .map((digit) => ({
      id: `${segment.id}-digit-${digit}`,
      digit,
      from: segment.from,
      to: segment.to,
      curve: segment.curve,
      bend: segment.bend,
    }));
}

function parseFreeformStroke(value: unknown, bitWidth: number): readonly FreeformStroke[] {
  if (value === null || typeof value !== "object") return [];
  const stroke = value as Partial<FreeformStroke> & { readonly activeBit?: unknown };
  if (typeof stroke.id !== "string" || !Array.isArray(stroke.segments)) return [];
  const segments = stroke.segments
    .slice(0, 64)
    .map(parseBezierSegment)
    .filter((segment): segment is BezierSegment => segment !== null);
  if (segments.length === 0) return [];

  const radix = radixForBitWidth(bitWidth);
  if (typeof stroke.digit === "number"
    && Number.isInteger(stroke.digit)
    && stroke.digit >= 0
    && stroke.digit < radix) {
    return [{ id: stroke.id, digit: stroke.digit, segments }];
  }

  const legacyBit = typeof stroke.activeBit === "number"
    && Number.isInteger(stroke.activeBit)
    && stroke.activeBit >= 0
    && stroke.activeBit < bitWidth
    ? stroke.activeBit
    : null;
  if (stroke.activeBit !== "always" && legacyBit === null) return [];

  return Array.from({ length: radix }, (_, digit) => digit)
    .filter((digit) => stroke.activeBit === "always" || digitToBits(digit, bitWidth)[legacyBit ?? 0])
    .map((digit) => ({ id: `${stroke.id}-digit-${digit}`, digit, segments }));
}

function parseBezierSegment(value: unknown): BezierSegment | null {
  if (value === null || typeof value !== "object") return null;
  const segment = value as Partial<BezierSegment>;
  if (!isPoint(segment.start)
    || !isPoint(segment.control1)
    || !isPoint(segment.control2)
    || !isPoint(segment.end)) return null;
  return {
    start: segment.start,
    control1: segment.control1,
    control2: segment.control2,
    end: segment.end,
  };
}

function isOneOf<const T extends readonly string[]>(value: unknown, options: T): value is T[number] {
  return typeof value === "string" && options.includes(value as T[number]);
}

function clampNumber(value: unknown, minimum: number, maximum: number, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value)
    ? Math.min(maximum, Math.max(minimum, value))
    : fallback;
}

function downloadText(filename: string, content: string, type: string) {
  const url = URL.createObjectURL(new Blob([content], { type }));
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = filename;
  anchor.click();
  window.setTimeout(() => URL.revokeObjectURL(url), 0);
}

export default App;
