import { canonicalCatalog } from "@fractonica/domain-catalog";

import { glyphStyleForRarity, normalizeGlyphStyle } from "./style.js";
import type {
  CreateOctalGlyphOptions,
  CreateMixedRadixGlyphOptions,
  GlyphColorRole,
  GlyphContour,
  GlyphFrameBounds,
  GlyphModel,
  GlyphPath,
  GlyphPoint,
  GlyphStyle,
} from "./types.js";

interface Socket {
  readonly start: GlyphPoint;
  readonly end: GlyphPoint;
}

interface Geometry {
  readonly depth: number;
  readonly frame: GlyphFrameBounds;
  readonly core: readonly GlyphContour[];
  readonly armPolygons: readonly (readonly (readonly GlyphPoint[] | null)[])[];
}

const glyphCatalog = canonicalCatalog.glyph;
const presentationDepth = canonicalCatalog.harmonics.presentationDepth;
const radixDigits = new Set([...canonicalCatalog.radix.digits]);
const geometryCache = new Map<string, Geometry>();
const mixedGeometryCache = new Map<string, Pick<Geometry, "depth" | "frame" | "core">>();
const STACK_MAX_DIGIT = 7;
const STACK_OFFSET_LIMIT = 64;
export const DEFAULT_MIXED_RADIX_STACK_OFFSET_X = 0.25;
export const DEFAULT_MIXED_RADIX_STACK_OFFSET_Y = 2.5;
/** Pull each continuation a full arm width inward so its root is buried in the seven-arm body. */
const STACK_ANCHOR_ADVANCE =
  Math.max(...glyphCatalog.arms.find((arm) => arm.digit === 7)!.points.map((point) => point[1])) -
  glyphCatalog.constants.socketWidth;

export function clampGlyphDepth(rawDepth: unknown): number {
  const numeric = coerceFiniteNumber(rawDepth);
  const integer = numeric === null ? presentationDepth.default : Math.trunc(numeric);
  return Math.min(
    Math.max(integer, glyphCatalog.supportedDepth.minimum),
    glyphCatalog.supportedDepth.maximum,
  );
}

export function normalizeGlyphOctal(
  value: unknown,
  rawDepth: unknown = presentationDepth.default,
): string {
  const depth = clampGlyphDepth(rawDepth);
  const filtered = [...safeString(value)]
    .filter((character) => radixDigits.has(character))
    .join("");
  return filtered.slice(-depth).padStart(depth, canonicalCatalog.radix.digits[0]);
}

export function glyphSocketDigitIndices(rawDepth: unknown): readonly number[] {
  const depth = clampGlyphDepth(rawDepth);
  return Object.freeze(
    Array.from({ length: depth }, (_, socketIndex) =>
      socketIndex === 0 ? 0 : depth - socketIndex,
    ),
  );
}

export function glyphFrameBounds(rawDepth: unknown): GlyphFrameBounds {
  return getGeometry(clampGlyphDepth(rawDepth)).frame;
}

/** Builds the immutable, deterministic fill geometry used by every renderer. */
export function createOctalGlyph(options: CreateOctalGlyphOptions): GlyphModel {
  const depth = clampGlyphDepth(options.depth);
  const geometry = getGeometry(depth);
  const normalizedValue = normalizeGlyphOctal(options.value, depth);
  const digits = [...normalizedValue].map((digit) => Number(digit));
  const hasStyle = options.style !== undefined;
  const hasRarity = Object.hasOwn(options, "rarityId");
  if (hasStyle === hasRarity) {
    throw new TypeError("Octal glyphs require exactly one explicit style or rarityId.");
  }
  const style = normalizeGlyphStyle(
    hasStyle ? options.style : glyphStyleForRarity(options.rarityId),
    depth,
  );
  const digitIndices = glyphSocketDigitIndices(depth);

  const paths: GlyphPath[] = [
    freezePath({
      id: "core",
      contours: geometry.core,
      colorRole: "secondary",
      fillRule: glyphCatalog.fillRule === "even-odd" ? "evenodd" : "nonzero",
    }),
  ];

  for (let socketIndex = 0; socketIndex < depth; socketIndex += 1) {
    const digitIndex = digitIndices[socketIndex];
    if (digitIndex === undefined) {
      continue;
    }
    const digit = digits[digitIndex] ?? 0;
    const points = geometry.armPolygons[socketIndex]?.[digit] ?? null;
    // Swift intentionally makes digit zero an empty arm: its two source points are not a polygon.
    if (points === null || points.length < 3) {
      continue;
    }
    paths.push(
      freezePath({
        id: `arm-${socketIndex}`,
        contours: [freezeContour(points)],
        colorRole: colorRoleForDigitIndex(style, digitIndex),
        fillRule: "nonzero",
        socketIndex,
        digitIndex,
        digit,
      }),
    );
  }

  const rawLabel = options.accessibilityLabel?.trim();
  const label =
    rawLabel === undefined || rawLabel === "" ? glyphCatalog.accessibility.label : rawLabel;
  return deepFreezeModel({
    kind: "octal",
    depth,
    normalizedValue,
    viewBox: [geometry.frame.x, geometry.frame.y, geometry.frame.width, geometry.frame.height],
    aspectRatio: geometry.frame.aspectRatio,
    paths,
    paints: {
      primary: style.primary,
      secondary: style.secondary,
    },
    accessibility: {
      label,
      value: normalizedValue,
    },
  });
}

/**
 * Builds the experimental mixed-radix glyph. Values above seven retain a full
 * seven arm and continue from its outer anchor with another octal layer.
 */
export function createMixedRadixGlyph(options: CreateMixedRadixGlyphOptions): GlyphModel {
  const { digits, radices } = normalizeMixedRadixInput(options.digits, options.radices);
  const stackOffsetX = normalizeStackOffset(options.stackOffsetX, "X");
  const stackOffsetY = normalizeStackOffset(options.stackOffsetY, "Y");
  const depth = digits.length;
  const geometry = getMixedGeometry(radices, stackOffsetX, stackOffsetY);
  const sockets = makeSockets(depth);
  const hasStyle = options.style !== undefined;
  const hasRarity = Object.hasOwn(options, "rarityId");
  if (hasStyle === hasRarity) {
    throw new TypeError("Mixed-radix glyphs require exactly one explicit style or rarityId.");
  }
  const style = normalizeGlyphStyle(
    hasStyle ? options.style : glyphStyleForRarity(options.rarityId),
    depth,
  );
  const digitIndices = glyphSocketDigitIndices(depth);
  const paths: GlyphPath[] = [
    freezePath({
      id: "core",
      contours: geometry.core,
      colorRole: "secondary",
      fillRule: glyphCatalog.fillRule === "even-odd" ? "evenodd" : "nonzero",
    }),
  ];

  for (let socketIndex = 0; socketIndex < depth; socketIndex += 1) {
    const digitIndex = digitIndices[socketIndex];
    if (digitIndex === undefined) continue;
    const digit = digits[digitIndex] ?? 0;
    const radix = radices[digitIndex] ?? STACK_MAX_DIGIT + 1;
    const contours = stackedArmContours(digit, socketIndex, sockets, stackOffsetX, stackOffsetY);
    contours.forEach((contour, layerIndex) => {
      const layerDigit = stackedLayerDigits(digit)[layerIndex] ?? 0;
      paths.push(
        freezePath({
          id: `arm-${socketIndex}-layer-${layerIndex}`,
          contours: [contour],
          colorRole: colorRoleForDigitIndex(style, digitIndex),
          fillRule: "nonzero",
          socketIndex,
          digitIndex,
          digit,
          layerIndex,
          layerDigit,
          radix,
        }),
      );
    });
  }

  const normalizedValue = digits.join("·");
  const rawLabel = options.accessibilityLabel?.trim();
  return deepFreezeModel({
    kind: "mixed-radix",
    depth,
    normalizedValue,
    viewBox: [geometry.frame.x, geometry.frame.y, geometry.frame.width, geometry.frame.height],
    aspectRatio: geometry.frame.aspectRatio,
    paths,
    paints: { primary: style.primary, secondary: style.secondary },
    accessibility: {
      label: rawLabel === undefined || rawLabel === "" ? "Mixed-radix glyph" : rawLabel,
      value: digits.map((digit, index) => `${digit} base ${radices[index]}`).join(", "),
    },
  });
}

/** Serializes all contours into a single SVG path, retaining even-odd holes. */
export function pathData(path: Pick<GlyphPath, "contours">): string {
  return path.contours
    .filter((contour) => contour.points.length >= 3)
    .map((contour) => {
      const [first, ...rest] = contour.points;
      if (first === undefined) {
        return "";
      }
      const commands = [`M ${format(first.x)} ${format(first.y)}`];
      for (const point of rest) {
        commands.push(`L ${format(point.x)} ${format(point.y)}`);
      }
      commands.push("Z");
      return commands.join(" ");
    })
    .filter(Boolean)
    .join(" ");
}

function getGeometry(depth: number): Geometry {
  const key = String(depth);
  const cached = geometryCache.get(key);
  if (cached !== undefined) {
    return cached;
  }
  const geometry = makeGeometry(depth);
  geometryCache.set(key, geometry);
  return geometry;
}

function getMixedGeometry(
  radices: readonly number[],
  stackOffsetX: number,
  stackOffsetY: number,
): Pick<Geometry, "depth" | "frame" | "core"> {
  const key = `${radices.join(".")}|${stackOffsetX}|${stackOffsetY}`;
  const cached = mixedGeometryCache.get(key);
  if (cached !== undefined) return cached;
  const depth = radices.length;
  const octalGeometry = getGeometry(depth);
  const sockets = makeSockets(depth);
  const points = octalGeometry.core.flatMap((contour) => [...contour.points]);
  radices.forEach((radix, digitIndex) => {
    const socketIndex = digitIndex === 0 ? 0 : depth - digitIndex;
    for (let digit = 0; digit < radix; digit += 1) {
      for (const contour of stackedArmContours(
        digit,
        socketIndex,
        sockets,
        stackOffsetX,
        stackOffsetY,
      )) {
        points.push(...contour.points);
      }
    }
  });
  const geometry = Object.freeze({
    depth,
    frame: paddedFrameBounds(points),
    core: octalGeometry.core,
  });
  mixedGeometryCache.set(key, geometry);
  return geometry;
}

function makeGeometry(depth: number): Geometry {
  const sockets = makeSockets(depth);
  const corePolygon = sockets.flatMap((socket) => [socket.start, socket.end]);
  const coreHole =
    depth === glyphCatalog.coreHole.exactDepth
      ? glyphCatalog.coreHole.exactPoints.map(tupleToPoint)
      : insetConvexPolygon(corePolygon, glyphCatalog.constants.insetThickness);
  const armPolygons = sockets.map((_, socketIndex) =>
    glyphCatalog.arms.map((arm) => {
      const points = armToWorldPoints(arm.points.map(tupleToPoint), socketIndex, sockets);
      return points.length >= 3 ? Object.freeze(points) : null;
    }),
  );
  const frame = makeFrameBounds(corePolygon, coreHole, sockets, depth);
  const geometry: Geometry = {
    depth,
    frame,
    core: [freezeContour(corePolygon), freezeContour(coreHole)],
    armPolygons: Object.freeze(armPolygons.map((socket) => Object.freeze(socket))),
  };
  return Object.freeze(geometry);
}

function makeSockets(depth: number): readonly Socket[] {
  const { socketWidth, coreRadius } = glyphCatalog.constants;
  const baseStart = { x: -socketWidth / 2, y: -coreRadius };
  const baseEnd = { x: socketWidth / 2, y: -coreRadius };
  const rotationStep = 360 / depth;
  return Object.freeze(
    Array.from({ length: depth }, (_, index) =>
      Object.freeze({
        start: rotate(baseStart, index * rotationStep),
        end: rotate(baseEnd, index * rotationStep),
      }),
    ),
  );
}

function makeFrameBounds(
  corePolygon: readonly GlyphPoint[],
  coreHole: readonly GlyphPoint[],
  sockets: readonly Socket[],
  depth: number,
): GlyphFrameBounds {
  const points: GlyphPoint[] = [...corePolygon, ...coreHole];
  points.push(...sockets.flatMap((socket) => [socket.start, socket.end]));
  for (let socketIndex = 0; socketIndex < depth; socketIndex += 1) {
    for (const arm of glyphCatalog.arms) {
      points.push(...armToWorldPoints(arm.points.map(tupleToPoint), socketIndex, sockets));
    }
  }
  return paddedFrameBounds(points);
}

function paddedFrameBounds(points: readonly GlyphPoint[]): GlyphFrameBounds {
  const xs = points.map((point) => point.x);
  const ys = points.map((point) => point.y);
  const minX = Math.min(...xs);
  const maxX = Math.max(...xs);
  const minY = Math.min(...ys);
  const maxY = Math.max(...ys);
  const { gridSize, paddingCells } = glyphCatalog.constants;
  const padding = gridSize * paddingCells;
  const halfWidth = Math.max(
    gridSize,
    Math.ceil(Math.max(Math.abs(minX), Math.abs(maxX)) / gridSize) * gridSize + padding,
  );
  const halfHeight = Math.max(
    gridSize,
    Math.ceil(Math.max(Math.abs(minY), Math.abs(maxY)) / gridSize) * gridSize + padding,
  );
  return Object.freeze({
    x: -halfWidth,
    y: -halfHeight,
    width: halfWidth * 2,
    height: halfHeight * 2,
    aspectRatio: halfWidth / halfHeight,
  });
}

function stackedArmContours(
  digit: number,
  socketIndex: number,
  sockets: readonly Socket[],
  stackOffsetX: number,
  stackOffsetY: number,
): readonly GlyphContour[] {
  const layers = stackedLayerDigits(digit);
  return Object.freeze(
    layers.flatMap((layerDigit, layerIndex) => {
      if (layerDigit === 0) return [];
      const offsetX = layerIndex * stackOffsetX;
      const offsetY = layerIndex * (STACK_ANCHOR_ADVANCE + stackOffsetY);
      const localPoints = (
        glyphCatalog.arms.find((arm) => arm.digit === layerDigit)?.points ?? []
      ).map(([x, y]) => ({ x: x + offsetX, y: y + offsetY }));
      const worldPoints = localArmToWorldPoints(localPoints, socketIndex, sockets);
      return worldPoints.length < 3 ? [] : [freezeContour(worldPoints)];
    }),
  );
}

function stackedLayerDigits(digit: number): readonly number[] {
  if (digit <= STACK_MAX_DIGIT) return Object.freeze([digit]);
  const completeLayers = Math.floor(digit / STACK_MAX_DIGIT);
  const remainder = digit % STACK_MAX_DIGIT;
  return Object.freeze([
    ...Array.from({ length: completeLayers }, () => STACK_MAX_DIGIT),
    ...(remainder === 0 ? [] : [remainder]),
  ]);
}

function localArmToWorldPoints(
  points: readonly GlyphPoint[],
  socketIndex: number,
  sockets: readonly Socket[],
): readonly GlyphPoint[] {
  const socket = sockets[socketIndex];
  if (socket === undefined) return Object.freeze([]);
  const center = midpoint(socket.start, socket.end);
  const dx = socket.end.x - socket.start.x;
  const dy = socket.end.y - socket.start.y;
  const length = Math.max(Math.hypot(dx, dy), 0.001);
  const tangent = { x: dx / length, y: dy / length };
  let outward = { x: tangent.y, y: -tangent.x };
  if (outward.x * center.x + outward.y * center.y < 0) {
    outward = { x: -outward.x, y: -outward.y };
  }
  return Object.freeze(
    points.map((point) =>
      Object.freeze({
        x: center.x + tangent.x * point.x + outward.x * point.y,
        y: center.y + tangent.y * point.x + outward.y * point.y,
      }),
    ),
  );
}

function normalizeMixedRadixInput(
  rawDigits: readonly number[],
  rawRadices: readonly number[],
): { readonly digits: readonly number[]; readonly radices: readonly number[] } {
  if (rawDigits.length !== rawRadices.length) {
    throw new RangeError("Mixed-radix digits and radices must be equal-length arrays.");
  }
  if (
    rawDigits.length < glyphCatalog.supportedDepth.minimum ||
    rawDigits.length > glyphCatalog.supportedDepth.maximum
  ) {
    throw new RangeError(
      `Mixed-radix glyph depth must be ${glyphCatalog.supportedDepth.minimum}...${glyphCatalog.supportedDepth.maximum}.`,
    );
  }
  const radices = rawRadices.map((radix) => {
    if (!Number.isSafeInteger(radix) || radix < 2 || radix > 64) {
      throw new RangeError("Mixed-radix bases must be safe integers from 2 through 64.");
    }
    return radix;
  });
  const digits = rawDigits.map((digit, index) => {
    if (!Number.isSafeInteger(digit) || digit < 0 || digit >= (radices[index] ?? 0)) {
      throw new RangeError(`Digit ${digit} is outside base ${radices[index] ?? "?"}.`);
    }
    return digit;
  });
  return { digits: Object.freeze(digits), radices: Object.freeze(radices) };
}

function normalizeStackOffset(rawValue: number | undefined, axis: "X" | "Y"): number {
  const value =
    rawValue ??
    (axis === "X" ? DEFAULT_MIXED_RADIX_STACK_OFFSET_X : DEFAULT_MIXED_RADIX_STACK_OFFSET_Y);
  if (!Number.isFinite(value) || Math.abs(value) > STACK_OFFSET_LIMIT) {
    throw new RangeError(
      `Mixed-radix stack ${axis} offset must be finite and within -${STACK_OFFSET_LIMIT}...${STACK_OFFSET_LIMIT}.`,
    );
  }
  return Object.is(value, -0) ? 0 : value;
}

function armToWorldPoints(
  points: readonly GlyphPoint[],
  socketIndex: number,
  sockets: readonly Socket[],
): readonly GlyphPoint[] {
  if (points.length < 2) {
    return points;
  }
  const socket = sockets[socketIndex];
  if (socket === undefined) {
    return Object.freeze([]);
  }
  const center = midpoint(socket.start, socket.end);
  const dx = socket.end.x - socket.start.x;
  const dy = socket.end.y - socket.start.y;
  const length = Math.max(Math.hypot(dx, dy), 0.001);
  const tangent = { x: dx / length, y: dy / length };
  let outward = { x: tangent.y, y: -tangent.x };
  if (outward.x * center.x + outward.y * center.y < 0) {
    outward = { x: -outward.x, y: -outward.y };
  }
  return Object.freeze(
    points.map((point, index) => {
      const aligned =
        index === 0
          ? { x: -length / 2, y: 0 }
          : index === points.length - 1
            ? { x: length / 2, y: 0 }
            : point;
      return Object.freeze({
        x: center.x + tangent.x * aligned.x + outward.x * aligned.y,
        y: center.y + tangent.y * aligned.x + outward.y * aligned.y,
      });
    }),
  );
}

function insetConvexPolygon(
  points: readonly GlyphPoint[],
  thickness: number,
): readonly GlyphPoint[] {
  if (points.length < 3 || thickness <= 0) {
    return points;
  }
  const inwardSign = signedArea(points) >= 0 ? 1 : -1;
  const lines = points.map((point, index) => {
    const next = points[(index + 1) % points.length] ?? point;
    const dx = next.x - point.x;
    const dy = next.y - point.y;
    const length = Math.max(Math.hypot(dx, dy), 0.001);
    const normal = {
      x: (-dy / length) * inwardSign,
      y: (dx / length) * inwardSign,
    };
    return {
      point: {
        x: point.x + normal.x * thickness,
        y: point.y + normal.y * thickness,
      },
      direction: { x: dx, y: dy },
    };
  });
  return Object.freeze(
    points.map((point, index) => {
      const previous = lines[(index + lines.length - 1) % lines.length];
      const current = lines[index];
      return previous === undefined || current === undefined
        ? point
        : (intersectLines(previous.point, previous.direction, current.point, current.direction) ??
            point);
    }),
  );
}

function intersectLines(
  pointA: GlyphPoint,
  directionA: GlyphPoint,
  pointB: GlyphPoint,
  directionB: GlyphPoint,
): GlyphPoint | null {
  const cross = directionA.x * directionB.y - directionA.y * directionB.x;
  if (Math.abs(cross) < 0.000001) {
    return null;
  }
  const delta = { x: pointB.x - pointA.x, y: pointB.y - pointA.y };
  const t = (delta.x * directionB.y - delta.y * directionB.x) / cross;
  return Object.freeze({
    x: pointA.x + directionA.x * t,
    y: pointA.y + directionA.y * t,
  });
}

function signedArea(points: readonly GlyphPoint[]): number {
  return points.reduce((area, point, index) => {
    const next = points[(index + 1) % points.length] ?? point;
    return area + point.x * next.y - next.x * point.y;
  }, 0);
}

function rotate(point: GlyphPoint, degrees: number): GlyphPoint {
  const radians = (degrees * Math.PI) / 180;
  const cosine = Math.cos(radians);
  const sine = Math.sin(radians);
  return Object.freeze({
    x: point.x * cosine - point.y * sine,
    y: point.x * sine + point.y * cosine,
  });
}

function midpoint(first: GlyphPoint, second: GlyphPoint): GlyphPoint {
  return {
    x: (first.x + second.x) / 2,
    y: (first.y + second.y) / 2,
  };
}

function tupleToPoint(tuple: readonly [number, number]): GlyphPoint {
  return Object.freeze({ x: tuple[0], y: tuple[1] });
}

function colorRoleForDigitIndex(style: GlyphStyle, digitIndex: number): GlyphColorRole {
  if (style.mode !== "split" || style.splitAfterDigitCount === null) {
    return "primary";
  }
  return digitIndex < style.splitAfterDigitCount ? "primary" : "secondary";
}

function freezeContour(points: readonly GlyphPoint[]): GlyphContour {
  return Object.freeze({ points: Object.freeze([...points]) });
}

function freezePath(path: GlyphPath): GlyphPath {
  return Object.freeze({
    ...path,
    contours: Object.freeze([...path.contours]),
  });
}

function deepFreezeModel(model: GlyphModel): GlyphModel {
  const viewBox: GlyphModel["viewBox"] = Object.freeze([
    model.viewBox[0],
    model.viewBox[1],
    model.viewBox[2],
    model.viewBox[3],
  ]);
  return Object.freeze({
    ...model,
    viewBox,
    paths: Object.freeze([...model.paths]),
    paints: Object.freeze({ ...model.paints }),
    accessibility: Object.freeze({ ...model.accessibility }),
  });
}

function coerceFiniteNumber(value: unknown): number | null {
  if (typeof value === "number") {
    return Number.isFinite(value) ? value : null;
  }
  if (typeof value === "string" && value.trim() !== "") {
    const number = Number(value);
    return Number.isFinite(number) ? number : null;
  }
  return null;
}

function safeString(value: unknown): string {
  try {
    if (typeof value === "string") {
      return value;
    }
    if (typeof value === "number" || typeof value === "bigint" || typeof value === "boolean") {
      return String(value);
    }
    if (typeof value === "symbol") {
      return value.description ?? "";
    }
    if (value !== null && typeof value === "object") {
      const converter = (value as { readonly toString?: unknown }).toString;
      if (typeof converter === "function" && converter !== Object.prototype.toString) {
        const converted: unknown = Reflect.apply(converter, value, []);
        return typeof converted === "string" ? converted : "";
      }
    }
    return "";
  } catch {
    return "";
  }
}

function format(value: number): string {
  const rounded = Number(value.toFixed(4));
  return Object.is(rounded, -0) ? "0" : String(rounded);
}
