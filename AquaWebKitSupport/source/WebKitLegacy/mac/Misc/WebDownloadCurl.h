/*
 * Copyright (C) 2026 Wowfunhappy. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#pragma once

// WebDownload retains its NSURLDownload ABI with a curl-backed HTTP implementation.
#import <Foundation/Foundation.h>
#import <WebCore/CocoaDownloadTransport.h>
#import <WebKitLegacy/WebDownload.h>
#include <wtf/RefPtr.h>

class WebDownloadCurlClient;
namespace WebCore {
class CocoaCurlResourceHandle;
struct CocoaCurlDownloadTransfer;
}

// Adopts a paused legacy HTTP transaction without initializing another wire loader.
@interface WebDownload (CocoaCurlTransferAdoption)
- (instancetype)_initWithCurlResourceHandle:(WebCore::CocoaCurlResourceHandle&)handle delegate:(id)delegate;
@end

@interface WebDownloadCurl : NSObject <NSURLAuthenticationChallengeSender, WebCoreCocoaDownloadTransport> {
@package
    RefPtr<WebDownloadCurlClient> _client;
}
- (instancetype)initWithDownload:(WebDownload *)download delegate:(id)delegate request:(NSURLRequest *)request resumeInformation:(NSDictionary *)resumeInformation path:(NSString *)path directory:(NSString *)directory;
- (instancetype)initWithDownload:(WebDownload *)download delegate:(id)delegate transfer:(WebCore::CocoaCurlDownloadTransfer&&)transfer;
- (void)start;
- (void)cancel;
- (void)setDestination:(NSString *)path allowOverwrite:(BOOL)allowOverwrite;
- (NSURLRequest *)request;
- (NSData *)resumeData;
- (NSDictionary *)resumeInformation;
- (BOOL)deletesFileUponFailure;
- (void)setDeletesFileUponFailure:(BOOL)value;
@end
