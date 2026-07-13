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
    // appearance to swap in or restore. Gate on the DEPLOYMENT TARGET (__MAC_OS_X_VERSION_MIN_REQUIRED) so
    // the 10.14+ calls below are never even compiled for 10.9. The selref-scope polyfill deliberately does
    // NOT supply currentDrawingAppearance (see wk_polyfills.m): it is exactly the selector whose absence
    // must be preserved so the respondsToSelector(currentDrawingAppearance) guards elsewhere in the control
    // draw path (ControlMac, Switch*Mac, ProgressBarMac, ScrollbarTrackCornerSystemImageMac, …) keep taking
    // their nil branch instead of running the 11.0+ appearanceByApplyingTintColor: path and crashing (e.g.
    // ScrollbarThemeMac::paintScrollCorner -> AppKitControlSystemImage::draw on a tinted scrollbar corner).
    UNUSED_PARAM(tintColor);
    m_usingDarkAppearance = useDarkAppearance;
    // MAVERICKS_BACKPORT: deployment-target gate — the appearance-swap APIs below are 10.14+; skip on 10.9.
#if __MAC_OS_X_VERSION_MIN_REQUIRED >= 101400
    m_savedSystemAppearance = [NSAppearance currentDrawingAppearance];

ALLOW_DEPRECATED_DECLARATIONS_BEGIN
    RetainPtr appearance = [NSAppearance appearanceNamed:m_usingDarkAppearance ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];

    if (tintColor.isValid())
        appearance = [appearance appearanceByApplyingTintColor:cocoaColor(tintColor).get()];

    [NSAppearance setCurrentAppearance:appearance.get()];
ALLOW_DEPRECATED_DECLARATIONS_END
// MAVERICKS_BACKPORT: end of the 10.14+ appearance-swap block compiled out on 10.9.
#endif
}

LocalDefaultSystemAppearance::~LocalDefaultSystemAppearance()
{
    // MAVERICKS_BACKPORT: on 10.9 nothing was saved (the appearance swap was compiled out), so there is
    // nothing to restore — bail before touching the 10.14+ setCurrentAppearance: API.
    if (!m_savedSystemAppearance)
        return;
ALLOW_DEPRECATED_DECLARATIONS_BEGIN
    [NSAppearance setCurrentAppearance:m_savedSystemAppearance.get()];
ALLOW_DEPRECATED_DECLARATIONS_END
}

}

#endif // USE(APPKIT)
