/**
 * lv_octal_glyph.h
 *
 * A real LVGL widget (lv_obj_class) that renders an OctalGlyph -- a radial
 * "core ring + up to 8 digit arms" glyph -- as the *exact* filled-polygon
 * geometry @fractonica/glyph-core's TypeScript produces (byte-for-byte
 * verified against it), via a small pure-C anti-aliased scanline rasterizer
 * (octal_glyph_raster.c) that writes straight into a plain ARGB8888 pixel
 * buffer -- no SVG, no ThorVG, no vector-graphics module, no dependency
 * beyond LVGL itself. An earlier design rendered this same exact geometry
 * through LVGL's native SVG decoder (LV_USE_SVG, ThorVG-backed) and it
 * looked right in every host simulation, but never rendered on the real
 * target hardware with no diagnosable failure signal; this rasterizer
 * trades ThorVG's vector-fill machinery for ~200 lines of plain C anyone
 * can step through. Two even earlier redesigns (stroked lines, then
 * pre-rendered sprites) simplified the artwork itself to cut render cost,
 * but neither looked close enough to the original. See the README's
 * "Rendering approach" section for the full history and trade-offs.
 *
 * Internally this wraps one lv_image child; every value/depth/color/split/
 * size change re-rasterizes directly into a heap-allocated pixel buffer
 * sized to the widget's current box and re-points the child at it. No
 * fixed-resolution constraint -- it scales (contain-fit) to whatever size
 * you give the widget.
 *
 * Usage:
 *   lv_obj_t * glyph = lv_octal_glyph_create(parent);
 *   lv_obj_set_size(glyph, 120, 120);
 *   lv_octal_glyph_set_depth(glyph, 7);
 *   lv_octal_glyph_set_value(glyph, 0754);            // shown base-8: "0000754"
 *   lv_octal_glyph_set_colors(glyph, lv_color_hex(0xFFFFFF), lv_color_hex(0x8E8E93));
 */
#pragma once

#include "lvgl.h"

#ifdef __cplusplus
extern "C" {
#endif

LV_ATTRIBUTE_EXTERN_DATA extern const lv_obj_class_t lv_octal_glyph_class;

/** Creates an octal glyph widget. Defaults: depth 7, value 0, white/gray. */
lv_obj_t *lv_octal_glyph_create(lv_obj_t *parent);

/** Sets the glyph's value. `value` is a plain integer -- its base-8 (octal)
 * digits are what's displayed, truncated to the rightmost `depth` digits and
 * left-padded with zeros (e.g. depth 5, value 15 -> "00017", since decimal 15
 * is octal 17). Write literals in octal (0754) if you want to eyeball which
 * digits will show. */
void lv_octal_glyph_set_value(lv_obj_t *obj, uint32_t value);

/** Sets the number of digit sockets (clamped to [3, 8]). */
void lv_octal_glyph_set_depth(lv_obj_t *obj, uint8_t depth);

/** Sets the core color (always secondary) and the default arm color. */
void lv_octal_glyph_set_colors(lv_obj_t *obj, lv_color_t primary, lv_color_t secondary);

/** Arms with digitIndex < split_after_digit_count use the primary color, the
 * rest use secondary. Pass 0 to disable splitting (every arm is primary). */
void lv_octal_glyph_set_split(lv_obj_t *obj, uint8_t split_after_digit_count);

uint32_t lv_octal_glyph_get_value(const lv_obj_t *obj);
uint8_t lv_octal_glyph_get_depth(const lv_obj_t *obj);

#ifdef __cplusplus
}
#endif
