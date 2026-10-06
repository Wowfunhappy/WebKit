// 'lcar' ligature carets. This OS keys a lookup by glyph to a u16 offset from the table base, reads a
// caret count there and then that many u16 caret values -- and it bounds neither the offset nor the
// values. Validating the lookup keeps the offset in the table; the check below keeps the count array
// there too.
#include "ots_aat_lookup.h"

bool wk_aat_validate_lcar(const uint8_t *table, size_t length, const wk_aat_font_facts &facts)
{
    uint32_t version = 0;
    uint16_t format = 0;
    // version(Fixed) == 0x00010000, format(u16) is 0 (distance) or 1 (control point), lookup at 6.
    if (!wk_aat_read32(table, length, 0, &version) || version != 0x00010000u)
        return false;
    if (!wk_aat_read16(table, length, 4, &format) || format > 1)
        return false;

    return wk_aat_validate_lookup(table, length, 6, 2, facts.numGlyphs,
        [&](const wk_aat_lookup_entry &entry) {
            uint16_t caretOffset = 0;
            if (!wk_aat_read16(table, length, entry.valueOffset, &caretOffset))
                return false;
            uint16_t count = 0;
            if (!wk_aat_read16(table, length, caretOffset, &count))
                return false;
            uint64_t end = static_cast<uint64_t>(caretOffset) + 2 + static_cast<uint64_t>(count) * 2;
            return end <= length;
        });
}
