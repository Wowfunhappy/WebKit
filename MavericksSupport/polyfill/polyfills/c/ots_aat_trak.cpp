// 'trak' tracking. This OS reads, per direction, a track count and size count, then a Fixed size array
// and a per-track value array; it bounds each of those against the table. Every offset and count it
// trusts is reproduced here so a value read never leaves the table.
#include "ots_aat.h"

namespace {

// A direction's TrackData: trackCount, sizeCount, sizeTableOffset, then trackCount entries of 8 bytes
// each (Fixed track, u16 nameIndex, u16 valuesOffset), a sizeCount Fixed size array, and per-track a
// sizeCount i16 value array. dirOffset 0 means the direction is absent.
bool validateDirection(const uint8_t *table, size_t length, uint32_t dirOffset)
{
    if (!dirOffset)
        return true;
    if (dirOffset > length)
        return false;

    uint16_t trackCount = 0, sizeCount = 0;
    uint32_t sizeTableOffset = 0;
    if (!wk_aat_read16(table, length, dirOffset, &trackCount)
        || !wk_aat_read16(table, length, dirOffset + 2, &sizeCount)
        || !wk_aat_read32(table, length, dirOffset + 4, &sizeTableOffset))
        return false;

    uint64_t entries = static_cast<uint64_t>(dirOffset) + 8;
    if (entries + static_cast<uint64_t>(trackCount) * 8 > length)
        return false;
    if (static_cast<uint64_t>(sizeTableOffset) + static_cast<uint64_t>(sizeCount) * 4 > length)
        return false;

    for (uint64_t t = 0; t < trackCount; ++t) {
        uint16_t valuesOffset = 0;
        if (!wk_aat_read16(table, length, static_cast<size_t>(entries + t * 8 + 6), &valuesOffset))
            return false;
        if (static_cast<uint64_t>(valuesOffset) + static_cast<uint64_t>(sizeCount) * 2 > length)
            return false;
    }
    return true;
}

} // namespace

bool wk_aat_validate_trak(const uint8_t *table, size_t length, const wk_aat_font_facts &)
{
    uint32_t version = 0;
    uint16_t format = 0, horizOffset = 0, vertOffset = 0;
    // version(Fixed) == 0x00010000, format(u16), horizOffset(u16), vertOffset(u16), reserved(u16).
    if (!wk_aat_read32(table, length, 0, &version) || version != 0x00010000u)
        return false;
    if (!wk_aat_read16(table, length, 4, &format)
        || !wk_aat_read16(table, length, 6, &horizOffset)
        || !wk_aat_read16(table, length, 8, &vertOffset))
        return false;

    return validateDirection(table, length, horizOffset) && validateDirection(table, length, vertOffset);
}
