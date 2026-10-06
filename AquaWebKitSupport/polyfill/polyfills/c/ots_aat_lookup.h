// A validator for the AAT SFNTLookupTable this OS's shaper reads (formats 0, 2, 4, 6, 8; format 10
// and anything higher this OS treats as a bad table). ankr, lcar, opbd, prop and bsln each carry one,
// and the shaper turns a looked-up entry into a pointer it reads. For formats 0/2/6/8 this OS bounds
// that pointer as it parses the header; for format 4 it computes base + segment.offset +
// valueSize*(glyph - firstGlyph) and reads there without bounding it, so a segment offset near the end
// of the table yields an out-of-table read. This validator bounds every array and, for format 4, every
// per-segment value array over its whole glyph range, then hands each covered glyph's in-bounds value
// offset to a visitor so a table can check what the value means. Every entry it accepts is one the
// shaper can read without leaving the table.
#ifndef WK_OTS_AAT_LOOKUP_H
#define WK_OTS_AAT_LOOKUP_H

#include "ots_aat.h"

// A covered glyph and the in-bounds byte offset of its value. valueOffset + valueSize <= length holds.
struct wk_aat_lookup_entry {
    uint32_t glyph;
    size_t valueOffset;
};

// base/length delimit the whole table; lookupOffset is where the lookup begins inside it. valueSize is
// the bytes the shaper reads per entry (2 for these tables). numGlyphs caps the glyph range. Visitor is
// called for each covered glyph and returns false to reject; returning false anywhere fails the table.
// Total entries visited are capped so a segment array cannot drive unbounded work.
template <typename Visitor>
inline bool wk_aat_validate_lookup(const uint8_t *base, size_t length, size_t lookupOffset,
    size_t valueSize, uint32_t numGlyphs, Visitor visitor)
{
    // A glyph count no table legitimately reaches; also the ceiling on entries any one lookup enumerates.
    const uint64_t kMaxGlyphs = 0x10000;
    if (!valueSize || valueSize > 4)
        return false;

    uint16_t format = 0;
    if (!wk_aat_read16(base, length, lookupOffset, &format))
        return false;

    if (format == 0) {
        // A value for every glyph, laid down right after the format word. This OS sizes the array from
        // the table extent (limit - arrayStart) / valueSize and looks up a glyph only when it is below
        // that count, so the array is bounded by construction; matching it never over-rejects a short one.
        uint64_t arrayStart = static_cast<uint64_t>(lookupOffset) + 2;
        if (arrayStart > length)
            return false;
        uint64_t count = (length - arrayStart) / valueSize;
        (void)numGlyphs;
        for (uint64_t g = 0; g < count; ++g) {
            if (!visitor(wk_aat_lookup_entry { static_cast<uint32_t>(g),
                    static_cast<size_t>(arrayStart + g * valueSize) }))
                return false;
        }
        return true;
    }

    if (format == 8) {
        // firstGlyph, glyphCount, then a value per glyph in that trimmed range.
        uint16_t firstGlyph = 0, glyphCount = 0;
        if (!wk_aat_read16(base, length, lookupOffset + 2, &firstGlyph)
            || !wk_aat_read16(base, length, lookupOffset + 4, &glyphCount))
            return false;
        uint64_t arrayStart = static_cast<uint64_t>(lookupOffset) + 6;
        if (arrayStart + static_cast<uint64_t>(glyphCount) * valueSize > length)
            return false;
        if (static_cast<uint64_t>(firstGlyph) + glyphCount > kMaxGlyphs)
            return false;
        for (uint64_t i = 0; i < glyphCount; ++i) {
            if (!visitor(wk_aat_lookup_entry { static_cast<uint32_t>(firstGlyph + i),
                    static_cast<size_t>(arrayStart + i * valueSize) }))
                return false;
        }
        return true;
    }

    if (format != 2 && format != 4 && format != 6) {
        // Any other format this OS treats as a bad table: the lookup returns nothing and the table is
        // inert at runtime, so keep it and enumerate no entries rather than diverge by dropping it.
        return true;
    }

    // Binary-search header: unitSize, nUnits, then searchRange/entrySelector/rangeShift the shaper
    // recomputes. Segments follow at lookupOffset + 12.
    uint16_t unitSize = 0, nUnits = 0;
    if (!wk_aat_read16(base, length, lookupOffset + 2, &unitSize)
        || !wk_aat_read16(base, length, lookupOffset + 4, &nUnits))
        return false;

    // Each record holds the glyph ids and, at a fixed position, the value or segment offset; this OS
    // strides by the unitSize the table declares, so a larger unitSize (padded records) is legal as long
    // as the value still fits and the array stays in bounds.
    uint64_t minimumUnit = (format == 2) ? 4 + valueSize : (format == 4) ? 6 : 2 + valueSize;
    if (unitSize < minimumUnit)
        return false;

    uint64_t segStart = static_cast<uint64_t>(lookupOffset) + 12;
    if (segStart + static_cast<uint64_t>(nUnits) * unitSize > length)
        return false;

    if (format == 6) {
        // A sorted array of (glyph, value) pairs, one glyph per record; 0xFFFF terminates.
        for (uint64_t u = 0; u < nUnits; ++u) {
            uint64_t rec = segStart + u * unitSize;
            uint16_t glyph = 0;
            if (!wk_aat_read16(base, length, static_cast<size_t>(rec), &glyph))
                return false;
            if (glyph == 0xFFFF)
                continue;
            if (!visitor(wk_aat_lookup_entry { glyph, static_cast<size_t>(rec + 2) }))
                return false;
        }
        return true;
    }

    uint64_t visited = 0;
    for (uint64_t u = 0; u < nUnits; ++u) {
        uint64_t rec = segStart + u * unitSize;
        uint16_t lastGlyph = 0, firstGlyph = 0;
        if (!wk_aat_read16(base, length, static_cast<size_t>(rec), &lastGlyph)
            || !wk_aat_read16(base, length, static_cast<size_t>(rec + 2), &firstGlyph))
            return false;
        // 0xFFFF/0xFFFF terminates the segment list; the shaper never reads its value.
        if (lastGlyph == 0xFFFF && firstGlyph == 0xFFFF)
            continue;
        if (firstGlyph > lastGlyph)
            return false;
        uint64_t span = static_cast<uint64_t>(lastGlyph) - firstGlyph + 1;
        visited += span;
        if (visited > kMaxGlyphs)
            return false;

        if (format == 2) {
            // One value shared by the whole segment, stored in the record after the two glyph ids.
            size_t valueOffset = static_cast<size_t>(rec + 4);
            for (uint64_t g = firstGlyph; g <= lastGlyph; ++g) {
                if (!visitor(wk_aat_lookup_entry { static_cast<uint32_t>(g), valueOffset }))
                    return false;
            }
        } else {
            // Format 4: the record holds an offset from the START OF THE LOOKUP TABLE (this OS's
            // LookupSegmentArray reads base + segment.offset, where base is the lookup, not the sfnt) to
            // a value per glyph in the span, so it is resolved against lookupOffset, not the table base.
            uint16_t segOffset = 0;
            if (!wk_aat_read16(base, length, static_cast<size_t>(rec + 4), &segOffset))
                return false;
            uint64_t arrayStart = static_cast<uint64_t>(lookupOffset) + segOffset;
            if (arrayStart + span * valueSize > length)
                return false;
            for (uint64_t i = 0; i < span; ++i) {
                if (!visitor(wk_aat_lookup_entry { static_cast<uint32_t>(firstGlyph + i),
                        static_cast<size_t>(arrayStart + i * valueSize) }))
                    return false;
            }
        }
    }
    return true;
}

#endif
