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

#if ENABLE(FULLSCREEN_API) && PLATFORM(MAC)

#import <AppKit/AppKit.h>
#import <WebCore/BoxExtents.h>
#import <wtf/CompletionHandler.h>
#import <wtf/RetainPtr.h>
#import <wtf/WeakObjCPtr.h>
#import <wtf/WeakPtr.h>

namespace WebKit { 
class LayerTreeContext;
class WebPageProxy;
}

namespace WebCore {
class IntRect;
}

@class WKWebView;
@class WKFullScreenPlaceholderView;
@class WebCoreFullScreenPlaceholderView;

typedef enum FullScreenState : NSInteger FullScreenState;

@interface WKFullScreenWindowController : NSWindowController<NSWindowDelegate> {
@private
    // MAVERICKS_BACKPORT: typed NSView rather than WKWebView so the Safari-7 WKView path can use this
    // controller too (MinimalPageClient.mm). Every use of this ivar in the implementation is NSView API
    // — window/frame/superview/autoresizingMask/removeFromSuperview/makeFirstResponder: — so this widens
    // what the controller accepts without changing what it does. Cannot be retained, see <rdar://problem/14884666>.
    WeakObjCPtr<NSView> _webView;
    WeakPtr<WebKit::WebPageProxy> _page;
    RetainPtr<WKFullScreenPlaceholderView> _webViewPlaceholder;
    RetainPtr<NSView> _exitPlaceholder;
    RetainPtr<NSView> _clipView;
    RetainPtr<NSView> _backgroundView;
    NSRect _initialFrame;
    NSRect _finalFrame;
    RetainPtr<NSTimer> _watchdogTimer;
    RetainPtr<NSArray> _savedConstraints;

    FullScreenState _fullScreenState;
    CompletionHandler<void(bool)> _enterFullScreenCompletionHandler;
    CompletionHandler<void()> _beganExitFullScreenCompletionHandler;
    CompletionHandler<void()> _exitFullScreenCompletionHandler;

    // MAVERICKS_BACKPORT: set when the full-screen-space opt-out hid the menu bar and Dock, so the
    // restore is guarded by "did I hide it" rather than by state the teardown paths can lose, plus the
    // host's own options from before the hide, so the restore puts back what was there.
    BOOL _mavericksDidHidePresentationOptions;
    NSApplicationPresentationOptions _mavericksSavedPresentationOptions;

    double _savedScale;
    WebCore::FloatBoxExtent _savedObscuredContentInsets;
}

@property (readonly) NSRect initialFrame;
@property (readonly) NSRect finalFrame;
@property (assign) NSArray *savedConstraints;

// MAVERICKS_BACKPORT: takes NSView rather than WKWebView (see the _webView ivar comment).
- (instancetype)initWithWindow:(NSWindow *)window webView:(NSView *)webView page:(std::reference_wrapper<WebKit::WebPageProxy>)page;

@property (nonatomic, readonly) WebCoreFullScreenPlaceholderView *webViewPlaceholder;

- (BOOL)isFullScreen;

- (void)enterFullScreen:(CompletionHandler<void(bool)>&&)completionHandler;
- (void)exitFullScreen:(CompletionHandler<void()>&&)completionHandler;
- (void)exitFullScreenImmediately;
- (void)requestExitFullScreen;
- (void)close;
- (void)beganEnterFullScreenWithInitialFrame:(NSRect)initialFrame finalFrame:(NSRect)finalFrame completionHandler:(CompletionHandler<void(bool)>&&)completionHandler;
- (void)beganExitFullScreenWithInitialFrame:(NSRect)initialFrame finalFrame:(NSRect)finalFrame completionHandler:(CompletionHandler<void()>&&)completionHandler;

- (void)videoControlsManagerDidChange;

@end

#endif
