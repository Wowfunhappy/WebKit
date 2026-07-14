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
// MAVERICKS_BACKPORT: extra includes for the software variable-font instancer wiring
// below — <algorithm> for the axis-value clamps, StringBuilder for the instance-cache key.
#include "LegacyCoreTextVariableFontInstancer.h"
#include <algorithm>
#include <wtf/RetainPtr.h>
#include <wtf/text/StringBuilder.h>
#include "SharedBuffer.h"
#include "StyleFontSizeFunctions.h"
#include "UnrealizedCoreTextFont.h"
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include <pal/spi/cf/CoreTextSPI.h>

namespace WebCore {

FontCustomPlatformData::~FontCustomPlatformData() = default;

// MAVERICKS_BACKPORT: the pinned axis values for one realization of a variable font,
// mirroring UnrealizedCoreTextFont::modifyFromContext's variation selection: the
// wght/wdth/slnt (or ital) axes track the font-selection request clamped to the
// @font-face capabilities, any other axis stays at its default, and CSS
// font-variation-settings override per the css-fonts-4 precedence.
static std::vector<std::pair<uint32_t, float>> pinnedAxisValuesForDescription(const std::vector<LegacyVariableFontAxis>& axes, const FontDescription& fontDescription, const FontCreationContext& fontCreationContext)
{
    auto request = fontDescription.fontSelectionRequest();
    float weight = request.weight;
    float width = request.width;
    float slope = request.slope.value_or(normalItalicValue());
    if (auto weightValue = fontCreationContext.fontFaceCapabilities().weight)
        weight = std::max(std::min(weight, static_cast<float>(weightValue->maximum)), static_cast<float>(weightValue->minimum));
    if (auto widthValue = fontCreationContext.fontFaceCapabilities().width)
        width = std::max(std::min(width, static_cast<float>(widthValue->maximum)), static_cast<float>(widthValue->minimum));
    if (auto slopeValue = fontCreationContext.fontFaceCapabilities().slope)
        slope = std::max(std::min(slope, static_cast<float>(slopeValue->maximum)), static_cast<float>(slopeValue->minimum));

    constexpr uint32_t wghtTag = 0x77676874;
    constexpr uint32_t wdthTag = 0x77647468;
    constexpr uint32_t slntTag = 0x736C6E74;
    constexpr uint32_t italTag = 0x6974616C;
    // An 'opsz' axis stays at its fvar default (upstream applies automatic optical
    // sizing from the font size; a per-size static instance per element size would
    // defeat the instance cache). Explicit font-variation-settings 'opsz' still pins.

    std::vector<std::pair<uint32_t, float>> pins;
    pins.reserve(axes.size());
    for (const auto& axis : axes) {
        float value = axis.defaultValue;
        if (axis.tag == wghtTag)
            value = weight;
        else if (axis.tag == wdthTag)
            value = width;
        else if (axis.tag == slntTag && fontDescription.fontStyleAxis() != FontStyleAxis::ital)
            value = slope;
        else if (axis.tag == italTag && fontDescription.fontStyleAxis() == FontStyleAxis::ital)
            value = 1;
        for (auto& variationSetting : fontDescription.variationSettings()) {
            auto tag = variationSetting.tag();
            uint32_t rawTag = (uint32_t(uint8_t(tag[0])) << 24) | (uint32_t(uint8_t(tag[1])) << 16) | (uint32_t(uint8_t(tag[2])) << 8) | uint8_t(tag[3]);
            if (rawTag == axis.tag)
                value = variationSetting.value();
        }
        value = std::min(axis.maximumValue, std::max(axis.minimumValue, value));
        pins.emplace_back(axis.tag, value);
    }
    return pins;
}

FontPlatformData FontCustomPlatformData::fontPlatformData(const FontDescription& fontDescription, bool bold, bool italic, const FontCreationContext& fontCreationContext)
{
    auto size = fontDescription.adjustedSizeForFontFace(fontCreationContext.sizeAdjust());
    // MAVERICKS_BACKPORT: for variable fonts, realize from a software-cut static
    // instance at the requested axis values (cached per pinned-value set); the member
    // fontDescriptor is the stripped default master and serves as the fallback.
    RetainPtr<CTFontDescriptorRef> descriptor = fontDescriptor;
    if (!m_legacyVariableFontAxes.empty()) {
        auto pins = pinnedAxisValuesForDescription(m_legacyVariableFontAxes, fontDescription, fontCreationContext);
        bool allDefault = true;
        for (size_t i = 0; i < pins.size(); ++i)
            allDefault &= pins[i].second == m_legacyVariableFontAxes[i].defaultValue;
        if (!allDefault) {
            StringBuilder keyBuilder;
            for (const auto& [tag, value] : pins) {
                keyBuilder.append(tag);
                keyBuilder.append('=');
                keyBuilder.append(static_cast<int>(std::lround(value * 100)));
                keyBuilder.append(';');
            }
            String key = keyBuilder.toString();
            Locker locker { m_legacyInstanceCacheLock };
            auto iterator = m_legacyInstanceCache.find(key);
            if (iterator != m_legacyInstanceCache.end())
                descriptor = iterator->value;
            else {
                RetainPtr<CTFontDescriptorRef> instancedDescriptor;
                if (RetainPtr instanced = adoptCF(createLegacyVariableFontInstance(creationData.fontFaceData->createCFData().get(), pins)))
                    instancedDescriptor = adoptCF(CTFontManagerCreateFontDescriptorFromData(instanced.get()));
                if (!instancedDescriptor)
                    instancedDescriptor = fontDescriptor;
                // font-variation-settings is animatable, so pinned-value sets can be
                // minted per frame; the cache is capped, and past the cap instances are
                // realized uncached (bounded memory — a pathological animated axis pays
                // CPU, not RSS). Each entry holds a full static sfnt via its descriptor.
                static constexpr unsigned maximumCachedInstances = 128;
                if (m_legacyInstanceCache.size() < maximumCachedInstances)
                    m_legacyInstanceCache.add(key, instancedDescriptor);
                descriptor = WTF::move(instancedDescriptor);
            }
        }
    }
    UnrealizedCoreTextFont unrealizedFont = { RetainPtr { descriptor } };
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

RefPtr<FontCustomPlatformData> FontCustomPlatformData::create(SharedBuffer& buffer, const String& itemInCollection)
{
// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text;
// 10.9's libFontParser does not export the FPFont system-parser API (FPFontCreateFontsFromData /
// FPFontCopySFNTData), so the already-decompressed buffer is used directly.
//     RetainPtr extractedData = extractFontCustomPlatformDataSystemParser(buffer, itemInCollection);
//     if (!extractedData) {
//         // Something is wrong with the font.
//         return nullptr;
//     }
    RetainPtr<CFDataRef> extractedData = buffer.createCFData();
    if (!extractedData) {
        // Something is wrong with the font.
        return nullptr;
    }
// (end MAVERICKS_BACKPORT restored block)

    // MAVERICKS_BACKPORT: 10.9 cannot instance variable fonts (CT variation attributes are
    // ignored; CGFontCreateCopyWithVariations collapses outlines), so the member descriptor
    // is built from a static strip of the fvar default master, the ORIGINAL variable bytes
    // stay in creationData, and fontPlatformData() below cuts real static instances at the
    // requested axis values (see LegacyCoreTextVariableFontInstancer.h). Note the descriptor
    // call below binds to libpolyfill's CGFont-backed CTFontManagerCreateFontDescriptorFromData
    // (graphics_shims.c): 10.9's own returns descriptors that crash in TFontFeatures at
    // realize time.
    // KNOWN GAP: consumers that rebuild a font straight from creationData's bytes with the
    // member descriptor (Font::fromIPCData / FontPlatformData::fromIPCData — the GPU-process
    // font IPC round trip) render the DEFAULT master, not a pinned instance. Dormant here:
    // this port draws with the TiledCoreAnimation drawing area, so fonts never take that path.
    RetainPtr<CFDataRef> strippedData = adoptCF(createFontDataWithVariationTablesStripped(extractedData.get()));

    RetainPtr fontDescriptor = adoptCF(CTFontManagerCreateFontDescriptorFromData(strippedData.get()));
    // MAVERICKS_BACKPORT: reject fonts even the CGFont-backed descriptor path cannot parse.
    if (!fontDescriptor)
        return nullptr;
    Ref bufferRef = SharedBuffer::create(extractedData.get());

    FontPlatformData::CreationData creationData = { WTF::move(bufferRef), itemInCollection };
    RefPtr result = adoptRef(new FontCustomPlatformData(fontDescriptor.get(), WTF::move(creationData)));
    // MAVERICKS_BACKPORT: record the variable axes for the software instancer.
    result->m_legacyVariableFontAxes = legacyVariableFontAxes(extractedData.get());
    return result;
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
