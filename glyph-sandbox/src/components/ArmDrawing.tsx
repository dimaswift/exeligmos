import {
  bezierStrokePathData,
  disconnectedBitIndices,
  digitToBits,
  freeformStrokeIsVisible,
  resolveStrokeSegments,
  segmentIsVisible,
  segmentPathData,
  tracedStrokeIsVisible,
} from "../glyph-engine";
import type { FreeformStroke, Point, StrokePreset, StrokeSegment, TracedStroke } from "../types";

interface ArmDrawingProps {
  readonly digit: number;
  readonly bitWidth: number;
  readonly points: readonly Point[];
  readonly corePoint: Point;
  readonly bottomBit: number;
  readonly strokePreset: StrokePreset;
  readonly segments: readonly StrokeSegment[];
  readonly tracedStrokes?: readonly TracedStroke[];
  readonly freeformStrokes?: readonly FreeformStroke[];
  readonly stroke: string;
  readonly strokeWidth: number;
  readonly rounded: boolean;
  readonly showGuides?: boolean;
  readonly mutedGuides?: boolean;
  readonly showDisconnectedBitDots?: boolean;
}

export function ArmDrawing({
  digit,
  bitWidth,
  points,
  corePoint,
  bottomBit,
  strokePreset,
  segments,
  tracedStrokes = [],
  freeformStrokes = [],
  stroke,
  strokeWidth,
  rounded,
  showGuides = false,
  mutedGuides = false,
  showDisconnectedBitDots = false,
}: ArmDrawingProps) {
  const bits = digitToBits(digit, bitWidth);
  const resolvedSegments = resolveStrokeSegments(strokePreset, segments, bitWidth, digit, bottomBit);
  const linecap = rounded ? "round" : "square";
  const linejoin = rounded ? "round" : "miter";
  const disconnectedBits = showDisconnectedBitDots
    ? disconnectedBitIndices(bits, resolvedSegments, tracedStrokes, digit)
    : [];

  return (
    <>
      {showGuides
        ? resolvedSegments.map((segment) => (
              <path
                key={`guide-${segment.id}`}
                d={segmentPathData(segment, points, 24, corePoint)}
                fill="none"
                stroke="currentColor"
                strokeDasharray="3 7"
                strokeOpacity={mutedGuides ? 0.1 : 0.18}
                strokeWidth={Math.max(1, strokeWidth * 0.35)}
              />
            ))
        : null}
      {resolvedSegments.map((segment) => {
        if (!segmentIsVisible(segment, bits)) return null;
        return (
          <path
            key={segment.id}
            d={segmentPathData(segment, points, 24, corePoint)}
            fill="none"
            stroke={stroke}
            strokeLinecap={linecap}
            strokeLinejoin={linejoin}
            strokeWidth={strokeWidth}
            vectorEffect="non-scaling-stroke"
          />
        );
      })}
      {showGuides
        ? tracedStrokes
          .filter((tracedStroke) => tracedStrokeIsVisible(tracedStroke, digit))
          .map((tracedStroke) => (
            <path
              d={segmentPathData(tracedStroke, points, 24, corePoint)}
              fill="none"
              key={`traced-guide-${tracedStroke.id}`}
              stroke="currentColor"
              strokeDasharray="3 7"
              strokeOpacity={mutedGuides ? 0.1 : 0.18}
              strokeWidth={Math.max(1, strokeWidth * 0.35)}
            />
          ))
        : null}
      {tracedStrokes.map((tracedStroke) => {
        if (!tracedStrokeIsVisible(tracedStroke, digit)) return null;
        return (
          <path
            data-traced-stroke={tracedStroke.id}
            d={segmentPathData(tracedStroke, points, 24, corePoint)}
            fill="none"
            key={tracedStroke.id}
            stroke={stroke}
            strokeLinecap={linecap}
            strokeLinejoin={linejoin}
            strokeWidth={strokeWidth}
            vectorEffect="non-scaling-stroke"
          />
        );
      })}
      {showGuides
        ? freeformStrokes
          .filter((freeformStroke) => freeformStrokeIsVisible(freeformStroke, digit))
          .map((freeformStroke) => (
            <path
              d={bezierStrokePathData(freeformStroke)}
              fill="none"
              key={`freeform-guide-${freeformStroke.id}`}
              stroke="currentColor"
              strokeDasharray="3 7"
              strokeOpacity={mutedGuides ? 0.1 : 0.18}
              strokeWidth={Math.max(1, strokeWidth * 0.35)}
            />
          ))
        : null}
      {freeformStrokes.map((freeformStroke) => {
        if (!freeformStrokeIsVisible(freeformStroke, digit)) return null;
        return (
          <path
            data-freeform-stroke={freeformStroke.id}
            d={bezierStrokePathData(freeformStroke)}
            fill="none"
            key={freeformStroke.id}
            stroke={stroke}
            strokeLinecap={linecap}
            strokeLinejoin={linejoin}
            strokeWidth={strokeWidth}
            vectorEffect="non-scaling-stroke"
          />
        );
      })}
      {disconnectedBits.map((index) => {
        const point = points[index];
        if (point === undefined) return null;
        return (
          <path
            data-disconnected-bit={index}
            d={`M ${point.x} ${point.y} h 0.001`}
            fill="none"
            key={`disconnected-bit-${index}`}
            stroke={stroke}
            strokeLinecap="round"
            strokeWidth={strokeWidth * 2}
            vectorEffect="non-scaling-stroke"
          />
        );
      })}
      {showGuides ? (
        <>
          {points.map((point, index) => (
            <circle
              key={`point-${index}`}
              cx={point.x}
              cy={point.y}
              fill={bits[index] ? stroke : "#17201c"}
              r={Math.max(3.6, strokeWidth * 0.62)}
              stroke={bits[index] ? "#17201c" : "currentColor"}
              strokeOpacity={bits[index] ? 1 : 0.46}
              strokeWidth={1.4}
              vectorEffect="non-scaling-stroke"
            />
          ))}
          <circle
            cx={corePoint.x}
            cy={corePoint.y}
            fill="#17201c"
            r={Math.max(3.6, strokeWidth * 0.62)}
            stroke={stroke}
            strokeWidth={1.8}
            vectorEffect="non-scaling-stroke"
          />
          <circle
            cx="0"
            cy="0"
            fill={stroke}
            r={Math.max(3.2, strokeWidth * 0.52)}
            stroke="#17201c"
            strokeWidth={1.2}
            vectorEffect="non-scaling-stroke"
          />
        </>
      ) : null}
    </>
  );
}
