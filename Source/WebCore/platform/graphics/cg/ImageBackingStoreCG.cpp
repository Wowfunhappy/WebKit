/*
 * Copyright (C) 2022 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "ImageBackingStore.h"

namespace WebCore {

static void dataProviderReleaseCallback(void* info, const void*, size_t)
{
    auto* pixels = static_cast<FragmentedSharedBuffer::DataSegment*>(info);
    pixels->deref(); // Balanced below in ImageBackingStore::image().
}

PlatformImagePtr ImageBackingStore::image() const
// MAVERICKS_BACKPORT: share native provider ownership for RGB and CMYK samples.
{
    auto colorSpace = adoptCF(CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
IGNORE_WARNINGS_BEGIN("deprecated-enum-enum-conversion")
    CGBitmapInfo bitmapInfo = (m_premultiplyAlpha ? kCGImageAlphaPremultipliedFirst : kCGImageAlphaFirst) | kCGImageByteOrder32Little;
IGNORE_WARNINGS_END
    return image(colorSpace.get(), bitmapInfo, nullptr);
}

PlatformImagePtr ImageBackingStore::image(CGColorSpaceRef colorSpace, CGBitmapInfo bitmapInfo, const CGFloat* decode) const
{
    static const size_t bytesPerPixel = 4;
    static const size_t bitsPerComponent = 8;
    size_t width = size().width();
    size_t height = size().height();
    size_t bytesPerRow = bytesPerPixel * width;

    // MAVERICKS_BACKPORT: the caller supplies the samples' native color model.
    // auto colorSpace = adoptCF(CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
    auto dataProvider = adoptCF(CGDataProviderCreateWithData(m_pixels.get(), m_pixelsSpan.data(), height * bytesPerRow, dataProviderReleaseCallback));

    if (!dataProvider)
        return nullptr;

    m_pixels->ref(); // Balanced above in dataProviderReleaseCallback().
    /* MAVERICKS_BACKPORT: the RGB entry point supplies its alpha layout; CMYK supplies its decode range.
IGNORE_WARNINGS_BEGIN("deprecated-enum-enum-conversion")
    CGBitmapInfo bitmapInfo = (m_premultiplyAlpha ? kCGImageAlphaPremultipliedFirst : kCGImageAlphaFirst) | kCGImageByteOrder32Little;
IGNORE_WARNINGS_END
    return adoptCF(CGImageCreate(width, height, bitsPerComponent, bytesPerPixel * 8, bytesPerRow, colorSpace.get(), bitmapInfo, dataProvider.get(), nullptr, true, kCGRenderingIntentDefault));
    */ // MAVERICKS_BACKPORT: closes the fixed-RGB image construction above.
    return adoptCF(CGImageCreate(width, height, bitsPerComponent, bytesPerPixel * 8, bytesPerRow, colorSpace, bitmapInfo, dataProvider.get(), decode, true, kCGRenderingIntentDefault));
}

} // namespace WebCore
