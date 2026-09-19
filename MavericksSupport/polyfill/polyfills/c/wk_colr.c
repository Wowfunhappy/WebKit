#include "wk_colr.h"

static uint16_t wk_be16(const uint8_t *p) { return (uint16_t)((p[0] << 8) | p[1]); }
static uint32_t wk_be32(const uint8_t *p) { return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3]; }

// COLR header shared by versions 0 and 1: version, numBaseGlyphRecords, baseGlyphRecordsOffset,
// layerRecordsOffset, numLayerRecords.
static const size_t wk_colrHeaderSize = 14;
static const size_t wk_colrBaseRecordSize = 6;
static const size_t wk_colrLayerRecordSize = 4;
// CPAL header: version, numPaletteEntries, numPalettes, numColorRecords, colorRecordsArrayOffset,
// then numPalettes uint16 colorRecordIndices. Version 1 follows those with paletteTypesArrayOffset,
// paletteLabelsArrayOffset and paletteEntryLabelsArrayOffset, each uint32 from the table start.
static const size_t wk_cpalHeaderSize = 12;
static const size_t wk_cpalColorRecordSize = 4;

static bool wk_colrBaseRecord(const wk_colr_tables *tables, uint16_t glyph, uint16_t *firstLayer, uint16_t *layerCount)
{
    if (!tables || !tables->colr || tables->colrLength < wk_colrHeaderSize)
        return false;
    const uint8_t *colr = tables->colr;
    uint16_t version = wk_be16(colr);
    if (version > 1)
        return false;
    uint64_t count = wk_be16(colr + 2);
    uint64_t offset = wk_be32(colr + 4);
    if (!count || offset + count * wk_colrBaseRecordSize > tables->colrLength)
        return false;

    uint64_t low = 0, high = count;
    while (low < high) {
        uint64_t middle = low + (high - low) / 2;
        const uint8_t *record = colr + offset + middle * wk_colrBaseRecordSize;
        uint16_t recordGlyph = wk_be16(record);
        if (recordGlyph == glyph) {
            *firstLayer = wk_be16(record + 2);
            *layerCount = wk_be16(record + 4);
            return true;
        }
        if (recordGlyph < glyph)
            low = middle + 1;
        else
            high = middle;
    }
    return false;
}

bool wk_colrHasBaseGlyph(const wk_colr_tables *tables, uint16_t glyph)
{
    uint16_t firstLayer, layerCount;
    return wk_colrBaseRecord(tables, glyph, &firstLayer, &layerCount) && layerCount;
}

uint16_t wk_cpalPaletteCount(const wk_colr_tables *tables)
{
    if (!tables || !tables->cpal || tables->cpalLength < wk_cpalHeaderSize)
        return 0;
    const uint8_t *cpal = tables->cpal;
    if (wk_be16(cpal) > 1)
        return 0;
    uint64_t palettes = wk_be16(cpal + 4);
    if (wk_cpalHeaderSize + palettes * 2 > tables->cpalLength)
        return 0;
    return (uint16_t)palettes;
}

uint16_t wk_cpalResolvePalette(const wk_colr_tables *tables, int64_t requested)
{
    uint16_t palettes = wk_cpalPaletteCount(tables);
    if (!palettes)
        return 0;
    if (requested >= 0)
        return requested < palettes ? (uint16_t)requested : 0;
    uint32_t wanted = requested == WK_CPAL_PALETTE_LIGHT ? WK_CPAL_USABLE_WITH_LIGHT_BACKGROUND
        : (requested == WK_CPAL_PALETTE_DARK ? WK_CPAL_USABLE_WITH_DARK_BACKGROUND : 0);
    const uint8_t *cpal = tables->cpal;
    if (!wanted || wk_be16(cpal) < 1)
        return 0;
    uint64_t typesOffsetField = wk_cpalHeaderSize + (uint64_t)palettes * 2;
    if (typesOffsetField + 4 > tables->cpalLength)
        return 0;
    uint64_t typesOffset = wk_be32(cpal + typesOffsetField);
    if (!typesOffset || typesOffset + (uint64_t)palettes * 4 > tables->cpalLength)
        return 0;
    for (uint16_t i = 0; i < palettes; ++i) {
        if (wk_be32(cpal + typesOffset + (uint64_t)i * 4) & wanted)
            return i;
    }
    return 0;
}

uint16_t wk_cpalEntryCount(const wk_colr_tables *tables)
{
    return wk_cpalPaletteCount(tables) ? wk_be16(tables->cpal + 2) : 0;
}

bool wk_cpalColor(const wk_colr_tables *tables, uint16_t palette, uint16_t entry, wk_colr_layer *layer)
{
    uint16_t palettes = wk_cpalPaletteCount(tables);
    if (palette >= palettes)
        return false;
    const uint8_t *cpal = tables->cpal;
    uint16_t entries = wk_be16(cpal + 2);
    uint64_t records = wk_be16(cpal + 6);
    uint64_t recordsOffset = wk_be32(cpal + 8);
    if (entry >= entries)
        return false;
    uint64_t index = (uint64_t)wk_be16(cpal + wk_cpalHeaderSize + 2 * (size_t)palette) + entry;
    if (index >= records || recordsOffset + (index + 1) * wk_cpalColorRecordSize > tables->cpalLength)
        return false;
    const uint8_t *record = cpal + recordsOffset + index * wk_cpalColorRecordSize;
    layer->blue = record[0];
    layer->green = record[1];
    layer->red = record[2];
    layer->alpha = record[3];
    return true;
}

size_t wk_colrLayers(const wk_colr_tables *tables, uint16_t glyph, uint32_t glyphCount, uint16_t palette,
    wk_colr_excluded_glyph excluded, void *excludedContext, wk_colr_layer *out, size_t capacity)
{
    uint16_t firstLayer, layerCount;
    if (!out || !wk_colrBaseRecord(tables, glyph, &firstLayer, &layerCount))
        return 0;
    if (!layerCount || layerCount > WK_COLR_MAX_LAYERS || layerCount > capacity)
        return 0;

    const uint8_t *colr = tables->colr;
    uint64_t layerRecords = wk_be16(colr + 12);
    uint64_t layersOffset = wk_be32(colr + 8);
    uint64_t end = (uint64_t)firstLayer + layerCount;
    if (end > layerRecords || layersOffset + end * wk_colrLayerRecordSize > tables->colrLength)
        return 0;

    for (uint64_t i = 0; i < layerCount; ++i) {
        const uint8_t *record = colr + layersOffset + ((uint64_t)firstLayer + i) * wk_colrLayerRecordSize;
        wk_colr_layer layer = { wk_be16(record), wk_be16(record + 2), 0, 0, 0, 0 };
        if (layer.glyph >= glyphCount)
            return 0;
        if (excluded && excluded(excludedContext, layer.glyph))
            return 0;
        if (layer.paletteEntry != WK_COLR_FOREGROUND && !wk_cpalColor(tables, palette, layer.paletteEntry, &layer))
            return 0;
        out[i] = layer;
    }
    return layerCount;
}
