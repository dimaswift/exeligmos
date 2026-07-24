/**
 * saros_clock.h
 *
 * Pure math port of the reference watchface's Saros phase-address model
 * (/Users/dimas/projects/zepp-faces/exeligmos/watchface/index.js --
 * seriesIndexForSaros, eclipseTriplet, intervalForSeries, readingForSeries,
 * octalAddress), trimmed to just what this clock needs: given a chosen
 * Saros series and the current UTC time, where are we (as a 10-digit octal
 * fraction) between that series' last eclipse and its next one.
 *
 * No LVGL/Arduino/display dependency -- pure C, unit-testable on a host
 * machine, same as the rest of this project's math (og_build_glyph,
 * og_glyph_rasterize).
 */
#pragma once

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SAROS_BASE_DIGITS     10
#define SAROS_HALF_DIGITS     5
#define SAROS_BASE_BIN_COUNT  1073741824u /* 8^10 */
#define SAROS_HALF_BIN_COUNT  32768u      /* 8^5 */

typedef struct {
    uint32_t bin_index;  /* 0 .. SAROS_BASE_BIN_COUNT-1: quantized phase through the current eclipse interval */
    uint32_t high_value; /* bin_index's top 5 octal digits, as a value in [0, SAROS_HALF_BIN_COUNT) */
    uint32_t low_value;  /* bin_index's bottom 5 octal digits, as a value in [0, SAROS_HALF_BIN_COUNT) */
} saros_reading_t;

/**
 * Computes the current phase-bin for `saros` (e.g. 141) at `now_seconds`
 * (Unix epoch, UTC -- fractional seconds accepted, for sub-second display
 * smoothness). `high_value`/`low_value` are each meant to drive one
 * depth-5 og_octal_glyph (og_build_glyph(..., 5, 0, &model)), matching the
 * reference watchface's two-glyph split (address.slice(0,5) /
 * address.slice(5,10)).
 *
 * Returns false if `now_seconds` falls outside this series' known
 * SAROS_ECLIPSES_PER_SERIES-eclipse window (see saros_data.h's coverage
 * note) -- when that happens, hold the last good reading rather than
 * displaying garbage.
 */
bool saros_reading_at(uint8_t saros, double now_seconds, saros_reading_t *out);

#ifdef __cplusplus
}
#endif
