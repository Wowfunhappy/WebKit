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

// MAVERICKS_BACKPORT: each `!PLATFORM(COCOA)` in this file reads `|| PLATFORM(MAC)`. This port
// decodes every image format in WebCore rather than in 10.9's ImageIO, so the Mac build takes the
// same byte-signature dispatch as the ports that have no CGImageSource at all.
#if !PLATFORM(COCOA) || PLATFORM(MAC)
#include "BMPImageDecoder.h"
#include "GIFImageDecoder.h"
#include "ICOImageDecoder.h"
#include "JPEGImageDecoder.h"
#include "PNGImageDecoder.h"
#include "WEBPImageDecoder.h"
#endif // MAVERICKS_BACKPORT: closes the widened guard above.
// MAVERICKS_BACKPORT: TIFF has no upstream ScalableImageDecoder. macOS hands images between
// applications as TIFF, so this port carries one (MavericksSupport/source, on libtiff).
#if USE(TIFF)
#include "TIFFImageDecoder.h"
#endif // MAVERICKS_BACKPORT: closes the USE(TIFF) guard above.
// MAVERICKS_BACKPORT: HEIF has no upstream ScalableImageDecoder; upstream Cocoa decodes it in
// ImageIO. This port carries one (MavericksSupport/source, on libheif).
#if USE(HEIF)
#include "HEIFImageDecoder.h"
#endif // MAVERICKS_BACKPORT: closes the USE(HEIF) guard above.
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

// MAVERICKS_BACKPORT: the Lockdown Mode check in ScalableImageDecoder::create below.
#if PLATFORM(MAC) && ENABLE(LOCKDOWN_MODE_API)
#include <pal/cocoa/LockdownModeCocoa.h>
#endif // MAVERICKS_BACKPORT: closes the Lockdown Mode include guard above.

#include <algorithm>
#include <cmath>

#if PLATFORM(COCOA) && USE(JPEGXL)
#include <wtf/darwin/WeakLinking.h>

WTF_WEAK_LINK_FORCE_IMPORT(JxlSignatureCheck);
#endif

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(ScalableImageDecoder);

namespace {

// MAVERICKS_BACKPORT: each `!PLATFORM(COCOA)` in this file reads `|| PLATFORM(MAC)`. This port
// decodes every image format in WebCore rather than in 10.9's ImageIO, so the Mac build takes the
// same byte-signature dispatch as the ports that have no CGImageSource at all.
#if !PLATFORM(COCOA) || PLATFORM(MAC)
static bool matchesGIFSignature(std::span<const uint8_t> contents)
{
    return spanHasPrefix(contents, "GIF87a"_span) || spanHasPrefix(contents, "GIF89a"_span);
}

static bool matchesPNGSignature(std::span<const uint8_t> contents)
{
    return spanHasPrefix(contents, unsafeMakeSpan("\x89\x50\x4E\x47\x0D\x0A\x1A\x0A", 8));
}

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

static bool matchesWebPSignature(std::span<const uint8_t> contents)
{
    return spanHasPrefix(contents, "RIFF"_span) && spanHasPrefix(contents.subspan(8), "WEBPVP"_span);
}
#endif // MAVERICKS_BACKPORT: closes the widened guard above.

// MAVERICKS_BACKPORT: the TIFF header is a byte-order mark followed by the version -- 42 for a
// classic TIFF, 43 for a BigTIFF -- in that byte order.
#if USE(TIFF)
static bool matchesTIFFSignature(std::span<const uint8_t> contents)
{
    return spanHasPrefix(contents, unsafeMakeSpan("\x49\x49\x2A\x00", 4))
        || spanHasPrefix(contents, unsafeMakeSpan("\x4D\x4D\x00\x2A", 4))
        || spanHasPrefix(contents, unsafeMakeSpan("\x49\x49\x2B\x00", 4))
        || spanHasPrefix(contents, unsafeMakeSpan("\x4D\x4D\x00\x2B", 4));
}
#endif // MAVERICKS_BACKPORT: closes the USE(TIFF) guard above.

#if USE(AVIF)
static bool matchesAVIFSignature(std::span<const uint8_t> contents, FragmentedSharedBuffer& data)
{
// MAVERICKS_BACKPORT: the CG flavour of this check asks ImageIO to name the data's UTI, and 10.9's
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

// MAVERICKS_BACKPORT: Lockdown Mode limits images to the formats UTIRegistry's
// lockdownSupportedImageTypes() lists -- WebP, JPEG, PNG and GIF. Upstream Cocoa enforces that list
// in ImageDecoderCG::encodedDataStatus() through isSupportedImageType(); the decoders this port
// builds are the ones below, so the same list is enforced where they are chosen.
#if PLATFORM(MAC) && ENABLE(LOCKDOWN_MODE_API)
    if (PAL::isLockdownModeEnabledForCurrentProcess()
        && !matchesWebPSignature(contentsSpan) && !matchesJPEGSignature(contentsSpan)
        && !matchesPNGSignature(contentsSpan) && !matchesGIFSignature(contentsSpan))
        return nullptr;
#endif // MAVERICKS_BACKPORT: closes the Lockdown Mode check above.

// MAVERICKS_BACKPORT: each `!PLATFORM(COCOA)` in this file reads `|| PLATFORM(MAC)`. This port
// decodes every image format in WebCore rather than in 10.9's ImageIO, so the Mac build takes the
// same byte-signature dispatch as the ports that have no CGImageSource at all.
#if !PLATFORM(COCOA) || PLATFORM(MAC)
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

    if (matchesWebPSignature(contentsSpan))
        return WEBPImageDecoder::create(alphaOption, gammaAndColorProfileOption);
#endif // MAVERICKS_BACKPORT: closes the widened guard above.

// MAVERICKS_BACKPORT: this port's TIFF decoder; see the include above.
#if USE(TIFF)
    if (matchesTIFFSignature(contentsSpan))
        return TIFFImageDecoder::create(alphaOption, gammaAndColorProfileOption);
#endif // MAVERICKS_BACKPORT: closes the USE(TIFF) guard above.

// MAVERICKS_BACKPORT: this port's HEIF decoder; see the include above. Ahead of the AVIF check,
// which matches any ISO base media file; HEIFImageDecoder answers only for HEIF brands without an
// AVIF one.
#if USE(HEIF)
    if (HEIFImageDecoder::matchesSignature(data))
        return HEIFImageDecoder::create(alphaOption, gammaAndColorProfileOption);
#endif // MAVERICKS_BACKPORT: closes the USE(HEIF) guard above.

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
#if USE(CG) // MAVERICKS_BACKPORT: match ImageDecoderCG by retaining the source profile until the image is drawn.
    return createNativeImage(*buffer);
#else
    return buffer->backingStore()->image();
#endif // MAVERICKS_BACKPORT: closes native image construction.
}

#if USE(CG) // MAVERICKS_BACKPORT: RGB profiles describe the decoder's unconverted RGB backing-store samples.
PlatformImagePtr ScalableImageDecoder::createNativeImage(const ScalableImageDecoderFrame& frame) const
{
    auto image = frame.backingStore()->image();
    if (image && m_embeddedRGBColorSpace)
        return adoptCF(CGImageCreateCopyWithColorSpace(image.get(), m_embeddedRGBColorSpace.get()));
    return image;
}

void ScalableImageDecoder::setEmbeddedRGBColorProfile(std::span<const uint8_t> profile)
{
    auto data = adoptCF(CFDataCreate(kCFAllocatorDefault, profile.data(), profile.size()));
ALLOW_DEPRECATED_DECLARATIONS_BEGIN
    auto colorSpace = adoptCF(CGColorSpaceCreateWithICCProfile(data.get()));
ALLOW_DEPRECATED_DECLARATIONS_END
    if (colorSpace && CGColorSpaceGetModel(colorSpace.get()) == kCGColorSpaceModelRGB)
        m_embeddedRGBColorSpace = std::move(colorSpace);
}
#endif // MAVERICKS_BACKPORT: closes native RGB profile retention.

}
