/**
 * Saros clock -- raw display (no LVGL), WiFi + NTP synced, dirty-rect only.
 *
 * Not a conventional HH:MM:SS clock: it shows where we are, as a 10-digit
 * octal fraction, between the last and next eclipse of a chosen solar
 * Saros series (141 by default) -- ported from the reference watchface's
 * "fixed" display mode:
 *   /Users/dimas/projects/zepp-faces/exeligmos/watchface/index.js
 * (the math + data port lives in the fractonica-embed library's
 * saros_clock.h/.c and saros_data.h -- see their doc comments for how the
 * eclipse data was cross-checked against the canonical dataset in
 * web/app/features/temporal).
 *
 * The 10-digit octal address is split into two 5-digit halves -- same
 * split the reference watchface uses -- each driving one depth-5
 * og_octal_glyph. Both glyphs render in a single flat color (matching the
 * reference: its glyph assets are always the "white" set regardless of
 * mode) on a black background, using the raw Display + dirty-rect update
 * pipeline from the previous benchmark (see that file's history for why
 * LVGL is bypassed entirely on this board, and for the diff-rect
 * mechanics). Saros 141's low digit advances roughly every ~0.5s, so this
 * is a real, continuously-ticking demonstration of that fast path: the
 * high-digit glyph barely ever changes (its fastest digit turns over
 * every few hours), so most loop iterations only touch the low glyph, and
 * only its small dirty region.
 *
 * Build/flash with: pio run -t upload
 */
#include <Arduino.h>
#include <ESP32C6LCD147.h>
#include <WiFi.h>
#include <time.h>
#include <sys/time.h>

#include <octal_glyph_geometry.h>
#include <octal_glyph_raster.h>
#include <saros_clock.h>

namespace board = esp32_c6_lcd_147;

board::DeviceConfig makeDeviceConfig()
{
  board::DeviceConfig config;
  config.mountSd = false;
  config.sdRequired = false;
  return config;
}

board::Device device(makeDeviceConfig());

namespace
{
  constexpr const char *kWifiSsid = "TENRETNI";
  constexpr const char *kWifiPassword = "skibidi5";

  constexpr uint8_t kFixedSaros = 141; /* matches the reference watchface's FIXED_SAROS default */
  constexpr uint8_t kGlyphDepth = SAROS_HALF_DIGITS; /* 5 -- one glyph per half of the 10-digit address */

  constexpr int32_t kGlyphBox = 130;
  constexpr uint16_t kRowSpacing = 15;
  constexpr uint16_t kTopMargin = 34;
  constexpr uint32_t kStatusIntervalMs = 2000;

  /* Single flat color for both core and arms, on a pure black background --
   * matches the reference watchface, whose glyph image assets are always
   * the "white" set regardless of display mode. */
  constexpr uint32_t kGlyphRgb = 0xFFFFFF;
  constexpr uint8_t kBgR = 0, kBgG = 0, kBgB = 0;

  uint16_t rgb565From888(uint8_t r, uint8_t g, uint8_t b)
  {
    return (uint16_t)(((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3));
  }

  void compositeRegionToRgb565(const uint8_t *argbFull, int32_t fullW,
                               int32_t x0, int32_t y0, int32_t rectW, int32_t rectH,
                               uint16_t *out)
  {
    for (int32_t ry = 0; ry < rectH; ry++)
    {
      const uint8_t *row = argbFull + (size_t)(y0 + ry) * (size_t)fullW * 4u + (size_t)x0 * 4u;
      uint16_t *outRow = out + (size_t)ry * (size_t)rectW;
      for (int32_t rx = 0; rx < rectW; rx++)
      {
        uint8_t b = row[rx * 4 + 0];
        uint8_t g = row[rx * 4 + 1];
        uint8_t r = row[rx * 4 + 2];
        uint8_t a = row[rx * 4 + 3];
        uint8_t outR = (uint8_t)(((uint16_t)r * a + (uint16_t)kBgR * (255 - a)) / 255);
        uint8_t outG = (uint8_t)(((uint16_t)g * a + (uint16_t)kBgG * (255 - a)) / 255);
        uint8_t outB = (uint8_t)(((uint16_t)b * a + (uint16_t)kBgB * (255 - a)) / 255);
        outRow[rx] = rgb565From888(outR, outG, outB);
      }
    }
  }

  struct GlyphSlot
  {
    uint8_t bufferA[kGlyphBox * kGlyphBox * 4];
    uint8_t bufferB[kGlyphBox * kGlyphBox * 4];
    uint8_t *front;
    uint8_t *back;
    uint16_t x, y;
    bool primed;
  };

  /* Two slots: index 0 = high 5 digits (barely ever changes), index 1 =
   * low 5 digits (the fast-ticking one). Static, not stack: each slot is
   * ~135KB (two 130x130 ARGB8888 buffers). */
  /* Total static budget: 2 * 135200 + 33800 (rgb565Scratch) = ~304KB of the
   * ESP32-C6's 512KB SRAM, before WiFi's own buffers/stack. Fine alongside
   * WiFi alone (no BT, no SD in this build); if allocation issues show up
   * once WiFi is active, kGlyphBox is the lever to shrink first. */
  GlyphSlot slots[2];
  uint16_t rgb565Scratch[kGlyphBox * kGlyphBox]; /* shared, reused per-glyph push */

  uint32_t lastStatusMs = 0;
  uint32_t updatesInWindow = 0;
  uint64_t updateUsInWindow = 0;
  uint64_t pushedPxInWindow = 0;

  void connectWifi()
  {
    Serial.printf("connecting to WiFi \"%s\"...\n", kWifiSsid);
    WiFi.mode(WIFI_STA);
    WiFi.begin(kWifiSsid, kWifiPassword);

    uint32_t lastAttemptMs = millis();
    while (WiFi.status() != WL_CONNECTED)
    {
      delay(250);
      Serial.print(".");
      if (millis() - lastAttemptMs > 15000)
      {
        Serial.println("\nstill not connected, retrying WiFi.begin()...");
        WiFi.disconnect();
        WiFi.begin(kWifiSsid, kWifiPassword);
        lastAttemptMs = millis();
      }
    }
    Serial.printf("\nWiFi connected, IP: %s\n", WiFi.localIP().toString().c_str());
  }

  void syncTimeViaNtp()
  {
    Serial.println("syncing time via NTP (UTC)...");
    configTime(0, 0, "pool.ntp.org", "time.nist.gov", "time.google.com");

    struct timeval tv;
    while (true)
    {
      gettimeofday(&tv, nullptr);
      if (tv.tv_sec > 1700000000) /* sane "must be synced" threshold (~Nov 2023) */
      {
        break;
      }
      delay(250);
      Serial.print(".");
    }
    Serial.printf("\ntime synced: %ld (unix seconds, UTC)\n", (long)tv.tv_sec);
  }

  double nowSecondsUtc()
  {
    struct timeval tv;
    gettimeofday(&tv, nullptr);
    return (double)tv.tv_sec + (double)tv.tv_usec / 1e6;
  }

  void initGlyphSlot(GlyphSlot &slot, uint16_t x, uint16_t y)
  {
    slot.front = slot.bufferA;
    slot.back = slot.bufferB;
    slot.x = x;
    slot.y = y;
    slot.primed = false;
  }

  /* Rasterizes `value` into slot.back, pushes only what changed relative
   * to slot.front (or the whole box on the first call for this slot),
   * then swaps front/back. Returns the number of pixels actually pushed. */
  uint32_t updateGlyphSlot(GlyphSlot &slot, uint32_t value)
  {
    og_glyph_t model;
    og_build_glyph(value, kGlyphDepth, 0, &model);
    og_glyph_rasterize(&model, kGlyphRgb, kGlyphRgb, kGlyphBox, kGlyphBox, slot.back);

    uint32_t pushedPx = 0;
    if (!slot.primed)
    {
      compositeRegionToRgb565(slot.back, kGlyphBox, 0, 0, kGlyphBox, kGlyphBox, rgb565Scratch);
      device.display().drawPixels(slot.x, slot.y, kGlyphBox, kGlyphBox, rgb565Scratch,
                                  board::PixelByteOrder::LittleEndian);
      pushedPx = (uint32_t)(kGlyphBox * kGlyphBox);
      slot.primed = true;
    }
    else
    {
      og_dirty_rect_t dirty = og_glyph_diff_rect(slot.front, slot.back, kGlyphBox, kGlyphBox);
      if (dirty.valid)
      {
        int32_t rectW = dirty.x1 - dirty.x0;
        int32_t rectH = dirty.y1 - dirty.y0;
        pushedPx = (uint32_t)(rectW * rectH);
        compositeRegionToRgb565(slot.back, kGlyphBox, dirty.x0, dirty.y0, rectW, rectH, rgb565Scratch);
        device.display().drawPixels((int16_t)(slot.x + dirty.x0), (int16_t)(slot.y + dirty.y0),
                                    (uint16_t)rectW, (uint16_t)rectH, rgb565Scratch,
                                    board::PixelByteOrder::LittleEndian);
      }
    }

    uint8_t *tmp = slot.front;
    slot.front = slot.back;
    slot.back = tmp;
    return pushedPx;
  }
}

void setup()
{
  Serial.begin(115200);
  delay(200);
  Serial.println("=== Saros clock (WiFi + NTP synced, no LVGL, dirty-rect only) ===");

  if (!device.display().begin())
  {
    Serial.printf("Display init failed: %s\n", device.display().lastError());
    return;
  }
  device.display().fill(rgb565From888(kBgR, kBgG, kBgB));

  connectWifi();
  syncTimeViaNtp();

  uint16_t w = device.display().width();
  uint16_t startX = (w - kGlyphBox) / 2;
  initGlyphSlot(slots[0], startX, kTopMargin);
  initGlyphSlot(slots[1], startX, kTopMargin + kGlyphBox + kRowSpacing);

  lastStatusMs = millis();
}

void loop()
{
  double nowSeconds = nowSecondsUtc();

  saros_reading_t reading;
  static saros_reading_t lastGoodReading = {0, 0, 0};
  if (saros_reading_at(kFixedSaros, nowSeconds, &reading))
  {
    lastGoodReading = reading;
  }
  else
  {
    reading = lastGoodReading; /* hold last good value rather than show garbage */
  }

  uint32_t startUs = micros();
  uint32_t pushedPx = 0;
  pushedPx += updateGlyphSlot(slots[0], reading.high_value);
  pushedPx += updateGlyphSlot(slots[1], reading.low_value);
  uint32_t elapsedUs = micros() - startUs;

  updatesInWindow++;
  updateUsInWindow += elapsedUs;
  pushedPxInWindow += pushedPx;

  uint32_t now = millis();
  if (now - lastStatusMs >= kStatusIntervalMs)
  {
    float avgUs = updatesInWindow > 0 ? (float)updateUsInWindow / (float)updatesInWindow : 0.0f;
    float avgPushedPx = updatesInWindow > 0 ? (float)pushedPxInWindow / (float)updatesInWindow : 0.0f;
    Serial.printf("saros=%u bin=%u high=%u low=%u  avg_update_us=%.1f  avg_pushed_px=%.0f  updates=%u  heap=%u\n",
                 (unsigned)kFixedSaros, (unsigned)reading.bin_index,
                 (unsigned)reading.high_value, (unsigned)reading.low_value,
                 avgUs, avgPushedPx, (unsigned)updatesInWindow, (unsigned)ESP.getFreeHeap());
    updatesInWindow = 0;
    updateUsInWindow = 0;
    pushedPxInWindow = 0;
    lastStatusMs = now;
  }
}
