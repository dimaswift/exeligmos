/**
 * octal_glyph_geometry.h
 *
 * Portable C port of @fractonica/glyph-core's geometry.ts. Pure math: no
 * lvgl.h, no Arduino.h, no dynamic allocation. Produces the same polygons
 * (core + hole, and per-socket arm shapes) as the web renderer, in the same
 * local coordinate space (origin center, x right, y down), so a caller can
 * scale/translate into any target size, or (see octal_glyph_svg.h) directly
 * serialize it into an SVG path string for LVGL's native SVG/ThorVG
 * pipeline to render.
 */
#pragma once

#include <stdint.h>
#include "octal_glyph_catalog.h"

#ifdef __cplusplus
extern "C" {
#endif

#define OCTAL_GLYPH_DEPTH_MIN     3
#define OCTAL_GLYPH_DEPTH_MAX     8
#define OCTAL_GLYPH_DEPTH_DEFAULT 7

#define OG_MAX_SOCKETS         OCTAL_GLYPH_DEPTH_MAX
#define OG_MAX_CORE_POINTS     (2 * OG_MAX_SOCKETS) /* 16 */
#define OG_MAX_CONTOUR_POINTS  OG_MAX_CORE_POINTS   /* covers both core (16) and arms (<=8) */
#define OG_MAX_SHAPES          (1 + OG_MAX_SOCKETS) /* core + up to 8 arms */

typedef enum {
    OG_COLOR_PRIMARY = 0,
    OG_COLOR_SECONDARY = 1,
} og_color_role_t;

typedef struct {
    og_point_t points[OG_MAX_CONTOUR_POINTS];
    uint8_t count;
} og_contour_t;

/* One fillable shape. The core has 2 contours (outer ring + hole, even-odd);
 * arms have exactly 1. All contours in a shape share the same color role. */
typedef struct {
    og_contour_t contours[2];
    uint8_t contour_count;
    og_color_role_t color_role;
    /* -1 for the core shape; otherwise the socket/digit bookkeeping, mirroring
     * glyph-core's GlyphPath metadata (useful for debugging/tests). */
    int8_t socket_index;
    int8_t digit_index;
    int8_t digit;
} og_shape_t;

typedef struct {
    uint8_t depth;
    char normalized_value[OCTAL_GLYPH_DEPTH_MAX + 1];
    float frame_x;
    float frame_y;
    float frame_width;
    float frame_height;
    og_shape_t shapes[OG_MAX_SHAPES];
    uint8_t shape_count;
} og_glyph_t;

/** Clamps an arbitrary requested depth into the supported [3, 8] range. */
uint8_t og_clamp_depth(int raw_depth);

/**
 * Base-8 (octal) digits of `value`, always exactly `depth` characters long
 * and truncated to the rightmost `depth` octal digits if `value` needs more
 * than that to represent (e.g. depth=5, value=15 -> "00017", since
 * 15 decimal == 017 octal). `out` must have room for depth+1 bytes
 * (NUL-terminated).
 */
void og_octal_digits_from_value(uint32_t value, uint8_t depth, char *out);

/** Stable frame/viewBox bounds for a given depth (independent of the value). */
void og_frame_bounds(uint8_t depth, float *x, float *y, float *width, float *height);

/**
 * Builds the full glyph geometry for (value, depth) with an optional
 * primary/secondary split rule: split_after_digit_count == 0 disables the
 * split (every arm is OG_COLOR_PRIMARY); otherwise an arm's digit index below
 * split_after_digit_count is OG_COLOR_PRIMARY and the rest are
 * OG_COLOR_SECONDARY. The core shape is always OG_COLOR_SECONDARY.
 *
 * `value` is a plain integer; its base-8 digits are what's actually shown
 * (see og_octal_digits_from_value).
 */
void og_build_glyph(uint32_t value, uint8_t depth, uint8_t split_after_digit_count, og_glyph_t *out);

#ifdef __cplusplus
}
#endif
