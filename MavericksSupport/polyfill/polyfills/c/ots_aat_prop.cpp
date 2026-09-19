// 'prop' glyph properties. This OS reads defaultProperties from the header and, for format 1, keys a
// lookup by glyph to a property word, bounding the looked-up pointer against the table before reading
// it. The format-4 segment offset is the read it leaves unbounded, so validating the lookup closes it;
// the property word itself is never used as an offset.
#include "ots_aat_lookup.h"

bool wk_aat_validate_prop(const uint8_t *table, size_t length, const wk_aat_font_facts &facts)
{
    uint32_t version = 0;
    uint16_t format = 0;
    // version(Fixed), format(u16), defaultProperties(u16), then a lookup for format 1. This OS compares
    // the version signed against 0x00030000 and rejects a greater one, so a version with the high bit
    // set (negative) passes it; matching that keeps exactly the versions this OS accepts.
    if (!wk_aat_read32(table, length, 0, &version) || static_cast<int32_t>(version) > 0x00030000)
        return false;
    uint16_t defaultProperties = 0;
    if (!wk_aat_read16(table, length, 4, &format) || !wk_aat_read16(table, length, 6, &defaultProperties))
        return false;
    if (format == 0)
        return true;
    if (format != 1)
        return false;

    return wk_aat_validate_lookup(table, length, 8, 2, facts.numGlyphs,
        [](const wk_aat_lookup_entry &) { return true; });
}
