import { useEffect, useRef, useState } from "react";

import {
  bezierSegmentsFromPolyline,
  bezierSegmentsPathData,
  bezierStrokePathData,
  digitToBits,
  formatDigit,
  freeformStrokeIsVisible,
  pointForEndpoint,
  radixForBitWidth,
  resolveStrokeSegments,
  segmentIsVisible,
  segmentPathData,
  snapPointToGrid,
} from "../glyph-engine";
import type {
  Endpoint,
  FreeformStroke,
  GridType,
  Point,
  StrokePreset,
  StrokeSegment,
  TracedStroke,
} from "../types";
import { ArmDrawing } from "./ArmDrawing";

interface BitPatternEditorProps {
  readonly bitWidth: number;
  readonly digit: number;
  readonly points: readonly Point[];
  readonly corePoint: Point;
  readonly bottomBit: number;
  readonly segments: readonly StrokeSegment[];
  readonly strokePreset: StrokePreset;
  readonly tracedStrokes: readonly TracedStroke[];
  readonly freeformStrokes: readonly FreeformStroke[];
  readonly strokeWidth: number;
  readonly rounded: boolean;
  readonly showDisconnectedBitDots: boolean;
  readonly strokeColor: string;
  readonly gridType: GridType;
  readonly snapToGrid: boolean;
  readonly gridSpacing: number;
  readonly onPointsChange: (points: readonly Point[]) => void;
  readonly onCorePointChange: (point: Point) => void;
  readonly onDigitChange: (digit: number) => void;
  readonly onTracedStrokeAdd: (from: Endpoint, to: Endpoint) => string;
  readonly onTracedStrokeUpdate: (id: string, patch: Partial<TracedStroke>) => void;
  readonly onTracedStrokeRemove: (id: string) => void;
  readonly onTracedStrokeUndo: () => void;
  readonly onFreeformAdd: (points: readonly Point[]) => void;
  readonly onFreeformUndo: () => void;
}

type EditorMode = "move" | "trace" | "freeform";

export function BitPatternEditor({
  bitWidth,
  digit,
  points,
  corePoint,
  bottomBit,
  segments,
  strokePreset,
  tracedStrokes,
  freeformStrokes,
  strokeWidth,
  rounded,
  showDisconnectedBitDots,
  strokeColor,
  gridType,
  snapToGrid,
  gridSpacing,
  onPointsChange,
  onCorePointChange,
  onDigitChange,
  onTracedStrokeAdd,
  onTracedStrokeUpdate,
  onTracedStrokeRemove,
  onTracedStrokeUndo,
  onFreeformAdd,
  onFreeformUndo,
}: BitPatternEditorProps) {
  const svgRef = useRef<SVGSVGElement>(null);
  const [draggedVertex, setDraggedVertex] = useState<number | "core" | null>(null);
  const [mode, setMode] = useState<EditorMode>("move");
  const [traceStart, setTraceStart] = useState<Endpoint | null>(null);
  const [tracePointer, setTracePointer] = useState<Point | null>(null);
  const [selectedTracedStrokeId, setSelectedTracedStrokeId] = useState<string | null>(null);
  const [drawingPoints, setDrawingPoints] = useState<readonly Point[]>([]);
  const drawingPointsRef = useRef<Point[]>([]);
  const drawingPointerRef = useRef<number | null>(null);
  const pendingTracedStrokeIdRef = useRef<string | null>(null);
  const radix = radixForBitWidth(bitWidth);
  const bits = digitToBits(digit, bitWidth);
  const resolvedSegments = resolveStrokeSegments(strokePreset, segments, bitWidth, digit, bottomBit);
  const currentTracedStrokes = tracedStrokes.filter((stroke) => stroke.digit === digit);
  const currentFreeformStrokes = freeformStrokes.filter((stroke) => stroke.digit === digit);
  const selectedTracedStroke = currentTracedStrokes.find((stroke) => stroke.id === selectedTracedStrokeId) ?? null;
  const drawingPreview = bezierSegmentsPathData(bezierSegmentsFromPolyline(drawingPoints, 1.2));

  useEffect(() => {
    const pendingId = pendingTracedStrokeIdRef.current;
    if (pendingId !== null && currentTracedStrokes.some((stroke) => stroke.id === pendingId)) {
      setSelectedTracedStrokeId(pendingId);
      pendingTracedStrokeIdRef.current = null;
    }
  }, [currentTracedStrokes]);

  useEffect(() => {
    pendingTracedStrokeIdRef.current = null;
    setTraceStart(null);
    setTracePointer(null);
    setSelectedTracedStrokeId(null);
  }, [digit]);

  const pointFromEvent = (event: React.PointerEvent<SVGElement>): Point | null => {
    const svg = svgRef.current;
    if (svg === null) return null;
    const matrix = svg.getScreenCTM();
    if (matrix === null) return null;
    const domPoint = new DOMPoint(event.clientX, event.clientY).matrixTransform(matrix.inverse());
    return {
      x: Math.max(-116, Math.min(116, domPoint.x)),
      y: Math.max(-174, Math.min(20, domPoint.y)),
    };
  };

  const movePoint = (event: React.PointerEvent<SVGCircleElement>, index: number) => {
    if (mode !== "move" || draggedVertex !== index) return;
    const eventPoint = pointFromEvent(event);
    if (eventPoint === null) return;
    const candidate = snapToGrid ? snapPointToGrid(eventPoint, gridType, gridSpacing) : eventPoint;
    const point = {
      x: Math.max(-100, Math.min(100, candidate.x)),
      y: Math.max(-154, Math.min(-26, candidate.y)),
    };
    onPointsChange(points.map((current, currentIndex) => (currentIndex === index ? point : current)));
  };

  const moveCorePoint = (event: React.PointerEvent<SVGCircleElement>) => {
    if (mode !== "move" || draggedVertex !== "core") return;
    const eventPoint = pointFromEvent(event);
    if (eventPoint === null) return;
    const candidate = snapToGrid ? snapPointToGrid(eventPoint, gridType, gridSpacing) : eventPoint;
    onCorePointChange({
      x: Math.max(-100, Math.min(100, candidate.x)),
      y: Math.max(-154, Math.min(-26, candidate.y)),
    });
  };

  const chooseTraceEndpoint = (endpoint: Endpoint) => {
    if (mode !== "trace") return;
    if (traceStart === null) {
      setTraceStart(endpoint);
      setTracePointer(pointForEndpoint(endpoint, points, corePoint));
      return;
    }
    if (traceStart !== endpoint) {
      const id = onTracedStrokeAdd(traceStart, endpoint);
      pendingTracedStrokeIdRef.current = id;
      setSelectedTracedStrokeId(id);
    }
    setTraceStart(null);
    setTracePointer(null);
  };

  const setEditorMode = (nextMode: EditorMode) => {
    setMode(nextMode);
    setTraceStart(null);
    setTracePointer(null);
    setSelectedTracedStrokeId(null);
    setDraggedVertex(null);
    drawingPointsRef.current = [];
    drawingPointerRef.current = null;
    setDrawingPoints([]);
  };

  const startFreeformStroke = (event: React.PointerEvent<SVGSVGElement>) => {
    if (mode !== "freeform" || event.button !== 0) return;
    const point = pointFromEvent(event);
    if (point === null) return;
    event.preventDefault();
    event.currentTarget.setPointerCapture(event.pointerId);
    drawingPointerRef.current = event.pointerId;
    drawingPointsRef.current = [point];
    setDrawingPoints([point]);
  };

  const continueFreeformStroke = (event: React.PointerEvent<SVGSVGElement>) => {
    if (mode !== "freeform" || drawingPointerRef.current !== event.pointerId) return;
    const point = pointFromEvent(event);
    const previous = drawingPointsRef.current.at(-1);
    if (point === null || (previous !== undefined && Math.hypot(point.x - previous.x, point.y - previous.y) < 1.4)) return;
    drawingPointsRef.current = [...drawingPointsRef.current, point];
    setDrawingPoints(drawingPointsRef.current);
  };

  const finishFreeformStroke = (event: React.PointerEvent<SVGSVGElement>) => {
    if (mode !== "freeform" || drawingPointerRef.current !== event.pointerId) return;
    const point = pointFromEvent(event);
    const previous = drawingPointsRef.current.at(-1);
    if (point !== null && previous !== undefined && Math.hypot(point.x - previous.x, point.y - previous.y) >= 1) {
      drawingPointsRef.current = [...drawingPointsRef.current, point];
    }
    const completed = drawingPointsRef.current;
    const drawnLength = completed.slice(1).reduce((length, point, index) => {
      const previous = completed[index];
      return previous === undefined ? length : length + Math.hypot(point.x - previous.x, point.y - previous.y);
    }, 0);
    if (completed.length >= 2 && drawnLength >= 4) {
      onFreeformAdd(completed);
    }
    if (event.currentTarget.hasPointerCapture(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId);
    }
    drawingPointerRef.current = null;
    drawingPointsRef.current = [];
    setDrawingPoints([]);
  };

  const cancelFreeformStroke = (event: React.PointerEvent<SVGSVGElement>) => {
    if (drawingPointerRef.current !== event.pointerId) return;
    if (event.currentTarget.hasPointerCapture(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId);
    }
    drawingPointerRef.current = null;
    drawingPointsRef.current = [];
    setDrawingPoints([]);
  };

  return (
    <div className="pattern-editor-shell">
      <div className="editor-mode-bar">
        <div className="segmented-control compact" aria-label="Vertex editor mode">
          <button aria-label="Move vertices" aria-pressed={mode === "move"} onClick={() => setEditorMode("move")} type="button">
            Move
          </button>
          <button aria-label="Trace strokes" aria-pressed={mode === "trace"} onClick={() => setEditorMode("trace")} type="button">
            Trace
          </button>
          <button aria-label="Draw freeform Bezier strokes" aria-pressed={mode === "freeform"} onClick={() => setEditorMode("freeform")} type="button">
            Freeform
          </button>
        </div>
        {mode === "trace" || mode === "freeform" ? (
          <label className="trace-condition freeform-condition">
            Editing digit
            {radix <= 256 ? (
              <select
                aria-label="Digit stroke set to edit"
                onChange={(event) => onDigitChange(Number(event.target.value))}
                value={digit}
              >
                {Array.from({ length: radix }, (_, value) => (
                  <option key={value} value={value}>{formatDigit(value, bitWidth)}</option>
                ))}
              </select>
            ) : (
              <input
                aria-label="Digit stroke set to edit"
                max={radix - 1}
                min="0"
                onChange={(event) => onDigitChange(Math.min(radix - 1, Math.max(0, Number(event.target.value))))}
                step="1"
                type="number"
                value={digit}
              />
            )}
          </label>
        ) : (
          <span className="editor-grid-status">
            {gridType} grid · {snapToGrid ? "snapping on" : "free move"}
          </span>
        )}
      </div>
      {mode === "trace" ? (
        <div className="trace-hint" role="status">
          <span>{traceStart === null
            ? selectedTracedStroke === null
              ? `Digit ${formatDigit(digit, bitWidth)} · choose two vertices to add a stroke, or select an existing stroke.`
              : `Editing this stroke for digit ${formatDigit(digit, bitWidth)}.`
            : `Start: ${traceEndpointName(traceStart)}. Choose the end vertex.`}</span>
          {traceStart !== null ? (
            <button onClick={() => setTraceStart(null)} type="button">Cancel</button>
          ) : currentTracedStrokes.length > 0 ? (
            <button onClick={onTracedStrokeUndo} type="button">Undo last for {formatDigit(digit, bitWidth)}</button>
          ) : null}
        </div>
      ) : mode === "freeform" ? (
        <div className="trace-hint freeform-hint" role="status">
          <span>{drawingPoints.length > 0
            ? `Drawing for ${formatDigit(digit, bitWidth)}… release to create the Bézier stroke.`
            : `Drag to draw a cubic Bézier stroke for digit ${formatDigit(digit, bitWidth)} only.`}</span>
          {currentFreeformStrokes.length > 0 ? <button onClick={onFreeformUndo} type="button">Undo last for {formatDigit(digit, bitWidth)}</button> : null}
        </div>
      ) : null}
      <div className="pattern-editor-canvas">
        <svg
          ref={svgRef}
          aria-label="Interactive bit geometry editor"
          className={`pattern-editor mode-${mode}`}
          onPointerCancel={cancelFreeformStroke}
          onPointerDown={startFreeformStroke}
          onPointerLeave={() => {
            if (traceStart !== null) setTracePointer(pointForEndpoint(traceStart, points, corePoint));
          }}
          onPointerMove={(event) => {
            if (traceStart !== null) setTracePointer(pointFromEvent(event));
            continueFreeformStroke(event);
          }}
          onPointerUp={finishFreeformStroke}
          role="img"
          viewBox="-120 -178 240 204"
        >
        <EditorGrid gridType={gridType} spacing={gridSpacing} />
        <line x1="-108" x2="108" y1="0" y2="0" stroke="currentColor" strokeOpacity=".18" />
        {resolvedSegments.map((segment) => (
          <path
            d={segmentPathData(segment, points, 24, corePoint)}
            fill="none"
            key={`rule-${segment.id}`}
            stroke="currentColor"
            strokeDasharray="3 6"
            strokeOpacity={segmentIsVisible(segment, bits) ? 0.2 : 0.08}
            strokeWidth="1.2"
          />
        ))}
        {currentFreeformStrokes.map((freeformStroke) => (
          <path
            d={bezierStrokePathData(freeformStroke)}
            fill="none"
            key={`freeform-rule-${freeformStroke.id}`}
            stroke="currentColor"
            strokeDasharray="3 6"
            strokeOpacity={freeformStrokeIsVisible(freeformStroke, digit) ? 0.2 : 0.08}
            strokeWidth="1.2"
          />
        ))}
        {traceStart !== null && tracePointer !== null ? (
          <path
            className="trace-preview"
            d={`M ${pointForEndpoint(traceStart, points, corePoint).x} ${pointForEndpoint(traceStart, points, corePoint).y} L ${tracePointer.x} ${tracePointer.y}`}
            fill="none"
          />
        ) : null}
        {drawingPreview === "" ? null : (
          <path className="freeform-preview" d={drawingPreview} fill="none" />
        )}
        <ArmDrawing
          bitWidth={bitWidth}
          bottomBit={bottomBit}
          corePoint={corePoint}
          digit={digit}
          freeformStrokes={freeformStrokes}
          points={points}
          rounded={rounded}
          segments={segments}
          showDisconnectedBitDots={showDisconnectedBitDots}
          strokePreset={strokePreset}
          tracedStrokes={tracedStrokes}
          stroke={strokeColor}
          strokeWidth={strokeWidth}
        />
        {mode === "trace" ? currentTracedStrokes.map((tracedStroke, index) => {
          const selected = tracedStroke.id === selectedTracedStrokeId;
          const label = `Trace stroke ${index + 1}, ${traceEndpointName(tracedStroke.from)} to ${traceEndpointName(tracedStroke.to)}`;
          return (
            <g className={`traced-segment-target ${selected ? "selected" : ""}`} key={`target-${tracedStroke.id}`}>
              <path
                className="traced-segment-outline"
                d={segmentPathData(tracedStroke, points, 24, corePoint)}
                fill="none"
              />
              <path
                aria-label={label}
                className="traced-segment-hit"
                d={segmentPathData(tracedStroke, points, 24, corePoint)}
                fill="none"
                onClick={(event) => {
                  event.stopPropagation();
                  setTraceStart(null);
                  setTracePointer(null);
                  setSelectedTracedStrokeId(tracedStroke.id);
                }}
                onKeyDown={(event) => {
                  if (event.key !== "Enter" && event.key !== " ") return;
                  event.preventDefault();
                  setSelectedTracedStrokeId(tracedStroke.id);
                }}
                role="button"
                tabIndex={0}
              />
            </g>
          );
        }) : null}
        <g className={traceStart === "core" ? "trace-origin" : undefined}>
          <circle
            aria-label={mode === "trace" ? "Choose core vertex" : mode === "move" ? "Drag core vertex" : "Core vertex guide"}
            className="core-handle"
            cx={corePoint.x}
            cy={corePoint.y}
            fill="var(--paper)"
            onClick={() => chooseTraceEndpoint("core")}
            onKeyDown={(event) => {
              if (event.key === "Enter" || event.key === " ") chooseTraceEndpoint("core");
            }}
            onPointerDown={(event) => {
              if (mode !== "move") return;
              event.currentTarget.setPointerCapture(event.pointerId);
              setDraggedVertex("core");
            }}
            onPointerMove={moveCorePoint}
            onPointerUp={(event) => {
              if (event.currentTarget.hasPointerCapture(event.pointerId)) {
                event.currentTarget.releasePointerCapture(event.pointerId);
              }
              setDraggedVertex(null);
            }}
            r="7"
            role={mode === "freeform" ? undefined : "button"}
            stroke="var(--accent-deep)"
            strokeWidth="2"
            tabIndex={mode === "freeform" ? undefined : 0}
          />
          <text className="core-label" pointerEvents="none" x={corePoint.x + 9} y={corePoint.y + 3}>core</text>
        </g>
        <g
          aria-label="Root vertex"
          className={traceStart === "root" ? "trace-origin" : undefined}
          onClick={() => chooseTraceEndpoint("root")}
          onKeyDown={(event) => {
            if (event.key === "Enter" || event.key === " ") chooseTraceEndpoint("root");
          }}
          role={mode === "trace" ? "button" : undefined}
          tabIndex={mode === "trace" ? 0 : undefined}
        >
          <circle className="root-handle" cx="0" cy="0" fill="var(--ink)" r={mode === "trace" ? 7 : 4} />
          <text x="8" y="4" className="svg-label">root</text>
        </g>
        {points.map((point, index) => (
          <g className={traceStart === index ? "trace-origin" : undefined} key={`handle-${index}`}>
            {strokePreset === "core-shell" && index === bottomBit ? (
              <circle className="bottom-bit-ring" cx={point.x} cy={point.y} r="10" />
            ) : null}
            <circle
              aria-label={mode === "trace" ? `Choose bit ${index}` : mode === "move" ? `Drag bit ${index}` : `Bit ${index} guide`}
              className="drag-handle"
              cx={point.x}
              cy={point.y}
              fill={bits[index] ? "var(--accent)" : "var(--paper)"}
              onClick={() => chooseTraceEndpoint(index)}
              onKeyDown={(event) => {
                if (event.key === "Enter" || event.key === " ") chooseTraceEndpoint(index);
              }}
              onPointerDown={(event) => {
                if (mode !== "move") return;
                event.currentTarget.setPointerCapture(event.pointerId);
                setDraggedVertex(index);
              }}
              onPointerMove={(event) => movePoint(event, index)}
              onPointerUp={(event) => {
                if (event.currentTarget.hasPointerCapture(event.pointerId)) {
                  event.currentTarget.releasePointerCapture(event.pointerId);
                }
                setDraggedVertex(null);
              }}
              r="7"
              role={mode === "freeform" ? undefined : "button"}
              stroke="var(--ink)"
              strokeWidth="1.5"
              tabIndex={mode === "freeform" ? undefined : 0}
            />
            <text className="bit-index" pointerEvents="none" textAnchor="middle" x={point.x} y={point.y + 2.7}>
              {index}
            </text>
          </g>
        ))}
        </svg>
        {mode === "trace" && selectedTracedStroke !== null ? (
          <div
            aria-label={`Curve controls for digit ${formatDigit(digit, bitWidth)}`}
            className="canvas-segment-editor"
            role="group"
          >
            <header>
              <div>
                <strong>{traceEndpointName(selectedTracedStroke.from)} → {traceEndpointName(selectedTracedStroke.to)}</strong>
                <small>Digit {formatDigit(digit, bitWidth)} stroke</small>
              </div>
              <button aria-label="Close curve controls" onClick={() => setSelectedTracedStrokeId(null)} type="button">×</button>
            </header>
            <div className="canvas-curve-types" role="group" aria-label="Curve type">
              <button
                aria-pressed={selectedTracedStroke.curve === "line"}
                onClick={() => onTracedStrokeUpdate(selectedTracedStroke.id, { curve: "line", bend: 0 })}
                type="button"
              >
                Line
              </button>
              <button
                aria-pressed={selectedTracedStroke.curve === "hyperbolic"}
                onClick={() => onTracedStrokeUpdate(selectedTracedStroke.id, {
                  curve: "hyperbolic",
                  bend: selectedTracedStroke.bend === 0 ? 32 : selectedTracedStroke.bend,
                })}
                type="button"
              >
                Hyperbolic
              </button>
            </div>
            {selectedTracedStroke.curve === "hyperbolic" ? (
              <>
                <label className="canvas-curvature">
                  <span>Curvature</span>
                  <input
                    aria-label="Selected trace curvature"
                    max="120"
                    min="4"
                    onChange={(event) => onTracedStrokeUpdate(selectedTracedStroke.id, {
                      bend: Math.sign(selectedTracedStroke.bend || 1) * Number(event.target.value),
                    })}
                    step="2"
                    type="range"
                    value={Math.max(4, Math.abs(selectedTracedStroke.bend))}
                  />
                  <output>{Math.abs(selectedTracedStroke.bend)}</output>
                </label>
                <div className="canvas-bend-side" role="group" aria-label="Bend side">
                  <span>Bend side</span>
                  <button
                    aria-pressed={selectedTracedStroke.bend >= 0}
                    onClick={() => onTracedStrokeUpdate(selectedTracedStroke.id, {
                      bend: Math.max(4, Math.abs(selectedTracedStroke.bend || 32)),
                    })}
                    type="button"
                  >
                    Left
                  </button>
                  <button
                    aria-pressed={selectedTracedStroke.bend < 0}
                    onClick={() => onTracedStrokeUpdate(selectedTracedStroke.id, {
                      bend: -Math.max(4, Math.abs(selectedTracedStroke.bend || 32)),
                    })}
                    type="button"
                  >
                    Right
                  </button>
                </div>
              </>
            ) : null}
            <footer>
              <button
                onClick={() => onTracedStrokeUpdate(selectedTracedStroke.id, {
                  from: selectedTracedStroke.to,
                  to: selectedTracedStroke.from,
                  bend: -selectedTracedStroke.bend,
                })}
                type="button"
              >
                Reverse direction
              </button>
              <button
                className="danger"
                onClick={() => {
                  onTracedStrokeRemove(selectedTracedStroke.id);
                  setSelectedTracedStrokeId(null);
                }}
                type="button"
              >
                Delete
              </button>
            </footer>
          </div>
        ) : null}
      </div>
    </div>
  );
}

function traceEndpointName(endpoint: Endpoint): string {
  if (endpoint === "root") return "Root";
  if (endpoint === "core") return "Core";
  return `B${endpoint}`;
}

function EditorGrid({ gridType, spacing }: { readonly gridType: GridType; readonly spacing: number }) {
  if (gridType === "square") {
    const verticals = range(-120, 120, spacing);
    const horizontals = range(-178, 26, spacing);
    return (
      <g className="editor-grid">
        {verticals.map((x) => <line key={`v-${x}`} x1={x} x2={x} y1="-178" y2="26" />)}
        {horizontals.map((y) => <line key={`h-${y}`} x1="-120" x2="120" y1={y} y2={y} />)}
      </g>
    );
  }

  if (gridType === "triangular") {
    const rowHeight = (spacing * Math.sqrt(3)) / 2;
    const minimumRow = Math.floor(-178 / rowHeight) - 1;
    const maximumRow = Math.ceil(26 / rowHeight) + 1;
    const strokes: React.ReactNode[] = [];
    for (let row = minimumRow; row <= maximumRow; row += 1) {
      const y = row * rowHeight;
      const offset = Math.abs(row) % 2 === 1 ? spacing / 2 : 0;
      const minimumColumn = Math.floor((-120 - offset) / spacing) - 1;
      const maximumColumn = Math.ceil((120 - offset) / spacing) + 1;
      for (let column = minimumColumn; column <= maximumColumn; column += 1) {
        const x = column * spacing + offset;
        strokes.push(<line key={`${row}-${column}-h`} x1={x} x2={x + spacing} y1={y} y2={y} />);
        strokes.push(
          <line
            key={`${row}-${column}-d`}
            x1={x}
            x2={x + (Math.abs(row) % 2 === 1 ? -spacing / 2 : spacing / 2)}
            y1={y}
            y2={y + rowHeight}
          />,
        );
      }
    }
    return <g className="editor-grid triangular-grid">{strokes}</g>;
  }

  const cells: React.ReactNode[] = [];
  const extent = Math.ceil(240 / spacing);
  for (let q = -extent; q <= extent; q += 1) {
    for (let r = -extent; r <= extent; r += 1) {
      const centerX = spacing * Math.sqrt(3) * (q + r / 2);
      const centerY = spacing * 1.5 * r;
      if (centerX < -120 - spacing || centerX > 120 + spacing) continue;
      if (centerY < -178 - spacing || centerY > 26 + spacing) continue;
      const vertices = Array.from({ length: 6 }, (_, index) => {
        const angle = ((index * 60 - 30) * Math.PI) / 180;
        return `${centerX + Math.cos(angle) * spacing},${centerY + Math.sin(angle) * spacing}`;
      }).join(" ");
      cells.push(<polygon key={`${q}-${r}`} points={vertices} />);
      cells.push(<circle className="grid-node" cx={centerX} cy={centerY} key={`${q}-${r}-node`} r="1.25" />);
    }
  }
  return <g className="editor-grid hexagonal-grid">{cells}</g>;
}

function range(minimum: number, maximum: number, spacing: number): readonly number[] {
  const start = Math.floor(minimum / spacing) * spacing;
  const values: number[] = [];
  for (let value = start; value <= maximum; value += spacing) values.push(value);
  return values;
}
