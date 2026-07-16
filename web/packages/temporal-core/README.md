# `@exeligmos/temporal-core`

Pure Saros clock, storage-address, and rarity semantics for the Exeligmos web analytics application.
The package contains no React, DOM, networking, locale, timezone, or wall-clock dependency. Every
timestamp and interval is supplied by the caller as epoch seconds.

All constants and vocabulary come from `@exeligmos/domain-catalog`, which is generated from the root
`domain-spec/catalog.json`. Do not copy depth bounds, the radix, unit exponents, rarity names,
semantic tokens, or address rules into this package or its consumers.

## Depth and address contracts

- `clockReading` and `assertCalculationDepth` reject depths outside the catalog's calculation range
  (`1...8` in catalog 1.0.0).
- presentation, storage-address, and rarity operations clamp to the catalog's presentation range
  (`3...8`).
- canonical and rarity-aware storage retain the **leftmost** radix digits and pad on the **right**;
- rarity classification retains the **leftmost** digits but pads on the **left** before suffix
  analysis;
- glyph normalization retains the rightmost digits and belongs to `@exeligmos/glyph-core`, not this
  package.

These distinctions are compatibility behavior, not interchangeable formatting choices.

## Recommended API

Use the bound immutable engine in application code:

```ts
import { canonicalTemporalEngine } from "@exeligmos/temporal-core";

const reading = canonicalTemporalEngine.clockReading({
  previousEpochSeconds: 0,
  nextEpochSeconds: 512,
  instantEpochSeconds: 256,
  harmonicDepth: 7,
});

const rarity = canonicalTemporalEngine.classifyRarity({
  octalAddress: reading.octalAddress,
  harmonicDepth: reading.harmonicDepth,
});
```

Standalone functions accept a `DomainCatalog` as their first argument for conformance testing or
future catalog-version inspection. `createTemporalEngine` binds those functions to a catalog without
introducing mutable state.

## Boundary behavior

- an all-zero address is `mythic-7` (`Omega Nihil`);
- a positive address ending in zero classifies the immediately preceding octal address;
- a repeated suffix with more than three wildcard-prefix digits is common;
- rarity headers use repeated digit zero for identity/rank, but their glyph address uses the
  catalog's header glyph digit;
- instants after the next interval boundary remain in the final bin and can return a negative
  `timeUntilNextFlip`.

The package test suite loads the generated `canonicalConformance` artifact (sourced from
`domain-spec/conformance/v1.json`) and executes every temporal, storage-address, and rarity vector.
Floating-point results use the vector contract's scaled tolerance.
