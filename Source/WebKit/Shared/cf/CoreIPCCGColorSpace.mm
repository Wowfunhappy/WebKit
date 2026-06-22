/*
 * Copyright (C) 2025 Apple Inc. All rights reserved.
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

#import "config.h"
#import "CoreIPCCGColorSpace.h"

#if PLATFORM(COCOA)

#import "CoreIPCTypes.h"

namespace WebKit {

CGColorSpaceSerialization CoreIPCCGColorSpace::serializableColorSpace(CGColorSpaceRef cgColorSpace)
{
    // On 10.9, colorSpaceForCGColorSpace handles the common cases (sRGB etc.)
    // and the extended color space APIs (CGColorSpaceGetName, extended property list
    // keys) don't exist. Just match known spaces and fall back to sRGB.
    if (auto colorSpace = WebCore::colorSpaceForCGColorSpace(cgColorSpace))
        return *colorSpace;

    // MAVERICKS_BACKPORT: CGColorSpaceGetName is 10.12+ (absent on 10.9, weak-imported -> calling it
    // crashes). Gate on the DEPLOYMENT TARGET (the #97 model), not the SDK; on 10.9 fall through to the
    // CGColorSpaceCopyPropertyList (ICC) path below, which preserves the color space (better than sRGB).
#if __MAC_OS_X_VERSION_MIN_REQUIRED >= 101200
    if (RetainPtr<CFStringRef> name = CGColorSpaceGetName(cgColorSpace))
        return WTF::move(name);
#endif

    if (auto propertyList = adoptCF(CGColorSpaceCopyPropertyList(cgColorSpace))) {
        if (auto data = dynamic_cf_cast<CFDataRef>(propertyList.get()))
            return ICCData { makeVector(data), ExtendedRangeDerivative::kNone };
    }

    return WebCore::ColorSpace::SRGB;
}

CoreIPCCGColorSpace::CoreIPCCGColorSpace(CGColorSpaceRef cgColorSpace)
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 101200
    : m_cgColorSpace(serializableColorSpace(cgColorSpace))
#else
    : m_cgColorSpace(WebCore::ColorSpace::SRGB)
#endif
{
}

CoreIPCCGColorSpace::CoreIPCCGColorSpace(CGColorSpaceSerialization data)
    : m_cgColorSpace(data)
{
}

RetainPtr<CGColorSpaceRef> CoreIPCCGColorSpace::toCF() const
{
    // On 10.9, only ColorSpace enum values are serialized (no ICCData/IndexedColorSpace).
    // Just handle the ColorSpace case and fall back to sRGB.
    auto colorSpace = WTF::switchOn(m_cgColorSpace,
    [](WebCore::ColorSpace colorSpace) -> RetainPtr<CGColorSpaceRef> {
        return RetainPtr { cachedNullableCGColorSpaceSingleton(colorSpace) };
    },
    [](RetainPtr<CFStringRef> name) -> RetainPtr<CGColorSpaceRef> {
        return adoptCF(CGColorSpaceCreateWithName(name.get()));
    },
    [](const ICCData&) -> RetainPtr<CGColorSpaceRef> {
        // CGColorSpaceCreateWithPropertyList not available on 10.9
        return adoptCF(CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
    },
    [](const IndexedColorSpace&) -> RetainPtr<CGColorSpaceRef> {
        return adoptCF(CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
    });
    if (!colorSpace) [[unlikely]]
        return nullptr;
    return colorSpace;
}

} // namespace WebKit

#endif // PLATFORM(COCOA)
