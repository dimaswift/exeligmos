import { forwardRef } from "react";

import { DEFAULT_CORE_POINT, makeLayout, makeStrokeSegments } from "../glyph-engine";
import type { CompositeAnalysis } from "../poly-radix/types";
import type { SandboxConfig } from "../types";
import { ArmDrawing } from "./ArmDrawing";

export interface PolyGlyphDebugOptions {
  readonly scaffold: boolean;
  readonly bitIndexes: boolean;
  readonly radixLabels: boolean;
  readonly residueValues: boolean;
  readonly orientation: boolean;
  readonly boundingGeometry: boolean;
}

export type PolyGlyphSelection =
  | { readonly kind: "core" }
  | { readonly kind: "bit"; readonly bitIndex: number }
  | { readonly kind: "radix"; readonly radix: number };

interface PolyRadixGlyphProps {
  readonly analysis: CompositeAnalysis;
  readonly armConfig: SandboxConfig;
  readonly debug: PolyGlyphDebugOptions;
  readonly wrappedRadices: readonly number[];
  readonly onSelect: (selection: PolyGlyphSelection) => void;
}

const MAIN_ROOT_Y = 64;
const MAIN_SCALE = 0.64;
const HUB_RADIUS = 104;
const ARM_ROOT_RADIUS = 154;
const LABEL_RADIUS = 286;

export const PolyRadixGlyph = forwardRef<SVGSVGElement, PolyRadixGlyphProps>(function PolyRadixGlyph(
  { analysis, armConfig, debug, wrappedRadices, onSelect },
  ref,
) {
  const ink = armConfig.inkColor;
  const mainGrammar = foundryGrammar(armConfig, 16);

  return (
    <svg
      ref={ref}
      aria-label={`Unified Foundry glyph for 16-bit state ${analysis.binary.fixedWord}`}
      className="poly-glyph"
      role="img"
      viewBox="-360 -320 720 640"
      xmlns="http://www.w3.org/2000/svg"
    >
      <title>Unified Foundry glyph for bases {analysis.radices.map(({ radix }) => radix).join(", ")}</title>

      {debug.scaffold ? (
        <g className="poly-scaffold" data-debug-layer="scaffold">
          <circle cx="0" cy="0" fill="none" r={HUB_RADIUS} />
          <circle cx="0" cy="0" fill="none" r={ARM_ROOT_RADIUS} />
          <circle cx="0" cy="0" fill="none" r={LABEL_RADIUS} />
          {analysis.radices.map((radix, index) => {
            const placement = radialPlacement(index, analysis.radices.length);
            return <line key={radix.radix} x1="0" x2={placement.labelX} y1="0" y2={placement.labelY} />;
          })}
        </g>
      ) : null}
      {debug.boundingGeometry ? (
        <rect className="poly-bounds" data-debug-layer="bounds" fill="none" height="600" width="680" x="-340" y="-300" />
      ) : null}

      <g
        className="poly-unified-skeleton"
        data-layer="unified-skeleton"
        stroke={ink}
        strokeLinecap={armConfig.rounded ? "round" : "square"}
        strokeLinejoin={armConfig.rounded ? "round" : "miter"}
        strokeWidth={armConfig.strokeWidth}
      >
        <circle cx="0" cy="0" fill="none" r={HUB_RADIUS} />
        {analysis.radices.map((radix, index) => {
          const placement = radialPlacement(index, analysis.radices.length);
          return (
            <line
              data-radix-connector={radix.radix}
              key={radix.radix}
              x1={Math.cos(placement.angleRadians) * HUB_RADIUS}
              x2={placement.x}
              y1={Math.sin(placement.angleRadians) * HUB_RADIUS}
              y2={placement.y}
            />
          );
        })}
      </g>

      <g
        aria-label={`Main 16-bit Foundry glyph, value ${analysis.value}`}
        className="poly-main-foundry-glyph"
        data-bit-width="16"
        data-state={analysis.binary.fixedWord}
        data-value={analysis.value}
        onClick={() => onSelect({ kind: "core" })}
        role="button"
        tabIndex={0}
        transform={`translate(0 ${MAIN_ROOT_Y}) scale(${MAIN_SCALE})`}
      >
        <ArmDrawing
          bitWidth={16}
          bottomBit={mainGrammar.bottomBit}
          corePoint={mainGrammar.corePoint}
          digit={analysis.value}
          freeformStrokes={mainGrammar.freeformStrokes}
          points={mainGrammar.points}
          rounded={armConfig.rounded}
          segments={mainGrammar.segments}
          showDisconnectedBitDots={armConfig.showDisconnectedBitDots}
          showGuides={debug.scaffold}
          stroke={ink}
          strokePreset={mainGrammar.strokePreset}
          strokeWidth={armConfig.strokeWidth}
          tracedStrokes={mainGrammar.tracedStrokes}
        />
        {mainGrammar.points.map((point, pointIndex) => {
          const bitIndex = 15 - pointIndex;
          const state = analysis.binary.fixedBits[bitIndex] ?? 0;
          return (
            <g key={pointIndex}>
              <circle
                aria-label={`Bit ${bitIndex}, weight ${2 ** bitIndex}, ${state === 1 ? "active" : "inactive"}`}
                className="poly-main-bit-hit"
                cx={point.x}
                cy={point.y}
                data-bit-index={bitIndex}
                data-state={state}
                onClick={(event) => {
                  event.stopPropagation();
                  onSelect({ kind: "bit", bitIndex });
                }}
                r="13"
                role="button"
                tabIndex={0}
              />
              {debug.bitIndexes ? (
                <text className="poly-bit-index" data-debug-layer="bit-index" textAnchor="middle" x={point.x} y={point.y - 15}>
                  {bitIndex}
                </text>
              ) : null}
            </g>
          );
        })}
      </g>

      {analysis.radices.map((radixAnalysis, index) => {
        const placement = radialPlacement(index, analysis.radices.length);
        const bitWidth = Math.max(2, Math.ceil(Math.log2(radixAnalysis.radix)));
        const grammar = foundryGrammar(armConfig, bitWidth);
        const scale = bitWidth >= 6 ? 0.52 : bitWidth === 5 ? 0.56 : 0.61;
        const wrapped = wrappedRadices.includes(radixAnalysis.radix);
        return (
          <g
            aria-label={`Base ${radixAnalysis.radix} Foundry glyph, residue ${radixAnalysis.residue}`}
            className={`poly-arm poly-foundry-radix-glyph ${wrapped ? "is-wrapping" : ""}`}
            data-bit-width={bitWidth}
            data-digit={radixAnalysis.residue}
            data-order={index}
            data-radix={radixAnalysis.radix}
            data-state={wrapped ? "wrapped" : "steady"}
            key={radixAnalysis.radix}
            onClick={() => onSelect({ kind: "radix", radix: radixAnalysis.radix })}
            role="button"
            tabIndex={0}
            transform={`translate(${placement.x} ${placement.y}) rotate(${placement.rotation})`}
          >
            <g color={ink} transform={`scale(${scale})`}>
              <ArmDrawing
                bitWidth={bitWidth}
                bottomBit={grammar.bottomBit}
                corePoint={grammar.corePoint}
                digit={radixAnalysis.residue}
                freeformStrokes={grammar.freeformStrokes}
                points={grammar.points}
                rounded={armConfig.rounded}
                segments={grammar.segments}
                showDisconnectedBitDots={armConfig.showDisconnectedBitDots}
                showGuides={debug.scaffold}
                stroke={ink}
                strokePreset={grammar.strokePreset}
                strokeWidth={armConfig.strokeWidth}
                tracedStrokes={grammar.tracedStrokes}
              />
            </g>
          </g>
        );
      })}

      <path
        className="poly-orientation-notch"
        d={`M -5 ${-HUB_RADIUS - 7} L 0 ${-HUB_RADIUS - 18} L 5 ${-HUB_RADIUS - 7}`}
        stroke={ink}
      />
      {debug.orientation ? (
        <text className="poly-debug-label" data-debug-layer="orientation" fill={ink} textAnchor="middle" x="0" y={-HUB_RADIUS - 24}>
          CLOCKWISE FROM TOP
        </text>
      ) : null}

      {analysis.radices.map((radixAnalysis, index) => {
        if (!debug.radixLabels && !debug.residueValues) return null;
        const placement = radialPlacement(index, analysis.radices.length);
        return (
          <text
            className="poly-arm-label"
            data-radix-label={radixAnalysis.radix}
            fill={ink}
            key={`label-${radixAnalysis.radix}`}
            textAnchor={placement.anchor}
            x={placement.labelX}
            y={placement.labelY + 3}
          >
            {debug.radixLabels ? `B${radixAnalysis.radix}` : ""}
            {debug.radixLabels && debug.residueValues ? " · " : ""}
            {debug.residueValues ? radixAnalysis.residue : ""}
          </text>
        );
      })}
    </svg>
  );
});

function foundryGrammar(config: SandboxConfig, bitWidth: number) {
  const matchesFoundry = config.bitWidth === bitWidth;
  const layoutPreset = config.layoutPreset === "custom" ? "orbit" : config.layoutPreset;
  const strokePreset = config.strokePreset === "custom" ? "weave" : config.strokePreset;
  return {
    points: matchesFoundry ? config.points : makeLayout(layoutPreset, bitWidth),
    corePoint: matchesFoundry ? config.corePoint : DEFAULT_CORE_POINT,
    bottomBit: matchesFoundry ? Math.min(bitWidth - 1, config.bottomBit) : bitWidth - 1,
    strokePreset: matchesFoundry ? config.strokePreset : strokePreset,
    segments: matchesFoundry ? config.segments : makeStrokeSegments(strokePreset, bitWidth),
    tracedStrokes: matchesFoundry ? config.tracedStrokes : [],
    freeformStrokes: matchesFoundry ? config.freeformStrokes : [],
  } as const;
}

function radialPlacement(index: number, count: number) {
  const angleRadians = -Math.PI / 2 + index * Math.PI * 2 / count;
  const angleDegrees = angleRadians * 180 / Math.PI;
  const labelX = Math.cos(angleRadians) * LABEL_RADIUS;
  const labelY = Math.sin(angleRadians) * LABEL_RADIUS;
  return {
    angleRadians,
    x: Math.cos(angleRadians) * ARM_ROOT_RADIUS,
    y: Math.sin(angleRadians) * ARM_ROOT_RADIUS,
    rotation: angleDegrees + 90,
    labelX,
    labelY,
    anchor: Math.abs(labelX) < 18 ? "middle" : labelX > 0 ? "start" : "end",
  } as const;
}
