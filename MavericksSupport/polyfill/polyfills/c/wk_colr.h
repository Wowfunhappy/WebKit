// COLR version 0 layer lookup and CPAL colour lookup over a font's raw tables.
#ifndef WK_COLR_H
#define WK_COLR_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define WK_COLR_MAX_LAYERS 1024
#define WK_COLR_FOREGROUND 0xFFFF

// kCTFontPaletteAttribute's named palettes.
#define WK_CPAL_PALETTE_LIGHT (-1)
#define WK_CPAL_PALETTE_DARK (-2)
// CPAL version 1 paletteTypes flags.
#define WK_CPAL_USABLE_WITH_LIGHT_BACKGROUND 0x1
#define WK_CPAL_USABLE_WITH_DARK_BACKGROUND 0x2

typedef struct {
    const uint8_t *colr;
    size_t colrLength;
    const uint8_t *cpal;
    size_t cpalLength;
} wk_colr_tables;

typedef struct {
    uint16_t glyph;
    uint16_t paletteEntry; // WK_COLR_FOREGROUND for the text's own colour
    uint8_t blue, green, red, alpha; // CPAL's record; unset for the foreground entry
} wk_colr_layer;

// Whether a glyph id is one a layer may not name (a glyph this OS would decode an sbix record for).
typedef bool (*wk_colr_excluded_glyph)(void *context, uint16_t glyph);

// Whether the tables give `glyph` a COLRv0 record at all.
bool wk_colrHasBaseGlyph(const wk_colr_tables *tables, uint16_t glyph);

// The layers of `glyph`, bottom first, with colours from `palette` (index into CPAL's palettes).
// Returns the layer count, or 0 when the glyph has no usable colour record: no record, a record whose
// layer range or any palette reference falls outside the tables, a layer glyph not below `glyphCount`,
// a layer glyph `excluded` rejects, or more layers than `capacity` / WK_COLR_MAX_LAYERS.
size_t wk_colrLayers(const wk_colr_tables *tables, uint16_t glyph, uint32_t glyphCount, uint16_t palette,
    wk_colr_excluded_glyph excluded, void *excludedContext, wk_colr_layer *out, size_t capacity);

// CPAL's palette count, 0 when the table is absent or malformed.
uint16_t wk_cpalPaletteCount(const wk_colr_tables *tables);
uint16_t wk_cpalEntryCount(const wk_colr_tables *tables);
bool wk_cpalColor(const wk_colr_tables *tables, uint16_t palette, uint16_t entry, wk_colr_layer *layer);

// The palette index a kCTFontPaletteAttribute value names: an index below the palette count as itself;
// WK_CPAL_PALETTE_LIGHT / _DARK as the first palette CPAL version 1 marks usable with that background;
// palette 0 for anything else, including an out-of-range index and a table with no paletteTypes array.
uint16_t wk_cpalResolvePalette(const wk_colr_tables *tables, int64_t requested);

#endif
