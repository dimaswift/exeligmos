import type {
  BinaryAnalysis,
  ComplementSymmetry,
  CompositeAnalysis,
  DigitRun,
  EqualDigitGroup,
  EventFilterId,
  EventFilterMode,
  PhaseConjunction,
  RadixAnalysis,
  ReflectionAxis,
  StructuralEvent,
  TemporalAnalysis,
  TemporalFrame,
} from "./types";

export const UINT16_STATE_COUNT = 65_536;
export const UINT16_MAX = UINT16_STATE_COUNT - 1;
export const DEFAULT_RADICES = Object.freeze([8, 9, 11, 13] as const);
export const DEFAULT_PHASE_TOLERANCE = 0.04;
export const RADIX_ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz+/";

export const TEMPORAL_FRAMES: readonly TemporalFrame[] = Object.freeze([
  { id: "lunar", label: "Synodic lunar month", days: 29.530588853 },
  { id: "year", label: "Tropical year", days: 365.24219 },
  { id: "saros", label: "Saros", days: 6585.3211 },
]);

export function clampUint16(value: unknown): number {
  const parsed = typeof value === "number" ? value : Number(value);
  if (!Number.isFinite(parsed)) return 0;
  return Math.min(UINT16_MAX, Math.max(0, Math.trunc(parsed)));
}

export function wrapUint16(value: number): number {
  const integer = Math.trunc(Number.isFinite(value) ? value : 0);
  return ((integer % UINT16_STATE_COUNT) + UINT16_STATE_COUNT) % UINT16_STATE_COUNT;
}

export function digitsForRadix(value: number, radix: number): readonly number[] {
  const safeValue = clampUint16(value);
  const safeRadix = Math.min(64, Math.max(2, Math.trunc(radix)));
  if (safeValue === 0) return Object.freeze([0]);
  const digits: number[] = [];
  let remaining = safeValue;
  while (remaining > 0) {
    digits.push(remaining % safeRadix);
    remaining = Math.floor(remaining / safeRadix);
  }
  return Object.freeze(digits.reverse());
}

export function formatRadixRepresentation(digits: readonly number[]): string {
  return digits.map((digit) => RADIX_ALPHABET[digit] ?? `[${digit}]`).join("");
}

export function analyzeRadix(value: number, radix: number): RadixAnalysis {
  const safeRadix = Math.min(64, Math.max(2, Math.trunc(radix)));
  const safeValue = clampUint16(value);
  const digits = digitsForRadix(safeValue, safeRadix);
  const { periodLength, block, repeatCount } = minimalRepeatingBlock(digits);
  const repeatedDigit = digits.length > 1 && digits.every((digit) => digit === digits[0]);
  const histogram = new Map<number, number>();
  for (const digit of digits) histogram.set(digit, (histogram.get(digit) ?? 0) + 1);
  const entropy = [...histogram.values()].reduce((total, count) => {
    const probability = count / digits.length;
    return total - probability * Math.log2(probability);
  }, 0);
  const entropyScale = Math.log2(Math.min(safeRadix, Math.max(2, digits.length)));
  return Object.freeze({
    radix: safeRadix,
    residue: safeValue % safeRadix,
    normalizedPhase: (safeValue % safeRadix) / safeRadix,
    digits,
    representation: formatRadixRepresentation(digits),
    isRepdigit: repeatedDigit,
    ...(repeatedDigit ? { repdigitDigit: digits[0], repdigitLength: digits.length } : {}),
    isPalindrome: digits.length > 1 && isPalindrome(digits),
    minimalPeriod: periodLength,
    periodBlock: block,
    repeatCount,
    alternating: periodLength === 2 && repeatCount > 1 && block[0] !== block[1],
    runs: runsOf(digits),
    uniqueDigitCount: histogram.size,
    digitSum: digits.reduce((total, digit) => total + digit, 0),
    normalizedEntropy: entropyScale === 0 ? 0 : entropy / entropyScale,
  });
}

export function analyzeBinary(value: number): BinaryAnalysis {
  const safeValue = clampUint16(value);
  const fixedBits = Object.freeze(Array.from({ length: 16 }, (_, index) => (safeValue >>> index) & 1));
  const fixedWord = [...fixedBits].reverse().join("");
  const significantWord = safeValue.toString(2);
  const significantBits = Object.freeze([...significantWord].map(Number));
  const reflectionAxes: ReflectionAxis[] = [];
  const complementSymmetries: ComplementSymmetry[] = [];

  for (let axis = 0; axis < 16; axis += 1) {
    if (fixedBits.every((bit, index) => bit === fixedBits[mod(axis - index, 16)])) {
      reflectionAxes.push({ index: axis, degrees: axis * 11.25, kind: axis % 2 === 0 ? "nodes" : "edges" });
    }
    if (fixedBits.every((bit, index) => bit !== fixedBits[mod(axis - index, 16)])) {
      complementSymmetries.push({ kind: "reflection", index: axis });
    }
  }
  for (let rotation = 1; rotation < 16; rotation += 1) {
    if (fixedBits.every((bit, index) => bit !== fixedBits[(index + rotation) % 16])) {
      complementSymmetries.push({ kind: "rotation", index: rotation });
    }
  }

  return Object.freeze({
    value: safeValue,
    fixedBits,
    significantBits,
    fixedWord,
    significantWord,
    popcount: fixedBits.reduce((total, bit) => total + bit, 0),
    linearRuns: runsOf([...fixedBits].reverse()),
    cyclicRuns: cyclicRunsOf(fixedBits),
    fixedPalindrome: isPalindrome([...fixedBits].reverse()),
    significantPalindrome: significantBits.length > 1 && isPalindrome(significantBits),
    rotationalPeriod: cyclicPeriod(fixedBits),
    significantPeriod: minimalRepeatingBlock(significantBits).periodLength,
    reflectionAxes: Object.freeze(reflectionAxes),
    alternating: fixedBits.every((bit, index) => index === 0 || bit !== fixedBits[index - 1]),
    significantAlternating: significantBits.length > 1
      && significantBits.every((bit, index) => index === 0 || bit !== significantBits[index - 1]),
    complementSymmetries: Object.freeze(complementSymmetries),
    complement: (~safeValue) & UINT16_MAX,
  });
}

export function analyzeComposite(
  value: number,
  radices: readonly number[] = DEFAULT_RADICES,
  phaseTolerance = DEFAULT_PHASE_TOLERANCE,
): CompositeAnalysis {
  const safeValue = clampUint16(value);
  const safeRadices = Object.freeze(radices.map((radix) => Math.min(64, Math.max(2, Math.trunc(radix)))));
  const binary = analyzeBinary(safeValue);
  const radixAnalyses = Object.freeze(safeRadices.map((radix) => analyzeRadix(safeValue, radix)));
  const lcmValue = safeRadices.reduce(lcm, 1);
  const product = safeRadices.reduce((total, radix) => total * radix, 1);
  const pairwiseGcd = Object.freeze(safeRadices.map((left) => Object.freeze(safeRadices.map((right) => gcd(left, right)))));
  const pairwisePhaseDistances = Object.freeze(radixAnalyses.map((left) => Object.freeze(
    radixAnalyses.map((right) => circularPhaseDistance(left.normalizedPhase, right.normalizedPhase)),
  )));
  const equalDigitGroups = equalResidueGroups(radixAnalyses);
  const phaseConjunctions: PhaseConjunction[] = [];
  radixAnalyses.forEach((left, leftIndex) => {
    radixAnalyses.slice(leftIndex + 1).forEach((right, relativeIndex) => {
      const rightIndex = leftIndex + relativeIndex + 1;
      const distance = pairwisePhaseDistances[leftIndex]?.[rightIndex] ?? 1;
      if (distance <= phaseTolerance) phaseConjunctions.push({ radices: [left.radix, right.radix], distance });
    });
  });

  const binaryScore = binaryRegularity(binary);
  const withinBases = radixAnalyses.reduce((score, analysis) => score
    + (analysis.isRepdigit ? 2 : 0)
    + (analysis.isPalindrome ? 1.25 : 0)
    + (analysis.repeatCount > 1 ? 1.5 : 0)
    + (analysis.uniqueDigitCount <= 2 && analysis.digits.length > 2 ? 0.5 : 0), 0);
  const crossBase = equalDigitGroups.reduce((score, group) => score + group.radices.length - 1, 0)
    + phaseConjunctions.length * 0.5;
  const resonanceComponents = Object.freeze({ binary: binaryScore, withinBases, crossBase });

  return Object.freeze({
    value: safeValue,
    binary,
    radices: radixAnalyses,
    lcm: lcmValue,
    product,
    outerPhase: safeValue % lcmValue,
    supercycleIndex: Math.floor(safeValue / lcmValue),
    pairwiseGcd,
    pairwisePhaseDistances,
    equalDigitGroups,
    phaseConjunctions: Object.freeze(phaseConjunctions),
    resonanceComponents,
    resonanceScore: binaryScore + withinBases + crossBase,
  });
}

export function analyzeTemporal(value: number, frame: TemporalFrame): TemporalAnalysis {
  const normalizedPhase = clampUint16(value) / UINT16_STATE_COUNT;
  const elapsedDays = normalizedPhase * frame.days;
  return Object.freeze({
    frame,
    normalizedPhase,
    degrees: normalizedPhase * 360,
    elapsedDays,
    remainingDays: frame.days - elapsedDays,
    binDurationSeconds: frame.days * 86_400 / UINT16_STATE_COUNT,
  });
}

export function scanStructuralEvents(
  radices: readonly number[],
  filters: ReadonlySet<EventFilterId>,
  mode: EventFilterMode,
  phaseTolerance = DEFAULT_PHASE_TOLERANCE,
): readonly StructuralEvent[] {
  if (filters.size === 0) return Object.freeze([]);
  const events: StructuralEvent[] = [];
  for (let value = 0; value <= UINT16_MAX; value += 1) {
    const analysis = analyzeComposite(value, radices, phaseTolerance);
    const labels = eventLabels(analysis);
    const matches = [...filters].map((filter) => labels.has(filter));
    const accepted = mode === "and" ? matches.every(Boolean) : matches.some(Boolean);
    if (accepted) {
      events.push(Object.freeze({
        value,
        labels: Object.freeze([...labels.values()].map(eventFilterLabel)),
        score: analysis.resonanceScore,
      }));
    }
  }
  return Object.freeze(events);
}

export function eventLabels(analysis: CompositeAnalysis): ReadonlySet<EventFilterId> {
  const labels = new Set<EventFilterId>();
  if (analysis.binary.fixedPalindrome || analysis.binary.significantPalindrome) labels.add("binary-palindrome");
  if (analysis.binary.rotationalPeriod < 16 || analysis.binary.reflectionAxes.length > 0) labels.add("binary-symmetry");
  if (analysis.radices.some((radix) => radix.isRepdigit)) labels.add("repdigit");
  if (analysis.radices.some((radix) => radix.isPalindrome)) labels.add("radix-palindrome");
  if (analysis.radices.some((radix) => radix.repeatCount > 1)) labels.add("repeated-block");
  if (analysis.equalDigitGroups.length > 0) labels.add("residue-conjunction");
  if (analysis.phaseConjunctions.length > 0) labels.add("phase-conjunction");
  return labels;
}

export function eventFilterLabel(filter: EventFilterId): string {
  switch (filter) {
    case "binary-palindrome": return "binary palindrome";
    case "binary-symmetry": return "binary symmetry";
    case "repdigit": return "repdigit";
    case "radix-palindrome": return "radix palindrome";
    case "repeated-block": return "repeated block";
    case "residue-conjunction": return "residue conjunction";
    case "phase-conjunction": return "phase conjunction";
  }
}

export function circularPhaseDistance(left: number, right: number): number {
  const difference = Math.abs(left - right) % 1;
  return Math.min(difference, 1 - difference);
}

export function gcd(left: number, right: number): number {
  let a = Math.abs(Math.trunc(left));
  let b = Math.abs(Math.trunc(right));
  while (b !== 0) [a, b] = [b, a % b];
  return a;
}

export function lcm(left: number, right: number): number {
  if (left === 0 || right === 0) return 0;
  return Math.abs(Math.trunc(left * right)) / gcd(left, right);
}

export function minimalRepeatingBlock(digits: readonly number[]): {
  readonly periodLength: number;
  readonly block: readonly number[];
  readonly repeatCount: number;
} {
  for (let length = 1; length <= digits.length; length += 1) {
    if (digits.length % length !== 0) continue;
    if (digits.every((digit, index) => digit === digits[index % length])) {
      return Object.freeze({
        periodLength: length,
        block: Object.freeze(digits.slice(0, length)),
        repeatCount: digits.length / length,
      });
    }
  }
  return Object.freeze({ periodLength: digits.length, block: Object.freeze([...digits]), repeatCount: 1 });
}

function equalResidueGroups(analyses: readonly RadixAnalysis[]): readonly EqualDigitGroup[] {
  const byResidue = new Map<number, number[]>();
  for (const analysis of analyses) {
    const group = byResidue.get(analysis.residue) ?? [];
    group.push(analysis.radix);
    byResidue.set(analysis.residue, group);
  }
  return Object.freeze([...byResidue.entries()]
    .filter(([, radices]) => radices.length > 1)
    .map(([residue, radices]) => Object.freeze({ residue, radices: Object.freeze(radices) })));
}

function binaryRegularity(binary: BinaryAnalysis): number {
  return (binary.rotationalPeriod < 16 ? (16 - binary.rotationalPeriod) / 4 : 0)
    + Math.min(2, binary.reflectionAxes.length * 0.25)
    + (binary.fixedPalindrome ? 1 : 0)
    + (binary.significantPalindrome ? 0.75 : 0)
    + (binary.significantAlternating ? 1.5 : 0)
    + ([0, 1, 8, 15, 16].includes(binary.popcount) ? 0.75 : 0);
}

function runsOf(digits: readonly number[]): readonly DigitRun[] {
  if (digits.length === 0) return Object.freeze([]);
  const runs: DigitRun[] = [];
  let digit = digits[0] ?? 0;
  let length = 1;
  for (let index = 1; index < digits.length; index += 1) {
    if (digits[index] === digit) length += 1;
    else {
      runs.push({ digit, length });
      digit = digits[index] ?? 0;
      length = 1;
    }
  }
  runs.push({ digit, length });
  return Object.freeze(runs.map((run) => Object.freeze(run)));
}

function cyclicRunsOf(bits: readonly number[]): readonly DigitRun[] {
  const runs = [...runsOf(bits)];
  if (runs.length > 1 && runs[0]?.digit === runs.at(-1)?.digit) {
    const first = runs[0];
    const last = runs.at(-1);
    if (first !== undefined && last !== undefined) {
      runs[0] = { digit: first.digit, length: first.length + last.length };
      runs.pop();
    }
  }
  return Object.freeze(runs.map((run) => Object.freeze(run)));
}

function cyclicPeriod(bits: readonly number[]): number {
  for (const period of [1, 2, 4, 8, 16]) {
    if (bits.every((bit, index) => bit === bits[(index + period) % bits.length])) return period;
  }
  return bits.length;
}

function isPalindrome(digits: readonly number[]): boolean {
  return digits.every((digit, index) => digit === digits[digits.length - index - 1]);
}

function mod(value: number, modulus: number): number {
  return ((value % modulus) + modulus) % modulus;
}
