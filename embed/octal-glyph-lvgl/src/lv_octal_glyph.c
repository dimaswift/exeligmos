/* lv_octal_glyph_private.h pulls in lv_octal_glyph.h, lvgl_private.h (the
 * full, non-opaque lv_obj_t / lv_obj_class_t layouts every custom LVGL
 * widget needs -- same split lv_led, lv_arc etc. use), and the geometry
 * header. */
#include "lv_octal_glyph_private.h"

#include <math.h>

#define MY_CLASS (&lv_octal_glyph_class)

static void lv_octal_glyph_constructor(const lv_obj_class_t *class_p, lv_obj_t *obj);
static void lv_octal_glyph_event(const lv_obj_class_t *class_p, lv_event_t *e);
static void lv_octal_glyph_draw(lv_octal_glyph_t *glyph, lv_event_t *e);
static void lv_octal_glyph_draw_ring(lv_layer_t *layer,
                                     lv_color_t color,
                                     int32_t center_x,
                                     int32_t center_y);
static void lv_octal_glyph_draw_arm(lv_layer_t *layer,
                                    const og_arm_sprite_t *sprite,
                                    lv_color_t color,
                                    int32_t center_x,
                                    int32_t center_y,
                                    int32_t rotation_deci_deg);

const lv_obj_class_t lv_octal_glyph_class = {
    .base_class = &lv_obj_class,
    .constructor_cb = lv_octal_glyph_constructor,
    .event_cb = lv_octal_glyph_event,
    .instance_size = sizeof(lv_octal_glyph_t),
    .width_def = OG_SPRITE_CANVAS_SIZE,
    .height_def = OG_SPRITE_CANVAS_SIZE,
    .name = "lv_octal_glyph",
};

lv_obj_t *lv_octal_glyph_create(lv_obj_t *parent) {
    LV_LOG_INFO("begin");
    lv_obj_t *obj = lv_obj_class_create_obj(MY_CLASS, parent);
    lv_obj_class_init_obj(obj);
    return obj;
}

void lv_octal_glyph_set_value(lv_obj_t *obj, uint32_t value) {
    LV_ASSERT_OBJ(obj, MY_CLASS);
    lv_octal_glyph_t *glyph = (lv_octal_glyph_t *)obj;
    glyph->value = value;
    lv_obj_invalidate(obj);
}

void lv_octal_glyph_set_depth(lv_obj_t *obj, uint8_t depth) {
    LV_ASSERT_OBJ(obj, MY_CLASS);
    lv_octal_glyph_t *glyph = (lv_octal_glyph_t *)obj;
    glyph->depth = og_clamp_depth(depth);
    lv_obj_invalidate(obj);
}

void lv_octal_glyph_set_colors(lv_obj_t *obj, lv_color_t primary, lv_color_t secondary) {
    LV_ASSERT_OBJ(obj, MY_CLASS);
    lv_octal_glyph_t *glyph = (lv_octal_glyph_t *)obj;
    glyph->primary_color = primary;
    glyph->secondary_color = secondary;
    lv_obj_invalidate(obj);
}

void lv_octal_glyph_set_split(lv_obj_t *obj, uint8_t split_after_digit_count) {
    LV_ASSERT_OBJ(obj, MY_CLASS);
    lv_octal_glyph_t *glyph = (lv_octal_glyph_t *)obj;
    glyph->split_after_digit_count = split_after_digit_count;
    lv_obj_invalidate(obj);
}

uint32_t lv_octal_glyph_get_value(const lv_obj_t *obj) {
    LV_ASSERT_OBJ(obj, MY_CLASS);
    const lv_octal_glyph_t *glyph = (const lv_octal_glyph_t *)obj;
    return glyph->value;
}

uint8_t lv_octal_glyph_get_depth(const lv_obj_t *obj) {
    LV_ASSERT_OBJ(obj, MY_CLASS);
    const lv_octal_glyph_t *glyph = (const lv_octal_glyph_t *)obj;
    return glyph->depth;
}

/* ---- internals ------------------------------------------------------------ */

static void lv_octal_glyph_constructor(const lv_obj_class_t *class_p, lv_obj_t *obj) {
    LV_UNUSED(class_p);
    lv_octal_glyph_t *glyph = (lv_octal_glyph_t *)obj;

    glyph->depth = OCTAL_GLYPH_DEPTH_DEFAULT;
    glyph->split_after_digit_count = 0;
    glyph->primary_color = lv_color_white();
    glyph->secondary_color = lv_color_hex(0x8E8E93); /* catalog color.rarity.triplex fallback */
    glyph->value = 0;

    lv_obj_set_style_bg_opa(obj, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(obj, 0, 0);

    LV_TRACE_OBJ_CREATE("finished");
}

static void lv_octal_glyph_event(const lv_obj_class_t *class_p, lv_event_t *e) {
    LV_UNUSED(class_p);

    lv_event_code_t code = lv_event_get_code(e);
    if (code != LV_EVENT_DRAW_MAIN && code != LV_EVENT_DRAW_MAIN_END) {
        lv_result_t res = lv_obj_event_base(MY_CLASS, e);
        if (res != LV_RESULT_OK) {
            return;
        }
    }

    if (code == LV_EVENT_DRAW_MAIN) {
        lv_obj_t *obj = lv_event_get_current_target(e);
        lv_octal_glyph_draw((lv_octal_glyph_t *)obj, e);
    }
}

/* No geometry to build at all: the ring is one live lv_draw_arc call, and
 * each arm is a lookup into the pre-baked sprite table (og_arm_sprites)
 * plus an angle. Digit extraction is the only per-draw computation left. */
static void lv_octal_glyph_draw(lv_octal_glyph_t *glyph, lv_event_t *e) {
    lv_obj_t *obj = &glyph->obj;
    lv_layer_t *layer = lv_event_get_layer(e);

    lv_area_t content_area;
    lv_obj_get_content_coords(obj, &content_area);

    int32_t area_w = lv_area_get_width(&content_area);
    int32_t area_h = lv_area_get_height(&content_area);
    if (area_w <= 0 || area_h <= 0) {
        return;
    }

    /* Fixed-resolution canvas, centered in the widget's content box (no
     * scaling to the box size yet -- see lv_octal_glyph.h). */
    int32_t center_x = content_area.x1 + area_w / 2;
    int32_t center_y = content_area.y1 + area_h / 2;

    lv_octal_glyph_draw_ring(layer, glyph->secondary_color, center_x, center_y);

    char digits[OCTAL_GLYPH_DEPTH_MAX + 1];
    og_octal_digits_from_value(glyph->value, glyph->depth, digits);

    for (uint8_t socket_index = 0; socket_index < glyph->depth; socket_index++) {
        uint8_t digit_index = og_digit_index_for_socket(socket_index, glyph->depth);
        uint8_t digit = (uint8_t)(digits[digit_index] - '0');
        if (digit == 0 || digit > 7) {
            continue; /* digit 0 has no visible arm; >7 defensive (normalize guarantees 0-7) */
        }

        lv_color_t color;
        if (glyph->split_after_digit_count == 0) {
            color = glyph->primary_color;
        } else {
            color = (digit_index < glyph->split_after_digit_count) ? glyph->primary_color : glyph->secondary_color;
        }

        int32_t rotation = (int32_t)lroundf((float)socket_index * (360.0f / (float)glyph->depth) * 10.0f);
        lv_octal_glyph_draw_arm(layer, &og_arm_sprites[digit - 1], color, center_x, center_y, rotation);
    }
}

/* The core ring is a single lv_draw_arc call (start=0, end=360 hits LVGL's
 * dedicated "full ring" fast path) -- one seam-free anti-aliased primitive,
 * no triangle mesh, no sprite. */
static void lv_octal_glyph_draw_ring(lv_layer_t *layer,
                                     lv_color_t color,
                                     int32_t center_x,
                                     int32_t center_y) {
    lv_draw_arc_dsc_t dsc;
    lv_draw_arc_dsc_init(&dsc);
    dsc.color = color;
    dsc.opa = LV_OPA_COVER;
    dsc.width = (int32_t)lroundf(OG_CORE_RING_WIDTH_PX);
    dsc.radius = (uint16_t)lroundf(OG_CORE_RADIUS_PX - OG_CORE_RING_WIDTH_PX / 2.0f);
    dsc.center.x = center_x;
    dsc.center.y = center_y;
    dsc.start_angle = 0;
    dsc.end_angle = 360;
    dsc.rounded = 0;

    lv_draw_arc(layer, &dsc);
}

/* Rotating a pre-rendered sprite around a pivot placed at the glyph's
 * on-screen center reproduces both the arm's on-ring position AND its
 * orientation in a single lv_draw_image call: LVGL keeps the pivot's own
 * screen position fixed while everything else swings around it, so the
 * same rotation that spins the sprite's pixels also carries its (baked-in)
 * base point around the ring to the correct socket -- no separate runtime
 * trig needed for placement, LVGL's image transform does both at once. */
static void lv_octal_glyph_draw_arm(lv_layer_t *layer,
                                    const og_arm_sprite_t *sprite,
                                    lv_color_t color,
                                    int32_t center_x,
                                    int32_t center_y,
                                    int32_t rotation_deci_deg) {
    lv_image_dsc_t img_dsc;
    lv_memzero(&img_dsc, sizeof(img_dsc));
    img_dsc.header.magic = LV_IMAGE_HEADER_MAGIC;
    img_dsc.header.cf = LV_COLOR_FORMAT_A8;
    img_dsc.header.w = sprite->w;
    img_dsc.header.h = sprite->h;
    img_dsc.header.stride = sprite->w;
    img_dsc.data_size = (uint32_t)sprite->w * (uint32_t)sprite->h;
    img_dsc.data = sprite->data;

    lv_draw_image_dsc_t dsc;
    lv_draw_image_dsc_init(&dsc);
    dsc.src = &img_dsc;
    dsc.pivot.x = sprite->pivot_x;
    dsc.pivot.y = sprite->pivot_y;
    dsc.rotation = rotation_deci_deg;
    dsc.recolor = color;
    dsc.recolor_opa = LV_OPA_COVER;
    dsc.opa = LV_OPA_COVER;
    dsc.antialias = 1;

    lv_area_t coords;
    coords.x1 = center_x - sprite->pivot_x;
    coords.y1 = center_y - sprite->pivot_y;
    coords.x2 = coords.x1 + sprite->w - 1;
    coords.y2 = coords.y1 + sprite->h - 1;

    lv_draw_image(layer, &dsc, &coords);
}
