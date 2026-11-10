/*
 * Copyright (C) 2011 Apple Inc. All rights reserved.
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
 * THE IMPLIED WARRANTIES OF MERCHANTAwBILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "WKIconDatabaseCG.h"

// AQUAWEBKIT: the icon store's frames (#49, github #76) and their stored form (WebIconDatabase.h).
#include "APIData.h"
#include "WebIconDatabase.h"
#include <WebCore/ShareableBitmap.h>
#include <wtf/RetainPtr.h>
#include "WKAPICast.h"
#include "WKSharedAPICast.h"
#include <WebCore/Image.h>

using namespace WebKit;

// AQUAWEBKIT: see WebIconDatabase.h.
static RetainPtr<CGColorSpaceRef> iconColorSpace()
{
    return adoptCF(CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
}

static constexpr CGBitmapInfo iconBitmapInfo = static_cast<CGBitmapInfo>(kCGImageAlphaPremultipliedFirst) | kCGBitmapByteOrder32Little;

// AQUAWEBKIT: see WebIconDatabase.h. Each bitmap is drawn into a frame of the stored form.
RefPtr<API::Data> WebKit::createIconData(const Vector<Ref<WebCore::ShareableBitmap>>& bitmaps)
{
    if (bitmaps.size() != iconLengths.size())
        return nullptr;

    RetainPtr colorSpace = iconColorSpace();
    Vector<uint8_t> data;
    for (size_t index = 0; index < iconLengths.size(); ++index) {
        auto length = iconLengths[index];
        Ref bitmap = bitmaps[index];
        if (bitmap->size() != WebCore::IntSize(length, length) || bitmap->colorSpace() != WebCore::DestinationColorSpace::SRGB())
            return nullptr;
        RetainPtr image = bitmap->createPlatformImage();
        if (!image)
            return nullptr;

        for (unsigned byte = 0; byte < sizeof(uint32_t); ++byte)
            data.append(static_cast<uint8_t>(length >> (8 * byte)));
        size_t pixelsOffset = data.size();
        data.grow(pixelsOffset + length * length * 4);
        auto pixels = data.mutableSpan().subspan(pixelsOffset);
        std::ranges::fill(pixels, 0);
        RetainPtr context = adoptCF(CGBitmapContextCreate(pixels.data(), length, length, 8, length * 4, colorSpace.get(), iconBitmapInfo));
        if (!context)
            return nullptr;
        CGContextSetBlendMode(context.get(), kCGBlendModeCopy);
        CGContextDrawImage(context.get(), CGRectMake(0, 0, length, length), image.get());
    }
    return API::Data::create(WTF::move(data));
}

// AQUAWEBKIT: see WebIconDatabase.h. One frame per entry of iconLengths, in that order, and nothing after.
bool WebKit::isIconData(std::span<const uint8_t> bytes)
{
    for (auto length : iconLengths) {
        if (bytes.size() < sizeof(uint32_t))
            return false;
        uint32_t storedLength = 0;
        for (unsigned byte = 0; byte < sizeof(uint32_t); ++byte)
            storedLength |= static_cast<uint32_t>(bytes[byte]) << (8 * byte);
        bytes = bytes.subspan(sizeof(uint32_t));
        size_t pixelsSize = static_cast<size_t>(length) * length * 4;
        if (storedLength != length || bytes.size() < pixelsSize)
            return false;
        bytes = bytes.subspan(pixelsSize);
    }
    return bytes.empty();
}

// AQUAWEBKIT: see WebIconDatabase.h. The frames come back in stored order, and a frame is built
// directly over a copy of its pixels.
Vector<RetainPtr<CGImageRef>> WebKit::iconFramesFromData(API::Data& data)
{
    auto bytes = data.span();
    if (!isIconData(bytes))
        return { };

    RetainPtr colorSpace = iconColorSpace();
    Vector<RetainPtr<CGImageRef>> frames;
    for (auto length : iconLengths) {
        bytes = bytes.subspan(sizeof(uint32_t));
        size_t pixelsSize = static_cast<size_t>(length) * length * 4;
        RetainPtr pixels = adoptCF(CFDataCreate(kCFAllocatorDefault, bytes.data(), pixelsSize));
        RetainPtr provider = adoptCF(CGDataProviderCreateWithCFData(pixels.get()));
        RetainPtr image = adoptCF(CGImageCreate(length, length, 8, 32, length * 4, colorSpace.get(), iconBitmapInfo, provider.get(), nullptr, false, kCGRenderingIntentDefault));
        if (!image)
            return { };
        frames.append(WTF::move(image));
        bytes = bytes.subspan(pixelsSize);
    }
    return frames;
}

// AQUAWEBKIT: the store lookup both C API entry points below share.
static Vector<RetainPtr<CGImageRef>> iconFramesForPageURL(WKIconDatabaseRef iconDatabaseRef, WKURLRef pageURL)
{
    RefPtr data = toImpl(iconDatabaseRef)->iconDataForPageURL(toWTFString(pageURL));
    if (!data)
        return { };
    return WebKit::iconFramesFromData(*data);
}

// AQUAWEBKIT: the stored favicon frame whose pixel size matches the request, else the first frame.
// "TryGet" returns an image the caller does not own, so it is autoreleased (#49, #76).
// CGImageRef WKIconDatabaseTryGetCGImageForURL(WKIconDatabaseRef, WKURLRef, WKSize)
// {
//     return nullptr;
// }
CGImageRef WKIconDatabaseTryGetCGImageForURL(WKIconDatabaseRef iconDatabaseRef, WKURLRef pageURL, WKSize size)
{
    auto frames = iconFramesForPageURL(iconDatabaseRef, pageURL); // AQUAWEBKIT
    if (frames.isEmpty())
        return nullptr;

    RetainPtr<CGImageRef> chosen = frames[0];
    if (size.width && size.height) {
        for (auto& frame : frames) {
            if (CGImageGetWidth(frame.get()) == static_cast<size_t>(size.width) && CGImageGetHeight(frame.get()) == static_cast<size_t>(size.height)) {
                chosen = frame;
                break;
            }
        }
    }

    return (CGImageRef)CFAutorelease(chosen.leakRef());
}

// AQUAWEBKIT: every frame of a stored favicon, smallest first (#76). Safari::IconController::bestSiteIconForURLString and ::bestFallbackCandidate
// pick the representation closest to the size they need from it.
// CFArrayRef WKIconDatabaseTryCopyCGImageArrayForURL(WKIconDatabaseRef, WKURLRef)
// {
//     return nullptr;
// }
CFArrayRef WKIconDatabaseTryCopyCGImageArrayForURL(WKIconDatabaseRef iconDatabaseRef, WKURLRef pageURL)
{
    auto frames = iconFramesForPageURL(iconDatabaseRef, pageURL); // AQUAWEBKIT
    if (frames.isEmpty())
        return nullptr;

    // AQUAWEBKIT: one CFArray element per stored frame.
    RetainPtr<CFMutableArrayRef> images = adoptCF(CFArrayCreateMutable(kCFAllocatorDefault, frames.size(), &kCFTypeArrayCallBacks));
    for (auto& frame : frames)
        CFArrayAppendValue(images.get(), frame.get());
    return images.leakRef(); // AQUAWEBKIT: "TryCopy" is +1, which the caller releases.
}

