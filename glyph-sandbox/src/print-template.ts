export type PrintTemplateMode = "blank" | "guided";
export type PrintPaper = "a4" | "letter";
export type PrintDotSize = "small" | "medium" | "large";
export type PrintNumberGroup =
  | "odd"
  | "even"
  | "composite"
  | "prime"
  | "squarefree"
  | "perfect-square"
  | "abundant"
  | "deficient"
  | "perfect";

export interface PrintNumberGroupDefinition {
  readonly id: PrintNumberGroup;
  readonly label: string;
  readonly mark: string;
}

/** Compact monochrome marks that remain distinguishable on a dense printed sheet. */
export const PRINT_NUMBER_GROUPS: readonly PrintNumberGroupDefinition[] = Object.freeze([
  { id: "odd", label: "Odd", mark: "○" },
  { id: "even", label: "Even", mark: "●" },
  { id: "composite", label: "Composite", mark: "×" },
  { id: "prime", label: "Prime", mark: "+" },
  { id: "squarefree", label: "Squarefree", mark: "◇" },
  { id: "perfect-square", label: "Perfect square", mark: "□" },
  { id: "abundant", label: "Abundant", mark: "▲" },
  { id: "deficient", label: "Deficient", mark: "▼" },
  { id: "perfect", label: "Perfect", mark: "=" },
]);

interface TemplateEntriesOptions {
  readonly mode: PrintTemplateMode;
  readonly radix: number;
  readonly capacity: number;
  readonly startDigit: number;
}

export function clampTemplateStart(startDigit: number, radix: number): number {
  const safeRadix = Math.max(1, Math.trunc(radix));
  const safeStart = Number.isFinite(startDigit) ? Math.trunc(startDigit) : 0;
  return Math.min(safeRadix - 1, Math.max(0, safeStart));
}

/** Keeps a stable page grid while using null for blank or out-of-range practice cells. */
export function makeTemplateEntries({
  mode,
  radix,
  capacity,
  startDigit,
}: TemplateEntriesOptions): readonly (number | null)[] {
  const safeCapacity = Math.min(40, Math.max(1, Math.trunc(capacity)));
  if (mode === "blank") return Object.freeze(Array<number | null>(safeCapacity).fill(null));
  const start = clampTemplateStart(startDigit, radix);
  return Object.freeze(
    Array.from({ length: safeCapacity }, (_, index) => {
      const digit = start + index;
      return digit < radix ? digit : null;
    }),
  );
}

export function dotRadiusForSize(size: PrintDotSize): number {
  switch (size) {
    case "small":
      return 3.2;
    case "medium":
      return 4.8;
    case "large":
      return 6.6;
  }
}

/** Returns overlapping arithmetic groups in the same stable order as the print legend. */
export function numberGroupsFor(value: number): readonly PrintNumberGroup[] {
  if (!Number.isSafeInteger(value) || value < 0) return Object.freeze([]);

  const groups = new Set<PrintNumberGroup>();
  groups.add(value % 2 === 0 ? "even" : "odd");

  const prime = isPrime(value);
  if (prime) groups.add("prime");
  if (value > 1 && !prime) groups.add("composite");
  if (value >= 1 && isSquarefree(value)) groups.add("squarefree");
  if (Number.isInteger(Math.sqrt(value))) groups.add("perfect-square");

  if (value >= 1) {
    const properDivisorSum = sumProperDivisors(value);
    if (properDivisorSum > value) groups.add("abundant");
    else if (properDivisorSum < value) groups.add("deficient");
    else groups.add("perfect");
  }

  return Object.freeze(
    PRINT_NUMBER_GROUPS
      .map((definition) => definition.id)
      .filter((group) => groups.has(group)),
  );
}

function isPrime(value: number): boolean {
  if (value < 2) return false;
  if (value === 2) return true;
  if (value % 2 === 0) return false;
  for (let divisor = 3; divisor * divisor <= value; divisor += 2) {
    if (value % divisor === 0) return false;
  }
  return true;
}

function isSquarefree(value: number): boolean {
  for (let divisor = 2; divisor * divisor <= value; divisor += 1) {
    if (value % (divisor * divisor) === 0) return false;
  }
  return true;
}

function sumProperDivisors(value: number): number {
  if (value === 1) return 0;
  let sum = 1;
  for (let divisor = 2; divisor * divisor <= value; divisor += 1) {
    if (value % divisor !== 0) continue;
    sum += divisor;
    const counterpart = value / divisor;
    if (counterpart !== divisor) sum += counterpart;
  }
  return sum;
}
