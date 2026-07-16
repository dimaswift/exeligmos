/**
 * lv_octal_glyph_private.h
 *
 * Full widget instance layout. Only lv_octal_glyph.c includes this -- it
 * embeds lv_obj_t by value, which requires LVGL's private core headers
 * (the same split every built-in LVGL widget uses between its public
 * lv_*.h and internal lv_*_private.h).
 *
 * There's no per-instance geometry cache and nothing to compute at draw
 * time beyond a digit lookup and an angle: the core ring is a live
 * lv_draw_arc call, and each arm is a pre-rendered sprite (see
 * octal_glyph_sprites.h) rotated onto its socket with lv_draw_image. No
 * triangle mesh, no polygon/polyline math, nothing that scales with glyph
 * complexity -- this struct only holds the widget's own small state.
 */
#pragma once

#include "lv_octal_glyph.h"
#include "lvgl_private.h"

#include "octal_glyph_geometry.h"
#include "octal_glyph_sprites.h"

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
} lv_octal_glyph_t;

#ifdef __cplusplus
}
#endif
