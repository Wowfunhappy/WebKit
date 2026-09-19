// Validator for the AAT 'feat' feature-name table.
//
// CTFontCopyFeatures parses this table in TFontFeatures::TFontFeatures. From the table base it reads
// featureNameCount at offset 4 and walks that many 12-byte feature records at offset 12, then for each
// record follows its settingTable offset (uint32 at record+4) and reads nSettings (uint16 at record+2)
// four-byte setting records there. None of featureNameCount, the settingTable offset or nSettings is
// bounded against the table length, so an out-of-range value walks off the end. This reproduces those
// reads and keeps the table only when every one stays inside it.
#include "ots_aat.h"

bool wk_aat_validate_feat(const uint8_t *table, size_t length, const wk_aat_font_facts &)
{
    uint32_t version;
    if (!wk_aat_read32(table, length, 0, &version))
        return false;
    // TFontFeatures reads the record array only for version 1.0 (or 1.1); any other value leaves the
    // table unparsed, so nothing is read out of bounds and it is kept as inert.
    if (version != 0x00010000u && version != 0x00010001u)
        return true;

    uint16_t featureNameCount;
    if (!wk_aat_read16(table, length, 4, &featureNameCount))
        return false;

    const uint64_t recordsBase = 12;
    if (recordsBase + static_cast<uint64_t>(featureNameCount) * 12 > length)
        return false;

    for (uint32_t i = 0; i < featureNameCount; ++i) {
        size_t record = static_cast<size_t>(recordsBase + static_cast<uint64_t>(i) * 12);
        uint16_t nSettings;
        uint32_t settingTableOffset;
        if (!wk_aat_read16(table, length, record + 2, &nSettings))
            return false;
        if (!wk_aat_read32(table, length, record + 4, &settingTableOffset))
            return false;
        if (nSettings) {
            uint64_t settingsEnd = static_cast<uint64_t>(settingTableOffset)
                + static_cast<uint64_t>(nSettings) * 4;
            if (settingTableOffset > length || settingsEnd > length)
                return false;
        }
    }
    return true;
}
