// Validator for the extended kerning table 'kerx' read by TAATKerxEngine.
#include "ots_aat.h"
#include "ots_aat_lookup.h"

namespace {

const uint64_t kMaxTableWork = 4u * 1024u * 1024u;
const uint32_t kAnkrTag = 0x616e6b72;

bool addWork(uint64_t amount, uint64_t &work)
{
    if (amount > kMaxTableWork - work)
        return false;
    work += amount;
    return true;
}

bool read8(const uint8_t *table, size_t length, uint64_t offset, uint8_t &value)
{
    uint16_t pair = 0;
    if (offset < length && length - offset >= 2
        && wk_aat_read16(table, length, static_cast<size_t>(offset), &pair)) {
        value = static_cast<uint8_t>(pair >> 8);
        return true;
    }
    if (!offset || !wk_aat_read16(table, length, static_cast<size_t>(offset - 1), &pair))
        return false;
    value = static_cast<uint8_t>(pair);
    return true;
}

uint64_t sectionEnd(uint64_t start, const uint64_t *sections, size_t count, uint64_t end)
{
    uint64_t result = end;
    for (size_t i = 0; i < count; ++i) {
        if (sections[i] > start && sections[i] < result)
            result = sections[i];
    }
    return result;
}

struct LookupValues {
    uint16_t maximum;
    bool any;
};

bool validateLookup16(const uint8_t *table, uint64_t lookupOffset, uint64_t end, uint32_t numGlyphs,
    uint64_t &work, uint32_t valueLimit, LookupValues &values)
{
    if (lookupOffset > end)
        return false;
    const uint8_t *lookup = table + lookupOffset;
    size_t lookupLength = static_cast<size_t>(end - lookupOffset);
    values.maximum = 0;
    values.any = false;
    return wk_aat_validate_lookup(lookup, lookupLength, 0, 2, numGlyphs,
        [&](const wk_aat_lookup_entry &entry) {
            if (!addWork(1, work))
                return false;
            if (entry.glyph >= numGlyphs)
                return true;
            uint16_t value = 0;
            if (!wk_aat_read16(lookup, lookupLength, entry.valueOffset, &value) || value >= valueLimit)
                return false;
            if (!values.any || value > values.maximum)
                values.maximum = value;
            values.any = true;
            return true;
        });
}

bool ankrPointLimit(const wk_aat_font_facts &facts, uint64_t &work, uint32_t &maximumPoints)
{
    maximumPoints = 0;
    const uint8_t *ankr = 0;
    size_t ankrLength = 0;
    if (!facts.findTable || !facts.findTable(facts, kAnkrTag, &ankr, &ankrLength))
        return true;

    uint16_t version = 0;
    uint32_t lookupOffset = 0, glyphDataOffset = 0;
    if (!wk_aat_read16(ankr, ankrLength, 0, &version) || version
        || !wk_aat_read32(ankr, ankrLength, 4, &lookupOffset)
        || !wk_aat_read32(ankr, ankrLength, 8, &glyphDataOffset)
        || lookupOffset > ankrLength || glyphDataOffset > ankrLength)
        return false;

    const uint8_t *lookup = ankr + lookupOffset;
    size_t lookupLength = ankrLength - lookupOffset;
    return wk_aat_validate_lookup(lookup, lookupLength, 0, 2, facts.numGlyphs,
        [&](const wk_aat_lookup_entry &entry) {
            if (!addWork(1, work))
                return false;
            if (entry.glyph >= facts.numGlyphs)
                return true;
            uint16_t pointOffset = 0;
            if (!wk_aat_read16(lookup, lookupLength, entry.valueOffset, &pointOffset))
                return false;
            uint64_t points = static_cast<uint64_t>(glyphDataOffset) + pointOffset;
            uint32_t count = 0;
            if (points > ankrLength || !wk_aat_read32(ankr, ankrLength, static_cast<size_t>(points), &count))
                return false;
            uint64_t available = (ankrLength - (points + 4)) / 4;
            if (count < available)
                available = count;
            if (available > maximumPoints)
                maximumPoints = static_cast<uint32_t>(available);
            return true;
        });
}

bool validateOrderedList(const uint8_t *table, size_t length, uint64_t dataOffset, uint64_t dataEnd,
    uint64_t &work)
{
    uint32_t pairCount = 0;
    if (!wk_aat_read32(table, length, static_cast<size_t>(dataOffset), &pairCount))
        return false;
    uint64_t records = dataOffset + 16;
    if (records > dataEnd || static_cast<uint64_t>(pairCount) * 6 > dataEnd - records)
        return false;
    return addWork(pairCount, work);
}

bool validateOffsetArray(const uint8_t *table, size_t length, uint64_t subtableOffset,
    uint64_t dataOffset, uint64_t dataEnd, uint32_t numGlyphs, uint64_t &work)
{
    uint32_t leftOffset = 0, rightOffset = 0, arrayOffset = 0;
    if (!wk_aat_read32(table, length, static_cast<size_t>(dataOffset + 4), &leftOffset)
        || !wk_aat_read32(table, length, static_cast<size_t>(dataOffset + 8), &rightOffset)
        || !wk_aat_read32(table, length, static_cast<size_t>(dataOffset + 12), &arrayOffset))
        return false;

    uint64_t left = subtableOffset + leftOffset;
    uint64_t right = subtableOffset + rightOffset;
    uint64_t array = subtableOffset + arrayOffset;
    if (left < dataOffset || right < dataOffset || array < dataOffset || array > dataEnd)
        return false;

    LookupValues leftValues, rightValues;
    if (!validateLookup16(table, left, dataEnd, numGlyphs, work, 0x10000, leftValues)
        || !validateLookup16(table, right, dataEnd, numGlyphs, work, 0x10000, rightValues))
        return false;
    uint64_t largest = static_cast<uint64_t>(leftValues.maximum) + rightValues.maximum;
    return largest <= dataEnd - array && 2 <= dataEnd - array - largest;
}

bool validatePrivateIndexArray(const uint8_t *table, size_t length, uint64_t dataOffset,
    uint64_t dataEnd, uint64_t &work)
{
    uint16_t glyphCount = 0, valueCount = 0, leftCount = 0;
    uint8_t rightCount = 0, flags = 0;
    if (!wk_aat_read16(table, length, static_cast<size_t>(dataOffset), &glyphCount)
        || !wk_aat_read16(table, length, static_cast<size_t>(dataOffset + 2), &valueCount)
        || !wk_aat_read16(table, length, static_cast<size_t>(dataOffset + 4), &leftCount)
        || !read8(table, length, dataOffset + 6, rightCount)
        || !read8(table, length, dataOffset + 7, flags) || flags)
        return false;

    uint64_t values = dataOffset + 10;
    uint64_t left = values + static_cast<uint64_t>(valueCount) * 2;
    uint64_t right = left + static_cast<uint64_t>(glyphCount) * 2;
    uint64_t indices = right + static_cast<uint64_t>(glyphCount) * 2;
    uint64_t indexCount = static_cast<uint64_t>(leftCount) * rightCount;
    if (values > dataEnd || left > dataEnd || right > dataEnd || indices > dataEnd
        || indexCount * 2 > dataEnd - indices
        || !addWork(static_cast<uint64_t>(glyphCount) * 2 + indexCount, work))
        return false;

    for (uint64_t i = 0; i < glyphCount; ++i) {
        uint16_t leftClass = 0, rightClass = 0;
        if (!wk_aat_read16(table, length, static_cast<size_t>(left + i * 2), &leftClass)
            || !wk_aat_read16(table, length, static_cast<size_t>(right + i * 2), &rightClass)
            || leftClass >= leftCount || rightClass >= rightCount)
            return false;
    }
    for (uint64_t i = 0; i < indexCount; ++i) {
        uint16_t valueIndex = 0;
        if (!wk_aat_read16(table, length, static_cast<size_t>(indices + i * 2), &valueIndex)
            || valueIndex >= valueCount)
            return false;
    }
    return true;
}

bool validateStateTable(const uint8_t *table, size_t length, uint64_t dataOffset, uint64_t dataEnd,
    uint32_t format, const wk_aat_font_facts &facts, uint64_t &work)
{
    uint32_t nClasses = 0, classOffset = 0, stateOffset = 0, entryOffset = 0, extra = 0;
    if (!wk_aat_read32(table, length, static_cast<size_t>(dataOffset), &nClasses)
        || !wk_aat_read32(table, length, static_cast<size_t>(dataOffset + 4), &classOffset)
        || !wk_aat_read32(table, length, static_cast<size_t>(dataOffset + 8), &stateOffset)
        || !wk_aat_read32(table, length, static_cast<size_t>(dataOffset + 12), &entryOffset)
        || !wk_aat_read32(table, length, static_cast<size_t>(dataOffset + 16), &extra)
        || nClasses < 4 || nClasses > 0xFFFF)
        return false;

    uint64_t classBase = dataOffset + classOffset;
    uint64_t stateBase = dataOffset + stateOffset;
    uint64_t entryBase = dataOffset + entryOffset;
    uint32_t actionType = extra >> 30;
    uint64_t finalBase = dataOffset + (format == 1 ? extra : extra & 0x00FFFFFFu);
    if (classBase < dataOffset + 20 || stateBase < dataOffset + 20 || entryBase < dataOffset + 20
        || classBase > dataEnd || stateBase > dataEnd || entryBase > dataEnd)
        return false;
    if (format == 1 && (finalBase < dataOffset + 20 || finalBase > dataEnd))
        return false;
    if (format == 4 && actionType < 3 && (finalBase < dataOffset + 20 || finalBase > dataEnd))
        return false;

    LookupValues classes;
    if (!validateLookup16(table, classBase, dataEnd, facts.numGlyphs, work, nClasses, classes))
        return false;

    uint64_t sections[4] = { classBase, stateBase, entryBase, finalBase };
    uint64_t stateEnd = sectionEnd(stateBase, sections, 4, dataEnd);
    uint64_t rowBytes = static_cast<uint64_t>(nClasses) * 2;
    uint64_t stateCount = (stateEnd - stateBase) / rowBytes;
    uint64_t entryEnd = sectionEnd(entryBase, sections, 4, dataEnd);
    uint64_t entryCount = (entryEnd - entryBase) / 6;
    uint64_t cells = stateCount * nClasses;
    if (stateCount < 2 || !entryCount || !addWork(cells + entryCount, work))
        return false;

    for (uint64_t i = 0; i < cells; ++i) {
        uint16_t entryIndex = 0;
        if (!wk_aat_read16(table, length, static_cast<size_t>(stateBase + i * 2), &entryIndex)
            || entryIndex >= entryCount)
            return false;
    }

    uint32_t maximumAnkrPoints = 0;
    bool haveAnkrLimit = false;
    for (uint64_t i = 0; i < entryCount; ++i) {
        uint64_t entry = entryBase + i * 6;
        uint16_t newState = 0, action = 0;
        if (!wk_aat_read16(table, length, static_cast<size_t>(entry), &newState)
            || !wk_aat_read16(table, length, static_cast<size_t>(entry + 4), &action)
            || newState >= stateCount)
            return false;
        if (action == 0xFFFF)
            continue;
        if (format == 1) {
            uint64_t value = finalBase + static_cast<uint64_t>(action) * 2;
            uint16_t unused = 0;
            if (value > dataEnd || !wk_aat_read16(table, static_cast<size_t>(dataEnd),
                    static_cast<size_t>(value), &unused))
                return false;
            continue;
        }
        if (actionType == 3)
            continue;
        uint64_t actionSize = actionType == 2 ? 8 : 4;
        uint64_t actionRecord = finalBase + static_cast<uint64_t>(action) * actionSize;
        uint16_t first = 0, second = 0;
        if (actionRecord > dataEnd || actionSize > dataEnd - actionRecord
            || !wk_aat_read16(table, length, static_cast<size_t>(actionRecord), &first)
            || !wk_aat_read16(table, length, static_cast<size_t>(actionRecord + 2), &second))
            return false;
        if (actionType == 1) {
            if (!haveAnkrLimit) {
                if (!ankrPointLimit(facts, work, maximumAnkrPoints))
                    return false;
                haveAnkrLimit = true;
            }
            const uint8_t *ankr = 0;
            size_t ankrLength = 0;
            bool hasAnkr = facts.findTable && facts.findTable(facts, kAnkrTag, &ankr, &ankrLength);
            if (hasAnkr && (first >= maximumAnkrPoints || second >= maximumAnkrPoints))
                return false;
        }
    }
    return true;
}

bool validateSubtable(const uint8_t *table, size_t length, uint64_t subtableOffset,
    uint64_t dataOffset, uint64_t dataEnd, uint32_t format, const wk_aat_font_facts &facts,
    uint64_t &work)
{
    switch (format) {
    case 0:
        return validateOrderedList(table, length, dataOffset, dataEnd, work);
    case 1:
    case 4:
        return validateStateTable(table, length, dataOffset, dataEnd, format, facts, work);
    case 2:
        return validateOffsetArray(table, length, subtableOffset, dataOffset, dataEnd,
            facts.numGlyphs, work);
    case 3:
        return validatePrivateIndexArray(table, length, dataOffset, dataEnd, work);
    default:
        return true;
    }
}

} // namespace

bool wk_aat_validate_kerx(const uint8_t *table, size_t length, const wk_aat_font_facts &facts)
{
    uint32_t version = 0, tableCount = 0;
    if (!wk_aat_read32(table, length, 0, &version) || version != 0x00020000u
        || !wk_aat_read32(table, length, 4, &tableCount) || length < 8
        || static_cast<uint64_t>(tableCount) * 34 > length - 8)
        return false;

    uint64_t cursor = 8;
    uint64_t work = 0;
    if (!addWork(tableCount, work))
        return false;
    for (uint32_t i = 0; i < tableCount; ++i) {
        uint32_t subtableLength = 0, coverage = 0, tupleCount = 0;
        if (!wk_aat_read32(table, length, static_cast<size_t>(cursor), &subtableLength)
            || !wk_aat_read32(table, length, static_cast<size_t>(cursor + 4), &coverage)
            || !wk_aat_read32(table, length, static_cast<size_t>(cursor + 8), &tupleCount)
            || subtableLength < 34 || subtableLength > length - cursor)
            return false;
        uint64_t next = cursor + subtableLength;
        if (!validateSubtable(table, length, cursor, cursor + 12, next, coverage & 0xFFu,
                facts, work))
            return false;
        cursor = next;
        (void)tupleCount;
    }
    return true;
}
