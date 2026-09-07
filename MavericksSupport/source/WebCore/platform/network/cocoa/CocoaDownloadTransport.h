/* Copyright (C) 2026. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#pragma once
// native WebDownload delegates can retain a NetworkProcess-owned curl download without exporting its private cookie jar into WebKitLegacy.
#import <Foundation/Foundation.h>
#import <wtf/RetainPtr.h>

@protocol WebCoreCocoaDownloadTransport <NSObject>
- (void)start;
- (void)cancel;
- (void)setDestination:(NSString *)path allowOverwrite:(BOOL)allowOverwrite;
// Safari queries the configured native download directory when a resumed download begins.
- (NSString *)directoryPath;
- (void)setDirectoryPath:(NSString *)path;
- (NSURLRequest *)request;
- (NSData *)resumeData;
- (NSDictionary *)resumeInformation;
- (BOOL)deletesFileUponFailure;
- (void)setDeletesFileUponFailure:(BOOL)value;
@end

namespace WebCore {
class ResourceRequest;
WEBCORE_EXPORT RetainPtr<NSDictionary> cocoaDownloadRequestInformation(const ResourceRequest&, bool generatedCookieHeader);
WEBCORE_EXPORT bool restoreCocoaDownloadRequestInformation(ResourceRequest&, id);
using CocoaRemoteDownloadFactory = RetainPtr<id<WebCoreCocoaDownloadTransport>> (*)(NSURLDownload*, id<NSURLDownloadDelegate>, NSDictionary*, NSString*);
WEBCORE_EXPORT void setCocoaRemoteDownloadFactory(CocoaRemoteDownloadFactory);
WEBCORE_EXPORT RetainPtr<id<WebCoreCocoaDownloadTransport>> createCocoaRemoteDownload(NSURLDownload*, id<NSURLDownloadDelegate>, NSDictionary*, NSString*);
}
