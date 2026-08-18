import { useEffect, useMemo, useState } from "react";

import { glyphColor } from "../glyph-colors";
import {
  digitToBits,
  findGlyphCollisions,
  formatDigit,
  radixForBitWidth,
} from "../glyph-engine";
import { clampTemplateStart, type PrintPaper } from "../print-template";
import type { SandboxConfig } from "../types";
import { ArmDrawing } from "./ArmDrawing";

interface GlyphAtlasProps {
  readonly config: SandboxConfig;
  readonly onClose: () => void;
}

export function GlyphAtlas({ config, onClose }: GlyphAtlasProps) {
  const radix = radixForBitWidth(config.bitWidth);
  const [paper, setPaper] = useState<PrintPaper>("a4");
  const [columns, setColumns] = useState(4);
  const [rows, setRows] = useState(() => Math.min(8, Math.max(3, Math.ceil(Math.min(radix, 32) / 4))));
  const [startDigit, setStartDigit] = useState(0);
  const [showBits, setShowBits] = useState(true);
  const [showGuides, setShowGuides] = useState(false);
  const capacity = columns * rows;
  const entries = useMemo(
    () => Array.from({ length: capacity }, (_, index) => {
      const digit = startDigit + index;
      return digit < radix ? digit : null;
    }),
    [capacity, radix, startDigit],
  );
  const visibleEntries = entries.filter((entry): entry is number => entry !== null);
  const collisionGroups = useMemo(
    () => findGlyphCollisions(
      config.bitWidth,
      config.segments,
      config.freeformStrokes,
      config.tracedStrokes,
      { strokePreset: config.strokePreset, bottomBit: config.bottomBit },
    ),
    [config],
  );
  const collidingDigits = useMemo(() => new Set(collisionGroups.flat()), [collisionGroups]);
  const distinctForms = radix - collisionGroups.reduce((count, group) => count + group.length - 1, 0);

  useEffect(() => {
    setStartDigit((current) => clampTemplateStart(current, radix));
  }, [radix]);

  useEffect(() => {
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") onClose();
    };
    window.addEventListener("keydown", handleKeyDown);
    return () => {
      document.body.style.overflow = previousOverflow;
      window.removeEventListener("keydown", handleKeyDown);
    };
  }, [onClose]);

  const rangeLabel = visibleEntries.length === 0
    ? "No digits on this page"
    : `${formatDigit(visibleEntries[0] ?? 0, config.bitWidth)}–${formatDigit(visibleEntries.at(-1) ?? 0, config.bitWidth)}`;

  return (
    <div aria-label="Glyph atlas preview" aria-modal="true" className="print-overlay atlas-overlay" role="dialog">
      <style>{`@page { size: ${paper === "a4" ? "A4" : "letter"} portrait; margin: 0; }`}</style>
      <button aria-label="Close glyph atlas" className="print-backdrop" onClick={onClose} type="button" />
      <aside className="print-dialog-panel">
        <header className="print-dialog-header">
          <div>
            <p className="eyebrow">System atlas</p>
            <h2>Preview every digit.</h2>
            <p>The sheet uses the current geometry, movable core, root bit, and stroke rule.</p>
          </div>
          <button aria-label="Close glyph atlas" className="print-close" onClick={onClose} type="button">×</button>
        </header>

        <div className="print-controls">
          <div className="print-control-pair">
            <AtlasField label="Paper">
              <select aria-label="Atlas paper size" className="select-input" onChange={(event) => setPaper(event.target.value as PrintPaper)} value={paper}>
                <option value="a4">A4 · 210 × 297 mm</option>
                <option value="letter">Letter · 8.5 × 11 in</option>
              </select>
            </AtlasField>
            <AtlasField label="Page" value={`${startDigit + 1} of ${radix}`}>
              <div className="atlas-page-actions">
                <button
                  disabled={startDigit === 0}
                  onClick={() => setStartDigit(Math.max(0, startDigit - capacity))}
                  type="button"
                >
                  ←
                </button>
                <button
                  disabled={startDigit + capacity >= radix}
                  onClick={() => setStartDigit(Math.min(radix - 1, startDigit + capacity))}
                  type="button"
                >
                  →
                </button>
              </div>
            </AtlasField>
          </div>

          <div className="print-control-pair">
            <AtlasField label="Columns" value={String(columns)}>
              <input aria-label="Atlas columns" max="8" min="3" onChange={(event) => setColumns(Number(event.target.value))} type="range" value={columns} />
            </AtlasField>
            <AtlasField label="Rows" value={String(rows)}>
              <input aria-label="Atlas rows" max="10" min="3" onChange={(event) => setRows(Number(event.target.value))} type="range" value={rows} />
            </AtlasField>
          </div>

          <AtlasField label="First digit" value={`${formatDigit(startDigit, config.bitWidth)} · decimal ${startDigit}`}>
            <input
              aria-label="First atlas digit"
              max={radix - 1}
              min="0"
              onChange={(event) => setStartDigit(clampTemplateStart(Number(event.target.value), radix))}
              type="range"
              value={startDigit}
            />
          </AtlasField>

          <div className="print-switches">
            <label className="switch-row">
              <input checked={showBits} onChange={(event) => setShowBits(event.target.checked)} type="checkbox" />
              <span>Show bit patterns</span>
            </label>
            <label className="switch-row">
              <input checked={showGuides} onChange={(event) => setShowGuides(event.target.checked)} type="checkbox" />
              <span>Show vertex guides</span>
            </label>
          </div>

          <div className="atlas-rule-summary">
            <span>Rule</span>
            <strong>{config.strokePreset === "core-shell" ? "Core + shell" : config.strokePreset}</strong>
            <small>Root → B{config.bottomBit} · Core {Math.round(config.corePoint.x)}, {Math.round(config.corePoint.y)}</small>
          </div>
        </div>

        <div className="print-summary">
          <span>{paper.toUpperCase()}</span>
          <span>{columns} × {rows}</span>
          <span>{rangeLabel}</span>
          <span>{distinctForms}/{radix} distinct</span>
        </div>
        <div className="print-dialog-actions">
          <button className="quiet-button" onClick={onClose} type="button">Cancel</button>
          <button className="primary-button" onClick={() => window.print()} type="button">Print atlas</button>
        </div>
      </aside>

      <main className="print-preview-region">
        <p className="print-preview-label">Atlas preview · {paper.toUpperCase()}</p>
        <AtlasSheet
          collidingDigits={collidingDigits}
          columns={columns}
          config={config}
          distinctForms={distinctForms}
          entries={entries}
          paper={paper}
          rows={rows}
          showBits={showBits}
          showGuides={showGuides}
        />
      </main>
    </div>
  );
}

interface AtlasSheetProps {
  readonly config: SandboxConfig;
  readonly entries: readonly (number | null)[];
  readonly collidingDigits: ReadonlySet<number>;
  readonly distinctForms: number;
  readonly paper: PrintPaper;
  readonly columns: number;
  readonly rows: number;
  readonly showBits: boolean;
  readonly showGuides: boolean;
}

function AtlasSheet({
  config,
  entries,
  collidingDigits,
  distinctForms,
  paper,
  columns,
  rows,
  showBits,
  showGuides,
}: AtlasSheetProps) {
  const radix = radixForBitWidth(config.bitWidth);
  return (
    <article className={`print-sheet atlas-sheet paper-${paper}`}>
      <header className="print-sheet-header">
        <div>
          <p>GLYPH FOUNDRY / DIGIT ATLAS</p>
          <h1>Base {radix} · {config.strokePreset === "core-shell" ? "Core + shell" : config.strokePreset}</h1>
        </div>
        <dl>
          <div><dt>bits</dt><dd>{config.bitWidth}</dd></div>
          <div><dt>root bit</dt><dd>B{config.bottomBit}</dd></div>
          <div><dt>forms</dt><dd>{distinctForms}/{radix}</dd></div>
        </dl>
      </header>
      <div
        className="atlas-grid"
        style={{ gridTemplateColumns: `repeat(${columns}, 1fr)`, gridTemplateRows: `repeat(${rows}, 1fr)` }}
      >
        {entries.map((digit, index) => digit === null ? (
          <section className="atlas-cell empty" key={`empty-${index}`} />
        ) : (
          <section className={`atlas-cell ${collidingDigits.has(digit) ? "collision" : ""}`} key={digit}>
            <header>
              <strong>{formatDigit(digit, config.bitWidth)}</strong>
              {showBits ? <span>{digitToBits(digit, config.bitWidth).map((bit) => bit ? "1" : "0").join("")}</span> : null}
              {radix > 36 ? <small>DEC {digit}</small> : null}
              {collidingDigits.has(digit) ? <em>!</em> : null}
            </header>
            <svg aria-label={`Atlas glyph ${formatDigit(digit, config.bitWidth)}`} role="img" viewBox="-120 -178 240 204">
              <ArmDrawing
                bitWidth={config.bitWidth}
                bottomBit={config.bottomBit}
                corePoint={config.corePoint}
                digit={digit}
                freeformStrokes={config.freeformStrokes}
                points={config.points}
                rounded={config.rounded}
                segments={config.segments}
                showGuides={showGuides}
                showDisconnectedBitDots={config.showDisconnectedBitDots}
                stroke={glyphColor(config, 0, digit)}
                strokePreset={config.strokePreset}
                strokeWidth={Math.max(3, config.strokeWidth * 0.72)}
                tracedStrokes={config.tracedStrokes}
              />
            </svg>
          </section>
        ))}
      </div>
      <footer className="print-sheet-footer">
        <span>Core {Math.round(config.corePoint.x)}, {Math.round(config.corePoint.y)} · Root → B{config.bottomBit}</span>
        <span>{entries.filter((entry) => entry !== null).length} glyphs · {paper.toUpperCase()}</span>
      </footer>
    </article>
  );
}

function AtlasField({
  label,
  value,
  children,
}: {
  readonly label: string;
  readonly value?: string;
  readonly children: React.ReactNode;
}) {
  return (
    <div className="print-field">
      <div><span>{label}</span>{value === undefined ? null : <strong>{value}</strong>}</div>
      {children}
    </div>
  );
}
