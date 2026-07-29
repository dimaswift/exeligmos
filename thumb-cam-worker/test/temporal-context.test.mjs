import assert from "node:assert/strict";
import test from "node:test";

import {
  recordTemporalContextAt,
  solarTemporalDataMetadata,
} from "../src/temporal-context.mjs";

test("derives canonical archive-ready Saros context from capture time", () => {
  const context = recordTemporalContextAt("2026-07-16T20:54:55.000Z");

  assert.deepEqual(solarTemporalDataMetadata, {
    sourceSha256:
      "cf8ca294b6537f7b98e68b791d71448b065d8c445d4b48e49775365da9663b43",
    seriesCount: 180,
    eclipseCount: 13_206,
  });
  assert.deepEqual(context.closestSarosPhase, {
    saros: 122,
    octalAddress: "32555606",
    harmonicDepth: 8,
    rarityRawValue: "common",
  });
  assert.deepEqual(
    context.spikes.map((spike) => ({
      saros: spike.saros,
      octalAddress: spike.octalAddress,
      harmonicDepth: spike.harmonicDepth,
    })),
    [
      { saros: 117, octalAddress: "34333333", harmonicDepth: 8 },
      { saros: 122, octalAddress: "32555555", harmonicDepth: 8 },
      { saros: 141, octalAddress: "72444444", harmonicDepth: 8 },
      { saros: 146, octalAddress: "70666666", harmonicDepth: 8 },
    ],
  );

  // These are the exact fields consumed by the plain archive's Saros index.
  for (const phase of [context.closestSarosPhase, ...context.spikes]) {
    assert.ok(Number.isSafeInteger(phase.saros) && phase.saros > 0);
    assert.equal(phase.harmonicDepth, 8);
    assert.match(phase.octalAddress, /^[0-7]{8}$/);
  }
});

test("rejects invalid and out-of-catalog capture instants", () => {
  assert.throws(
    () => recordTemporalContextAt("not a timestamp"),
    /valid instant/,
  );
  assert.throws(
    () => recordTemporalContextAt("5000-01-01T00:00:00.000Z"),
    /outside the canonical eclipse dataset/,
  );
});
