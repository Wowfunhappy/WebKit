/*
 * Copyright (C) 2026 Wowfunhappy. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Software variable-font instancer for legacy (10.9) CoreText. See the header for why this
// exists. The implementation follows the OpenType 1.8 fvar/avar/gvar specification: normalize
// the pinned axis coordinates, compute each tuple's scalar, apply the interpolated per-point
// deltas (including IUP inference for unreferenced points and the four phantom points) to every
// glyph, then reassemble a static sfnt with rebuilt glyf/loca/hmtx/head/hhea and the variation
// tables dropped. A font whose outlines are a CFF2 table is cut the same way into one with a CFF
// table (see the CFF2 section).
//
// Everything but the C entry points at the bottom has internal linkage: this object is
// force-loaded into every shipped WebKit binary as part of libpolyfill.a, and nothing outside
// CoreText.c has any business calling into it.
#include "VariableFontInstancer.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <map>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace {

struct LegacyVariableFontAxis {
    uint32_t tag { 0 };
    double minimumValue { 0 };
    double defaultValue { 0 };
    double maximumValue { 0 };
    int32_t fixedMinimumValue { 0 };
    int32_t fixedDefaultValue { 0 };
    int32_t fixedMaximumValue { 0 };
    uint16_t nameID { 0 };
};

constexpr uint32_t tagFor(char a, char b, char c, char d)
{
    return (uint32_t(uint8_t(a)) << 24) | (uint32_t(uint8_t(b)) << 16) | (uint32_t(uint8_t(c)) << 8) | uint32_t(uint8_t(d));
}

// Hard ceiling on any sfnt this file assembles and on the cumulative re-encoded glyf
// bytes. This code runs on untrusted web-font data in the WebContent process: table
// records may overlap (so per-record-validated lengths can sum to tens of GB), and
// glyf re-encoding can amplify a small hostile glyph by orders of magnitude. All size
// accounting is 64-bit and anything past this cap is rejected. Real fonts — including
// full CJK families — stay well under it.
constexpr uint64_t maximumAssembledFontSize = 256 * 1024 * 1024;

constexpr uint32_t fvarTag = tagFor('f', 'v', 'a', 'r');
constexpr uint32_t avarTag = tagFor('a', 'v', 'a', 'r');
constexpr uint32_t gvarTag = tagFor('g', 'v', 'a', 'r');
constexpr uint32_t glyfTag = tagFor('g', 'l', 'y', 'f');
constexpr uint32_t locaTag = tagFor('l', 'o', 'c', 'a');
constexpr uint32_t headTag = tagFor('h', 'e', 'a', 'd');
constexpr uint32_t hheaTag = tagFor('h', 'h', 'e', 'a');
constexpr uint32_t hmtxTag = tagFor('h', 'm', 't', 'x');
constexpr uint32_t maxpTag = tagFor('m', 'a', 'x', 'p');

static bool isVariationTableTag(uint32_t tag)
{
    switch (tag) {
    case 0x66766172: /* fvar */
    case 0x67766172: /* gvar */
    case 0x61766172: /* avar */
    case 0x63766172: /* cvar */
    case 0x48564152: /* HVAR */
    case 0x56564152: /* VVAR */
    case 0x4D564152: /* MVAR */
    case 0x53544154: /* STAT */
        return true;
    default:
        return false;
    }
}

// A bounds-checked big-endian reader. Any out-of-range read latches m_failed;
// callers check failed() once at the end of each parsing unit.
class Reader {
public:
    Reader(const uint8_t* data, size_t size)
        : m_data(data)
        , m_size(size)
    {
    }

    Reader slice(size_t offset, size_t length) const
    {
        if (offset > m_size || length > m_size - offset) {
            Reader failed(nullptr, 0);
            failed.m_failed = true;
            return failed;
        }
        return Reader(m_data + offset, length);
    }

    uint8_t u8()
    {
        if (m_pos + 1 > m_size) {
            m_failed = true;
            return 0;
        }
        return m_data[m_pos++];
    }

    uint16_t u16()
    {
        if (m_pos + 2 > m_size) {
            m_failed = true;
            return 0;
        }
        uint16_t v = (uint16_t(m_data[m_pos]) << 8) | m_data[m_pos + 1];
        m_pos += 2;
        return v;
    }

    int16_t s16() { return int16_t(u16()); }

    uint32_t u32()
    {
        if (m_pos + 4 > m_size) {
            m_failed = true;
            return 0;
        }
        uint32_t v = (uint32_t(m_data[m_pos]) << 24) | (uint32_t(m_data[m_pos + 1]) << 16) | (uint32_t(m_data[m_pos + 2]) << 8) | m_data[m_pos + 3];
        m_pos += 4;
        return v;
    }

    int32_t s32() { return int32_t(u32()); }

    float f2dot14() { return s16() / 16384.0f; }
    float fixed() { return s32() / 65536.0f; }

    void skip(size_t n)
    {
        if (m_pos + n > m_size) {
            m_failed = true;
            return;
        }
        m_pos += n;
    }

    void seek(size_t pos)
    {
        if (pos > m_size) {
            m_failed = true;
            return;
        }
        m_pos = pos;
    }

    size_t position() const { return m_pos; }
    size_t size() const { return m_size; }
    const uint8_t* bytesAt(size_t offset, size_t length) const
    {
        if (offset > m_size || length > m_size - offset)
            return nullptr;
        return m_data + offset;
    }
    bool failed() const { return m_failed; }

private:
    const uint8_t* m_data { nullptr };
    size_t m_size { 0 };
    size_t m_pos { 0 };
    bool m_failed { false };
};

// Big-endian writer over a growable buffer.
class Writer {
public:
    void u8(uint8_t v) { m_bytes.push_back(v); }
    void u16(uint16_t v)
    {
        m_bytes.push_back(v >> 8);
        m_bytes.push_back(v);
    }
    void s16(int16_t v) { u16(uint16_t(v)); }
    void u32(uint32_t v)
    {
        m_bytes.push_back(v >> 24);
        m_bytes.push_back(v >> 16);
        m_bytes.push_back(v >> 8);
        m_bytes.push_back(v);
    }
    void bytes(const uint8_t* data, size_t length) { m_bytes.insert(m_bytes.end(), data, data + length); }
    void padTo4() { while (m_bytes.size() % 4) m_bytes.push_back(0); }
    size_t size() const { return m_bytes.size(); }
    const std::vector<uint8_t>& vector() const { return m_bytes; }
    std::vector<uint8_t>& vector() { return m_bytes; }

private:
    std::vector<uint8_t> m_bytes;
};

struct SfntTable {
    uint32_t tag { 0 };
    uint32_t offset { 0 };
    uint32_t length { 0 };
};

struct ParsedSfnt {
    Reader whole { nullptr, 0 };
    uint32_t sfntVersion { 0 };
    std::vector<SfntTable> tables;

    const SfntTable* find(uint32_t tag) const
    {
        for (const auto& table : tables) {
            if (table.tag == tag)
                return &table;
        }
        return nullptr;
    }

    Reader tableReader(uint32_t tag) const
    {
        const SfntTable* table = find(tag);
        if (!table)
            return whole.slice(1, 1); // A failed reader.
        return whole.slice(table->offset, table->length);
    }
};

static std::optional<ParsedSfnt> parseSfnt(CFDataRef input)
{
    if (!input)
        return std::nullopt;
    ParsedSfnt sfnt;
    sfnt.whole = Reader(CFDataGetBytePtr(input), CFDataGetLength(input));
    Reader header = sfnt.whole;
    sfnt.sfntVersion = header.u32();
    // Single sfnts with TrueType outlines (0x00010000 / 'true') or CFF-family outlines ('OTTO'); collections ('ttcf') are not handled.
    if (sfnt.sfntVersion != 0x00010000 && sfnt.sfntVersion != 0x74727565 && sfnt.sfntVersion != 0x4F54544F)
        return std::nullopt;
    uint16_t numTables = header.u16();
    header.skip(6);
    for (uint16_t i = 0; i < numTables && !header.failed(); ++i) {
        SfntTable table;
        table.tag = header.u32();
        header.u32(); // checksum, recomputed on output
        table.offset = header.u32();
        table.length = header.u32();
        if (table.offset > sfnt.whole.size() || table.length > sfnt.whole.size() - table.offset)
            return std::nullopt;
        sfnt.tables.push_back(table);
    }
    if (header.failed())
        return std::nullopt;
    return sfnt;
}

static uint32_t sfntTableChecksum(const uint8_t* data, uint32_t length)
{
    uint32_t sum = 0;
    uint32_t nLongs = (length + 3) / 4;
    for (uint32_t i = 0; i < nLongs; ++i) {
        uint32_t word = 0;
        for (unsigned b = 0; b < 4; ++b) {
            uint32_t idx = i * 4 + b;
            word = (word << 8) | (idx < length ? data[idx] : 0);
        }
        sum += word;
    }
    return sum;
}

// Reassembles an sfnt from (tag, bytes) pairs: sorted table directory, 4-byte-aligned
// table data, per-table checksums, and head.checkSumAdjustment.
static CFDataRef assembleSfnt(uint32_t sfntVersion, std::vector<std::pair<uint32_t, std::vector<uint8_t>>>& tables)
{
    if (tables.empty() || tables.size() > 0xFFFF)
        return nullptr;
    std::sort(tables.begin(), tables.end(), [](const auto& a, const auto& b) { return a.first < b.first; });

    uint16_t numTables = tables.size();
    uint32_t headerSize = 12 + uint32_t(numTables) * 16;
    uint64_t total64 = headerSize;
    for (const auto& table : tables)
        total64 += (uint64_t(table.second.size()) + 3) & ~3ull;
    if (total64 > maximumAssembledFontSize)
        return nullptr;
    uint32_t total = uint32_t(total64);

    std::vector<uint8_t> out(total, 0);
    uint8_t* o = out.data();
    auto writeBE32 = [](uint8_t* p, uint32_t v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; };
    auto writeBE16 = [](uint8_t* p, uint16_t v) { p[0] = v >> 8; p[1] = v; };

    writeBE32(o, sfntVersion);
    writeBE16(o + 4, numTables);
    uint16_t entrySelector = 0;
    while ((1u << (entrySelector + 1)) <= numTables)
        ++entrySelector;
    uint16_t searchRange = (1u << entrySelector) * 16;
    writeBE16(o + 6, searchRange);
    writeBE16(o + 8, entrySelector);
    writeBE16(o + 10, uint16_t(numTables * 16 - searchRange));

    uint32_t dataOffset = headerSize;
    int headOutputOffset = -1;
    for (uint16_t i = 0; i < numTables; ++i) {
        auto& [tag, bytes] = tables[i];
        memcpy(o + dataOffset, bytes.data(), bytes.size());
        if (tag == headTag && bytes.size() >= 12) {
            headOutputOffset = dataOffset;
            // checkSumAdjustment (bytes 8..12) must be zero while checksums are computed.
            writeBE32(o + dataOffset + 8, 0);
        }
        uint32_t checksum = sfntTableChecksum(o + dataOffset, bytes.size());
        uint8_t* record = o + 12 + i * 16;
        writeBE32(record, tag);
        writeBE32(record + 4, checksum);
        writeBE32(record + 8, dataOffset);
        writeBE32(record + 12, uint32_t(bytes.size()));
        dataOffset += (uint32_t(bytes.size()) + 3) & ~3u;
    }

    // head.checkSumAdjustment = 0xB1B0AFBA - checksum(whole file with the field still zero).
    if (headOutputOffset >= 0)
        writeBE32(o + headOutputOffset + 8, 0xB1B0AFBAu - sfntTableChecksum(o, total));

    return CFDataCreate(kCFAllocatorDefault, o, total);
}

static std::vector<LegacyVariableFontAxis> parseFvarAxes(const ParsedSfnt& sfnt)
{
    std::vector<LegacyVariableFontAxis> axes;
    Reader fvar = sfnt.tableReader(fvarTag);
    fvar.u16(); // majorVersion
    fvar.u16(); // minorVersion
    uint16_t axesArrayOffset = fvar.u16();
    fvar.u16(); // reserved
    uint16_t axisCount = fvar.u16();
    uint16_t axisSize = fvar.u16();
    if (fvar.failed() || !axisCount || axisSize < 20)
        return { };
    for (uint16_t i = 0; i < axisCount; ++i) {
        fvar.seek(size_t(axesArrayOffset) + size_t(i) * axisSize);
        LegacyVariableFontAxis axis;
        axis.tag = fvar.u32();
        axis.fixedMinimumValue = fvar.s32();
        axis.fixedDefaultValue = fvar.s32();
        axis.fixedMaximumValue = fvar.s32();
        fvar.u16(); // flags
        axis.nameID = fvar.u16();
        axis.minimumValue = axis.fixedMinimumValue / 65536.0;
        axis.defaultValue = axis.fixedDefaultValue / 65536.0;
        axis.maximumValue = axis.fixedMaximumValue / 65536.0;
        if (fvar.failed() || axis.minimumValue > axis.defaultValue || axis.defaultValue > axis.maximumValue)
            return { };
        axes.push_back(axis);
    }
    return axes;
}

// avar: piecewise-linear mapping of each axis's normalized coordinate.
// OpenType normalization uses 16.16 arithmetic and returns F2DOT14 coordinates.
static int64_t roundedDivision(int64_t numerator, int64_t denominator)
{
    int64_t quotient = numerator / denominator;
    int64_t remainder = numerator % denominator;
    if (remainder < 0) {
        --quotient;
        remainder += denominator;
    }
    return quotient + (remainder * 2 >= denominator);
}

static int32_t normalizedFixed(const LegacyVariableFontAxis& axis, double input)
{
    double clamped = std::min(axis.maximumValue, std::max(axis.minimumValue, input));
    int64_t value = int64_t(std::floor(clamped * 65536.0 + 0.5));
    int64_t origin = axis.fixedDefaultValue;
    int64_t denominator = value < origin ? origin - int64_t(axis.fixedMinimumValue) : int64_t(axis.fixedMaximumValue) - origin;
    if (value == origin || !denominator)
        return 0;
    return int32_t(std::max<int64_t>(-65536, std::min<int64_t>(65536, roundedDivision((value - origin) * 65536, denominator))));
}

static float normalizedF2Dot14(int32_t fixed)
{
    return float(std::floor((double(fixed) + 2) / 4) / 16384.0);
}

static bool applyAvar(const ParsedSfnt&, std::vector<float>&);

// Packed point numbers (gvar serialized data). Returns false on parse failure.
// An empty result with allPoints=true means "deltas apply to every point".
static bool readPackedPointNumbers(Reader& reader, std::vector<uint32_t>& points, bool& allPoints)
{
    points.clear();
    allPoints = false;
    uint16_t count = reader.u8();
    if (reader.failed())
        return false;
    if (!count) {
        allPoints = true;
        return true;
    }
    if (count & 0x80)
        count = ((count & 0x7F) << 8) | reader.u8();
    uint32_t point = 0;
    while (points.size() < count) {
        uint8_t control = reader.u8();
        if (reader.failed())
            return false;
        uint32_t runLength = (control & 0x7F) + 1;
        bool words = control & 0x80;
        for (uint32_t i = 0; i < runLength && points.size() < count; ++i) {
            point += words ? reader.u16() : reader.u8();
            points.push_back(point);
        }
    }
    return !reader.failed();
}

static bool readPackedDeltas(Reader& reader, size_t count, std::vector<int32_t>& deltas)
{
    deltas.clear();
    deltas.reserve(count);
    while (deltas.size() < count) {
        uint8_t control = reader.u8();
        if (reader.failed())
            return false;
        uint32_t runLength = (control & 0x3F) + 1;
        for (uint32_t i = 0; i < runLength && deltas.size() < count; ++i) {
            if (control & 0x80)
                deltas.push_back(0);
            else if (control & 0x40)
                deltas.push_back(reader.s16());
            else
                deltas.push_back(int8_t(reader.u8()));
        }
    }
    return !reader.failed();
}

// The standard variation-region scalar (fontTools supportScalar equivalent).
static float tupleScalar(const std::vector<float>& coords, const std::vector<float>& peaks, const std::vector<float>* starts, const std::vector<float>* ends)
{
    float scalar = 1;
    for (size_t i = 0; i < coords.size(); ++i) {
        float peak = peaks[i];
        if (!peak)
            continue;
        float lower = starts ? (*starts)[i] : std::min(0.0f, peak);
        float upper = ends ? (*ends)[i] : std::max(0.0f, peak);
        if (lower > peak || peak > upper)
            continue;
        if (lower < 0 && upper > 0)
            continue;
        float v = coords[i];
        if (v == peak)
            continue;
        if (v <= lower || upper <= v)
            return 0;
        if (v < peak)
            scalar *= (v - lower) / (peak - lower);
        else
            scalar *= (upper - v) / (upper - peak);
    }
    return scalar;
}

struct MetricField {
    uint32_t tag;
    uint32_t table;
    uint16_t offset;
    bool isUnsigned { false };
};

static const std::vector<MetricField>& metricFields()
{
    constexpr uint32_t os2 = tagFor('O', 'S', '/', '2');
    constexpr uint32_t vhea = tagFor('v', 'h', 'e', 'a');
    constexpr uint32_t post = tagFor('p', 'o', 's', 't');
    static const std::vector<MetricField> fields = {
        { tagFor('h', 'a', 's', 'c'), os2, 68 },
        { tagFor('h', 'd', 's', 'c'), os2, 70 },
        { tagFor('h', 'l', 'g', 'p'), os2, 72 },
        { tagFor('h', 'c', 'l', 'a'), os2, 74, true },
        { tagFor('h', 'c', 'l', 'd'), os2, 76, true },
        { tagFor('x', 'h', 'g', 't'), os2, 86 },
        { tagFor('c', 'p', 'h', 't'), os2, 88 },
        { tagFor('s', 'b', 'x', 's'), os2, 10 },
        { tagFor('s', 'b', 'y', 's'), os2, 12 },
        { tagFor('s', 'b', 'x', 'o'), os2, 14 },
        { tagFor('s', 'b', 'y', 'o'), os2, 16 },
        { tagFor('s', 'p', 'x', 's'), os2, 18 },
        { tagFor('s', 'p', 'y', 's'), os2, 20 },
        { tagFor('s', 'p', 'x', 'o'), os2, 22 },
        { tagFor('s', 'p', 'y', 'o'), os2, 24 },
        { tagFor('s', 't', 'r', 's'), os2, 26 },
        { tagFor('s', 't', 'r', 'o'), os2, 28 },
        { tagFor('h', 'c', 'r', 's'), hheaTag, 18 },
        { tagFor('h', 'c', 'r', 'n'), hheaTag, 20 },
        { tagFor('h', 'c', 'o', 'f'), hheaTag, 22 },
        { tagFor('v', 'a', 's', 'c'), vhea, 4 },
        { tagFor('v', 'd', 's', 'c'), vhea, 6 },
        { tagFor('v', 'l', 'g', 'p'), vhea, 8 },
        { tagFor('v', 'c', 'r', 's'), vhea, 18 },
        { tagFor('v', 'c', 'r', 'n'), vhea, 20 },
        { tagFor('v', 'c', 'o', 'f'), vhea, 22 },
        { tagFor('u', 'n', 'd', 's'), post, 10 },
        { tagFor('u', 'n', 'd', 'o'), post, 8 },
    };
    return fields;
}

class ItemVariationStore {
public:
    explicit ItemVariationStore(Reader reader)
        : m_reader(reader)
    {
    }

    bool initialize(const std::vector<float>& coords)
    {
        Reader store = m_reader;
        uint16_t format = store.u16();
        uint32_t regionOffset = store.u32();
        m_dataCount = store.u16();
        if (store.failed() || format != 1 || !store.bytesAt(8, size_t(m_dataCount) * 4) || !regionOffset || regionOffset > store.size())
            return false;
        Reader regions = store.slice(regionOffset, store.size() - regionOffset);
        uint16_t axisCount = regions.u16();
        uint16_t regionCount = regions.u16();
        if (regions.failed() || axisCount != coords.size() || regionCount & 0x8000 || !regions.bytesAt(4, size_t(axisCount) * regionCount * 6))
            return false;
        m_scalars.reserve(regionCount);
        std::vector<float> starts(axisCount), peaks(axisCount), ends(axisCount);
        for (uint16_t region = 0; region < regionCount; ++region) {
            for (uint16_t axis = 0; axis < axisCount; ++axis) {
                starts[axis] = regions.f2dot14();
                peaks[axis] = regions.f2dot14();
                ends[axis] = regions.f2dot14();
            }
            m_scalars.push_back(tupleScalar(coords, peaks, &starts, &ends));
        }
        return true;
    }

    // The axis count of the store's region list, for a caller with no coordinates of its own.
    std::optional<uint16_t> axisCount() const
    {
        Reader store = m_reader;
        store.u16(); // format
        uint32_t regionOffset = store.u32();
        if (store.failed() || !regionOffset || regionOffset > store.size())
            return std::nullopt;
        Reader regions = store.slice(regionOffset, store.size() - regionOffset);
        uint16_t axes = regions.u16();
        return regions.failed() ? std::nullopt : std::optional<uint16_t>(axes);
    }

    // The scalars of the regions ItemVariationData `dataIndex` weights its deltas by, in its region-index
    // order. A NULL ItemVariationData has no regions.
    bool dataScalars(uint32_t dataIndex, std::vector<float>& scalars) const
    {
        if (dataIndex >= m_dataCount)
            return false;
        Reader store = m_reader;
        store.seek(8 + size_t(dataIndex) * 4);
        uint32_t dataOffset = store.u32();
        scalars.clear();
        if (store.failed() || dataOffset > store.size())
            return false;
        if (!dataOffset)
            return true;
        Reader data = store.slice(dataOffset, store.size() - dataOffset);
        data.skip(4); // itemCount, wordDeltaCount
        uint16_t regionIndexCount = data.u16();
        if (data.failed() || !data.bytesAt(6, size_t(regionIndexCount) * 2))
            return false;
        scalars.resize(regionIndexCount);
        for (uint16_t i = 0; i < regionIndexCount; ++i) {
            uint16_t region = data.u16();
            if (region >= m_scalars.size())
                return false;
            scalars[i] = m_scalars[region];
        }
        return true;
    }

    std::optional<double> delta(uint32_t index) const
    {
        if (index == 0xFFFFFFFF)
            return 0;
        uint16_t outer = index >> 16;
        uint16_t inner = index;
        if (outer >= m_dataCount)
            return std::nullopt;
        Reader store = m_reader;
        store.seek(8 + size_t(outer) * 4);
        uint32_t dataOffset = store.u32();
        // A NULL subtable offset denotes items with no variation data.
        if (!dataOffset)
            return 0;
        if (dataOffset > store.size())
            return std::nullopt;
        Reader data = store.slice(dataOffset, store.size() - dataOffset);
        uint16_t itemCount = data.u16();
        uint16_t wordDeltaCount = data.u16();
        uint16_t indexCount = data.u16();
        bool longWords = wordDeltaCount & 0x8000;
        wordDeltaCount &= 0x7FFF;
        size_t rowSize = size_t(wordDeltaCount) * (longWords ? 4 : 2);
        if (data.failed() || inner >= itemCount || wordDeltaCount > indexCount)
            return std::nullopt;
        rowSize += size_t(indexCount - wordDeltaCount) * (longWords ? 2 : 1);
        size_t rowsOffset = 6 + size_t(indexCount) * 2;
        if (!data.bytesAt(6, size_t(indexCount) * 2) || !data.bytesAt(rowsOffset, size_t(itemCount) * rowSize))
            return std::nullopt;
        Reader row = data.slice(rowsOffset + size_t(inner) * rowSize, rowSize);
        double result = 0;
        for (uint16_t column = 0; column < indexCount; ++column) {
            uint16_t region = data.u16();
            if (region >= m_scalars.size())
                return std::nullopt;
            int32_t value = column < wordDeltaCount ? (longWords ? row.s32() : row.s16()) : (longWords ? row.s16() : int8_t(row.u8()));
            result += double(m_scalars[region]) * value;
        }
        return row.failed() ? std::nullopt : std::optional<double>(result);
    }

private:
    Reader m_reader;
    uint16_t m_dataCount { 0 };
    std::vector<float> m_scalars;
};

static std::optional<uint32_t> mappedVariationIndex(Reader map, uint32_t index)
{
    uint8_t format = map.u8();
    uint8_t entryFormat = map.u8();
    uint32_t count = format ? map.u32() : map.u16();
    size_t entrySize = ((entryFormat >> 4) & 3) + 1;
    unsigned innerBits = (entryFormat & 15) + 1;
    if (map.failed() || format > 1 || entryFormat & 0xC0 || !map.bytesAt(map.position(), size_t(count) * entrySize))
        return std::nullopt;
    if (!count)
        return index;
    map.skip(size_t(std::min(index, count - 1)) * entrySize);
    uint32_t packed = 0;
    for (size_t i = 0; i < entrySize; ++i)
        packed = (packed << 8) | map.u8();
    uint32_t outer = packed >> innerBits;
    if (outer > 0xFFFF)
        return std::nullopt;
    return (outer << 16) | (packed & ((uint32_t(1) << innerBits) - 1));
}

// MVAR deltas use font design units; avar2 deltas use F2DOT14 coordinate units.
static bool metricVariations(const ParsedSfnt& sfnt, const std::vector<float>& coords, std::map<uint32_t, double>& deltas)
{
    constexpr uint32_t mvarTag = tagFor('M', 'V', 'A', 'R');
    if (!sfnt.find(mvarTag))
        return true;
    Reader mvar = sfnt.tableReader(mvarTag);
    uint16_t major = mvar.u16();
    mvar.skip(4); // minor version and reserved
    uint16_t recordSize = mvar.u16();
    uint16_t recordCount = mvar.u16();
    uint16_t storeOffset = mvar.u16();
    if (mvar.failed() || major != 1 || recordSize < 8 || !mvar.bytesAt(12, size_t(recordSize) * recordCount))
        return false;
    if (!recordCount)
        return true;
    if (!storeOffset || storeOffset > mvar.size())
        return false;
    ItemVariationStore store(mvar.slice(storeOffset, mvar.size() - storeOffset));
    if (!store.initialize(coords))
        return false;
    for (uint16_t record = 0; record < recordCount; ++record) {
        mvar.seek(12 + size_t(record) * recordSize);
        uint32_t tag = mvar.u32();
        uint32_t index = mvar.u32();
        bool knownTag = (tag >= tagFor('g', 's', 'p', '0') && tag <= tagFor('g', 's', 'p', '9'));
        for (const auto& field : metricFields())
            knownTag |= field.tag == tag;
        if (!knownTag)
            continue;
        auto delta = store.delta(index);
        if (!delta || !deltas.emplace(tag, *delta).second)
            return false;
    }
    return true;
}

static bool applyAvar(const ParsedSfnt& sfnt, std::vector<float>& normalizedCoords)
{
    if (!sfnt.find(avarTag)) {
        for (float& coordinate : normalizedCoords)
            coordinate = normalizedF2Dot14(int32_t(coordinate * 65536));
        return true;
    }
    Reader avar = sfnt.tableReader(avarTag);
    uint16_t majorVersion = avar.u16();
    avar.u16(); // minorVersion
    avar.u16(); // reserved
    uint16_t axisCount = avar.u16();
    if (avar.failed() || (majorVersion != 1 && majorVersion != 2) || (axisCount != normalizedCoords.size() && !(majorVersion == 2 && !axisCount)))
        return false;
    for (uint16_t axis = 0; axis < axisCount; ++axis) {
        uint16_t positionMapCount = avar.u16();
        int32_t coord = int32_t(normalizedCoords[axis] * 65536);
        int32_t mapped = coord;
        int32_t previousFrom = -131072, previousTo = -131072;
        bool done = false;
        for (uint16_t i = 0; i < positionMapCount; ++i) {
            int32_t from = int32_t(avar.s16()) * 4;
            int32_t to = int32_t(avar.s16()) * 4;
            if (!done) {
                if (coord == from) {
                    mapped = to;
                    done = true;
                } else if (coord < from) {
                    if (i && from > previousFrom) {
                        int64_t ratio = roundedDivision(int64_t(coord - previousFrom) * 65536, from - previousFrom);
                        mapped = int32_t(previousTo + roundedDivision(ratio * (to - previousTo), 65536));
                    } else
                        mapped = to;
                    done = true;
                }
            }
            previousFrom = from;
            previousTo = to;
        }
        if (avar.failed())
            return false;
        normalizedCoords[axis] = normalizedF2Dot14(std::max(-65536, std::min(65536, mapped)));
    }
    if (majorVersion == 2) {
        if (!axisCount) {
            for (float& coordinate : normalizedCoords)
                coordinate = normalizedF2Dot14(int32_t(coordinate * 65536));
        }
        uint32_t mapOffset = avar.u32();
        uint32_t storeOffset = avar.u32();
        if (avar.failed() || mapOffset > avar.size() || storeOffset > avar.size())
            return false;
        ItemVariationStore store(avar.slice(storeOffset, avar.size() - storeOffset));
        if (storeOffset && !store.initialize(normalizedCoords))
            return false;
        std::vector<float> finalCoords = normalizedCoords;
        for (size_t axis = 0; axis < normalizedCoords.size(); ++axis) {
            auto index = mapOffset ? mappedVariationIndex(avar.slice(mapOffset, avar.size() - mapOffset), uint32_t(axis)) : std::optional<uint32_t>(axis);
            if (!index)
                return false;
            auto delta = storeOffset ? store.delta(*index) : std::optional<double>(0);
            if (!delta)
                return false;
            double coordinate = std::floor(normalizedCoords[axis] * 16384.0 + 0.5) + std::floor(*delta + 0.5);
            finalCoords[axis] = float(std::max(-16384.0, std::min(16384.0, coordinate)) / 16384.0);
        }
        normalizedCoords = std::move(finalCoords);
    }
    return true;
}

static bool applyMetricVariations(uint32_t table, std::vector<uint8_t>& bytes, const std::map<uint32_t, double>& deltas)
{
    auto apply = [&](uint32_t tag, size_t offset, bool isUnsigned) {
        auto found = deltas.find(tag);
        if (found == deltas.end())
            return true;
        if (offset + 2 > bytes.size())
            return false;
        uint16_t encoded = (uint16_t(bytes[offset]) << 8) | bytes[offset + 1];
        double value = (isUnsigned ? int32_t(encoded) : int16_t(encoded)) + std::floor(found->second + 0.5);
        if (value < (isUnsigned ? 0.0 : -32768.0) || value > (isUnsigned ? 65535.0 : 32767.0))
            return false;
        encoded = uint16_t(int32_t(value));
        bytes[offset] = uint8_t(encoded >> 8);
        bytes[offset + 1] = uint8_t(encoded);
        return true;
    };
    for (const auto& field : metricFields()) {
        if (field.table == table && !apply(field.tag, field.offset, field.isUnsigned))
            return false;
    }
    if (table == tagFor('g', 'a', 's', 'p')) {
        if (bytes.size() < 4)
            return false;
        uint16_t count = (uint16_t(bytes[2]) << 8) | bytes[3];
        if (4 + size_t(count) * 4 > bytes.size())
            return false;
        // The last gasp range ends at the fixed 0xFFFF sentinel.
        for (uint16_t i = 0; i < 10 && i + 1 < count; ++i) {
            if (!apply(tagFor('g', 's', 'p', '0') + i, 4 + size_t(i) * 4, true))
                return false;
        }
    }
    return true;
}

static bool setOffset16(std::vector<uint8_t>& bytes, size_t position, size_t value)
{
    if (value > 0xFFFF || position + 2 > bytes.size())
        return false;
    bytes[position] = uint8_t(value >> 8);
    bytes[position + 1] = uint8_t(value);
    return true;
}

static std::optional<std::vector<uint8_t>> staticFeature(Reader layout, size_t offset, uint32_t tag, uint16_t totalLookups)
{
    layout.seek(offset);
    uint16_t parameters = layout.u16();
    uint16_t lookupCount = layout.u16();
    size_t length = 4 + size_t(lookupCount) * 2;
    const uint8_t* source = layout.bytesAt(offset, length);
    if (layout.failed() || !source)
        return std::nullopt;
    std::vector<uint8_t> result(source, source + length);
    for (uint16_t i = 0; i < lookupCount; ++i) {
        if (layout.u16() >= totalLookups)
            return std::nullopt;
    }
    if (!parameters)
        return result;
    size_t parameterLength = 0;
    if (tag == tagFor('s', 'i', 'z', 'e'))
        parameterLength = 10;
    else if (tag >= tagFor('s', 's', '0', '1') && tag <= tagFor('s', 's', '2', '0') && (tag & 0xFF) >= '0' && (tag & 0xFF) <= '9')
        parameterLength = 4;
    else if ((tag >> 16) == (tagFor('c', 'v', 0, 0) >> 16) && ((tag >> 8) & 0xFF) >= '0' && ((tag >> 8) & 0xFF) <= '9' && (tag & 0xFF) >= '0' && (tag & 0xFF) <= '9' && (tag & 0xFFFF) != 0x3030) {
        layout.seek(offset + parameters + 12);
        parameterLength = 14 + size_t(layout.u16()) * 3;
    } else
        return std::nullopt;
    const uint8_t* parameterBytes = layout.bytesAt(offset + parameters, parameterLength);
    if (layout.failed() || !parameterBytes || !setOffset16(result, 0, result.size()))
        return std::nullopt;
    result.insert(result.end(), parameterBytes, parameterBytes + parameterLength);
    return result;
}

static std::optional<std::vector<uint8_t>> staticScriptList(Reader layout, size_t offset)
{
    layout.seek(offset);
    uint16_t count = layout.u16();
    const uint8_t* records = layout.bytesAt(offset, 2 + size_t(count) * 6);
    if (layout.failed() || !records)
        return std::nullopt;
    std::vector<uint8_t> result(records, records + 2 + size_t(count) * 6);
    std::map<size_t, size_t> scriptOffsets;
    for (uint16_t i = 0; i < count; ++i) {
        layout.seek(offset + 2 + size_t(i) * 6 + 4);
        size_t scriptOffset = offset + layout.u16();
        auto known = scriptOffsets.find(scriptOffset);
        if (known != scriptOffsets.end()) {
            if (!setOffset16(result, 2 + size_t(i) * 6 + 4, known->second))
                return std::nullopt;
            continue;
        }
        layout.seek(scriptOffset);
        uint16_t defaultOffset = layout.u16();
        uint16_t languages = layout.u16();
        size_t headerSize = 4 + size_t(languages) * 6;
        const uint8_t* header = layout.bytesAt(scriptOffset, headerSize);
        if (layout.failed() || !header)
            return std::nullopt;
        std::vector<uint8_t> script(header, header + headerSize);
        std::map<size_t, size_t> languageOffsets;
        for (uint32_t j = 0; j <= languages; ++j) {
            size_t field = j ? 4 + size_t(j - 1) * 6 + 4 : 0;
            layout.seek(scriptOffset + field);
            uint16_t languageOffset = j ? layout.u16() : defaultOffset;
            if (!languageOffset && !j)
                continue;
            auto knownLanguage = languageOffsets.find(languageOffset);
            if (knownLanguage != languageOffsets.end()) {
                if (!setOffset16(script, field, knownLanguage->second))
                    return std::nullopt;
                continue;
            }
            layout.seek(scriptOffset + languageOffset + 4);
            size_t length = 6 + size_t(layout.u16()) * 2;
            const uint8_t* language = layout.bytesAt(scriptOffset + languageOffset, length);
            if (layout.failed() || !language || !setOffset16(script, field, script.size()))
                return std::nullopt;
            languageOffsets.emplace(languageOffset, script.size());
            script.insert(script.end(), language, language + length);
        }
        if (!setOffset16(result, 2 + size_t(i) * 6 + 4, result.size()))
            return std::nullopt;
        scriptOffsets.emplace(scriptOffset, result.size());
        result.insert(result.end(), script.begin(), script.end());
    }
    return result;
}

// Resolve the first matching GSUB/GPOS FeatureVariations record into a static FeatureList.
static bool instanceLayoutFeatures(std::vector<uint8_t>& bytes, const std::vector<float>& coords)
{
    Reader layout(bytes.data(), bytes.size());
    if (layout.u32() != 0x00010001)
        return !layout.failed();
    uint16_t scriptOffset = layout.u16();
    uint16_t featureOffset = layout.u16();
    uint16_t lookupOffset = layout.u16();
    uint32_t variationsOffset = layout.u32();
    if (layout.failed() || variationsOffset > bytes.size())
        return false;
    layout.seek(featureOffset);
    uint16_t featureCount = layout.u16();
    if (layout.failed() || !layout.bytesAt(featureOffset + 2, size_t(featureCount) * 6))
        return false;
    std::map<uint16_t, size_t> replacements;
    if (variationsOffset) {
        Reader variations = layout.slice(variationsOffset, bytes.size() - variationsOffset);
        uint32_t version = variations.u32();
        uint32_t count = variations.u32();
        if (variations.failed() || (version == 0x00010000 && !variations.bytesAt(8, size_t(count) * 8)))
            return false;
        for (uint32_t i = 0; version == 0x00010000 && i < count; ++i) {
            variations.seek(8 + size_t(i) * 8);
            uint32_t conditionOffset = variations.u32();
            uint32_t substitutionOffset = variations.u32();
            bool matches = true;
            if (conditionOffset) {
                if (conditionOffset > variations.size())
                    return false;
                Reader conditions = variations.slice(conditionOffset, variations.size() - conditionOffset);
                uint16_t conditionCount = conditions.u16();
                if (conditions.failed() || !conditions.bytesAt(2, size_t(conditionCount) * 4))
                    return false;
                for (uint16_t c = 0; c < conditionCount; ++c) {
                    conditions.seek(2 + size_t(c) * 4);
                    uint32_t condition = conditions.u32();
                    conditions.seek(condition);
                    uint16_t format = conditions.u16();
                    if (conditions.failed())
                        return false;
                    if (format != 1) {
                        matches = false;
                        continue;
                    }
                    uint16_t axis = conditions.u16();
                    float minimum = conditions.f2dot14();
                    float maximum = conditions.f2dot14();
                    if (conditions.failed())
                        return false;
                    double coordinate = axis < coords.size() ? std::floor(coords[axis] * 16384.0 + 0.5) / 16384.0 : 0;
                    matches &= axis < coords.size() && coordinate >= minimum && coordinate <= maximum;
                }
            }
            if (!matches)
                continue;
            if (!substitutionOffset)
                break;
            if (substitutionOffset > variations.size())
                return false;
            Reader substitutions = variations.slice(substitutionOffset, variations.size() - substitutionOffset);
            uint32_t substitutionVersion = substitutions.u32();
            if (substitutions.failed())
                return false;
            if (substitutionVersion != 0x00010000)
                continue;
            uint16_t substitutionCount = substitutions.u16();
            if (substitutions.failed() || !substitutions.bytesAt(6, size_t(substitutionCount) * 6))
                return false;
            for (uint16_t r = 0; r < substitutionCount; ++r) {
                uint16_t feature = substitutions.u16();
                uint32_t alternate = substitutions.u32();
                if (feature >= featureCount || !alternate || alternate > substitutions.size()
                    || !replacements.emplace(feature, size_t(variationsOffset) + substitutionOffset + alternate).second)
                    return false;
            }
            break;
        }
    }
    layout.seek(lookupOffset);
    uint16_t lookupCount = layout.u16();
    if (layout.failed() || !layout.bytesAt(lookupOffset + 2, size_t(lookupCount) * 2))
        return false;
    bool fits = true;
    for (const auto& replacement : replacements) {
        layout.seek(featureOffset + 2 + size_t(replacement.first) * 6);
        uint32_t tag = layout.u32();
        if (!staticFeature(layout, replacement.second, tag, lookupCount))
            return false;
        fits &= replacement.second >= featureOffset && replacement.second - featureOffset <= 0xFFFF;
    }
    if (fits) {
        for (const auto& replacement : replacements) {
            if (!setOffset16(bytes, featureOffset + 2 + size_t(replacement.first) * 6 + 4, replacement.second - featureOffset))
                return false;
        }
        bytes[3] = 0; // Layout version 1.0; the extra header bytes are padding.
        std::fill(bytes.begin() + 10, bytes.begin() + 14, 0);
        return true;
    }

    // AlternateFeature offsets are 32-bit. Pack their static 16-bit references near
    // the header while retaining every lookup's original relative offsets.
    auto scripts = staticScriptList(layout, scriptOffset);
    if (!scripts || lookupOffset > layout.size())
        return false;
    std::vector<uint8_t> features(2 + size_t(featureCount) * 6);
    std::memcpy(features.data(), bytes.data() + featureOffset, features.size());
    std::map<std::vector<uint8_t>, size_t> featurePositions;
    for (uint16_t i = 0; i < featureCount; ++i) {
        layout.seek(featureOffset + 2 + size_t(i) * 6);
        uint32_t tag = layout.u32();
        size_t original = size_t(featureOffset) + layout.u16();
        auto replacement = replacements.find(i);
        auto feature = staticFeature(layout, replacement == replacements.end() ? original : replacement->second, tag, lookupCount);
        if (!feature)
            return false;
        auto known = featurePositions.find(*feature);
        size_t position = known == featurePositions.end() ? features.size() : known->second;
        if (!setOffset16(features, 2 + size_t(i) * 6 + 4, position))
            return false;
        if (known == featurePositions.end()) {
            featurePositions.emplace(*feature, position);
            features.insert(features.end(), feature->begin(), feature->end());
        }
    }
    std::vector<uint8_t> lookups(bytes.begin() + lookupOffset, bytes.end());
    const std::vector<uint8_t>* blocks[] = { &*scripts, &features, &lookups };
    unsigned order[] = { 0, 1, 2 };
    do {
        std::vector<uint8_t> result { 0, 1, 0, 0, 0, 0, 0, 0, 0, 0 };
        bool representable = true;
        for (unsigned block : order) {
            if (!setOffset16(result, 4 + block * 2, result.size()) || blocks[block]->size() > maximumAssembledFontSize - result.size()) {
                representable = false;
                break;
            }
            result.insert(result.end(), blocks[block]->begin(), blocks[block]->end());
        }
        if (representable) {
            bytes = std::move(result);
            return true;
        }
    } while (std::next_permutation(std::begin(order), std::end(order)));
    return false;
}

struct GlyphPoint {
    int32_t x { 0 };
    int32_t y { 0 };
    uint8_t flags { 0 }; // Original on-curve (0x01) and overlap (0x40) bits.
};

struct CompositeComponent {
    uint16_t flags { 0 };
    uint16_t glyphIndex { 0 };
    int32_t arg1 { 0 };
    int32_t arg2 { 0 };
    std::vector<uint8_t> transformBytes; // Raw scale/matrix bytes, copied verbatim.
    // Decoded 2x2 transform, used only for bbox computation.
    float xx { 1 }, xy { 0 }, yx { 0 }, yy { 1 };
};

struct DecodedGlyph {
    bool isComposite { false };
    // Simple glyphs:
    std::vector<uint16_t> endPoints;
    std::vector<GlyphPoint> points;
    std::vector<uint8_t> instructions;
    // Composite glyphs:
    std::vector<CompositeComponent> components;
    std::vector<uint8_t> trailingBytes; // Composite instructions, copied verbatim.

    size_t pointCountForGvar() const { return isComposite ? components.size() : points.size(); }
};

static constexpr uint8_t onCurveFlag = 0x01;
static constexpr uint8_t xShortFlag = 0x02;
static constexpr uint8_t yShortFlag = 0x04;
static constexpr uint8_t repeatFlag = 0x08;
static constexpr uint8_t xSameOrPositiveFlag = 0x10;
static constexpr uint8_t ySameOrPositiveFlag = 0x20;
static constexpr uint8_t overlapSimpleFlag = 0x40;

static constexpr uint16_t arg1And2AreWordsFlag = 0x0001;
static constexpr uint16_t argsAreXYValuesFlag = 0x0002;
static constexpr uint16_t weHaveAScaleFlag = 0x0008;
static constexpr uint16_t moreComponentsFlag = 0x0020;
static constexpr uint16_t weHaveAnXAndYScaleFlag = 0x0040;
static constexpr uint16_t weHaveATwoByTwoFlag = 0x0080;

static std::optional<DecodedGlyph> decodeGlyph(Reader glyph, int16_t& numberOfContours)
{
    DecodedGlyph decoded;
    numberOfContours = glyph.s16();
    glyph.skip(8); // Bounding box, recomputed on output.
    if (glyph.failed())
        return std::nullopt;

    if (numberOfContours >= 0) {
        for (int i = 0; i < numberOfContours; ++i)
            decoded.endPoints.push_back(glyph.u16());
        uint16_t instructionLength = glyph.u16();
        if (glyph.failed())
            return std::nullopt;
        const uint8_t* instructions = glyph.bytesAt(glyph.position(), instructionLength);
        if (!instructions)
            return std::nullopt;
        decoded.instructions.assign(instructions, instructions + instructionLength);
        glyph.skip(instructionLength);

        size_t numPoints = decoded.endPoints.empty() ? 0 : size_t(decoded.endPoints.back()) + 1;
        for (size_t i = 1; i < decoded.endPoints.size(); ++i) {
            if (decoded.endPoints[i] < decoded.endPoints[i - 1])
                return std::nullopt;
        }

        std::vector<uint8_t> flags;
        flags.reserve(numPoints);
        while (flags.size() < numPoints) {
            uint8_t flag = glyph.u8();
            flags.push_back(flag);
            if (flag & repeatFlag) {
                uint8_t repeatCount = glyph.u8();
                for (uint8_t i = 0; i < repeatCount && flags.size() < numPoints; ++i)
                    flags.push_back(flag);
            }
            if (glyph.failed())
                return std::nullopt;
        }

        decoded.points.resize(numPoints);
        int32_t x = 0;
        for (size_t i = 0; i < numPoints; ++i) {
            uint8_t flag = flags[i];
            if (flag & xShortFlag) {
                uint8_t dx = glyph.u8();
                x += (flag & xSameOrPositiveFlag) ? dx : -int32_t(dx);
            } else if (!(flag & xSameOrPositiveFlag))
                x += glyph.s16();
            decoded.points[i].x = x;
            decoded.points[i].flags = flag & (onCurveFlag | overlapSimpleFlag);
        }
        int32_t y = 0;
        for (size_t i = 0; i < numPoints; ++i) {
            uint8_t flag = flags[i];
            if (flag & yShortFlag) {
                uint8_t dy = glyph.u8();
                y += (flag & ySameOrPositiveFlag) ? dy : -int32_t(dy);
            } else if (!(flag & ySameOrPositiveFlag))
                y += glyph.s16();
            decoded.points[i].y = y;
        }
        if (glyph.failed())
            return std::nullopt;
        return decoded;
    }

    decoded.isComposite = true;
    bool more = true;
    while (more) {
        CompositeComponent component;
        component.flags = glyph.u16();
        component.glyphIndex = glyph.u16();
        if (component.flags & arg1And2AreWordsFlag) {
            component.arg1 = glyph.s16();
            component.arg2 = glyph.s16();
        } else if (component.flags & argsAreXYValuesFlag) {
            component.arg1 = int8_t(glyph.u8());
            component.arg2 = int8_t(glyph.u8());
        } else {
            component.arg1 = glyph.u8();
            component.arg2 = glyph.u8();
        }
        size_t transformLength = 0;
        if (component.flags & weHaveAScaleFlag)
            transformLength = 2;
        else if (component.flags & weHaveAnXAndYScaleFlag)
            transformLength = 4;
        else if (component.flags & weHaveATwoByTwoFlag)
            transformLength = 8;
        if (transformLength) {
            const uint8_t* bytes = glyph.bytesAt(glyph.position(), transformLength);
            if (!bytes)
                return std::nullopt;
            component.transformBytes.assign(bytes, bytes + transformLength);
            Reader transform = glyph.slice(glyph.position(), transformLength);
            if (component.flags & weHaveAScaleFlag) {
                component.xx = component.yy = transform.f2dot14();
            } else if (component.flags & weHaveAnXAndYScaleFlag) {
                component.xx = transform.f2dot14();
                component.yy = transform.f2dot14();
            } else {
                component.xx = transform.f2dot14();
                component.xy = transform.f2dot14();
                component.yx = transform.f2dot14();
                component.yy = transform.f2dot14();
            }
            glyph.skip(transformLength);
        }
        if (glyph.failed())
            return std::nullopt;
        decoded.components.push_back(component);
        more = component.flags & moreComponentsFlag;
    }
    // Composite instructions (and anything else trailing) are copied verbatim.
    const uint8_t* trailing = glyph.bytesAt(glyph.position(), glyph.size() - glyph.position());
    if (trailing)
        decoded.trailingBytes.assign(trailing, trailing + (glyph.size() - glyph.position()));
    return decoded;
}

struct BBox {
    int32_t xMin { 0 }, yMin { 0 }, xMax { 0 }, yMax { 0 };
    bool valid { false };

    void add(float x, float y) { addPoint(int32_t(std::lround(x)), int32_t(std::lround(y))); }

    void addPoint(int32_t xi, int32_t yi)
    {
        if (!valid) {
            xMin = xMax = xi;
            yMin = yMax = yi;
            valid = true;
            return;
        }
        xMin = std::min(xMin, xi);
        xMax = std::max(xMax, xi);
        yMin = std::min(yMin, yi);
        yMax = std::max(yMax, yi);
    }
};

static int16_t clampToInt16(int32_t v)
{
    return int16_t(std::min<int32_t>(32767, std::max<int32_t>(-32768, v)));
}

static void encodeSimpleGlyph(const DecodedGlyph& glyph, const BBox& bbox, Writer& out)
{
    out.s16(int16_t(glyph.endPoints.size()));
    out.s16(clampToInt16(bbox.xMin));
    out.s16(clampToInt16(bbox.yMin));
    out.s16(clampToInt16(bbox.xMax));
    out.s16(clampToInt16(bbox.yMax));
    for (uint16_t endPoint : glyph.endPoints)
        out.u16(endPoint);
    out.u16(uint16_t(glyph.instructions.size()));
    out.bytes(glyph.instructions.data(), glyph.instructions.size());

    // Flags, then x deltas, then y deltas (no REPEAT compression).
    std::vector<uint8_t> flags(glyph.points.size());
    int32_t previousX = 0, previousY = 0;
    for (size_t i = 0; i < glyph.points.size(); ++i) {
        int32_t dx = glyph.points[i].x - previousX;
        int32_t dy = glyph.points[i].y - previousY;
        previousX = glyph.points[i].x;
        previousY = glyph.points[i].y;
        uint8_t flag = glyph.points[i].flags & (onCurveFlag | overlapSimpleFlag);
        if (!dx)
            flag |= xSameOrPositiveFlag;
        else if (dx >= -255 && dx <= 255) {
            flag |= xShortFlag;
            if (dx > 0)
                flag |= xSameOrPositiveFlag;
        }
        if (!dy)
            flag |= ySameOrPositiveFlag;
        else if (dy >= -255 && dy <= 255) {
            flag |= yShortFlag;
            if (dy > 0)
                flag |= ySameOrPositiveFlag;
        }
        flags[i] = flag;
    }
    out.bytes(flags.data(), flags.size());
    previousX = 0;
    for (size_t i = 0; i < glyph.points.size(); ++i) {
        int32_t dx = glyph.points[i].x - previousX;
        previousX = glyph.points[i].x;
        if (flags[i] & xShortFlag)
            out.u8(uint8_t(std::abs(dx)));
        else if (!(flags[i] & xSameOrPositiveFlag))
            out.s16(int16_t(dx));
    }
    previousY = 0;
    for (size_t i = 0; i < glyph.points.size(); ++i) {
        int32_t dy = glyph.points[i].y - previousY;
        previousY = glyph.points[i].y;
        if (flags[i] & yShortFlag)
            out.u8(uint8_t(std::abs(dy)));
        else if (!(flags[i] & ySameOrPositiveFlag))
            out.s16(int16_t(dy));
    }
}

static void encodeCompositeGlyph(const DecodedGlyph& glyph, const BBox& bbox, Writer& out)
{
    out.s16(-1);
    out.s16(clampToInt16(bbox.xMin));
    out.s16(clampToInt16(bbox.yMin));
    out.s16(clampToInt16(bbox.xMax));
    out.s16(clampToInt16(bbox.yMax));
    for (const auto& component : glyph.components) {
        uint16_t flags = component.flags;
        bool argsAreXY = flags & argsAreXYValuesFlag;
        bool needWords = component.arg1 < -128 || component.arg1 > 127 || component.arg2 < -128 || component.arg2 > 127;
        if (!argsAreXY)
            needWords = component.arg1 > 255 || component.arg2 > 255;
        if (needWords)
            flags |= arg1And2AreWordsFlag;
        out.u16(flags);
        out.u16(component.glyphIndex);
        if (flags & arg1And2AreWordsFlag) {
            out.s16(int16_t(component.arg1));
            out.s16(int16_t(component.arg2));
        } else {
            out.u8(uint8_t(component.arg1));
            out.u8(uint8_t(component.arg2));
        }
        out.bytes(component.transformBytes.data(), component.transformBytes.size());
    }
    out.bytes(glyph.trailingBytes.data(), glyph.trailingBytes.size());
}

// IUP: infer deltas for unreferenced points of one contour, one coordinate axis at a
// time, from the nearest referenced neighbors (cyclically), interpolating by the
// DEFAULT-master coordinate values.
static void interpolateUntouchedPointsInContour(size_t begin, size_t end, const std::vector<GlyphPoint>& points, const std::vector<bool>& referenced, bool xAxis, std::vector<float>& deltas)
{
    std::vector<size_t> anchors;
    for (size_t i = begin; i < end; ++i) {
        if (referenced[i])
            anchors.push_back(i);
    }
    if (anchors.empty()) {
        for (size_t i = begin; i < end; ++i)
            deltas[i] = 0;
        return;
    }
    if (anchors.size() == 1) {
        for (size_t i = begin; i < end; ++i)
            deltas[i] = deltas[anchors[0]];
        return;
    }
    auto coordinate = [&](size_t i) { return float(xAxis ? points[i].x : points[i].y); };
    size_t contourSize = end - begin;
    for (size_t a = 0; a < anchors.size(); ++a) {
        size_t r1 = anchors[a];
        size_t r2 = anchors[(a + 1) % anchors.size()];
        // Walk the (cyclic) gap between r1 and r2.
        for (size_t step = 1;; ++step) {
            size_t i = begin + (r1 - begin + step) % contourSize;
            if (i == r2)
                break;
            float c = coordinate(i);
            float c1 = coordinate(r1);
            float c2 = coordinate(r2);
            float d1 = deltas[r1];
            float d2 = deltas[r2];
            if (c1 == c2) {
                deltas[i] = (d1 == d2) ? d1 : 0;
                continue;
            }
            if (c1 > c2) {
                std::swap(c1, c2);
                std::swap(d1, d2);
            }
            if (c <= c1)
                deltas[i] = d1;
            else if (c >= c2)
                deltas[i] = d2;
            else
                deltas[i] = d1 + (d2 - d1) * (c - c1) / (c2 - c1);
        }
    }
}

struct GvarHeader {
    uint16_t axisCount { 0 };
    uint16_t sharedTupleCount { 0 };
    uint32_t sharedTuplesOffset { 0 };
    uint16_t glyphCount { 0 };
    bool longOffsets { false };
    uint32_t dataArrayOffset { 0 };
    std::vector<uint32_t> offsets;
};

static std::optional<GvarHeader> parseGvarHeader(Reader& gvar, size_t axisCount)
{
    GvarHeader header;
    uint16_t majorVersion = gvar.u16();
    gvar.u16(); // minorVersion
    header.axisCount = gvar.u16();
    header.sharedTupleCount = gvar.u16();
    header.sharedTuplesOffset = gvar.u32();
    header.glyphCount = gvar.u16();
    uint16_t flags = gvar.u16();
    header.dataArrayOffset = gvar.u32();
    if (gvar.failed() || majorVersion != 1 || header.axisCount != axisCount)
        return std::nullopt;
    header.longOffsets = flags & 1;
    header.offsets.reserve(size_t(header.glyphCount) + 1);
    for (uint32_t i = 0; i <= header.glyphCount; ++i)
        header.offsets.push_back(header.longOffsets ? gvar.u32() : uint32_t(gvar.u16()) * 2);
    if (gvar.failed())
        return std::nullopt;
    return header;
}

// Accumulated (dx, dy) for every gvar point (glyph points/components + 4 phantoms) of
// one glyph at the pinned coordinates. Returns false on parse failure.
static bool computeGlyphDeltas(const GvarHeader& gvarHeader, Reader gvarTable, uint16_t glyphID, const DecodedGlyph& glyph, const std::vector<float>& coords, std::vector<float>& totalDX, std::vector<float>& totalDY)
{
    size_t pointCount = glyph.pointCountForGvar() + 4;
    totalDX.assign(pointCount, 0);
    totalDY.assign(pointCount, 0);

    if (glyphID >= gvarHeader.glyphCount)
        return true;
    uint32_t begin = gvarHeader.offsets[glyphID];
    uint32_t end = gvarHeader.offsets[glyphID + 1];
    if (begin > end)
        return false;
    if (begin == end)
        return true;
    Reader data = gvarTable.slice(size_t(gvarHeader.dataArrayOffset) + begin, end - begin);
    if (data.failed())
        return false;

    uint16_t tupleVariationCount = data.u16();
    uint16_t serializedDataOffset = data.u16();
    if (data.failed())
        return false;
    bool hasSharedPoints = tupleVariationCount & 0x8000;
    uint16_t tupleCount = tupleVariationCount & 0x0FFF;

    Reader serialized = data.slice(serializedDataOffset, data.size() - serializedDataOffset);
    if (serialized.failed())
        return false;

    std::vector<uint32_t> sharedPoints;
    bool sharedAllPoints = false;
    if (hasSharedPoints) {
        if (!readPackedPointNumbers(serialized, sharedPoints, sharedAllPoints))
            return false;
    }

    size_t axisCount = coords.size();
    std::vector<float> peaks(axisCount), starts(axisCount), ends(axisCount);
    std::vector<uint32_t> privatePoints;
    std::vector<int32_t> deltasX, deltasY;
    std::vector<float> tupleDX(pointCount), tupleDY(pointCount);
    std::vector<bool> referenced(pointCount);

    for (uint16_t t = 0; t < tupleCount; ++t) {
        uint16_t variationDataSize = data.u16();
        uint16_t tupleIndex = data.u16();
        bool embeddedPeak = tupleIndex & 0x8000;
        bool intermediate = tupleIndex & 0x4000;
        bool privatePointNumbers = tupleIndex & 0x2000;
        uint16_t sharedTupleIndex = tupleIndex & 0x0FFF;

        if (embeddedPeak) {
            for (size_t i = 0; i < axisCount; ++i)
                peaks[i] = data.f2dot14();
        } else {
            if (sharedTupleIndex >= gvarHeader.sharedTupleCount)
                return false;
            Reader sharedTuples = gvarTable.slice(gvarHeader.sharedTuplesOffset + size_t(sharedTupleIndex) * axisCount * 2, axisCount * 2);
            for (size_t i = 0; i < axisCount; ++i)
                peaks[i] = sharedTuples.f2dot14();
            if (sharedTuples.failed())
                return false;
        }
        if (intermediate) {
            for (size_t i = 0; i < axisCount; ++i)
                starts[i] = data.f2dot14();
            for (size_t i = 0; i < axisCount; ++i)
                ends[i] = data.f2dot14();
        }
        if (data.failed())
            return false;

        Reader tupleData = serialized.slice(serialized.position(), variationDataSize);
        serialized.skip(variationDataSize);
        if (tupleData.failed() || serialized.failed())
            return false;

        float scalar = tupleScalar(coords, peaks, intermediate ? &starts : nullptr, intermediate ? &ends : nullptr);
        if (!scalar)
            continue;

        const std::vector<uint32_t>* pointNumbers = &sharedPoints;
        bool allPoints = sharedAllPoints;
        if (privatePointNumbers) {
            if (!readPackedPointNumbers(tupleData, privatePoints, allPoints))
                return false;
            pointNumbers = &privatePoints;
        } else if (!hasSharedPoints) {
            // No shared and no private point numbers: deltas apply to all points.
            allPoints = true;
        }

        size_t deltaCount = allPoints ? pointCount : pointNumbers->size();
        if (!readPackedDeltas(tupleData, deltaCount, deltasX) || !readPackedDeltas(tupleData, deltaCount, deltasY))
            return false;

        std::fill(tupleDX.begin(), tupleDX.end(), 0);
        std::fill(tupleDY.begin(), tupleDY.end(), 0);
        std::fill(referenced.begin(), referenced.end(), false);
        if (allPoints) {
            for (size_t i = 0; i < pointCount; ++i) {
                tupleDX[i] = deltasX[i];
                tupleDY[i] = deltasY[i];
            }
        } else {
            for (size_t i = 0; i < pointNumbers->size(); ++i) {
                uint32_t point = (*pointNumbers)[i];
                if (point >= pointCount)
                    continue; // Out-of-range point numbers are ignored (matches rasterizer behavior).
                tupleDX[point] = deltasX[i];
                tupleDY[point] = deltasY[i];
                referenced[point] = true;
            }
            // IUP inference for unreferenced points, per contour, simple glyphs only.
            if (!glyph.isComposite) {
                size_t contourBegin = 0;
                for (uint16_t endPoint : glyph.endPoints) {
                    size_t contourEnd = size_t(endPoint) + 1;
                    if (contourEnd > glyph.points.size())
                        return false;
                    interpolateUntouchedPointsInContour(contourBegin, contourEnd, glyph.points, referenced, true, tupleDX);
                    interpolateUntouchedPointsInContour(contourBegin, contourEnd, glyph.points, referenced, false, tupleDY);
                    contourBegin = contourEnd;
                }
            }
            // Unreferenced composite-component and phantom points keep delta 0.
        }

        for (size_t i = 0; i < pointCount; ++i) {
            totalDX[i] += scalar * tupleDX[i];
            totalDY[i] += scalar * tupleDY[i];
        }
    }
    return !data.failed();
}

// Variation deltas a GPOS or GDEF table carries in VariationIndex device tables -- variable kerning,
// placement, anchors and ligature carets -- folded into the values they adjust at the instance, with the
// device offsets cleared. A ValueRecord's hinting device tables are cleared too: 10.9 lays a record that
// has one out without any of its value (measured: an A-V kern of -100 with a 20 ppem device applies at no
// size). Every subtable, PairSet, anchor and caret value is folded once, however many records share it.
class LayoutDeltaFolder {
public:
    LayoutDeltaFolder(std::vector<uint8_t>& bytes, const ItemVariationStore& store)
        : m_bytes(bytes)
        , m_store(store)
        , m_visited(bytes.size(), false)
    {
    }

    bool foldGPOS()
    {
        uint16_t lookupListOffset = u16(8);
        if (m_failed || !lookupListOffset)
            return !m_failed;
        size_t lookupList = lookupListOffset;
        uint16_t lookupCount = u16(lookupList);
        for (uint16_t i = 0; i < lookupCount && !m_failed; ++i) {
            size_t lookup = lookupList + u16(lookupList + 2 + size_t(i) * 2);
            uint16_t type = u16(lookup);
            uint16_t subtableCount = u16(lookup + 4);
            for (uint16_t j = 0; j < subtableCount && !m_failed; ++j)
                foldSubtable(type, lookup + u16(lookup + 6 + size_t(j) * 2), 0);
        }
        return !m_failed;
    }

    bool foldGDEF()
    {
        size_t list = u16(8);
        uint16_t ligGlyphCount = list ? u16(list + 2) : 0;
        for (uint16_t i = 0; i < ligGlyphCount && !m_failed; ++i) {
            size_t ligGlyph = list + u16(list + 4 + size_t(i) * 2);
            uint16_t caretCount = u16(ligGlyph);
            for (uint16_t j = 0; j < caretCount && !m_failed; ++j) {
                size_t caret = ligGlyph + u16(ligGlyph + 2 + size_t(j) * 2);
                if (u16(caret) != 3 || !firstVisit(caret))
                    continue;
                // Format 3: coordinate, then a device offset from the caret value.
                foldCoordinate(caret + 2, caret, caret + 4);
            }
        }
        // Every VariationIndex now folded, GDEF's item variation store is referenced by nothing, and its
        // regions name axes the instance no longer has.
        if (!m_failed && u16(2) >= 3) {
            setU16(14, 0);
            setU16(16, 0);
        }
        return !m_failed;
    }

private:
    uint16_t u16(size_t offset)
    {
        if (offset > m_bytes.size() || m_bytes.size() - offset < 2) {
            m_failed = true;
            return 0;
        }
        return uint16_t(m_bytes[offset] << 8 | m_bytes[offset + 1]);
    }

    void setU16(size_t offset, uint16_t value)
    {
        if (offset > m_bytes.size() || m_bytes.size() - offset < 2) {
            m_failed = true;
            return;
        }
        m_bytes[offset] = uint8_t(value >> 8);
        m_bytes[offset + 1] = uint8_t(value);
    }

    // Whether `count` items of `stride` bytes from `start` lie inside the table.
    bool fits(size_t start, uint64_t count, size_t stride)
    {
        if (start > m_bytes.size() || count * stride > m_bytes.size() - start) {
            m_failed = true;
            return false;
        }
        return true;
    }

    bool firstVisit(size_t offset)
    {
        if (offset >= m_visited.size()) {
            m_failed = true;
            return false;
        }
        if (m_visited[offset])
            return false;
        m_visited[offset] = true;
        return true;
    }

    // The delta of the device table at `device`, or nothing when it is not a VariationIndex table.
    std::optional<int32_t> variationDelta(size_t device)
    {
        uint16_t outer = u16(device);
        uint16_t inner = u16(device + 2);
        if (m_failed || u16(device + 4) != 0x8000)
            return std::nullopt;
        auto delta = m_store.delta(uint32_t(outer) << 16 | inner);
        if (!delta) {
            m_failed = true;
            return std::nullopt;
        }
        return int32_t(std::floor(*delta + 0.5));
    }

    void addTo(size_t valueOffset, int32_t delta)
    {
        int32_t value = int16_t(u16(valueOffset)) + delta;
        setU16(valueOffset, uint16_t(clampToInt16(value)));
    }

    // A coordinate at `value` with its device offset at `deviceOffset`, relative to `base`.
    void foldCoordinate(size_t value, size_t base, size_t deviceOffset)
    {
        uint16_t offset = u16(deviceOffset);
        if (m_failed || !offset)
            return;
        if (auto delta = variationDelta(base + offset)) {
            addTo(value, *delta);
            setU16(deviceOffset, 0);
        }
    }

    void foldAnchor(size_t base, uint16_t offset)
    {
        if (!offset)
            return;
        size_t anchor = base + offset;
        if (u16(anchor) != 3 || !firstVisit(anchor))
            return;
        foldCoordinate(anchor + 2, anchor, anchor + 6);
        foldCoordinate(anchor + 4, anchor, anchor + 8);
        // With both devices cleared, the anchor is a format 1 one; its unused device offsets stay behind.
        if (!m_failed && !u16(anchor + 6) && !u16(anchor + 8))
            setU16(anchor, 1);
    }

    static size_t valueRecordSize(uint16_t format)
    {
        size_t fields = 0;
        for (uint16_t bit = 1; bit <= 0x80; bit <<= 1)
            fields += (format & bit) ? 1 : 0;
        return fields * 2;
    }

    // The ValueRecords of one value-format slot of a subtable, each with the table its device offsets
    // are relative to.
    struct ValueRecordRef {
        size_t record;
        size_t parent;
    };

    // Folds the records of one slot and rewrites the subtable's ValueFormat at `formatOffset`. Each device
    // field the format has without its base field becomes that base field, so every record keeps its size;
    // the rule reads the format alone, so subtables sharing PairSets agree on their layout. Only records not
    // folded through another subtable are in `records`.
    void foldValueRecords(size_t formatOffset, const std::vector<ValueRecordRef>& records)
    {
        uint16_t format = u16(formatOffset);
        if (m_failed || !(format & 0xF0))
            return;
        auto fieldPosition = [](uint16_t format, uint16_t bit) {
            size_t index = 0;
            for (uint16_t b = 1; b < bit; b <<= 1)
                index += (format & b) ? 1 : 0;
            return index * 2;
        };
        uint16_t newFormat = format;
        for (uint16_t device = 0x10; device <= 0x80; device <<= 1) {
            uint16_t base = device >> 4;
            if ((format & device) && !(format & base))
                newFormat = uint16_t((newFormat & ~device) | base);
        }
        int32_t values[8];
        for (const auto& ref : records) {
            for (unsigned field = 0; field < 8; ++field) {
                uint16_t bit = uint16_t(1 << field);
                values[field] = (format & bit) ? (field < 4 ? int32_t(int16_t(u16(ref.record + fieldPosition(format, bit)))) : int32_t(u16(ref.record + fieldPosition(format, bit)))) : 0;
            }
            for (unsigned field = 4; field < 8; ++field) {
                if (!values[field])
                    continue;
                if (auto delta = variationDelta(ref.parent + uint32_t(values[field])))
                    values[field - 4] += *delta;
                values[field] = 0;
            }
            for (unsigned field = 0; field < 8; ++field) {
                uint16_t bit = uint16_t(1 << field);
                if (newFormat & bit)
                    setU16(ref.record + fieldPosition(newFormat, bit), uint16_t(field < 4 ? clampToInt16(values[field]) : values[field]));
            }
        }
        setU16(formatOffset, newFormat);
    }

    void foldSubtable(uint16_t type, size_t subtable, int depth)
    {
        if (m_failed || !firstVisit(subtable))
            return;
        uint16_t format = u16(subtable);
        switch (type) {
        case 1: { // SinglePos
            uint16_t valueFormat = u16(subtable + 4);
            size_t size = valueRecordSize(valueFormat);
            std::vector<ValueRecordRef> records;
            if (format == 1)
                records.push_back({ subtable + 6, subtable });
            else if (format == 2) {
                uint16_t count = u16(subtable + 6);
                if (!fits(subtable + 8, count, size))
                    return;
                for (uint16_t i = 0; i < count; ++i)
                    records.push_back({ subtable + 8 + size_t(i) * size, subtable });
            }
            foldValueRecords(subtable + 4, records);
            break;
        }
        case 2: { // PairPos
            uint16_t format1 = u16(subtable + 4);
            uint16_t format2 = u16(subtable + 6);
            size_t size1 = valueRecordSize(format1);
            size_t size2 = valueRecordSize(format2);
            std::vector<ValueRecordRef> first, second;
            if (format == 1) {
                uint16_t pairSetCount = u16(subtable + 8);
                for (uint16_t i = 0; i < pairSetCount && !m_failed; ++i) {
                    size_t pairSet = subtable + u16(subtable + 10 + size_t(i) * 2);
                    if (!firstVisit(pairSet))
                        continue;
                    uint16_t pairCount = u16(pairSet);
                    if (!fits(pairSet + 2, pairCount, 2 + size1 + size2))
                        return;
                    for (uint16_t j = 0; j < pairCount; ++j) {
                        size_t record = pairSet + 2 + size_t(j) * (2 + size1 + size2);
                        first.push_back({ record + 2, pairSet });
                        second.push_back({ record + 2 + size1, pairSet });
                    }
                }
            } else if (format == 2) {
                uint16_t class1Count = u16(subtable + 12);
                uint16_t class2Count = u16(subtable + 14);
                if (!fits(subtable + 16, uint64_t(class1Count) * class2Count, size1 + size2))
                    return;
                for (uint32_t i = 0; i < uint32_t(class1Count) * class2Count; ++i) {
                    size_t record = subtable + 16 + size_t(i) * (size1 + size2);
                    first.push_back({ record, subtable });
                    second.push_back({ record + size1, subtable });
                }
            }
            foldValueRecords(subtable + 4, first);
            foldValueRecords(subtable + 6, second);
            break;
        }
        case 3: { // CursivePos
            uint16_t count = u16(subtable + 4);
            for (uint16_t i = 0; i < count && !m_failed; ++i) {
                foldAnchor(subtable, u16(subtable + 6 + size_t(i) * 4));
                foldAnchor(subtable, u16(subtable + 8 + size_t(i) * 4));
            }
            break;
        }
        case 4: // MarkBasePos
        case 6: { // MarkMarkPos
            uint16_t classCount = u16(subtable + 6);
            foldMarkArray(subtable + u16(subtable + 8));
            size_t array = subtable + u16(subtable + 10);
            uint16_t count = u16(array);
            if (!fits(array + 2, uint64_t(count) * classCount, 2))
                return;
            for (uint32_t i = 0; i < uint32_t(count) * classCount && !m_failed; ++i)
                foldAnchor(array, u16(array + 2 + size_t(i) * 2));
            break;
        }
        case 5: { // MarkLigPos
            uint16_t classCount = u16(subtable + 6);
            foldMarkArray(subtable + u16(subtable + 8));
            size_t ligatureArray = subtable + u16(subtable + 10);
            uint16_t ligatureCount = u16(ligatureArray);
            for (uint16_t i = 0; i < ligatureCount && !m_failed; ++i) {
                size_t attach = ligatureArray + u16(ligatureArray + 2 + size_t(i) * 2);
                uint16_t componentCount = u16(attach);
                if (!fits(attach + 2, uint64_t(componentCount) * classCount, 2))
                    return;
                for (uint32_t j = 0; j < uint32_t(componentCount) * classCount && !m_failed; ++j)
                    foldAnchor(attach, u16(attach + 2 + size_t(j) * 2));
            }
            break;
        }
        case 9: // Extension
            if (format == 1 && depth < 1) {
                uint16_t extensionType = u16(subtable + 2);
                uint32_t offset = uint32_t(u16(subtable + 4)) << 16 | u16(subtable + 6);
                if (extensionType != 9)
                    foldSubtable(extensionType, subtable + offset, depth + 1);
            }
            break;
        default:
            break;
        }
    }

    void foldMarkArray(size_t array)
    {
        uint16_t count = u16(array);
        for (uint16_t i = 0; i < count && !m_failed; ++i)
            foldAnchor(array, u16(array + 4 + size_t(i) * 4));
    }

    std::vector<uint8_t>& m_bytes;
    const ItemVariationStore& m_store;
    std::vector<bool> m_visited;
    bool m_failed { false };
};

// A GSUB, GPOS or GDEF table at the instance: FeatureVariations resolved, and the VariationIndex deltas
// GDEF's item variation store holds folded into GPOS values and GDEF caret values.
static bool instanceLayoutTable(const ParsedSfnt& sfnt, uint32_t tag, std::vector<uint8_t>& bytes, const std::vector<float>& coords)
{
    constexpr uint32_t gsubTag = tagFor('G', 'S', 'U', 'B');
    constexpr uint32_t gposTag = tagFor('G', 'P', 'O', 'S');
    constexpr uint32_t gdefTag = tagFor('G', 'D', 'E', 'F');
    if ((tag == gsubTag || tag == gposTag) && !instanceLayoutFeatures(bytes, coords))
        return false;
    if ((tag != gposTag && tag != gdefTag) || !sfnt.find(gdefTag))
        return true;
    Reader gdef = sfnt.tableReader(gdefTag);
    uint32_t version = gdef.u32();
    if (gdef.failed() || version < 0x00010003)
        return true;
    gdef.seek(14);
    uint32_t storeOffset = gdef.u32();
    if (gdef.failed() || storeOffset > gdef.size())
        return false;
    if (!storeOffset)
        return true;
    ItemVariationStore store(gdef.slice(storeOffset, gdef.size() - storeOffset));
    std::vector<float> at = coords;
    if (at.empty()) {
        auto axisCount = store.axisCount();
        if (!axisCount)
            return false;
        at.assign(*axisCount, 0);
    }
    if (!store.initialize(at))
        return false;
    LayoutDeltaFolder folder(bytes, store);
    return tag == gposTag ? folder.foldGPOS() : folder.foldGDEF();
}

// Reflects a pinned instance in OS/2's weight and width classes, so font traits match the outlines.
static void applyPinnedClasses(std::vector<uint8_t>& os2, const std::vector<LegacyVariableFontAxis>& axes, const std::vector<double>& pinnedDesignValues)
{
    if (os2.size() < 8)
        return;
    auto writeBE16At = [&](size_t offset, uint16_t v) {
        os2[offset] = uint8_t(v >> 8);
        os2[offset + 1] = uint8_t(v);
    };
    for (size_t i = 0; i < axes.size() && i < pinnedDesignValues.size(); ++i) {
        if (axes[i].tag == tagFor('w', 'g', 'h', 't'))
            writeBE16At(4, uint16_t(std::min(1000.0, std::max(1.0, pinnedDesignValues[i]))));
        else if (axes[i].tag == tagFor('w', 'd', 't', 'h')) {
            static constexpr float widthClassPercentages[] = { 50, 62.5, 75, 87.5, 100, 112.5, 125, 150, 200 };
            uint16_t widthClass = 5;
            float best = 1e9;
            for (uint16_t c = 0; c < 9; ++c) {
                float distance = std::abs(pinnedDesignValues[i] - widthClassPercentages[c]);
                if (distance < best) {
                    best = distance;
                    widthClass = c + 1;
                }
            }
            writeBE16At(6, widthClass);
        }
    }
}

struct InstancedGlyph {
    std::vector<uint8_t> bytes;
    BBox bbox;
    int32_t advanceDelta { 0 };
    int32_t leftPhantomDelta { 0 };
    int32_t oldXMin { 0 };
    bool isComposite { false };
    std::vector<CompositeComponent> components; // For composite bbox resolution.
};

// The full instancing pipeline. Kept as a class so intermediate state (tables,
// glyphs) is shared between phases.
class Instancer {
public:
    Instancer(const ParsedSfnt& sfnt)
        : m_sfnt(sfnt)
    {
    }

    CFDataRef instance(const std::vector<std::pair<uint32_t, double>>& pinnedAxisValues);

private:
    bool parseMetricsTables();
    bool computeNormalizedCoords(const std::vector<std::pair<uint32_t, double>>& pinnedAxisValues);
    bool instanceAllGlyphs();
    void resolveCompositeBBox(uint16_t glyphID, int depth);
    CFDataRef assemble();

    const ParsedSfnt& m_sfnt;
    std::vector<LegacyVariableFontAxis> m_axes;
    std::vector<float> m_coords;
    std::vector<double> m_pinnedDesignValues;
    uint16_t m_numGlyphs { 0 };
    uint16_t m_numberOfHMetrics { 0 };
    bool m_lsbIsXMin { false };
    std::vector<uint32_t> m_loca;
    std::vector<uint16_t> m_advances;
    std::vector<int16_t> m_leftSideBearings;
    std::vector<InstancedGlyph> m_glyphs;
    std::vector<bool> m_bboxResolved;
};

bool Instancer::parseMetricsTables()
{
    Reader head = m_sfnt.tableReader(headTag);
    head.seek(16);
    uint16_t headFlags = head.u16();
    head.seek(50);
    uint16_t indexToLocFormat = head.u16();
    if (head.failed() || indexToLocFormat > 1)
        return false;
    m_lsbIsXMin = headFlags & 0x2;

    Reader maxp = m_sfnt.tableReader(maxpTag);
    maxp.seek(4);
    m_numGlyphs = maxp.u16();
    if (maxp.failed())
        return false;

    Reader hhea = m_sfnt.tableReader(hheaTag);
    hhea.seek(34);
    m_numberOfHMetrics = hhea.u16();
    if (hhea.failed() || !m_numberOfHMetrics || m_numberOfHMetrics > m_numGlyphs)
        return false;

    Reader loca = m_sfnt.tableReader(locaTag);
    m_loca.reserve(size_t(m_numGlyphs) + 1);
    for (uint32_t i = 0; i <= m_numGlyphs; ++i)
        m_loca.push_back(indexToLocFormat ? loca.u32() : uint32_t(loca.u16()) * 2);
    if (loca.failed())
        return false;
    for (size_t i = 1; i < m_loca.size(); ++i) {
        if (m_loca[i] < m_loca[i - 1])
            return false;
    }

    Reader hmtx = m_sfnt.tableReader(hmtxTag);
    m_advances.reserve(m_numGlyphs);
    m_leftSideBearings.reserve(m_numGlyphs);
    uint16_t lastAdvance = 0;
    for (uint32_t i = 0; i < m_numGlyphs; ++i) {
        if (i < m_numberOfHMetrics) {
            lastAdvance = hmtx.u16();
            m_advances.push_back(lastAdvance);
            m_leftSideBearings.push_back(hmtx.s16());
        } else {
            m_advances.push_back(lastAdvance);
            m_leftSideBearings.push_back(hmtx.s16());
        }
    }
    return !hmtx.failed();
}

bool Instancer::computeNormalizedCoords(const std::vector<std::pair<uint32_t, double>>& pinnedAxisValues)
{
    m_axes = parseFvarAxes(m_sfnt);
    if (m_axes.empty())
        return false;
    m_coords.resize(m_axes.size());
    m_pinnedDesignValues.resize(m_axes.size());
    for (size_t i = 0; i < m_axes.size(); ++i) {
        const auto& axis = m_axes[i];
        double value = axis.defaultValue;
        for (const auto& [tag, pinnedValue] : pinnedAxisValues) {
            if (tag == axis.tag) {
                value = pinnedValue;
                break;
            }
        }
        value = std::min(axis.maximumValue, std::max(axis.minimumValue, value));
        m_pinnedDesignValues[i] = value;
        m_coords[i] = normalizedFixed(axis, value) / 65536.0f;
    }
    return applyAvar(m_sfnt, m_coords);
}

bool Instancer::instanceAllGlyphs()
{
    Reader gvarTable = m_sfnt.tableReader(gvarTag);
    Reader gvarForHeader = gvarTable;
    auto gvarHeader = parseGvarHeader(gvarForHeader, m_coords.size());
    if (!gvarHeader)
        return false;

    Reader glyfTable = m_sfnt.tableReader(glyfTag);
    if (glyfTable.failed())
        return false;

    m_glyphs.resize(m_numGlyphs);
    std::vector<float> totalDX, totalDY;
    uint64_t encodedBytesTotal = 0;
    for (uint16_t glyphID = 0; glyphID < m_numGlyphs; ++glyphID) {
        InstancedGlyph& out = m_glyphs[glyphID];
        uint32_t begin = m_loca[glyphID];
        uint32_t end = m_loca[glyphID + 1];
        if (end > glyfTable.size())
            return false;
        if (begin == end) {
            // Empty glyph (e.g. space): only phantom deltas can apply.
            DecodedGlyph empty;
            if (!computeGlyphDeltas(*gvarHeader, gvarTable, glyphID, empty, m_coords, totalDX, totalDY))
                return false;
            out.leftPhantomDelta = int32_t(std::lround(totalDX[0]));
            out.advanceDelta = int32_t(std::lround(totalDX[1] - totalDX[0]));
            continue;
        }

        Reader glyphReader = glyfTable.slice(begin, end - begin);
        Reader headerReader = glyphReader;
        headerReader.skip(2);
        out.oldXMin = headerReader.s16();
        int16_t numberOfContours = 0;
        auto decoded = decodeGlyph(glyphReader, numberOfContours);
        if (!decoded)
            return false;

        if (!computeGlyphDeltas(*gvarHeader, gvarTable, glyphID, *decoded, m_coords, totalDX, totalDY))
            return false;

        size_t basePointCount = decoded->pointCountForGvar();
        out.leftPhantomDelta = int32_t(std::lround(totalDX[basePointCount]));
        out.advanceDelta = int32_t(std::lround(totalDX[basePointCount + 1] - totalDX[basePointCount]));

        Writer encoded;
        if (!decoded->isComposite) {
            for (size_t i = 0; i < decoded->points.size(); ++i) {
                decoded->points[i].x = int32_t(std::lround(decoded->points[i].x + totalDX[i]));
                decoded->points[i].y = int32_t(std::lround(decoded->points[i].y + totalDY[i]));
            }
            for (const auto& point : decoded->points)
                out.bbox.add(point.x, point.y);
            encodeSimpleGlyph(*decoded, out.bbox, encoded);
            out.bytes = std::move(encoded.vector());
        } else {
            for (size_t i = 0; i < decoded->components.size(); ++i) {
                if (decoded->components[i].flags & argsAreXYValuesFlag) {
                    decoded->components[i].arg1 = int32_t(std::lround(decoded->components[i].arg1 + totalDX[i]));
                    decoded->components[i].arg2 = int32_t(std::lround(decoded->components[i].arg2 + totalDY[i]));
                }
            }
            out.isComposite = true;
            out.components = decoded->components;
            // The bbox is resolved after all simple glyphs are instanced; encode then.
            // Stash the encodable state.
            Writer placeholder;
            encodeCompositeGlyph(*decoded, out.bbox, placeholder);
            out.bytes = std::move(placeholder.vector());
        }
        encodedBytesTotal += out.bytes.size();
        if (encodedBytesTotal > maximumAssembledFontSize)
            return false;
    }

    // Resolve composite bounding boxes now that all simple glyphs have final outlines,
    // then patch the already-encoded composite headers.
    m_bboxResolved.assign(m_numGlyphs, false);
    for (uint16_t glyphID = 0; glyphID < m_numGlyphs; ++glyphID)
        resolveCompositeBBox(glyphID, 0);
    for (uint16_t glyphID = 0; glyphID < m_numGlyphs; ++glyphID) {
        InstancedGlyph& glyph = m_glyphs[glyphID];
        if (!glyph.isComposite || glyph.bytes.size() < 10)
            continue;
        auto writeBE16At = [&](size_t offset, int16_t v) {
            glyph.bytes[offset] = uint8_t(uint16_t(v) >> 8);
            glyph.bytes[offset + 1] = uint8_t(uint16_t(v));
        };
        writeBE16At(2, clampToInt16(glyph.bbox.xMin));
        writeBE16At(4, clampToInt16(glyph.bbox.yMin));
        writeBE16At(6, clampToInt16(glyph.bbox.xMax));
        writeBE16At(8, clampToInt16(glyph.bbox.yMax));
    }
    return true;
}

void Instancer::resolveCompositeBBox(uint16_t glyphID, int depth)
{
    if (glyphID >= m_numGlyphs || m_bboxResolved[glyphID] || depth > 8)
        return;
    m_bboxResolved[glyphID] = true;
    InstancedGlyph& glyph = m_glyphs[glyphID];
    if (!glyph.isComposite)
        return;
    BBox bbox;
    for (const auto& component : glyph.components) {
        if (component.glyphIndex >= m_numGlyphs)
            continue;
        resolveCompositeBBox(component.glyphIndex, depth + 1);
        const InstancedGlyph& child = m_glyphs[component.glyphIndex];
        if (!child.bbox.valid)
            continue;
        if (!(component.flags & argsAreXYValuesFlag)) {
            // Point-matching placement: fall back to the untransformed child bbox.
            bbox.add(child.bbox.xMin, child.bbox.yMin);
            bbox.add(child.bbox.xMax, child.bbox.yMax);
            continue;
        }
        float corners[4][2] = {
            { float(child.bbox.xMin), float(child.bbox.yMin) },
            { float(child.bbox.xMin), float(child.bbox.yMax) },
            { float(child.bbox.xMax), float(child.bbox.yMin) },
            { float(child.bbox.xMax), float(child.bbox.yMax) },
        };
        for (auto& corner : corners) {
            float x = component.xx * corner[0] + component.yx * corner[1] + component.arg1;
            float y = component.xy * corner[0] + component.yy * corner[1] + component.arg2;
            bbox.add(x, y);
        }
    }
    glyph.bbox = bbox;
}

CFDataRef Instancer::assemble()
{
    std::map<uint32_t, double> globalDeltas;
    if (!metricVariations(m_sfnt, m_coords, globalDeltas))
        return nullptr;

    // glyf + loca (always long offsets).
    Writer glyf;
    Writer loca;
    for (uint16_t glyphID = 0; glyphID < m_numGlyphs; ++glyphID) {
        loca.u32(uint32_t(glyf.size()));
        glyf.bytes(m_glyphs[glyphID].bytes.data(), m_glyphs[glyphID].bytes.size());
        glyf.padTo4();
    }
    loca.u32(uint32_t(glyf.size()));

    // hmtx: full advance+lsb pairs for every glyph.
    Writer hmtx;
    BBox fontBBox;
    int32_t advanceWidthMax = 0;
    int32_t minLeftSideBearing = 32767, minRightSideBearing = 32767, xMaxExtent = -32768;
    bool anyContours = false;
    for (uint16_t glyphID = 0; glyphID < m_numGlyphs; ++glyphID) {
        const InstancedGlyph& glyph = m_glyphs[glyphID];
        int32_t advance = std::max<int32_t>(0, int32_t(m_advances[glyphID]) + glyph.advanceDelta);
        advance = std::min<int32_t>(advance, 65535);
        int32_t leftSideBearing;
        if (glyph.bbox.valid) {
            if (m_lsbIsXMin)
                leftSideBearing = glyph.bbox.xMin;
            else {
                // lsb' = xMin' - pp1'.x, where pp1 = (xMin - lsb, 0) moved by the left phantom delta.
                leftSideBearing = glyph.bbox.xMin - (glyph.oldXMin - int32_t(m_leftSideBearings[glyphID]) + glyph.leftPhantomDelta);
            }
            fontBBox.add(glyph.bbox.xMin, glyph.bbox.yMin);
            fontBBox.add(glyph.bbox.xMax, glyph.bbox.yMax);
            anyContours = true;
            advanceWidthMax = std::max(advanceWidthMax, advance);
            minLeftSideBearing = std::min(minLeftSideBearing, leftSideBearing);
            minRightSideBearing = std::min(minRightSideBearing, advance - leftSideBearing - (glyph.bbox.xMax - glyph.bbox.xMin));
            xMaxExtent = std::max(xMaxExtent, leftSideBearing + (glyph.bbox.xMax - glyph.bbox.xMin));
        } else {
            leftSideBearing = m_leftSideBearings[glyphID];
            advanceWidthMax = std::max(advanceWidthMax, advance);
        }
        hmtx.u16(uint16_t(advance));
        hmtx.s16(clampToInt16(leftSideBearing));
    }

    Reader os2Metrics = m_sfnt.tableReader(tagFor('O', 'S', '/', '2'));
    Reader hheaMetrics = m_sfnt.tableReader(hheaTag);
    const uint8_t* typo = os2Metrics.bytesAt(68, 6);
    const uint8_t* horizontal = hheaMetrics.bytesAt(4, 6);
    bool synchronizeVerticalMetrics = typo && horizontal && !std::memcmp(typo, horizontal, 6);

    std::vector<std::pair<uint32_t, std::vector<uint8_t>>> outTables;
    for (const auto& table : m_sfnt.tables) {
        if (isVariationTableTag(table.tag) || table.tag == tagFor('D', 'S', 'I', 'G'))
            continue;
        const uint8_t* bytes = m_sfnt.whole.bytesAt(table.offset, table.length);
        if (!bytes)
            return nullptr;
        std::vector<uint8_t> copy(bytes, bytes + table.length);
        switch (table.tag) {
        case glyfTag:
            copy = glyf.vector();
            break;
        case locaTag:
            copy = loca.vector();
            break;
        case hmtxTag:
            copy = hmtx.vector();
            break;
        case headTag: {
            if (copy.size() < 54)
                return nullptr;
            auto writeBE16At = [&](size_t offset, int16_t v) {
                copy[offset] = uint8_t(uint16_t(v) >> 8);
                copy[offset + 1] = uint8_t(uint16_t(v));
            };
            if (anyContours) {
                writeBE16At(36, clampToInt16(fontBBox.xMin));
                writeBE16At(38, clampToInt16(fontBBox.yMin));
                writeBE16At(40, clampToInt16(fontBBox.xMax));
                writeBE16At(42, clampToInt16(fontBBox.yMax));
            }
            writeBE16At(50, 1); // indexToLocFormat: long
            break;
        }
        case hheaTag: {
            if (copy.size() < 36)
                return nullptr;
            auto writeBE16At = [&](size_t offset, int16_t v) {
                copy[offset] = uint8_t(uint16_t(v) >> 8);
                copy[offset + 1] = uint8_t(uint16_t(v));
            };
            writeBE16At(10, int16_t(uint16_t(std::min<int32_t>(advanceWidthMax, 65535))));
            if (anyContours) {
                writeBE16At(12, clampToInt16(minLeftSideBearing));
                writeBE16At(14, clampToInt16(minRightSideBearing));
                writeBE16At(16, clampToInt16(xMaxExtent));
            }
            writeBE16At(34, int16_t(m_numGlyphs));
            if (synchronizeVerticalMetrics) {
                const uint32_t tags[] = { tagFor('h', 'a', 's', 'c'), tagFor('h', 'd', 's', 'c'), tagFor('h', 'l', 'g', 'p') };
                for (size_t i = 0; i < 3; ++i) {
                    auto delta = globalDeltas.find(tags[i]);
                    if (delta == globalDeltas.end())
                        continue;
                    int16_t original = int16_t((uint16_t(copy[4 + 2 * i]) << 8) | copy[5 + 2 * i]);
                    double value = original + std::floor(delta->second + 0.5);
                    if (value < -32768 || value > 32767)
                        return nullptr;
                    writeBE16At(4 + 2 * i, int16_t(value));
                }
            }
            break;
        }
        default:
            if (table.tag == tagFor('O', 'S', '/', '2'))
                applyPinnedClasses(copy, m_axes, m_pinnedDesignValues);
            break;
        }
        if (!instanceLayoutTable(m_sfnt, table.tag, copy, m_coords) || !applyMetricVariations(table.tag, copy, globalDeltas))
            return nullptr;
        outTables.emplace_back(table.tag, std::move(copy));
    }
    return assembleSfnt(m_sfnt.sfntVersion, outTables);
}

CFDataRef Instancer::instance(const std::vector<std::pair<uint32_t, double>>& pinnedAxisValues)
{
    if (!m_sfnt.find(gvarTag) || !m_sfnt.find(glyfTag))
        return nullptr;
    if (!parseMetricsTables())
        return nullptr;
    if (!computeNormalizedCoords(pinnedAxisValues))
        return nullptr;
    if (!instanceAllGlyphs())
        return nullptr;
    return assemble();
}

// The name-table record 10.9's CoreText reads for `nameID`: Macintosh Roman, English first, then
// Unicode, then Windows Unicode, US English first.
static CFStringRef copyNameRecord(const ParsedSfnt& sfnt, uint16_t nameID)
{
    constexpr uint32_t nameTag = tagFor('n', 'a', 'm', 'e');
    if (!sfnt.find(nameTag))
        return nullptr;
    Reader name = sfnt.tableReader(nameTag);
    name.u16(); // version
    uint16_t count = name.u16();
    uint16_t storageOffset = name.u16();
    int bestRank = 5;
    uint16_t bestPlatform = 0;
    size_t bestOffset = 0;
    size_t bestLength = 0;
    for (uint16_t i = 0; i < count && !name.failed(); ++i) {
        uint16_t platformID = name.u16();
        uint16_t encodingID = name.u16();
        uint16_t languageID = name.u16();
        uint16_t recordNameID = name.u16();
        uint16_t length = name.u16();
        uint16_t offset = name.u16();
        if (name.failed() || recordNameID != nameID)
            continue;
        int rank;
        if (platformID == 1 && !encodingID)
            rank = languageID ? 1 : 0;
        else if (!platformID)
            rank = 2;
        else if (platformID == 3 && (encodingID == 1 || encodingID == 10))
            rank = languageID == 0x409 ? 3 : 4;
        else
            continue;
        if (rank < bestRank) {
            bestRank = rank;
            bestPlatform = platformID;
            bestOffset = offset;
            bestLength = length;
        }
    }
    if (bestRank == 5)
        return nullptr;
    const uint8_t* bytes = name.bytesAt(size_t(storageOffset) + bestOffset, bestLength);
    if (!bytes)
        return nullptr;
    return CFStringCreateWithBytes(kCFAllocatorDefault, bytes, CFIndex(bestLength),
        bestPlatform == 1 ? kCFStringEncodingMacRoman : kCFStringEncodingUTF16BE, false);
}

// CFF2, the OpenType 1.8 outline table, variable or not. 10.9's CoreGraphics reads CFF (version 1)
// outlines only, so a font with a CFF2 table is rewritten as one with a CID-keyed CFF table at a
// pinned instance. Every charstring runs with its blends resolved at the instance's region scalars and
// its subroutines inlined, and is re-encoded as a Type 2 charstring of moveto/lineto/curveto segments
// on whole-unit points; stem hints and hint masks are not carried. Private DICT blends resolve the same
// way. HVAR, VVAR and MVAR vary the metrics tables, as gvar's phantom points and MVAR do for glyf.

constexpr uint32_t cff2Tag = tagFor('C', 'F', 'F', '2');
constexpr uint32_t cffTag = tagFor('C', 'F', 'F', ' ');
constexpr uint32_t hvarTag = tagFor('H', 'V', 'A', 'R');
constexpr uint32_t vvarTag = tagFor('V', 'V', 'A', 'R');
constexpr uint32_t vheaTag = tagFor('v', 'h', 'e', 'a');
constexpr uint32_t vmtxTag = tagFor('v', 'm', 't', 'x');
constexpr uint32_t vorgTag = tagFor('V', 'O', 'R', 'G');
constexpr uint32_t os2Tag = tagFor('O', 'S', '/', '2');

// The CFF2 Top DICT and Private DICT operators read here; escaped operators are 0x0c00 | the second byte.
constexpr uint16_t charStringsOperator = 17;
constexpr uint16_t privateOperator = 18;
constexpr uint16_t subrsOperator = 19;
constexpr uint16_t vsindexOperator = 22;
constexpr uint16_t blendOperator = 23;
constexpr uint16_t vstoreOperator = 24;
constexpr uint16_t fontMatrixOperator = 0x0c07;
constexpr uint16_t fdArrayOperator = 0x0c24;
constexpr uint16_t fdSelectOperator = 0x0c25;

// The CFF2 limits: the argument stack, and the nesting of subroutine calls.
constexpr size_t maximumCFF2StackDepth = 513;
constexpr int maximumSubroutineDepth = 10;
// Inlining subroutines can multiply a short charstring's work; one glyph runs at most this many
// operators and draws at most this many segments.
constexpr uint64_t maximumCharstringOperations = 1 << 20;
constexpr size_t maximumGlyphSegments = 1 << 16;

// A CFF2 INDEX: a 32-bit count, an offset size, count + 1 one-based offsets, then the data.
class CFF2Index {
public:
    bool parse(Reader table, size_t offset, size_t& end)
    {
        if (offset > table.size())
            return false;
        Reader index = table.slice(offset, table.size() - offset);
        m_count = index.u32();
        if (index.failed())
            return false;
        if (!m_count) {
            end = offset + 4;
            return true;
        }
        uint8_t offSize = index.u8();
        if (index.failed() || offSize < 1 || offSize > 4)
            return false;
        uint64_t offsetsLength = (uint64_t(m_count) + 1) * offSize;
        if (offsetsLength > index.size())
            return false;
        m_offsets.resize(size_t(m_count) + 1);
        for (auto& value : m_offsets) {
            uint32_t read = 0;
            for (uint8_t b = 0; b < offSize; ++b)
                read = (read << 8) | index.u8();
            value = read;
        }
        if (index.failed() || m_offsets[0] != 1)
            return false;
        for (size_t i = 1; i < m_offsets.size(); ++i) {
            if (m_offsets[i] < m_offsets[i - 1])
                return false;
        }
        size_t dataStart = 5 + size_t(offsetsLength);
        uint64_t dataLength = uint64_t(m_offsets.back()) - 1;
        if (dataStart > index.size() || dataLength > index.size() - dataStart)
            return false;
        m_data = index.slice(dataStart, size_t(dataLength));
        end = offset + dataStart + size_t(dataLength);
        return true;
    }

    uint32_t count() const { return m_count; }
    Reader item(uint32_t i) const { return m_data.slice(m_offsets[i] - 1, m_offsets[i + 1] - m_offsets[i]); }

private:
    uint32_t m_count { 0 };
    std::vector<uint32_t> m_offsets;
    Reader m_data { nullptr, 0 };
};

// The region scalars a blend weights its deltas by: those of the regions the ItemVariationData its
// vsindex selects names. One ItemVariationData's region list is read at a time.
class BlendScalars {
public:
    explicit BlendScalars(const ItemVariationStore* store)
        : m_store(store)
    {
    }

    const std::vector<float>* forIndex(uint32_t vsindex)
    {
        if (!m_store)
            return nullptr;
        if (!m_read || vsindex != m_vsindex) {
            m_read = true;
            m_vsindex = vsindex;
            m_valid = m_store->dataScalars(vsindex, m_scalars);
        }
        return m_valid ? &m_scalars : nullptr;
    }

private:
    const ItemVariationStore* m_store;
    std::vector<float> m_scalars;
    uint32_t m_vsindex { 0 };
    bool m_read { false };
    bool m_valid { false };
};

// Resolves a blend on `stack`: n default values, then k deltas for each of them, then n itself.
static bool resolveBlend(std::vector<double>& stack, BlendScalars* blend, uint32_t vsindex)
{
    const std::vector<float>* scalars = blend ? blend->forIndex(vsindex) : nullptr;
    if (!scalars || stack.empty())
        return false;
    double count = stack.back();
    stack.pop_back();
    size_t k = scalars->size();
    if (count < 0 || count != std::floor(count) || count > stack.size())
        return false;
    size_t n = size_t(count);
    if (n * (k + 1) > stack.size())
        return false;
    size_t base = stack.size() - n * (k + 1);
    for (size_t i = 0; i < n; ++i) {
        double value = stack[base + i];
        for (size_t j = 0; j < k; ++j)
            value += double((*scalars)[j]) * stack[base + n + i * k + j];
        stack[base + i] = value;
    }
    stack.resize(base + n);
    return true;
}

// A DICT real: packed decimal nibbles, terminated by 0xf.
static bool readDictReal(Reader& dict, double& value)
{
    double mantissa = 0;
    int fractionDigits = 0;
    bool inFraction = false;
    bool negative = false;
    int exponent = 0;
    int exponentSign = 0;
    bool done = false;
    while (!done) {
        uint8_t byte = dict.u8();
        if (dict.failed())
            return false;
        for (int half = 0; half < 2 && !done; ++half) {
            uint8_t nibble = half ? (byte & 0xf) : (byte >> 4);
            if (nibble <= 9) {
                if (exponentSign) {
                    if (exponent > 1000)
                        return false;
                    exponent = exponent * 10 + nibble;
                } else {
                    mantissa = mantissa * 10 + nibble;
                    if (inFraction)
                        ++fractionDigits;
                }
            } else if (nibble == 0xa)
                inFraction = true;
            else if (nibble == 0xb)
                exponentSign = 1;
            else if (nibble == 0xc)
                exponentSign = -1;
            else if (nibble == 0xe)
                negative = true;
            else if (nibble == 0xf)
                done = true;
            else
                return false;
        }
    }
    value = mantissa * std::pow(10.0, double(exponentSign * exponent - fractionDigits));
    if (negative)
        value = -value;
    return std::isfinite(value);
}

struct DictEntry {
    uint16_t op { 0 };
    std::vector<double> operands;
};

// Reads a DICT into its entries, resolving blends with `blend` (null where none may appear). A
// vsindex entry is kept, since a Private DICT's vsindex is its charstrings' default as well.
static bool parseDict(Reader dict, BlendScalars* blend, std::vector<DictEntry>& entries)
{
    std::vector<double> operands;
    uint32_t vsindex = 0;
    while (dict.position() < dict.size()) {
        uint8_t b0 = dict.u8();
        if (b0 == 28)
            operands.push_back(dict.s16());
        else if (b0 == 29)
            operands.push_back(dict.s32());
        else if (b0 == 30) {
            double real = 0;
            if (!readDictReal(dict, real))
                return false;
            operands.push_back(real);
        } else if (b0 >= 32 && b0 <= 246)
            operands.push_back(int(b0) - 139);
        else if (b0 >= 247 && b0 <= 250)
            operands.push_back((int(b0) - 247) * 256 + dict.u8() + 108);
        else if (b0 >= 251 && b0 <= 254)
            operands.push_back(-(int(b0) - 251) * 256 - dict.u8() - 108);
        else if (b0 <= 27) {
            uint16_t op = b0 == 12 ? uint16_t(0x0c00 | dict.u8()) : b0;
            if (op == blendOperator) {
                if (!resolveBlend(operands, blend, vsindex))
                    return false;
                continue;
            }
            if (op == vsindexOperator) {
                if (operands.size() != 1 || operands[0] < 0 || operands[0] > 65535)
                    return false;
                vsindex = uint32_t(operands[0]);
            }
            entries.push_back({ op, operands });
            operands.clear();
        } else
            return false;
        if (dict.failed() || operands.size() > maximumCFF2StackDepth)
            return false;
    }
    return operands.empty();
}

static const DictEntry* findDictEntry(const std::vector<DictEntry>& entries, uint16_t op)
{
    for (const auto& entry : entries) {
        if (entry.op == op)
            return &entry;
    }
    return nullptr;
}

static bool dictOffset(const DictEntry* entry, size_t index, size_t& value)
{
    if (!entry || index >= entry->operands.size())
        return false;
    double operand = entry->operands[index];
    if (operand < 0 || operand != std::floor(operand) || operand > 0x7FFFFFFF)
        return false;
    value = size_t(operand);
    return true;
}

struct OutlineSegment {
    bool isCurve { false };
    double x1 { 0 }, y1 { 0 }, x2 { 0 }, y2 { 0 }, x { 0 }, y { 0 };
};

struct OutlineContour {
    double startX { 0 };
    double startY { 0 };
    size_t firstSegment { 0 };
};

// A glyph's contours in absolute coordinates. Each contour's segments run from its firstSegment to the
// next contour's (or the end); the buffers are kept across glyphs.
struct Outline {
    std::vector<OutlineContour> contours;
    std::vector<OutlineSegment> segments;

    void clear()
    {
        contours.clear();
        segments.clear();
    }

    size_t endOfContour(size_t contour) const
    {
        return contour + 1 < contours.size() ? contours[contour + 1].firstSegment : segments.size();
    }
};

static uint32_t subroutineBias(uint32_t count)
{
    return count < 1240 ? 107 : (count < 33900 ? 1131 : 32768);
}

// Runs CFF2 charstrings into absolute outlines. One interpreter serves every glyph of a font.
class CFF2CharstringInterpreter {
public:
    CFF2CharstringInterpreter(const CFF2Index& globalSubrs, BlendScalars* blend)
        : m_globalSubrs(globalSubrs)
        , m_blend(blend)
    {
        m_stack.reserve(maximumCFF2StackDepth + 1);
    }

    bool run(Reader charstring, const CFF2Index* localSubrs, uint32_t vsindex, Outline& outline)
    {
        m_localSubrs = localSubrs;
        m_vsindex = vsindex;
        m_outline = &outline;
        m_stack.clear();
        m_x = m_y = 0;
        m_stems = 0;
        m_operations = 0;
        m_ended = false;
        return execute(charstring, 0);
    }

private:
    bool moveTo(double dx, double dy)
    {
        m_x += dx;
        m_y += dy;
        m_outline->contours.push_back({ m_x, m_y, m_outline->segments.size() });
        return true;
    }

    bool lineTo(double dx, double dy)
    {
        if (m_outline->contours.empty() || m_outline->segments.size() >= maximumGlyphSegments)
            return false;
        m_x += dx;
        m_y += dy;
        OutlineSegment segment;
        segment.x = m_x;
        segment.y = m_y;
        m_outline->segments.push_back(segment);
        return true;
    }

    bool curveTo(double dxa, double dya, double dxb, double dyb, double dxc, double dyc)
    {
        if (m_outline->contours.empty() || m_outline->segments.size() >= maximumGlyphSegments)
            return false;
        OutlineSegment segment;
        segment.isCurve = true;
        segment.x1 = m_x + dxa;
        segment.y1 = m_y + dya;
        segment.x2 = segment.x1 + dxb;
        segment.y2 = segment.y1 + dyb;
        segment.x = segment.x2 + dxc;
        segment.y = segment.y2 + dyc;
        m_x = segment.x;
        m_y = segment.y;
        m_outline->segments.push_back(segment);
        return true;
    }

    // hvcurveto and vhcurveto: curves alternating between a horizontal and a vertical start tangent,
    // the last one taking a fifth argument for its final tangent's other component.
    bool alternatingCurves(bool horizontal)
    {
        const auto& s = m_stack;
        size_t i = 0;
        if (s.size() < 4)
            return false;
        while (s.size() - i >= 4) {
            double last = s.size() - i == 5 ? s[i + 4] : 0;
            bool ok = horizontal ? curveTo(s[i], 0, s[i + 1], s[i + 2], last, s[i + 3])
                                 : curveTo(0, s[i], s[i + 1], s[i + 2], s[i + 3], last);
            if (!ok)
                return false;
            i += s.size() - i == 5 ? 5 : 4;
            horizontal = !horizontal;
        }
        return i == s.size();
    }

    bool execute(Reader cs, int depth)
    {
        while (cs.position() < cs.size()) {
            if (++m_operations > maximumCharstringOperations)
                return false;
            uint8_t b0 = cs.u8();
            if (b0 >= 32 && b0 <= 246)
                m_stack.push_back(int(b0) - 139);
            else if (b0 >= 247 && b0 <= 250)
                m_stack.push_back((int(b0) - 247) * 256 + cs.u8() + 108);
            else if (b0 >= 251 && b0 <= 254)
                m_stack.push_back(-(int(b0) - 251) * 256 - cs.u8() - 108);
            else if (b0 == 28)
                m_stack.push_back(cs.s16());
            else if (b0 == 255)
                m_stack.push_back(cs.s32() / 65536.0);
            else if (b0 == 11) // return
                return true;
            else if (!executeOperator(b0, cs, depth))
                return false;
            if (cs.failed() || m_stack.size() > maximumCFF2StackDepth)
                return false;
            if (m_ended)
                return true;
        }
        return true;
    }

    bool executeOperator(uint8_t b0, Reader& cs, int depth)
    {
        auto& s = m_stack;
        bool ok = true;
        switch (b0) {
        case 1: // hstem
        case 3: // vstem
        case 18: // hstemhm
        case 23: // vstemhm
            m_stems += s.size() / 2;
            break;
        case 19: // hintmask
        case 20: // cntrmask
            // Arguments before the first mask are an implied vstem.
            m_stems += s.size() / 2;
            cs.skip((m_stems + 7) / 8);
            break;
        case 21: // rmoveto
            ok = s.size() == 2 && moveTo(s[0], s[1]);
            break;
        case 22: // hmoveto
            ok = s.size() == 1 && moveTo(s[0], 0);
            break;
        case 4: // vmoveto
            ok = s.size() == 1 && moveTo(0, s[0]);
            break;
        case 5: // rlineto
            ok = !s.empty() && !(s.size() % 2);
            for (size_t i = 0; ok && i < s.size(); i += 2)
                ok = lineTo(s[i], s[i + 1]);
            break;
        case 6: // hlineto
        case 7: { // vlineto
            bool horizontal = b0 == 6;
            ok = !s.empty();
            for (size_t i = 0; ok && i < s.size(); ++i, horizontal = !horizontal)
                ok = horizontal ? lineTo(s[i], 0) : lineTo(0, s[i]);
            break;
        }
        case 8: // rrcurveto
            ok = !s.empty() && !(s.size() % 6);
            for (size_t i = 0; ok && i < s.size(); i += 6)
                ok = curveTo(s[i], s[i + 1], s[i + 2], s[i + 3], s[i + 4], s[i + 5]);
            break;
        case 24: // rcurveline
            ok = s.size() >= 8 && !((s.size() - 2) % 6);
            for (size_t i = 0; ok && i + 2 < s.size(); i += 6)
                ok = curveTo(s[i], s[i + 1], s[i + 2], s[i + 3], s[i + 4], s[i + 5]);
            ok = ok && lineTo(s[s.size() - 2], s[s.size() - 1]);
            break;
        case 25: // rlinecurve
            ok = s.size() >= 8 && !((s.size() - 6) % 2);
            for (size_t i = 0; ok && i + 6 < s.size(); i += 2)
                ok = lineTo(s[i], s[i + 1]);
            if (ok) {
                size_t c = s.size() - 6;
                ok = curveTo(s[c], s[c + 1], s[c + 2], s[c + 3], s[c + 4], s[c + 5]);
            }
            break;
        case 26: { // vvcurveto
            size_t i = s.size() % 2;
            double dx1 = i ? s[0] : 0;
            ok = s.size() - i >= 4 && !((s.size() - i) % 4);
            for (; ok && i < s.size(); i += 4, dx1 = 0)
                ok = curveTo(dx1, s[i], s[i + 1], s[i + 2], 0, s[i + 3]);
            break;
        }
        case 27: { // hhcurveto
            size_t i = s.size() % 2;
            double dy1 = i ? s[0] : 0;
            ok = s.size() - i >= 4 && !((s.size() - i) % 4);
            for (; ok && i < s.size(); i += 4, dy1 = 0)
                ok = curveTo(s[i], dy1, s[i + 1], s[i + 2], s[i + 3], 0);
            break;
        }
        case 30: // vhcurveto
            ok = alternatingCurves(false);
            break;
        case 31: // hvcurveto
            ok = alternatingCurves(true);
            break;
        case 10: // callsubr
        case 29: { // callgsubr
            const CFF2Index* subrs = b0 == 10 ? m_localSubrs : &m_globalSubrs;
            if (!subrs || s.empty() || depth >= maximumSubroutineDepth)
                return false;
            double index = s.back() + subroutineBias(subrs->count());
            s.pop_back();
            if (index < 0 || index != std::floor(index) || index >= subrs->count())
                return false;
            Reader subr = subrs->item(uint32_t(index));
            if (subr.failed())
                return false;
            // The callee works on the caller's stack.
            return execute(subr, depth + 1);
        }
        case 14: // endchar
            m_ended = true;
            break;
        case 15: // vsindex
            if (s.size() != 1 || s[0] < 0 || s[0] > 65535)
                return false;
            m_vsindex = uint32_t(s[0]);
            break;
        case 16: // blend
            return resolveBlend(s, m_blend, m_vsindex);
        case 12: {
            uint8_t b1 = cs.u8();
            switch (b1) {
            case 35: // flex
                ok = s.size() == 13 && curveTo(s[0], s[1], s[2], s[3], s[4], s[5]) && curveTo(s[6], s[7], s[8], s[9], s[10], s[11]);
                break;
            case 34: // hflex
                ok = s.size() == 7 && curveTo(s[0], 0, s[1], s[2], s[3], 0) && curveTo(s[4], 0, s[5], -s[2], s[6], 0);
                break;
            case 36: // hflex1
                ok = s.size() == 9 && curveTo(s[0], s[1], s[2], s[3], s[4], 0) && curveTo(s[5], 0, s[6], s[7], s[8], -(s[1] + s[3] + s[7]));
                break;
            case 37: { // flex1
                if (s.size() != 11)
                    return false;
                double dx = s[0] + s[2] + s[4] + s[6] + s[8];
                double dy = s[1] + s[3] + s[5] + s[7] + s[9];
                bool horizontal = std::abs(dx) > std::abs(dy);
                ok = curveTo(s[0], s[1], s[2], s[3], s[4], s[5])
                    && curveTo(s[6], s[7], s[8], s[9], horizontal ? s[10] : -dx, horizontal ? -dy : s[10]);
                break;
            }
            default:
                return false;
            }
            break;
        }
        default:
            return false;
        }
        s.clear();
        return ok;
    }

    const CFF2Index& m_globalSubrs;
    BlendScalars* m_blend;
    const CFF2Index* m_localSubrs { nullptr };
    uint32_t m_vsindex { 0 };
    Outline* m_outline { nullptr };
    std::vector<double> m_stack;
    double m_x { 0 };
    double m_y { 0 };
    uint32_t m_stems { 0 };
    uint64_t m_operations { 0 };
    bool m_ended { false };
};

static void addCubicBounds(BBox& bbox, int32_t x0, int32_t y0, int32_t x1, int32_t y1, int32_t x2, int32_t y2, int32_t x3, int32_t y3)
{
    bbox.addPoint(x3, y3);
    const double p0[2] = { double(x0), double(y0) };
    const double p1[2] = { double(x1), double(y1) };
    const double p2[2] = { double(x2), double(y2) };
    const double p3[2] = { double(x3), double(y3) };
    for (int axis = 0; axis < 2; ++axis) {
        // Only a control point outside its curve's end points can put an extremum between them.
        double low = std::min(p0[axis], p3[axis]);
        double high = std::max(p0[axis], p3[axis]);
        if (p1[axis] >= low && p1[axis] <= high && p2[axis] >= low && p2[axis] <= high)
            continue;
        // The derivative over 3: a t^2 + b t + c.
        double a = -p0[axis] + 3 * p1[axis] - 3 * p2[axis] + p3[axis];
        double b = 2 * (p0[axis] - 2 * p1[axis] + p2[axis]);
        double c = p1[axis] - p0[axis];
        double roots[2];
        int rootCount = 0;
        if (std::abs(a) < 1e-12) {
            if (std::abs(b) > 1e-12)
                roots[rootCount++] = -c / b;
        } else {
            double discriminant = b * b - 4 * a * c;
            if (discriminant >= 0) {
                double root = std::sqrt(discriminant);
                roots[rootCount++] = (-b + root) / (2 * a);
                roots[rootCount++] = (-b - root) / (2 * a);
            }
        }
        for (int r = 0; r < rootCount; ++r) {
            double t = roots[r];
            if (!(t > 0 && t < 1))
                continue;
            double u = 1 - t;
            double x = u * u * u * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t * t * t * p3[0];
            double y = u * u * u * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t * t * t * p3[1];
            bbox.add(float(x), float(y));
        }
    }
}

// The whole-unit point an outline coordinate is encoded at.
static bool roundedCoordinate(double value, int32_t& rounded)
{
    double r = std::floor(value + 0.5);
    if (!(std::abs(r) <= 32767))
        return false;
    rounded = int32_t(r);
    return true;
}

// The bounds of `outline` as encodeType2Charstring encodes it: whole-unit points, curve extrema included.
static bool outlineBounds(const Outline& outline, BBox& bbox)
{
    for (size_t c = 0; c < outline.contours.size(); ++c) {
        size_t end = outline.endOfContour(c);
        if (outline.contours[c].firstSegment == end)
            continue;
        int32_t x, y;
        if (!roundedCoordinate(outline.contours[c].startX, x) || !roundedCoordinate(outline.contours[c].startY, y))
            return false;
        bbox.addPoint(x, y);
        for (size_t i = outline.contours[c].firstSegment; i < end; ++i) {
            const OutlineSegment& segment = outline.segments[i];
            int32_t p[6];
            if (!roundedCoordinate(segment.x, p[4]) || !roundedCoordinate(segment.y, p[5]))
                return false;
            if (segment.isCurve) {
                if (!roundedCoordinate(segment.x1, p[0]) || !roundedCoordinate(segment.y1, p[1])
                    || !roundedCoordinate(segment.x2, p[2]) || !roundedCoordinate(segment.y2, p[3]))
                    return false;
                addCubicBounds(bbox, x, y, p[0], p[1], p[2], p[3], p[4], p[5]);
            } else
                bbox.addPoint(p[4], p[5]);
            x = p[4];
            y = p[5];
        }
    }
    return true;
}

static void writeType2Number(Writer& out, int32_t v)
{
    if (v >= -107 && v <= 107)
        out.u8(uint8_t(v + 139));
    else if (v >= 108 && v <= 1131) {
        v -= 108;
        out.u8(uint8_t((v >> 8) + 247));
        out.u8(uint8_t(v));
    } else if (v >= -1131 && v <= -108) {
        v = -v - 108;
        out.u8(uint8_t((v >> 8) + 251));
        out.u8(uint8_t(v));
    } else {
        out.u8(28);
        out.s16(int16_t(v));
    }
}

// Encodes `outline` as a Type 2 charstring on whole-unit points: the advance width as the first
// stack-clearing operator's extra argument, then per contour an rmoveto followed by runs of rlineto and
// rrcurveto, each holding at most the 48 arguments a Type 2 stack takes, then endchar. Every number is a
// Type 2 integer, so a width or a coordinate step past 16 bits fails the glyph. `bbox` receives the bounds
// outlineBounds gives.
static bool encodeType2Charstring(const Outline& outline, int32_t width, Writer& out, std::vector<int32_t>& arguments, BBox& bbox)
{
    if (width < -32768 || width > 32767)
        return false;
    int32_t x = 0, y = 0;
    bool widthWritten = false;
    arguments.clear();
    auto delta = [&](double target, int32_t& current, int32_t& value) {
        int32_t rounded;
        if (!roundedCoordinate(target, rounded))
            return false;
        value = rounded - current;
        current = rounded;
        return value >= -32768 && value <= 32767;
    };
    auto emit = [&](uint8_t op) {
        if (!widthWritten) {
            writeType2Number(out, width);
            widthWritten = true;
        }
        for (int32_t argument : arguments)
            writeType2Number(out, argument);
        out.u8(op);
        arguments.clear();
    };
    for (size_t c = 0; c < outline.contours.size(); ++c) {
        size_t end = outline.endOfContour(c);
        if (outline.contours[c].firstSegment == end)
            continue;
        int32_t dx, dy;
        if (!delta(outline.contours[c].startX, x, dx) || !delta(outline.contours[c].startY, y, dy))
            return false;
        arguments.push_back(dx);
        arguments.push_back(dy);
        emit(21);
        bbox.addPoint(x, y);
        uint8_t runOperator = 0;
        for (size_t i = outline.contours[c].firstSegment; i < end; ++i) {
            const OutlineSegment& segment = outline.segments[i];
            uint8_t op = segment.isCurve ? 8 : 5;
            size_t perSegment = segment.isCurve ? 6 : 2;
            if (runOperator && (runOperator != op || arguments.size() + perSegment > 48))
                emit(runOperator);
            runOperator = op;
            int32_t d[6];
            int32_t startX = x, startY = y;
            if (segment.isCurve) {
                if (!delta(segment.x1, x, d[0]) || !delta(segment.y1, y, d[1]))
                    return false;
                int32_t x1 = x, y1 = y;
                if (!delta(segment.x2, x, d[2]) || !delta(segment.y2, y, d[3]))
                    return false;
                int32_t x2 = x, y2 = y;
                if (!delta(segment.x, x, d[4]) || !delta(segment.y, y, d[5]))
                    return false;
                arguments.insert(arguments.end(), d, d + 6);
                addCubicBounds(bbox, startX, startY, x1, y1, x2, y2, x, y);
            } else {
                if (!delta(segment.x, x, d[0]) || !delta(segment.y, y, d[1]))
                    return false;
                arguments.insert(arguments.end(), d, d + 2);
                bbox.addPoint(x, y);
            }
        }
        if (runOperator)
            emit(runOperator);
    }
    emit(14);
    return true;
}

static void writeDictInteger(Writer& out, int32_t v)
{
    if (v >= -107 && v <= 107)
        out.u8(uint8_t(v + 139));
    else if (v >= 108 && v <= 1131) {
        v -= 108;
        out.u8(uint8_t((v >> 8) + 247));
        out.u8(uint8_t(v));
    } else if (v >= -1131 && v <= -108) {
        v = -v - 108;
        out.u8(uint8_t((v >> 8) + 251));
        out.u8(uint8_t(v));
    } else if (v >= -32768 && v <= 32767) {
        out.u8(28);
        out.s16(int16_t(v));
    } else {
        out.u8(29);
        out.u32(uint32_t(v));
    }
}

// An offset in its five-byte form, so that a DICT's size does not depend on the offsets it holds.
static void writeDictOffset(Writer& out, uint32_t v)
{
    out.u8(29);
    out.u32(v);
}

static void writeDictNumber(Writer& out, double v)
{
    if (v == std::floor(v) && std::abs(v) <= 0x7FFFFFFF) {
        writeDictInteger(out, int32_t(v));
        return;
    }
    char text[32];
    snprintf(text, sizeof(text), "%.9g", v);
    std::vector<uint8_t> nibbles;
    for (const char* c = text; *c; ++c) {
        if (*c >= '0' && *c <= '9')
            nibbles.push_back(uint8_t(*c - '0'));
        else if (*c == '.' || *c == ',')
            nibbles.push_back(0xa);
        else if (*c == '-')
            nibbles.push_back(0xe);
        else if (*c == 'e' || *c == 'E') {
            if (c[1] == '-') {
                nibbles.push_back(0xc);
                ++c;
            } else {
                nibbles.push_back(0xb);
                if (c[1] == '+')
                    ++c;
            }
        }
    }
    nibbles.push_back(0xf);
    if (nibbles.size() % 2)
        nibbles.push_back(0xf);
    out.u8(30);
    for (size_t i = 0; i < nibbles.size(); i += 2)
        out.u8(uint8_t(nibbles[i] << 4 | nibbles[i + 1]));
}

static void writeDictOperator(Writer& out, uint16_t op)
{
    if (op >= 0x0c00) {
        out.u8(12);
        out.u8(uint8_t(op));
    } else
        out.u8(uint8_t(op));
}

// A CFF (version 1) INDEX of `count` items laid end to end in `data`, item i ending at ends[i]: a 16-bit
// count, then offsets of the smallest size that holds them.
static bool writeCFFIndex(Writer& out, const uint8_t* data, const std::vector<uint32_t>& ends)
{
    if (ends.size() > 0xFFFF)
        return false;
    out.u16(uint16_t(ends.size()));
    if (ends.empty())
        return true;
    uint64_t dataSize = ends.back();
    if (dataSize + 1 > 0xFFFFFFFFull)
        return false;
    uint8_t offSize = dataSize + 1 <= 0xFF ? 1 : (dataSize + 1 <= 0xFFFF ? 2 : (dataSize + 1 <= 0xFFFFFF ? 3 : 4));
    out.u8(offSize);
    auto writeOffset = [&](uint64_t value) {
        for (int b = offSize - 1; b >= 0; --b)
            out.u8(uint8_t(value >> (8 * b)));
    };
    writeOffset(1);
    for (uint32_t end : ends)
        writeOffset(uint64_t(end) + 1);
    out.bytes(data, size_t(dataSize));
    return true;
}

static bool writeCFFIndex(Writer& out, const std::vector<std::vector<uint8_t>>& items)
{
    std::vector<uint8_t> data;
    std::vector<uint32_t> ends;
    for (const auto& item : items) {
        data.insert(data.end(), item.begin(), item.end());
        if (data.size() > 0xFFFFFFFEull)
            return false;
        ends.push_back(uint32_t(data.size()));
    }
    return writeCFFIndex(out, data.data(), ends);
}

// The name a CFF Name INDEX may hold: printable ASCII without the PostScript delimiters, at most 63 bytes.
static std::string postScriptFontName(CFStringRef name)
{
    std::string result;
    char buffer[256];
    if (name && CFStringGetCString(name, buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
        for (const char* c = buffer; *c && result.size() < 63; ++c) {
            if (*c > 32 && *c < 127 && !strchr("[](){}<>/%", *c))
                result.push_back(*c);
        }
    }
    return result.empty() ? std::string("Untitled") : result;
}

struct CFF2FontDict {
    std::vector<DictEntry> privateEntries;
    CFF2Index localSubrs;
    bool hasLocalSubrs { false };
    uint32_t vsindex { 0 };
};

// Every glyph's Type 2 charstring, laid end to end, glyph i ending at ends[i]; and each glyph's bounds.
struct CFF2Outlines {
    Writer charstrings;
    std::vector<uint32_t> ends;
    std::vector<BBox> bounds;
};

// The parsed CFF2 table: what the conversion of every glyph reads.
class CFF2Font {
public:
    bool parse(Reader table, uint32_t numGlyphs, const std::vector<float>& coords)
    {
        uint8_t major = table.u8();
        table.u8(); // minor
        uint8_t headerSize = table.u8();
        uint16_t topDictLength = table.u16();
        if (table.failed() || major != 2 || headerSize < 5 || size_t(headerSize) + topDictLength > table.size())
            return false;
        std::vector<DictEntry> top;
        if (!parseDict(table.slice(headerSize, topDictLength), nullptr, top))
            return false;
        size_t end = 0;
        if (!m_globalSubrs.parse(table, size_t(headerSize) + topDictLength, end))
            return false;

        size_t offset = 0;
        if (const DictEntry* vstore = findDictEntry(top, vstoreOperator)) {
            // A uint16 length precedes the store.
            if (!dictOffset(vstore, 0, offset) || offset > table.size() || table.size() - offset < 2)
                return false;
            m_store.emplace(table.slice(offset + 2, table.size() - offset - 2));
            // A font without fvar sits at every axis's default.
            std::vector<float> at = coords;
            if (at.empty()) {
                auto axisCount = m_store->axisCount();
                if (!axisCount)
                    return false;
                at.assign(*axisCount, 0);
            }
            if (!m_store->initialize(at))
                return false;
            m_blend.emplace(&*m_store);
        }
        if (const DictEntry* matrix = findDictEntry(top, fontMatrixOperator)) {
            if (matrix->operands.size() != 6)
                return false;
            m_fontMatrix = matrix->operands;
        }
        if (!dictOffset(findDictEntry(top, charStringsOperator), 0, offset) || !m_charstrings.parse(table, offset, end) || m_charstrings.count() != numGlyphs)
            return false;

        CFF2Index fdArray;
        if (!dictOffset(findDictEntry(top, fdArrayOperator), 0, offset) || !fdArray.parse(table, offset, end) || !fdArray.count() || fdArray.count() > 256)
            return false;
        for (uint32_t fd = 0; fd < fdArray.count(); ++fd) {
            std::vector<DictEntry> fontDict;
            if (!parseDict(fdArray.item(fd), nullptr, fontDict))
                return false;
            size_t privateSize = 0, privateOffset = 0;
            const DictEntry* privateEntry = findDictEntry(fontDict, privateOperator);
            if (!dictOffset(privateEntry, 0, privateSize) || !dictOffset(privateEntry, 1, privateOffset)
                || privateOffset > table.size() || privateSize > table.size() - privateOffset)
                return false;
            CFF2FontDict dict;
            if (!parseDict(table.slice(privateOffset, privateSize), blend(), dict.privateEntries))
                return false;
            if (const DictEntry* vsindex = findDictEntry(dict.privateEntries, vsindexOperator))
                dict.vsindex = uint32_t(vsindex->operands[0]);
            size_t subrsOffset = 0;
            if (findDictEntry(dict.privateEntries, subrsOperator)) {
                if (!dictOffset(findDictEntry(dict.privateEntries, subrsOperator), 0, subrsOffset)
                    || !dict.localSubrs.parse(table, privateOffset + subrsOffset, end))
                    return false;
                dict.hasLocalSubrs = true;
            }
            m_fontDicts.push_back(std::move(dict));
        }

        m_fdSelect.assign(numGlyphs, 0);
        if (findDictEntry(top, fdSelectOperator)) {
            if (!dictOffset(findDictEntry(top, fdSelectOperator), 0, offset) || !parseFDSelect(table, offset, numGlyphs))
                return false;
        } else if (m_fontDicts.size() != 1)
            return false;
        for (uint8_t fd : m_fdSelect) {
            if (fd >= m_fontDicts.size())
                return false;
        }
        m_interpreter.emplace(m_globalSubrs, blend());
        return true;
    }

    // Runs glyph `glyph` into `outline`.
    bool outline(uint32_t glyph, Outline& outline)
    {
        const CFF2FontDict& dict = m_fontDicts[m_fdSelect[glyph]];
        Reader charstring = m_charstrings.item(glyph);
        outline.clear();
        return !charstring.failed() && m_interpreter->run(charstring, dict.hasLocalSubrs ? &dict.localSubrs : nullptr, dict.vsindex, outline);
    }

    // The CID-keyed CFF table for `outlines`, under the PostScript name `name`.
    std::optional<std::vector<uint8_t>> assembleCFF(const std::string& name, const CFF2Outlines& outlines, const BBox& fontBBox) const
    {
        uint32_t numGlyphs = uint32_t(outlines.ends.size());
        if (!numGlyphs || numGlyphs > 0xFFFF)
            return std::nullopt;

        Writer nameIndex;
        writeCFFIndex(nameIndex, { std::vector<uint8_t>(name.begin(), name.end()) });
        // The ROS registry and ordering are the first two strings past the 391 standard ones.
        Writer stringIndex;
        writeCFFIndex(stringIndex, { std::vector<uint8_t> { 'A', 'd', 'o', 'b', 'e' }, std::vector<uint8_t> { 'I', 'd', 'e', 'n', 't', 'i', 't', 'y' } });
        Writer globalSubrIndex;
        writeCFFIndex(globalSubrIndex, std::vector<std::vector<uint8_t>> { });

        // charset: glyph i is CID i.
        Writer charset;
        if (numGlyphs > 1) {
            charset.u8(2);
            charset.u16(1);
            charset.u16(uint16_t(numGlyphs - 2));
        } else
            charset.u8(0);

        // FDSelect, format 3.
        Writer fdSelect;
        std::vector<std::pair<uint16_t, uint8_t>> ranges;
        for (uint32_t glyph = 0; glyph < numGlyphs; ++glyph) {
            if (ranges.empty() || ranges.back().second != m_fdSelect[glyph])
                ranges.emplace_back(uint16_t(glyph), m_fdSelect[glyph]);
        }
        fdSelect.u8(3);
        fdSelect.u16(uint16_t(ranges.size()));
        for (const auto& range : ranges) {
            fdSelect.u16(range.first);
            fdSelect.u8(range.second);
        }
        fdSelect.u16(uint16_t(numGlyphs));

        Writer charStringsIndex;
        if (!writeCFFIndex(charStringsIndex, outlines.charstrings.vector().data(), outlines.ends))
            return std::nullopt;

        // Private DICTs: the resolved CFF2 entries without their subroutines or variation index, and
        // zero default and nominal widths, which every charstring's explicit width is relative to.
        std::vector<std::vector<uint8_t>> privateDicts;
        for (const auto& dict : m_fontDicts) {
            Writer out;
            for (const auto& entry : dict.privateEntries) {
                if (entry.op == subrsOperator || entry.op == vsindexOperator || entry.op == 20 || entry.op == 21)
                    continue;
                for (double operand : entry.operands)
                    writeDictNumber(out, operand);
                writeDictOperator(out, entry.op);
            }
            writeDictInteger(out, 0);
            writeDictOperator(out, 20);
            writeDictInteger(out, 0);
            writeDictOperator(out, 21);
            privateDicts.push_back(out.vector());
        }

        auto topDict = [&](uint32_t charsetOffset, uint32_t fdSelectOffset, uint32_t fdArrayOffset, uint32_t charStringsOffset) {
            Writer out;
            writeDictInteger(out, 391);
            writeDictInteger(out, 392);
            writeDictInteger(out, 0);
            writeDictOperator(out, 0x0c1e); // ROS
            writeDictInteger(out, int32_t(numGlyphs));
            writeDictOperator(out, 0x0c22); // CIDCount
            writeDictInteger(out, fontBBox.xMin);
            writeDictInteger(out, fontBBox.yMin);
            writeDictInteger(out, fontBBox.xMax);
            writeDictInteger(out, fontBBox.yMax);
            writeDictOperator(out, 5); // FontBBox
            if (!m_fontMatrix.empty()) {
                for (double value : m_fontMatrix)
                    writeDictNumber(out, value);
                writeDictOperator(out, fontMatrixOperator);
            }
            writeDictOffset(out, charsetOffset);
            writeDictOperator(out, 15);
            writeDictOffset(out, fdSelectOffset);
            writeDictOperator(out, fdSelectOperator);
            writeDictOffset(out, fdArrayOffset);
            writeDictOperator(out, fdArrayOperator);
            writeDictOffset(out, charStringsOffset);
            writeDictOperator(out, charStringsOperator);
            return out.vector();
        };
        auto fontDicts = [&](uint32_t firstPrivateOffset) {
            std::vector<std::vector<uint8_t>> dicts;
            uint64_t offset = firstPrivateOffset;
            for (const auto& privateDict : privateDicts) {
                Writer out;
                writeDictOffset(out, uint32_t(privateDict.size()));
                writeDictOffset(out, uint32_t(offset));
                writeDictOperator(out, privateOperator);
                dicts.push_back(out.vector());
                offset += privateDict.size();
            }
            return dicts;
        };

        // Every offset is written in its fixed five-byte form, so the sizes measured with zeros hold.
        Writer measuredTop;
        writeCFFIndex(measuredTop, { topDict(0, 0, 0, 0) });
        Writer measuredFDArray;
        writeCFFIndex(measuredFDArray, fontDicts(0));
        uint64_t charsetOffset = 4 + nameIndex.size() + measuredTop.size() + stringIndex.size() + globalSubrIndex.size();
        uint64_t fdSelectOffset = charsetOffset + charset.size();
        uint64_t charStringsOffset = fdSelectOffset + fdSelect.size();
        uint64_t fdArrayOffset = charStringsOffset + charStringsIndex.size();
        uint64_t privateOffset = fdArrayOffset + measuredFDArray.size();
        uint64_t total = privateOffset;
        for (const auto& privateDict : privateDicts)
            total += privateDict.size();
        if (total > maximumAssembledFontSize)
            return std::nullopt;

        Writer cff;
        cff.vector().reserve(size_t(total));
        cff.u8(1); // major
        cff.u8(0); // minor
        cff.u8(4); // header size
        cff.u8(4); // absolute offset size
        cff.bytes(nameIndex.vector().data(), nameIndex.size());
        writeCFFIndex(cff, { topDict(uint32_t(charsetOffset), uint32_t(fdSelectOffset), uint32_t(fdArrayOffset), uint32_t(charStringsOffset)) });
        cff.bytes(stringIndex.vector().data(), stringIndex.size());
        cff.bytes(globalSubrIndex.vector().data(), globalSubrIndex.size());
        cff.bytes(charset.vector().data(), charset.size());
        cff.bytes(fdSelect.vector().data(), fdSelect.size());
        cff.bytes(charStringsIndex.vector().data(), charStringsIndex.size());
        writeCFFIndex(cff, fontDicts(uint32_t(privateOffset)));
        for (const auto& privateDict : privateDicts)
            cff.bytes(privateDict.data(), privateDict.size());
        if (cff.size() != total)
            return std::nullopt;
        return std::move(cff.vector());
    }

private:
    BlendScalars* blend() { return m_blend ? &*m_blend : nullptr; }

    bool parseFDSelect(Reader table, size_t offset, uint32_t numGlyphs)
    {
        if (offset > table.size())
            return false;
        Reader select = table.slice(offset, table.size() - offset);
        uint8_t format = select.u8();
        if (format == 0) {
            for (uint32_t glyph = 0; glyph < numGlyphs; ++glyph)
                m_fdSelect[glyph] = select.u8();
            return !select.failed();
        }
        if (format != 3 && format != 4)
            return false;
        uint32_t rangeCount = format == 3 ? select.u16() : select.u32();
        uint32_t first = format == 3 ? select.u16() : select.u32();
        if (select.failed() || !rangeCount || first)
            return false;
        for (uint32_t range = 0; range < rangeCount; ++range) {
            uint16_t fd = format == 3 ? select.u8() : select.u16();
            uint32_t next = format == 3 ? select.u16() : select.u32();
            if (select.failed() || next <= first || next > numGlyphs || fd > 0xFF)
                return false;
            for (uint32_t glyph = first; glyph < next; ++glyph)
                m_fdSelect[glyph] = uint8_t(fd);
            first = next;
        }
        return first == numGlyphs;
    }

    CFF2Index m_globalSubrs;
    CFF2Index m_charstrings;
    std::optional<ItemVariationStore> m_store;
    std::optional<BlendScalars> m_blend;
    std::optional<CFF2CharstringInterpreter> m_interpreter;
    std::vector<double> m_fontMatrix;
    std::vector<CFF2FontDict> m_fontDicts;
    std::vector<uint8_t> m_fdSelect;
};

// An HVAR or VVAR delta for one glyph through the mapping at `mappingOffset` (zero: glyph IDs index
// the store's first ItemVariationData directly).
static std::optional<double> glyphMetricDelta(Reader table, const ItemVariationStore& store, uint32_t mappingOffset, uint32_t glyph)
{
    if (!mappingOffset)
        return store.delta(glyph);
    if (mappingOffset > table.size())
        return std::nullopt;
    auto index = mappedVariationIndex(table.slice(mappingOffset, table.size() - mappingOffset), glyph);
    return index ? store.delta(*index) : std::nullopt;
}

// Rewrites a font whose outlines are a CFF2 table as one with a CFF table, at the instance pinned by
// `pinnedAxisValues` (the fvar defaults where an axis is not named, and for a font without fvar).
class CFF2Instancer {
public:
    explicit CFF2Instancer(const ParsedSfnt& sfnt)
        : m_sfnt(sfnt)
    {
    }

    CFDataRef instance(const std::vector<std::pair<uint32_t, double>>& pinnedAxisValues)
    {
        m_pinned = !pinnedAxisValues.empty();
        if (!computeCoords(pinnedAxisValues) || !readMetrics())
            return nullptr;
        CFF2Font font;
        Reader table = m_sfnt.tableReader(cff2Tag);
        if (table.failed() || !font.parse(table, m_numGlyphs, m_coords))
            return nullptr;
        if (!varyMetrics())
            return nullptr;
        CFF2Outlines outlines;
        outlines.ends.resize(m_numGlyphs);
        outlines.bounds.resize(m_numGlyphs);
        outlines.charstrings.vector().reserve(table.size() * 2);
        BBox fontBBox;
        Outline outline;
        std::vector<int32_t> arguments;
        arguments.reserve(48);
        for (uint32_t glyph = 0; glyph < m_numGlyphs; ++glyph) {
            if (!font.outline(glyph, outline) || !encodeType2Charstring(outline, m_advances[glyph], outlines.charstrings, arguments, outlines.bounds[glyph]))
                return nullptr;
            if (outlines.charstrings.size() > maximumAssembledFontSize)
                return nullptr;
            outlines.ends[glyph] = uint32_t(outlines.charstrings.size());
            const BBox& bounds = outlines.bounds[glyph];
            if (bounds.valid) {
                fontBBox.add(bounds.xMin, bounds.yMin);
                fontBBox.add(bounds.xMax, bounds.yMax);
            }
        }
        if (m_hasVerticalMetrics && !resolveTopSideBearings(outlines.bounds))
            return nullptr;
        CFStringRef nameRecord = copyNameRecord(m_sfnt, 6);
        std::string name = postScriptFontName(nameRecord);
        if (nameRecord)
            CFRelease(nameRecord);
        auto cff = font.assembleCFF(name, outlines, fontBBox);
        if (!cff)
            return nullptr;
        return assemble(*cff, outlines.bounds, fontBBox);
    }

private:
    bool computeCoords(const std::vector<std::pair<uint32_t, double>>& pinnedAxisValues)
    {
        if (!m_sfnt.find(fvarTag))
            return pinnedAxisValues.empty();
        m_axes = parseFvarAxes(m_sfnt);
        if (m_axes.empty())
            return false;
        m_coords.resize(m_axes.size());
        m_pinnedDesignValues.resize(m_axes.size());
        for (size_t i = 0; i < m_axes.size(); ++i) {
            const auto& axis = m_axes[i];
            double value = axis.defaultValue;
            for (const auto& [tag, pinnedValue] : pinnedAxisValues) {
                if (tag == axis.tag) {
                    value = pinnedValue;
                    break;
                }
            }
            value = std::min(axis.maximumValue, std::max(axis.minimumValue, value));
            m_pinnedDesignValues[i] = value;
            m_coords[i] = normalizedFixed(axis, value) / 65536.0f;
        }
        return applyAvar(m_sfnt, m_coords);
    }

    bool atDefault() const
    {
        return std::all_of(m_coords.begin(), m_coords.end(), [](float coordinate) { return !coordinate; });
    }

    bool readMetrics()
    {
        Reader maxp = m_sfnt.tableReader(maxpTag);
        maxp.seek(4);
        m_numGlyphs = maxp.u16();
        Reader hhea = m_sfnt.tableReader(hheaTag);
        hhea.seek(34);
        uint16_t numberOfHMetrics = hhea.u16();
        if (maxp.failed() || hhea.failed() || !m_numGlyphs || !numberOfHMetrics || numberOfHMetrics > m_numGlyphs)
            return false;
        if (!readLongMetrics(m_sfnt.tableReader(hmtxTag), numberOfHMetrics, m_advances, m_leftSideBearings))
            return false;
        if (m_sfnt.find(vheaTag) && m_sfnt.find(vmtxTag)) {
            Reader vhea = m_sfnt.tableReader(vheaTag);
            vhea.seek(34);
            uint16_t numberOfVMetrics = vhea.u16();
            if (vhea.failed() || !numberOfVMetrics || numberOfVMetrics > m_numGlyphs
                || !readLongMetrics(m_sfnt.tableReader(vmtxTag), numberOfVMetrics, m_verticalAdvances, m_topSideBearings))
                return false;
            m_hasVerticalMetrics = true;
        }
        return true;
    }

    bool readLongMetrics(Reader table, uint16_t longCount, std::vector<int32_t>& advances, std::vector<int32_t>& bearings)
    {
        advances.resize(m_numGlyphs);
        bearings.resize(m_numGlyphs);
        int32_t lastAdvance = 0;
        for (uint32_t glyph = 0; glyph < m_numGlyphs; ++glyph) {
            if (glyph < longCount)
                lastAdvance = table.u16();
            advances[glyph] = lastAdvance;
            bearings[glyph] = table.s16();
        }
        return !table.failed();
    }

    // HVAR and VVAR advance deltas, and VVAR's vertical-origin deltas over VORG.
    bool varyMetrics()
    {
        if (atDefault())
            return true;
        auto vary = [&](uint32_t tag, std::vector<int32_t>& advances, bool vertical) {
            if (!m_sfnt.find(tag))
                return true;
            Reader table = m_sfnt.tableReader(tag);
            uint16_t major = table.u16();
            table.u16(); // minor
            uint32_t storeOffset = table.u32();
            uint32_t advanceMapping = table.u32();
            table.u32(); // start-side bearing mapping
            table.u32(); // end-side bearing mapping
            uint32_t originMapping = vertical ? table.u32() : 0;
            if (table.failed() || major != 1 || !storeOffset || storeOffset > table.size())
                return false;
            ItemVariationStore store(table.slice(storeOffset, table.size() - storeOffset));
            if (!store.initialize(m_coords))
                return false;
            for (uint32_t glyph = 0; glyph < m_numGlyphs; ++glyph) {
                auto delta = glyphMetricDelta(table, store, advanceMapping, glyph);
                if (!delta)
                    return false;
                advances[glyph] = std::min<int32_t>(65535, std::max<int32_t>(0, advances[glyph] + int32_t(std::floor(*delta + 0.5))));
            }
            if (originMapping && m_sfnt.find(vorgTag)) {
                if (!readVerticalOrigins(m_verticalOrigins))
                    return false;
                for (uint32_t glyph = 0; glyph < m_numGlyphs; ++glyph) {
                    auto delta = glyphMetricDelta(table, store, originMapping, glyph);
                    if (!delta)
                        return false;
                    m_verticalOrigins[glyph] += int32_t(std::floor(*delta + 0.5));
                }
                m_variesVerticalOrigins = true;
            }
            return true;
        };
        return vary(hvarTag, m_advances, false) && (!m_hasVerticalMetrics || vary(vvarTag, m_verticalAdvances, true));
    }

    bool readVerticalOrigins(std::vector<int32_t>& origins) const
    {
        Reader vorg = m_sfnt.tableReader(vorgTag);
        uint16_t major = vorg.u16();
        vorg.u16(); // minor
        int16_t defaultOrigin = vorg.s16();
        uint16_t count = vorg.u16();
        if (vorg.failed() || major != 1)
            return false;
        origins.assign(m_numGlyphs, defaultOrigin);
        for (uint16_t i = 0; i < count; ++i) {
            uint16_t glyph = vorg.u16();
            int16_t origin = vorg.s16();
            if (glyph < m_numGlyphs)
                origins[glyph] = origin;
        }
        return !vorg.failed();
    }

    // A glyph's top-side bearing is its vertical origin less its top. The origin is VORG's where the
    // font has one; otherwise it is the default master's, which the outline at the fvar defaults gives.
    bool resolveTopSideBearings(const std::vector<BBox>& bounds)
    {
        if (atDefault())
            return true;
        constexpr int32_t noOrigin = std::numeric_limits<int32_t>::min();
        std::vector<int32_t> origins;
        if (m_sfnt.find(vorgTag)) {
            if (m_variesVerticalOrigins)
                origins = m_verticalOrigins;
            else if (!readVerticalOrigins(origins))
                return false;
        } else {
            CFF2Font defaultFont;
            std::vector<float> defaultCoords(m_axes.size(), 0);
            if (!applyAvar(m_sfnt, defaultCoords) || !defaultFont.parse(m_sfnt.tableReader(cff2Tag), m_numGlyphs, defaultCoords))
                return false;
            origins.resize(m_numGlyphs);
            Outline outline;
            for (uint32_t glyph = 0; glyph < m_numGlyphs; ++glyph) {
                BBox defaultBounds;
                if (!defaultFont.outline(glyph, outline) || !outlineBounds(outline, defaultBounds))
                    return false;
                origins[glyph] = defaultBounds.valid ? m_topSideBearings[glyph] + defaultBounds.yMax : noOrigin;
            }
        }
        for (uint32_t glyph = 0; glyph < m_numGlyphs; ++glyph) {
            if (bounds[glyph].valid && origins[glyph] != noOrigin)
                m_topSideBearings[glyph] = origins[glyph] - bounds[glyph].yMax;
        }
        return true;
    }

    CFDataRef assemble(const std::vector<uint8_t>& cff, const std::vector<BBox>& bounds, const BBox& fontBBox)
    {
        std::map<uint32_t, double> globalDeltas;
        if (!metricVariations(m_sfnt, m_coords, globalDeltas))
            return nullptr;

        // hmtx: CFF outlines put each glyph's left side bearing at its left edge.
        Writer hmtx;
        int32_t advanceWidthMax = 0;
        int32_t minLeftSideBearing = 32767, minRightSideBearing = 32767, xMaxExtent = -32768;
        bool anyContours = false;
        for (uint32_t glyph = 0; glyph < m_numGlyphs; ++glyph) {
            const BBox& box = bounds[glyph];
            int32_t advance = m_advances[glyph];
            int32_t leftSideBearing = box.valid ? box.xMin : m_leftSideBearings[glyph];
            advanceWidthMax = std::max(advanceWidthMax, advance);
            if (box.valid) {
                anyContours = true;
                minLeftSideBearing = std::min(minLeftSideBearing, leftSideBearing);
                minRightSideBearing = std::min(minRightSideBearing, advance - box.xMax);
                xMaxExtent = std::max(xMaxExtent, box.xMax);
            }
            hmtx.u16(uint16_t(advance));
            hmtx.s16(clampToInt16(leftSideBearing));
        }

        Writer vmtx;
        int32_t advanceHeightMax = 0;
        int32_t minTopSideBearing = 32767, minBottomSideBearing = 32767, yMaxExtent = -32768;
        if (m_hasVerticalMetrics) {
            for (uint32_t glyph = 0; glyph < m_numGlyphs; ++glyph) {
                const BBox& box = bounds[glyph];
                int32_t advance = m_verticalAdvances[glyph];
                int32_t topSideBearing = m_topSideBearings[glyph];
                advanceHeightMax = std::max(advanceHeightMax, advance);
                if (box.valid) {
                    minTopSideBearing = std::min(minTopSideBearing, topSideBearing);
                    minBottomSideBearing = std::min(minBottomSideBearing, advance - topSideBearing - (box.yMax - box.yMin));
                    yMaxExtent = std::max(yMaxExtent, topSideBearing + (box.yMax - box.yMin));
                }
                vmtx.u16(uint16_t(advance));
                vmtx.s16(clampToInt16(topSideBearing));
            }
        }

        Reader os2Metrics = m_sfnt.tableReader(os2Tag);
        Reader hheaMetrics = m_sfnt.tableReader(hheaTag);
        const uint8_t* typo = os2Metrics.bytesAt(68, 6);
        const uint8_t* horizontal = hheaMetrics.bytesAt(4, 6);
        bool synchronizeVerticalMetrics = typo && horizontal && !std::memcmp(typo, horizontal, 6);

        auto writeBE16At = [](std::vector<uint8_t>& bytes, size_t offset, int16_t v) {
            bytes[offset] = uint8_t(uint16_t(v) >> 8);
            bytes[offset + 1] = uint8_t(uint16_t(v));
        };
        std::vector<std::pair<uint32_t, std::vector<uint8_t>>> outTables;
        for (const auto& table : m_sfnt.tables) {
            if (isVariationTableTag(table.tag) || table.tag == tagFor('D', 'S', 'I', 'G') || table.tag == cff2Tag || table.tag == cffTag)
                continue;
            const uint8_t* bytes = m_sfnt.whole.bytesAt(table.offset, table.length);
            if (!bytes)
                return nullptr;
            std::vector<uint8_t> copy(bytes, bytes + table.length);
            switch (table.tag) {
            case hmtxTag:
                copy = hmtx.vector();
                break;
            case vmtxTag:
                if (m_hasVerticalMetrics)
                    copy = vmtx.vector();
                break;
            case headTag:
                if (copy.size() < 54)
                    return nullptr;
                if (anyContours) {
                    writeBE16At(copy, 36, clampToInt16(fontBBox.xMin));
                    writeBE16At(copy, 38, clampToInt16(fontBBox.yMin));
                    writeBE16At(copy, 40, clampToInt16(fontBBox.xMax));
                    writeBE16At(copy, 42, clampToInt16(fontBBox.yMax));
                }
                break;
            case hheaTag:
                if (copy.size() < 36)
                    return nullptr;
                writeBE16At(copy, 10, int16_t(uint16_t(std::min<int32_t>(advanceWidthMax, 65535))));
                if (anyContours) {
                    writeBE16At(copy, 12, clampToInt16(minLeftSideBearing));
                    writeBE16At(copy, 14, clampToInt16(minRightSideBearing));
                    writeBE16At(copy, 16, clampToInt16(xMaxExtent));
                }
                writeBE16At(copy, 34, int16_t(m_numGlyphs));
                if (synchronizeVerticalMetrics) {
                    const uint32_t tags[] = { tagFor('h', 'a', 's', 'c'), tagFor('h', 'd', 's', 'c'), tagFor('h', 'l', 'g', 'p') };
                    for (size_t i = 0; i < 3; ++i) {
                        auto delta = globalDeltas.find(tags[i]);
                        if (delta == globalDeltas.end())
                            continue;
                        int16_t original = int16_t((uint16_t(copy[4 + 2 * i]) << 8) | copy[5 + 2 * i]);
                        double value = original + std::floor(delta->second + 0.5);
                        if (value < -32768 || value > 32767)
                            return nullptr;
                        writeBE16At(copy, 4 + 2 * i, int16_t(value));
                    }
                }
                break;
            case vheaTag:
                if (!m_hasVerticalMetrics)
                    break;
                if (copy.size() < 36)
                    return nullptr;
                writeBE16At(copy, 10, int16_t(uint16_t(std::min<int32_t>(advanceHeightMax, 65535))));
                if (anyContours) {
                    writeBE16At(copy, 12, clampToInt16(minTopSideBearing));
                    writeBE16At(copy, 14, clampToInt16(minBottomSideBearing));
                    writeBE16At(copy, 16, clampToInt16(yMaxExtent));
                }
                writeBE16At(copy, 34, int16_t(m_numGlyphs));
                break;
            case vorgTag:
                if (m_variesVerticalOrigins)
                    copy = verticalOriginTable();
                break;
            case os2Tag:
                if (m_pinned)
                    applyPinnedClasses(copy, m_axes, m_pinnedDesignValues);
                break;
            default:
                break;
            }
            if (!instanceLayoutTable(m_sfnt, table.tag, copy, m_coords) || !applyMetricVariations(table.tag, copy, globalDeltas))
                return nullptr;
            outTables.emplace_back(table.tag, std::move(copy));
        }
        outTables.emplace_back(cffTag, cff);
        return assembleSfnt(tagFor('O', 'T', 'T', 'O'), outTables);
    }

    // VORG for the varied origins: the most common one as the default, every other glyph listed.
    std::vector<uint8_t> verticalOriginTable() const
    {
        std::vector<int32_t> sorted = m_verticalOrigins;
        std::sort(sorted.begin(), sorted.end());
        int32_t mostCommon = sorted.empty() ? 0 : sorted[0];
        size_t best = 0;
        for (size_t i = 0; i < sorted.size();) {
            size_t j = i;
            while (j < sorted.size() && sorted[j] == sorted[i])
                ++j;
            if (j - i > best) {
                best = j - i;
                mostCommon = sorted[i];
            }
            i = j;
        }
        Writer out;
        out.u16(1);
        out.u16(0);
        out.s16(clampToInt16(mostCommon));
        size_t countPosition = out.size();
        out.u16(0);
        uint16_t count = 0;
        for (uint32_t glyph = 0; glyph < m_numGlyphs; ++glyph) {
            if (m_verticalOrigins[glyph] == mostCommon)
                continue;
            out.u16(uint16_t(glyph));
            out.s16(clampToInt16(m_verticalOrigins[glyph]));
            ++count;
        }
        out.vector()[countPosition] = uint8_t(count >> 8);
        out.vector()[countPosition + 1] = uint8_t(count);
        return out.vector();
    }

    const ParsedSfnt& m_sfnt;
    bool m_pinned { false };
    std::vector<LegacyVariableFontAxis> m_axes;
    std::vector<float> m_coords;
    std::vector<double> m_pinnedDesignValues;
    uint32_t m_numGlyphs { 0 };
    std::vector<int32_t> m_advances;
    std::vector<int32_t> m_leftSideBearings;
    bool m_hasVerticalMetrics { false };
    std::vector<int32_t> m_verticalAdvances;
    std::vector<int32_t> m_topSideBearings;
    bool m_variesVerticalOrigins { false };
    std::vector<int32_t> m_verticalOrigins;
};

// A variable font this file can cut: fvar over glyf outlines with gvar, or over a CFF2 table.
static bool isInstanceable(const ParsedSfnt& sfnt)
{
    return sfnt.find(fvarTag) && ((sfnt.find(gvarTag) && sfnt.find(glyfTag)) || sfnt.find(cff2Tag));
}

std::vector<LegacyVariableFontAxis> legacyVariableFontAxes(CFDataRef data)
{
    auto sfnt = parseSfnt(data);
    if (!sfnt || !isInstanceable(*sfnt))
        return { };
    return parseFvarAxes(*sfnt);
}

CFDataRef createLegacyVariableFontInstance(CFDataRef data, const std::vector<std::pair<uint32_t, double>>& pinnedAxisValues)
{
    auto sfnt = parseSfnt(data);
    if (!sfnt)
        return nullptr;
    if (sfnt->find(cff2Tag))
        return CFF2Instancer(*sfnt).instance(pinnedAxisValues);
    Instancer instancer(*sfnt);
    return instancer.instance(pinnedAxisValues);
}

CFDataRef createFontDataWithVariationTablesStripped(CFDataRef input)
{
    auto retainInput = [&]() -> CFDataRef {
        CFRetain(input);
        return input;
    };
    auto sfnt = parseSfnt(input);
    if (!sfnt)
        return retainInput();
    // CFF2 outlines, variable or not, become CFF ones at the fvar defaults.
    if (sfnt->find(cff2Tag)) {
        if (CFDataRef converted = CFF2Instancer(*sfnt).instance({ }))
            return converted;
        return retainInput();
    }
    if (!sfnt->find(fvarTag))
        return retainInput();

    auto axes = parseFvarAxes(*sfnt);
    std::vector<float> defaultCoords(axes.size(), 0);
    if (!applyAvar(*sfnt, defaultCoords))
        return retainInput();
    std::map<uint32_t, double> defaultMetrics;
    if (!metricVariations(*sfnt, defaultCoords, defaultMetrics))
        return retainInput();
    bool changesDefault = std::any_of(defaultCoords.begin(), defaultCoords.end(), [](float coordinate) { return coordinate != 0; })
        || std::any_of(defaultMetrics.begin(), defaultMetrics.end(), [](const auto& metric) { return metric.second != 0; });
    if (changesDefault && sfnt->find(gvarTag) && sfnt->find(glyfTag)) {
        Instancer instancer(*sfnt);
        if (CFDataRef instance = instancer.instance({ }))
            return instance;
        return retainInput();
    }
    std::vector<std::pair<uint32_t, std::vector<uint8_t>>> outTables;
    for (const auto& table : sfnt->tables) {
        if (isVariationTableTag(table.tag))
            continue;
        const uint8_t* bytes = sfnt->whole.bytesAt(table.offset, table.length);
        if (!bytes || !table.length)
            continue;
        std::vector<uint8_t> copy(bytes, bytes + table.length);
        if (!instanceLayoutTable(*sfnt, table.tag, copy, defaultCoords))
            return retainInput();
        outTables.emplace_back(table.tag, std::move(copy));
    }
    if (outTables.empty() || outTables.size() == sfnt->tables.size())
        return retainInput();
    if (CFDataRef assembled = assembleSfnt(sfnt->sfntVersion, outTables))
        return assembled;
    // The font cannot be safely rewritten (e.g. overlapping table records summing past
    // the size cap) — hand back the input unmodified and let CoreText reject it.
    return retainInput();
}

// The pinned value for every axis of `sfnt`, given a kCTFontVariationAttribute dictionary: an
// axis named there takes that value clamped to its own range, any other axis stays at its fvar
// default. Empty when the font is not instanceable or when nothing differs from the defaults —
// in both cases the default master is the right answer and no cut is needed.
std::vector<std::pair<uint32_t, double>> pinnedAxisValues(CFDataRef sfnt, CFDictionaryRef variations)
{
    auto axes = legacyVariableFontAxes(sfnt);
    if (axes.empty())
        return { };

    // kCTFontVariationAttribute keys an axis by a CFNumber holding its four-character code.
    std::vector<std::pair<uint32_t, double>> requested;
    CFIndex count = CFDictionaryGetCount(variations);
    std::vector<const void*> keys(count ? count : 1);
    std::vector<const void*> values(count ? count : 1);
    CFDictionaryGetKeysAndValues(variations, keys.data(), values.data());
    for (CFIndex i = 0; i < count; ++i) {
        long long raw = 0;
        if (CFGetTypeID(keys[i]) != CFNumberGetTypeID()
            || !CFNumberGetValue(static_cast<CFNumberRef>(keys[i]), kCFNumberLongLongType, &raw))
            continue;
        uint32_t tag = static_cast<uint32_t>(raw);
        if (CFGetTypeID(values[i]) != CFNumberGetTypeID())
            continue;
        double value = 0;
        if (CFNumberGetValue(static_cast<CFNumberRef>(values[i]), kCFNumberDoubleType, &value) && !std::isnan(value))
            requested.emplace_back(tag, value);
    }

    std::vector<std::pair<uint32_t, double>> pins;
    pins.reserve(axes.size());
    bool allDefault = true;
    for (const auto& axis : axes) {
        double value = axis.defaultValue;
        for (const auto& entry : requested) {
            if (entry.first == axis.tag)
                value = entry.second;
        }
        value = std::min(axis.maximumValue, std::max(axis.minimumValue, value));
        allDefault &= value == axis.defaultValue;
        pins.emplace_back(axis.tag, value);
    }
    return allDefault ? std::vector<std::pair<uint32_t, double>> { } : pins;
}

// The canonical key of a pinned-value set: every axis's value in fvar order, so that every request
// realizing one instance has one key.
std::string instanceKey(const std::vector<std::pair<uint32_t, double>>& pins)
{
    std::string key;
    char buffer[48];
    for (const auto& [tag, value] : pins) {
        snprintf(buffer, sizeof(buffer), "%c%c%c%c=%a;", char(tag >> 24), char(tag >> 16), char(tag >> 8), char(tag), value);
        key += buffer;
    }
    return key;
}

} // anonymous namespace

bool wk_legacy_variable_font_is_instanceable(CFDataRef sfnt)
{
    return sfnt && !legacyVariableFontAxes(sfnt).empty();
}

CFDataRef wk_legacy_variable_font_strip_variations(CFDataRef sfnt)
{
    if (!sfnt)
        return nullptr;
    return createFontDataWithVariationTablesStripped(sfnt);
}

CFDataRef wk_legacy_variable_font_instance(CFDataRef sfnt, CFDictionaryRef ctVariationAttribute)
{
    if (!sfnt || !ctVariationAttribute || CFGetTypeID(ctVariationAttribute) != CFDictionaryGetTypeID())
        return nullptr;
    auto pins = pinnedAxisValues(sfnt, ctVariationAttribute);
    return pins.empty() ? nullptr : createLegacyVariableFontInstance(sfnt, pins);
}

CFStringRef wk_legacy_variable_font_copy_instance_key(CFDataRef sfnt, CFDictionaryRef ctVariationAttribute)
{
    if (!sfnt || !ctVariationAttribute || CFGetTypeID(ctVariationAttribute) != CFDictionaryGetTypeID())
        return nullptr;
    auto pins = pinnedAxisValues(sfnt, ctVariationAttribute);
    if (pins.empty())
        return nullptr;
    std::string key = instanceKey(pins);
    return CFStringCreateWithBytes(kCFAllocatorDefault, reinterpret_cast<const UInt8*>(key.data()), CFIndex(key.size()), kCFStringEncodingASCII, false);
}

CFIndex wk_legacy_variable_font_copy_axes(CFDataRef sfnt, wk_legacy_variable_font_axis* axes, CFIndex capacity)
{
    auto parsed = parseSfnt(sfnt);
    if (!parsed || !isInstanceable(*parsed))
        return 0;
    auto list = parseFvarAxes(*parsed);
    for (size_t i = 0; i < list.size() && CFIndex(i) < capacity; ++i) {
        axes[i].tag = list[i].tag;
        axes[i].minimumValue = list[i].fixedMinimumValue;
        axes[i].defaultValue = list[i].fixedDefaultValue;
        axes[i].maximumValue = list[i].fixedMaximumValue;
        axes[i].name = copyNameRecord(*parsed, list[i].nameID);
    }
    return CFIndex(list.size());
}

CFIndex wk_legacy_variable_font_table_tags(CFDataRef sfnt, uint32_t* tags, CFIndex capacity)
{
    auto parsed = parseSfnt(sfnt);
    if (!parsed)
        return 0;
    for (size_t i = 0; i < parsed->tables.size() && CFIndex(i) < capacity; ++i)
        tags[i] = parsed->tables[i].tag;
    return CFIndex(parsed->tables.size());
}

CFDataRef wk_legacy_variable_font_copy_table(CFDataRef sfnt, uint32_t tag)
{
    auto parsed = parseSfnt(sfnt);
    const SfntTable* table = parsed ? parsed->find(tag) : nullptr;
    const uint8_t* bytes = table ? parsed->whole.bytesAt(table->offset, table->length) : nullptr;
    return bytes ? CFDataCreate(kCFAllocatorDefault, bytes, table->length) : nullptr;
}
