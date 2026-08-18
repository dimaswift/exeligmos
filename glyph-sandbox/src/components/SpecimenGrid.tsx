import { useMemo } from "react";

import { glyphColor } from "../glyph-colors";
import {
  digitToBits,
  findGlyphCollisions,
  formatDigit,
  radixForBitWidth,
} from "../glyph-engine";
import type { ColorMode, FreeformStroke, Point, StrokePreset, StrokeSegment, TracedStroke } from "../types";
import { ArmDrawing } from "./ArmDrawing";

interface SpecimenGridProps {
  readonly bitWidth: number;
  readonly points: readonly Point[];
  readonly corePoint: Point;
  readonly bottomBit: number;
  readonly colorMode: ColorMode;
  readonly rounded: boolean;
  readonly segments: readonly StrokeSegment[];
  readonly strokePreset: StrokePreset;
  readonly tracedStrokes: readonly TracedStroke[];
  readonly freeformStrokes: readonly FreeformStroke[];
  readonly inkColor: string;
  readonly paletteColors: readonly string[];
  readonly selectedDigit: number;
  readonly showDisconnectedBitDots: boolean;
  readonly strokeWidth: number;
  readonly onSelect: (digit: number) => void;
}

export function SpecimenGrid({
  bitWidth,
  points,
  corePoint,
  bottomBit,
  colorMode,
  rounded,
  segments,
  strokePreset,
  tracedStrokes,
  freeformStrokes,
  inkColor,
  paletteColors,
  selectedDigit,
  showDisconnectedBitDots,
  strokeWidth,
  onSelect,
}: SpecimenGridProps) {
  const radix = radixForBitWidth(bitWidth);
  const visibleCount = Math.min(radix, 32);
  const collisionGroups = useMemo(
    () => findGlyphCollisions(bitWidth, segments, freeformStrokes, tracedStrokes, {
      strokePreset,
      bottomBit,
    }),
    [bitWidth, bottomBit, freeformStrokes, segments, strokePreset, tracedStrokes],
  );
  const collidingDigits = new Set(collisionGroups.flat());
  const distinctForms = radix - collisionGroups.reduce((count, group) => count + group.length - 1, 0);

  return (
    <>
      <div className={`collision-report ${collisionGroups.length === 0 ? "clean" : "warning"}`}>
        <strong>{distinctForms}/{radix} distinct forms</strong>
        <span>
          {collisionGroups.length === 0
            ? "No collisions in this stroke graph."
            : `${collisionGroups.length} collision ${collisionGroups.length === 1 ? "group" : "groups"} found.`}
        </span>
      </div>
      <div className="specimen-grid">
        {Array.from({ length: visibleCount }, (_, digit) => {
          const bits = digitToBits(digit, bitWidth);
          return (
            <button
              key={digit}
              aria-pressed={selectedDigit === digit}
              className={`specimen ${collidingDigits.has(digit) ? "has-collision" : ""}`}
              onClick={() => onSelect(digit)}
              type="button"
            >
              <div className="specimen-meta">
                <strong>{formatDigit(digit, bitWidth)}</strong>
                <span>
                  {collidingDigits.has(digit) ? <em title="This form collides with another digit">!</em> : null}
                  {bits.map((bit) => (bit ? "1" : "0")).join("")}
                </span>
              </div>
              <svg aria-hidden="true" viewBox="-116 -168 232 190">
                <ArmDrawing
                  bitWidth={bitWidth}
                  bottomBit={bottomBit}
                  corePoint={corePoint}
                  digit={digit}
                  freeformStrokes={freeformStrokes}
                  points={points}
                  rounded={rounded}
                  segments={segments}
                  strokePreset={strokePreset}
                  tracedStrokes={tracedStrokes}
                  showDisconnectedBitDots={showDisconnectedBitDots}
                  stroke={glyphColor({ colorMode, inkColor, paletteColors }, 0, digit)}
                  strokeWidth={Math.max(4, strokeWidth * 0.68)}
                />
              </svg>
            </button>
          );
        })}
      </div>
      {radix > visibleCount ? (
        <p className="grid-note">
          Showing the first {visibleCount} of {radix} values. Enter any higher value in the address
          field to render it.
        </p>
      ) : null}
    </>
  );
}
