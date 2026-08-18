import type {
  ArmInstance,
  AssemblyLayout,
  BezierSegment,
  Endpoint,
  FreeformStroke,
  GridType,
  InputDirection,
  LayoutPreset,
  Point,
  ReadingDirection,
  StrokeCondition,
  StrokePreset,
  StrokeSegment,
  TracedStroke,
} from "./types";

export const MIN_BIT_WIDTH = 2;
export const MAX_BIT_WIDTH = 16;
export const DIGIT_ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";
export const MIN_GRID_SPACING = 6;
export const MAX_GRID_SPACING = 40;
export const DEFAULT_CORE_POINT: Point = Object.freeze({ x: 0, y: -100 });

export function clampBitWidth(value: unknown): number {
  const parsed = typeof value === "number" ? value : Number(value);
  if (!Number.isFinite(parsed)) return 4;
  return Math.min(MAX_BIT_WIDTH, Math.max(MIN_BIT_WIDTH, Math.round(parsed)));
}

export function radixForBitWidth(bitWidth: number): number {
  return 2 ** clampBitWidth(bitWidth);
}

export function formatDigit(value: number, bitWidth: number): string {
  const radix = radixForBitWidth(bitWidth);
  const normalized = Math.min(radix - 1, Math.max(0, Math.trunc(value)));
  return radix <= DIGIT_ALPHABET.length ? (DIGIT_ALPHABET[normalized] ?? "0") : String(normalized);
}

export function digitToBits(value: number, bitWidth: number): readonly boolean[] {
  const width = clampBitWidth(bitWidth);
  const max = 2 ** width - 1;
  const safeValue = Math.min(max, Math.max(0, Math.trunc(value)));
  return Object.freeze(
    Array.from({ length: width }, (_, index) => (safeValue & 2 ** (width - index - 1)) !== 0),
  );
}

export function bitsToDigit(bits: readonly boolean[]): number {
  return bits.reduce((value, bit) => value * 2 + (bit ? 1 : 0), 0);
}

export function parseDigitInput(input: string, bitWidth: number): readonly number[] {
  const radix = radixForBitWidth(bitWidth);
  if (radix <= DIGIT_ALPHABET.length) {
    return Object.freeze(
      [...input.toUpperCase()]
        .map((character) => DIGIT_ALPHABET.indexOf(character))
        .filter((value) => value >= 0 && value < radix),
    );
  }
  return Object.freeze(
    input
      .trim()
      .split(/[^0-9]+/u)
      .filter(Boolean)
      .map(Number)
      .filter((value) => Number.isInteger(value) && value >= 0 && value < radix),
  );
}

export function normalizeDigits(
  input: string,
  bitWidth: number,
  digitCount: number,
  inputDirection: InputDirection,
): readonly number[] {
  const count = Math.min(12, Math.max(1, Math.trunc(digitCount)));
  const parsed = [...parseDigitInput(input, bitWidth)];
  const padded = [...Array(Math.max(0, count - parsed.length)).fill(0), ...parsed.slice(-count)];
  return Object.freeze(inputDirection === "lsb-first" ? padded.reverse() : padded);
}

export function formatAddress(digits: readonly number[], bitWidth: number): string {
  const radix = radixForBitWidth(bitWidth);
  const separator = radix > DIGIT_ALPHABET.length ? " " : "";
  return digits.map((digit) => formatDigit(digit, bitWidth)).join(separator);
}

export function makeLayout(preset: Exclude<LayoutPreset, "custom">, bitWidth: number): readonly Point[] {
  const count = clampBitWidth(bitWidth);
  switch (preset) {
    case "line":
      return freezePoints(
        Array.from({ length: count }, (_, index) => ({
          x: positionInSpan(index, count, 118),
          y: -112,
        })),
      );
    case "square": {
      const columns = Math.ceil(Math.sqrt(count));
      const rows = Math.ceil(count / columns);
      return freezePoints(
        Array.from({ length: count }, (_, index) => ({
          x: positionInSpan(index % columns, columns, 112),
          y: -62 - normalizedIndex(Math.floor(index / columns), rows) * 74,
        })),
      );
    }
    case "triangle":
      if (count === 4) {
        return freezePoints([
          { x: 0, y: -146 },
          { x: -62, y: -62 },
          { x: 0, y: -90 },
          { x: 62, y: -62 },
        ]);
      }
      return freezePoints(pointsOnPolygon(count, 3, { x: 0, y: -92 }, 68, -90));
    case "diamond":
      return freezePoints(pointsOnPolygon(count, 4, { x: 0, y: -92 }, 66, -90));
    case "orbit":
      return freezePoints(pointsOnPolygon(count, count, { x: 0, y: -94 }, 66, -90));
  }
}

export function makeStrokeSegments(
  preset: Exclude<StrokePreset, "custom">,
  bitWidth: number,
): readonly StrokeSegment[] {
  const count = clampBitWidth(bitWidth);
  const segments: StrokeSegment[] = [];
  const add = (from: Endpoint, to: Endpoint, condition: StrokeCondition) => {
    segments.push({
      id: `${preset}-${segments.length}`,
      from,
      to,
      condition,
      curve: "line",
      bend: 0,
    });
  };

  switch (preset) {
    case "rays":
      for (let index = 0; index < count; index += 1) add("root", index, "target");
      break;
    case "trace":
      add("root", 0, "target");
      for (let index = 1; index < count; index += 1) add(index - 1, index, "target");
      break;
    case "weave":
      for (let index = 0; index < count; index += 1) add("root", index, "target");
      for (let index = 1; index < count; index += 1) add(index - 1, index, "both");
      if (count > 2) add(count - 1, 0, "both");
      break;
    case "circuit":
      add("root", 0, "target");
      for (let index = 1; index < count; index += 1) {
        add(index - 1, index, "either");
      }
      add(count - 1, "root", "source");
      break;
    case "core-shell":
      break;
  }
  return Object.freeze(segments.map((segment) => Object.freeze(segment)));
}

/** Builds the active LSB chains, cyclic inactive shell, and permanent root stem for one digit. */
export function makeCoreShellSegments(
  bitWidth: number,
  digit: number,
  bottomBit: number,
): readonly StrokeSegment[] {
  const width = clampBitWidth(bitWidth);
  const bits = digitToBits(digit, width);
  const lsbFirst = Array.from({ length: width }, (_, index) => width - index - 1);
  const active = lsbFirst.filter((index) => bits[index] ?? false);
  const segments: StrokeSegment[] = [];
  const add = (id: string, from: Endpoint, to: Endpoint) => {
    segments.push({ id, from, to, condition: "always", curve: "line", bend: 0 });
  };

  active.forEach((bit, index) => {
    const previous = active[index - 1];
    add(
      `core-shell-active-${bit}`,
      previous !== undefined && previous - bit === 1 ? previous : "core",
      bit,
    );
  });

  // The shell is the bit-position cycle, not a chain of the filtered inactive
  // vertices. Process each position exactly once, beginning at the most
  // significant inactive bit. Index 0 is the MSB, so stepping below it wraps
  // to the LSB. An active endpoint suppresses that edge instead of allowing a
  // jump across the gap.
  const mostSignificantInactive = bits.findIndex((bit) => !bit);
  if (mostSignificantInactive >= 0) {
    for (let offset = 0; offset < width; offset += 1) {
      const from = (mostSignificantInactive - offset + width) % width;
      const to = (from - 1 + width) % width;
      if (!(bits[from] ?? false) && !(bits[to] ?? false)) {
        add(`core-shell-inactive-${from}-${to}`, from, to);
      }
    }
  }

  const safeBottomBit = Math.min(width - 1, Math.max(0, Math.trunc(bottomBit)));
  add(`core-shell-root-${safeBottomBit}`, "root", safeBottomBit);
  return Object.freeze(segments.map((segment) => Object.freeze(segment)));
}

export function resolveStrokeSegments(
  preset: StrokePreset,
  segments: readonly StrokeSegment[],
  bitWidth: number,
  digit: number,
  bottomBit: number,
): readonly StrokeSegment[] {
  return preset === "core-shell"
    ? makeCoreShellSegments(bitWidth, digit, bottomBit)
    : segments;
}

export function endpointIsActive(endpoint: Endpoint, bits: readonly boolean[]): boolean {
  return endpoint === "root" || endpoint === "core" ? true : (bits[endpoint] ?? false);
}

export function segmentIsVisible(segment: StrokeSegment, bits: readonly boolean[]): boolean {
  const source = endpointIsActive(segment.from, bits);
  const target = endpointIsActive(segment.to, bits);
  switch (segment.condition) {
    case "target":
      return target;
    case "source":
      return source;
    case "both":
      return source && target;
    case "either":
      return source || target;
    case "always":
      return true;
  }
}

/** Returns bit vertices untouched by any visible generated or manual Trace segment. */
export function disconnectedBitIndices(
  bits: readonly boolean[],
  segments: readonly StrokeSegment[],
  tracedStrokes: readonly TracedStroke[],
  digit: number,
): readonly number[] {
  const connected = new Set<number>();
  const connectEndpoint = (endpoint: Endpoint) => {
    if (typeof endpoint === "number" && endpoint >= 0 && endpoint < bits.length) {
      connected.add(endpoint);
    }
  };

  segments.forEach((segment) => {
    if (!segmentIsVisible(segment, bits)) return;
    connectEndpoint(segment.from);
    connectEndpoint(segment.to);
  });
  tracedStrokes.forEach((stroke) => {
    if (!tracedStrokeIsVisible(stroke, digit)) return;
    connectEndpoint(stroke.from);
    connectEndpoint(stroke.to);
  });

  return Object.freeze(bits.map((_, index) => index).filter((index) => !connected.has(index)));
}

export function findGlyphCollisions(
  bitWidth: number,
  segments: readonly StrokeSegment[],
  freeformStrokes: readonly FreeformStroke[] = [],
  tracedStrokes: readonly TracedStroke[] = [],
  dynamicRule: {
    readonly strokePreset?: StrokePreset;
    readonly bottomBit?: number;
  } = {},
): readonly (readonly number[])[] {
  const radix = radixForBitWidth(bitWidth);
  const signatures = new Map<string, number[]>();
  for (let digit = 0; digit < radix; digit += 1) {
    const bits = digitToBits(digit, bitWidth);
    const resolvedSegments = resolveStrokeSegments(
      dynamicRule.strokePreset ?? "custom",
      segments,
      bitWidth,
      digit,
      dynamicRule.bottomBit ?? bitWidth - 1,
    );
    const visibleGeometry = new Set([
      ...resolvedSegments
        .filter((segment) => segmentIsVisible(segment, bits))
        .map((segment) => `rule:${segmentGeometryKey(segment)}`),
      ...freeformStrokes
        .filter((stroke) => freeformStrokeIsVisible(stroke, digit))
        .map((stroke) => `freeform:${bezierStrokePathData(stroke)}`),
      ...tracedStrokes
        .filter((stroke) => tracedStrokeIsVisible(stroke, digit))
        .map((stroke) => `trace:${segmentGeometryKey(stroke)}`),
    ]);
    const signature = [...visibleGeometry].sort().join("|");
    const matches = signatures.get(signature) ?? [];
    matches.push(digit);
    signatures.set(signature, matches);
  }
  return Object.freeze(
    [...signatures.values()]
      .filter((digits) => digits.length > 1)
      .map((digits) => Object.freeze(digits)),
  );
}

export function pointForEndpoint(
  endpoint: Endpoint,
  points: readonly Point[],
  corePoint: Point = DEFAULT_CORE_POINT,
): Point {
  if (endpoint === "root") return { x: 0, y: 0 };
  if (endpoint === "core") return corePoint;
  return points[endpoint] ?? { x: 0, y: 0 };
}

export function clampGridSpacing(value: unknown): number {
  const parsed = typeof value === "number" ? value : Number(value);
  if (!Number.isFinite(parsed)) return 16;
  return Math.min(MAX_GRID_SPACING, Math.max(MIN_GRID_SPACING, Math.round(parsed)));
}

export function snapPointToGrid(point: Point, grid: GridType, spacing: number): Point {
  const step = clampGridSpacing(spacing);
  if (grid === "square") {
    return { x: Math.round(point.x / step) * step, y: Math.round(point.y / step) * step };
  }

  if (grid === "triangular") {
    const rowHeight = (step * Math.sqrt(3)) / 2;
    const approximateRow = Math.round(point.y / rowHeight);
    let nearest = { x: 0, y: 0 };
    let nearestDistance = Number.POSITIVE_INFINITY;
    for (let row = approximateRow - 1; row <= approximateRow + 1; row += 1) {
      const offset = Math.abs(row) % 2 === 1 ? step / 2 : 0;
      const approximateColumn = Math.round((point.x - offset) / step);
      for (let column = approximateColumn - 1; column <= approximateColumn + 1; column += 1) {
        const candidate = { x: column * step + offset, y: row * rowHeight };
        const distance = (point.x - candidate.x) ** 2 + (point.y - candidate.y) ** 2;
        if (distance < nearestDistance) {
          nearest = candidate;
          nearestDistance = distance;
        }
      }
    }
    return nearest;
  }

  const radius = step;
  const axialQ = ((Math.sqrt(3) / 3) * point.x - point.y / 3) / radius;
  const axialR = ((2 / 3) * point.y) / radius;
  const rounded = roundAxialCoordinates(axialQ, axialR);
  return {
    x: radius * Math.sqrt(3) * (rounded.q + rounded.r / 2),
    y: radius * 1.5 * rounded.r,
  };
}

export function snapPointsToGrid(
  points: readonly Point[],
  grid: GridType,
  spacing: number,
): readonly Point[] {
  return freezePoints(points.map((point) => snapPointToGrid(point, grid, spacing)));
}

export function segmentPathData(
  segment: StrokeSegment | TracedStroke,
  points: readonly Point[],
  samples = 24,
  corePoint: Point = DEFAULT_CORE_POINT,
): string {
  const from = pointForEndpoint(segment.from, points, corePoint);
  const to = pointForEndpoint(segment.to, points, corePoint);
  if (segment.curve === "line" || Math.abs(segment.bend) < 0.001) {
    return `M ${formatPathNumber(from.x)} ${formatPathNumber(from.y)} L ${formatPathNumber(to.x)} ${formatPathNumber(to.y)}`;
  }

  const dx = to.x - from.x;
  const dy = to.y - from.y;
  const length = Math.hypot(dx, dy);
  if (length < 0.001) return `M ${formatPathNumber(from.x)} ${formatPathNumber(from.y)}`;

  const normalX = -dy / length;
  const normalY = dx / length;
  const bend = Math.min(120, Math.max(-120, segment.bend));
  const curveFactor = 2.5;
  const denominator = Math.cosh(curveFactor) - 1;
  const sampleCount = Math.min(80, Math.max(4, Math.round(samples)));
  const path = Array.from({ length: sampleCount + 1 }, (_, index) => {
    const progress = index / sampleCount;
    const centered = progress * 2 - 1;
    const envelope =
      (Math.cosh(curveFactor) - Math.cosh(curveFactor * centered)) / denominator;
    const x = from.x + dx * progress + normalX * bend * envelope;
    const y = from.y + dy * progress + normalY * bend * envelope;
    return `${index === 0 ? "M" : "L"} ${formatPathNumber(x)} ${formatPathNumber(y)}`;
  });
  return path.join(" ");
}

export function freeformStrokeIsVisible(
  stroke: FreeformStroke,
  digit: number,
): boolean {
  return stroke.digit === digit;
}

export function tracedStrokeIsVisible(stroke: TracedStroke, digit: number): boolean {
  return stroke.digit === digit;
}

export function bezierSegmentsFromPolyline(
  input: readonly Point[],
  tolerance = 2.2,
): readonly BezierSegment[] {
  const finitePoints = input.filter(
    (point) => Number.isFinite(point.x) && Number.isFinite(point.y),
  );
  if (finitePoints.length < 2) return Object.freeze([]);
  const simplified = simplifyPolyline(finitePoints, Math.max(0.5, tolerance));
  const stride = Math.max(1, Math.ceil(simplified.length / 64));
  const points = stride === 1
    ? simplified
    : simplified.filter((_, index) => index % stride === 0 || index === simplified.length - 1);
  if (points.length < 2) return Object.freeze([]);

  const segments = Array.from({ length: points.length - 1 }, (_, index): BezierSegment => {
    const start = points[index] ?? points[0] ?? { x: 0, y: 0 };
    const end = points[index + 1] ?? start;
    const previous = points[index - 1] ?? start;
    const next = points[index + 2] ?? end;
    return Object.freeze({
      start: Object.freeze({ ...start }),
      control1: Object.freeze({
        x: start.x + (end.x - previous.x) / 6,
        y: start.y + (end.y - previous.y) / 6,
      }),
      control2: Object.freeze({
        x: end.x - (next.x - start.x) / 6,
        y: end.y - (next.y - start.y) / 6,
      }),
      end: Object.freeze({ ...end }),
    });
  });
  return Object.freeze(segments);
}

export function bezierSegmentsPathData(segments: readonly BezierSegment[]): string {
  const first = segments[0];
  if (first === undefined) return "";
  return [
    `M ${formatPathNumber(first.start.x)} ${formatPathNumber(first.start.y)}`,
    ...segments.map((segment) =>
      `C ${formatPathNumber(segment.control1.x)} ${formatPathNumber(segment.control1.y)} ${formatPathNumber(segment.control2.x)} ${formatPathNumber(segment.control2.y)} ${formatPathNumber(segment.end.x)} ${formatPathNumber(segment.end.y)}`,
    ),
  ].join(" ");
}

export function bezierStrokePathData(stroke: FreeformStroke): string {
  return bezierSegmentsPathData(stroke.segments);
}

interface ComposeOptions {
  readonly digits: readonly number[];
  readonly layout: AssemblyLayout;
  readonly direction: ReadingDirection;
  readonly startAngle: number;
  readonly fanSpread: number;
  readonly lineSpacing: number;
}

export function composeArmInstances(options: ComposeOptions): readonly ArmInstance[] {
  const { digits, layout, direction, startAngle, fanSpread, lineSpacing } = options;
  const sign = direction === "clockwise" ? 1 : -1;
  const count = Math.max(1, digits.length);
  return Object.freeze(
    digits.map((digit, sourceIndex) => {
      if (layout === "linear") {
        const desiredSpan = Math.max(0, count - 1) * lineSpacing;
        const fit = desiredSpan > 0 ? Math.min(1, 440 / desiredSpan) : 1;
        return Object.freeze({
          digit,
          sourceIndex,
          x: positionInSpan(sourceIndex, count, desiredSpan * fit),
          y: 112,
          rotation: 0,
          scale: fit,
        });
      }
      if (layout === "fan") {
        const angle = startAngle + sign * positionInSpan(sourceIndex, count, fanSpread);
        return Object.freeze({
          digit,
          sourceIndex,
          x: 0,
          y: 0,
          rotation: angle,
          scale: Math.min(1, 6 / count),
        });
      }
      if (layout === "stack") {
        return Object.freeze({
          digit,
          sourceIndex,
          x: 0,
          y: 0,
          rotation: startAngle + sign * positionInSpan(sourceIndex, count, Math.min(72, count * 9)),
          scale: 1 - sourceIndex * Math.min(0.045, 0.28 / count),
        });
      }
      return Object.freeze({
        digit,
        sourceIndex,
        x: 0,
        y: 0,
        rotation: startAngle + sign * (sourceIndex * 360) / count,
        scale: Math.min(1, 6.5 / count),
      });
    }),
  );
}

export function endpointLabel(endpoint: Endpoint): string {
  if (endpoint === "root") return "Root";
  if (endpoint === "core") return "Core";
  return `B${endpoint}`;
}

function normalizedIndex(index: number, count: number): number {
  return count <= 1 ? 0.5 : index / (count - 1);
}

function positionInSpan(index: number, count: number, span: number): number {
  return (normalizedIndex(index, count) - 0.5) * span;
}

function pointsOnPolygon(
  count: number,
  sides: number,
  center: Point,
  radius: number,
  startDegrees: number,
): Point[] {
  return Array.from({ length: count }, (_, index) => {
    const sidePosition = (index * sides) / count;
    const sideIndex = Math.floor(sidePosition);
    const progress = sidePosition - sideIndex;
    const first = polarPoint(sideIndex, sides, center, radius, startDegrees);
    const second = polarPoint((sideIndex + 1) % sides, sides, center, radius, startDegrees);
    return {
      x: first.x + (second.x - first.x) * progress,
      y: first.y + (second.y - first.y) * progress,
    };
  });
}

function polarPoint(
  index: number,
  count: number,
  center: Point,
  radius: number,
  startDegrees: number,
): Point {
  const radians = ((startDegrees + (index * 360) / count) * Math.PI) / 180;
  return { x: center.x + Math.cos(radians) * radius, y: center.y + Math.sin(radians) * radius };
}

function freezePoints(points: readonly Point[]): readonly Point[] {
  return Object.freeze(points.map((point) => Object.freeze({ ...point })));
}

function simplifyPolyline(points: readonly Point[], tolerance: number): readonly Point[] {
  if (points.length <= 2) return [...points];
  const first = points[0];
  const last = points[points.length - 1];
  if (first === undefined || last === undefined) return [];
  let largestDistance = 0;
  let splitIndex = 0;
  for (let index = 1; index < points.length - 1; index += 1) {
    const point = points[index];
    if (point === undefined) continue;
    const distance = perpendicularDistance(point, first, last);
    if (distance > largestDistance) {
      largestDistance = distance;
      splitIndex = index;
    }
  }
  if (largestDistance <= tolerance) return [first, last];
  const left = simplifyPolyline(points.slice(0, splitIndex + 1), tolerance);
  const right = simplifyPolyline(points.slice(splitIndex), tolerance);
  return [...left.slice(0, -1), ...right];
}

function perpendicularDistance(point: Point, start: Point, end: Point): number {
  const dx = end.x - start.x;
  const dy = end.y - start.y;
  if (Math.abs(dx) < 0.001 && Math.abs(dy) < 0.001) {
    return Math.hypot(point.x - start.x, point.y - start.y);
  }
  const progress = ((point.x - start.x) * dx + (point.y - start.y) * dy) / (dx ** 2 + dy ** 2);
  const closestX = start.x + progress * dx;
  const closestY = start.y + progress * dy;
  return Math.hypot(point.x - closestX, point.y - closestY);
}

function roundAxialCoordinates(q: number, r: number): { readonly q: number; readonly r: number } {
  const x = q;
  const z = r;
  const y = -x - z;
  let roundedX = Math.round(x);
  let roundedY = Math.round(y);
  let roundedZ = Math.round(z);
  const differenceX = Math.abs(roundedX - x);
  const differenceY = Math.abs(roundedY - y);
  const differenceZ = Math.abs(roundedZ - z);
  if (differenceX > differenceY && differenceX > differenceZ) roundedX = -roundedY - roundedZ;
  else if (differenceY > differenceZ) roundedY = -roundedX - roundedZ;
  else roundedZ = -roundedX - roundedY;
  return { q: roundedX, r: roundedZ };
}

function formatPathNumber(value: number): string {
  const rounded = Math.round(value * 1000) / 1000;
  return Object.is(rounded, -0) ? "0" : String(rounded);
}

function undirectedSegmentKey(from: Endpoint, to: Endpoint): string {
  const first = endpointSortValue(from);
  const second = endpointSortValue(to);
  return first <= second ? `${first}:${second}` : `${second}:${first}`;
}

function segmentGeometryKey(segment: StrokeSegment | TracedStroke): string {
  if (segment.curve === "line" || Math.abs(segment.bend) < 0.001) {
    return undirectedSegmentKey(segment.from, segment.to);
  }
  const from = endpointSortValue(segment.from);
  const to = endpointSortValue(segment.to);
  const first = Math.min(from, to);
  const second = Math.max(from, to);
  const canonicalBend = from <= to ? segment.bend : -segment.bend;
  return `${first}:${second}:hyperbolic:${canonicalBend}`;
}

function endpointSortValue(endpoint: Endpoint): number {
  if (endpoint === "root") return -2;
  if (endpoint === "core") return -1;
  return endpoint;
}
