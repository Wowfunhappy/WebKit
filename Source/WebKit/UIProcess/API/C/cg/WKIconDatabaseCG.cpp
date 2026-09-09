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

// MAVERICKS_BACKPORT: APIData for the raw favicon bytes read out of the revived in-memory icon store (#49).
#include "APIData.h"
#include "WKAPICast.h"
#include "WKSharedAPICast.h"
// MAVERICKS_BACKPORT: the store, plus WebCore's image decoding — the same decoders that draw a
// page's images, so a favicon in any format this port renders is a usable icon here too
// (#49, github #76).
#include "WebIconDatabase.h"
#include <WebCore/ImageDecoder.h>
#include <WebCore/SharedBuffer.h>
#include <wtf/RetainPtr.h>

using namespace WebKit;

// MAVERICKS_BACKPORT: every frame a stored favicon decodes to, in file order — shared by the
// single-image and the array lookup below, and by the store's admission test (#49, github #76).
Vector<RetainPtr<CGImageRef>> WebKit::decodeIconData(API::Data& data)
{
    // MAVERICKS_BACKPORT: ImageDecoder directly rather than BitmapImage: decoding here must be synchronous (the answer is
    // the return value), and this is the same decoder selection WebCore uses for page images.
    // The MIME type is left empty on purpose: the decoders sniff the bytes, and the store keeps no
    // type — the honest test is whether the bytes decode, not what a server called them.
    Ref buffer = WebCore::SharedBuffer::create(data.span());
    RefPtr decoder = WebCore::ImageDecoder::create(buffer, String(), WebCore::AlphaOption::Premultiplied, WebCore::GammaAndColorProfileOption::Applied);
    if (!decoder)
        return { };
    // A decoder is constructed with nothing ingested; the data arrives here. (Missing this rejected
    // every icon, since the status stays Unknown.)
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

// MAVERICKS_BACKPORT: the store lookup both C API entry points below share.
static Vector<RetainPtr<CGImageRef>> iconFramesForPageURL(WKIconDatabaseRef iconDatabaseRef, WKURLRef pageURL)
{
    RefPtr data = toImpl(iconDatabaseRef)->iconDataForPageURL(toWTFString(pageURL)); // MAVERICKS_BACKPORT
    if (!data)
        return { };
    return WebKit::decodeIconData(*data);
}

// MAVERICKS_BACKPORT: decode the favicon bytes held in the revived in-memory icon store into a
// CGImage for Safari 7, instead of the upstream nullptr stub. Honour the requested size the way the
// pre-deletion upstream did (BitmapImage::getFirstCGImageRefOfSize, 2013): a .ico carries several
// sizes, so return the frame whose pixel size matches the request and fall back to the first frame
// when none does — a caller asking for 16x16 must not silently get a 512x512 image. "TryGet" semantics
// mean the caller does not own the returned image, so it is autoreleased (#49, github #76).
CGImageRef WKIconDatabaseTryGetCGImageForURL(WKIconDatabaseRef iconDatabaseRef, WKURLRef pageURL, WKSize size)
{
    auto frames = iconFramesForPageURL(iconDatabaseRef, pageURL); // MAVERICKS_BACKPORT
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

// MAVERICKS_BACKPORT: every image a stored favicon contains (github #76). This is the other half of
// the C API Safari 7 asks favicons through: Safari::IconController::bestSiteIconForURLString and
// ::bestFallbackCandidate read the array and pick the representation closest to the size they need
// (that is what backs a Reading List row's icon, among others), and when it comes back empty they fall
// straight through to the generic globe. Frame order is the file's own, matching pre-deletion upstream
// (BitmapImage::getCGImageArray); a .ico commonly carries several sizes, hence an array, and a
// single-image format yields a one-element one.
CFArrayRef WKIconDatabaseTryCopyCGImageArrayForURL(WKIconDatabaseRef iconDatabaseRef, WKURLRef pageURL)
{
    auto frames = iconFramesForPageURL(iconDatabaseRef, pageURL); // MAVERICKS_BACKPORT
    if (frames.isEmpty())
        return nullptr;

    // MAVERICKS_BACKPORT: one CFArray element per decoded frame.
    RetainPtr<CFMutableArrayRef> images = adoptCF(CFArrayCreateMutable(kCFAllocatorDefault, frames.size(), &kCFTypeArrayCallBacks));
    for (auto& frame : frames)
        CFArrayAppendValue(images.get(), frame.get());
    return images.leakRef(); // MAVERICKS_BACKPORT: "TryCopy" is +1, which the caller releases.
}


