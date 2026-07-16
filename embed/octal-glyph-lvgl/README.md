# octal-glyph-lvgl

An LVGL widget that renders **OctalGlyphs** -- the radial "core ring + up to
8 digit arms" glyph used across Exeligmos -- at a specified depth and color,
with **zero dependencies beyond LVGL itself**.

The glyph is a fixed 120x120px composite: a live-drawn ring (`lv_draw_arc`)
plus up to 8 digit-arm **sprites** -- small pre-rendered PROGMEM bitmaps,
baked offline, rotated onto their socket at draw time with `lv_draw_image`.
There is no shape geometry left to compute at runtime at all. This is a
deliberate stylistic simplification of
[`@exeligmos/glyph-core`](../../web/packages/glyph-core)'s SVG artwork, not
a pixel-for-pixel port -- see "Rendering approach" below for the history and
trade-offs of the three designs this library has gone through.

## Rendering approach

`@exeligmos/glyph-core` produces even-odd-filled SVG paths. Microcontrollers
don't have an SVG stack, and LVGL's only path/vector-fill renderer
(`LV_USE_VECTOR_GRAPHIC`) pulls in ThorVG, a sizeable C++ library that's off
by default and heavy for small displays. This library has tried three
different ways around that, each replacing the last:

1. **Triangulated fill.** Ear-clipping the glyph's filled polygons (with a
   hole-bridging step for the core ring) and painting the result with
   `lv_draw_triangle`. It worked, but adjacent same-color triangles each
   anti-alias their shared edge independently, leaving faint seam lines no
   amount of vertex-nudging fully closed, and re-triangulating up to ~9
   shapes (90+ triangles worst case) on every redraw was measurably slow.
2. **Stroked lines.** Drawing the core as a single ring (`lv_draw_arc`) and
   each arm as a short rounded-cap polyline (`lv_draw_line`). No triangle
   mesh, no seams (LVGL draws a round cap as a solid filled circle, so
   overlapping caps at a shared joint don't blend), and about 40% faster.
   Still, every redraw recomputed each arm's rotated points from scratch.
3. **Pre-rendered sprites (current).** Each non-zero digit's arm shape is
   rasterized *once*, offline, into a small alpha-only (`LV_COLOR_FORMAT_A8`)
   bitmap baked into flash (`tools/bake_sprites.py` -> `octal_glyph_sprites.h`,
   `static const ... OG_SPRITE_PROGMEM`). At draw time there's no shape math
   left: look up the sprite for the digit, and hand it to `lv_draw_image`
   with a `rotation` of `socket_index * 360/depth` and a `pivot` placed at
   the glyph's on-screen center. LVGL's image transform keeps the pivot's
   screen position fixed while everything else swings around it, so a
   single rotated-image draw reproduces both the arm's position on the ring
   *and* its orientation -- no runtime trigonometry for placement at all,
   just a lookup and a multiply. Measured on the host benchmark harness
   (6 glyphs, depth 7, increment-and-redraw every iteration):

   | version | avg time / iteration |
   |---|---|
   | triangulated fill | ~1122 us |
   | stroked lines | ~689 us |
   | pre-rendered sprites | ~336 us |

The trade-off, unchanged since design (2): the original SVG artwork only
exists as hand-authored filled polygons (flags, zigzags, hooks per digit) --
there's no centerline/stroke path upstream to reuse, so the arm shapes are
new, simplified art rather than a port. They're designed to preserve each
digit's general identity (0 = empty, 1/4 = simple mirrored flicks,
2 = straight spike, 3/5 = mirrored zigzags, 6 = spike+hook, 7 = most
elaborate/longest reach) rather than reproducing the exact silhouette.

The glyph also now renders at a **fixed 120x120px canvas** regardless of the
widget's own size -- sprites are baked pixels, not vectors, so there's no
cheap way to rescale them yet. Give the widget a size >= 120x120 so nothing
clips; arbitrary scaling could be added later via `lv_draw_image`'s
`scale_x`/`scale_y` if needed.

## Architecture

- `octal_glyph_catalog.h` -- the ring's baked pixel radius/width
  (`OG_CORE_RADIUS_PX`, `OG_CORE_RING_WIDTH_PX`) plus the "design space"
  constants `tools/bake_sprites.py` was authored against (only relevant if
  re-baking). No dependencies at all.
- `octal_glyph_geometry.{h,c}` -- the tiny bit of math still needed at
  runtime: depth clamping, octal digit extraction, and the
  socket-index -> digitIndex mapping. No LVGL dependency; unit-testable on
  a host machine.
- `octal_glyph_sprites.h` -- **generated** by `tools/bake_sprites.py`. Do not
  hand-edit. One `static const uint8_t ... OG_SPRITE_PROGMEM` byte array per
  non-zero digit (A8 alpha, cropped to its own bounding box) plus a lookup
  table (`og_arm_sprites[7]`) with each sprite's width/height/pivot.
- `octal_glyph_progmem.h` -- defines `OG_SPRITE_PROGMEM` to the framework's
  `PROGMEM` if one is defined (Arduino cores), otherwise to nothing, so the
  sprite header compiles under Arduino, plain ESP-IDF, or a host test
  without a hard Arduino.h dependency.
- `lv_octal_glyph.{h,c}` (+ `lv_octal_glyph_private.h`) -- the actual LVGL
  widget (`lv_obj_class`). This is the only file that includes `lvgl.h`; it
  calls `lv_draw_arc` once for the ring and `lv_draw_image` once per active
  arm.
- `tools/bake_sprites.py` -- the offline bake script (Python + Pillow).
  Rasterizes each digit's arm at 4x supersampling for smooth anti-aliased
  edges, downsamples, auto-crops to its bounding box, and emits
  `octal_glyph_sprites.h`. Run it from the `tools/` directory; it writes
  into `../src/` and drops PNG previews next to itself for a quick visual
  check. Re-run it if you change the arm templates, canvas size, stroke
  width, or bake scale (all defined near the top of the script; keep them
  in sync with `octal_glyph_catalog.h`'s `OG_LOCAL_*` constants).

## Usage

```c
#include "lv_octal_glyph.h"

lv_obj_t *glyph = lv_octal_glyph_create(parent);
lv_obj_set_size(glyph, 120, 120);                /* fixed canvas size */
lv_octal_glyph_set_depth(glyph, 7);              /* depth: 3-8 */
lv_octal_glyph_set_value(glyph, 01422222);       /* octal literal -- digits shown: 1422222 */
lv_octal_glyph_set_colors(glyph,                 /* color */
                          lv_color_hex(0xFFFFFF), /* primary (arms) */
                          lv_color_hex(0x8E8E93));/* secondary (core + split remainder) */
```

Optional split coloring (mirrors `splitSemanticGlyphStyle`): arms whose
digit index is below the split count use the primary color, the rest use
secondary.

```c
lv_octal_glyph_set_split(glyph, 2);
```

`lv_octal_glyph_set_value` takes a plain `uint32_t` -- its base-8 (octal)
digits are what's displayed, truncated to the rightmost `depth` digits and
left-padded with zeros (e.g. depth 5, value `15` -> `"00017"`, since decimal
15 is octal 17). Write value literals in octal (`0754`) if you want to
eyeball which digits will show; `lv_octal_glyph_get_value` returns the same
`uint32_t` back.

## Verification

- Octal normalization (`og_octal_digits_from_value`, unchanged since the
  very first version) is still diffed against a golden JSON generated by
  running the real `geometry.ts` through Node -- 22 cases across every
  depth, edge cases, and split-style coloring all match on
  `normalizedValue`/`depth`.
- `og_digit_index_for_socket` is checked against the documented mapping for
  every socket at every supported depth (3-8), and `og_clamp_depth`'s
  boundary behavior is checked directly.
- The baked sprite table itself is sanity-checked: all 7 non-zero digits
  present, dimensions and pivot in a plausible range, data non-null, and
  every sprite has at least one visible (non-transparent) pixel -- catching
  a silently-empty bake.
- End-to-end rendering was visually confirmed via a headless LVGL harness
  (plain gcc + LVGL core, no SDL2/ThorVG) that dumps the framebuffer to
  PNG, including a pixel-level close-up crop to check the rotated sprites
  for seams or artifacts up close (none found -- rotation is a single
  atomic image blit, so there's nothing to seam in the first place).

## Benchmark

`esp32-c6-lcd`'s `benchmark` PlatformIO environment
(`src/benchmark_main.cpp`) creates 6 persistent glyphs (depth 7) on the real
display once, then every `loop()` iteration bumps all 6 values and forces an
immediate synchronous redraw with `lv_refr_now()` -- no throttling, no
recreated widgets, just "update + render 6 glyphs" as fast as the board can
go. Throughput is accumulated over a rolling ~500ms window and reported both
over Serial (CSV: `elapsed_ms,total_updates,updates_per_sec,avg_render_us`)
and on the display. Build/flash with:

```sh
pio run -e benchmark -t upload
pio device monitor
```

## Reuse on other devices

This library only calls `lv_obj_*`, `lv_draw_arc`, `lv_draw_image`, and
standard color/style APIs, so it works on any LVGL 9 project regardless of
display driver, MCU, or board. On PlatformIO, add it via `lib_deps` (e.g.
`symlink://../octal-glyph-lvgl` for a sibling-directory checkout during
development, or a git URL once published).
