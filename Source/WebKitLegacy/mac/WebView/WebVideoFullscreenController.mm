/*
 * Copyright (C) 2009-2018 Apple Inc. All rights reserved.
 * MAVERICKS_BACKPORT: macOS 10.9 minimal stub. The upstream controller drives fullscreen through AVKit
 * (AVPlayerView / WebAVPlayerView / PlaybackSessionInterfaceAVKitLegacy / WebCoreFullScreenWindow), none of
 * which are usable on 10.9, so the whole implementation is reduced to inert no-op methods here.
 */

#import "WebVideoFullscreenController.h"

// MAVERICKS_BACKPORT: PLATFORM(MAC)-first guard ordering for the 10.9 stub build (no behavior change).
#if PLATFORM(MAC) && ENABLE(VIDEO)

#import <WebCore/HTMLVideoElement.h>

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
}

- (void)exitFullscreen
{
}

@end

#endif
