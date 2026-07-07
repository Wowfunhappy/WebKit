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
#import "SystemFontDatabaseCoreText.h"

#import <pal/ios/UIKitSoftLink.h>

namespace WebCore {

static auto cocoaFontClassSingleton()
{
#if PLATFORM(IOS_FAMILY)
    return PAL::getUIFontClassSingleton();
#else
    return NSFont.class;
#endif
};

RetainPtr<CTFontDescriptorRef> SystemFontDatabaseCoreText::smallCaptionFontDescriptor()
{
    // MAVERICKS_BACKPORT: NSFontDescriptor is not toll-free bridged to CTFontDescriptorRef on
    // 10.9 (bridging is 10.11+), so the upstream static_cast hands CoreText an NSFontDescriptor
    // and CT introspection crashes. Build the equivalent descriptor natively in CoreText.
    return adoptCF(CTFontDescriptorCreateForUIType(kCTFontUIFontSmallSystem, [cocoaFontClassSingleton() smallSystemFontSize], nullptr));
}

RetainPtr<CTFontDescriptorRef> SystemFontDatabaseCoreText::menuFontDescriptor()
{
    return adoptCF(CTFontDescriptorCreateForUIType(kCTFontUIFontMenuItem, [cocoaFontClassSingleton() systemFontSize], nullptr));
}

RetainPtr<CTFontDescriptorRef> SystemFontDatabaseCoreText::statusBarFontDescriptor()
{
    return adoptCF(CTFontDescriptorCreateForUIType(kCTFontUIFontSystem, [cocoaFontClassSingleton() labelFontSize], nullptr));
}

RetainPtr<CTFontDescriptorRef> SystemFontDatabaseCoreText::miniControlFontDescriptor()
{
#if PLATFORM(IOS_FAMILY)
    return adoptCF(CTFontDescriptorCreateForUIType(kCTFontUIFontMiniSystem, 0, nullptr));
#else
    // MAVERICKS_BACKPORT: no NSFontDescriptor→CT bridging on 10.9; native CT descriptor instead.
    return adoptCF(CTFontDescriptorCreateForUIType(kCTFontUIFontMiniSystem, [cocoaFontClassSingleton() systemFontSizeForControlSize:NSControlSizeMini], nullptr));
#endif
}

RetainPtr<CTFontDescriptorRef> SystemFontDatabaseCoreText::smallControlFontDescriptor()
{
#if PLATFORM(IOS_FAMILY)
    return adoptCF(CTFontDescriptorCreateForUIType(kCTFontUIFontSmallSystem, 0, nullptr));
#else
    // MAVERICKS_BACKPORT: no NSFontDescriptor→CT bridging on 10.9; native CT descriptor instead.
    return adoptCF(CTFontDescriptorCreateForUIType(kCTFontUIFontSmallSystem, [cocoaFontClassSingleton() systemFontSizeForControlSize:NSControlSizeSmall], nullptr));
#endif
}

RetainPtr<CTFontDescriptorRef> SystemFontDatabaseCoreText::controlFontDescriptor()
{
#if PLATFORM(IOS_FAMILY)
    return adoptCF(CTFontDescriptorCreateForUIType(kCTFontUIFontSystem, 0, nullptr));
#else
    // MAVERICKS_BACKPORT: no NSFontDescriptor→CT bridging on 10.9; native CT descriptor instead.
    return adoptCF(CTFontDescriptorCreateForUIType(kCTFontUIFontSystem, [cocoaFontClassSingleton() systemFontSizeForControlSize:NSControlSizeRegular], nullptr));
#endif
}

} // namespace WebCore
