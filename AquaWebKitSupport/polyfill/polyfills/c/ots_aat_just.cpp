// Validator for the AAT 'just' justification table.
//
// TAATJustEngine reads this table during CTLineCreateJustifiedLine. Its constructor takes the table
// length as a limit and bounds every read: the 10-byte header, the per-direction JustDirectionTable it
// selects at offset 6 (horizontal) or 8 (vertical), and -- in FetchJustClasses, DoActions and
// DoGlyphActions -- the justification-class lookup, postcompensation action lists and their subrecords
// are each compared against the table end before use, and a table that fails is dropped with a log.
// This reproduces the header gate the constructor applies: version 1.0 and each present direction
// table's 24-byte header inside the table. Nothing in this table drives an unbounded read.
#include "ots_aat.h"

namespace {

// A JustDirectionTable header is 24 bytes; the constructor requires base + directionOffset + 0x18 to
// stay inside the table before reading it.
bool directionTableInBounds(const uint8_t *table, size_t length, size_t offsetField)
{
    uint16_t directionOffset;
    if (!wk_aat_read16(table, length, offsetField, &directionOffset))
        return false;
    if (!directionOffset)
        return true;
    uint64_t headerEnd = static_cast<uint64_t>(directionOffset) + 0x18;
    return directionOffset <= length && headerEnd <= length;
}

} // namespace

bool wk_aat_validate_just(const uint8_t *table, size_t length, const wk_aat_font_facts &)
{
    uint32_t version;
    if (!wk_aat_read32(table, length, 0, &version))
        return false;
    // The constructor reads a direction table only for version 1.0; any other value leaves the table
    // unparsed and inert.
    if (version != 0x00010000u)
        return true;

    // Horizontal JustDirectionTable offset at 6, vertical at 8.
    return directionTableInBounds(table, length, 6) && directionTableInBounds(table, length, 8);
}
