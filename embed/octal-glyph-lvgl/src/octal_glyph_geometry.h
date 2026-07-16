/**
 * octal_glyph_geometry.h
 *
 * Small, pure-math helpers shared by the widget: depth clamping, octal
 * digit extraction, and the socket-index -> digitIndex mapping. No lvgl.h,
 * no Arduino.h, no dynamic allocation -- unit-testable on a host machine.
 *
 * This is deliberately tiny: with the sprite-based render (see
 * octal_glyph_sprites.h), there's no shape geometry left to compute at
 * runtime -- placing an arm is just "look up its sprite, rotate it by
 * socket_index * 360/depth". An earlier version of this file built full
 * polygon/polyline shape models (og_build_glyph, og_frame_bounds); that's
 * gone now that shapes are pre-rendered pixels, not live geometry.
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

/**
 * Socket order at depth d is [0, d-1, d-2, ..., 1]; digitIndex 0 is the
 * fixed "current" socket, the rest walk backwards through history.
 */
uint8_t og_digit_index_for_socket(uint8_t socket_index, uint8_t depth);

#ifdef __cplusplus
}
#endif
