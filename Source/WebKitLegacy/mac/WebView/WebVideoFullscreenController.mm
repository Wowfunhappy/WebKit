/*
 * Copyright (C) 2009-2018 Apple Inc. All rights reserved.
 * macOS 10.9 minimal stub - AVKit fullscreen unsupported.
 */

#import "WebVideoFullscreenController.h"

#if PLATFORM(MAC) && ENABLE(VIDEO)

#import <WebCore/HTMLVideoElement.h>

@implementation WebVideoFullscreenController

- (void)setVideoElement:(NakedPtr<WebCore::HTMLVideoElement>)videoElement
{
    _videoElement = videoElement.get();
}

- (NakedPtr<WebCore::HTMLVideoElement>)videoElement
{
    return _videoElement.get();
}

- (void)enterFullscreen:(NSScreen *)screen
{
}

- (void)exitFullscreen
{
}

@end

#endif
