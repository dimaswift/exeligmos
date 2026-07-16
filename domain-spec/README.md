# Exeligmos domain specification

This directory is the language-neutral source of truth for Exeligmos temporal
units, harmonic depths, rarity semantics, octal glyph geometry, and numeric
event-type registration. UI code may format or arrange these concepts, but it
must not redefine their values or infer a second taxonomy.

The current catalog is a faithful foundation extracted from the Swift app. It
does not yet replace the Swift implementation; conformance vectors provide the
bridge until Swift and TypeScript consumers are generated from, or checked
against, this contract.

## Files

- [`catalog.json`](catalog.json) is the canonical, versioned data catalog.
- [`catalog.schema.json`](catalog.schema.json) is its JSON Schema Draft 2020-12
  contract.
- [`conformance/v1.json`](conformance/v1.json) contains behavior vectors copied
  from current XCTest expectations and implementation boundary behavior.
- [`conformance/vectors.schema.json`](conformance/vectors.schema.json) validates
  the vector envelope.
- [`scripts/validate.mjs`](scripts/validate.mjs) validates both schemas, checks
  cross-reference and registry invariants, and executes every vector.

The source implementations used for this first catalog are:

- [`JournalSettings`, `SarosPulseUnit`, `FlipRarity`, and `OctalGlyphGeometry`](../SarosHarmonicJournal/Views/SharedViews.swift)
- [`SarosClockCalculator`](../SarosHarmonicJournal/Domain/SarosClock.swift)
- [the server event type wire contract](../sync-server/openapi/openapi.yaml)

## Validation

```sh
cd domain-spec
npm ci
npm test
```

The only development dependency is Ajv. The test performs full Draft 2020-12
schema validation, then checks invariants that JSON Schema cannot express
concisely, including unique semantic IDs, valid token references, contiguous
event ranges, non-overlapping producer allocations, and role/order agreement.

It also executes the catalog-driven reference implementation against the
conformance vectors. The final SHA-256 is suitable for diagnostics or as the
basis of a future catalog endpoint ETag; it is not a substitute for
`catalogVersion`.

## Compatibility and versioning

There are two versions with different purposes:

- `schemaVersion` changes only when the structure itself becomes incompatible.
  Consumers must reject unsupported schema versions.
- `catalogVersion` follows semantic versioning. A major version can change an
  existing meaning or algorithm, a minor version can add types, tokens, or
  allocations, and a patch version can clarify descriptions without changing
  behavior.

Published IDs are permanent. A time-unit ID, semantic-token ID, rarity ID, or
numeric event type must never be reassigned to a different meaning. Deprecated
entries remain resolvable.

Every consumer should expose both versions in diagnostics. Persisted resources
that depend on an interpretation should store `catalogVersion` in metadata when
reproducibility matters.

## Temporal model

The catalog deliberately separates two depth ranges that were previously easy
to conflate:

- clock calculations accept harmonic depths `1...8`;
- application presentation and glyph rendering clamp to `3...8`, default to
  `7`, and use `8` as the canonical stored/display depth.

Address normalization also has two distinct contracts:

- canonical and rarity-aware storage retain the leftmost octal digits and pad
  on the right;
- glyph input retains the rightmost octal digits and pads on the left.

Changing either behavior alters existing glyphs and rarity classification, so
both are covered by vectors.

The base period is `6585.3211` days. Unit duration is:

```text
basePeriod.seconds / 8^unit.exponent
```

This means the unit whose legacy ID is `saros` is the average cycle divided by
`8^7`; it is not the full 6585-day cycle. The single-l spelling `mili` is also a
canonical legacy ID. Human-facing aliases can be corrected without changing
the persisted identifier.

## Rarity model

The five families retain the current wire IDs while the catalog owns their
display vocabulary:

| ID | Display family | Order | Wildcard prefix |
| --- | --- | ---: | ---: |
| `common` | Common | 0 | 7 |
| `rare` | Triplex | 3 | 3 |
| `epic` | Duplex | 4 | 2 |
| `legendary` | Simplex | 5 | 1 |
| `mythic` | Nihil | 6 | 0 |

Digits `1...7` add Alpha, Beta, Gamma, Delta, Epsilon, Digamma, and Omega
prefixes. Family colors and exact digit colors are referenced through semantic
tokens rather than copied into components. `mythic-7` keeps the Swift red color
override.

Rarity classification includes the current zero-boundary rule: a positive
address ending in zero classifies the immediately preceding address. The Swift
implementation also classifies an all-zero address as `mythic-7`; that perhaps
surprising behavior is explicit and tested rather than silently “fixed” during
the port.

## Glyph renderer contract

The glyph section contains all geometry needed by an SVG or native renderer:

- coordinate direction and rotation convention;
- socket/core dimensions and symmetric frame-padding rules;
- all eight arm polygons;
- the exact legacy seven-depth core hole;
- the inset rule used for other depths;
- digit-to-socket ordering, fill rule, split-color semantics, and accessibility
  value normalization.

Renderers should turn the catalog into immutable geometry primitives. They
must not contain rarity classification or time-unit logic. Geometry cache keys
must include `geometryVersion` and depth. Visual tests should cover every depth,
digit, semantic color mode, and malformed-input normalization case.

## Numeric event-type registry

The server stores a nonnegative signed 32-bit integer and requires clients to
preserve unknown future values. The catalog divides that space into contiguous
namespaces:

| Range | Purpose |
| --- | --- |
| `0...999` | cataloged core meanings |
| `1000...999999` | cataloged, project-reviewed integration meanings |
| `1000000...1999999999` | globally stable producer blocks allocated in groups of 1000 |
| `2000000000...2147483647` | provider-qualified experimental values |

Only type `0` (`core.unspecified`) is registered initially. An example in API
documentation does not implicitly reserve or define a number.

An automated public account such as `@sun` should use the workflow below:

1. During development, choose an experimental number and include provider
   metadata. The number alone has no global meaning.
2. Before publishing a durable integration, allocate the producer a block in
   `events.producerAllocations` or register shared meanings in the reviewed
   range.
3. Add each public meaning to `events.entries` in a minor catalog release.
   Never renumber it afterward.

Experimental metadata lives inside the event's existing `metadata` object:

```json
{
  "type": 2000000000,
  "metadata": {
    "eventType": {
      "namespace": "dev.exeligmos.sun",
      "name": "solar-flare",
      "version": 1,
      "label": "Solar flare"
    }
  }
}
```

The solar name above is a provider-qualified example, not a core catalog type.
Unknown numeric values must survive fetch, caching, filtering, realtime
delivery, and write-back unchanged. A client without a matching catalog entry
renders `Unknown event type {type}` with the generic semantic token. It may show
well-formed provider metadata as secondary context, but must not treat an
untrusted label or semantic token as authoritative styling.

## Consumer rules

1. Load and validate one catalog at application startup or build time.
2. Build typed indexes from catalog IDs; do not scatter string or numeric
   constants through features.
3. Keep temporal and glyph packages free of React, networking, locale, and the
   wall clock. Pass timestamps and presentation context explicitly.
4. Run these vectors in every independent implementation. Add a vector before
   changing a boundary rule.
5. Preserve unknown enum-like and numeric values at API boundaries even when
   the current UI cannot interpret them.

The realtime feed can then transport records and events without coupling its
wire protocol to a particular frontend release: known meanings enrich
immediately, while unknown meanings remain lossless until a newer catalog is
available.
