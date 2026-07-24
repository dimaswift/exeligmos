#ifndef LV_CONF_H
#define LV_CONF_H

#if 0 && defined(__ASSEMBLY__)
#include <stdint.h>
#endif

#define LV_COLOR_DEPTH 16

#define LV_USE_STDLIB_MALLOC LV_STDLIB_BUILTIN
#define LV_USE_STDLIB_STRING LV_STDLIB_BUILTIN
#define LV_USE_STDLIB_SPRINTF LV_STDLIB_BUILTIN
/* 16KB: src/main.cpp now bypasses LVGL entirely (talks straight to
 * ESP32C6LCD147's raw Display class -- see that file's doc comment for
 * why), so lv_init() is never called and this pool is never actually
 * used. It's kept small but nonzero rather than ripping LVGL out of the
 * project, since ESP32C6LCD147.h still links against it (Ui/lv_display_t
 * types) and the lv_octal_glyph widget is still there if a future build
 * wants LVGL back. Note this static array is reserved at boot regardless
 * of whether lv_init() runs (see LVGL's lv_mem_core_builtin.c), so keep
 * this small -- our own front/back pixel buffers in main.cpp (~169KB for
 * one 130x130 glyph) are the real budget to watch now. */
#define LV_MEM_SIZE (16 * 1024U)

#define LV_DEF_REFR_PERIOD 16
#define LV_DPI_DEF 260
#define LV_USE_OS LV_OS_NONE

#define LV_DRAW_BUF_ALIGN 4
#define LV_USE_DRAW_SW 1
#define LV_DRAW_SW_SUPPORT_RGB565 1
#define LV_DRAW_SW_SUPPORT_RGB565_SWAPPED 1
#define LV_DRAW_SW_DRAW_UNIT_CNT 1

#define LV_USE_LOG 0
#define LV_USE_ASSERT_NULL 1
#define LV_USE_ASSERT_MALLOC 1
#define LV_USE_ASSERT_STYLE 0
#define LV_USE_ASSERT_MEM_INTEGRITY 0
#define LV_USE_ASSERT_OBJ 0

#define LV_USE_PERF_MONITOR 0
#define LV_USE_MEM_MONITOR 0
#define LV_USE_REFR_DEBUG 0

#define LV_BUILD_EXAMPLES 0
#define LV_USE_DEMO_WIDGETS 0
#define LV_USE_DEMO_BENCHMARK 0
#define LV_USE_DEMO_STRESS 0
#define LV_USE_DEMO_MUSIC 0

#endif  // LV_CONF_H
