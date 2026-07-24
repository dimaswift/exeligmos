/**
 * octal_glyph_raster.h
 *
 * Direct-to-pixel-buffer rasterizer for og_glyph_t: no SVG, no ThorVG, no
 * vector-graphics module -- a plain scanline polygon fill (even-odd for the
 * core ring's outer+hole contours, nonzero for each single-contour arm),
 * anti-aliased via 4x vertical supersampling plus exact horizontal coverage,
 * writing straight (non-premultiplied) alpha pixels directly into a
 * caller-owned buffer in LVGL's native ARGB8888 byte order (blue, green,
 * red, alpha -- matches lv_color32_t / LV_COLOR_FORMAT_ARGB8888 raw image
 * data, so the result can be handed to lv_image_set_src with zero decoding
 * step and zero extra lv_conf.h flags).
 *
 * This exists because the SVG/ThorVG rendering path (see the git history of
 * this file's sibling octal_glyph_svg.c, since removed) matched the
 * original artwork exactly and worked correctly in every host simulation,
 * but never rendered on the real ESP32-C6 target and the failure mode gave
 * no diagnosable signal (no crash, no log, no error) even with LVGL's own
 * logging enabled -- undiagnosable without hardware-level tracing this
 * project doesn't have access to. This rasterizer trades ThorVG's proper
 * vector fill quality for a small, dependency-free, fully-debuggable
 * software path: if something's wrong here, it's wrong in ~200 lines of
 * plain C we can step through, not in a third-party C++ library's internal
 * state on unfamiliar silicon.
 */
#pragma once

#include <stdint.h>
#include <stddef.h>
#include "octal_glyph_geometry.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Rasterizes `glyph` into `buf`, a caller-owned buffer of exactly
 * `w * h * 4` bytes, byte order (B,G,R,A) per pixel (LVGL's
 * LV_COLOR_FORMAT_ARGB8888 raw layout), row-major, stride == w * 4.
 * `buf` is fully overwritten (cleared to transparent first).
 *
 * `primary_rgb`/`secondary_rgb` are 0xRRGGBB; shapes pick between them via
 * og_shape_t.color_role exactly like octal_glyph_svg.c did.
 */
void og_glyph_rasterize(const og_glyph_t *glyph, uint32_t primary_rgb, uint32_t secondary_rgb,
                        int32_t w, int32_t h, uint8_t *buf);

/**
 * Axis-aligned pixel rectangle, half-open on the high end (x1/y1 are one
 * past the last dirty pixel, like most framebuffer/blit APIs). `valid` is 0
 * if the two compared buffers were pixel-identical (nothing to redraw).
 */
typedef struct {
    int32_t x0, y0, x1, y1;
    uint8_t valid;
} og_dirty_rect_t;

/**
 * Compares two same-sized (w * h, ARGB8888) buffers -- typically two
 * successive og_glyph_rasterize() outputs for the same glyph at different
 * values -- and returns the minimal bounding rectangle containing every
 * differing pixel.
 *
 * This is the building block for fast direct-to-framebuffer updates that
 * skip LVGL entirely: keep two buffers, a "front" (whatever's currently on
 * the physical display) and a "back" (freshly rasterized for the new
 * value), diff them, and push only the returned rectangle instead of the
 * whole glyph box. In practice this is a small fraction of the full box:
 * the core ring and any digit whose value didn't change rasterize to
 * bit-identical pixels every time (this is a deterministic, non-dithered
 * fill), so only the digit(s) that actually changed produce any
 * difference. After pushing, the caller can simply swap its front/back
 * pointers rather than copying -- "back" is a complete, correct next frame
 * in its own right, not just a patch.
 *
 * Cost is at most O(w*h) (a full-buffer diff), but the common case is much
 * cheaper: whole rows that didn't change are rejected by a single memcmp,
 * and only rows touched by a changed shape get the finer per-pixel scan
 * that determines that row's left/right extent.
 */
og_dirty_rect_t og_glyph_diff_rect(const uint8_t *prev, const uint8_t *next, int32_t w, int32_t h);

#ifdef __cplusplus
}
#endif
