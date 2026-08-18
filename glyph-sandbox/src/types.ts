export interface Point {
  readonly x: number;
  readonly y: number;
}

export type LayoutPreset = "line" | "square" | "triangle" | "diamond" | "orbit" | "custom";
export type StrokePreset = "rays" | "trace" | "weave" | "circuit" | "core-shell" | "custom";
export type StrokeCondition = "target" | "source" | "both" | "either" | "always";
export type SegmentCurve = "line" | "hyperbolic";
export type GridType = "square" | "triangular" | "hexagonal";
export type Endpoint = "root" | "core" | number;
export type AssemblyLayout = "radial" | "fan" | "stack" | "linear";
export type ReadingDirection = "clockwise" | "counterclockwise";
export type InputDirection = "msb-first" | "lsb-first";
export type CoreStyle = "ring" | "polygon" | "dot" | "none";
export type ColorMode = "single" | "position" | "digit";

export interface StrokeSegment {
  readonly id: string;
  readonly from: Endpoint;
  readonly to: Endpoint;
  readonly condition: StrokeCondition;
  readonly curve: SegmentCurve;
  readonly bend: number;
}

export interface TracedStroke {
  readonly id: string;
  readonly digit: number;
  readonly from: Endpoint;
  readonly to: Endpoint;
  readonly curve: SegmentCurve;
  readonly bend: number;
}

export interface BezierSegment {
  readonly start: Point;
  readonly control1: Point;
  readonly control2: Point;
  readonly end: Point;
}

export interface FreeformStroke {
  readonly id: string;
  readonly digit: number;
  readonly segments: readonly BezierSegment[];
}

export interface SandboxConfig {
  readonly version: 8;
  readonly bitWidth: number;
  readonly layoutPreset: LayoutPreset;
  readonly points: readonly Point[];
  readonly corePoint: Point;
  readonly bottomBit: number;
  readonly vertexGrid: GridType;
  readonly snapToGrid: boolean;
  readonly gridSpacing: number;
  readonly strokePreset: StrokePreset;
  readonly segments: readonly StrokeSegment[];
  readonly tracedStrokes: readonly TracedStroke[];
  readonly freeformStrokes: readonly FreeformStroke[];
  readonly address: string;
  readonly digitCount: number;
  readonly inputDirection: InputDirection;
  readonly assemblyLayout: AssemblyLayout;
  readonly readingDirection: ReadingDirection;
  readonly startAngle: number;
  readonly fanSpread: number;
  readonly lineSpacing: number;
  readonly coreStyle: CoreStyle;
  readonly strokeWidth: number;
  readonly rounded: boolean;
  readonly colorMode: ColorMode;
  readonly inkColor: string;
  readonly canvasColor: string;
  readonly paletteColors: readonly string[];
  readonly showGuides: boolean;
  readonly showDisconnectedBitDots: boolean;
}

export interface ArmInstance {
  readonly digit: number;
  readonly sourceIndex: number;
  readonly x: number;
  readonly y: number;
  readonly rotation: number;
  readonly scale: number;
}
