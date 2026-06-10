/*
 * Copyright (C) 2020 Apple Inc. All rights reserved.
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

// 10.9 backport status: minimal implementation. The PDF HUD is the floating
// zoom/save overlay shown over inline PDFs by the PDF plugin. This inert view
// is created and laid out by WebViewImpl but draws nothing and handles no
// clicks (handleMouse* return NO so events fall through to the page). Real ObjC
// metadata lives in WebKit.framework; the full HUD can be restored from upstream.

#import "config.h"
#import "WKPDFHUDView.h"

#if ENABLE(PDF_HUD)

#import "WebPageProxy.h"

@implementation WKPDFHUDView

- (instancetype)initWithFrame:(NSRect)frame pluginIdentifier:(WebKit::PDFPluginIdentifier)pluginIdentifier frameIdentifier:(WebCore::FrameIdentifier)frameID page:(WebKit::WebPageProxy&)page
{
    self = [super initWithFrame:frame];
    if (!self)
        return nil;
    UNUSED_PARAM(pluginIdentifier);
    UNUSED_PARAM(frameID);
    UNUSED_PARAM(page);
    return self;
}

- (void)setDeviceScaleFactor:(CGFloat)deviceScaleFactor
{
    UNUSED_PARAM(deviceScaleFactor);
}

- (BOOL)handleMouseDown:(NSEvent *)event
{
    UNUSED_PARAM(event);
    return NO;
}

- (BOOL)handleMouseUp:(NSEvent *)event
{
    UNUSED_PARAM(event);
    return NO;
}

@end

#endif // ENABLE(PDF_HUD)
