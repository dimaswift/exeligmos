import { describe, expect, it } from "vitest";

import { canonicalConformance } from "@exeligmos/domain-catalog";

import { runCanonicalConformance } from "./conformance.js";

describe("canonical web engine conformance", () => {
  it("executes every generated vector through production code", () => {
    const results = runCanonicalConformance();
    const failures = results.filter((result) => !result.passed);

    expect(results).toHaveLength(canonicalConformance.vectors.length);
    expect(results).toHaveLength(40);
    expect(failures).toEqual([]);
  });

  it("covers every operation declared by the generated contract", () => {
    const expectedOperations = new Set(
      canonicalConformance.vectors.map((vector) => vector.operation),
    );
    const actualOperations = new Set(runCanonicalConformance().map((result) => result.operation));

    expect(actualOperations).toEqual(expectedOperations);
  });
});
