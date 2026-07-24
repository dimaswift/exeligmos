/* lv_octal_glyph_private.h pulls in lv_octal_glyph.h, lvgl_private.h (the
 * full, non-opaque lv_obj_t / lv_obj_class_t layouts every custom LVGL
 * widget needs -- same split lv_led, lv_arc etc. use), and the geometry +
 * rasterizer headers. */
#include "lv_octal_glyph_private.h"
#include "src/misc/cache/lv_cache.h" /* lv_image_cache_drop -- see rebuild() */

#define MY_CLASS (&lv_octal_glyph_class)

static void lv_octal_glyph_constructor(const lv_obj_class_t *class_p, lv_obj_t *obj);
static void lv_octal_glyph_destructor(const lv_obj_class_t *class_p, lv_obj_t *obj);
static void lv_octal_glyph_event(const lv_obj_class_t *class_p, lv_event_t *e);
static void lv_octal_glyph_rebuild(lv_octal_glyph_t *glyph);

const lv_obj_class_t lv_octal_glyph_class = {
    .base_class = &lv_obj_class,
    .constructor_cb = lv_octal_glyph_constructor,
    .destructor_cb = lv_octal_glyph_destructor,
    .event_cb = lv_octal_glyph_event,
    .instance_size = sizeof(lv_octal_glyph_t),
    .width_def = LV_DPI_DEF / 2,
    .height_def = LV_DPI_DEF / 2,
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
    lv_octal_glyph_rebuild(glyph);
}

void lv_octal_glyph_set_depth(lv_obj_t *obj, uint8_t depth) {
    LV_ASSERT_OBJ(obj, MY_CLASS);
    lv_octal_glyph_t *glyph = (lv_octal_glyph_t *)obj;
    glyph->depth = og_clamp_depth(depth);
    lv_octal_glyph_rebuild(glyph);
}

void lv_octal_glyph_set_colors(lv_obj_t *obj, lv_color_t primary, lv_color_t secondary) {
    LV_ASSERT_OBJ(obj, MY_CLASS);
    lv_octal_glyph_t *glyph = (lv_octal_glyph_t *)obj;
    glyph->primary_color = primary;
    glyph->secondary_color = secondary;
    lv_octal_glyph_rebuild(glyph);
}

void lv_octal_glyph_set_split(lv_obj_t *obj, uint8_t split_after_digit_count) {
    LV_ASSERT_OBJ(obj, MY_CLASS);
    lv_octal_glyph_t *glyph = (lv_octal_glyph_t *)obj;
    glyph->split_after_digit_count = split_after_digit_count;
    lv_octal_glyph_rebuild(glyph);
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

    glyph->image = lv_image_create(obj);
    glyph->pixel_buf = NULL;
    glyph->pixel_buf_w = 0;
    glyph->pixel_buf_h = 0;
    lv_memzero(&glyph->pixel_dsc, sizeof(glyph->pixel_dsc));

    lv_octal_glyph_rebuild(glyph);

    LV_TRACE_OBJ_CREATE("finished");
}

static void lv_octal_glyph_destructor(const lv_obj_class_t *class_p, lv_obj_t *obj) {
    LV_UNUSED(class_p);
    lv_octal_glyph_t *glyph = (lv_octal_glyph_t *)obj;
    if (glyph->pixel_buf != NULL) {
        lv_image_cache_drop(&glyph->pixel_dsc);
        lv_free(glyph->pixel_buf);
        glyph->pixel_buf = NULL;
    }
}

static void lv_octal_glyph_event(const lv_obj_class_t *class_p, lv_event_t *e) {
    LV_UNUSED(class_p);

    lv_event_code_t code = lv_event_get_code(e);
    lv_result_t res = lv_obj_event_base(MY_CLASS, e);
    if (res != LV_RESULT_OK) {
        return;
    }

    if (code == LV_EVENT_SIZE_CHANGED) {
        lv_obj_t *obj = lv_event_get_current_target(e);
        lv_octal_glyph_rebuild((lv_octal_glyph_t *)obj);
    }
}

/* Rasterizes the exact, golden-JSON-verified @fractonica/glyph-core polygon
 * geometry (og_build_glyph + og_glyph_rasterize -- a plain scanline
 * anti-aliased fill, no SVG, no ThorVG, no vector-graphics module) directly
 * into a heap-allocated ARGB8888 pixel buffer sized to the widget's current
 * content box, and re-points the internal lv_image child at it as a raw
 * (non-decoded) image source. Reallocates pixel_buf only when the box size
 * actually changes; otherwise reuses it in place. */
static void lv_octal_glyph_rebuild(lv_octal_glyph_t *glyph) {
    lv_obj_t *obj = &glyph->obj;
    if (glyph->image == NULL) {
        return; /* called once during construction before the child exists */
    }

    int32_t area_w = lv_obj_get_content_width(obj);
    int32_t area_h = lv_obj_get_content_height(obj);
    if (area_w <= 0 || area_h <= 0) {
        return;
    }

    if (area_w != glyph->pixel_buf_w || area_h != glyph->pixel_buf_h || glyph->pixel_buf == NULL) {
        uint8_t *new_buf = lv_realloc(glyph->pixel_buf, (size_t)area_w * (size_t)area_h * 4u);
        if (new_buf == NULL) {
            return; /* keep the old buffer/size; try again on the next rebuild */
        }
        glyph->pixel_buf = new_buf;
        glyph->pixel_buf_w = area_w;
        glyph->pixel_buf_h = area_h;
        lv_obj_set_size(glyph->image, area_w, area_h);
        lv_obj_center(glyph->image);
    }

    og_glyph_t model;
    og_build_glyph(glyph->value, glyph->depth, glyph->split_after_digit_count, &model);

    uint32_t primary_rgb = lv_color_to_u32(glyph->primary_color) & 0xFFFFFFu;
    uint32_t secondary_rgb = lv_color_to_u32(glyph->secondary_color) & 0xFFFFFFu;

    og_glyph_rasterize(&model, primary_rgb, secondary_rgb, area_w, area_h, glyph->pixel_buf);

    glyph->pixel_dsc.header.magic = LV_IMAGE_HEADER_MAGIC;
    glyph->pixel_dsc.header.cf = LV_COLOR_FORMAT_ARGB8888;
    glyph->pixel_dsc.header.w = (uint16_t)area_w;
    glyph->pixel_dsc.header.h = (uint16_t)area_h;
    glyph->pixel_dsc.header.stride = (uint16_t)(area_w * 4);
    glyph->pixel_dsc.data_size = (uint32_t)area_w * (uint32_t)area_h * 4u;
    glyph->pixel_dsc.data = glyph->pixel_buf;

    /* glyph->pixel_dsc/pixel_buf live at fixed per-instance addresses that we
     * mutate in place on every rebuild (unlike a normal PROGMEM image
     * constant, whose address implies immutable content). LVGL's image
     * decoder cache keys purely on (src_type, src pointer), so without
     * dropping the stale entry here, re-pointing the child image at the
     * same address after it was already used once before would keep
     * serving the *previous* pixels. This mirrors the
     * lv_canvas/lv_qrcode/lv_barcode/lv_gif pattern of calling
     * lv_image_cache_drop() before re-using a mutated buffer. */
    lv_image_cache_drop(&glyph->pixel_dsc);

    lv_image_set_src(glyph->image, &glyph->pixel_dsc);
}
