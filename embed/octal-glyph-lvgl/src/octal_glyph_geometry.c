#include "octal_glyph_geometry.h"

uint8_t og_clamp_depth(int raw_depth) {
    int depth = raw_depth;
    if (depth < OCTAL_GLYPH_DEPTH_MIN) {
        depth = OCTAL_GLYPH_DEPTH_MIN;
    }
    if (depth > OCTAL_GLYPH_DEPTH_MAX) {
        depth = OCTAL_GLYPH_DEPTH_MAX;
    }
    return (uint8_t)depth;
}

void og_octal_digits_from_value(uint32_t value, uint8_t depth, char *out) {
    /* Extract exactly `depth` base-8 digits, least-significant first, then
     * place them right-to-left. Any digits beyond `depth` are simply never
     * extracted (equivalent to value % 8^depth, i.e. "keep rightmost"), and
     * if `value` has fewer than `depth` octal digits the leftover high
     * positions naturally stay '0' (left-padded). */
    for (uint8_t i = 0; i < depth; i++) {
        uint8_t digit = (uint8_t)(value & 0x7u);
        out[depth - 1 - i] = (char)('0' + digit);
        value >>= 3;
    }
    out[depth] = '\0';
}

uint8_t og_digit_index_for_socket(uint8_t socket_index, uint8_t depth) {
    return socket_index == 0 ? 0 : (uint8_t)(depth - socket_index);
}
