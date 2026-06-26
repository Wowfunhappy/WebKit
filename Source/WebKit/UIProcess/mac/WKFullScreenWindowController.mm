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

// MAVERICKS_BACKPORT status: minimal implementation. The full element-fullscreen
// controller depends on VideoPresentationManagerProxy and a number of 10.10+
// AppKit/animation APIs. This inert controller keeps real ObjC metadata in
// WebKit.framework and — crucially — completes every fullscreen request handshake
// it is handed (enter -> reports failure, exit/began -> reports done) so the
// HTML Fullscreen API resolves/rejects cleanly instead of hanging the page.
// Element fullscreen therefore degrades to "request denied" rather than crashing.
// The real controller can be restored from upstream.

#import "config.h"
#import "WKFullScreenWindowController.h"

#if ENABLE(FULLSCREEN_API) && PLATFORM(MAC)

#import "WebPageProxy.h"

enum FullScreenState : NSInteger {
    NotInFullScreen,
    WaitingToEnterFullScreen,
    EnteringFullScreen,
    InFullScreen,
    WaitingToExitFullScreen,
    ExitingFullScreen,
};

@implementation WKFullScreenWindowController

- (instancetype)initWithWindow:(NSWindow *)window webView:(WKWebView *)webView page:(std::reference_wrapper<WebKit::WebPageProxy>)page
{
    self = [super initWithWindow:window];
    if (!self)
        return nil;

    _webView = webView;
    _page = page.get();
    _fullScreenState = NotInFullScreen;

    return self;
}

- (NSRect)initialFrame
{
    return _initialFrame;
}

- (NSRect)finalFrame
{
    return _finalFrame;
}

- (NSArray *)savedConstraints
{
    return _savedConstraints.get();
}

- (void)setSavedConstraints:(NSArray *)savedConstraints
{
    _savedConstraints = savedConstraints;
}

- (WebCoreFullScreenPlaceholderView *)webViewPlaceholder
{
    return nil;
}

- (BOOL)isFullScreen
{
    return _fullScreenState == InFullScreen;
}

- (void)enterFullScreen:(CompletionHandler<void(bool)>&&)completionHandler
{
    // Element fullscreen is not available in this minimal implementation; report
    // failure so the page's requestFullscreen() promise rejects rather than hangs.
    if (completionHandler)
        completionHandler(false);
}

- (void)exitFullScreen:(CompletionHandler<void()>&&)completionHandler
{
    _fullScreenState = NotInFullScreen;
    if (completionHandler)
        completionHandler();
}

- (void)exitFullScreenImmediately
{
    _fullScreenState = NotInFullScreen;
}

- (void)requestExitFullScreen
{
    _fullScreenState = NotInFullScreen;
}

- (void)close
{
    _fullScreenState = NotInFullScreen;
}

- (void)beganEnterFullScreenWithInitialFrame:(NSRect)initialFrame finalFrame:(NSRect)finalFrame completionHandler:(CompletionHandler<void(bool)>&&)completionHandler
{
    _initialFrame = initialFrame;
    _finalFrame = finalFrame;
    if (completionHandler)
        completionHandler(false);
}

- (void)beganExitFullScreenWithInitialFrame:(NSRect)initialFrame finalFrame:(NSRect)finalFrame completionHandler:(CompletionHandler<void()>&&)completionHandler
{
    _initialFrame = initialFrame;
    _finalFrame = finalFrame;
    _fullScreenState = NotInFullScreen;
    if (completionHandler)
        completionHandler();
}

- (void)videoControlsManagerDidChange
{
}

@end

#endif // ENABLE(FULLSCREEN_API) && PLATFORM(MAC)
