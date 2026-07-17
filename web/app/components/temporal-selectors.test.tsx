import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";

import {
  LowestRaritySelector,
  stepTemporalPeriod,
  TemporalPeriodSelector,
} from "./temporal-selectors";

describe("TemporalPeriodSelector", () => {
  it("steps through the ordered scale and remains bounded", () => {
    expect(stepTemporalPeriod("mili", -1)).toBe("mili");
    expect(stepTemporalPeriod("mili", 1)).toBe("saros");
    expect(stepTemporalPeriod("mega", -1)).toBe("kilo");
    expect(stepTemporalPeriod("mega", 1)).toBe("giga");
    expect(stepTemporalPeriod("tera", 1)).toBe("tera");
  });

  it("renders accessible controls and disables the bounded edge", () => {
    const markup = renderToStaticMarkup(<TemporalPeriodSelector onChange={vi.fn()} value="mili" />);

    expect(markup).toContain('role="group"');
    expect(markup).toContain('aria-label="Temporal period"');
    expect(markup).toContain('aria-label="Smaller period than Mili"');
    expect(markup).toContain('aria-label="Larger period than Mili"');
    expect(markup).toContain("disabled");
    expect(markup).toContain("Mili");
  });
});

describe("LowestRaritySelector", () => {
  it("renders one native radio for every supported threshold", () => {
    const markup = renderToStaticMarkup(<LowestRaritySelector onChange={vi.fn()} value="duplex" />);

    expect(markup).toContain("<legend>Lowest rarity</legend>");
    for (const value of ["triplex", "duplex", "simplex", "nihil"] as const) {
      expect(markup).toContain(`value="${value}"`);
    }
    expect(markup).toMatch(/checked="" value="duplex"|value="duplex" checked=""/);
  });
});
