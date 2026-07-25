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
// MAVERICKS_BACKPORT: WebIconDatabase + CoreGraphics/ImageIO for decoding the stored favicon bytes to a CGImage (#49).
#include "WebIconDatabase.h"
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <WebCore/Image.h>
// MAVERICKS_BACKPORT: RetainPtr for the CFData/CGImageSource handles used in the CGImage decode path below (#49).
#include <wtf/RetainPtr.h>

using namespace WebKit;

// MAVERICKS_BACKPORT: the stored favicon bytes as a decodable ImageIO source, or null — shared by the
// single-image and the array lookup below (#49, github #76).
static RetainPtr<CGImageSourceRef> imageSourceForPageURL(WKIconDatabaseRef iconDatabaseRef, WKURLRef pageURL)
{
    RefPtr data = toImpl(iconDatabaseRef)->iconDataForPageURL(toWTFString(pageURL)); // MAVERICKS_BACKPORT
    if (!data)
        return nullptr;

    auto span = data->span();
    RetainPtr<CFDataRef> cfData = adoptCF(CFDataCreate(kCFAllocatorDefault, span.data(), span.size()));
    if (!cfData)
        return nullptr;

    return adoptCF(CGImageSourceCreateWithData(cfData.get(), nullptr));
}

// MAVERICKS_BACKPORT: decode the favicon bytes held in the revived in-memory icon store into a
// CGImage for Safari 7, instead of the upstream nullptr stub. "TryGet" semantics mean the caller does
// not own the returned image, so it is autoreleased (#49).
CGImageRef WKIconDatabaseTryGetCGImageForURL(WKIconDatabaseRef iconDatabaseRef, WKURLRef pageURL, WKSize)
{
    RetainPtr<CGImageSourceRef> source = imageSourceForPageURL(iconDatabaseRef, pageURL); // MAVERICKS_BACKPORT
    if (!source)
        return nullptr;

    CGImageRef cgImage = CGImageSourceCreateImageAtIndex(source.get(), 0, nullptr);
    if (!cgImage)
        return nullptr;

    return (CGImageRef)CFAutorelease(cgImage);
}

// MAVERICKS_BACKPORT: every image a stored favicon contains, largest first (github #76). This is the
// other half of the C API Safari 7 asks favicons through: Safari::IconController::bestSiteIconForURLString
// and ::bestFallbackCandidate read the array and pick the representation closest to the size they need
// (that is what backs a Reading List row's icon, among others), and when it comes back empty they fall
// straight through to the generic globe. A .ico commonly carries several sizes, hence an array; a
// single-image format yields a one-element one.
CFArrayRef WKIconDatabaseTryCopyCGImageArrayForURL(WKIconDatabaseRef iconDatabaseRef, WKURLRef pageURL)
{
    RetainPtr<CGImageSourceRef> source = imageSourceForPageURL(iconDatabaseRef, pageURL);
    if (!source)
        return nullptr;

    size_t count = CGImageSourceGetCount(source.get());
    if (!count)
        return nullptr;

    RetainPtr<CFMutableArrayRef> images = adoptCF(CFArrayCreateMutable(kCFAllocatorDefault, count, &kCFTypeArrayCallBacks));
    for (size_t index = 0; index < count; ++index) {
        RetainPtr<CGImageRef> image = adoptCF(CGImageSourceCreateImageAtIndex(source.get(), index, nullptr));
        if (image)
            CFArrayAppendValue(images.get(), image.get());
    }

    if (!CFArrayGetCount(images.get()))
        return nullptr;

    return images.leakRef();
}

