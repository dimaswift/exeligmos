#include "saros_clock.h"
#include "saros_data.h"

#include <stddef.h> /* NULL */

bool saros_reading_at(uint8_t saros, double now_seconds, saros_reading_t *out) {
    if (out == NULL) {
        return false;
    }

    int32_t series_index = (int32_t)saros - SAROS_FIRST;
    if (series_index < 0) {
        series_index = 0;
    }
    if (series_index > SAROS_SERIES_COUNT - 1) {
        series_index = SAROS_SERIES_COUNT - 1;
    }

    const uint32_t *points = &SAROS_ECLIPSE_SECONDS[series_index * SAROS_ECLIPSES_PER_SERIES];

    if (now_seconds < (double)points[0] || now_seconds >= (double)points[SAROS_ECLIPSES_PER_SERIES - 1]) {
        return false; /* outside this series' known eclipse window */
    }

    /* Find the consecutive pair [points[k], points[k+1]) that brackets
     * now_seconds. With SAROS_ECLIPSES_PER_SERIES points there are
     * SAROS_ECLIPSES_PER_SERIES - 1 candidate intervals; the range check
     * above guarantees one of them matches. */
    double start = (double)points[0];
    double end = (double)points[SAROS_ECLIPSES_PER_SERIES - 1];
    for (int k = 0; k < SAROS_ECLIPSES_PER_SERIES - 1; k++) {
        if (now_seconds < (double)points[k + 1]) {
            start = (double)points[k];
            end = (double)points[k + 1];
            break;
        }
    }

    double duration = end - start;
    if (duration < 1.0) {
        duration = 1.0;
    }
    double phase = (now_seconds - start) / duration;
    if (phase < 0.0) {
        phase = 0.0;
    }
    /* Matches the reference's PHASE_UPPER_BOUND exactly (1 - Number.EPSILON
     * in JS): the largest double strictly less than 1.0, so the very last
     * representable instant before an interval ends still resolves to
     * bin (SAROS_BASE_BIN_COUNT - 1), not an out-of-range bin. */
    if (phase > 0.9999999999999998) {
        phase = 0.9999999999999998;
    }

    double bin_f = phase * (double)SAROS_BASE_BIN_COUNT;
    uint32_t bin = (uint32_t)bin_f;
    if (bin >= SAROS_BASE_BIN_COUNT) {
        bin = SAROS_BASE_BIN_COUNT - 1;
    }

    out->bin_index = bin;
    out->high_value = bin >> 15;                        /* top 5 octal digits: bin / 8^5 */
    out->low_value = bin & (SAROS_HALF_BIN_COUNT - 1);   /* bottom 5 octal digits: bin % 8^5 */
    return true;
}
