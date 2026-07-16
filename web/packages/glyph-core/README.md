# `@exeligmos/glyph-core`

Pure, immutable octal-glyph normalization, geometry, and semantic paint models for Exeligmos. The
package has no React, DOM, canvas, networking, locale, or wall-clock dependency. React/SVG output
lives in `@exeligmos/ui`.

All coordinates, arms, depth bounds, socket order, fill rules, accessibility text, rarity colors,
and semantic tokens come from `@exeligmos/domain-catalog`, generated from
`domain-spec/catalog.json`. Production callers must not duplicate those constants.

## Creating a glyph

Every glyph requires exactly one explicit color meaning: either a `rarityId` or a catalog-backed
`style`. The catalog does not currently define a generic default glyph color, so silently choosing
one would create a second source of truth.

```ts
import { createOctalGlyph, splitSemanticGlyphStyle } from "@exeligmos/glyph-core";

const rarityGlyph = createOctalGlyph({
  value: "1422222",
  depth: 7,
  rarityId: "epic-2",
});

const splitGlyph = createOctalGlyph({
  value: "1234567",
  depth: 7,
  style: splitSemanticGlyphStyle("color.digit.1", "color.digit.6", 3),
});
```

Unknown or legacy rarity input is resolved through the catalog and safely falls back to its common
rarity. Style constructors reject unknown semantic color tokens.

## Compatibility behavior

- Glyph input retains the **rightmost** octal digits and pads on the **left**. This deliberately
  differs from persisted address normalization in `@exeligmos/temporal-core`.
- Presentation depth is clamped to the catalog-supported glyph range (`3...8` in catalog 1.0.0).
- Socket order at depth `d` is `[0, d-1, d-2, ..., 1]`; split paint is selected by digit index, not
  socket index.
- Digit zero produces no arm polygon.
- The core and its hole are one even-odd path; arms are separate fill-only paths. Renderers must not
  add strokes.
- Geometry is deterministic, deeply frozen, and cached by `geometryVersion:depth`.
- Stable frame bounds include every arm template, so changing the address never changes layout.

## Rendering

`@exeligmos/ui` provides the SSR-safe SVG adapter:

```tsx
import { GlyphRenderer } from "@exeligmos/ui";

<GlyphRenderer model={rarityGlyph} size={160} />;
<GlyphRenderer decorative model={rarityGlyph} size="100%" />;
```

The default accessible form exposes the catalog label and normalized address separately with
collision-free SSR identifiers. Use `decorative` only when nearby text already provides equivalent
meaning. Semantic paints can be themed with `--glyph-primary`, `--glyph-secondary`, or the generated
semantic token variables without changing geometry.

The package tests execute every generated glyph conformance vector and cover all depths, all arm
digits, exact frame bounds, malformed input, split mapping, rarity overrides, immutability, and the
legacy seven-depth core hole. Renderer tests additionally enforce fill-only accessible SVG and
deterministic server rendering.
