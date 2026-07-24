#include "octal_glyph_raster.h"

#include <string.h>
#include <math.h>

/* 4 vertical subsamples per scanline; horizontal coverage is exact
 * (per-pixel overlap of the subsample's span against each pixel's [x,x+1)
 * interval), so effective quality is close to full 2D supersampling without
 * needing >1 horizontal sample. */
#define OG_RASTER_VSAMPLES 4

/* Generous static caps so the rasterizer needs no heap allocation of its
 * own: a shape has at most 2 contours * OG_MAX_CONTOUR_POINTS (16) points,
 * i.e. at most 32 edges; row width is capped defensively (glyphs render at
 * most a few hundred px in any realistic use of this widget). */
#define OG_RASTER_MAX_EDGES 40
#define OG_RASTER_MAX_ROW_PX 512

typedef struct {
    float x0, y0, x1, y1; /* directed edge; y0 != y1 always (horizontal edges dropped) */
    int winding;          /* +1 if y increases along the edge, -1 otherwise */
} og_edge_t;

typedef struct {
    float x;
    int winding;
} og_crossing_t;

static int og_collect_edges(const og_shape_t *shape, float ox, float oy, float pad_x, float pad_y,
                            float scale, og_edge_t *edges, int max_edges) {
    int n = 0;
    for (uint8_t c = 0; c < shape->contour_count && n < max_edges; c++) {
        const og_contour_t *contour = &shape->contours[c];
        uint8_t count = contour->count;
        if (count < 2) {
            continue;
        }
        for (uint8_t i = 0; i < count && n < max_edges; i++) {
            const og_point_t *p0 = &contour->points[i];
            const og_point_t *p1 = &contour->points[(i + 1) % count];
            float x0 = (p0->x - ox) * scale + pad_x;
            float y0 = (p0->y - oy) * scale + pad_y;
            float x1 = (p1->x - ox) * scale + pad_x;
            float y1 = (p1->y - oy) * scale + pad_y;
            if (y0 == y1) {
                continue; /* horizontal edges contribute no scanline crossings */
            }
            edges[n].x0 = x0;
            edges[n].y0 = y0;
            edges[n].x1 = x1;
            edges[n].y1 = y1;
            edges[n].winding = (y1 > y0) ? 1 : -1;
            n++;
        }
    }
    return n;
}

/* Adds `weight` coverage for the portion of [xa,xb) (absolute pixel-space
 * coordinates) that overlaps each pixel column in cov[0..row_w), where
 * cov[k] corresponds to absolute column (x_start + k). */
static void og_accumulate_span(float *cov, int x_start, int row_w, float xa, float xb, float weight) {
    if (xb <= xa) {
        return;
    }
    float lo = xa - (float)x_start;
    float hi = xb - (float)x_start;
    if (hi <= 0.0f || lo >= (float)row_w) {
        return;
    }
    if (lo < 0.0f) {
        lo = 0.0f;
    }
    if (hi > (float)row_w) {
        hi = (float)row_w;
    }
    int ix0 = (int)floorf(lo);
    int ix1 = (int)floorf(hi - 1e-5f);
    if (ix0 < 0) {
        ix0 = 0;
    }
    if (ix1 >= row_w) {
        ix1 = row_w - 1;
    }
    for (int x = ix0; x <= ix1; x++) {
        float px_lo = (float)x;
        float px_hi = (float)(x + 1);
        float overlap_lo = lo > px_lo ? lo : px_lo;
        float overlap_hi = hi < px_hi ? hi : px_hi;
        float overlap = overlap_hi - overlap_lo;
        if (overlap > 0.0f) {
            cov[x] += overlap * weight;
        }
    }
}

static void og_rasterize_shape(const og_shape_t *shape, float ox, float oy, float pad_x, float pad_y,
                               float scale, uint32_t rgb, int32_t w, int32_t h, uint8_t *buf) {
    og_edge_t edges[OG_RASTER_MAX_EDGES];
    int edge_count = og_collect_edges(shape, ox, oy, pad_x, pad_y, scale, edges, OG_RASTER_MAX_EDGES);
    if (edge_count == 0) {
        return;
    }

    float minx = edges[0].x0, maxx = edges[0].x0, miny = edges[0].y0, maxy = edges[0].y0;
    for (int i = 0; i < edge_count; i++) {
        float exmin = edges[i].x0 < edges[i].x1 ? edges[i].x0 : edges[i].x1;
        float exmax = edges[i].x0 > edges[i].x1 ? edges[i].x0 : edges[i].x1;
        float eymin = edges[i].y0 < edges[i].y1 ? edges[i].y0 : edges[i].y1;
        float eymax = edges[i].y0 > edges[i].y1 ? edges[i].y0 : edges[i].y1;
        if (exmin < minx) minx = exmin;
        if (exmax > maxx) maxx = exmax;
        if (eymin < miny) miny = eymin;
        if (eymax > maxy) maxy = eymax;
    }

    int y_start = (int)floorf(miny);
    int y_end = (int)ceilf(maxy);
    int x_start = (int)floorf(minx);
    int x_end = (int)ceilf(maxx);
    if (y_start < 0) y_start = 0;
    if (y_end > h) y_end = h;
    if (x_start < 0) x_start = 0;
    if (x_end > w) x_end = w;
    if (x_end <= x_start || y_end <= y_start) {
        return;
    }

    int row_w = x_end - x_start;
    if (row_w > OG_RASTER_MAX_ROW_PX) {
        row_w = OG_RASTER_MAX_ROW_PX; /* defensive clamp; not expected at realistic sizes */
    }

    float cov[OG_RASTER_MAX_ROW_PX];
    og_crossing_t crossings[OG_RASTER_MAX_EDGES];

    uint8_t sr = (uint8_t)((rgb >> 16) & 0xFFu);
    uint8_t sg = (uint8_t)((rgb >> 8) & 0xFFu);
    uint8_t sb = (uint8_t)(rgb & 0xFFu);

    int nonzero_rule = (shape->contour_count <= 1);
    const float weight = 1.0f / (float)OG_RASTER_VSAMPLES;

    for (int y = y_start; y < y_end; y++) {
        memset(cov, 0, sizeof(float) * (size_t)row_w);

        for (int s = 0; s < OG_RASTER_VSAMPLES; s++) {
            float suby = (float)y + ((float)s + 0.5f) * weight;
            int nx = 0;
            for (int i = 0; i < edge_count; i++) {
                float ylo = edges[i].y0 < edges[i].y1 ? edges[i].y0 : edges[i].y1;
                float yhi = edges[i].y0 < edges[i].y1 ? edges[i].y1 : edges[i].y0;
                if (suby < ylo || suby >= yhi) {
                    continue;
                }
                float t = (suby - edges[i].y0) / (edges[i].y1 - edges[i].y0);
                crossings[nx].x = edges[i].x0 + t * (edges[i].x1 - edges[i].x0);
                crossings[nx].winding = edges[i].winding;
                nx++;
            }
            /* insertion sort by x -- nx is small (<= edge_count <= 40) */
            for (int a = 1; a < nx; a++) {
                og_crossing_t key = crossings[a];
                int b = a - 1;
                while (b >= 0 && crossings[b].x > key.x) {
                    crossings[b + 1] = crossings[b];
                    b--;
                }
                crossings[b + 1] = key;
            }

            if (nonzero_rule) {
                int winding = 0;
                for (int k = 0; k + 1 < nx; k++) {
                    winding += crossings[k].winding;
                    if (winding != 0) {
                        og_accumulate_span(cov, x_start, row_w, crossings[k].x, crossings[k + 1].x, weight);
                    }
                }
            } else {
                for (int k = 0; k + 1 < nx; k += 2) {
                    og_accumulate_span(cov, x_start, row_w, crossings[k].x, crossings[k + 1].x, weight);
                }
            }
        }

        uint8_t *row = buf + (size_t)y * (size_t)w * 4u;
        for (int x = 0; x < row_w; x++) {
            float c = cov[x];
            if (c <= 0.0f) {
                continue;
            }
            if (c > 1.0f) {
                c = 1.0f;
            }
            uint8_t *p = row + (size_t)(x_start + x) * 4u; /* B,G,R,A */
            float dstA = p[3] / 255.0f;
            float srcA = c;
            float outA = srcA + dstA * (1.0f - srcA);
            if (outA <= 0.0f) {
                p[0] = p[1] = p[2] = p[3] = 0;
                continue;
            }
            float dstFactor = dstA * (1.0f - srcA);
            float outR = ((float)sr * srcA + (float)p[2] * dstFactor) / outA;
            float outG = ((float)sg * srcA + (float)p[1] * dstFactor) / outA;
            float outB = ((float)sb * srcA + (float)p[0] * dstFactor) / outA;
            p[2] = (uint8_t)(outR + 0.5f);
            p[1] = (uint8_t)(outG + 0.5f);
            p[0] = (uint8_t)(outB + 0.5f);
            p[3] = (uint8_t)(outA * 255.0f + 0.5f);
        }
    }
}

void og_glyph_rasterize(const og_glyph_t *glyph, uint32_t primary_rgb, uint32_t secondary_rgb,
                        int32_t w, int32_t h, uint8_t *buf) {
    if (w <= 0 || h <= 0 || buf == NULL) {
        return;
    }
    memset(buf, 0, (size_t)w * (size_t)h * 4u);

    if (glyph->frame_width <= 0.0f || glyph->frame_height <= 0.0f) {
        return;
    }

    float scale_x = (float)w / glyph->frame_width;
    float scale_y = (float)h / glyph->frame_height;
    float scale = scale_x < scale_y ? scale_x : scale_y;

    float scaled_w = glyph->frame_width * scale;
    float scaled_h = glyph->frame_height * scale;
    float pad_x = ((float)w - scaled_w) * 0.5f;
    float pad_y = ((float)h - scaled_h) * 0.5f;

    for (uint8_t i = 0; i < glyph->shape_count; i++) {
        const og_shape_t *shape = &glyph->shapes[i];
        uint32_t rgb = (shape->color_role == OG_COLOR_PRIMARY) ? primary_rgb : secondary_rgb;
        og_rasterize_shape(shape, glyph->frame_x, glyph->frame_y, pad_x, pad_y, scale, rgb, w, h, buf);
    }
}

og_dirty_rect_t og_glyph_diff_rect(const uint8_t *prev, const uint8_t *next, int32_t w, int32_t h) {
    og_dirty_rect_t r = {0, 0, 0, 0, 0};
    if (w <= 0 || h <= 0 || prev == NULL || next == NULL) {
        return r;
    }

    size_t stride = (size_t)w * 4u;
    int32_t min_y = -1, max_y = -1;
    int32_t min_x = w, max_x = -1;

    for (int32_t y = 0; y < h; y++) {
        const uint8_t *rp = prev + (size_t)y * stride;
        const uint8_t *rn = next + (size_t)y * stride;
        if (memcmp(rp, rn, stride) == 0) {
            continue; /* whole row identical -- skip the per-pixel scan */
        }
        if (min_y < 0) {
            min_y = y;
        }
        max_y = y;

        int32_t row_min = -1, row_max = -1;
        for (int32_t x = 0; x < w; x++) {
            const uint8_t *pp = rp + (size_t)x * 4u;
            const uint8_t *pn = rn + (size_t)x * 4u;
            if (pp[0] != pn[0] || pp[1] != pn[1] || pp[2] != pn[2] || pp[3] != pn[3]) {
                if (row_min < 0) {
                    row_min = x;
                }
                row_max = x;
            }
        }
        if (row_min >= 0) {
            if (row_min < min_x) {
                min_x = row_min;
            }
            if (row_max > max_x) {
                max_x = row_max;
            }
        }
    }

    if (min_y < 0 || max_x < 0) {
        return r; /* buffers are pixel-identical */
    }

    r.x0 = min_x;
    r.y0 = min_y;
    r.x1 = max_x + 1;
    r.y1 = max_y + 1;
    r.valid = 1;
    return r;
}
