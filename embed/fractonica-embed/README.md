# fractonica-embed

A zero-dependency C library for embedded Fractonica displays. Two modules,
usable independently or together:

1. **OctalGlyph rendering** (`octal_glyph_*`) -- renders the exact
   `@fractonica/glyph-core` radial glyph geometry (a "core ring + up to 8
   digit arms" shape) directly into a caller-owned ARGB8888 pixel buffer,
   plus a dirty-rect diff utility for fast, partial-redraw updates.
2. **Saros clock math** (`saros_*`) -- computes a Saros-eclipse-cycle
   phase-address (a 10-digit octal fraction of progress between a solar
   Saros series' eclipses) from UTC time, from a compact flash-resident
   eclipse dataset.

Everything in `src/` is pure ISO C99: no LVGL, no Arduino, no OS
dependency, no dynamic allocation beyond what you ask for. You own the
pixel buffer and the display driver call -- this library never touches
either. An optional LVGL widget wrapper is available separately (see
"Optional LVGL widget" below) for projects that prefer LVGL's own
display/flush pipeline instead of pushing pixels yourself.

## OctalGlyph rendering

### Rendering approach

`@fractonica/glyph-core` produces even-odd-filled polygons. Getting a
dependency-free, hardware-reliable renderer took five iterations; each of
the first four was replaced because it either didn't look close enough to
the original artwork or didn't actually work on real hardware, even though
each was a reasonable engineering trade at the time:

1. **Triangulated fill.** Ear-clipping the glyph's filled polygons (with a
   hole-bridging step for the core ring) and painting the result with
   `lv_draw_triangle`. Exact geometry, but adjacent same-color triangles
   each anti-alias their shared edge independently, leaving faint seam
   lines no amount of vertex-nudging fully closed, and re-triangulating up
   to ~9 shapes (90+ triangles worst case) on every redraw was measurably
   slow (~1122 us/iteration, 6 glyphs).
2. **Stroked lines.** Drawing the core as a single ring (`lv_draw_arc`) and
   each arm as a short rounded-cap polyline (`lv_draw_line`) -- a
   simplified, not-exact redesign of the arm art. No seams and ~40% faster
   (~689 us), but no longer resembled the original silhouette closely.
3. **Pre-rendered sprites.** Each non-zero digit's (still simplified) arm
   shape rasterized once, offline, into a small alpha-only bitmap baked into
   flash, composited with `lv_draw_image` at a rotation. Fastest of the
   three (~336 us) and zero runtime shape math, but locked to a fixed
   120x120px canvas (sprites are baked pixels, not vectors) and still not
   the real artwork.
4. **SVG + ThorVG.** Every shape's contours are exactly what `glyph-core`'s
   TypeScript computes -- no simplification, no re-triangulation, no fixed
   canvas. Serialized straight into an SVG `<path>` string and rendered
   through LVGL's native SVG decoder, backed by ThorVG's software
   rasterizer. This was a genuine pixel-for-pixel match to the original
   artwork in every host simulation -- but it never rendered on the real
   target hardware, with no crash, no log output even with LVGL's own
   logging enabled, and a clean build/flash. That failure mode gave no
   signal to chase, so the whole SVG/ThorVG dependency was dropped.
5. **Custom scanline rasterizer.** Same exact contours as design 4, but
   filled directly by `octal_glyph_raster.c`: 4x vertical supersampling
   plus exact horizontal fractional-pixel coverage per scanline, even-odd
   winding for the core ring's outer+hole, nonzero winding for each arm,
   composited with a straight-alpha "over" blend into a plain ARGB8888
   buffer. Verified pixel-perfect on host, through an LVGL widget wrapper
   -- but still invisible on the real board. Same silent failure as design
   4: clean build, clean flash, no crash, nothing on screen.
6. **Bypass the display library's flush layer entirely (current).** Two
   designs in a row working everywhere except the one place that mattered
   meant the bug was never in the rendering logic -- it was somewhere
   between the display library's flush callback and the physical panel, on
   that specific board. Talking straight to the display driver's raw
   pixel-push API (whatever that is on your board -- e.g. a
   `Display::drawPixels()`-style call) with this same rasterizer is the
   first design confirmed working on real hardware.

This library ships design 5's rasterizer (`octal_glyph_raster.c`) as its
core rendering primitive -- it's design-agnostic: hand its output to LVGL
as a raw image source (see "Optional LVGL widget"), or push it straight to
a display driver (design 6, and the approach this library is built around).

### Architecture

- `octal_glyph_catalog.h` -- the original filled-polygon geometry: core
  ring/hole constants and the per-digit arm outline templates
  (`og_arm_templates`), straight from `glyph-core`. No dependencies at all.
- `octal_glyph_geometry.{h,c}` -- builds the full glyph model (`og_glyph_t`:
  core ring + hole contours, one shape per active arm, frame bounds) from a
  numeric value/depth/split, mirroring `glyph-core`'s `insetConvexPolygon`,
  socket layout, and arm-to-world placement. Unit-testable on a host
  machine.
- `octal_glyph_raster.{h,c}` -- rasterizes an `og_glyph_t` directly into a
  caller-supplied ARGB8888 buffer (`og_glyph_rasterize`): contain-fit scales
  and centers the glyph's frame to the target box, then fills each shape
  with an anti-aliased scanline rasterizer, alpha-compositing straight
  (non-premultiplied) pixels with the standard "over" formula. Also
  declares `og_glyph_diff_rect` (see "Direct rendering" below).

### Usage

```c
#include "octal_glyph_geometry.h"
#include "octal_glyph_raster.h"

og_glyph_t model;
og_build_glyph(01422222, 7, 0, &model);  /* value (octal literal), depth 3-8, split (0 = off) */

uint8_t buf[130 * 130 * 4]; /* ARGB8888 (BGRA byte order), caller-owned */
og_glyph_rasterize(&model, 0xFFFFFF /* primary */, 0x8E8E93 /* secondary */, 130, 130, buf);
/* buf now holds a contain-fit-scaled, anti-aliased render of the glyph --
   push it to your display however you push pixels. */
```

`value`'s base-8 (octal) digits are what's displayed, truncated to the
rightmost `depth` digits and left-padded with zeros (e.g. depth 5, value
`15` -> `"00017"`, since decimal 15 is octal 17). Split coloring (mirrors
`splitSemanticGlyphStyle`): pass a nonzero `split_after_digit_count` to
`og_build_glyph` and arms whose digit index is below that count get
`OG_COLOR_PRIMARY`, the rest `OG_COLOR_SECONDARY` -- `og_glyph_rasterize`'s
two color arguments map to those roles (pass the same value for both if you
want a single flat color, as the Saros clock example below does).

### Direct rendering (dirty-rect updates)

For callers pushing pixels straight to a display driver (design 6 above),
`og_glyph_diff_rect` turns "redraw the whole glyph" into "redraw only what
changed":

```c
uint8_t front[W*H*4], back[W*H*4]; /* two ARGB8888 buffers */
/* front already matches what's on the physical panel. */

og_glyph_t model;
og_build_glyph(new_value, depth, split, &model);
og_glyph_rasterize(&model, primary_rgb, secondary_rgb, W, H, back);

og_dirty_rect_t r = og_glyph_diff_rect(front, back, W, H);
if (r.valid) {
    /* convert just back[r.x0..r.x1, r.y0..r.y1] to your pixel format and
       push only that rectangle to the display */
}
/* back is a complete, correct frame in its own right (not a patch) -- no
   copy needed, just swap the two pointers for the next update. */
```

This works because rasterization is deterministic and dither-free: the
core ring and any digit whose value didn't change produce bit-identical
pixels every time, so the diff is exactly (and only) the digit(s) that
actually changed. Since socket 0 always holds digit index 0 -- the
fastest-changing digit in a counter/clock use case -- and socket position
is fixed regardless of value (see `og_digit_index_for_socket` in
`octal_glyph_geometry.c`), a typical single-digit tick's dirty rectangle
lands in the same fixed region every time. Measured on host (depth 7,
130x130 box):

| change | dirty rect | % of full box |
|---|---|---|
| no change (identical value) | none | 0% |
| single digit, no rollover (e.g. 5 -> 6) | 36x33 | 7.0% |
| rollover (e.g. 7 -> 8, 2 digits change) | 34x40 | 8.0% |
| large jump (most digits differ) | 98x76 | 44.1% |
| color change only, same value | 21x24 | 3.0% |

For the common case (a clock ticking its fastest digit once a second, no
rollover), this cuts the pixels actually pushed to the display by roughly
93% -- and since a raw pixel push (e.g. over SPI) is the dominant cost of
an update, not rasterization (tens of microseconds), that's roughly
proportional to the actual speedup.

### Memory & performance

- **Heap.** This library never allocates -- every buffer is caller-owned.
  Budget `w * h * 4` bytes per glyph for its ARGB8888 buffer (times two if
  you're double-buffering for dirty-rect diffing).
- **Render time.** Measured on a host benchmark (depth 7, direct rasterizer
  calls, no display push):

  | concurrent glyphs | avg time / iteration |
  |---|---|
  | 2 | ~130 us |
  | 6 | ~370 us |

  These numbers are from an x86 host build and are a rough proxy, not a
  substitute for measuring on your target.

### Verification

- Octal normalization (`og_octal_digits_from_value`) and the full geometry
  build (`og_build_glyph`) are diffed against a golden JSON generated by
  running the real `geometry.ts` through Node -- 22 cases across every
  depth, edge cases, and split-style coloring all match on
  `normalizedValue`/`depth`/contour points/frame bounds within tolerance.
- `og_glyph_rasterize` was verified standalone against a wide grid of test
  glyphs spanning every depth, several values, colors, and split settings,
  dumped to PNG -- confirmed smooth anti-aliasing and a crisp even-odd
  core-ring hole.
- `og_glyph_diff_rect` was tested against five cases: identical values (no
  diff), a single-digit tick, a two-digit rollover, a large jump touching
  most digits, and a same-value color change -- confirming it reports no
  diff only when actually identical, and its rectangle is never smaller
  than the true set of differing pixels.
- On real ESP32-C6 hardware: pushing this rasterizer's output via a raw,
  no-LVGL display driver call is confirmed working. Two earlier,
  LVGL-based designs (SVG/ThorVG and this same rasterizer wrapped in an
  LVGL widget) never rendered anything on that board despite matching
  pixel-for-pixel on host -- see "Rendering approach" above.

## Saros clock

Not a conventional HH:MM:SS clock: `saros_reading_at` computes where the
current instant falls, as a 10-digit octal fraction, between the last and
next eclipse of a chosen solar Saros series -- ported from a reference
watchface implementation's "fixed" display mode. Two 5-digit halves of
that address are a natural fit for two depth-5 OctalGlyphs (see "Usage"
below), and since the low-digit half advances roughly once every half
second (for Saros 141, the default series), it's a genuinely
continuously-ticking clock, not a once-a-day novelty.

### Data provenance

`saros_data.h` holds a compact, flash-resident (`static const`) snapshot:
`SAROS_ECLIPSES_PER_SERIES` (currently 5) consecutive eclipse timestamps
for each of `SAROS_SERIES_COUNT` (40) active solar Saros series (117-156),
generally 1 eclipse before "now" and the rest after, extracted directly
from the full canonical astronomical dataset (`@fractonica/temporal-core`'s
generated eclipse catalog, which spans ~70 eclipses per series back to
antiquity and forward for centuries) -- not independently computed, so it
can't drift from the source of truth. One series (117) has its window
shifted 2 eclipses earlier than the rest because that series' dataset only
extends to 2054 (a real property of that series, not a generation bug);
every window was verified, at extraction time, to actually bracket the
extraction date. Valid usage window per series is `[data[0], data[N-1])`,
roughly 90-160 years depending on the series -- re-extract from the
canonical dataset well before this device would run past that.

### Usage

```c
#include "saros_clock.h"
#include "octal_glyph_geometry.h"
#include "octal_glyph_raster.h"

double now_seconds = /* UTC unix time, fractional seconds ok, e.g. from gettimeofday() */;

saros_reading_t reading;
if (saros_reading_at(141, now_seconds, &reading)) {
    og_glyph_t high, low;
    og_build_glyph(reading.high_value, SAROS_HALF_DIGITS, 0, &high); /* first 5 octal digits */
    og_build_glyph(reading.low_value, SAROS_HALF_DIGITS, 0, &low);   /* last 5 octal digits */
    /* rasterize + push each as usual (see OctalGlyph rendering above) --
       a single flat color for both primary/secondary args matches the
       reference watchface's monochrome glyph style */
}
```

`saros_reading_at` returns `false` if `now_seconds` falls outside the
chosen series' known eclipse window (see "Data provenance") -- hold the
last good reading rather than displaying garbage when that happens.

### Verification

Ported logic was cross-checked against a JS re-implementation of the exact
reference watchface algorithm (`readingForSeries`/`octalAddress`,
generalized here to scan `SAROS_ECLIPSES_PER_SERIES - 1` candidate
intervals instead of a fixed 3-point window) across boundary and typical
cases for multiple series, including the shifted Saros 117 window --
`bin_index`/`high_value`/`low_value` match exactly in every case. Two real
bugs were caught this way during development: a missing `stdlib.h` that
silently truncated a `double` return value's precision, and a phase-clamp
constant that was insufficiently precise for values right at an interval's
boundary.

## Optional LVGL widget

`optional-lvgl-widget/lv_octal_glyph.{h,c}` (+ `lv_octal_glyph_private.h`)
wraps the OctalGlyph rasterizer as a proper LVGL widget (`lv_obj_class`,
one internal `lv_image` child, standard `lv_octal_glyph_create` /
`_set_value` / `_set_depth` / `_set_colors` / `_set_split` API) for
projects that want LVGL managing the display/flush pipeline instead of a
direct pixel push. It's a real, useful integration -- see "Rendering
approach" design 5 -- but it depends on LVGL 9, so it lives outside `src/`
and is **not compiled by default**: this library's default `srcDir` (just
`src/`) has zero dependencies on purpose.

To opt in: add `optional-lvgl-widget/` to your own build's include path and
source list alongside this library's `src/` (e.g. in PlatformIO, extend
`build_src_filter` and `build_flags -I` in your project, not this
library's, to also pick up that directory). No special `lv_conf.h` flags
are needed beyond a standard LVGL 9 build; just budget heap for your
concurrent glyph count and size (each widget instance heap-allocates one
ARGB8888 buffer sized to its box and keeps it resident).

## Reuse on other devices

The core (`src/`) calls nothing beyond the C standard library (`<string.h>`,
`<math.h>`) -- no display driver, no OS, no dynamic allocation. It compiles
and runs identically on a host machine (for testing) or any embedded
target. On PlatformIO, add it via `lib_deps` (e.g.
`symlink://../fractonica-embed` for a sibling-directory checkout during
development, or a git URL once published).
