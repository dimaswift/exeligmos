#include "octal_glyph_geometry.h"

#include <math.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

typedef struct {
    og_point_t start;
    og_point_t end;
} og_socket_t;

/* ---- small vector helpers ------------------------------------------------ */

static og_point_t og_rotate(og_point_t p, float degrees) {
    float rad = degrees * (float)M_PI / 180.0f;
    float c = cosf(rad);
    float s = sinf(rad);
    og_point_t r;
    r.x = p.x * c - p.y * s;
    r.y = p.x * s + p.y * c;
    return r;
}

static og_point_t og_midpoint(og_point_t a, og_point_t b) {
    og_point_t m;
    m.x = (a.x + b.x) / 2.0f;
    m.y = (a.y + b.y) / 2.0f;
    return m;
}

static float og_signed_area(const og_point_t *pts, uint8_t n) {
    float area = 0.0f;
    for (uint8_t i = 0; i < n; i++) {
        og_point_t p = pts[i];
        og_point_t q = pts[(i + 1) % n];
        area += p.x * q.y - q.x * p.y;
    }
    return area;
}

static int og_intersect_lines(og_point_t point_a, og_point_t dir_a,
                               og_point_t point_b, og_point_t dir_b,
                               og_point_t *out) {
    float cross = dir_a.x * dir_b.y - dir_a.y * dir_b.x;
    if (fabsf(cross) < 0.000001f) {
        return 0;
    }
    float dx = point_b.x - point_a.x;
    float dy = point_b.y - point_a.y;
    float t = (dx * dir_b.y - dy * dir_b.x) / cross;
    out->x = point_a.x + dir_a.x * t;
    out->y = point_a.y + dir_a.y * t;
    return 1;
}

/* ---- sockets / core / arms ------------------------------------------------ */

static void og_make_sockets(uint8_t depth, og_socket_t *sockets) {
    og_point_t base_start = {-OG_SOCKET_WIDTH / 2.0f, -OG_CORE_RADIUS};
    og_point_t base_end = {OG_SOCKET_WIDTH / 2.0f, -OG_CORE_RADIUS};
    float rotation_step = 360.0f / (float)depth;
    for (uint8_t i = 0; i < depth; i++) {
        sockets[i].start = og_rotate(base_start, (float)i * rotation_step);
        sockets[i].end = og_rotate(base_end, (float)i * rotation_step);
    }
}

static uint8_t og_make_core_polygon(const og_socket_t *sockets, uint8_t depth, og_point_t *out) {
    uint8_t n = 0;
    for (uint8_t i = 0; i < depth; i++) {
        out[n++] = sockets[i].start;
        out[n++] = sockets[i].end;
    }
    return n;
}

/* Inward offset of a convex polygon by `thickness`, preserving vertex order
 * and count. Mirrors glyph-core's insetConvexPolygon exactly. */
static void og_inset_convex_polygon(const og_point_t *points, uint8_t n, float thickness, og_point_t *out) {
    if (n < 3 || thickness <= 0.0f) {
        memcpy(out, points, sizeof(og_point_t) * n);
        return;
    }

    float inward_sign = og_signed_area(points, n) >= 0.0f ? 1.0f : -1.0f;

    og_point_t line_point[OG_MAX_CORE_POINTS];
    og_point_t line_dir[OG_MAX_CORE_POINTS];

    for (uint8_t i = 0; i < n; i++) {
        og_point_t p = points[i];
        og_point_t next = points[(i + 1) % n];
        float dx = next.x - p.x;
        float dy = next.y - p.y;
        float len = sqrtf(dx * dx + dy * dy);
        if (len < 0.001f) {
            len = 0.001f;
        }
        og_point_t normal = {(-dy / len) * inward_sign, (dx / len) * inward_sign};
        line_point[i].x = p.x + normal.x * thickness;
        line_point[i].y = p.y + normal.y * thickness;
        line_dir[i].x = dx;
        line_dir[i].y = dy;
    }

    for (uint8_t i = 0; i < n; i++) {
        uint8_t prev = (uint8_t)((i + n - 1) % n);
        og_point_t result;
        if (!og_intersect_lines(line_point[prev], line_dir[prev], line_point[i], line_dir[i], &result)) {
            result = points[i];
        }
        out[i] = result;
    }
}

/* Re-bases an arm template (local x along the socket chord, local y outward)
 * onto the world position/orientation of a specific socket. Point count is
 * unchanged; the first/last points are snapped exactly onto the socket's
 * own chord endpoints (matching glyph-core's "aligned" behavior). */
static uint8_t og_arm_to_world_points(const og_arm_template_t *tmpl, uint8_t socket_index,
                                      const og_socket_t *sockets, og_point_t *out) {
    uint8_t n = tmpl->count;
    if (n < 2) {
        for (uint8_t i = 0; i < n; i++) {
            out[i] = tmpl->points[i];
        }
        return n;
    }

    og_socket_t socket = sockets[socket_index];
    og_point_t center = og_midpoint(socket.start, socket.end);
    float dx = socket.end.x - socket.start.x;
    float dy = socket.end.y - socket.start.y;
    float len = sqrtf(dx * dx + dy * dy);
    if (len < 0.001f) {
        len = 0.001f;
    }
    og_point_t tangent = {dx / len, dy / len};
    og_point_t outward = {tangent.y, -tangent.x};
    if (outward.x * center.x + outward.y * center.y < 0.0f) {
        outward.x = -outward.x;
        outward.y = -outward.y;
    }

    for (uint8_t i = 0; i < n; i++) {
        og_point_t aligned;
        if (i == 0) {
            aligned.x = -len / 2.0f;
            aligned.y = 0.0f;
        } else if (i == n - 1) {
            aligned.x = len / 2.0f;
            aligned.y = 0.0f;
        } else {
            aligned = tmpl->points[i];
        }
        out[i].x = center.x + tangent.x * aligned.x + outward.x * aligned.y;
        out[i].y = center.y + tangent.y * aligned.x + outward.y * aligned.y;
    }
    return n;
}

static uint8_t og_make_core_hole(const og_point_t *core_polygon, uint8_t core_len, uint8_t depth, og_point_t *out) {
    if (depth == OG_CORE_HOLE_LEGACY_EXACT_DEPTH) {
        memcpy(out, og_core_hole_legacy_points, sizeof(og_core_hole_legacy_points));
        return OG_CORE_HOLE_LEGACY_POINT_COUNT;
    }
    og_inset_convex_polygon(core_polygon, core_len, OG_INSET_THICKNESS, out);
    return core_len;
}

/* ---- depth / normalization ------------------------------------------------ */

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

/* Socket order at depth d is [0, d-1, d-2, ..., 1]; digitIndex 0 is the
 * fixed "current" socket, the rest walk backwards through history. */
static uint8_t og_digit_index_for_socket(uint8_t socket_index, uint8_t depth) {
    return socket_index == 0 ? 0 : (uint8_t)(depth - socket_index);
}

/* ---- frame bounds ---------------------------------------------------------
 * Stable per-depth bounding box: includes every arm template at every
 * socket (not just the ones a given value actually uses), so changing the
 * glyph's value never changes its layout/frame. */
void og_frame_bounds(uint8_t depth, float *out_x, float *out_y, float *out_width, float *out_height) {
    depth = og_clamp_depth(depth);

    og_socket_t sockets[OG_MAX_SOCKETS];
    og_make_sockets(depth, sockets);

    og_point_t core_polygon[OG_MAX_CORE_POINTS];
    uint8_t core_len = og_make_core_polygon(sockets, depth, core_polygon);

    og_point_t hole[OG_MAX_CORE_POINTS];
    uint8_t hole_len = og_make_core_hole(core_polygon, core_len, depth, hole);

    float min_x = 0.0f, max_x = 0.0f, min_y = 0.0f, max_y = 0.0f;
    int have_bounds = 0;

#define OG_ACCUMULATE(pt)                              \
    do {                                                \
        og_point_t _p = (pt);                           \
        if (!have_bounds) {                             \
            min_x = max_x = _p.x;                        \
            min_y = max_y = _p.y;                        \
            have_bounds = 1;                             \
        } else {                                         \
            if (_p.x < min_x) min_x = _p.x;               \
            if (_p.x > max_x) max_x = _p.x;               \
            if (_p.y < min_y) min_y = _p.y;               \
            if (_p.y > max_y) max_y = _p.y;               \
        }                                                \
    } while (0)

    for (uint8_t i = 0; i < core_len; i++) OG_ACCUMULATE(core_polygon[i]);
    for (uint8_t i = 0; i < hole_len; i++) OG_ACCUMULATE(hole[i]);

    for (uint8_t socket_index = 0; socket_index < depth; socket_index++) {
        for (uint8_t digit = 0; digit < OG_ARM_DIGIT_COUNT; digit++) {
            og_point_t world[OG_ARM_MAX_POINTS];
            uint8_t n = og_arm_to_world_points(&og_arm_templates[digit], socket_index, sockets, world);
            for (uint8_t i = 0; i < n; i++) OG_ACCUMULATE(world[i]);
        }
    }
#undef OG_ACCUMULATE

    float padding = OG_GRID_SIZE * OG_PADDING_CELLS;
    float max_abs_x = fabsf(min_x) > fabsf(max_x) ? fabsf(min_x) : fabsf(max_x);
    float max_abs_y = fabsf(min_y) > fabsf(max_y) ? fabsf(min_y) : fabsf(max_y);

    float half_width = ceilf(max_abs_x / OG_GRID_SIZE) * OG_GRID_SIZE + padding;
    float half_height = ceilf(max_abs_y / OG_GRID_SIZE) * OG_GRID_SIZE + padding;
    if (half_width < OG_GRID_SIZE) half_width = OG_GRID_SIZE;
    if (half_height < OG_GRID_SIZE) half_height = OG_GRID_SIZE;

    *out_x = -half_width;
    *out_y = -half_height;
    *out_width = half_width * 2.0f;
    *out_height = half_height * 2.0f;
}

/* ---- full glyph build ------------------------------------------------------ */

void og_build_glyph(uint32_t value, uint8_t depth, uint8_t split_after_digit_count, og_glyph_t *out) {
    depth = og_clamp_depth(depth);
    out->depth = depth;

    og_octal_digits_from_value(value, depth, out->normalized_value);

    og_socket_t sockets[OG_MAX_SOCKETS];
    og_make_sockets(depth, sockets);

    og_point_t core_polygon[OG_MAX_CORE_POINTS];
    uint8_t core_len = og_make_core_polygon(sockets, depth, core_polygon);

    og_point_t hole[OG_MAX_CORE_POINTS];
    uint8_t hole_len = og_make_core_hole(core_polygon, core_len, depth, hole);

    og_frame_bounds(depth, &out->frame_x, &out->frame_y, &out->frame_width, &out->frame_height);

    uint8_t shape_count = 0;

    /* shape 0: core (2 contours, even-odd hole) */
    og_shape_t *core_shape = &out->shapes[shape_count++];
    memcpy(core_shape->contours[0].points, core_polygon, sizeof(og_point_t) * core_len);
    core_shape->contours[0].count = core_len;
    memcpy(core_shape->contours[1].points, hole, sizeof(og_point_t) * hole_len);
    core_shape->contours[1].count = hole_len;
    core_shape->contour_count = 2;
    core_shape->color_role = OG_COLOR_SECONDARY;
    core_shape->socket_index = -1;
    core_shape->digit_index = -1;
    core_shape->digit = -1;

    for (uint8_t socket_index = 0; socket_index < depth; socket_index++) {
        uint8_t digit_index = og_digit_index_for_socket(socket_index, depth);
        uint8_t digit = (uint8_t)(out->normalized_value[digit_index] - '0');
        if (digit >= OG_ARM_DIGIT_COUNT) {
            digit = 0; /* defensive; normalize already guarantees 0-7 */
        }

        og_point_t world[OG_ARM_MAX_POINTS];
        uint8_t n = og_arm_to_world_points(&og_arm_templates[digit], socket_index, sockets, world);
        if (n < 3) {
            continue; /* digit 0 (or any degenerate template) has no visible arm */
        }

        og_shape_t *arm_shape = &out->shapes[shape_count++];
        memcpy(arm_shape->contours[0].points, world, sizeof(og_point_t) * n);
        arm_shape->contours[0].count = n;
        arm_shape->contour_count = 1;

        if (split_after_digit_count == 0) {
            arm_shape->color_role = OG_COLOR_PRIMARY;
        } else {
            arm_shape->color_role = (digit_index < split_after_digit_count) ? OG_COLOR_PRIMARY : OG_COLOR_SECONDARY;
        }
        arm_shape->socket_index = (int8_t)socket_index;
        arm_shape->digit_index = (int8_t)digit_index;
        arm_shape->digit = (int8_t)digit;
    }

    out->shape_count = shape_count;
}
