// Validator for the Apple 1.0 kerning table read by TAATKernEngine.
#include "ots_aat.h"

namespace {

const uint64_t kMaxTableWork = 4u * 1024u * 1024u;

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

bool validateOrderedList(const uint8_t *table, size_t length, uint64_t dataOffset, uint64_t dataEnd,
    uint64_t &work)
{
    uint16_t pairCount = 0;
    if (!wk_aat_read16(table, length, static_cast<size_t>(dataOffset), &pairCount))
        return false;
    uint64_t records = dataOffset + 8;
    if (records > dataEnd || static_cast<uint64_t>(pairCount) * 6 > dataEnd - records)
        return false;
    return addWork(pairCount, work);
}

bool validateStateTable(const uint8_t *table, size_t length, uint64_t dataOffset, uint64_t dataEnd,
    uint64_t &work)
{
    uint16_t stateSize = 0, classOffset = 0, stateOffset = 0, entryOffset = 0, valueOffset = 0;
    if (!wk_aat_read16(table, length, static_cast<size_t>(dataOffset), &stateSize)
        || !wk_aat_read16(table, length, static_cast<size_t>(dataOffset + 2), &classOffset)
        || !wk_aat_read16(table, length, static_cast<size_t>(dataOffset + 4), &stateOffset)
        || !wk_aat_read16(table, length, static_cast<size_t>(dataOffset + 6), &entryOffset)
        || !wk_aat_read16(table, length, static_cast<size_t>(dataOffset + 8), &valueOffset)
        || stateSize < 4 || stateSize > 0x100)
        return false;

    uint64_t classBase = dataOffset + classOffset;
    uint64_t stateBase = dataOffset + stateOffset;
    uint64_t entryBase = dataOffset + entryOffset;
    uint64_t valueBase = dataOffset + valueOffset;
    if (classBase < dataOffset + 10 || stateBase < dataOffset + 10
        || entryBase < dataOffset + 10 || valueBase < dataOffset + 10
        || classBase > dataEnd || stateBase > dataEnd || entryBase > dataEnd || valueBase > dataEnd)
        return false;

    uint64_t sections[4] = { classBase, stateBase, entryBase, valueBase };
    uint64_t classEnd = sectionEnd(classBase, sections, 4, dataEnd);
    uint16_t firstGlyph = 0, glyphCount = 0;
    if (!wk_aat_read16(table, length, static_cast<size_t>(classBase), &firstGlyph)
        || !wk_aat_read16(table, length, static_cast<size_t>(classBase + 2), &glyphCount)
        || classEnd - classBase < 4 || glyphCount > classEnd - classBase - 4
        || !addWork(glyphCount, work))
        return false;
    for (uint64_t i = 0; i < glyphCount; ++i) {
        uint8_t glyphClass = 0;
        if (!read8(table, static_cast<size_t>(classEnd), classBase + 4 + i, glyphClass)
            || glyphClass >= stateSize)
            return false;
    }

    uint64_t stateEnd = sectionEnd(stateBase, sections, 4, dataEnd);
    uint64_t stateCount = (stateEnd - stateBase) / stateSize;
    uint64_t cells = stateCount * stateSize;
    uint64_t entryEnd = sectionEnd(entryBase, sections, 4, dataEnd);
    uint64_t entryCount = (entryEnd - entryBase) / 4;
    if (stateCount < 2 || !entryCount || !addWork(cells + entryCount, work))
        return false;

    for (uint64_t i = 0; i < cells; ++i) {
        uint8_t entryIndex = 0;
        if (!read8(table, static_cast<size_t>(stateEnd), stateBase + i, entryIndex)
            || entryIndex >= entryCount)
            return false;
    }
    for (uint64_t i = 0; i < entryCount; ++i) {
        uint64_t entry = entryBase + i * 4;
        uint16_t newState = 0, flags = 0;
        if (!wk_aat_read16(table, length, static_cast<size_t>(entry), &newState)
            || !wk_aat_read16(table, length, static_cast<size_t>(entry + 2), &flags)
            || newState < stateOffset || (newState - stateOffset) % stateSize
            || (newState - stateOffset) / stateSize >= stateCount)
            return false;
        uint64_t actionOffset = flags & 0x3FFFu;
        if (actionOffset) {
            uint16_t unused = 0;
            uint64_t action = dataOffset + actionOffset;
            if (action > dataEnd || !wk_aat_read16(table, static_cast<size_t>(dataEnd),
                    static_cast<size_t>(action), &unused))
                return false;
        }
    }
    (void)firstGlyph;
    return true;
}

struct ClassOffsets {
    uint16_t minimum;
    uint16_t maximum;
};

bool validateClassOffsets(const uint8_t *table, size_t length, uint64_t classBase, uint64_t classEnd,
    uint64_t &work, ClassOffsets &offsets)
{
    uint16_t firstGlyph = 0, glyphCount = 0;
    if (!wk_aat_read16(table, length, static_cast<size_t>(classBase), &firstGlyph)
        || !wk_aat_read16(table, length, static_cast<size_t>(classBase + 2), &glyphCount)
        || classEnd - classBase < 4
        || static_cast<uint64_t>(glyphCount) * 2 > classEnd - classBase - 4
        || !addWork(glyphCount, work))
        return false;
    offsets.minimum = 0xFFFF;
    offsets.maximum = 0;
    for (uint64_t i = 0; i < glyphCount; ++i) {
        uint16_t value = 0;
        if (!wk_aat_read16(table, length, static_cast<size_t>(classBase + 4 + i * 2), &value))
            return false;
        if (value < offsets.minimum)
            offsets.minimum = value;
        if (value > offsets.maximum)
            offsets.maximum = value;
    }
    (void)firstGlyph;
    return true;
}

bool validateOffsetArray(const uint8_t *table, size_t length, uint64_t subtableOffset,
    uint64_t dataOffset, uint64_t dataEnd, uint64_t &work)
{
    uint16_t leftOffset = 0, rightOffset = 0, arrayOffset = 0;
    if (!wk_aat_read16(table, length, static_cast<size_t>(dataOffset + 2), &leftOffset)
        || !wk_aat_read16(table, length, static_cast<size_t>(dataOffset + 4), &rightOffset)
        || !wk_aat_read16(table, length, static_cast<size_t>(dataOffset + 6), &arrayOffset))
        return false;
    uint64_t left = subtableOffset + leftOffset;
    uint64_t right = subtableOffset + rightOffset;
    if (left < dataOffset + 8 || right < dataOffset + 8 || left > dataEnd || right > dataEnd)
        return false;
    uint64_t array = subtableOffset + arrayOffset;
    uint64_t sections[3] = { left, right, array };
    ClassOffsets leftValues, rightValues;
    if (!validateClassOffsets(table, length, left, sectionEnd(left, sections, 3, dataEnd), work, leftValues)
        || !validateClassOffsets(table, length, right, sectionEnd(right, sections, 3, dataEnd), work, rightValues))
        return false;

    uint64_t smallestLeft = arrayOffset;
    uint64_t largestLeft = arrayOffset;
    if (leftValues.minimum != 0xFFFF && leftValues.minimum < smallestLeft)
        smallestLeft = leftValues.minimum;
    if (leftValues.maximum > largestLeft)
        largestLeft = leftValues.maximum;
    uint64_t largestRight = rightValues.maximum;
    uint64_t smallest = smallestLeft;
    uint64_t largest = largestLeft + largestRight;
    return smallest >= 8 && largest <= dataEnd - subtableOffset
        && 2 <= dataEnd - subtableOffset - largest;
}

bool validateIndexArray(const uint8_t *table, size_t length, uint64_t dataOffset,
    uint64_t dataEnd, uint64_t &work)
{
    uint16_t glyphCount = 0;
    uint8_t valueCount = 0, leftCount = 0, rightCount = 0, flags = 0;
    if (!wk_aat_read16(table, length, static_cast<size_t>(dataOffset), &glyphCount)
        || !read8(table, length, dataOffset + 2, valueCount)
        || !read8(table, length, dataOffset + 3, leftCount)
        || !read8(table, length, dataOffset + 4, rightCount)
        || !read8(table, length, dataOffset + 5, flags))
        return false;

    uint64_t values = dataOffset + 6;
    uint64_t left = values + static_cast<uint64_t>(valueCount) * 2;
    uint64_t right = left + glyphCount;
    uint64_t indices = right + glyphCount;
    uint64_t indexCount = static_cast<uint64_t>(leftCount) * rightCount;
    if (values > dataEnd || left > dataEnd || right > dataEnd || indices > dataEnd
        || indexCount > dataEnd - indices
        || !addWork(static_cast<uint64_t>(glyphCount) * 2 + indexCount, work))
        return false;

    for (uint64_t i = 0; i < glyphCount; ++i) {
        uint8_t leftClass = 0, rightClass = 0;
        if (!read8(table, static_cast<size_t>(dataEnd), left + i, leftClass)
            || !read8(table, static_cast<size_t>(dataEnd), right + i, rightClass)
            || leftClass >= leftCount || rightClass >= rightCount)
            return false;
    }
    for (uint64_t i = 0; i < indexCount; ++i) {
        uint8_t valueIndex = 0;
        if (!read8(table, static_cast<size_t>(dataEnd), indices + i, valueIndex)
            || valueIndex >= valueCount)
            return false;
    }
    (void)flags;
    return true;
}

bool validateSubtable(const uint8_t *table, size_t length, uint64_t subtableOffset,
    uint64_t dataOffset, uint64_t dataEnd, uint32_t format, uint64_t &work)
{
    switch (format) {
    case 0:
        return validateOrderedList(table, length, dataOffset, dataEnd, work);
    case 1:
        return validateStateTable(table, length, dataOffset, dataEnd, work);
    case 2:
        return validateOffsetArray(table, length, subtableOffset, dataOffset, dataEnd, work);
    case 3:
        return validateIndexArray(table, length, dataOffset, dataEnd, work);
    default:
        return true;
    }
}

} // namespace

bool wk_aat_validate_kern(const uint8_t *table, size_t length, const wk_aat_font_facts &facts)
{
    uint32_t version = 0, tableCount = 0;
    if (!wk_aat_read32(table, length, 0, &version) || version != 0x00010000u
        || !wk_aat_read32(table, length, 4, &tableCount) || length < 8
        || static_cast<uint64_t>(tableCount) * 20 > length - 8)
        return false;

    uint64_t cursor = 8;
    uint64_t work = 0;
    if (!addWork(tableCount, work))
        return false;
    for (uint32_t i = 0; i < tableCount; ++i) {
        uint32_t subtableLength = 0;
        uint16_t coverage = 0, tupleIndex = 0;
        if (!wk_aat_read32(table, length, static_cast<size_t>(cursor), &subtableLength)
            || !wk_aat_read16(table, length, static_cast<size_t>(cursor + 4), &coverage)
            || !wk_aat_read16(table, length, static_cast<size_t>(cursor + 6), &tupleIndex)
            || subtableLength < 20 || subtableLength > 0x7FFFFFFFu
            || subtableLength > length - cursor)
            return false;
        uint64_t next = cursor + subtableLength;
        if (!validateSubtable(table, length, cursor, cursor + 8, next, coverage & 0xFFu, work))
            return false;
        cursor = next;
        (void)tupleIndex;
    }
    (void)facts;
    return true;
}
