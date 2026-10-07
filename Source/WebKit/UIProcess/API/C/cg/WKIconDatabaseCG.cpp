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

// AQUAWEBKIT: the in-memory icon store's favicon bytes (#49), decoded by the decoders that draw a page's
// images (github #76).
#include "APIData.h"
#include "WebIconDatabase.h"
#include <WebCore/ImageDecoder.h>
#include <WebCore/SharedBuffer.h>
#include <wtf/RetainPtr.h>
#include "WKAPICast.h"
#include "WKSharedAPICast.h"
#include <WebCore/Image.h>

using namespace WebKit;

// AQUAWEBKIT: every frame a stored favicon decodes to, in file order, for the lookups below and the
// store's admission test (#49, github #76).
Vector<RetainPtr<CGImageRef>> WebKit::decodeIconData(API::Data& data)
{
    // AQUAWEBKIT: a synchronous ImageDecoder, with WebCore's decoder selection for page images. The store
    // keeps no MIME type; the decoders sniff the bytes.
    Ref buffer = WebCore::SharedBuffer::create(data.span());
    RefPtr decoder = WebCore::ImageDecoder::create(buffer, String(), WebCore::AlphaOption::Premultiplied, WebCore::GammaAndColorProfileOption::Applied);
    if (!decoder)
        return { };
    // A decoder is constructed with nothing ingested; the data arrives here.
    decoder->setData(buffer, true);
    if (decoder->encodedDataStatus() != WebCore::EncodedDataStatus::Complete)
        return { };

    Vector<RetainPtr<CGImageRef>> frames;
    size_t count = decoder->frameCount();
    frames.reserveInitialCapacity(count);
    for (size_t index = 0; index < count; ++index) {
        if (auto frame = decoder->createFrameImageAtIndex(index))
            frames.append(WTF::move(frame));
    }
    return frames;
}

// AQUAWEBKIT: the store lookup both C API entry points below share.
static Vector<RetainPtr<CGImageRef>> iconFramesForPageURL(WKIconDatabaseRef iconDatabaseRef, WKURLRef pageURL)
{
    RefPtr data = toImpl(iconDatabaseRef)->iconDataForPageURL(toWTFString(pageURL));
    if (!data)
        return { };
    return WebKit::decodeIconData(*data);
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

// AQUAWEBKIT: every image a stored favicon contains, in file order (#76). Safari::IconController::bestSiteIconForURLString and ::bestFallbackCandidate
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

    // AQUAWEBKIT: one CFArray element per decoded frame.
    RetainPtr<CFMutableArrayRef> images = adoptCF(CFArrayCreateMutable(kCFAllocatorDefault, frames.size(), &kCFTypeArrayCallBacks));
    for (auto& frame : frames)
        CFArrayAppendValue(images.get(), frame.get());
    return images.leakRef(); // AQUAWEBKIT: "TryCopy" is +1, which the caller releases.
}

