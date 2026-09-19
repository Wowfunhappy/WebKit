// 'ankr' anchor points. This OS keys a lookup (SFNTLookupTable) by glyph to an offset into the glyph
// data section, reads an anchor count there, then an anchor's coordinates; the count and coordinate
// reads it bounds against the section as it makes them. The one read it makes without bounding is the
// value the lookup returns for a format-4 subtable, whose per-segment offset it does not check, so
// validating the lookup structure is what keeps every anchor lookup inside the table.
#include "ots_aat_lookup.h"

bool wk_aat_validate_ankr(const uint8_t *table, size_t length, const wk_aat_font_facts &facts)
{
    uint16_t version = 0;
    uint32_t lookupOffset = 0, glyphDataOffset = 0;
    // version(u16)=0, flags(u16), lookupTableOffset(u32), glyphDataTableOffset(u32).
    if (!wk_aat_read16(table, length, 0, &version) || version != 0)
        return false;
    if (!wk_aat_read32(table, length, 4, &lookupOffset)
        || !wk_aat_read32(table, length, 8, &glyphDataOffset))
        return false;
    if (glyphDataOffset > length)
        return false;

    // The lookup value is an offset from the glyph data section; this OS bounds where it points.
    return wk_aat_validate_lookup(table, length, lookupOffset, 2, facts.numGlyphs,
        [](const wk_aat_lookup_entry &) { return true; });
}
