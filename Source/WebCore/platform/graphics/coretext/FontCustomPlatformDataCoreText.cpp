/*
 * Copyright (C) 2007-2023 Apple Inc. All rights reserved.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Library General Public License for more details.
 *
 * You should have received a copy of the GNU Library General Public License
 * along with this library; see the file COPYING.LIB.  If not, write to
 * the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA 02110-1301, USA.
 *
 */

#include "config.h"
#include "FontCustomPlatformData.h"

#include "CSSFontFaceSrcValue.h"
#include "Font.h"
#include "FontCache.h"
#include "FontCacheCoreText.h"
#include "FontCreationContext.h"
#include "FontDescription.h"
#include "FontPlatformData.h"
// MAVERICKS_BACKPORT: extra includes for the sfnt variation-table stripper / CGFont font-load path below.
#include <algorithm>
#include <cstring>
#include <wtf/NeverDestroyed.h>
#include <wtf/Vector.h>
#include <wtf/RetainPtr.h>
#include "SharedBuffer.h"
#include "StyleFontSizeFunctions.h"
#include "UnrealizedCoreTextFont.h"
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include <pal/spi/cf/CoreTextSPI.h>

namespace WebCore {

FontCustomPlatformData::~FontCustomPlatformData() = default;

FontPlatformData FontCustomPlatformData::fontPlatformData(const FontDescription& fontDescription, bool bold, bool italic, const FontCreationContext& fontCreationContext)
{
    auto size = fontDescription.adjustedSizeForFontFace(fontCreationContext.sizeAdjust());
    UnrealizedCoreTextFont unrealizedFont = { RetainPtr { fontDescriptor } };
    unrealizedFont.setSize(size);
    unrealizedFont.modify([&](CFMutableDictionaryRef attributes) {
        addAttributesForWebFonts(attributes, fontDescription.shouldAllowUserInstalledFonts());
    });

    FontOrientation orientation = fontDescription.orientation();
    FontWidthVariant widthVariant = fontDescription.widthVariant();

    auto font = preparePlatformFont(WTF::move(unrealizedFont), fontDescription, fontCreationContext);
    ASSERT(font);
    FontPlatformData platformData(font.get(), size, bold, italic, orientation, widthVariant, fontDescription.textRenderingMode(), this);

    platformData.updateSizeWithFontSizeAdjust(fontDescription.fontSizeAdjust(), fontDescription.computedSize());
    return platformData;
}

static RetainPtr<CFDataRef> extractFontCustomPlatformDataShared(RetainPtr<CFArrayRef>&& array, const String& itemInCollection)
{
    if (!array)
        return nullptr;

    FPFontRef font = nullptr;

    auto length = CFArrayGetCount(array.get());
    if (length <= 0)
        return nullptr;
    if (!itemInCollection.isNull()) {
        if (auto desiredName = itemInCollection.createCFString()) {
            for (CFIndex i = 0; i < length; ++i) {
                auto candidate = static_cast<FPFontRef>(CFArrayGetValueAtIndex(array.get(), i));
                auto postScriptName = adoptCF(FPFontCopyPostScriptName(candidate));
                if (CFStringCompare(postScriptName.get(), desiredName.get(), 0) == kCFCompareEqualTo) {
                    font = candidate;
                    break;
                }
            }
        }
    }
    if (!font)
        font = static_cast<FPFontRef>(CFArrayGetValueAtIndex(array.get(), 0));

    // Retain the extracted font contents, so the GPU process doesn't have to extract it a second time later.
    // This is a power optimization.
    return adoptCF(FPFontCopySFNTData(font));
}

static RetainPtr<CFDataRef> extractFontCustomPlatformDataSystemParser(const SharedBuffer& buffer, const String& itemInCollection)
{
    RetainPtr bufferData = buffer.createCFData();

    RetainPtr array = adoptCF(FPFontCreateFontsFromData(bufferData.get()));
    return extractFontCustomPlatformDataShared(WTF::move(array), itemInCollection);
}

#if HAVE(CTFONTMANAGER_CREATEMEMORYSAFEFONTDESCRIPTORFROMDATA)
static RetainPtr<CFDataRef> extractFontCustomPlatformDataMemorySafe(const SharedBuffer& buffer, const String& itemInCollection)
{
    RetainPtr bufferData = buffer.createCFData();

    RetainPtr array = adoptCF(FPFontCreateMemorySafeFontsFromData(bufferData.get()));
    return extractFontCustomPlatformDataShared(WTF::move(array), itemInCollection);
}
#endif

// MAVERICKS_BACKPORT: big-endian sfnt byte helpers + checksum for the legacy-CoreText
// variation-table stripper and CGFont-based font loader below.
static inline uint32_t readBE32(const uint8_t* p) { return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | p[3]; }
static inline uint16_t readBE16(const uint8_t* p) { return (uint16_t(p[0]) << 8) | p[1]; }
static inline void writeBE32(uint8_t* p, uint32_t v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }
static inline void writeBE16(uint8_t* p, uint16_t v) { p[0] = v >> 8; p[1] = v; }

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

// MAVERICKS_BACKPORT: macOS 10.9's CoreText predates OpenType 1.8 variable fonts and instances them via its
// legacy TrueType-GX path. A single-axis font (lone 'wght' — Inter, Open Sans) instances correctly, but
// the moment a font carries a SECOND axis ('wdth'/'opsz'/… — Mona Sans / GitHub's UI font, Roboto Flex)
// the CGFont we build from it (CGFontCreateWithDataProvider, below) produces collapsed/empty glyph
// outlines, so the text renders as a handful of stray glyphs or nothing at all. Pinning fewer axes or
// dropping the kCTFontVariationAttribute at realize() time does NOT help — the CGFont itself is broken.
// The static (non-variable) build of the very same typeface renders perfectly through this same code
// path, so for multi-axis fonts we rewrite the sfnt to drop the variation tables (fvar/gvar/avar/…),
// turning it into its default (Regular) master. Glyphs then render correctly; width/optical-size/weight
// axis selection is lost and WebKit synthesizes bold/oblique as needed. Single-axis fonts are left
// untouched so they keep real weight interpolation.
static RetainPtr<CFDataRef> stripVariationTablesForLegacyCoreText(CFDataRef input)
{
    if (!input)
        return input;
    const uint8_t* data = CFDataGetBytePtr(input);
    CFIndex size = CFDataGetLength(input);
    if (size < 12)
        return input;

    uint32_t sfntVersion = readBE32(data);
    // Only single TrueType-outline sfnts (0x00010000 / 'true'). Skip collections ('ttcf') and CFF ('OTTO').
    if (sfntVersion != 0x00010000 && sfntVersion != 0x74727565)
        return input;

    uint16_t numTables = readBE16(data + 4);
    if (size < 12 + CFIndex(numTables) * 16)
        return input;

    struct Record { uint32_t tag, checksum, offset, length; };
    Vector<Record> records;
    records.reserveInitialCapacity(numTables);
    int fvarIndex = -1;
    for (uint16_t i = 0; i < numTables; ++i) {
        const uint8_t* r = data + 12 + i * 16;
        Record rec { readBE32(r), readBE32(r + 4), readBE32(r + 8), readBE32(r + 12) };
        if (rec.tag == 0x66766172 /* 'fvar' */)
            fvarIndex = records.size();
        records.append(rec);
    }

    if (fvarIndex < 0)
        return input; // Not a variable font.

    // Read the axis count from the fvar header (axisCount is a uint16 at byte 8 of the table).
    const Record& fvar = records[fvarIndex];
    if (fvar.offset + 10 > uint32_t(size))
        return input;
    uint16_t axisCount = readBE16(data + fvar.offset + 8);
    if (axisCount <= 1)
        return input; // Single-axis variable fonts instance correctly on 10.9 — leave them alone.

    auto isVariationTable = [](uint32_t tag) {
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
    };

    Vector<Record> kept;
    for (const auto& rec : records) {
        if (!isVariationTable(rec.tag) && rec.offset && rec.length && rec.offset + rec.length <= uint32_t(size))
            kept.append(rec);
    }
    if (kept.size() == records.size() || kept.isEmpty())
        return input; // Nothing to strip, or the font is too corrupt to safely rewrite — leave it alone.
    // sfnt requires table records sorted ascending by tag.
    std::sort(kept.begin(), kept.end(), [](const Record& a, const Record& b) { return a.tag < b.tag; });

    uint16_t newNumTables = kept.size();
    uint32_t headerSize = 12 + uint32_t(newNumTables) * 16;
    uint32_t total = headerSize;
    for (const auto& rec : kept)
        total += (rec.length + 3) & ~3u;

    Vector<uint8_t> out(total, 0);
    uint8_t* o = out.mutableSpan().data();
    // Offset table.
    writeBE32(o, sfntVersion);
    writeBE16(o + 4, newNumTables);
    uint16_t entrySelector = 0;
    while ((1u << (entrySelector + 1)) <= newNumTables)
        ++entrySelector;
    uint16_t searchRange = (1u << entrySelector) * 16;
    writeBE16(o + 6, searchRange);
    writeBE16(o + 8, entrySelector);
    writeBE16(o + 10, uint16_t(newNumTables * 16 - searchRange));

    uint32_t dataOffset = headerSize;
    int headOutputOffset = -1;
    for (uint16_t i = 0; i < newNumTables; ++i) {
        const Record& rec = kept[i];
        memcpy(o + dataOffset, data + rec.offset, rec.length);
        if (rec.tag == 0x68656164 /* 'head' */ && rec.length >= 12) {
            headOutputOffset = dataOffset;
            // checkSumAdjustment (bytes 8..12) must be zero while checksums are computed.
            writeBE32(o + dataOffset + 8, 0);
        }
        uint32_t checksum = sfntTableChecksum(o + dataOffset, rec.length);
        uint8_t* recOut = o + 12 + i * 16;
        writeBE32(recOut, rec.tag);
        writeBE32(recOut + 4, checksum);
        writeBE32(recOut + 8, dataOffset);
        writeBE32(recOut + 12, rec.length);
        dataOffset += (rec.length + 3) & ~3u;
    }

    // head.checkSumAdjustment = 0xB1B0AFBA - checksum(whole file with the field still zero).
    if (headOutputOffset >= 0)
        writeBE32(o + headOutputOffset + 8, 0xB1B0AFBAu - sfntTableChecksum(o, total));

    return adoptCF(CFDataCreate(kCFAllocatorDefault, o, total));
}

RefPtr<FontCustomPlatformData> FontCustomPlatformData::create(SharedBuffer& buffer, const String& itemInCollection)
{
    // MAVERICKS_BACKPORT: CoreText 10.9's TFontFeatures pipeline crashes on many
    // downloaded fonts (DDG and others) — TBaseFont::CopyFeatures calls
    // CreateFontWithFontURL which message-sends to a freed object.
    //
    // Try the CGFont path first: load via CGDataProviderCreateWithCFData +
    // CGFontCreateWithDataProvider, then create a CTFontDescriptor from the
    // CGFont. The CGFont path avoids triggering TFontFeatures loading because
    // CT skips feature setup when given a CGFont-backed descriptor.
    RetainPtr<CFDataRef> bufferData = buffer.createCFData();
    if (!bufferData)
        return nullptr;
    // MAVERICKS_BACKPORT: neutralize multi-axis variable fonts (see stripVariationTablesForLegacyCoreText).
    bufferData = stripVariationTablesForLegacyCoreText(bufferData.get());
    RetainPtr provider = adoptCF(CGDataProviderCreateWithCFData(bufferData.get()));
    if (!provider)
        return nullptr;
    RetainPtr cgFont = adoptCF(CGFontCreateWithDataProvider(provider.get()));
    if (!cgFont)
        return nullptr;
    // Get a CTFontDescriptor from the CGFont via a CTFont round-trip.
    auto ctFont = adoptCF(CTFontCreateWithGraphicsFont(cgFont.get(), 12.0, nullptr, nullptr));
    if (!ctFont)
        return nullptr;
    RetainPtr fontDescriptor = adoptCF(CTFontCopyFontDescriptor(ctFont.get()));
    if (!fontDescriptor)
        return nullptr;
    Ref bufferRef = SharedBuffer::create(bufferData.get());

    FontPlatformData::CreationData creationData = { WTF::move(bufferRef), itemInCollection };
    return adoptRef(new FontCustomPlatformData(fontDescriptor.get(), WTF::move(creationData)));
}

RefPtr<FontCustomPlatformData> FontCustomPlatformData::createMemorySafe(SharedBuffer& buffer, const String& itemInCollection)
{
#if HAVE(CTFONTMANAGER_CREATEMEMORYSAFEFONTDESCRIPTORFROMDATA)
    RetainPtr extractedData = extractFontCustomPlatformDataMemorySafe(buffer, itemInCollection);
    if (!extractedData) {
        // Something is wrong with the font.
        return nullptr;
    }

    RetainPtr fontDescriptor = adoptCF(CTFontManagerCreateMemorySafeFontDescriptorFromData(extractedData.get()));

    // Safe Font parser could not handle this font. This is already logged by CachedFontLoadRequest::ensureCustomFontData
    if (!fontDescriptor)
        return nullptr;

    Ref bufferRef = SharedBuffer::create(extractedData.get());

    FontPlatformData::CreationData creationData = { WTF::move(bufferRef), itemInCollection };
    return adoptRef(new FontCustomPlatformData(fontDescriptor.get(), WTF::move(creationData)));
#else
    UNUSED_PARAM(buffer);
    UNUSED_PARAM(itemInCollection);
    return nullptr;
#endif
}

std::optional<Ref<FontCustomPlatformData>> FontCustomPlatformData::tryMakeFromSerializationData(FontCustomPlatformSerializedData&& data, bool shouldUseLockdownFontParser )
{
    RefPtr fontCustomPlatformData = shouldUseLockdownFontParser ? FontCustomPlatformData::createMemorySafe(WTF::move(data.fontFaceData), data.itemInCollection) : FontCustomPlatformData::create(WTF::move(data.fontFaceData), data.itemInCollection);
    if (!fontCustomPlatformData)
        return std::nullopt;
    fontCustomPlatformData->m_renderingResourceIdentifier = data.renderingResourceIdentifier;
    return fontCustomPlatformData.releaseNonNull();
}

FontCustomPlatformSerializedData FontCustomPlatformData::serializedData() const
{
    return FontCustomPlatformSerializedData { creationData.fontFaceData, creationData.itemInCollection, m_renderingResourceIdentifier };
}

bool FontCustomPlatformData::supportsFormat(const String& format)
{
    return equalLettersIgnoringASCIICase(format, "truetype"_s)
        || equalLettersIgnoringASCIICase(format, "opentype"_s)
        || equalLettersIgnoringASCIICase(format, "woff2"_s)
        || equalLettersIgnoringASCIICase(format, "woff2-variations"_s)
        || equalLettersIgnoringASCIICase(format, "woff-variations"_s)
        || equalLettersIgnoringASCIICase(format, "truetype-variations"_s)
        || equalLettersIgnoringASCIICase(format, "opentype-variations"_s)
        || equalLettersIgnoringASCIICase(format, "woff"_s)
        || equalLettersIgnoringASCIICase(format, "svg"_s);
}

bool FontCustomPlatformData::supportsTechnology(const FontTechnology& tech)
{
    switch (tech) {
    case FontTechnology::ColorColrv0:
    case FontTechnology::ColorSbix:
    case FontTechnology::ColorSvg:
    case FontTechnology::FeaturesAat:
    case FontTechnology::FeaturesOpentype:
    case FontTechnology::Palettes:
    case FontTechnology::Variations:
        return true;
    default:
        return false;
    }
}

}
