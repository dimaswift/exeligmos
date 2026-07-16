/**
 * octal_glyph_progmem.h
 *
 * Portable flash-placement attribute for the baked sprite data. Arduino
 * cores define `PROGMEM` (on AVR it's load-bearing -- those MCUs need
 * pgm_read_byte() to read it; on ESP32's Arduino core it's a no-op since
 * flash is memory-mapped and plain pointer reads already work). Non-Arduino
 * builds (plain ESP-IDF, host tests) don't have `PROGMEM` at all, so this
 * header makes it optional: use it if the framework already defined it,
 * otherwise expand to nothing. Either way the sprite arrays are `static
 * const`, so a normal compiler/linker still places them in read-only
 * (flash-backed) memory instead of consuming RAM.
 */
#pragma once

#ifndef OG_SPRITE_PROGMEM
#ifdef PROGMEM
#define OG_SPRITE_PROGMEM PROGMEM
#else
#define OG_SPRITE_PROGMEM
#endif
#endif
