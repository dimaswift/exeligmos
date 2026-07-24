/**
 * lv_octal_glyph_private.h
 *
 * Full widget instance layout. Only lv_octal_glyph.c includes this -- it
 * embeds lv_obj_t by value, which requires LVGL's private core headers
 * (the same split every built-in LVGL widget uses between its public
 * lv_*.h and internal lv_*_private.h).
 *
 * The widget wraps a single internal `lv_image` child. Every value/depth/
 * color/split/size change re-rasterizes the exact @fractonica/glyph-core
 * polygon geometry (see octal_glyph_geometry.h + octal_glyph_raster.h)
 * directly into `pixel_buf`, a heap-allocated ARGB8888 buffer sized to the
 * widget's current content box, and re-points the child image at it via
 * lv_image_set_src as a plain raw (undecoded) image source -- no SVG, no
 * ThorVG, no image decoder involved at all. `pixel_buf` is realloc'd only
 * when the box size actually changes.
 */
#pragma once

#include "lv_octal_glyph.h"
#include "lvgl_private.h"

#include "octal_glyph_geometry.h"
#include "octal_glyph_raster.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    lv_obj_t obj;

    uint32_t value;
    uint8_t depth;
    uint8_t split_after_digit_count;
    lv_color_t primary_color;
    lv_color_t secondary_color;

    lv_obj_t *image;
    lv_image_dsc_t pixel_dsc;
    uint8_t *pixel_buf;    /* heap-allocated, pixel_buf_w * pixel_buf_h * 4 bytes */
    int32_t pixel_buf_w;
    int32_t pixel_buf_h;
} lv_octal_glyph_t;

#ifdef __cplusplus
}
#endif
