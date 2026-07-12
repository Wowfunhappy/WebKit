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

#import "config.h"
#import "WKFullScreenWindowController.h"

// MAVERICKS_BACKPORT status: minimal implementation. The full element-fullscreen
// controller depends on VideoPresentationManagerProxy and a number of 10.10+
// AppKit/animation APIs. This inert controller keeps real ObjC metadata in
// WebKit.framework and — crucially — completes every fullscreen request handshake
// it is handed (enter -> reports failure, exit/began -> reports done) so the
// HTML Fullscreen API resolves/rejects cleanly instead of hanging the page.
// Element fullscreen therefore degrades to "request denied" rather than crashing.
// The real controller can be restored from upstream.

// MAVERICKS_BACKPORT: gate on PLATFORM(MAC) (upstream uses !PLATFORM(IOS_FAMILY)); this stub is Mac-only.
#if ENABLE(FULLSCREEN_API) && PLATFORM(MAC)

/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
#import "AppKitSPI.h"
#import "GPUProcessProxy.h"
#import "LayerTreeContext.h"
#import "NativeWebMouseEvent.h"
#import "VideoPresentationManagerProxy.h"
#import "WKAPICast.h"
#import "WKViewInternal.h"
#import "WKViewPrivate.h"
#import "WKWebViewInternal.h"
#import "WebFullScreenManagerProxy.h"
MAVERICKS_BACKPORT */
#import "WebPageProxy.h"
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
#import "WebProcessProxy.h"
#import <QuartzCore/QuartzCore.h>
#import <WebCore/CGWindowUtilities.h>
#import <WebCore/FloatRect.h>
#import <WebCore/GeometryUtilities.h>
#import <WebCore/IntRect.h>
#import <WebCore/LocalizedStrings.h>
#import <WebCore/PlatformScreen.h>
#import <WebCore/VideoPresentationInterfaceMac.h>
#import <WebCore/VideoPresentationModel.h>
#import <WebCore/WebCoreFullScreenPlaceholderView.h>
#import <WebCore/WebCoreFullScreenWindow.h>
#import <pal/spi/cg/CoreGraphicsSPI.h>
#import <pal/spi/mac/NSWindowSPI.h>
#import <pal/system/SleepDisabler.h>
#import <wtf/BlockObjCExceptions.h>
#import <wtf/LoggerHelper.h>

static const NSTimeInterval DefaultWatchdogTimerInterval = 1;

@interface WKFullScreenPlaceholderView : WebCoreFullScreenPlaceholderView <NSScrollViewSeparatorTrackingAdapter>

@end

@implementation WKFullScreenPlaceholderView {
#if HAVE(LIQUID_GLASS)
    RetainPtr<NSScrollPocket> _scrollPocket;
    RetainPtr<NSHashTable<NSView *>> _scrollPocketContainers;
#endif
    WebCore::FloatBoxExtent _obscuredContentInsets;
}

- (NSRect)scrollViewFrame
{
    WebCore::FloatRect boundsAdjustedByHorizontalInsets = self.bounds;
    boundsAdjustedByHorizontalInsets.shiftXEdgeBy(_obscuredContentInsets.left());
    boundsAdjustedByHorizontalInsets.shiftMaxXEdgeBy(-_obscuredContentInsets.right());
    return [self convertRect:boundsAdjustedByHorizontalInsets toView:nil];
}

- (BOOL)hasScrolledContentsUnderTitlebar
{
    return NO;
}

#if HAVE(LIQUID_GLASS)

- (void)setTopScrollPocket:(NSScrollPocket *)scrollPocket obscuredContentInsets:(const WebCore::FloatBoxExtent&)obscuredContentInsets
{
    _scrollPocket = scrollPocket;
    if (!_scrollPocket)
        return;

    _scrollPocketContainers = [NSHashTable<NSView *> weakObjectsHashTable];
    _obscuredContentInsets = obscuredContentInsets;
    [self _recomputeScrollPocketFrame];
    [self addSubview:_scrollPocket.get()];
}

- (void)setFrame:(NSRect)frame
{
    super.frame = frame;

    [self _recomputeScrollPocketFrame];
}

- (void)setBounds:(NSRect)bounds
{
    super.bounds = bounds;

    [self _recomputeScrollPocketFrame];
}

- (void)setFrameSize:(NSSize)newSize
{
    super.frameSize = newSize;

    [self _recomputeScrollPocketFrame];
}

- (void)setBoundsSize:(NSSize)newSize
{
    super.boundsSize = newSize;

    [self _recomputeScrollPocketFrame];
}

- (void)_recomputeScrollPocketFrame
{
    [_scrollPocket setFrame:NSMakeRect(0, NSHeight(self.bounds) - _obscuredContentInsets.top(), NSWidth(self.bounds), _obscuredContentInsets.top())];
}

- (BOOL)scrollViewDrawsMagicPocket
{
    return !!_scrollPocket;
}

- (void)registerPocketContainer:(NSView *)container onEdge:(NSScrollPocketEdge)edge
{
    if (edge != NSScrollPocketEdgeTop)
        return;

    if (!container)
        return;

    if ([_scrollPocketContainers containsObject:container])
        return;

    if (!_scrollPocketContainers)
        _scrollPocketContainers = [NSHashTable<NSView *> weakObjectsHashTable];

    [_scrollPocketContainers addObject:container];
    [_scrollPocket addElementContainer:container];
}

- (void)unregisterPocketContainer:(NSView *)container onEdge:(NSScrollPocketEdge)edge
{
    if (edge != NSScrollPocketEdgeTop)
        return;

    if (!container)
        return;

    if (![_scrollPocketContainers containsObject:container])
        return;

    [_scrollPocketContainers removeObject:container];
    [_scrollPocket removeElementContainer:container];
}

#endif // HAVE(LIQUID_GLASS)

@end

@interface WKFullScreenWindowController (VideoPresentationManagerProxyClient)
- (void)didEnterPictureInPicture;
- (void)didExitPictureInPicture;
@end
MAVERICKS_BACKPORT */

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
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
    Ref page = pageWrapper.get();
    [window setDelegate:self];
    [window setCollectionBehavior:([window collectionBehavior] | NSWindowCollectionBehaviorFullScreenPrimary | NSWindowCollectionBehaviorStationary)];

    // Hide the titlebar during the animation to full screen so that only the WKWebView content is visible.
    window.titlebarAlphaValue = 0;
    window.animationBehavior = NSWindowAnimationBehaviorNone;

    RetainPtr contentView = [window contentView];
    contentView.get().hidden = YES;
    contentView.get().autoresizesSubviews = YES;
MAVERICKS_BACKPORT */

/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
    _backgroundView = adoptNS([[NSView alloc] initWithFrame:contentView.get().bounds]);
    _backgroundView.get().layer = [CALayer layer];
    _backgroundView.get().wantsLayer = YES;
    _backgroundView.get().autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [contentView addSubview:_backgroundView.get()];

    _clipView = adoptNS([[NSView alloc] initWithFrame:contentView.get().bounds]);
    [_clipView setWantsLayer:YES];
    [_clipView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
    [_backgroundView addSubview:_clipView.get()];

    [self windowDidLoad];
    [window displayIfNeeded];
MAVERICKS_BACKPORT */
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

- (void)enterFullScreen:(CompletionHandler<void(bool)>&&)completionHandler
{
// MAVERICKS_BACKPORT: stub reports enter-failure so requestFullscreen() rejects instead of hanging.
    // Element fullscreen is not available in this minimal implementation; report
    // failure so the page's requestFullscreen() promise rejects rather than hangs.
    if (completionHandler)
        completionHandler(false);
}

- (void)exitFullScreen:(CompletionHandler<void()>&&)completionHandler
{
// MAVERICKS_BACKPORT: stub exit just resets state and completes immediately (no exit animation).
    _fullScreenState = NotInFullScreen;
    if (completionHandler)
        completionHandler();
}

- (void)exitFullScreenImmediately
{
// MAVERICKS_BACKPORT: stub immediate-exit just resets state (no placeholder/window teardown).
    _fullScreenState = NotInFullScreen;
}

- (void)requestExitFullScreen
{
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
    if (RefPtr manager = [self _manager])
        manager->requestExitFullScreen();
}

- (void)beganExitFullScreenWithInitialFrame:(NSRect)initialFrame finalFrame:(NSRect)finalFrame completionHandler:(CompletionHandler<void()>&&)completionHandler
{
    if (_fullScreenState != WaitingToExitFullScreen)
        return completionHandler();
    _fullScreenState = ExitingFullScreen;
    _beganExitFullScreenCompletionHandler = WTF::move(completionHandler);

    RetainPtr window = [self window];
    if (![window isOnActiveSpace]) {
        // If the full screen window is not in the active space, the NSWindow full screen animation delegate methods
        // will never be called. So call finishedExitFullScreenAnimationAndExitImmediately explicitly.
        [self finishedExitFullScreenAnimationAndExitImmediately:NO];
    }

    [window exitFullScreenMode:self];
}

static RetainPtr<CGImageRef> takeWindowSnapshot(CGSWindowID windowID, bool captureAtNominalResolution)
{
    CGSWindowCaptureOptions options = kCGSCaptureIgnoreGlobalClipShape;
    if (captureAtNominalResolution)
        options |= kCGSWindowCaptureNominalResolution;
    RetainPtr<CFArrayRef> windowSnapshotImages = adoptCF(CGSHWCaptureWindowList(CGSMainConnectionID(), &windowID, 1, options));

    if (windowSnapshotImages && CFArrayGetCount(windowSnapshotImages.get()))
        return checked_cf_cast<CGImageRef>(CFArrayGetValueAtIndex(windowSnapshotImages.get(), 0));

    // Fall back to the non-hardware capture path if we didn't get a snapshot
    // (which usually happens if the window is fully off-screen).
    CGWindowImageOption imageOptions = kCGWindowImageBoundsIgnoreFraming | kCGWindowImageShouldBeOpaque;
    if (captureAtNominalResolution)
        imageOptions |= kCGWindowImageNominalResolution;
    return WebCore::cgWindowListCreateImage(CGRectNull, kCGWindowListOptionIncludingWindow, windowID, imageOptions);
}

- (void)_continueExitingFullscreenAfterPostingNotificationAndExitImmediately:(bool)immediately
{
    RefPtr manager = [self _manager];
    if (!manager)
        return;

    if (_fullScreenState == InFullScreen) {
        // If we are currently in the InFullScreen state, this notification is unexpected, meaning
        // fullscreen was exited without being initiated by WebKit. Do not return early, but continue to
        // clean up our state by calling those methods which would have been called by -exitFullscreen,
        // and proceed to close the fullscreen window.
        manager->requestExitFullScreen();
        [_webViewPlaceholder setTarget:nil];
        manager->setAnimatingFullScreen(false);
    } else if (_fullScreenState != ExitingFullScreen)
        return;
MAVERICKS_BACKPORT */
    _fullScreenState = NotInFullScreen;
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport

    // Hide the titlebar at the end of the animation so that it can slide away without turning blank.
    self.window.titlebarAlphaValue = 0;

    RetainPtr firstResponder = [[self window] firstResponder];

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    NSRect exitPlaceholderScreenRect = _initialFrame;
    exitPlaceholderScreenRect.origin.y = NSMaxY(WebCore::safeScreenFrame(retainPtr([[NSScreen screens] objectAtIndex:0]).get())) - NSMaxY(exitPlaceholderScreenRect);

    RetainPtr webView = _webView.get();
    RetainPtr<CGImageRef> webViewContents = takeWindowSnapshot([[webView window] windowNumber], true);
    webViewContents = adoptCF(CGImageCreateWithImageInRect(webViewContents.get(), NSRectToCGRect(exitPlaceholderScreenRect)));
    
    _exitPlaceholder = adoptNS([[NSView alloc] initWithFrame:[webView frame]]);
    [_exitPlaceholder setWantsLayer: YES];
    [_exitPlaceholder setAutoresizesSubviews: YES];
    [_exitPlaceholder setLayerContentsPlacement: NSViewLayerContentsPlacementScaleProportionallyToFit];
    [_exitPlaceholder setLayerContentsRedrawPolicy: NSViewLayerContentsRedrawNever];
    [_exitPlaceholder setFrame:[webView frame]];
    [[_exitPlaceholder layer] setContents:(__bridge id)webViewContents.get()];
    [retainPtr([webView superview]) addSubview:_exitPlaceholder.get() positioned:NSWindowAbove relativeTo:webView.get()];

    [CATransaction commit];
    [CATransaction flush];

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    
    [retainPtr(_backgroundView.get().layer) removeAllAnimations];
    RefPtr page = _page.get();
    page->setSuppressVisibilityUpdates(true);
    [webView removeFromSuperview];
    [webView setFrame:[_webViewPlaceholder frame]];
    [webView setAutoresizingMask:[_webViewPlaceholder autoresizingMask]];
    [retainPtr([_webViewPlaceholder superview]) addSubview:webView.get() positioned:NSWindowBelow relativeTo:_webViewPlaceholder.get()];

    BEGIN_BLOCK_OBJC_EXCEPTIONS
    [NSLayoutConstraint activateConstraints:retainPtr(self.savedConstraints).get()];
    END_BLOCK_OBJC_EXCEPTIONS
    self.savedConstraints = nil;
    makeResponderFirstResponderIfDescendantOfView(retainPtr([webView window]).get(), firstResponder.get(), webView.get());

    // These messages must be sent after the swap or flashing will occur during forceRepaint:
    manager->setAnimatingFullScreen(false);
    if (_beganExitFullScreenCompletionHandler)
        _beganExitFullScreenCompletionHandler();
    page->scalePageRelativeToScrollPosition(_savedScale, { });
    page->setObscuredContentInsets(_savedObscuredContentInsets);
    page->flushDeferredResizeEvents();
    page->flushDeferredScrollEvents();

    [CATransaction commit];
    [CATransaction flush];

    if (immediately) {
        [self completeFinishExitFullScreenAnimation];
        return;
    }

    page->updateRenderingWithForcedRepaint([weakSelf = WeakObjCPtr<WKFullScreenWindowController>(self)] {
        if (RetainPtr strongSelf = weakSelf.get())
            [strongSelf completeFinishExitFullScreenAnimation];
    });
}

- (void)finishedExitFullScreenAnimationAndExitImmediately:(bool)immediately
{
#if ENABLE(GPU_PROCESS)
    RefPtr gpuProcess = WebKit::GPUProcessProxy::singletonIfCreated();
    if (!gpuProcess)
        return;

    OBJC_ALWAYS_LOG(OBJC_LOGIDENTIFIER);

    gpuProcess->postWillTakeSnapshotNotification([self, protectedSelf = RetainPtr { self }, immediately, logIdentifier = OBJC_LOGIDENTIFIER] () mutable {
        OBJC_ALWAYS_LOG(logIdentifier, " - finished posting snapshot notification");

        [protectedSelf _continueExitingFullscreenAfterPostingNotificationAndExitImmediately:immediately];
    });
#else
    [self _continueExitingFullscreenAfterPostingNotificationAndExitImmediately:immediately];
#endif
}

- (void)completeFinishExitFullScreenAnimation
{
    [CATransaction begin];
    [CATransaction setDisableActions:YES];

#if HAVE(LIQUID_GLASS)
    [[_webViewPlaceholder window] unregisterScrollViewSeparatorTrackingAdapter:_webViewPlaceholder.get()];
#endif
    [_webViewPlaceholder removeFromSuperview];
    [retainPtr([self window]) orderOut:self];
    RetainPtr contentView = [[self window] contentView];
    contentView.get().hidden = YES;
    [_exitPlaceholder removeFromSuperview];
    [retainPtr([_exitPlaceholder layer]) setContents:nil];
    _exitPlaceholder = nil;

    [retainPtr([_webView.get() window]) makeKeyAndOrderFront:self];
    _webViewPlaceholder = nil;

    RefPtr page = _page.get();
    page->setSuppressVisibilityUpdates(false);
    page->setNeedsDOMWindowResizeEvent();

    [CATransaction commit];
    [CATransaction flush];
}

- (void)performClose:(id)sender
{
    if ([self isFullScreen])
        [self cancelOperation:sender];
MAVERICKS_BACKPORT */
}

- (void)close
{
// MAVERICKS_BACKPORT: stub close just resets state; upstream tears down placeholder views/animation.
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
// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
//     return _logger.get();
// (end MAVERICKS_BACKPORT restored block)
}

// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
// - (WTFLogChannel*)logChannel
// {
//     return &WebKit2LogFullscreen;
// }
// (end MAVERICKS_BACKPORT restored block)
@end
// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
// #endif
// (end MAVERICKS_BACKPORT restored block)

// MAVERICKS_BACKPORT: guard pairs with the PLATFORM(MAC) gate substituted for upstream's !PLATFORM(IOS_FAMILY).
#endif // ENABLE(FULLSCREEN_API) && PLATFORM(MAC)
