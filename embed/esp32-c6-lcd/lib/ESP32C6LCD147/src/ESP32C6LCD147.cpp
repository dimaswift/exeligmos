#include "ESP32C6LCD147.h"

#include <algorithm>
#include <cstring>

#include <esp_heap_caps.h>

namespace esp32_c6_lcd_147 {
namespace {

constexpr uint8_t kCmdSleepOut = 0x11;
constexpr uint8_t kCmdDisplayOff = 0x28;
constexpr uint8_t kCmdDisplayOn = 0x29;
constexpr uint8_t kCmdColumnAddressSet = 0x2A;
constexpr uint8_t kCmdRowAddressSet = 0x2B;
constexpr uint8_t kCmdMemoryWrite = 0x2C;
constexpr uint8_t kCmdMemoryAccessControl = 0x36;
constexpr uint8_t kCmdPixelFormat = 0x3A;
constexpr uint8_t kCmdDisplayInversionOff = 0x20;
constexpr uint8_t kCmdDisplayInversionOn = 0x21;
constexpr uint8_t kCmdSleepIn = 0x10;

uint8_t clampPercent(uint8_t percent) {
  return percent > 100 ? 100 : percent;
}

}  // namespace

Display::Display(DisplayConfig config) : config_(config) {}

SPIClass &Display::spi() {
  return config_.spi == nullptr ? SPI : *config_.spi;
}

bool Display::begin() {
  ready_ = false;
  setError("ok");

  pinMode(config_.cs, OUTPUT);
  pinMode(config_.dc, OUTPUT);
  pinMode(config_.rst, OUTPUT);
  digitalWrite(config_.cs, HIGH);
  digitalWrite(config_.dc, HIGH);

  if (!beginSpi()) {
    return false;
  }
  if (!beginBacklight()) {
    return false;
  }

  hardwareReset();
  initializePanel();
  setBrightness(config_.initialBrightness);

  ready_ = true;
  fill(0x0000);
  return true;
}

void Display::end() {
  if (config_.backlight >= 0 && backlightAttached_) {
    ledcWrite(config_.backlight, 0);
    ledcDetach(config_.backlight);
  }
  backlightAttached_ = false;
  ready_ = false;
}

bool Display::beginSpi() {
  if (!spi().begin(config_.sclk, config_.miso, config_.mosi, config_.cs)) {
    setError("lcd spi begin failed");
    return false;
  }
  return true;
}

bool Display::beginBacklight() {
  if (config_.backlight < 0) {
    return true;
  }

  if (!ledcAttach(config_.backlight, config_.backlightFrequency, config_.backlightResolution)) {
    setError("backlight pwm attach failed");
    return false;
  }

  backlightAttached_ = true;
  return true;
}

void Display::hardwareReset() {
  digitalWrite(config_.cs, HIGH);
  digitalWrite(config_.rst, HIGH);
  delay(20);
  digitalWrite(config_.rst, LOW);
  delay(50);
  digitalWrite(config_.rst, HIGH);
  delay(120);
}

void Display::initializePanel() {
  writeCommand(kCmdSleepOut);
  delay(120);

  const uint8_t madctl = config_.madctl;
  writeCommandData(kCmdMemoryAccessControl, &madctl, 1);

  const uint8_t colorMode = 0x05;
  writeCommandData(kCmdPixelFormat, &colorMode, 1);

  const uint8_t ramControl[] = {0x00, 0xE8};
  writeCommandData(0xB0, ramControl, sizeof(ramControl));

  const uint8_t porchControl[] = {0x0C, 0x0C, 0x00, 0x33, 0x33};
  writeCommandData(0xB2, porchControl, sizeof(porchControl));

  const uint8_t gateControl = 0x35;
  writeCommandData(0xB7, &gateControl, 1);

  const uint8_t vcom = 0x35;
  writeCommandData(0xBB, &vcom, 1);

  const uint8_t lcmControl = 0x2C;
  writeCommandData(0xC0, &lcmControl, 1);

  const uint8_t vdvVrhEnable = 0x01;
  writeCommandData(0xC2, &vdvVrhEnable, 1);

  const uint8_t vrh = 0x13;
  writeCommandData(0xC3, &vrh, 1);

  const uint8_t vdv = 0x20;
  writeCommandData(0xC4, &vdv, 1);

  const uint8_t frameRate = 0x0F;
  writeCommandData(0xC6, &frameRate, 1);

  const uint8_t powerControl[] = {0xA4, 0xA1};
  writeCommandData(0xD0, powerControl, sizeof(powerControl));

  const uint8_t gateControl2 = 0xA1;
  writeCommandData(0xD6, &gateControl2, 1);

  const uint8_t positiveGamma[] = {
      0xF0, 0x00, 0x04, 0x04, 0x04, 0x05, 0x29,
      0x33, 0x3E, 0x38, 0x12, 0x12, 0x28, 0x30,
  };
  writeCommandData(0xE0, positiveGamma, sizeof(positiveGamma));

  const uint8_t negativeGamma[] = {
      0xF0, 0x07, 0x0A, 0x0D, 0x0B, 0x07, 0x28,
      0x33, 0x3E, 0x36, 0x14, 0x14, 0x29, 0x32,
  };
  writeCommandData(0xE1, negativeGamma, sizeof(negativeGamma));

  writeCommand(config_.invertColors ? kCmdDisplayInversionOn : kCmdDisplayInversionOff);
  writeCommand(kCmdDisplayOn);
  delay(20);
}

bool Display::fill(uint16_t rgb565) {
  return fillRect(0, 0, config_.width, config_.height, rgb565);
}

bool Display::fillRect(int16_t x, int16_t y, uint16_t width, uint16_t height, uint16_t rgb565) {
  if (!ready_ || width == 0 || height == 0) {
    return false;
  }
  if (!clipRect(x, y, width, height)) {
    return false;
  }

  const uint8_t pattern[] = {static_cast<uint8_t>(rgb565 >> 8), static_cast<uint8_t>(rgb565 & 0xFF)};
  const uint32_t pixelCount = static_cast<uint32_t>(width) * height;

  startPixelWrite(static_cast<uint16_t>(x), static_cast<uint16_t>(y), width, height);
  spi().writePattern(pattern, sizeof(pattern), pixelCount);
  endTransaction();
  return true;
}

bool Display::drawPixel(int16_t x, int16_t y, uint16_t rgb565) {
  return fillRect(x, y, 1, 1, rgb565);
}

bool Display::drawPixels(int16_t x,
                         int16_t y,
                         uint16_t width,
                         uint16_t height,
                         const uint16_t *pixels,
                         PixelByteOrder byteOrder) {
  if (!ready_ || pixels == nullptr || width == 0 || height == 0) {
    return false;
  }

  const uint16_t sourceWidth = width;
  uint16_t sourceX = 0;
  uint16_t sourceY = 0;
  if (!clipSourceRect(x, y, width, height, sourceX, sourceY)) {
    return false;
  }

  startPixelWrite(static_cast<uint16_t>(x), static_cast<uint16_t>(y), width, height);
  for (uint16_t row = 0; row < height; ++row) {
    const uint16_t *rowPixels = pixels + (static_cast<size_t>(sourceY + row) * sourceWidth) + sourceX;
    writePixelData(rowPixels, width, byteOrder);
  }
  endTransaction();
  return true;
}

void Display::setBrightness(uint8_t percent) {
  brightness_ = clampPercent(percent);
  if (config_.backlight < 0 || !backlightAttached_) {
    return;
  }

  const uint32_t maxDuty = (1UL << config_.backlightResolution) - 1UL;
  const uint32_t duty = (maxDuty * brightness_) / 100UL;
  ledcWrite(config_.backlight, duty);
}

void Display::setDisplayOn(bool enabled) {
  if (ready_) {
    writeCommand(enabled ? kCmdDisplayOn : kCmdDisplayOff);
  }
}

void Display::setSleep(bool enabled) {
  if (!ready_) {
    return;
  }
  writeCommand(enabled ? kCmdSleepIn : kCmdSleepOut);
  delay(enabled ? 5 : 120);
}

void Display::beginTransaction() {
  spi().beginTransaction(SPISettings(config_.spiFrequency, MSBFIRST, SPI_MODE0));
  digitalWrite(config_.cs, LOW);
}

void Display::endTransaction() {
  digitalWrite(config_.cs, HIGH);
  spi().endTransaction();
}

void Display::writeCommandInline(uint8_t command) {
  digitalWrite(config_.dc, LOW);
  spi().write(command);
}

void Display::writeDataInline(const uint8_t *data, size_t length) {
  if (data == nullptr || length == 0) {
    return;
  }
  digitalWrite(config_.dc, HIGH);
  spi().writeBytes(data, length);
}

void Display::writeDataByteInline(uint8_t data) {
  digitalWrite(config_.dc, HIGH);
  spi().write(data);
}

void Display::writeData16Inline(uint16_t value) {
  writeDataByteInline(static_cast<uint8_t>(value >> 8));
  writeDataByteInline(static_cast<uint8_t>(value & 0xFF));
}

void Display::writeCommand(uint8_t command) {
  beginTransaction();
  writeCommandInline(command);
  endTransaction();
}

void Display::writeCommandData(uint8_t command, const uint8_t *data, size_t length) {
  beginTransaction();
  writeCommandInline(command);
  writeDataInline(data, length);
  endTransaction();
}

void Display::startPixelWrite(uint16_t x, uint16_t y, uint16_t width, uint16_t height) {
  const uint16_t x1 = x + config_.xOffset;
  const uint16_t y1 = y + config_.yOffset;
  const uint16_t x2 = x1 + width - 1;
  const uint16_t y2 = y1 + height - 1;

  beginTransaction();
  writeCommandInline(kCmdColumnAddressSet);
  writeData16Inline(x1);
  writeData16Inline(x2);

  writeCommandInline(kCmdRowAddressSet);
  writeData16Inline(y1);
  writeData16Inline(y2);

  writeCommandInline(kCmdMemoryWrite);
  digitalWrite(config_.dc, HIGH);
}

void Display::writePixelData(const uint16_t *pixels, size_t count, PixelByteOrder byteOrder) {
  if (count == 0) {
    return;
  }

  if (byteOrder == PixelByteOrder::BigEndian) {
    spi().writeBytes(reinterpret_cast<const uint8_t *>(pixels), count * sizeof(uint16_t));
    return;
  }

  constexpr size_t chunkPixels = 256;
  uint8_t buffer[chunkPixels * sizeof(uint16_t)];
  size_t sent = 0;

  while (sent < count) {
    const size_t n = std::min(chunkPixels, count - sent);
    for (size_t i = 0; i < n; ++i) {
      const uint16_t color = pixels[sent + i];
      if (byteOrder == PixelByteOrder::LittleEndian) {
        buffer[i * 2] = static_cast<uint8_t>(color & 0xFF);
        buffer[i * 2 + 1] = static_cast<uint8_t>(color >> 8);
      } else {
        buffer[i * 2] = static_cast<uint8_t>(color >> 8);
        buffer[i * 2 + 1] = static_cast<uint8_t>(color & 0xFF);
      }
    }
    spi().writeBytes(buffer, n * sizeof(uint16_t));
    sent += n;
  }
}

bool Display::clipRect(int16_t &x, int16_t &y, uint16_t &width, uint16_t &height) const {
  int32_t x0 = x;
  int32_t y0 = y;
  int32_t x1 = static_cast<int32_t>(x) + width;
  int32_t y1 = static_cast<int32_t>(y) + height;

  if (x1 <= 0 || y1 <= 0 || x0 >= config_.width || y0 >= config_.height) {
    return false;
  }

  x0 = std::max<int32_t>(x0, 0);
  y0 = std::max<int32_t>(y0, 0);
  x1 = std::min<int32_t>(x1, config_.width);
  y1 = std::min<int32_t>(y1, config_.height);

  x = static_cast<int16_t>(x0);
  y = static_cast<int16_t>(y0);
  width = static_cast<uint16_t>(x1 - x0);
  height = static_cast<uint16_t>(y1 - y0);
  return width > 0 && height > 0;
}

bool Display::clipSourceRect(int16_t &x,
                             int16_t &y,
                             uint16_t &width,
                             uint16_t &height,
                             uint16_t &sourceX,
                             uint16_t &sourceY) const {
  int32_t x0 = x;
  int32_t y0 = y;
  int32_t x1 = static_cast<int32_t>(x) + width;
  int32_t y1 = static_cast<int32_t>(y) + height;

  if (x1 <= 0 || y1 <= 0 || x0 >= config_.width || y0 >= config_.height) {
    return false;
  }

  if (x0 < 0) {
    sourceX = static_cast<uint16_t>(-x0);
    x0 = 0;
  }
  if (y0 < 0) {
    sourceY = static_cast<uint16_t>(-y0);
    y0 = 0;
  }

  x1 = std::min<int32_t>(x1, config_.width);
  y1 = std::min<int32_t>(y1, config_.height);

  x = static_cast<int16_t>(x0);
  y = static_cast<int16_t>(y0);
  width = static_cast<uint16_t>(x1 - x0);
  height = static_cast<uint16_t>(y1 - y0);
  return width > 0 && height > 0;
}

void Display::setError(const char *message) {
  lastError_ = message == nullptr ? "unknown error" : message;
}

SdCard::SdCard(SdCardConfig config) : config_(config) {}

bool SdCard::begin() {
  mounted_ = false;
  setError("ok");

  pinMode(config_.cs, OUTPUT);
  digitalWrite(config_.cs, HIGH);

  if (!spi().begin(config_.sclk, config_.miso, config_.mosi, config_.cs)) {
    setError("sd spi begin failed");
    return false;
  }

  if (!SD.begin(config_.cs, spi(), config_.frequency, config_.mountPoint, config_.maxOpenFiles, config_.formatIfEmpty)) {
    setError("sd mount failed");
    return false;
  }

  if (SD.cardType() == CARD_NONE) {
    SD.end();
    setError("no sd card");
    return false;
  }

  mounted_ = true;
  return true;
}

void SdCard::end() {
  if (mounted_) {
    SD.end();
  }
  mounted_ = false;
}

SdCardInfo SdCard::info() const {
  SdCardInfo result;
  if (!mounted_) {
    return result;
  }

  result.type = convertCardType(SD.cardType());
  result.cardBytes = SD.cardSize();
  result.totalBytes = SD.totalBytes();
  result.usedBytes = SD.usedBytes();
  return result;
}

uint64_t SdCard::freeBytes() const {
  const SdCardInfo card = info();
  return card.totalBytes > card.usedBytes ? card.totalBytes - card.usedBytes : 0;
}

fs::FS &SdCard::fs() const {
  return SD;
}

File SdCard::open(const char *path, const char *mode) const {
  if (!mounted_) {
    return File();
  }
  return SD.open(path, mode);
}

bool SdCard::exists(const char *path) const {
  return mounted_ && SD.exists(path);
}

bool SdCard::remove(const char *path) const {
  return mounted_ && SD.remove(path);
}

bool SdCard::mkdir(const char *path) const {
  return mounted_ && SD.mkdir(path);
}

std::vector<String> SdCard::list(const char *directory, const char *extension, size_t maxFiles) const {
  std::vector<String> files;
  if (!mounted_ || directory == nullptr || maxFiles == 0) {
    return files;
  }

  File dir = SD.open(directory);
  if (!dir || !dir.isDirectory()) {
    return files;
  }

  for (File entry = dir.openNextFile(); entry && files.size() < maxFiles; entry = dir.openNextFile()) {
    if (!entry.isDirectory()) {
      String name(entry.name());
      if (extensionMatches(name, extension)) {
        files.push_back(name);
      }
    }
    entry.close();
  }
  dir.close();
  return files;
}

const char *SdCard::cardTypeName(CardType type) {
  switch (type) {
    case CardType::Mmc:
      return "MMC";
    case CardType::Sd:
      return "SDSC";
    case CardType::Sdhc:
      return "SDHC";
    case CardType::Unknown:
      return "UNKNOWN";
    case CardType::None:
    default:
      return "NONE";
  }
}

void SdCard::setError(const char *message) {
  lastError_ = message == nullptr ? "unknown error" : message;
}

SPIClass &SdCard::spi() const {
  return config_.spi == nullptr ? SPI : *config_.spi;
}

CardType SdCard::convertCardType(uint8_t arduinoCardType) {
  switch (arduinoCardType) {
    case CARD_MMC:
      return CardType::Mmc;
    case CARD_SD:
      return CardType::Sd;
    case CARD_SDHC:
      return CardType::Sdhc;
    case CARD_NONE:
      return CardType::None;
    default:
      return CardType::Unknown;
  }
}

bool SdCard::extensionMatches(const String &name, const char *extension) {
  if (extension == nullptr || extension[0] == '\0') {
    return true;
  }

  String fileName = name;
  String suffix = extension;
  fileName.toLowerCase();
  suffix.toLowerCase();
  if (!suffix.startsWith(".")) {
    suffix = "." + suffix;
  }
  return fileName.endsWith(suffix);
}

bool Ui::lvglInitialized_ = false;

Ui::Ui(Display &display, UiConfig config) : display_(display), config_(config) {}

Ui::~Ui() {
  releaseBuffers();
}

bool Ui::begin() {
  ready_ = false;
  setError("ok");

  if (!display_.ready()) {
    setError("display not initialized");
    return false;
  }

  if (!lvglInitialized_) {
    lv_init();
    lvglInitialized_ = true;
  }
  lv_tick_set_cb(lvTickMillis);

  if (!allocateBuffers()) {
    return false;
  }

  lvglDisplay_ = lv_display_create(display_.width(), display_.height());
  if (lvglDisplay_ == nullptr) {
    setError("lvgl display create failed");
    releaseBuffers();
    return false;
  }

  lv_display_set_color_format(lvglDisplay_, LV_COLOR_FORMAT_RGB565);
  lv_display_set_user_data(lvglDisplay_, this);
  lv_display_set_flush_cb(lvglDisplay_, flush);
  lv_display_set_buffers(lvglDisplay_, buffer1_, buffer2_, bufferBytes_, LV_DISPLAY_RENDER_MODE_PARTIAL);
  lv_display_set_default(lvglDisplay_);

  ready_ = true;
  if (config_.showBootScreen) {
    createBootScreen();
  }
  return true;
}

void Ui::update() {
  if (ready_) {
    lv_timer_handler();
  }
}

lv_obj_t *Ui::screen() const {
  return ready_ ? lv_screen_active() : nullptr;
}

bool Ui::allocateBuffers() {
  releaseBuffers();

  uint16_t rows = std::min<uint16_t>(std::max<uint16_t>(config_.bufferRows, 1), display_.height());
  while (rows > 0) {
    const size_t bytes = static_cast<size_t>(display_.width()) * rows * sizeof(uint16_t);
    buffer1_ = heap_caps_malloc(bytes, MALLOC_CAP_INTERNAL | MALLOC_CAP_DMA | MALLOC_CAP_8BIT);
    if (buffer1_ != nullptr) {
      if (config_.doubleBuffer) {
        buffer2_ = heap_caps_malloc(bytes, MALLOC_CAP_INTERNAL | MALLOC_CAP_DMA | MALLOC_CAP_8BIT);
      }
      bufferBytes_ = bytes;
      actualBufferRows_ = rows;
      return true;
    }
    rows /= 2;
  }

  setError("lvgl buffer allocation failed");
  return false;
}

void Ui::releaseBuffers() {
  if (buffer1_ != nullptr) {
    heap_caps_free(buffer1_);
  }
  if (buffer2_ != nullptr) {
    heap_caps_free(buffer2_);
  }
  buffer1_ = nullptr;
  buffer2_ = nullptr;
  bufferBytes_ = 0;
  actualBufferRows_ = 0;
}

void Ui::createBootScreen() {
  lv_obj_t *root = lv_screen_active();
  lv_obj_set_style_bg_color(root, lv_color_hex(0x101820), 0);
  lv_obj_set_style_bg_opa(root, LV_OPA_COVER, 0);

  lv_obj_t *title = lv_label_create(root);
  lv_label_set_text(title, "ESP32-C6-LCD-1.47");
  lv_obj_set_style_text_color(title, lv_color_hex(0xF4F7FB), 0);
  lv_obj_align(title, LV_ALIGN_CENTER, 0, -18);

  lv_obj_t *status = lv_label_create(root);
  lv_label_set_text_fmt(status, "LVGL %d.%d.%d  |  %u rows",
                        LVGL_VERSION_MAJOR,
                        LVGL_VERSION_MINOR,
                        LVGL_VERSION_PATCH,
                        actualBufferRows_);
  lv_obj_set_style_text_color(status, lv_color_hex(0x8BC4FF), 0);
  lv_obj_align(status, LV_ALIGN_CENTER, 0, 14);
}

uint32_t Ui::lvTickMillis() {
  return static_cast<uint32_t>(millis());
}

void Ui::flush(lv_display_t *display, const lv_area_t *area, uint8_t *pixels) {
  Ui *ui = static_cast<Ui *>(lv_display_get_user_data(display));
  if (ui == nullptr || area == nullptr || pixels == nullptr) {
    lv_display_flush_ready(display);
    return;
  }

  const int32_t width = lv_area_get_width(area);
  const int32_t height = lv_area_get_height(area);
  if (width <= 0 || height <= 0) {
    lv_display_flush_ready(display);
    return;
  }

  ui->display_.drawPixels(static_cast<int16_t>(area->x1),
                          static_cast<int16_t>(area->y1),
                          static_cast<uint16_t>(width),
                          static_cast<uint16_t>(height),
                          reinterpret_cast<const uint16_t *>(pixels),
                          ui->config_.lvglByteOrder);
  lv_display_flush_ready(display);
}

void Ui::setError(const char *message) {
  lastError_ = message == nullptr ? "unknown error" : message;
}

Device::Device(DeviceConfig config)
    : config_(config), display_(config.display), sd_(config.sd), ui_(display_, config.ui) {}

bool Device::begin() {
  setError("ok");
  if (!display_.begin()) {
    setError(display_.lastError());
    return false;
  }

  if (!ui_.begin()) {
    setError(ui_.lastError());
    return false;
  }

  if (config_.mountSd && !sd_.begin()) {
    if (config_.sdRequired) {
      setError(sd_.lastError());
      return false;
    }
  }

  return true;
}

void Device::update() {
  ui_.update();
}

void Device::setError(const char *message) {
  lastError_ = message == nullptr ? "unknown error" : message;
}

}  // namespace esp32_c6_lcd_147
