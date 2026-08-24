import { describe, expect, it } from "vitest";

import { parseHistoryQuery, searchHistory } from "./history.server";

describe("history search", () => {
  it("treats a six-digit primary search as an octal address", () => {
    const query = parseHistoryQuery("https://example.test/history?q=774112");

    expect(query.text).toBe("");
    expect(query.searchInput).toBe("");
    expect(query.radix).toBe(8);
    expect(query.address).toBe("774112");
    expect(query.warnings).toEqual([]);
  });

  it("keeps a repeated exact-address form submission idempotent", () => {
    const query = parseHistoryQuery(
      "https://example.test/history?q=774112&address=774112&saros=&country=&type=&outcome=",
    );

    expect(query.text).toBe("");
    expect(query.address).toBe("774112");
    expect(query.warnings).toEqual([]);
  });

  it("reports invalid address and Saros filters without executing malformed input", () => {
    const query = parseHistoryQuery(
      "https://example.test/history?radix=2&address=128999&saros=zero&page=-1",
    );

    expect(query.address).toBe("");
    expect(query.saros).toBeUndefined();
    expect(query.page).toBe(1);
    expect(query.warnings).toEqual([
      "Address contains a digit that is not valid in base 2.",
      "Saros must be a whole number.",
      "Page must be a whole number.",
    ]);
  });

  it("finds event text through the full-text index", () => {
    const result = searchHistory(
      parseHistoryQuery("https://example.test/history?q=Battle%20of%20Panipat"),
    );

    expect(result.total).toBeGreaterThan(0);
    expect(result.events.some((event) => event.title === "Battle of Panipat")).toBe(true);
    expect(result.metadata).toMatchObject({ eventCount: 1096, locationCount: 44471 });
  });

  it("returns only corresponding Saros series for an exact octal address", () => {
    const result = searchHistory(parseHistoryQuery("https://example.test/history?address=774112"));
    const panipat = result.events.find((event) => event.title === "Battle of Panipat");

    expect(panipat).toBeDefined();
    expect(panipat?.locations).toContainEqual({ saros: 100, address: "774112", radix: 8 });
    expect(panipat?.locations.every((location) => location.address === "774112")).toBe(true);
  });

  it("combines address prefix, Saros, and catalog filters", () => {
    const result = searchHistory(
      parseHistoryQuery(
        "https://example.test/history?address=774&saros=100&country=India&type=Battle",
      ),
    );

    expect(result.events.length).toBeGreaterThan(0);
    expect(
      result.events.every(
        (event) =>
          event.country === "India" &&
          event.eventType === "Battle" &&
          event.locations.every(
            (location) => location.saros === 100 && location.address.startsWith("774"),
          ),
      ),
    ).toBe(true);
  });

  it("converts and searches the same Saros phase in a custom radix", () => {
    const textResult = searchHistory(
      parseHistoryQuery("https://example.test/history?q=Battle%20of%20Panipat&radix=16"),
    );
    const panipat = textResult.events.find((event) => event.title === "Battle of Panipat");
    const location = panipat?.locations.find((candidate) => candidate.saros === 100);

    expect(location).toMatchObject({ saros: 100, radix: 16 });
    expect(location?.address).toMatch(/^[0-9A-F]{6}$/);

    const addressResult = searchHistory(
      parseHistoryQuery(
        `https://example.test/history?radix=16&address=${location?.address ?? ""}&saros=100`,
      ),
    );
    expect(addressResult.events.some((event) => event.title === "Battle of Panipat")).toBe(true);
    expect(
      addressResult.events.every((event) =>
        event.locations.every(
          (candidate) =>
            candidate.radix === 16 &&
            candidate.address === location?.address &&
            candidate.saros === 100,
        ),
      ),
    ).toBe(true);
  });

  it("accepts alphanumeric digits up to base 36 and normalizes case", () => {
    const query = parseHistoryQuery("https://example.test/history?radix=36&address=z7q2");

    expect(query.radix).toBe(36);
    expect(query.address).toBe("Z7Q2");
    expect(query.warnings).toEqual([]);
  });
});
