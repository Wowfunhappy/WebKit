/*
 * Copyright (C) 2026 Wowfunhappy. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#pragma once

// A WebDownload whose curl transfer was redirected to a request curl does not load (cocoaCurlLoadsRequest)
// continues on NSURLDownload's own loader, which reaches the protocol that claims the request. The loader's
// delegate callbacks name the WebDownload, as the callbacks of the WebDownload's own loader do.
#import <Foundation/Foundation.h>
#import <WebCore/CocoaDownloadTransport.h>
#include <wtf/RetainPtr.h>

@class WebDownload;

@interface WebDownloadNative : NSObject <NSURLDownloadDelegate, WebCoreCocoaDownloadTransport> {
@package
    // Retained until the download finishes, fails or is cancelled, as the curl transfer retains it.
    RetainPtr<WebDownload> _download;
    RetainPtr<id> _delegate;
    RetainPtr<NSURLDownload> _loader;
}
- (instancetype)initWithDownload:(WebDownload *)download delegate:(id)delegate request:(NSURLRequest *)request directory:(NSString *)directory deletesFileUponFailure:(BOOL)deletesFileUponFailure;
@end
