/*
 * Copyright (C) 2011 Apple Inc. All rights reserved.
 * MAVERICKS_BACKPORT: stubbed minimal controller; original copyright span narrowed accordingly.
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

// MAVERICKS_BACKPORT: gate on PLATFORM(MAC) (upstream uses !PLATFORM(IOS_FAMILY)); this stub is Mac-only.
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

// MAVERICKS_BACKPORT: stub @implementation; init keeps only the page/view/state ivars (no placeholder/background/clip views or PiP observer).
@implementation WKFullScreenWindowController

- (instancetype)initWithWindow:(NSWindow *)window webView:(WKWebView *)webView page:(std::reference_wrapper<WebKit::WebPageProxy>)page
{
    self = [super initWithWindow:window];
    if (!self)
        return nil;

    _webView = webView;
    _page = page.get();
    // MAVERICKS_BACKPORT: start in NotInFullScreen; no enter/exit animation pipeline exists here.
    _fullScreenState = NotInFullScreen;

    return self;
}

// MAVERICKS_BACKPORT: plain accessor (upstream's is @synthesize-backed in the full controller).
- (NSRect)initialFrame
{
    return _initialFrame;
}

// MAVERICKS_BACKPORT: plain accessor (upstream's is @synthesize-backed in the full controller).
- (NSRect)finalFrame
{
    return _finalFrame;
}

- (NSArray *)savedConstraints
{
    return _savedConstraints.get();
}

// MAVERICKS_BACKPORT: plain accessor (upstream's is @synthesize-backed via the full controller's ivars).
- (void)setSavedConstraints:(NSArray *)savedConstraints
{
    _savedConstraints = savedConstraints;
}

// MAVERICKS_BACKPORT: no placeholder view in the stub; upstream returns the swapped-in WKFullScreenPlaceholderView.
- (WebCoreFullScreenPlaceholderView *)webViewPlaceholder
{
    return nil;
}

// MAVERICKS_BACKPORT: stub tracks only InFullScreen (no entering/waiting transient states are reached).
- (BOOL)isFullScreen
{
    return _fullScreenState == InFullScreen;
}

// MAVERICKS_BACKPORT: stub reports enter-failure so requestFullscreen() rejects instead of hanging.
- (void)enterFullScreen:(CompletionHandler<void(bool)>&&)completionHandler
{
    // Element fullscreen is not available in this minimal implementation; report
    // failure so the page's requestFullscreen() promise rejects rather than hangs.
    if (completionHandler)
        completionHandler(false);
}

// MAVERICKS_BACKPORT: stub exit just resets state and completes immediately (no exit animation).
- (void)exitFullScreen:(CompletionHandler<void()>&&)completionHandler
{
    _fullScreenState = NotInFullScreen;
    if (completionHandler)
        completionHandler();
}

// MAVERICKS_BACKPORT: stub immediate-exit just resets state (no placeholder/window teardown).
- (void)exitFullScreenImmediately
{
    _fullScreenState = NotInFullScreen;
}

- (void)requestExitFullScreen
{
    _fullScreenState = NotInFullScreen;
}

// MAVERICKS_BACKPORT: stub close just resets state; upstream tears down placeholder views/animation.
- (void)close
{
    _fullScreenState = NotInFullScreen;
}

// MAVERICKS_BACKPORT: stub records frames and reports enter-failure (no fullscreen animation on 10.9).
- (void)beganEnterFullScreenWithInitialFrame:(NSRect)initialFrame finalFrame:(NSRect)finalFrame completionHandler:(CompletionHandler<void(bool)>&&)completionHandler
{
    _initialFrame = initialFrame;
    _finalFrame = finalFrame;
    if (completionHandler)
        completionHandler(false);
}

// MAVERICKS_BACKPORT: stub records frames and immediately completes the exit handshake (no animation path).
- (void)beganExitFullScreenWithInitialFrame:(NSRect)initialFrame finalFrame:(NSRect)finalFrame completionHandler:(CompletionHandler<void()>&&)completionHandler
{
    _initialFrame = initialFrame;
    _finalFrame = finalFrame;
    _fullScreenState = NotInFullScreen;
    if (completionHandler)
        completionHandler();
}

// MAVERICKS_BACKPORT: no-op stub; video controls manager wiring depends on VideoPresentationManagerProxy (absent here).
- (void)videoControlsManagerDidChange
{
}

@end

// MAVERICKS_BACKPORT: guard pairs with the PLATFORM(MAC) gate substituted for upstream's !PLATFORM(IOS_FAMILY).
#endif // ENABLE(FULLSCREEN_API) && PLATFORM(MAC)
