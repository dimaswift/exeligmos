export interface DigitRun {
  readonly digit: number;
  readonly length: number;
}

export interface RadixAnalysis {
  readonly radix: number;
  readonly residue: number;
  readonly normalizedPhase: number;
  readonly digits: readonly number[];
  readonly representation: string;
  readonly isRepdigit: boolean;
  readonly repdigitDigit?: number;
  readonly repdigitLength?: number;
  readonly isPalindrome: boolean;
  readonly minimalPeriod: number;
  readonly periodBlock: readonly number[];
  readonly repeatCount: number;
  readonly alternating: boolean;
  readonly runs: readonly DigitRun[];
  readonly uniqueDigitCount: number;
  readonly digitSum: number;
  readonly normalizedEntropy: number;
}

export interface ReflectionAxis {
  readonly index: number;
  readonly degrees: number;
  readonly kind: "nodes" | "edges";
}

export interface ComplementSymmetry {
  readonly kind: "rotation" | "reflection";
  readonly index: number;
}

export interface BinaryAnalysis {
  readonly value: number;
  /** LSB-first, matching the radial core's clockwise node order. */
  readonly fixedBits: readonly number[];
  /** MSB-first, with leading zeroes removed except for zero itself. */
  readonly significantBits: readonly number[];
  readonly fixedWord: string;
  readonly significantWord: string;
  readonly popcount: number;
  readonly linearRuns: readonly DigitRun[];
  readonly cyclicRuns: readonly DigitRun[];
  readonly fixedPalindrome: boolean;
  readonly significantPalindrome: boolean;
  readonly rotationalPeriod: number;
  readonly significantPeriod: number;
  readonly reflectionAxes: readonly ReflectionAxis[];
  readonly alternating: boolean;
  readonly significantAlternating: boolean;
  readonly complementSymmetries: readonly ComplementSymmetry[];
  readonly complement: number;
}

export interface EqualDigitGroup {
  readonly residue: number;
  readonly radices: readonly number[];
}

export interface PhaseConjunction {
  readonly radices: readonly [number, number];
  readonly distance: number;
}

export interface ResonanceComponents {
  readonly binary: number;
  readonly withinBases: number;
  readonly crossBase: number;
}

export interface CompositeAnalysis {
  readonly value: number;
  readonly binary: BinaryAnalysis;
  readonly radices: readonly RadixAnalysis[];
  readonly lcm: number;
  readonly product: number;
  readonly outerPhase: number;
  readonly supercycleIndex: number;
  readonly pairwiseGcd: readonly (readonly number[])[];
  readonly pairwisePhaseDistances: readonly (readonly number[])[];
  readonly equalDigitGroups: readonly EqualDigitGroup[];
  readonly phaseConjunctions: readonly PhaseConjunction[];
  readonly resonanceComponents: ResonanceComponents;
  readonly resonanceScore: number;
}

export interface TemporalFrame {
  readonly id: "lunar" | "year" | "saros" | "custom";
  readonly label: string;
  readonly days: number;
}

export interface TemporalAnalysis {
  readonly frame: TemporalFrame;
  readonly normalizedPhase: number;
  readonly degrees: number;
  readonly elapsedDays: number;
  readonly remainingDays: number;
  readonly binDurationSeconds: number;
}

export type EventFilterId =
  | "binary-palindrome"
  | "binary-symmetry"
  | "repdigit"
  | "radix-palindrome"
  | "repeated-block"
  | "residue-conjunction"
  | "phase-conjunction";

export type EventFilterMode = "and" | "or";

export interface StructuralEvent {
  readonly value: number;
  readonly labels: readonly string[];
  readonly score: number;
}

