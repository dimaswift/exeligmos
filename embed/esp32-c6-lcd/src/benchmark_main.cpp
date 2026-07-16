/**
 * OctalGlyph render-time benchmark.
 *
 * Six persistent glyphs whose values increment every loop iteration, as
 * fast as possible (no throttling): each iteration bumps all 6 values and
 * forces an immediate synchronous redraw with lv_refr_now(), so the timed
 * work is exactly "update + render 6 glyphs", not blurred by LVGL's normal
 * timer-handler cadence. Throughput (updates/sec and average render time)
 * is accumulated over a rolling ~500ms window and reported both over
 * Serial (CSV: elapsed_ms,total_updates,updates_per_sec,avg_render_us) and
 * on the display.
 *
 * The sprite-based renderer draws every glyph at a fixed 120x120px canvas
 * regardless of its object's box size (see octal-glyph-lvgl's README), so
 * 6 of them can't tile edge-to-edge on this 172x320 panel without either
 * shrinking below the baked size (which would just clip, not scale) or
 * overlapping. This benchmark deliberately overlaps them in a loose 2x3
 * grid -- each glyph is still fully on-screen and gets a full, unculled
 * lv_draw_arc + lv_draw_image pass every iteration (LVGL only culls what's
 * clipped by the *display* bounds, not by sibling widgets drawing over
 * each other), so the timing stays a true "6 real glyphs" measurement even
 * though the layout looks stacked.
 *
 * Build/flash with: pio run -e benchmark -t upload
 */
#include <Arduino.h>
#include <ESP32C6LCD147.h>
#include <lv_octal_glyph.h>

namespace board = esp32_c6_lcd_147;

board::DeviceConfig makeDeviceConfig()
{
  board::DeviceConfig config;
  config.mountSd = false;
  config.sdRequired = false;
  config.ui.showBootScreen = false;
  config.ui.doubleBuffer = false;
  config.ui.bufferRows = 8;
  return config;
}

board::Device device(makeDeviceConfig());

namespace
{
constexpr uint16_t kGlyphCount = 6;
constexpr uint16_t kGlyphBox = 120;   // fixed sprite canvas size (OG_SPRITE_CANVAS_SIZE)
constexpr uint16_t kCols = 2;
constexpr uint16_t kColSpacing = 52;  // < kGlyphBox on purpose -- see header comment (overlap ok)
constexpr uint16_t kRowSpacing = 88;  // < kGlyphBox on purpose -- see header comment (overlap ok)
constexpr uint16_t kTopMargin = 24;
constexpr uint32_t kReportIntervalMs = 500;

lv_obj_t *statusLabel = nullptr;
lv_obj_t *glyphs[kGlyphCount];

uint32_t counter = 0;
uint32_t updatesInWindow = 0;
uint64_t renderUsInWindow = 0;
uint32_t lastReportMs = 0;
uint32_t totalUpdates = 0;
} // namespace

void setup()
{
  Serial.begin(115200);
  delay(200);

  if (!device.begin())
  {
    Serial.printf("Device init failed: %s\n", device.lastError());
    return;
  }

  lv_obj_t *screen = device.ui().screen();
  lv_obj_set_style_bg_color(screen, lv_color_hex(0x101820), 0);
  lv_obj_set_style_bg_opa(screen, LV_OPA_COVER, 0);

  statusLabel = lv_label_create(screen);
  lv_obj_set_style_text_color(statusLabel, lv_color_hex(0xFFFFFF), 0);
  lv_obj_align(statusLabel, LV_ALIGN_TOP_MID, 0, 4);
  lv_label_set_text(statusLabel, "warming up...");

  uint16_t gridWidth = kGlyphBox + (kCols - 1) * kColSpacing;
  uint16_t startX = (device.display().width() - gridWidth) / 2;
  for (uint16_t i = 0; i < kGlyphCount; i++)
  {
    uint16_t col = i % kCols;
    uint16_t row = i / kCols;

    lv_obj_t *g = lv_octal_glyph_create(screen);
    lv_obj_set_size(g, kGlyphBox, kGlyphBox);
    lv_obj_set_pos(g, startX + col * kColSpacing, kTopMargin + row * kRowSpacing);
    lv_octal_glyph_set_depth(g, 7);
    lv_octal_glyph_set_value(g, i);
    lv_octal_glyph_set_colors(g, lv_color_hex(0xFFFFFF), lv_color_hex(0x8E8E93));
    glyphs[i] = g;
  }

  Serial.println("elapsed_ms,total_updates,updates_per_sec,avg_render_us");
  lastReportMs = millis();
}

void loop()
{
  counter++;

  uint32_t startUs = micros();
  for (uint16_t i = 0; i < kGlyphCount; i++)
  {
    lv_octal_glyph_set_value(glyphs[i], counter + i);
  }
  lv_refr_now(NULL);
  uint32_t elapsedUs = micros() - startUs;

  totalUpdates++;
  updatesInWindow++;
  renderUsInWindow += elapsedUs;

  uint32_t now = millis();
  uint32_t windowMs = now - lastReportMs;
  if (windowMs >= kReportIntervalMs)
  {
    float updatesPerSec = updatesInWindow * 1000.0f / (float)windowMs;
    float avgUs = updatesInWindow > 0 ? (float)renderUsInWindow / (float)updatesInWindow : 0.0f;

    lv_label_set_text_fmt(statusLabel, "%u updates  %.1f/s  %.0f us/update",
                          (unsigned)totalUpdates, updatesPerSec, avgUs);

    Serial.printf("%u,%u,%.2f,%.1f\n", (unsigned)now, (unsigned)totalUpdates, updatesPerSec, avgUs);

    updatesInWindow = 0;
    renderUsInWindow = 0;
    lastReportMs = now;
  }
}
