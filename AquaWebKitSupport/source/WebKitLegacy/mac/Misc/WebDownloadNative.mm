/*
 * Copyright (C) 2026 Wowfunhappy. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#import "config.h"
#import "WebDownloadNative.h"

#import <WebKitLegacy/WebDownload.h>
#import <objc/runtime.h>

@interface NSURLDownload (WebDownloadNativeLoader)
- (id)_initWithRequest:(NSURLRequest *)request delegate:(id)delegate directory:(NSString *)directory;
- (NSDictionary *)_resumeInformation;
- (NSString *)_directoryPath;
- (void)_setDirectoryPath:(NSString *)path;
@end

@implementation WebDownloadNative

- (instancetype)initWithDownload:(WebDownload *)download delegate:(id)delegate request:(NSURLRequest *)request directory:(NSString *)directory deletesFileUponFailure:(BOOL)deletesFileUponFailure
{
    if (!(self = [super init]))
        return nil;
    _download = download;
    _delegate = delegate;
    // As the WebDownload's own initializers: Safari's directory initializer, or the public one.
    if (directory)
        _loader = adoptNS([[NSURLDownload alloc] _initWithRequest:request delegate:self directory:directory]);
    else
        _loader = adoptNS([[NSURLDownload alloc] initWithRequest:request delegate:self]);
    [_loader setDeletesFileUponFailure:deletesFileUponFailure];
    return self;
}

// The WebDownload's own -downloadDidBegin: was delivered when its transfer began.
- (void)start
{
}

- (void)cancel
{
    [_loader cancel];
    _delegate = nil;
    // The WebDownload owns this transport; its release waits for the caller to return.
    std::exchange(_download, nil).autorelease();
}

- (void)setDestination:(NSString *)path allowOverwrite:(BOOL)allowOverwrite { [_loader setDestination:path allowOverwrite:allowOverwrite]; }
- (NSString *)directoryPath { return [_loader _directoryPath]; }
- (void)setDirectoryPath:(NSString *)path { [_loader _setDirectoryPath:path]; }
- (NSURLRequest *)request { return [_loader request]; }
- (NSData *)resumeData { return [_loader resumeData]; }
- (NSDictionary *)resumeInformation { return [_loader _resumeInformation]; }
- (BOOL)deletesFileUponFailure { return [_loader deletesFileUponFailure]; }
- (void)setDeletesFileUponFailure:(BOOL)value { [_loader setDeletesFileUponFailure:value]; }

// NSURLDownload's delegate, answered by the WebDownload's: the loader sees exactly the delegate methods the WebDownload's
// delegate implements.
- (BOOL)respondsToSelector:(SEL)selector
{
    if (selector == @selector(downloadDidBegin:) || selector == @selector(download:willSendRequest:redirectResponse:))
        return YES;
    if (protocol_getMethodDescription(@protocol(NSURLDownloadDelegate), selector, NO, YES).name)
        return [_delegate respondsToSelector:selector];
    return [super respondsToSelector:selector];
}

- (void)downloadDidBegin:(NSURLDownload *)download
{
}

- (NSURLRequest *)download:(NSURLDownload *)download willSendRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)redirectResponse
{
    // The WebDownload's delegate approved this request as the redirect it continues.
    if (!redirectResponse || ![_delegate respondsToSelector:@selector(download:willSendRequest:redirectResponse:)])
        return request;
    return [_delegate download:_download.get() willSendRequest:request redirectResponse:redirectResponse];
}

- (BOOL)download:(NSURLDownload *)download canAuthenticateAgainstProtectionSpace:(NSURLProtectionSpace *)protectionSpace
{
    return [_delegate download:_download.get() canAuthenticateAgainstProtectionSpace:protectionSpace];
}

- (void)download:(NSURLDownload *)download didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
{
    [_delegate download:_download.get() didReceiveAuthenticationChallenge:challenge];
}

- (void)download:(NSURLDownload *)download didCancelAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
{
    if ([_delegate respondsToSelector:@selector(download:didCancelAuthenticationChallenge:)])
        [_delegate download:_download.get() didCancelAuthenticationChallenge:challenge];
}

- (BOOL)downloadShouldUseCredentialStorage:(NSURLDownload *)download
{
    return [_delegate downloadShouldUseCredentialStorage:_download.get()];
}

- (void)download:(NSURLDownload *)download didReceiveResponse:(NSURLResponse *)response
{
    if ([_delegate respondsToSelector:@selector(download:didReceiveResponse:)])
        [_delegate download:_download.get() didReceiveResponse:response];
}

- (void)download:(NSURLDownload *)download willResumeWithResponse:(NSURLResponse *)response fromByte:(long long)startingByte
{
    if ([_delegate respondsToSelector:@selector(download:willResumeWithResponse:fromByte:)])
        [_delegate download:_download.get() willResumeWithResponse:response fromByte:startingByte];
}

- (void)download:(NSURLDownload *)download didReceiveDataOfLength:(NSUInteger)length
{
    if ([_delegate respondsToSelector:@selector(download:didReceiveDataOfLength:)])
        [_delegate download:_download.get() didReceiveDataOfLength:length];
}

- (BOOL)download:(NSURLDownload *)download shouldDecodeSourceDataOfMIMEType:(NSString *)encodingType
{
    return [_delegate download:_download.get() shouldDecodeSourceDataOfMIMEType:encodingType];
}

- (void)download:(NSURLDownload *)download decideDestinationWithSuggestedFilename:(NSString *)filename
{
    if ([_delegate respondsToSelector:@selector(download:decideDestinationWithSuggestedFilename:)])
        [_delegate download:_download.get() decideDestinationWithSuggestedFilename:filename];
}

- (void)download:(NSURLDownload *)download didCreateDestination:(NSString *)path
{
    if ([_delegate respondsToSelector:@selector(download:didCreateDestination:)])
        [_delegate download:_download.get() didCreateDestination:path];
}

- (void)downloadDidFinish:(NSURLDownload *)download
{
    RetainPtr delegate = std::exchange(_delegate, nil);
    WebDownload *webDownload = std::exchange(_download, nil).autorelease();
    if ([delegate respondsToSelector:@selector(downloadDidFinish:)])
        [delegate downloadDidFinish:webDownload];
}

- (void)download:(NSURLDownload *)download didFailWithError:(NSError *)error
{
    RetainPtr delegate = std::exchange(_delegate, nil);
    WebDownload *webDownload = std::exchange(_download, nil).autorelease();
    if ([delegate respondsToSelector:@selector(download:didFailWithError:)])
        [delegate download:webDownload didFailWithError:error];
}

@end
