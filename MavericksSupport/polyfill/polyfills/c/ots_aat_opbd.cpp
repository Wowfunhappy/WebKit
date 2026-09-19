// 'opbd' optical bounds. This OS keys a lookup by glyph to an offset, reads four side values (format 0)
// or four control-point indices (format 1) there, and bounds that offset against the table as it reads.
// The read it does not bound is the lookup value itself for a format-4 subtable, so validating the
// lookup keeps every side-value read inside the table.
#include "ots_aat_lookup.h"

bool wk_aat_validate_opbd(const uint8_t *table, size_t length, const wk_aat_font_facts &facts)
{
    uint32_t version = 0;
    uint16_t format = 0;
    // version(Fixed) == 0x00010000, format(u16) is 0 or 1, then a lookup at offset 6.
    if (!wk_aat_read32(table, length, 0, &version) || version != 0x00010000u)
        return false;
    if (!wk_aat_read16(table, length, 4, &format) || format > 1)
        return false;

    return wk_aat_validate_lookup(table, length, 6, 2, facts.numGlyphs,
        [](const wk_aat_lookup_entry &) { return true; });
}
