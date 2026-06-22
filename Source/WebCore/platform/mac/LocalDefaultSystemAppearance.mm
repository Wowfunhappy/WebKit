/*
 * Copyright (C) 2018-2023 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1.  Redistributions of source code must retain the above copyright
 *     notice, this list of conditions and the following disclaimer.
 * 2.  Redistributions in binary form must reproduce the above copyright
 *     notice, this list of conditions and the following disclaimer in the
 *     documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
 * ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "config.h"
#import "LocalDefaultSystemAppearance.h"

#if USE(APPKIT)

#import "ColorMac.h"

#import <AppKit/NSAppearance.h>
#import <pal/spi/mac/NSAppearanceSPI.h>

namespace WebCore {

LocalDefaultSystemAppearance::LocalDefaultSystemAppearance(bool useDarkAppearance, const Color& tintColor)
{
    // MAVERICKS_BACKPORT: the NSAppearance appearance-swapping system is 10.10+ (currentDrawingAppearance/
    // setCurrentAppearance: 10.14+, appearanceByApplyingTintColor: 11.0+) and absent on 10.9 — there is no
    // appearance to swap in or restore. Gate on the DEPLOYMENT TARGET (__MAC_OS_X_VERSION_MIN_REQUIRED),
    // NOT a respondsToSelector(currentDrawingAppearance) runtime check: that check is DEFEATED by the
    // objc_inject currentDrawingAppearance shim (it returns YES on 10.9), which would let the 11.0+
    // appearanceByApplyingTintColor: path run and crash (unrecognized selector when amazon paints a
    // tinted scrollbar corner: ScrollbarThemeMac::paintScrollCorner -> AppKitControlSystemImage::draw).
    UNUSED_PARAM(tintColor);
    m_usingDarkAppearance = useDarkAppearance;
#if __MAC_OS_X_VERSION_MIN_REQUIRED >= 101400
    m_savedSystemAppearance = [NSAppearance currentDrawingAppearance];

ALLOW_DEPRECATED_DECLARATIONS_BEGIN
    RetainPtr appearance = [NSAppearance appearanceNamed:m_usingDarkAppearance ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];

    if (tintColor.isValid())
        appearance = [appearance appearanceByApplyingTintColor:cocoaColor(tintColor).get()];

    [NSAppearance setCurrentAppearance:appearance.get()];
ALLOW_DEPRECATED_DECLARATIONS_END
#endif
}

LocalDefaultSystemAppearance::~LocalDefaultSystemAppearance()
{
    if (!m_savedSystemAppearance)
        return;
ALLOW_DEPRECATED_DECLARATIONS_BEGIN
    [NSAppearance setCurrentAppearance:m_savedSystemAppearance.get()];
ALLOW_DEPRECATED_DECLARATIONS_END
}

}

#endif // USE(APPKIT)
