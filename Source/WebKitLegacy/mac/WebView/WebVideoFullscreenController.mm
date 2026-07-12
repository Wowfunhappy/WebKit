/*
 * Copyright (C) 2009-2018 Apple Inc. All rights reserved.
 * MAVERICKS_BACKPORT: macOS 10.9 minimal stub. The upstream controller drives fullscreen through AVKit
 * (AVPlayerView / WebAVPlayerView / PlaybackSessionInterfaceAVKitLegacy / WebCoreFullScreenWindow), none of
 * which are usable on 10.9, so the whole implementation is reduced to inert no-op methods here.
 */

#import "WebVideoFullscreenController.h"

// MAVERICKS_BACKPORT: PLATFORM(MAC)-first guard ordering for the 10.9 stub build (no behavior change).
#if PLATFORM(MAC) && ENABLE(VIDEO)

// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
// #import <AVFoundation/AVPlayer.h>
// (end MAVERICKS_BACKPORT restored block)
#import <WebCore/HTMLVideoElement.h>
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
#import <WebCore/PlaybackSessionInterfaceAVKitLegacy.h>
#import <WebCore/PlaybackSessionModelMediaElement.h>
#import <WebCore/WebAVPlayerController.h>
#import <WebCore/WebCoreFullScreenWindow.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <pal/spi/cocoa/AVKitSPI.h>
#import <pal/spi/mac/NSWindowSPI.h>
#import <wtf/RetainPtr.h>

#import <pal/cf/CoreMediaSoftLink.h>
#import <pal/cocoa/AVFoundationSoftLink.h>

SOFTLINK_AVKIT_FRAMEWORK()
SOFT_LINK_CLASS(AVKit, AVPlayerView)

ALLOW_DEPRECATED_DECLARATIONS_BEGIN

@interface AVPlayerView (SecretStuff)
@property (nonatomic, assign) BOOL showsAudioOnlyIndicatorView;
@end

@interface WebVideoFullscreenOverlayLayer : CALayer
@end

@implementation WebVideoFullscreenOverlayLayer
- (void)layoutSublayers
{
    for (CALayer* layer in self.sublayers)
        layer.frame = self.bounds;
}
@end

@class WebAVPlayerView;

@protocol WebAVPlayerViewDelegate
- (BOOL)playerViewIsFullScreen:(WebAVPlayerView*)playerView;
- (void)playerViewRequestEnterFullscreen:(WebAVPlayerView*)playerView;
- (void)playerViewRequestExitFullscreen:(WebAVPlayerView*)playerView;
@end

@interface WebAVPlayerView : AVPlayerView
@property (weak) id<WebAVPlayerViewDelegate> webDelegate;
@end

static id<WebAVPlayerViewDelegate> WebAVPlayerView_webDelegate(id aSelf, SEL)
{
    void* webDelegate = nil;
    object_getInstanceVariable(aSelf, "_webDelegate", &webDelegate);
    return static_cast<id<WebAVPlayerViewDelegate>>(webDelegate);
}

static void WebAVPlayerView_setWebDelegate(id aSelf, SEL, id<WebAVPlayerViewDelegate> webDelegate)
{
    object_setInstanceVariable(aSelf, "_webDelegate", webDelegate);
}

static BOOL WebAVPlayerView_isFullScreen(id aSelf, SEL)
{
    WebAVPlayerView *playerView = aSelf;
    return [playerView.webDelegate playerViewIsFullScreen:playerView];
}

static void WebAVPlayerView_enterFullScreen(id aSelf, SEL, id sender)
{
    WebAVPlayerView *playerView = aSelf;
    [playerView.webDelegate playerViewRequestEnterFullscreen:playerView];
}

static void WebAVPlayerView_exitFullScreen(id aSelf, SEL, id sender)
{
    WebAVPlayerView *playerView = aSelf;
    [playerView.webDelegate playerViewRequestExitFullscreen:playerView];
}

static WebAVPlayerView *allocWebAVPlayerViewInstance()
{
    static NeverDestroyed<RetainPtr<Class>> theClass = [] {
        ASSERT(getAVPlayerViewClassSingleton());
        RetainPtr aClass = objc_allocateClassPair(getAVPlayerViewClassSingleton(), "WebAVPlayerView", 0);
        RetainPtr theClass = aClass;
        class_addMethod(theClass.get(), @selector(setWebDelegate:), (IMP)WebAVPlayerView_setWebDelegate, "v@:@");
        class_addMethod(theClass.get(), @selector(webDelegate), (IMP)WebAVPlayerView_webDelegate, "@@:");
        class_addMethod(theClass.get(), @selector(isFullScreen), (IMP)WebAVPlayerView_isFullScreen, "B@:");
        class_addMethod(theClass.get(), @selector(enterFullScreen:), (IMP)WebAVPlayerView_enterFullScreen, "v@:@");
        class_addMethod(theClass.get(), @selector(exitFullScreen:), (IMP)WebAVPlayerView_exitFullScreen, "v@:@");

        class_addIvar(theClass.get(), "_webDelegate", sizeof(id), log2(sizeof(id)), "@");
        class_addIvar(theClass.get(), "_webIsFullScreen", sizeof(BOOL), log2(sizeof(BOOL)), "B");

        objc_registerClassPair(theClass.get());
        return theClass;
    }();
    return (WebAVPlayerView *)[theClass->get() alloc];
}

@interface WebVideoFullscreenController () <WebAVPlayerViewDelegate, NSWindowDelegate> {
    RefPtr<WebCore::PlaybackSessionModelMediaElement> _playbackModel;
    RefPtr<WebCore::PlaybackSessionInterfaceIOS> _playbackInterface;
    RetainPtr<NSView> _contentOverlay;
    RetainPtr<WebAVPlayerView> _playerView;
    BOOL _isFullScreen;
}
@property (readonly) WebCoreFullScreenWindow* fullscreenWindow;
@end
MAVERICKS_BACKPORT */

@implementation WebVideoFullscreenController

// MAVERICKS_BACKPORT: stub body just records the element; the upstream AVKit playback-model/interface setup is dropped on 10.9.
- (void)setVideoElement:(NakedPtr<WebCore::HTMLVideoElement>)videoElement
{
    _videoElement = videoElement.get();
}

- (NakedPtr<WebCore::HTMLVideoElement>)videoElement
{
    return _videoElement.get();
}

// MAVERICKS_BACKPORT: no-op fullscreen enter/exit on 10.9 (the AVKit fullscreen window/animation path is unavailable).
- (void)enterFullscreen:(NSScreen *)screen
{
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
    if (!_videoElement)
        return;
    [NSAnimationContext beginGrouping];
    _videoElement->setVideoFullscreenLayer(_contentOverlay.get().layer, [self, protectedSelf = retainPtr(self)] {
        [self.fullscreenWindow setFrame:self.videoElementRect display:YES];
        [self.fullscreenWindow makeKeyAndOrderFront:self];
        [self.fullscreenWindow enterFullScreenMode:self];
        [NSAnimationContext endGrouping];
    });
MAVERICKS_BACKPORT */
}

- (void)exitFullscreen
{
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
    [self.fullscreenWindow exitFullScreenMode:self];
}

- (NSRect)videoElementRect
{
    return _videoElement->screenRect();
}

- (void)applicationDidResignActive:(NSNotification*)notification
{
    UNUSED_PARAM(notification);
    NSWindow* fullscreenWindow = [self fullscreenWindow];

    // Replicate the QuickTime Player (X) behavior when losing active application status:
    // Is the fullscreen screen the main screen? (Note: this covers the case where only a
    // single screen is available.)  Is the fullscreen screen on the current space? IFF so,
    // then exit fullscreen mode.
    if (fullscreenWindow.screen == [NSScreen screens][0] && fullscreenWindow.onActiveSpace)
        [self _requestExit];
}

- (void)_requestExit
{
    [self.fullscreenWindow exitFullScreenMode:self];
}

- (void)_requestEnter
{
    if (_videoElement)
        _videoElement->enterFullscreen();
}

- (void)cancelOperation:(id)sender
{
    [self _requestExit];
}

- (BOOL)playerViewIsFullScreen:(WebAVPlayerView*)playerView
{
    return _isFullScreen;
}

- (void)playerViewRequestEnterFullscreen:(AVPlayerView*)playerView
{
    [self _requestEnter];
}

- (void)playerViewRequestExitFullscreen:(AVPlayerView*)playerView
{
    [self _requestExit];
}

- (nullable NSArray<NSWindow *> *)customWindowsToEnterFullScreenForWindow:(NSWindow *)window
{
    return @[self.fullscreenWindow];
}

- (void)window:(NSWindow *)window startCustomAnimationToEnterFullScreenWithDuration:(NSTimeInterval)duration
{
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.allowsImplicitAnimation = YES;
        context.duration = duration;
        [window setFrame:window.screen.frame display:YES];
    } completionHandler:NULL];
}

- (nullable NSArray<NSWindow *> *)customWindowsToExitFullScreenForWindow:(NSWindow *)window
{
    return @[self.fullscreenWindow];
}

- (void)window:(NSWindow *)window startCustomAnimationToExitFullScreenWithDuration:(NSTimeInterval)duration
{
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.allowsImplicitAnimation = YES;
        context.duration = duration;
        [window setFrame:self.videoElementRect display:YES];
    } completionHandler:NULL];
}

- (void)windowDidEnterFullScreen:(NSNotification *)notification
{
    _playerView.get().controlsStyle = AVPlayerViewControlsStyleFloating;
    [_playerView willChangeValueForKey:@"isFullScreen"];
    _isFullScreen = YES;
    [_playerView didChangeValueForKey:@"isFullScreen"];
    if (_videoElement)
        _videoElement->didBecomeFullscreenElement();
}

- (void)windowWillExitFullScreen:(NSNotification *)notification
{
    _playerView.get().controlsStyle = AVPlayerViewControlsStyleNone;
}

- (void)windowDidExitFullScreen:(NSNotification *)notification
{
    [_playerView willChangeValueForKey:@"isFullScreen"];
    _isFullScreen = NO;
    [_playerView didChangeValueForKey:@"isFullScreen"];

    if (!_videoElement) {
        [self.fullscreenWindow close];
        return;
    }

    [NSAnimationContext beginGrouping];
    _videoElement->setVideoFullscreenLayer(nil, [self, protectedSelf = retainPtr(self)] {
        [self.fullscreenWindow close];
        [NSAnimationContext endGrouping];
    });

    if (_videoElement->isFullscreen())
        _videoElement->exitFullscreen();
MAVERICKS_BACKPORT */
}

@end

// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
// ALLOW_DEPRECATED_DECLARATIONS_END
//
// (end MAVERICKS_BACKPORT restored block)
#endif
