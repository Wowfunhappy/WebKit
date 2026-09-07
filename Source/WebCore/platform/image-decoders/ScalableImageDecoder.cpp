/*
 * Copyright (C) 2016-2023 Apple Inc. All rights reserved.
 * Copyright (C) 2008-2009 Torch Mobile, Inc.
 * Copyright (C) Research In Motion Limited 2009-2010. All rights reserved.
 *
 *  This library is free software; you can redistribute it and/or
 *  modify it under the terms of the GNU Library General Public
 *  License as published by the Free Software Foundation; either
 *  version 2 of the License, or (at your option) any later version.
 *
 *  This library is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 *  Library General Public License for more details.
 *
 *  You should have received a copy of the GNU Library General Public License
 *  along with this library; see the file COPYING.LIB.  If not, write to
 *  the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 *  Boston, MA 02110-1301, USA.
 *
 */

#include "config.h"
#include "ScalableImageDecoder.h"

#include "NotImplemented.h"
#include "SharedBuffer.h"
#include <wtf/TZoneMallocInlines.h>

#if !PLATFORM(COCOA)
#include "BMPImageDecoder.h"
#include "GIFImageDecoder.h"
#include "ICOImageDecoder.h"
#include "JPEGImageDecoder.h"
#include "PNGImageDecoder.h"
// MAVERICKS_BACKPORT: upstream's version of the lines below, kept commented rather than deleted so the divergence stays visible in place. Reason: see the note just below the block.
// #include "WEBPImageDecoder.h"
// (end MAVERICKS_BACKPORT restored block)
#endif
// MAVERICKS_BACKPORT: WEBPImageDecoder also compiled on PLATFORM(MAC) so libwebp
// can decode WebP responses that ImageIO can't handle on this build.
#include "WEBPImageDecoder.h"
// MAVERICKS_BACKPORT: PNGImageDecoder likewise, for the animated PNGs ImageIO decodes as one frame.
// USE(PNG) follows the vendored libpng the decoder includes <png.h> from (OptionsMacMavericks.cmake).
#if USE(PNG)
#include "PNGImageDecoder.h"
#endif
#if USE(AVIF)
#include "AVIFImageDecoder.h"
#endif
#if USE(JPEGXL)
#include "JPEGXLImageDecoder.h"
#endif

#if USE(CG)
#include "ImageDecoderCG.h"
#include <ImageIO/ImageIO.h>
#endif

#include <algorithm>
#include <cmath>

#if PLATFORM(COCOA) && USE(JPEGXL)
#include <wtf/darwin/WeakLinking.h>

WTF_WEAK_LINK_FORCE_IMPORT(JxlSignatureCheck);
#endif

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(ScalableImageDecoder);

namespace {

#if !PLATFORM(COCOA)
static bool matchesGIFSignature(std::span<const uint8_t> contents)
{
    return spanHasPrefix(contents, "GIF87a"_span) || spanHasPrefix(contents, "GIF89a"_span);
}

#endif // MAVERICKS_BACKPORT: closes the !PLATFORM(COCOA) guard above, so the PNG signature below is reachable on Cocoa.

#if !PLATFORM(COCOA) || USE(PNG) // MAVERICKS_BACKPORT: matchesAnimatedPNGSignature reads this on PLATFORM(MAC).
static bool matchesPNGSignature(std::span<const uint8_t> contents)
{
    return spanHasPrefix(contents, unsafeMakeSpan("\x89\x50\x4E\x47\x0D\x0A\x1A\x0A", 8));
}
#endif // MAVERICKS_BACKPORT: closes the guard above.

#if !PLATFORM(COCOA) // MAVERICKS_BACKPORT: reopens the guard for the signatures Cocoa does not use.

static bool matchesJPEGSignature(std::span<const uint8_t> contents)
{
    return spanHasPrefix(contents, unsafeMakeSpan("\xFF\xD8\xFF", 3));
}

static bool matchesBMPSignature(std::span<const uint8_t> contents)
{
    return spanHasPrefix(contents, "BM"_span);
}

static bool matchesICOSignature(std::span<const uint8_t> contents)
{
    return spanHasPrefix(contents, unsafeMakeSpan("\x00\x00\x01\x00", 4));
}

static bool matchesCURSignature(std::span<const uint8_t> contents)
{
    return spanHasPrefix(contents, unsafeMakeSpan("\x00\x00\x02\x00", 4));
}

#endif

// MAVERICKS_BACKPORT: also needed on PLATFORM(MAC) for the WebP fallback path.
static bool matchesWebPSignature(std::span<const uint8_t> contents)
{
    return spanHasPrefix(contents, "RIFF"_span) && spanHasPrefix(contents.subspan(8), "WEBPVP"_span);
}
// MAVERICKS_BACKPORT: upstream's version of the lines below, kept commented rather than deleted so the divergence stays visible in place. Reason: see the note directly above.
// #endif
// (end MAVERICKS_BACKPORT restored block)

#if USE(AVIF)
// MAVERICKS_BACKPORT: an animated PNG carries an acTL chunk ahead of its first IDAT. 10.9's ImageIO
// decodes a PNG's default image alone -- CGImageSourceGetCount() answers 1 through every creation path,
// there is no {PNG} container dictionary, and the per-frame dictionary holds InterlaceType and nothing
// else -- so a file with acTL goes to WebCore's own decoder, which reads acTL, fcTL and fdAT. A PNG
// without acTL is left to ImageIO, which keeps its colour management, subsampling and asynchronous
// decoding for the ordinary case.
#if USE(PNG)
static bool matchesAnimatedPNGSignature(std::span<const uint8_t> contents, FragmentedSharedBuffer& data)
{
    if (!matchesPNGSignature(contents))
        return false;

    auto sharedBuffer = data.makeContiguous();
    auto bytes = sharedBuffer->span();
    // Chunks follow the 8-byte signature as [length][type][data][CRC]; acTL and IDAT are both near the
    // front, so a buffer that holds the header holds the answer.
    for (size_t offset = 8; offset + 8 <= bytes.size();) {
        auto type = bytes.subspan(offset + 4, 4);
        if (spanHasPrefix(type, "acTL"_span))
            return true;
        if (spanHasPrefix(type, "IDAT"_span))
            return false;
        uint32_t length = (static_cast<uint32_t>(bytes[offset]) << 24) | (static_cast<uint32_t>(bytes[offset + 1]) << 16)
            | (static_cast<uint32_t>(bytes[offset + 2]) << 8) | static_cast<uint32_t>(bytes[offset + 3]);
        if (length > bytes.size() - offset)
            return false;
        offset += static_cast<size_t>(length) + 12;
    }
    return false;
}
#endif // MAVERICKS_BACKPORT: closes the USE(PNG) guard on the animated-PNG sniff above.

static bool matchesAVIFSignature(std::span<const uint8_t> contents, FragmentedSharedBuffer& data)
{
// MAVERICKS_BACKPORT: the CG flavor of this check asks ImageIO to name the data's UTI, and 10.9's
// ImageIO predates AVIF -- decodeUTI can never answer public.avif/avis, so the decoder below would
// never run. Use upstream's non-CG byte signature instead, like the WebP dispatch above.
#if USE(CG) && !PLATFORM(MAC)
    UNUSED_PARAM(contents);
    auto sharedBuffer = data.makeContiguous();
    auto cfData = sharedBuffer->createCFData();
    auto imageSource = adoptCF(CGImageSourceCreateWithData(cfData.get(), nullptr));
    auto uti = ImageDecoderCG::decodeUTI(imageSource.get(), sharedBuffer.get());
    return uti == "public.avif"_s || uti == "public.avis"_s;
#else
    UNUSED_PARAM(data);
    return spanHasPrefix(contents.subspan(4), unsafeMakeSpan("\x66\x74\x79\x70", 4));
#endif
}
#endif // USE(AVIF)

#if USE(JPEGXL)
static bool matchesJPEGXLSignature(std::span<const uint8_t> contents)
{
#if PLATFORM(COCOA)
    if (!&JxlSignatureCheck)
        return false;
#endif
    JxlSignature signature = JxlSignatureCheck(contents.data(), contents.size());
    return signature != JXL_SIG_NOT_ENOUGH_BYTES && signature != JXL_SIG_INVALID;
}
#endif

} // Anonymous namespace

RefPtr<ScalableImageDecoder> ScalableImageDecoder::create(FragmentedSharedBuffer& data, AlphaOption alphaOption, GammaAndColorProfileOption gammaAndColorProfileOption)
{
    constexpr size_t lengthOfLongestSignature = 14; // To wit: "RIFF????WEBPVP"
    if (data.size() < lengthOfLongestSignature)
        return nullptr;

    std::array<uint8_t, lengthOfLongestSignature> contents;
    data.copyTo(std::span { contents });

    std::span contentsSpan { contents };

#if !PLATFORM(COCOA)
    if (matchesGIFSignature(contentsSpan))
        return GIFImageDecoder::create(alphaOption, gammaAndColorProfileOption);

    if (matchesPNGSignature(contentsSpan))
        return PNGImageDecoder::create(alphaOption, gammaAndColorProfileOption);

    if (matchesICOSignature(contentsSpan) || matchesCURSignature(contentsSpan))
        return ICOImageDecoder::create(alphaOption, gammaAndColorProfileOption);

    if (matchesJPEGSignature(contentsSpan))
        return JPEGImageDecoder::create(alphaOption, gammaAndColorProfileOption);

    if (matchesBMPSignature(contentsSpan))
        return BMPImageDecoder::create(alphaOption, gammaAndColorProfileOption);
// MAVERICKS_BACKPORT: the WebP dispatch is lifted out of this !PLATFORM(COCOA) block into the PLATFORM(MAC)-inclusive block below.
#endif

#if PLATFORM(MAC) || !PLATFORM(COCOA)
    // MAVERICKS_BACKPORT: ImageIO on this build doesn't decode WebP, so fall back to the
    // libwebp-backed scalable decoder. iOS Cocoa's ImageIO handles WebP natively.
    if (matchesWebPSignature(contentsSpan))
        return WEBPImageDecoder::create(alphaOption, gammaAndColorProfileOption);
#endif

#if PLATFORM(MAC) && USE(PNG)
    // MAVERICKS_BACKPORT: animated PNGs only; see matchesAnimatedPNGSignature above.
    if (matchesAnimatedPNGSignature(contentsSpan, data))
        return PNGImageDecoder::create(alphaOption, gammaAndColorProfileOption);
#endif

#if USE(AVIF)
    if (matchesAVIFSignature(contentsSpan, data))
        return AVIFImageDecoder::create(alphaOption, gammaAndColorProfileOption);
#else
    UNUSED_PARAM(alphaOption);
    UNUSED_PARAM(gammaAndColorProfileOption);
#endif

#if USE(JPEGXL)
    if (matchesJPEGXLSignature(contentsSpan))
        return JPEGXLImageDecoder::create(alphaOption, gammaAndColorProfileOption);
#endif

    return nullptr;
}

bool ScalableImageDecoder::frameIsCompleteAtIndex(size_t index) const
{
    Locker locker { m_lock };
    if (index >= m_frameBufferCache.size())
        return false;

    auto& frame = m_frameBufferCache[index];
    return frame.isComplete();
}

bool ScalableImageDecoder::frameHasAlphaAtIndex(size_t index) const
{
    Locker locker { m_lock };
    if (m_frameBufferCache.size() <= index)
        return true;

    auto& frame = m_frameBufferCache[index];
    if (!frame.isComplete())
        return true;
    return frame.hasAlpha();
}

Seconds ScalableImageDecoder::frameDurationAtIndex(size_t index) const
{
    Locker locker { m_lock };
    if (index >= m_frameBufferCache.size())
        return 0_s;

    auto& frame = m_frameBufferCache[index];
    if (!frame.isComplete())
        return 0_s;

    // Many annoying ads specify a 0 duration to make an image flash as quickly as possible.
    // We follow Firefox's behavior and use a duration of 100 ms for any frames that specify
    // a duration of <= 10 ms. See <rdar://problem/7689300> and <http://webkit.org/b/36082>
    // for more information.
    Seconds duration = frame.duration();
    if (duration < 11_ms)
        return 100_ms;
    return duration;
}

PlatformImagePtr ScalableImageDecoder::createFrameImageAtIndex(size_t index, SubsamplingLevel, const DecodingOptions&)
{
    Locker locker { m_lock };
    // Zero-height images can cause problems for some ports. If we have an empty image dimension, just bail.
    if (size().isEmpty())
        return nullptr;

    auto* buffer = frameBufferAtIndex(index);
    if (!buffer || buffer->isInvalid() || !buffer->hasBackingStore())
        return nullptr;

    // Return the buffer contents as a native image. For some ports, the data
    // is already in a native container, and this just increments its refcount.
    return buffer->backingStore()->image();
}

}
