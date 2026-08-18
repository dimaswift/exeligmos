import { useEffect, useMemo, useState } from "react";

import { digitToBits, formatDigit, radixForBitWidth } from "../glyph-engine";
import {
  clampTemplateStart,
  dotRadiusForSize,
  makeTemplateEntries,
  numberGroupsFor,
  PRINT_NUMBER_GROUPS,
  type PrintDotSize,
  type PrintNumberGroup,
  type PrintPaper,
  type PrintTemplateMode,
} from "../print-template";
import type { Point, SandboxConfig } from "../types";

interface PrintTemplateProps {
  readonly config: SandboxConfig;
  readonly onClose: () => void;
}

export function PrintTemplate({ config, onClose }: PrintTemplateProps) {
  const [mode, setMode] = useState<PrintTemplateMode>("blank");
  const [paper, setPaper] = useState<PrintPaper>("a4");
  const [columns, setColumns] = useState(4);
  const [rows, setRows] = useState(5);
  const [dotSize, setDotSize] = useState<PrintDotSize>("medium");
  const [showLabels, setShowLabels] = useState(true);
  const [markActiveBits, setMarkActiveBits] = useState(true);
  const [showFrames, setShowFrames] = useState(true);
  const [startDigit, setStartDigit] = useState(0);
  const [markedNumberGroups, setMarkedNumberGroups] = useState<readonly PrintNumberGroup[]>(
    () => PRINT_NUMBER_GROUPS.map((definition) => definition.id),
  );
  const radix = radixForBitWidth(config.bitWidth);
  const capacity = columns * rows;
  const entries = useMemo(
    () => makeTemplateEntries({ mode, radix, capacity, startDigit }),
    [capacity, mode, radix, startDigit],
  );
  const visibleGuidedEntries = entries.filter((entry) => entry !== null);

  const toggleNumberGroup = (group: PrintNumberGroup) => {
    setMarkedNumberGroups((current) => current.includes(group)
      ? current.filter((candidate) => candidate !== group)
      : PRINT_NUMBER_GROUPS
        .map((definition) => definition.id)
        .filter((candidate) => candidate === group || current.includes(candidate)));
  };

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

  const pageRange = mode === "blank"
    ? `${capacity} blank templates`
    : visibleGuidedEntries.length === 0
      ? "No digits on this page"
      : `${formatDigit(visibleGuidedEntries[0] ?? 0, config.bitWidth)}–${formatDigit(visibleGuidedEntries.at(-1) ?? 0, config.bitWidth)}`;

  return (
    <div aria-label="Print dot templates" aria-modal="true" className="print-overlay" role="dialog">
      <style>{`@page { size: ${paper === "a4" ? "A4" : "letter"} portrait; margin: 0; }`}</style>
      <button aria-label="Close print preview" className="print-backdrop" onClick={onClose} type="button" />
      <aside className="print-dialog-panel">
        <header className="print-dialog-header">
          <div>
            <p className="eyebrow">Hand-drawing template</p>
            <h2>Print a field of dots.</h2>
            <p>Every cell uses the current bit geometry. No generator strokes are printed.</p>
          </div>
          <button aria-label="Close print preview" className="print-close" onClick={onClose} type="button">×</button>
        </header>

        <div className="print-controls">
          <PrintField label="Sheet content">
            <div className="segmented-control" role="group" aria-label="Sheet content">
              <button aria-pressed={mode === "blank"} onClick={() => setMode("blank")} type="button">Blank practice</button>
              <button aria-pressed={mode === "guided"} onClick={() => setMode("guided")} type="button">Guided digits</button>
            </div>
          </PrintField>

          <div className="print-control-pair">
            <PrintField label="Paper">
              <select aria-label="Paper size" className="select-input" onChange={(event) => setPaper(event.target.value as PrintPaper)} value={paper}>
                <option value="a4">A4 · 210 × 297 mm</option>
                <option value="letter">Letter · 8.5 × 11 in</option>
              </select>
            </PrintField>
            <PrintField label="Dot size">
              <select aria-label="Printed dot size" className="select-input" onChange={(event) => setDotSize(event.target.value as PrintDotSize)} value={dotSize}>
                <option value="small">Small · fine pen</option>
                <option value="medium">Medium · pencil</option>
                <option value="large">Large · marker</option>
              </select>
            </PrintField>
          </div>

          <div className="print-control-pair">
            <PrintField label="Columns" value={String(columns)}>
              <input aria-label="Template columns" max="5" min="2" onChange={(event) => setColumns(Number(event.target.value))} type="range" value={columns} />
            </PrintField>
            <PrintField label="Rows" value={String(rows)}>
              <input aria-label="Template rows" max="8" min="3" onChange={(event) => setRows(Number(event.target.value))} type="range" value={rows} />
            </PrintField>
          </div>

          {mode === "guided" ? (
            <>
              <PrintField label="First digit" value={`${startDigit + 1} of ${radix}`}>
                <input
                  aria-label="First guided digit"
                  max={radix - 1}
                  min="0"
                  onChange={(event) => setStartDigit(clampTemplateStart(Number(event.target.value), radix))}
                  type="range"
                  value={startDigit}
                />
              </PrintField>
              <PrintField label="Number group marks" value={`${markedNumberGroups.length} of ${PRINT_NUMBER_GROUPS.length}`}>
                <div className="number-group-actions">
                  <button
                    disabled={markedNumberGroups.length === PRINT_NUMBER_GROUPS.length}
                    onClick={() => setMarkedNumberGroups(PRINT_NUMBER_GROUPS.map((definition) => definition.id))}
                    type="button"
                  >
                    All
                  </button>
                  <button
                    disabled={markedNumberGroups.length === 0}
                    onClick={() => setMarkedNumberGroups([])}
                    type="button"
                  >
                    None
                  </button>
                </div>
                <div className="number-group-picker" role="group" aria-label="Number groups to mark">
                  {PRINT_NUMBER_GROUPS.map((definition) => (
                    <label key={definition.id}>
                      <input
                        checked={markedNumberGroups.includes(definition.id)}
                        onChange={() => toggleNumberGroup(definition.id)}
                        type="checkbox"
                      />
                      <span aria-hidden="true">{definition.mark}</span>
                      {definition.label}
                    </label>
                  ))}
                </div>
              </PrintField>
            </>
          ) : null}

          <div className="print-switches">
            <label className="switch-row">
              <input checked={showLabels} onChange={(event) => setShowLabels(event.target.checked)} type="checkbox" />
              <span>Label root and bit positions</span>
            </label>
            {mode === "guided" ? (
              <label className="switch-row">
                <input checked={markActiveBits} onChange={(event) => setMarkActiveBits(event.target.checked)} type="checkbox" />
                <span>Fill the active bit dots</span>
              </label>
            ) : null}
            <label className="switch-row">
              <input checked={showFrames} onChange={(event) => setShowFrames(event.target.checked)} type="checkbox" />
              <span>Show faint cell frames</span>
            </label>
          </div>
        </div>

        <div className="print-summary">
          <span>{paper.toUpperCase()}</span>
          <span>{columns} × {rows}</span>
          <span>{pageRange}</span>
        </div>
        <div className="print-dialog-actions">
          <button className="quiet-button" onClick={onClose} type="button">Cancel</button>
          <button className="primary-button" onClick={() => window.print()} type="button">Print sheet</button>
        </div>
      </aside>

      <main className="print-preview-region">
        <p className="print-preview-label">Paper preview · {paper.toUpperCase()}</p>
        <PrintSheet
          columns={columns}
          config={config}
          dotSize={dotSize}
          entries={entries}
          markActiveBits={markActiveBits && mode === "guided"}
          markedNumberGroups={mode === "guided" ? markedNumberGroups : []}
          mode={mode}
          paper={paper}
          rows={rows}
          showFrames={showFrames}
          showLabels={showLabels}
        />
      </main>
    </div>
  );
}

interface PrintSheetProps {
  readonly config: SandboxConfig;
  readonly entries: readonly (number | null)[];
  readonly mode: PrintTemplateMode;
  readonly paper: PrintPaper;
  readonly columns: number;
  readonly rows: number;
  readonly dotSize: PrintDotSize;
  readonly showLabels: boolean;
  readonly markActiveBits: boolean;
  readonly markedNumberGroups: readonly PrintNumberGroup[];
  readonly showFrames: boolean;
}

function PrintSheet({
  config,
  entries,
  mode,
  paper,
  columns,
  rows,
  dotSize,
  showLabels,
  markActiveBits,
  markedNumberGroups,
  showFrames,
}: PrintSheetProps) {
  const radix = radixForBitWidth(config.bitWidth);
  return (
    <article className={`print-sheet paper-${paper} ${showFrames ? "with-frames" : "without-frames"}`}>
      <header className="print-sheet-header">
        <div>
          <p>GLYPH FOUNDRY / DOT TEMPLATE</p>
          <h1>{mode === "blank" ? "Blank arm practice" : `Base ${radix} digit study`}</h1>
        </div>
        <dl>
          <div><dt>bits</dt><dd>{config.bitWidth}</dd></div>
          <div><dt>base</dt><dd>{radix}</dd></div>
          <div><dt>geometry</dt><dd>{config.layoutPreset}</dd></div>
        </dl>
      </header>
      {mode === "guided" && markedNumberGroups.length > 0 ? (
        <div className="print-number-legend" aria-label="Number group mark legend">
          {PRINT_NUMBER_GROUPS
            .filter((definition) => markedNumberGroups.includes(definition.id))
            .map((definition) => (
              <span key={definition.id}><b aria-hidden="true">{definition.mark}</b>{definition.label}</span>
            ))}
        </div>
      ) : null}
      <div
        className="print-dot-grid"
        style={{ gridTemplateColumns: `repeat(${columns}, 1fr)`, gridTemplateRows: `repeat(${rows}, 1fr)` }}
      >
        {entries.map((digit, index) => (
          <DotCell
            key={`${index}-${digit ?? "blank"}`}
            bitWidth={config.bitWidth}
            corePoint={config.corePoint}
            digit={digit}
            dotRadius={dotRadiusForSize(dotSize)}
            index={index}
            markActiveBits={markActiveBits}
            markedNumberGroups={markedNumberGroups}
            mode={mode}
            points={config.points}
            showLabels={showLabels}
          />
        ))}
      </div>
      <footer className="print-sheet-footer">
        <span>Connect the dots by hand. The page intentionally contains no generated strokes.</span>
        <span>{columns * rows} cells · {paper.toUpperCase()}</span>
      </footer>
    </article>
  );
}

interface DotCellProps {
  readonly bitWidth: number;
  readonly corePoint: Point;
  readonly digit: number | null;
  readonly dotRadius: number;
  readonly index: number;
  readonly markActiveBits: boolean;
  readonly markedNumberGroups: readonly PrintNumberGroup[];
  readonly mode: PrintTemplateMode;
  readonly points: readonly Point[];
  readonly showLabels: boolean;
}

function DotCell({
  bitWidth,
  corePoint,
  digit,
  dotRadius,
  index,
  markActiveBits,
  markedNumberGroups,
  mode,
  points,
  showLabels,
}: DotCellProps) {
  const bits = digit === null ? Array<boolean>(bitWidth).fill(false) : digitToBits(digit, bitWidth);
  const numberGroups = digit === null
    ? []
    : numberGroupsFor(digit).filter((group) => markedNumberGroups.includes(group));
  return (
    <section className="print-dot-cell">
      <header>
        {mode === "guided" && digit !== null ? (
          <div className="print-dot-cell-id">
            <strong>{formatDigit(digit, bitWidth)}</strong>
            <span>{bits.map((bit) => bit ? "1" : "0").join("")}</span>
          </div>
        ) : (
          <span>NO. {String(index + 1).padStart(2, "0")}</span>
        )}
        {numberGroups.length > 0 ? (
          <div
            aria-label={numberGroups
              .map((group) => PRINT_NUMBER_GROUPS.find((definition) => definition.id === group)?.label)
              .filter(Boolean)
              .join(", ")}
            className="print-cell-number-marks"
          >
            {numberGroups.map((group) => {
              const definition = PRINT_NUMBER_GROUPS.find((candidate) => candidate.id === group);
              return definition === undefined ? null : (
                <abbr key={group} title={definition.label}>{definition.mark}</abbr>
              );
            })}
          </div>
        ) : null}
      </header>
      <svg aria-label={digit === null ? `Blank dot template ${index + 1}` : `Dot template for digit ${formatDigit(digit, bitWidth)}`} role="img" viewBox="-125 -180 250 220">
        {points.map((point, pointIndex) => {
          const active = markActiveBits && (bits[pointIndex] ?? false);
          return (
            <g key={pointIndex}>
              <circle className={active ? "active-dot" : "open-dot"} cx={point.x} cy={point.y} r={dotRadius} />
              {showLabels ? <text x={point.x + dotRadius + 4} y={point.y + 3}>B{pointIndex}</text> : null}
            </g>
          );
        })}
        <circle className="core-dot" cx={corePoint.x} cy={corePoint.y} r={dotRadius} />
        {showLabels ? <text x={corePoint.x + dotRadius + 4} y={corePoint.y + 3}>CORE</text> : null}
        <circle className="root-dot" cx="0" cy="0" r={dotRadius} />
        {showLabels ? <text x={dotRadius + 4} y="3">ROOT</text> : null}
      </svg>
    </section>
  );
}

function PrintField({
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
