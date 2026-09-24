// The memory-safe font parser behind FPFontCreateMemorySafeFontsFromData and
// CTFontManagerCreateMemorySafeFontDescriptorFromData in CoreText.c, on OTS.
//
// OTS reads a sfnt into its own bounds-checked per-table structures and writes a fresh font out of
// them, so every table directory entry, offset and length in the result is a value OTS computed.
// A table OTS does not model is left out. Callers get NULL for a font it will not accept.

#include <CoreFoundation/CoreFoundation.h>
#include <opentype-sanitiser.h>
#include <objc/objc.h>
#include <objc/runtime.h>
#include <algorithm>
#include <cstring>
#include <vector>

#include "ots_aat.h"

// wk_ots_sanitize_font stamps its immutable output with a process-unique object association so the
// CoreText entry points can tell a font they already sanitized from one off the network and sanitize
// each font once. The mark is set only on an immutable copy, so the bytes cannot change under it, and
// only this code ever sets it -- a CFData built from content never carries it and is always sanitized.
static SEL wk_ots_sanitized_key(void) { return sel_registerName("wk_otsSanitizedFont"); }

extern "C" bool wk_font_is_ots_sanitized(CFDataRef data)
{
    return data && objc_getAssociatedObject((id)(const void *)data, wk_ots_sanitized_key()) == (id)kCFBooleanTrue;
}

namespace {

// OTS asks the stream how much room it has before it decompresses a WOFF and refuses a font that
// would outgrow it; its own ExpandingMemoryStream answers with a caller-chosen limit the same way. The
// limit is OTS's own ceiling on a decompressed font, OTS_MAX_DECOMPRESSED_FILE_SIZE in its ots.h.
const size_t maximumSanitizedFontSize = 300u * 1024u * 1024u;

// OTS lays a table directory down before it knows where the tables after it land, then seeks back to
// fill it in, so the sink needs random access rather than append. It is the CFData the caller returns,
// written in place.
class FontDataOTSStream final : public ots::OTSStream {
public:
    FontDataOTSStream() : m_data(CFDataCreateMutable(kCFAllocatorDefault, 0)) { }

    ~FontDataOTSStream() override
    {
        if (m_data)
            CFRelease(m_data);
    }

    CFDataRef copyData()
    {
        CFDataRef data = m_data;
        m_data = NULL;
        return data;
    }

private:
    size_t size() override { return maximumSanitizedFontSize; }

    bool WriteRaw(const void* data, size_t length) override
    {
        if (!m_data || length > maximumSanitizedFontSize - m_offset)
            return false;

        size_t end = m_offset + length;
        // CFDataSetLength zeroes what it adds, so a gap left by a seek past the end never carries
        // stray bytes into the font.
        if (end > static_cast<size_t>(CFDataGetLength(m_data))) {
            CFDataSetLength(m_data, static_cast<CFIndex>(end));
            if (static_cast<size_t>(CFDataGetLength(m_data)) < end)
                return false;
        }

        memcpy(CFDataGetMutableBytePtr(m_data) + m_offset, data, length);
        m_offset = end;
        return true;
    }

    bool Seek(off_t position) override
    {
        if (position < 0 || static_cast<uint64_t>(position) > maximumSanitizedFontSize)
            return false;
        m_offset = static_cast<size_t>(position);
        return true;
    }

    off_t Tell() const override { return static_cast<off_t>(m_offset); }

    CFMutableDataRef m_data;
    size_t m_offset = 0;
};

// OTS models neither sbix nor the AAT layout tables, and this OS reads all of them from offsets it does
// not bound: sbix for colour-bitmap glyphs, and morx/mort/kerx/kern/feat/ankr/trak/just/opbd/prop/lcar/
// bsln for shaping. Rather than drop them -- which would lose colour emoji and every AAT-only font's
// shaping -- each is passed through OTS and then validated against the sanitized sfnt: sbix by
// sbixOffsetsInBounds, and each AAT table by the validator in its ots_aat_<tag>.cpp. Each validator
// reproduces the reads this OS performs -- bounded by the whole table, as this OS bounds them, and for
// the metamorphosis state machines by walking the reachable (state, component-stack) graph -- and drops
// the table when any read this OS would make leaves the table or crashes its shaper. A table that
// validates is kept; one that does not is dropped in a second OTS pass.
struct AATTable {
    uint32_t tag;
    bool (*validate)(const uint8_t *table, size_t length, const wk_aat_font_facts &facts);
};

const AATTable kAATTables[] = {
    { OTS_TAG('m', 'o', 'r', 'x'), wk_aat_validate_morx },
    { OTS_TAG('m', 'o', 'r', 't'), wk_aat_validate_mort },
    { OTS_TAG('k', 'e', 'r', 'x'), wk_aat_validate_kerx },
    { OTS_TAG('k', 'e', 'r', 'n'), wk_aat_validate_kern },
    { OTS_TAG('f', 'e', 'a', 't'), wk_aat_validate_feat },
    { OTS_TAG('a', 'n', 'k', 'r'), wk_aat_validate_ankr },
    { OTS_TAG('t', 'r', 'a', 'k'), wk_aat_validate_trak },
    { OTS_TAG('j', 'u', 's', 't'), wk_aat_validate_just },
    { OTS_TAG('o', 'p', 'b', 'd'), wk_aat_validate_opbd },
    { OTS_TAG('p', 'r', 'o', 'p'), wk_aat_validate_prop },
    { OTS_TAG('l', 'c', 'a', 'r'), wk_aat_validate_lcar },
    { OTS_TAG('b', 's', 'l', 'n'), wk_aat_validate_bsln },
};
const size_t kAATTableCount = sizeof(kAATTables) / sizeof(kAATTables[0]);
const uint32_t kAllPreservedMask = (1u << kAATTableCount) - 1u;

// Pass 1 passes AAT tables through (keepMask all ones) to the sanitized sfnt for validation; pass 2
// passes through only the tables that validated (their bits still set in keepMask),
// dropping the rest. sbix is always kept -- sbixOffsetsInBounds enforces its bounds separately.
class FontParserContext final : public ots::OTSContext {
public:
    explicit FontParserContext(uint32_t keepMask) : m_keepMask(keepMask) { }

private:
    ots::TableAction GetTableAction(uint32_t tag) override
    {
        if (tag == OTS_TAG('s', 'b', 'i', 'x'))
            return ots::TABLE_ACTION_PASSTHRU;
        for (size_t i = 0; i < kAATTableCount; ++i) {
            if (kAATTables[i].tag == tag)
                return (m_keepMask & (1u << i)) ? ots::TABLE_ACTION_PASSTHRU : ots::TABLE_ACTION_DEFAULT;
        }
        return ots::TABLE_ACTION_DEFAULT;
    }

    uint32_t m_keepMask;
};

// This OS's colour-bitmap lookup reads a glyph's sbix record at the offset the font supplies without
// checking it lies inside the table, so a record offset pointing past the end faults inside
// CTFontDrawGlyphs and CTFontCreatePathForGlyph. These functions read the offsets the way that lookup
// does -- ppem then a glyphCount+1 array of record offsets per strike, glyphCount from maxp -- and
// answer false when any strike offset, offset-array entry or record runs outside the sbix table.
uint16_t readBE16(const uint8_t *p) { return static_cast<uint16_t>((p[0] << 8) | p[1]); }

uint32_t readBE32(const uint8_t *p)
{
    return (static_cast<uint32_t>(p[0]) << 24) | (static_cast<uint32_t>(p[1]) << 16)
        | (static_cast<uint32_t>(p[2]) << 8) | p[3];
}

bool sbixOffsetsInBoundsForFont(const uint8_t *sfnt, size_t length, size_t base)
{
    if (base + 12 > length)
        return false;
    unsigned tableCount = readBE16(sfnt + base + 4);
    if (base + 12 + static_cast<uint64_t>(tableCount) * 16 > length)
        return false;

    size_t sbixOffset = 0, sbixLength = 0;
    unsigned glyphCount = 0;
    bool haveMaxp = false;
    for (unsigned i = 0; i < tableCount; ++i) {
        const uint8_t *record = sfnt + base + 12 + i * 16;
        uint32_t tag = readBE32(record), offset = readBE32(record + 8), tableLength = readBE32(record + 12);
        if (static_cast<uint64_t>(offset) + tableLength > length)
            return false;
        if (tag == OTS_TAG('s', 'b', 'i', 'x')) {
            sbixOffset = offset;
            sbixLength = tableLength;
        } else if (tag == OTS_TAG('m', 'a', 'x', 'p')) {
            if (tableLength < 6)
                return false;
            glyphCount = readBE16(sfnt + offset + 4);
            haveMaxp = true;
        }
    }
    if (!sbixOffset)
        return true;
    if (!haveMaxp || sbixLength < 8)
        return false;

    const uint8_t *sbix = sfnt + sbixOffset;
    uint32_t strikeCount = readBE32(sbix + 4);
    if (static_cast<uint64_t>(strikeCount) * 4 > sbixLength - 8)
        return false;
    for (uint32_t s = 0; s < strikeCount; ++s) {
        uint32_t strikeOffset = readBE32(sbix + 8 + s * 4);
        uint64_t headerNeed = 4 + (static_cast<uint64_t>(glyphCount) + 1) * 4;
        if (static_cast<uint64_t>(strikeOffset) + headerNeed > sbixLength)
            return false;
        const uint8_t *strike = sbix + strikeOffset;
        for (unsigned g = 0; g < glyphCount; ++g) {
            uint32_t start = readBE32(strike + 4 + g * 4);
            uint32_t end = readBE32(strike + 4 + (g + 1) * 4);
            if (end == start)
                continue;
            if (end < start || end - start < 8)
                return false;
            if (static_cast<uint64_t>(strikeOffset) + end > sbixLength)
                return false;
            // A 'dupe' record names another glyph in place of image bytes; this OS reads that glyph
            // index at record+8 and then indexes the strike's offset array with it, both unchecked. A
            // dupe record shorter than 10 bytes has no index to read, and an index past the glyph
            // count reaches outside that array.
            const uint8_t *record = strike + start;
            if (readBE32(record + 4) == OTS_TAG('d', 'u', 'p', 'e')) {
                if (end - start < 10 || readBE16(record + 8) >= glyphCount)
                    return false;
            }
        }
    }
    return true;
}

bool sbixOffsetsInBounds(CFDataRef font)
{
    CFIndex length = CFDataGetLength(font);
    if (length < 4)
        return false;
    const uint8_t *sfnt = CFDataGetBytePtr(font);
    if (readBE32(sfnt) == OTS_TAG('t', 't', 'c', 'f')) {
        if (length < 12)
            return false;
        uint32_t fontCount = readBE32(sfnt + 8);
        if (12 + static_cast<uint64_t>(fontCount) * 4 > static_cast<uint64_t>(length))
            return false;
        for (uint32_t i = 0; i < fontCount; ++i) {
            if (!sbixOffsetsInBoundsForFont(sfnt, static_cast<size_t>(length), readBE32(sfnt + 12 + i * 4)))
                return false;
        }
        return true;
    }
    return sbixOffsetsInBoundsForFont(sfnt, static_cast<size_t>(length), 0);
}

// The sfnt table directory at `base`; fills *outOffset/*outLength for `tag` and returns true when the
// table is present and lies wholly inside the font. Backs both the facts computation and the findTable a
// validator uses to reach a sibling AAT table.
bool findTableInFont(const uint8_t *sfnt, size_t length, size_t base, uint32_t tag,
    size_t *outOffset, size_t *outLength)
{
    if (base + 12 > length)
        return false;
    unsigned tableCount = readBE16(sfnt + base + 4);
    if (base + 12 + static_cast<uint64_t>(tableCount) * 16 > length)
        return false;
    for (unsigned i = 0; i < tableCount; ++i) {
        const uint8_t *record = sfnt + base + 12 + i * 16;
        if (readBE32(record) != tag)
            continue;
        uint32_t offset = readBE32(record + 8), tableLength = readBE32(record + 12);
        if (static_cast<uint64_t>(offset) + tableLength > length)
            return false;
        *outOffset = offset;
        *outLength = tableLength;
        return true;
    }
    return false;
}

// The cookie a validator carries as facts.sfnt: the sanitized sfnt and the font's base offset. It lets
// findSiblingTable resolve a tag without the validator seeing the collection layout.
struct FindTableCookie {
    const uint8_t *sfnt;
    size_t length;
    size_t base;
};

bool findSiblingTable(const wk_aat_font_facts &facts, uint32_t tag,
    const uint8_t **outData, size_t *outLength)
{
    const FindTableCookie *cookie = static_cast<const FindTableCookie *>(facts.sfnt);
    size_t offset = 0, tableLength = 0;
    if (!findTableInFont(cookie->sfnt, cookie->length, cookie->base, tag, &offset, &tableLength))
        return false;
    *outData = cookie->sfnt + offset;
    *outLength = tableLength;
    return true;
}

// The facts a validator bounds against. numGlyphs is maxp.numGlyphs: OTS enforces that a CFF font's
// CharStrings count equals maxp.numGlyphs on its own output, so on the sanitized sfnt the maxp count is
// the count this OS bounds glyph indices against. `ok` is false when maxp is absent or short, and the
// caller then drops every AAT table without calling a validator.
wk_aat_font_facts computeFacts(const FindTableCookie *cookie)
{
    wk_aat_font_facts facts;
    facts.numGlyphs = 0;
    facts.unitsPerEm = 0;
    facts.ok = false;
    facts.findTable = findSiblingTable;
    facts.sfnt = cookie;

    size_t offset = 0, len = 0;
    if (findTableInFont(cookie->sfnt, cookie->length, cookie->base, OTS_TAG('m', 'a', 'x', 'p'), &offset, &len)
        && len >= 6) {
        facts.numGlyphs = readBE16(cookie->sfnt + offset + 4);
        facts.ok = true;
    }
    if (findTableInFont(cookie->sfnt, cookie->length, cookie->base, OTS_TAG('h', 'e', 'a', 'd'), &offset, &len)
        && len >= 20)
        facts.unitsPerEm = readBE16(cookie->sfnt + offset + 18);
    return facts;
}

// AAT tables are validated against the sanitized glyph count and sibling tables.
void collectFontTableDrops(const uint8_t *sfnt, size_t length, size_t base, uint32_t *dropMask)
{
    FindTableCookie cookie { sfnt, length, base };
    wk_aat_font_facts facts = computeFacts(&cookie);
    for (size_t i = 0; i < kAATTableCount; ++i) {
        size_t offset = 0, len = 0;
        if (!findTableInFont(sfnt, length, base, kAATTables[i].tag, &offset, &len))
            continue;
        if (!facts.ok || !kAATTables[i].validate(sfnt + offset, len, facts))
            *dropMask |= (1u << i);
    }
}

// The union of table drops across every font in the sanitized sfnt or collection.
uint32_t collectTableDrops(CFDataRef font)
{
    const uint8_t *sfnt = CFDataGetBytePtr(font);
    size_t length = static_cast<size_t>(CFDataGetLength(font));
    uint32_t dropMask = 0;
    if (length >= 12 && readBE32(sfnt) == OTS_TAG('t', 't', 'c', 'f')) {
        uint32_t fontCount = readBE32(sfnt + 8);
        if (12 + static_cast<uint64_t>(fontCount) * 4 > length)
            return kAllPreservedMask;
        for (uint32_t i = 0; i < fontCount; ++i)
            collectFontTableDrops(sfnt, length, readBE32(sfnt + 12 + i * 4), &dropMask);
        return dropMask;
    }
    collectFontTableDrops(sfnt, length, 0, &dropMask);
    return dropMask;
}

// One OTS pass over `bytes`: the font at `index` of a collection, or the whole file for -1. NULL when OTS
// refuses it.
CFDataRef processFont(const uint8_t *bytes, size_t length, uint32_t index, uint32_t keepMask)
{
    FontDataOTSStream output;
    FontParserContext context(keepMask);
    if (!context.Process(&output, bytes, length, index))
        return NULL;
    CFDataRef font = output.copyData();
    if (font && !CFDataGetLength(font)) {
        CFRelease(font);
        return NULL;
    }
    return font;
}

// Checks a font OTS wrote with every AAT table passed through: its sbix offsets must lie in bounds,
// and a second pass keeps only the AAT tables that validated. Takes ownership of `font`.
CFDataRef validateSanitizedFont(CFDataRef font)
{
    if (!sbixOffsetsInBounds(font)) {
        CFRelease(font);
        return NULL;
    }
    uint32_t dropMask = collectTableDrops(font);
    if (!dropMask)
        return font;
    // The second pass re-reads OTS's own output (a bare sfnt, so no unwrap), and OTS passes kept tables
    // byte for byte.
    CFDataRef kept = processFont(CFDataGetBytePtr(font), static_cast<size_t>(CFDataGetLength(font)),
        static_cast<uint32_t>(-1), kAllPreservedMask & ~dropMask);
    CFRelease(font);
    return kept;
}

// This OS's GPOS reader skips the last glyph a PairPos format 1 subtable covers: OTL::GPOS::ApplyPairPos
// (CoreText 0x433ae) takes the glyph's 1-based Coverage index and requires pairSetCount to exceed it
// (cmp at 0x435e0, jbe to the no-match exit), where pairSetCount equals the Coverage count, so the last
// covered glyph never finds its PairSet and never kerns. Each such subtable is written again at the end
// of GPOS with one more PairSet offset, a copy of the last, and reached through an Extension subtable, as
// the lookup types a font compiler writes for a large GPOS are. A reader that indexes PairSets by Coverage
// index, as the OpenType specification has every reader do, finds the same pairs. The offsets inside the
// rewritten subtable move by the two bytes inserted after its offset array.
//
// A PairPos lookup becomes an Extension lookup by writing an Extension subtable over the first 8 bytes of
// each of its subtables and copying every one of them, format 2 unchanged. It stays as it is when any offset
// in GPOS resolves into the bytes that would change, or when a lookup that stays as it is shares one of
// its subtables.
struct LayoutTableReader {
    const uint8_t *bytes;
    size_t length;

    bool has(size_t offset, size_t size) const { return offset <= length && size <= length - offset; }
    uint16_t u16(size_t offset) const { return has(offset, 2) ? readBE16(bytes + offset) : 0; }
    uint32_t u32(size_t offset) const { return has(offset, 4) ? readBE32(bytes + offset) : 0; }
};

void writeBE16(uint8_t *out, uint16_t value)
{
    out[0] = static_cast<uint8_t>(value >> 8);
    out[1] = static_cast<uint8_t>(value);
}

void writeBE32(uint8_t *out, uint32_t value)
{
    out[0] = static_cast<uint8_t>(value >> 24);
    out[1] = static_cast<uint8_t>(value >> 16);
    out[2] = static_cast<uint8_t>(value >> 8);
    out[3] = static_cast<uint8_t>(value);
}

size_t valueRecordSize(uint16_t format)
{
    size_t fields = 0;
    for (unsigned bit = 0; bit < 8; ++bit)
        fields += (format >> bit) & 1;
    return 2 * fields;
}

// Where, relative to a value record, each of its Device offsets lies.
std::vector<size_t> deviceFieldPositions(uint16_t format)
{
    std::vector<size_t> positions;
    size_t position = 0;
    for (unsigned bit = 0; bit < 8; ++bit) {
        if (!((format >> bit) & 1))
            continue;
        if (bit >= 4)
            positions.push_back(position);
        position += 2;
    }
    return positions;
}

// Every position an offset in GPOS resolves to: the script, feature, feature-variation and lookup lists
// and what they reference, every lookup's subtables, and the Coverage, ClassDef, PairSet, Anchor, mark and
// base arrays, rule sets and Device tables those reference.
class GPOSOffsetTargets {
public:
    explicit GPOSOffsetTargets(const LayoutTableReader &table)
        : m_table(table)
    {
        walk();
        std::sort(m_targets.begin(), m_targets.end());
        std::sort(m_subtableTargets.begin(), m_subtableTargets.end());
    }

    // Whether an offset resolves into [begin, end).
    bool anyWithin(size_t begin, size_t end) const
    {
        auto target = std::lower_bound(m_targets.begin(), m_targets.end(), begin);
        if (target != m_targets.end() && *target < end)
            return true;
        auto subtable = std::lower_bound(m_subtableTargets.begin(), m_subtableTargets.end(), begin + 1);
        return subtable != m_subtableTargets.end() && *subtable < end;
    }

private:
    size_t add(size_t base, size_t offset)
    {
        if (!offset)
            return 0;
        m_targets.push_back(base + offset);
        return base + offset;
    }

    bool fits(size_t position, size_t size) const { return m_table.has(position, size); }

    void valueRecord(size_t base, size_t record, uint16_t format)
    {
        for (size_t position : deviceFieldPositions(format))
            add(base, m_table.u16(record + position));
    }

    void anchor(size_t base, uint16_t offset)
    {
        size_t anchorTable = add(base, offset);
        if (anchorTable && m_table.u16(anchorTable) == 3) {
            add(anchorTable, m_table.u16(anchorTable + 6));
            add(anchorTable, m_table.u16(anchorTable + 8));
        }
    }

    void markArray(size_t base, uint16_t offset)
    {
        size_t array = add(base, offset);
        if (!array)
            return;
        for (uint16_t i = 0; i < m_table.u16(array) && fits(array + 2 + 4 * static_cast<size_t>(i), 4); ++i)
            anchor(array, m_table.u16(array + 4 + 4 * static_cast<size_t>(i)));
    }

    // An array of rows, each `columns` Anchor offsets from the array.
    void anchorMatrix(size_t array, uint16_t columns)
    {
        const size_t cells = static_cast<size_t>(m_table.u16(array)) * columns;
        for (size_t cell = 0; cell < cells && fits(array + 2 + 2 * cell, 2); ++cell)
            anchor(array, m_table.u16(array + 2 + 2 * cell));
    }

    void ruleSets(size_t subtable, size_t countPosition)
    {
        for (uint16_t i = 0; i < m_table.u16(subtable + countPosition) && fits(subtable + countPosition + 2 + 2 * static_cast<size_t>(i), 2); ++i) {
            size_t set = add(subtable, m_table.u16(subtable + countPosition + 2 + 2 * static_cast<size_t>(i)));
            if (!set)
                continue;
            for (uint16_t rule = 0; rule < m_table.u16(set) && fits(set + 2 + 2 * static_cast<size_t>(rule), 2); ++rule)
                add(set, m_table.u16(set + 2 + 2 * static_cast<size_t>(rule)));
        }
    }

    void offsetArray(size_t base, size_t countPosition)
    {
        for (uint16_t i = 0; i < m_table.u16(countPosition) && fits(countPosition + 2 + 2 * static_cast<size_t>(i), 2); ++i)
            add(base, m_table.u16(countPosition + 2 + 2 * static_cast<size_t>(i)));
    }

    void subtable(uint16_t type, size_t position, bool extended)
    {
        const LayoutTableReader &t = m_table;
        uint16_t format = t.u16(position);
        switch (type) {
        case 1: {
            add(position, t.u16(position + 2));
            uint16_t valueFormat = t.u16(position + 4);
            if (format == 1)
                valueRecord(position, position + 6, valueFormat);
            else if (format == 2) {
                const size_t size = valueRecordSize(valueFormat);
                for (uint16_t i = 0; i < t.u16(position + 6) && fits(position + 8 + i * size, size); ++i)
                    valueRecord(position, position + 8 + i * size, valueFormat);
            }
            break;
        }
        case 2: {
            add(position, t.u16(position + 2));
            uint16_t format1 = t.u16(position + 4), format2 = t.u16(position + 6);
            const size_t size1 = valueRecordSize(format1), size2 = valueRecordSize(format2);
            if (format == 1) {
                for (uint16_t i = 0; i < t.u16(position + 8) && fits(position + 10 + 2 * static_cast<size_t>(i), 2); ++i) {
                    size_t pairSet = add(position, t.u16(position + 10 + 2 * static_cast<size_t>(i)));
                    if (!pairSet)
                        continue;
                    const size_t recordSize = 2 + size1 + size2;
                    for (uint16_t record = 0; record < t.u16(pairSet) && fits(pairSet + 2 + record * recordSize, recordSize); ++record) {
                        valueRecord(position, pairSet + 4 + record * recordSize, format1);
                        valueRecord(position, pairSet + 4 + record * recordSize + size1, format2);
                    }
                }
            } else if (format == 2) {
                add(position, t.u16(position + 8));
                add(position, t.u16(position + 10));
                const size_t records = static_cast<size_t>(t.u16(position + 12)) * t.u16(position + 14);
                for (size_t record = 0; record < records && fits(position + 16 + record * (size1 + size2), size1 + size2); ++record) {
                    valueRecord(position, position + 16 + record * (size1 + size2), format1);
                    valueRecord(position, position + 16 + record * (size1 + size2) + size1, format2);
                }
            }
            break;
        }
        case 3:
            add(position, t.u16(position + 2));
            for (uint16_t i = 0; i < t.u16(position + 4) && fits(position + 6 + 4 * static_cast<size_t>(i), 4); ++i) {
                anchor(position, t.u16(position + 6 + 4 * static_cast<size_t>(i)));
                anchor(position, t.u16(position + 8 + 4 * static_cast<size_t>(i)));
            }
            break;
        case 4:
        case 6: {
            add(position, t.u16(position + 2));
            add(position, t.u16(position + 4));
            markArray(position, t.u16(position + 8));
            size_t array = add(position, t.u16(position + 10));
            if (array)
                anchorMatrix(array, t.u16(position + 6));
            break;
        }
        case 5: {
            add(position, t.u16(position + 2));
            add(position, t.u16(position + 4));
            markArray(position, t.u16(position + 8));
            size_t ligatures = add(position, t.u16(position + 10));
            for (uint16_t i = 0; ligatures && i < t.u16(ligatures) && fits(ligatures + 2 + 2 * static_cast<size_t>(i), 2); ++i) {
                size_t attach = add(ligatures, t.u16(ligatures + 2 + 2 * static_cast<size_t>(i)));
                if (attach)
                    anchorMatrix(attach, t.u16(position + 6));
            }
            break;
        }
        case 7:
            if (format == 1) {
                add(position, t.u16(position + 2));
                ruleSets(position, 4);
            } else if (format == 2) {
                add(position, t.u16(position + 2));
                add(position, t.u16(position + 4));
                ruleSets(position, 6);
            } else if (format == 3) {
                for (uint16_t i = 0; i < t.u16(position + 2) && fits(position + 6 + 2 * static_cast<size_t>(i), 2); ++i)
                    add(position, t.u16(position + 6 + 2 * static_cast<size_t>(i)));
            }
            break;
        case 8:
            if (format == 1) {
                add(position, t.u16(position + 2));
                ruleSets(position, 4);
            } else if (format == 2) {
                for (size_t field = 2; field <= 8; field += 2)
                    add(position, t.u16(position + field));
                ruleSets(position, 10);
            } else if (format == 3) {
                size_t count = position + 2;
                for (unsigned sequence = 0; sequence < 3 && fits(count, 2); ++sequence) {
                    offsetArray(position, count);
                    count += 2 + 2 * static_cast<size_t>(t.u16(count));
                }
            }
            break;
        case 9:
            if (!extended && format == 1 && fits(position, 8) && t.u32(position + 4)) {
                size_t target = position + t.u32(position + 4);
                m_subtableTargets.push_back(target);
                subtable(t.u16(position + 2), target, true);
            }
            break;
        }
    }

    void feature(size_t base, size_t offset32OrZero, uint16_t offset16)
    {
        size_t featureTable = offset32OrZero ? base + offset32OrZero : add(base, offset16);
        if (offset32OrZero)
            m_targets.push_back(featureTable);
        if (featureTable)
            add(featureTable, m_table.u16(featureTable));
    }

    void walk()
    {
        const LayoutTableReader &t = m_table;
        size_t scripts = add(0, t.u16(4));
        for (uint16_t i = 0; scripts && i < t.u16(scripts) && fits(scripts + 2 + 6 * static_cast<size_t>(i), 6); ++i) {
            size_t script = add(scripts, t.u16(scripts + 6 + 6 * static_cast<size_t>(i)));
            if (!script)
                continue;
            add(script, t.u16(script));
            for (uint16_t j = 0; j < t.u16(script + 2) && fits(script + 4 + 6 * static_cast<size_t>(j), 6); ++j)
                add(script, t.u16(script + 8 + 6 * static_cast<size_t>(j)));
        }
        size_t features = add(0, t.u16(6));
        for (uint16_t i = 0; features && i < t.u16(features) && fits(features + 2 + 6 * static_cast<size_t>(i), 6); ++i)
            feature(features, 0, t.u16(features + 6 + 6 * static_cast<size_t>(i)));
        size_t lookups = add(0, t.u16(8));
        for (uint16_t i = 0; lookups && i < t.u16(lookups) && fits(lookups + 2 + 2 * static_cast<size_t>(i), 2); ++i) {
            size_t lookup = add(lookups, t.u16(lookups + 2 + 2 * static_cast<size_t>(i)));
            if (!lookup)
                continue;
            for (uint16_t s = 0; s < t.u16(lookup + 4) && fits(lookup + 6 + 2 * static_cast<size_t>(s), 2); ++s) {
                uint16_t offset = t.u16(lookup + 6 + 2 * static_cast<size_t>(s));
                size_t position = offset ? lookup + offset : 0;
                if (position)
                    m_subtableTargets.push_back(position);
                if (position)
                    subtable(t.u16(lookup), position, false);
            }
        }
        if (t.u16(2) >= 1 && t.u32(10)) {
            size_t variations = t.u32(10);
            m_targets.push_back(variations);
            for (uint32_t i = 0; i < t.u32(variations + 4) && fits(variations + 8 + 8 * static_cast<size_t>(i), 8); ++i) {
                size_t conditions = t.u32(variations + 8 + 8 * static_cast<size_t>(i));
                if (conditions) {
                    m_targets.push_back(variations + conditions);
                    size_t set = variations + conditions;
                    for (uint16_t c = 0; c < t.u16(set) && fits(set + 2 + 4 * static_cast<size_t>(c), 4); ++c) {
                        if (t.u32(set + 2 + 4 * static_cast<size_t>(c)))
                            m_targets.push_back(set + t.u32(set + 2 + 4 * static_cast<size_t>(c)));
                    }
                }
                size_t substitution = t.u32(variations + 12 + 8 * static_cast<size_t>(i));
                if (!substitution)
                    continue;
                size_t table = variations + substitution;
                m_targets.push_back(table);
                for (uint16_t r = 0; r < t.u16(table + 4) && fits(table + 6 + 6 * static_cast<size_t>(r), 6); ++r)
                    feature(table, t.u32(table + 8 + 6 * static_cast<size_t>(r)), 0);
            }
        }
    }

    const LayoutTableReader &m_table;
    std::vector<size_t> m_targets;
    std::vector<size_t> m_subtableTargets;
};

// Extends *end past the Device or VariationIndex table `offset` bytes after `base`, relative to base.
bool extendPastDevice(const LayoutTableReader &table, size_t base, uint16_t offset, size_t *end)
{
    if (!offset)
        return true;
    size_t device = base + offset;
    if (!table.has(device, 6))
        return false;
    uint16_t startSize = table.u16(device), endSize = table.u16(device + 2), format = table.u16(device + 4);
    size_t size;
    if (format == 0x8000)
        size = 6;
    else if (format >= 1 && format <= 3 && endSize >= startSize)
        size = 6 + ((((static_cast<size_t>(endSize) - startSize + 1) << format) + 15) / 16) * 2;
    else
        return false;
    if (!table.has(device, size))
        return false;
    *end = std::max(*end, static_cast<size_t>(offset) + size);
    return true;
}

bool extendPastCoverage(const LayoutTableReader &table, size_t base, uint16_t offset, size_t *end)
{
    size_t coverage = base + offset;
    uint16_t format = table.u16(coverage), count = table.u16(coverage + 2);
    size_t size = format == 1 ? 4 + 2 * static_cast<size_t>(count) : format == 2 ? 4 + 6 * static_cast<size_t>(count) : 0;
    if (!offset || !size || !table.has(coverage, size))
        return false;
    *end = std::max(*end, static_cast<size_t>(offset) + size);
    return true;
}

bool extendPastClassDef(const LayoutTableReader &table, size_t base, uint16_t offset, size_t *end)
{
    if (!offset)
        return true;
    size_t classDef = base + offset;
    uint16_t format = table.u16(classDef);
    size_t size = format == 1 ? 6 + 2 * static_cast<size_t>(table.u16(classDef + 4))
        : format == 2 ? 4 + 6 * static_cast<size_t>(table.u16(classDef + 2)) : 0;
    if (!size || !table.has(classDef, size))
        return false;
    *end = std::max(*end, static_cast<size_t>(offset) + size);
    return true;
}

// The PairPos format 1 subtable at `subtable`, with one more PairSet offset inserted after its offset array.
bool copyPairPosFormat1WithExtraPairSet(const LayoutTableReader &table, size_t subtable, std::vector<uint8_t> *copy)
{
    uint16_t coverageOffset = table.u16(subtable + 2), format1 = table.u16(subtable + 4), format2 = table.u16(subtable + 6);
    uint16_t pairSetCount = table.u16(subtable + 8);
    const size_t arrayEnd = 10 + 2 * static_cast<size_t>(pairSetCount);
    if (!pairSetCount || !table.has(subtable, arrayEnd) || (format1 | format2) > 0xff)
        return false;
    const size_t size1 = valueRecordSize(format1), size2 = valueRecordSize(format2), recordSize = 2 + size1 + size2;
    const std::vector<size_t> devices1 = deviceFieldPositions(format1), devices2 = deviceFieldPositions(format2);
    size_t end = arrayEnd;
    if (coverageOffset < arrayEnd || !extendPastCoverage(table, subtable, coverageOffset, &end))
        return false;
    size_t coverage = subtable + coverageOffset;
    size_t coveredGlyphs = table.u16(coverage + 2);
    if (table.u16(coverage) == 2) {
        coveredGlyphs = 0;
        for (uint16_t i = 0; i < table.u16(coverage + 2); ++i) {
            size_t range = coverage + 4 + 6 * static_cast<size_t>(i);
            uint16_t first = table.u16(range), last = table.u16(range + 2);
            if (last < first || table.u16(range + 4) != coveredGlyphs)
                return false;
            coveredGlyphs += static_cast<size_t>(last) - first + 1;
        }
    }
    if (coveredGlyphs != pairSetCount)
        return false;
    std::vector<uint16_t> pairSets;
    for (uint16_t i = 0; i < pairSetCount; ++i) {
        uint16_t offset = table.u16(subtable + 10 + 2 * static_cast<size_t>(i));
        size_t pairSet = subtable + offset;
        size_t pairSetSize = 2 + table.u16(pairSet) * recordSize;
        if (offset < arrayEnd || !table.has(pairSet, pairSetSize))
            return false;
        end = std::max(end, static_cast<size_t>(offset) + pairSetSize);
        if (std::find(pairSets.begin(), pairSets.end(), offset) != pairSets.end())
            continue;
        pairSets.push_back(offset);
        for (uint16_t record = 0; record < table.u16(pairSet); ++record) {
            size_t values = pairSet + 2 + record * recordSize + 2;
            for (size_t position : devices1) {
                uint16_t device = table.u16(values + position);
                if ((device && device < arrayEnd) || !extendPastDevice(table, subtable, device, &end))
                    return false;
            }
            for (size_t position : devices2) {
                uint16_t device = table.u16(values + size1 + position);
                if ((device && device < arrayEnd) || !extendPastDevice(table, subtable, device, &end))
                    return false;
            }
        }
    }
    if (!table.has(subtable, end) || end + 2 > 0xffff + static_cast<size_t>(1))
        return false;

    copy->assign(end + 2, 0);
    uint8_t *out = copy->data();
    memcpy(out, table.bytes + subtable, arrayEnd);
    memcpy(out + arrayEnd + 2, table.bytes + subtable + arrayEnd, end - arrayEnd);
    writeBE16(out + 2, static_cast<uint16_t>(coverageOffset + 2));
    writeBE16(out + 8, static_cast<uint16_t>(pairSetCount + 1));
    for (uint16_t i = 0; i < pairSetCount; ++i)
        writeBE16(out + 10 + 2 * static_cast<size_t>(i), static_cast<uint16_t>(table.u16(subtable + 10 + 2 * static_cast<size_t>(i)) + 2));
    writeBE16(out + arrayEnd, static_cast<uint16_t>(table.u16(subtable + arrayEnd - 2) + 2));
    for (uint16_t offset : pairSets) {
        size_t pairSet = subtable + offset;
        for (uint16_t record = 0; record < table.u16(pairSet); ++record) {
            size_t values = offset + 2 + record * recordSize + 2;
            auto shiftDevice = [&](size_t position) {
                uint16_t device = table.u16(subtable + position);
                if (device)
                    writeBE16(out + position + 2, static_cast<uint16_t>(device + 2));
            };
            for (size_t position : devices1)
                shiftDevice(values + position);
            for (size_t position : devices2)
                shiftDevice(values + size1 + position);
        }
    }
    return true;
}

// The PairPos format 2 subtable at `subtable`, byte for byte.
bool copyPairPosFormat2(const LayoutTableReader &table, size_t subtable, std::vector<uint8_t> *copy)
{
    uint16_t format1 = table.u16(subtable + 4), format2 = table.u16(subtable + 6);
    uint16_t class1Count = table.u16(subtable + 12), class2Count = table.u16(subtable + 14);
    if ((format1 | format2) > 0xff)
        return false;
    const size_t size1 = valueRecordSize(format1), size2 = valueRecordSize(format2);
    const size_t records = static_cast<size_t>(class1Count) * class2Count;
    size_t end = 16 + records * (size1 + size2);
    if (!table.has(subtable, end) || !extendPastCoverage(table, subtable, table.u16(subtable + 2), &end)
        || !extendPastClassDef(table, subtable, table.u16(subtable + 8), &end)
        || !extendPastClassDef(table, subtable, table.u16(subtable + 10), &end))
        return false;
    const std::vector<size_t> devices1 = deviceFieldPositions(format1), devices2 = deviceFieldPositions(format2);
    for (size_t record = 0; record < records; ++record) {
        size_t values = subtable + 16 + record * (size1 + size2);
        for (size_t position : devices1) {
            if (!extendPastDevice(table, subtable, table.u16(values + position), &end))
                return false;
        }
        for (size_t position : devices2) {
            if (!extendPastDevice(table, subtable, table.u16(values + size1 + position), &end))
                return false;
        }
    }
    if (!table.has(subtable, end))
        return false;
    copy->assign(table.bytes + subtable, table.bytes + subtable + end);
    return true;
}

// GPOS with every PairPos format 1 subtable's last PairSet reachable, or an empty vector when nothing
// changes.
std::vector<uint8_t> gposWithLastPairSetsReachable(const uint8_t *bytes, size_t length)
{
    const LayoutTableReader table { bytes, length };
    if (!table.has(0, 10) || table.u16(0) != 1)
        return { };
    const size_t lookupList = table.u16(8);
    const uint16_t lookupCount = lookupList ? table.u16(lookupList) : 0;
    if (!lookupCount || !table.has(lookupList, 2 + 2 * static_cast<size_t>(lookupCount)))
        return { };

    auto lookupAt = [&](uint16_t index) { return lookupList + table.u16(lookupList + 2 + 2 * static_cast<size_t>(index)); };
    auto subtableCount = [&](size_t lookup) { return table.has(lookup, 6) && table.has(lookup, 6 + 2 * static_cast<size_t>(table.u16(lookup + 4))) ? table.u16(lookup + 4) : 0; };
    auto subtableAt = [&](size_t lookup, uint16_t index) { return lookup + table.u16(lookup + 6 + 2 * static_cast<size_t>(index)); };
    auto extensionTarget = [&](size_t extension) -> size_t {
        if (!table.has(extension, 8) || table.u16(extension) != 1 || table.u16(extension + 2) != 2 || !table.u32(extension + 4))
            return 0;
        return extension + table.u32(extension + 4);
    };

    bool anyFormat1 = false;
    for (uint16_t i = 0; i < lookupCount && !anyFormat1; ++i) {
        size_t lookup = lookupAt(i);
        for (uint16_t s = 0; s < subtableCount(lookup) && !anyFormat1; ++s) {
            size_t subtable = table.u16(lookup) == 9 ? extensionTarget(subtableAt(lookup, s)) : table.u16(lookup) == 2 ? subtableAt(lookup, s) : 0;
            anyFormat1 = subtable && table.u16(subtable) == 1;
        }
    }
    if (!anyFormat1)
        return { };

    struct Copy {
        size_t subtable;
        std::vector<uint8_t> bytes;
        bool valid;
        size_t placed;
    };
    std::vector<Copy> copies;
    auto copyIndex = [&](size_t subtable) {
        for (size_t i = 0; i < copies.size(); ++i) {
            if (copies[i].subtable == subtable)
                return i;
        }
        Copy copy { subtable, { }, false, 0 };
        uint16_t format = table.u16(subtable);
        copy.valid = format == 1 ? copyPairPosFormat1WithExtraPairSet(table, subtable, &copy.bytes) : format == 2 && copyPairPosFormat2(table, subtable, &copy.bytes);
        copies.push_back(std::move(copy));
        return copies.size() - 1;
    };

    // The PairPos lookups with a format 1 subtable whose every subtable can take an Extension subtable
    // over its first 8 bytes.
    const GPOSOffsetTargets targets(table);
    std::vector<bool> converted(lookupCount, false);
    for (uint16_t i = 0; i < lookupCount; ++i) {
        size_t lookup = lookupAt(i);
        if (table.u16(lookup) != 2 || !subtableCount(lookup))
            continue;
        bool hasFormat1 = false;
        bool convertible = true;
        for (uint16_t s = 0; s < subtableCount(lookup) && convertible; ++s) {
            size_t subtable = subtableAt(lookup, s);
            hasFormat1 = hasFormat1 || table.u16(subtable) == 1;
            convertible = table.has(subtable, 8) && !targets.anyWithin(subtable, subtable + 8) && copies[copyIndex(subtable)].valid;
        }
        converted[i] = hasFormat1 && convertible;
    }
    // A subtable a lookup that stays as it is still reads directly is never written over.
    for (bool settled = false; !settled; ) {
        settled = true;
        for (uint16_t i = 0; i < lookupCount; ++i) {
            size_t lookup = lookupAt(i);
            if (table.u16(lookup) != 2 || converted[i])
                continue;
            for (uint16_t s = 0; s < subtableCount(lookup); ++s) {
                size_t shared = subtableAt(lookup, s);
                for (uint16_t j = 0; j < lookupCount; ++j) {
                    if (!converted[j])
                        continue;
                    for (uint16_t k = 0; k < subtableCount(lookupAt(j)); ++k) {
                        if (subtableAt(lookupAt(j), k) == shared) {
                            converted[j] = false;
                            settled = false;
                        }
                    }
                }
            }
        }
    }

    std::vector<uint8_t> out(bytes, bytes + length);
    auto place = [&](size_t index) -> size_t {
        Copy &copy = copies[index];
        if (copy.placed)
            return copy.placed;
        if (out.size() & 1)
            out.push_back(0);
        if (out.size() + copy.bytes.size() > maximumSanitizedFontSize)
            return 0;
        copy.placed = out.size();
        out.insert(out.end(), copy.bytes.begin(), copy.bytes.end());
        return copy.placed;
    };

    bool changed = false;
    std::vector<size_t> stubs;
    for (uint16_t i = 0; i < lookupCount; ++i) {
        if (!converted[i])
            continue;
        size_t lookup = lookupAt(i);
        for (uint16_t s = 0; s < subtableCount(lookup); ++s) {
            size_t subtable = subtableAt(lookup, s);
            size_t placed = place(copyIndex(subtable));
            if (!placed)
                return { };
            if (std::find(stubs.begin(), stubs.end(), subtable) != stubs.end())
                continue;
            writeBE16(out.data() + subtable, 1);
            writeBE16(out.data() + subtable + 2, 2);
            writeBE32(out.data() + subtable + 4, static_cast<uint32_t>(placed - subtable));
            stubs.push_back(subtable);
        }
        writeBE16(out.data() + lookup, 9);
        changed = true;
    }
    for (uint16_t i = 0; i < lookupCount; ++i) {
        size_t lookup = lookupAt(i);
        if (table.u16(lookup) != 9)
            continue;
        for (uint16_t s = 0; s < subtableCount(lookup); ++s) {
            size_t extension = subtableAt(lookup, s);
            size_t subtable = extensionTarget(extension);
            if (!subtable)
                continue;
            bool stubbed = std::find(stubs.begin(), stubs.end(), subtable) != stubs.end();
            if (table.u16(subtable) != 1 && !stubbed)
                continue;
            size_t index = copyIndex(subtable);
            if (!copies[index].valid) {
                if (stubbed)
                    return { };
                continue;
            }
            size_t placed = place(index);
            if (!placed)
                return { };
            writeBE32(out.data() + extension + 4, static_cast<uint32_t>(placed - extension));
            changed = true;
        }
    }
    if (!changed)
        return { };
    return out;
}

// The font is written again with GPOS rewritten as above; every table keeps its bytes and its order, and
// the tables after GPOS move with it.
CFDataRef accommodateLayoutReaders(CFDataRef font)
{
    const uint8_t *sfnt = CFDataGetBytePtr(font);
    size_t length = static_cast<size_t>(CFDataGetLength(font));
    if (length < 12)
        return font;
    unsigned tableCount = readBE16(sfnt + 4);
    const size_t directoryEnd = 12 + 16 * static_cast<size_t>(tableCount);
    if (directoryEnd > length)
        return font;
    auto recordAt = [sfnt](unsigned table) { return sfnt + 12 + 16 * static_cast<size_t>(table); };
    for (unsigned t = 0; t < tableCount; ++t) {
        const uint8_t *record = recordAt(t);
        if (static_cast<uint64_t>(readBE32(record + 8)) + readBE32(record + 12) > length)
            return font;
    }

    std::vector<std::vector<uint8_t>> replacements(tableCount);
    std::vector<bool> replaced(tableCount, false);
    bool changed = false;
    for (unsigned t = 0; t < tableCount; ++t) {
        const uint8_t *record = recordAt(t);
        const uint8_t *table = sfnt + readBE32(record + 8);
        const size_t tableLength = readBE32(record + 12);
        if (readBE32(record) == OTS_TAG('G', 'P', 'O', 'S'))
            replacements[t] = gposWithLastPairSetsReachable(table, tableLength);
        replaced[t] = !replacements[t].empty();
        changed = changed || replaced[t];
    }
    if (!changed)
        return font;

    std::vector<unsigned> order(tableCount);
    for (unsigned t = 0; t < tableCount; ++t)
        order[t] = t;
    std::sort(order.begin(), order.end(), [&recordAt](unsigned a, unsigned b) {
        return readBE32(recordAt(a) + 8) < readBE32(recordAt(b) + 8);
    });
    auto newLength = [&](unsigned table) {
        return replaced[table] ? static_cast<uint64_t>(replacements[table].size()) : static_cast<uint64_t>(readBE32(recordAt(table) + 12));
    };
    std::vector<size_t> placed(tableCount);
    size_t end = (directoryEnd + 3) & ~static_cast<size_t>(3);
    for (unsigned t : order) {
        const uint64_t padded = (newLength(t) + 3) & ~static_cast<uint64_t>(3);
        if (padded > maximumSanitizedFontSize - end)
            return font;
        placed[t] = end;
        end += static_cast<size_t>(padded);
    }

    CFMutableDataRef rewritten = CFDataCreateMutable(kCFAllocatorDefault, 0);
    if (!rewritten)
        return font;
    // CFDataSetLength zeroes what it adds, so every table's padding is zero.
    CFDataSetLength(rewritten, static_cast<CFIndex>(end));
    if (static_cast<size_t>(CFDataGetLength(rewritten)) != end) {
        CFRelease(rewritten);
        return font;
    }
    uint8_t *out = CFDataGetMutableBytePtr(rewritten);
    memcpy(out, sfnt, directoryEnd);
    for (unsigned t = 0; t < tableCount; ++t) {
        const uint8_t *record = recordAt(t);
        if (replaced[t])
            memcpy(out + placed[t], replacements[t].data(), replacements[t].size());
        else
            memcpy(out + placed[t], sfnt + readBE32(record + 8), readBE32(record + 12));
        const size_t recordOffset = 12 + 16 * static_cast<size_t>(t);
        writeBE32(out + recordOffset + 8, static_cast<uint32_t>(placed[t]));
        writeBE32(out + recordOffset + 12, static_cast<uint32_t>(newLength(t)));
    }
    CFRelease(font);
    return rewritten;
}

// A collection's fonts, each sanitized on its own from the original bytes and laid out as a TTC. OTS writes a
// whole collection with a font's tables taken from the first font that has a table of the same tag, and
// refuses a collection whose tables lie before a font's own directory, which is how it lays out the
// collections it writes; a font OTS reads alone is written alone. A font OTS refuses read alone is left
// out, and a collection with no font left is refused; WebCore finds a collection's font by its PostScript
// name. The TTC puts every font's directory before every table, as the collections this OS ships do, so
// OTS reads each font of it back, and writes a table the fonts share byte for byte once.
CFDataRef sanitizeCollection(CFDataRef data, uint32_t fontCount)
{
    const uint8_t *bytes = CFDataGetBytePtr(data);
    size_t length = static_cast<size_t>(CFDataGetLength(data));
    if (!fontCount || 12 + 4 * static_cast<uint64_t>(fontCount) > maximumSanitizedFontSize)
        return NULL;

    struct Table {
        const uint8_t *bytes;
        uint32_t tag;
        uint32_t length;
        size_t offset;
    };
    std::vector<CFDataRef> fonts;
    std::vector<Table> written;
    std::vector<std::vector<size_t>> tableOffsets;
    for (uint32_t i = 0; i < fontCount; ++i) {
        CFDataRef font = processFont(bytes, length, i, kAllPreservedMask);
        font = font ? validateSanitizedFont(font) : NULL;
        font = font ? accommodateLayoutReaders(font) : NULL;
        if (!font)
            continue;
        size_t fontLength = static_cast<size_t>(CFDataGetLength(font));
        const uint8_t *sfnt = CFDataGetBytePtr(font);
        if (fontLength < 12 || 12 + static_cast<uint64_t>(readBE16(sfnt + 4)) * 16 > fontLength) {
            CFRelease(font);
            continue;
        }
        fonts.push_back(font);
    }
    const size_t headerLength = 12 + 4 * fonts.size();
    size_t directoryEnd = headerLength;
    bool ok = !fonts.empty();
    for (size_t i = 0; ok && i < fonts.size(); ++i) {
        const uint64_t directoryLength = 12 + 16 * static_cast<uint64_t>(readBE16(CFDataGetBytePtr(fonts[i]) + 4));
        ok = directoryEnd + directoryLength <= maximumSanitizedFontSize;
        directoryEnd += static_cast<size_t>(directoryLength);
    }
    // Where each table lands: after every directory, 4-byte aligned, a table identical to one already
    // placed sharing its place.
    size_t end = (directoryEnd + 3) & ~static_cast<size_t>(3);
    for (size_t i = 0; ok && i < fonts.size(); ++i) {
        const uint8_t *sfnt = CFDataGetBytePtr(fonts[i]);
        size_t fontLength = static_cast<size_t>(CFDataGetLength(fonts[i]));
        unsigned tableCount = readBE16(sfnt + 4);
        std::vector<size_t> offsets;
        for (unsigned t = 0; ok && t < tableCount; ++t) {
            const uint8_t *record = sfnt + 12 + 16 * static_cast<size_t>(t);
            uint32_t tag = readBE32(record), offset = readBE32(record + 8), tableLength = readBE32(record + 12);
            if (static_cast<uint64_t>(offset) + tableLength > fontLength) {
                ok = false;
                break;
            }
            size_t placed = 0;
            bool shared = false;
            for (const Table &table : written) {
                if (table.tag == tag && table.length == tableLength && !memcmp(table.bytes, sfnt + offset, tableLength)) {
                    placed = table.offset;
                    shared = true;
                    break;
                }
            }
            if (!shared) {
                const size_t padded = (static_cast<size_t>(tableLength) + 3) & ~static_cast<size_t>(3);
                if (padded > maximumSanitizedFontSize - end) {
                    ok = false;
                    break;
                }
                placed = end;
                written.push_back(Table { sfnt + offset, tag, tableLength, placed });
                end += padded;
            }
            offsets.push_back(placed);
        }
        tableOffsets.push_back(offsets);
    }

    CFMutableDataRef collection = ok ? CFDataCreateMutable(kCFAllocatorDefault, 0) : NULL;
    if (collection) {
        CFDataSetLength(collection, static_cast<CFIndex>(end));
        ok = static_cast<size_t>(CFDataGetLength(collection)) == end;
    }
    if (collection && ok) {
        uint8_t *out = CFDataGetMutableBytePtr(collection);
        auto put32 = [out](size_t offset, uint32_t value) {
            out[offset] = static_cast<uint8_t>(value >> 24);
            out[offset + 1] = static_cast<uint8_t>(value >> 16);
            out[offset + 2] = static_cast<uint8_t>(value >> 8);
            out[offset + 3] = static_cast<uint8_t>(value);
        };
        put32(0, OTS_TAG('t', 't', 'c', 'f'));
        put32(4, 0x00010000);
        put32(8, static_cast<uint32_t>(fonts.size()));
        size_t directory = headerLength;
        for (size_t i = 0; i < fonts.size(); ++i) {
            const uint8_t *sfnt = CFDataGetBytePtr(fonts[i]);
            unsigned tableCount = readBE16(sfnt + 4);
            put32(12 + 4 * i, static_cast<uint32_t>(directory));
            memcpy(out + directory, sfnt, 12 + 16 * static_cast<size_t>(tableCount));
            for (unsigned t = 0; t < tableCount; ++t)
                put32(directory + 12 + 16 * static_cast<size_t>(t) + 8, static_cast<uint32_t>(tableOffsets[i][t]));
            directory += 12 + 16 * static_cast<size_t>(tableCount);
        }
        for (const Table &table : written)
            memcpy(out + table.offset, table.bytes, table.length);
    }
    for (CFDataRef font : fonts)
        CFRelease(font);
    if (!ok) {
        if (collection)
            CFRelease(collection);
        return NULL;
    }
    return collection;
}

} // namespace

// WOFF and WOFF2 wrap a sfnt, and OTS unwraps both as it reads them -- ots.cc inflates a WOFF through
// zlib and a WOFF2 through the WOFF2 decoder before it looks at a table -- so a container handed here
// is sanitized to the sfnt inside without a separate unwrap step.
extern "C" CFDataRef wk_ots_sanitize_font(CFDataRef data)
{
    if (!data)
        return NULL;

    CFIndex length = CFDataGetLength(data);
    if (length <= 0)
        return NULL;

    // OTS reads the file whole, carrying AAT tables into the sanitized sfnt for validation against its glyph
    // count and sibling tables. A file it refuses read whole is refused.
    CFDataRef pass1 = processFont(CFDataGetBytePtr(data), static_cast<size_t>(length),
        static_cast<uint32_t>(-1), kAllPreservedMask);
    if (!pass1)
        return NULL;

    CFDataRef sanitized;
    if (CFDataGetLength(pass1) >= 12 && readBE32(CFDataGetBytePtr(pass1)) == OTS_TAG('t', 't', 'c', 'f')) {
        uint32_t fontCount = readBE32(CFDataGetBytePtr(pass1) + 8);
        CFRelease(pass1);
        sanitized = sanitizeCollection(data, fontCount);
    } else {
        sanitized = validateSanitizedFont(pass1);
        if (sanitized)
            sanitized = accommodateLayoutReaders(sanitized);
    }
    if (!sanitized)
        return NULL;

    // The output is mutable; return an immutable copy so nothing can change the bytes after the mark,
    // and stamp it so the entry points do not sanitize it a second time.
    CFDataRef immutable = CFDataCreateCopy(kCFAllocatorDefault, sanitized);
    CFRelease(sanitized);
    if (!immutable)
        return NULL;
    objc_setAssociatedObject((id)(const void *)immutable, wk_ots_sanitized_key(), (id)kCFBooleanTrue, OBJC_ASSOCIATION_ASSIGN);
    return immutable;
}

extern "C" CFArrayRef wk_ots_copy_font_faces(CFDataRef sanitized)
{
    if (!wk_font_is_ots_sanitized(sanitized))
        return NULL;
    auto bytes = CFDataGetBytePtr(sanitized);
    auto length = static_cast<size_t>(CFDataGetLength(sanitized));
    if (length < 12 || readBE32(bytes) != OTS_TAG('t', 't', 'c', 'f')) {
        const void* values[] = { sanitized };
        return CFArrayCreate(kCFAllocatorDefault, values, 1, &kCFTypeArrayCallBacks);
    }
    uint32_t count = readBE32(bytes + 8);
    if (12 + static_cast<uint64_t>(count) * 4 > length)
        return NULL;
    CFMutableArrayRef fonts = CFArrayCreateMutable(kCFAllocatorDefault, count, &kCFTypeArrayCallBacks);
    if (!fonts)
        return NULL;
    // A font OTS does not read back is left out, as the sanitizer leaves out one it refuses.
    for (uint32_t i = 0; i < count; ++i) {
        CFDataRef face = processFont(bytes, length, i, kAllPreservedMask);
        CFDataRef immutable = face ? CFDataCreateCopy(kCFAllocatorDefault, face) : NULL;
        if (face)
            CFRelease(face);
        if (!immutable)
            continue;
        objc_setAssociatedObject((id)(const void*)immutable, wk_ots_sanitized_key(), (id)kCFBooleanTrue, OBJC_ASSOCIATION_ASSIGN);
        CFArrayAppendValue(fonts, immutable);
        CFRelease(immutable);
    }
    if (!CFArrayGetCount(fonts)) {
        CFRelease(fonts);
        return NULL;
    }
    return fonts;
}
