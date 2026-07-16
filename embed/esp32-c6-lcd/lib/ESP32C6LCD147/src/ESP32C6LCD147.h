#pragma once

#include <Arduino.h>
#include <FS.h>
#include <SD.h>
#include <SPI.h>
#include <lvgl.h>

#include <stddef.h>
#include <stdint.h>
#include <vector>

namespace esp32_c6_lcd_147 {

namespace pins {
static constexpr int8_t sdCs = 4;
static constexpr int8_t spiMiso = 5;
static constexpr int8_t spiMosi = 6;
static constexpr int8_t spiSclk = 7;
static constexpr int8_t lcdCs = 14;
static constexpr int8_t lcdDc = 15;
static constexpr int8_t lcdRst = 21;
static constexpr int8_t backlight = 22;
}  // namespace pins

static constexpr uint16_t displayWidth = 172;
static constexpr uint16_t displayHeight = 320;
static constexpr uint16_t displayXOffset = 34;
static constexpr uint16_t displayYOffset = 0;

enum class PixelByteOrder : uint8_t {
  HostEndian,
  BigEndian,
  LittleEndian,
};

enum class CardType : uint8_t {
  None,
  Mmc,
  Sd,
  Sdhc,
  Unknown,
};

struct DisplayConfig {
  SPIClass *spi = nullptr;
  int8_t sclk = pins::spiSclk;
  int8_t miso = pins::spiMiso;
  int8_t mosi = pins::spiMosi;
  int8_t cs = pins::lcdCs;
  int8_t dc = pins::lcdDc;
  int8_t rst = pins::lcdRst;
  int8_t backlight = pins::backlight;
  uint16_t width = displayWidth;
  uint16_t height = displayHeight;
  uint16_t xOffset = displayXOffset;
  uint16_t yOffset = displayYOffset;
  uint8_t madctl = 0x00;
  bool invertColors = true;
  uint32_t spiFrequency = 80000000UL;
  uint32_t backlightFrequency = 1000;
  uint8_t backlightResolution = 10;
  uint8_t initialBrightness = 70;
};

class Display {
 public:
  explicit Display(DisplayConfig config = {});

  bool begin();
  void end();
  bool ready() const { return ready_; }

  uint16_t width() const { return config_.width; }
  uint16_t height() const { return config_.height; }
  uint8_t brightness() const { return brightness_; }
  const char *lastError() const { return lastError_; }
  const DisplayConfig &config() const { return config_; }

  SPIClass &spi();

  bool fill(uint16_t rgb565);
  bool fillRect(int16_t x, int16_t y, uint16_t width, uint16_t height, uint16_t rgb565);
  bool drawPixel(int16_t x, int16_t y, uint16_t rgb565);
  bool drawPixels(int16_t x,
                  int16_t y,
                  uint16_t width,
                  uint16_t height,
                  const uint16_t *pixels,
                  PixelByteOrder byteOrder = PixelByteOrder::HostEndian);

  void setBrightness(uint8_t percent);
  void setDisplayOn(bool enabled);
  void setSleep(bool enabled);

 private:
  void setError(const char *message);
  bool beginSpi();
  bool beginBacklight();
  void hardwareReset();
  void initializePanel();

  void beginTransaction();
  void endTransaction();
  void writeCommandInline(uint8_t command);
  void writeDataInline(const uint8_t *data, size_t length);
  void writeDataByteInline(uint8_t data);
  void writeData16Inline(uint16_t value);
  void writeCommand(uint8_t command);
  void writeCommandData(uint8_t command, const uint8_t *data, size_t length);
  void startPixelWrite(uint16_t x, uint16_t y, uint16_t width, uint16_t height);
  void writePixelData(const uint16_t *pixels, size_t count, PixelByteOrder byteOrder);
  bool clipRect(int16_t &x, int16_t &y, uint16_t &width, uint16_t &height) const;
  bool clipSourceRect(int16_t &x,
                      int16_t &y,
                      uint16_t &width,
                      uint16_t &height,
                      uint16_t &sourceX,
                      uint16_t &sourceY) const;

  DisplayConfig config_;
  bool ready_ = false;
  bool backlightAttached_ = false;
  uint8_t brightness_ = 0;
  const char *lastError_ = "ok";
};

struct SdCardConfig {
  SPIClass *spi = nullptr;
  int8_t sclk = pins::spiSclk;
  int8_t miso = pins::spiMiso;
  int8_t mosi = pins::spiMosi;
  int8_t cs = pins::sdCs;
  uint32_t frequency = 20000000UL;
  const char *mountPoint = "/sd";
  uint8_t maxOpenFiles = 5;
  bool formatIfEmpty = false;
};

struct SdCardInfo {
  CardType type = CardType::None;
  uint64_t cardBytes = 0;
  uint64_t totalBytes = 0;
  uint64_t usedBytes = 0;
};

class SdCard {
 public:
  explicit SdCard(SdCardConfig config = {});

  bool begin();
  void end();
  bool mounted() const { return mounted_; }
  const char *lastError() const { return lastError_; }
  const SdCardConfig &config() const { return config_; }

  SdCardInfo info() const;
  uint64_t freeBytes() const;
  fs::FS &fs() const;
  File open(const char *path, const char *mode = FILE_READ) const;
  bool exists(const char *path) const;
  bool remove(const char *path) const;
  bool mkdir(const char *path) const;
  std::vector<String> list(const char *directory = "/", const char *extension = nullptr, size_t maxFiles = 32) const;

  static const char *cardTypeName(CardType type);

 private:
  void setError(const char *message);
  SPIClass &spi() const;
  static CardType convertCardType(uint8_t arduinoCardType);
  static bool extensionMatches(const String &name, const char *extension);

  SdCardConfig config_;
  bool mounted_ = false;
  const char *lastError_ = "ok";
};

struct UiConfig {
  uint16_t bufferRows = 40;
  bool doubleBuffer = true;
  bool showBootScreen = true;
  PixelByteOrder lvglByteOrder = PixelByteOrder::LittleEndian;
};

class Ui {
 public:
  explicit Ui(Display &display, UiConfig config = {});
  ~Ui();

  bool begin();
  void update();

  lv_display_t *lvglDisplay() const { return lvglDisplay_; }
  lv_obj_t *screen() const;
  uint16_t bufferRows() const { return actualBufferRows_; }
  size_t bufferBytes() const { return bufferBytes_; }
  bool ready() const { return ready_; }
  const char *lastError() const { return lastError_; }

 private:
  void setError(const char *message);
  bool allocateBuffers();
  void releaseBuffers();
  void createBootScreen();

  static uint32_t lvTickMillis();
  static void flush(lv_display_t *display, const lv_area_t *area, uint8_t *pixels);

  Display &display_;
  UiConfig config_;
  lv_display_t *lvglDisplay_ = nullptr;
  void *buffer1_ = nullptr;
  void *buffer2_ = nullptr;
  size_t bufferBytes_ = 0;
  uint16_t actualBufferRows_ = 0;
  bool ready_ = false;
  const char *lastError_ = "ok";

  static bool lvglInitialized_;
};

struct DeviceConfig {
  DisplayConfig display;
  SdCardConfig sd;
  UiConfig ui;
  bool mountSd = true;
  bool sdRequired = false;
};

class Device {
 public:
  explicit Device(DeviceConfig config = {});

  bool begin();
  void update();

  Display &display() { return display_; }
  SdCard &sd() { return sd_; }
  Ui &ui() { return ui_; }
  const char *lastError() const { return lastError_; }

 private:
  void setError(const char *message);

  DeviceConfig config_;
  Display display_;
  SdCard sd_;
  Ui ui_;
  const char *lastError_ = "ok";
};

}  // namespace esp32_c6_lcd_147
