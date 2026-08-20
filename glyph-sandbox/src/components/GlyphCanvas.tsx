import { forwardRef } from "react";

import { glyphColor, readableTextColor } from "../glyph-colors";
import { composeArmInstances, digitToBits } from "../glyph-engine";
import type { SandboxConfig } from "../types";
import { ArmDrawing } from "./ArmDrawing";

interface GlyphCanvasProps {
  readonly config: SandboxConfig;
  readonly digits: readonly number[];
  readonly className?: string;
  readonly title?: string;
}

export const GlyphCanvas = forwardRef<SVGSVGElement, GlyphCanvasProps>(function GlyphCanvas(
  { config, digits, className, title = "Generated multi-digit glyph" },
  ref,
) {
  const arms = composeArmInstances({
    digits,
    layout: config.assemblyLayout,
    direction: config.readingDirection,
    startAngle: config.startAngle,
    fanSpread: config.fanSpread,
    lineSpacing: config.lineSpacing,
  });
  const coreRadius = config.assemblyLayout === "linear" ? 0 : 48;
  const viewBox = config.assemblyLayout === "linear" ? "-300 -210 600 390" : "-300 -300 600 600";

  return (
    <svg
      ref={ref}
      aria-label={title}
      className={className}
      role="img"
      viewBox={viewBox}
      xmlns="http://www.w3.org/2000/svg"
    >
      <title>{title}</title>
      <g color={readableTextColor(config.canvasColor)}>
        {arms.map((arm) => {
          const stroke = glyphColor(config, arm.sourceIndex, arm.digit);
          const rootOffset = config.assemblyLayout === "linear"
            ? 0
            : config.assemblyLayout === "radial"
              ? -config.radialRadius
              : -coreRadius;
          return (
            <g
              key={`${arm.sourceIndex}-${arm.digit}`}
              data-digit={arm.digit}
              data-source-index={arm.sourceIndex}
              transform={`translate(${arm.x} ${arm.y}) rotate(${arm.rotation})`}
            >
              <g transform={`translate(0 ${rootOffset}) scale(${arm.scale})`}>
                <ArmDrawing
                  bitWidth={config.bitWidth}
                  bottomBit={config.bottomBit}
                  corePoint={config.corePoint}
                  digit={arm.digit}
                  freeformStrokes={config.freeformStrokes}
                  points={config.points}
                  rounded={config.rounded}
                  segments={config.segments}
                  strokePreset={config.strokePreset}
                  tracedStrokes={config.tracedStrokes}
                  showGuides={config.showGuides}
                  showDisconnectedBitDots={config.showDisconnectedBitDots}
                  stroke={stroke}
                  strokeWidth={config.strokeWidth}
                />
              </g>
            </g>
          );
        })}
      </g>
      {config.assemblyLayout === "linear" || config.coreStyle === "none" ? null : (
        <Core
          backgroundColor={config.canvasColor}
          color={glyphColor(config, 0, digits[0] ?? 0)}
          count={digits.length}
          radius={coreRadius}
          style={config.coreStyle}
          strokeWidth={config.strokeWidth}
        />
      )}
    </svg>
  );
});

interface CoreProps {
  readonly style: SandboxConfig["coreStyle"];
  readonly radius: number;
  readonly count: number;
  readonly color: string;
  readonly backgroundColor: string;
  readonly strokeWidth: number;
}

function Core({ style, radius, count, color, backgroundColor, strokeWidth }: CoreProps) {
  if (style === "dot") {
    return <circle cx="0" cy="0" fill={color} r={Math.max(8, strokeWidth * 1.2)} />;
  }
  if (style === "polygon") {
    const sides = Math.max(3, Math.min(12, count));
    const points = Array.from({ length: sides }, (_, index) => {
      const angle = -Math.PI / 2 + (index * Math.PI * 2) / sides;
      return `${Math.cos(angle) * (radius - 4)},${Math.sin(angle) * (radius - 4)}`;
    }).join(" ");
    return (
      <polygon
        fill={backgroundColor}
        points={points}
        stroke={color}
        strokeLinejoin="round"
        strokeWidth={strokeWidth}
      />
    );
  }
  return (
    <circle
      cx="0"
      cy="0"
      fill={backgroundColor}
      r={radius - 7}
      stroke={color}
      strokeWidth={strokeWidth}
    />
  );
}

export function bitSignature(digit: number, bitWidth: number): string {
  return digitToBits(digit, bitWidth)
    .map((bit) => (bit ? "1" : "0"))
    .join("");
}
