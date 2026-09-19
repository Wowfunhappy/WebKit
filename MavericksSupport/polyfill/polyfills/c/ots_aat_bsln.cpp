// 'bsln' baselines. This OS turns a baseline value into a table index into a fixed 32-entry array
// (bslnToBaselineMap) with no range check, so a value of 32 or more reads past that array. The default
// baseline in the header and, for the mapped formats, every value the per-glyph lookup returns must be
// below 32. The distance and control-point parts are fixed-size arrays this OS reads whole.
#include "ots_aat_lookup.h"

namespace {
const uint16_t kBaselineClassCount = 32;
}

bool wk_aat_validate_bsln(const uint8_t *table, size_t length, const wk_aat_font_facts &facts)
{
    uint32_t version = 0;
    uint16_t format = 0, defaultBaseline = 0;
    // version(Fixed) == 0x00010000, format(u16) in 0..3, defaultBaseline(u16) < 32.
    if (!wk_aat_read32(table, length, 0, &version) || version != 0x00010000u)
        return false;
    if (!wk_aat_read16(table, length, 4, &format) || format > 3)
        return false;
    if (!wk_aat_read16(table, length, 6, &defaultBaseline) || defaultBaseline >= kBaselineClassCount)
        return false;

    // Fixed part after the 8-byte header: 32 i16 deltas (formats 0/1) or a std glyph and 32 u16 control
    // points (formats 2/3). The mapping lookup, when present, follows it.
    size_t mappingOffset = 0;
    if (format == 0 || format == 1) {
        uint64_t partEnd = 8 + static_cast<uint64_t>(kBaselineClassCount) * 2;
        if (partEnd > length)
            return false;
        mappingOffset = static_cast<size_t>(partEnd);
    } else {
        uint64_t partEnd = 8 + 2 + static_cast<uint64_t>(kBaselineClassCount) * 2;
        if (partEnd > length)
            return false;
        mappingOffset = static_cast<size_t>(partEnd);
    }

    if (format != 1 && format != 3)
        return true;

    // A mapped format keys a lookup by glyph to a baseline value, which indexes the 32-entry array too.
    return wk_aat_validate_lookup(table, length, mappingOffset, 2, facts.numGlyphs,
        [&](const wk_aat_lookup_entry &entry) {
            uint16_t value = 0;
            if (!wk_aat_read16(table, length, entry.valueOffset, &value))
                return false;
            return value < kBaselineClassCount;
        });
}
