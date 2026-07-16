import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import { createOctalGlyph, splitSemanticGlyphStyle } from "@exeligmos/glyph-core";

import { defaultGlyphColor, GlyphRenderer, type GlyphRendererStyle } from "./glyph-renderer.js";

describe("GlyphRenderer", () => {
  it("renders accessible fill-only SVG with separate catalog label and normalized value", () => {
    const model = createOctalGlyph({ value: "17", depth: 5, rarityId: "common" });
    const markup = renderToStaticMarkup(<GlyphRenderer model={model} size={32} />);

    expect(markup).toContain('role="img"');
    expect(markup).toContain('width="32"');
    expect(markup).toContain('height="32"');
    expect(markup).toContain('viewBox="-192 -200 384 400"');
    expect(markup).toContain(">Octal glyph</title>");
    expect(markup).toContain(">00017</desc>");
    expect(markup).toMatch(/aria-labelledby="([^"]+)-glyph-title"/);
    expect(markup).toMatch(/aria-describedby="([^"]+)-glyph-value"/);
    expect(markup).toContain('fill-rule="evenodd"');
    expect(markup).not.toContain("stroke=");
  });

  it("omits digit-zero arms and retains the core hole in one path", () => {
    const markup = renderToStaticMarkup(
      <GlyphRenderer model={createOctalGlyph({ value: "000", depth: 3, rarityId: "common" })} />,
    );
    expect(markup.match(/<path/g)).toHaveLength(1);
    const coreData = markup.match(/<path[^>]+d="([^"]+)"/)?.[1] ?? "";
    expect(coreData.match(/\bM\b/g)).toHaveLength(2);
    expect(coreData.match(/\bZ\b/g)).toHaveLength(2);
  });

  it("supports explicit decorative mode without leaking accessible metadata", () => {
    const markup = renderToStaticMarkup(
      <GlyphRenderer
        accessibilityLabel="Ignored label"
        decorative
        model={createOctalGlyph({ value: "777", depth: 3, rarityId: "common" })}
      />,
    );
    expect(markup).toContain('aria-hidden="true"');
    expect(markup).not.toContain('role="img"');
    expect(markup).not.toContain("<title");
    expect(markup).not.toContain("<desc");
    expect(markup).not.toContain("aria-labelledby");
  });

  it("is responsive, styleable, and exposes stable semantic hooks", () => {
    const style: GlyphRendererStyle = {
      "--glyph-primary": "hotpink",
      display: "block",
    };
    const markup = renderToStaticMarkup(
      <GlyphRenderer
        accessibilityLabel="Solar phase"
        className="solar-glyph"
        height="auto"
        model={createOctalGlyph({ value: "12345", depth: 5, rarityId: "mythic-7" })}
        style={style}
        width="100%"
      />,
    );
    expect(markup).toContain('class="solar-glyph"');
    expect(markup).toContain('width="100%"');
    expect(markup).toContain('height="auto"');
    expect(markup).toContain("--glyph-primary:hotpink");
    expect(markup).toContain(">Solar phase</title>");
    expect(markup).toContain('data-glyph-depth="5"');
    expect(markup).toContain('data-glyph-value="12345"');
    expect(markup).toContain("--exeligmos-color-rarity-mythic-omega");
  });

  it("allows a renderer-level color resolver without changing geometry", () => {
    const model = createOctalGlyph({
      value: "11111",
      depth: 5,
      style: splitSemanticGlyphStyle("color.digit.1", "color.digit.2", 2),
    });
    const markup = renderToStaticMarkup(
      <GlyphRenderer
        colorForRole={(role) => (role === "primary" ? "#123456" : "#abcdef")}
        model={model}
      />,
    );
    expect(markup).toContain('data-color-role="primary"');
    expect(markup).toContain('data-color-role="secondary"');
    expect(markup).toContain('fill="#123456"');
    expect(markup).toContain('fill="#abcdef"');
  });

  it("uses collision-free SSR accessibility identifiers for sibling glyphs", () => {
    const model = createOctalGlyph({ value: "765", depth: 3, rarityId: "common" });
    const markup = renderToStaticMarkup(
      <div>
        <GlyphRenderer model={model} />
        <GlyphRenderer model={model} />
      </div>,
    );
    const ids = [...markup.matchAll(/\sid="([^"]+)"/g)].map((match) => match[1]);
    const references = [...markup.matchAll(/\saria-(?:labelledby|describedby)="([^"]+)"/g)].map(
      (match) => match[1],
    );
    expect(ids).toHaveLength(4);
    expect(new Set(ids).size).toBe(4);
    expect(references.toSorted()).toEqual(ids.toSorted());
  });

  it("normalizes invalid numeric dimensions and is deterministic under SSR", () => {
    const model = createOctalGlyph({ value: "555", depth: 3, rarityId: "common" });
    const first = renderToStaticMarkup(
      <GlyphRenderer height={Number.NaN} model={model} size={0} width={-2} />,
    );
    const second = renderToStaticMarkup(
      <GlyphRenderer height={Number.NaN} model={model} size={0} width={-2} />,
    );
    expect(first).toBe(second);
    expect(first).toContain('width="1em"');
    expect(first).toContain('height="1em"');
  });

  it("renders every supported presentation depth", () => {
    for (const depth of [3, 4, 5, 6, 7, 8]) {
      const markup = renderToStaticMarkup(
        <GlyphRenderer
          model={createOctalGlyph({
            value: "7".repeat(depth),
            depth,
            rarityId: "common",
          })}
        />,
      );
      expect(markup).toContain(`data-glyph-depth="${depth}"`);
      expect(markup.match(/<path/g)).toHaveLength(depth + 1);
    }
  });
});

describe("defaultGlyphColor", () => {
  it("nests a role override over the catalog semantic token and fallback", () => {
    expect(
      defaultGlyphColor("primary", {
        semanticToken: "color.rarity.duplex",
        fallbackSrgb: "#007AFF",
      }),
    ).toBe("var(--glyph-primary, var(--exeligmos-color-rarity-duplex, #007AFF))");
  });
});
