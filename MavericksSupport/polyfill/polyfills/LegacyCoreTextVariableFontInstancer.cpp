/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

// Software variable-font instancer for legacy (10.9) CoreText. See the header for why this
// exists. The implementation follows the OpenType 1.8 fvar/avar/gvar specification: normalize
// the pinned axis coordinates, compute each tuple's scalar, apply the interpolated per-point
// deltas (including IUP inference for unreferenced points and the four phantom points) to every
// glyph, then reassemble a static sfnt with rebuilt glyf/loca/hmtx/head/hhea and the variation
// tables dropped.
//
// Everything but the three C entry points at the bottom has internal linkage: this object is
// force-loaded into every shipped WebKit binary as part of libpolyfill.a, and nothing outside
// graphics.c has any business calling into it.
#include "LegacyCoreTextVariableFontInstancer.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <map>
#include <optional>
#include <pthread.h>
#include <string>
#include <utility>
#include <vector>

namespace {

struct LegacyVariableFontAxis {
    uint32_t tag { 0 };
    float minimumValue { 0 };
    float defaultValue { 0 };
    float maximumValue { 0 };
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
    // Only single TrueType-outline sfnts (0x00010000 / 'true'). Collections ('ttcf') and CFF ('OTTO') are not handled.
    if (sfnt.sfntVersion != 0x00010000 && sfnt.sfntVersion != 0x74727565)
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
        axis.minimumValue = fvar.fixed();
        axis.defaultValue = fvar.fixed();
        axis.maximumValue = fvar.fixed();
        if (fvar.failed() || axis.minimumValue > axis.defaultValue || axis.defaultValue > axis.maximumValue)
            return { };
        axes.push_back(axis);
    }
    return axes;
}

// avar: piecewise-linear mapping of each axis's normalized coordinate.
static bool applyAvar(const ParsedSfnt& sfnt, std::vector<float>& normalizedCoords)
{
    if (!sfnt.find(avarTag))
        return true;
    Reader avar = sfnt.tableReader(avarTag);
    uint16_t majorVersion = avar.u16();
    avar.u16(); // minorVersion
    avar.u16(); // reserved
    uint16_t axisCount = avar.u16();
    if (avar.failed() || majorVersion != 1 || axisCount != normalizedCoords.size())
        return false;
    for (uint16_t axis = 0; axis < axisCount; ++axis) {
        uint16_t positionMapCount = avar.u16();
        float coord = normalizedCoords[axis];
        float mapped = coord;
        float previousFrom = -2, previousTo = -2;
        bool done = false;
        for (uint16_t i = 0; i < positionMapCount; ++i) {
            float from = avar.f2dot14();
            float to = avar.f2dot14();
            if (!done) {
                if (coord == from) {
                    mapped = to;
                    done = true;
                } else if (coord < from) {
                    if (i && from != previousFrom)
                        mapped = previousTo + (to - previousTo) * (coord - previousFrom) / (from - previousFrom);
                    else
                        mapped = to;
                    done = true;
                }
            }
            previousFrom = from;
            previousTo = to;
        }
        if (avar.failed())
            return false;
        normalizedCoords[axis] = std::min(1.0f, std::max(-1.0f, mapped));
    }
    return true;
}

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

    void add(float x, float y)
    {
        int32_t xi = int32_t(std::lround(x));
        int32_t yi = int32_t(std::lround(y));
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

    CFDataRef instance(const std::vector<std::pair<uint32_t, float>>& pinnedAxisValues);

private:
    bool parseMetricsTables();
    bool computeNormalizedCoords(const std::vector<std::pair<uint32_t, float>>& pinnedAxisValues);
    bool instanceAllGlyphs();
    void resolveCompositeBBox(uint16_t glyphID, int depth);
    CFDataRef assemble();

    const ParsedSfnt& m_sfnt;
    std::vector<LegacyVariableFontAxis> m_axes;
    std::vector<float> m_coords;
    std::vector<float> m_pinnedDesignValues;
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

bool Instancer::computeNormalizedCoords(const std::vector<std::pair<uint32_t, float>>& pinnedAxisValues)
{
    m_axes = parseFvarAxes(m_sfnt);
    if (m_axes.empty())
        return false;
    m_coords.resize(m_axes.size());
    m_pinnedDesignValues.resize(m_axes.size());
    for (size_t i = 0; i < m_axes.size(); ++i) {
        const auto& axis = m_axes[i];
        float value = axis.defaultValue;
        for (const auto& [tag, pinnedValue] : pinnedAxisValues) {
            if (tag == axis.tag) {
                value = pinnedValue;
                break;
            }
        }
        value = std::min(axis.maximumValue, std::max(axis.minimumValue, value));
        m_pinnedDesignValues[i] = value;
        float normalized = 0;
        if (value < axis.defaultValue && axis.defaultValue > axis.minimumValue)
            normalized = (value - axis.defaultValue) / (axis.defaultValue - axis.minimumValue);
        else if (value > axis.defaultValue && axis.maximumValue > axis.defaultValue)
            normalized = (value - axis.defaultValue) / (axis.maximumValue - axis.defaultValue);
        m_coords[i] = std::min(1.0f, std::max(-1.0f, normalized));
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
            break;
        }
        default:
            if (table.tag == tagFor('O', 'S', '/', '2') && copy.size() >= 8) {
                // Reflect the pinned instance in the reported weight/width classes so
                // font traits match what the outlines now are.
                auto writeBE16At = [&](size_t offset, uint16_t v) {
                    copy[offset] = uint8_t(v >> 8);
                    copy[offset + 1] = uint8_t(v);
                };
                for (size_t i = 0; i < m_axes.size(); ++i) {
                    if (m_axes[i].tag == tagFor('w', 'g', 'h', 't'))
                        writeBE16At(4, uint16_t(std::min(1000.0f, std::max(1.0f, m_pinnedDesignValues[i]))));
                    else if (m_axes[i].tag == tagFor('w', 'd', 't', 'h')) {
                        static constexpr float widthClassPercentages[] = { 50, 62.5, 75, 87.5, 100, 112.5, 125, 150, 200 };
                        uint16_t widthClass = 5;
                        float best = 1e9;
                        for (uint16_t c = 0; c < 9; ++c) {
                            float distance = std::abs(m_pinnedDesignValues[i] - widthClassPercentages[c]);
                            if (distance < best) {
                                best = distance;
                                widthClass = c + 1;
                            }
                        }
                        writeBE16At(6, widthClass);
                    }
                }
            }
            break;
        }
        outTables.emplace_back(table.tag, std::move(copy));
    }
    return assembleSfnt(m_sfnt.sfntVersion, outTables);
}

CFDataRef Instancer::instance(const std::vector<std::pair<uint32_t, float>>& pinnedAxisValues)
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

std::vector<LegacyVariableFontAxis> legacyVariableFontAxes(CFDataRef data)
{
    auto sfnt = parseSfnt(data);
    if (!sfnt || !sfnt->find(fvarTag) || !sfnt->find(gvarTag) || !sfnt->find(glyfTag))
        return { };
    return parseFvarAxes(*sfnt);
}

CFDataRef createLegacyVariableFontInstance(CFDataRef data, const std::vector<std::pair<uint32_t, float>>& pinnedAxisValues)
{
    auto sfnt = parseSfnt(data);
    if (!sfnt)
        return nullptr;
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
    if (!sfnt || !sfnt->find(fvarTag))
        return retainInput();

    std::vector<std::pair<uint32_t, std::vector<uint8_t>>> outTables;
    for (const auto& table : sfnt->tables) {
        if (isVariationTableTag(table.tag))
            continue;
        const uint8_t* bytes = sfnt->whole.bytesAt(table.offset, table.length);
        if (!bytes || !table.length)
            continue;
        outTables.emplace_back(table.tag, std::vector<uint8_t>(bytes, bytes + table.length));
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
std::vector<std::pair<uint32_t, float>> pinnedAxisValues(CFDataRef sfnt, CFDictionaryRef variations)
{
    auto axes = legacyVariableFontAxes(sfnt);
    if (axes.empty())
        return { };

    // CoreText writes the axis tag as a CFNumber holding the four-character code; accept any
    // number type, and a four-character CFString as well, since kCTFontVariationAttribute is
    // public API and a caller outside WebKit may build it either way.
    std::vector<std::pair<uint32_t, float>> requested;
    CFIndex count = CFDictionaryGetCount(variations);
    std::vector<const void*> keys(count ? count : 1);
    std::vector<const void*> values(count ? count : 1);
    CFDictionaryGetKeysAndValues(variations, keys.data(), values.data());
    for (CFIndex i = 0; i < count; ++i) {
        uint32_t tag = 0;
        if (CFGetTypeID(keys[i]) == CFNumberGetTypeID()) {
            long long raw = 0;
            if (!CFNumberGetValue(static_cast<CFNumberRef>(keys[i]), kCFNumberLongLongType, &raw))
                continue;
            tag = static_cast<uint32_t>(raw);
        } else if (CFGetTypeID(keys[i]) == CFStringGetTypeID()) {
            char buffer[8] = { 0 };
            if (!CFStringGetCString(static_cast<CFStringRef>(keys[i]), buffer, sizeof(buffer), kCFStringEncodingASCII)
                || strlen(buffer) != 4)
                continue;
            tag = tagFor(buffer[0], buffer[1], buffer[2], buffer[3]);
        } else
            continue;
        if (CFGetTypeID(values[i]) != CFNumberGetTypeID())
            continue;
        double value = 0;
        if (CFNumberGetValue(static_cast<CFNumberRef>(values[i]), kCFNumberDoubleType, &value))
            requested.emplace_back(tag, static_cast<float>(value));
    }

    std::vector<std::pair<uint32_t, float>> pins;
    pins.reserve(axes.size());
    bool allDefault = true;
    for (const auto& axis : axes) {
        float value = axis.defaultValue;
        for (const auto& entry : requested) {
            if (entry.first == axis.tag)
                value = entry.second;
        }
        value = std::min(axis.maximumValue, std::max(axis.minimumValue, value));
        allDefault &= value == axis.defaultValue;
        pins.emplace_back(axis.tag, value);
    }
    return allDefault ? std::vector<std::pair<uint32_t, float>> { } : pins;
}

// Cutting an instance parses and re-emits the whole font, and CSS font-variation-settings is
// animatable, so a page can ask for a new pinned-value set every frame. Memoize by source buffer
// and requested variations. Keys hold a reference to the source data so that a freed buffer's
// address cannot be reused by a different font and alias an entry; entries are never evicted, so
// the table is capped and past the cap instances are cut uncached (a pathological animated axis
// then pays CPU, not RSS).
constexpr size_t maximumCachedInstances = 128;

pthread_mutex_t instanceCacheMutex = PTHREAD_MUTEX_INITIALIZER;
// Values (and the retained sources) are immortal, and the table is capped, so a flat vector is both
// small enough to scan and free of the associative containers' weak libc++ helper symbols, which
// libpolyfill.a — force-loaded into every binary — must not carry.
std::vector<std::pair<std::string, CFDataRef>>* instanceCache;

std::string instanceCacheKey(CFDataRef sfnt, CFDictionaryRef variations)
{
    char buffer[64];
    snprintf(buffer, sizeof(buffer), "%p/%ld:", static_cast<const void*>(sfnt), static_cast<long>(CFDataGetLength(sfnt)));
    std::string key = buffer;

    CFIndex count = CFDictionaryGetCount(variations);
    std::vector<const void*> keys(count ? count : 1);
    std::vector<const void*> values(count ? count : 1);
    CFDictionaryGetKeysAndValues(variations, keys.data(), values.data());
    std::vector<std::string> entries;
    entries.reserve(count);
    for (CFIndex i = 0; i < count; ++i) {
        double tag = 0;
        double value = 0;
        if (CFGetTypeID(keys[i]) == CFNumberGetTypeID())
            CFNumberGetValue(static_cast<CFNumberRef>(keys[i]), kCFNumberDoubleType, &tag);
        else if (CFGetTypeID(keys[i]) == CFStringGetTypeID()) {
            char tagBuffer[8] = { 0 };
            if (CFStringGetCString(static_cast<CFStringRef>(keys[i]), tagBuffer, sizeof(tagBuffer), kCFStringEncodingASCII) && strlen(tagBuffer) == 4)
                tag = tagFor(tagBuffer[0], tagBuffer[1], tagBuffer[2], tagBuffer[3]);
        }
        if (CFGetTypeID(values[i]) == CFNumberGetTypeID())
            CFNumberGetValue(static_cast<CFNumberRef>(values[i]), kCFNumberDoubleType, &value);
        snprintf(buffer, sizeof(buffer), "%.0f=%.4f;", tag, value);
        entries.emplace_back(buffer);
    }
    // CFDictionary has no order; sort so that one requested set has one key.
    std::sort(entries.begin(), entries.end());
    for (const auto& entry : entries)
        key += entry;
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
    if (!sfnt || !ctVariationAttribute || CFGetTypeID(ctVariationAttribute) != CFDictionaryGetTypeID()
        || !CFDictionaryGetCount(ctVariationAttribute))
        return nullptr;

    std::string key = instanceCacheKey(sfnt, ctVariationAttribute);

    pthread_mutex_lock(&instanceCacheMutex);
    if (!instanceCache)
        instanceCache = new std::vector<std::pair<std::string, CFDataRef>>();
    for (const auto& entry : *instanceCache) {
        if (entry.first != key)
            continue;
        // A remembered null records that this font declined instancing at these values, so the
        // parse is not retried for every glyph run.
        CFDataRef cached = entry.second;
        pthread_mutex_unlock(&instanceCacheMutex);
        return cached ? static_cast<CFDataRef>(CFRetain(cached)) : nullptr;
    }

    auto pins = pinnedAxisValues(sfnt, ctVariationAttribute);
    CFDataRef instance = pins.empty() ? nullptr : createLegacyVariableFontInstance(sfnt, pins);

    if (instanceCache->size() < maximumCachedInstances) {
        if (instance)
            CFRetain(instance);
        CFRetain(sfnt); // Keeps the address in the key from being reused by another font.
        instanceCache->emplace_back(key, instance);
    }
    pthread_mutex_unlock(&instanceCacheMutex);
    return instance;
}
