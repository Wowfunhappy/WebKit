/*
 * Copyright (C) 2021 Apple Inc. All rights reserved.
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
#import "WKInspectorResourceURLSchemeHandler.h"

#if PLATFORM(MAC)

#ifndef dispatch_assert_queue
#define dispatch_assert_queue(q) ((void)(q))
#endif

#import "Logging.h"
#import "WKURLSchemeTask.h"
#import "WebInspectorUIProxy.h"
#import "WebURLSchemeHandlerCocoa.h"
#import <WebCore/MIMETypeRegistry.h>
#import <wtf/Assertions.h>
#import <wtf/darwin/DispatchExtras.h>

@implementation WKInspectorResourceURLSchemeHandler {
    RetainPtr<NSMapTable<id <WKURLSchemeTask>, NSOperation *>> _fileLoadOperations;
    RetainPtr<NSBundle> _cachedBundle;
    
    RetainPtr<NSSet<NSString *>> _allowedURLSchemesForCSP;
    RetainPtr<NSSet<NSURL *>> _mainResourceURLsForCSP;
}

- (NSSet<NSString *> *)allowedURLSchemesForCSP
{
    return _allowedURLSchemesForCSP.get();
}

- (void)setAllowedURLSchemesForCSP:(NSSet<NSString *> *)allowedURLSchemes
{
    _allowedURLSchemesForCSP = adoptNS([allowedURLSchemes copy]);
}

- (NSSet<NSURL *> *)mainResourceURLsForCSP
{
    if (!_mainResourceURLsForCSP)
        _mainResourceURLsForCSP = adoptNS([[NSSet alloc] initWithObjects:adoptNS([[NSURL alloc] initWithString:WebKit::WebInspectorUIProxy::inspectorPageURL().createNSString().get()]).get(), adoptNS([[NSURL alloc] initWithString:WebKit::WebInspectorUIProxy::inspectorTestPageURL().createNSString().get()]).get(), nil]);

    return _mainResourceURLsForCSP.get();
}

// MARK - WKURLSchemeHandler Protocol

- (void)webView:(WKWebView *)webView startURLSchemeTask:(id <WKURLSchemeTask>)urlSchemeTask
{
    NSLog(@"[INSPECTOR-SCHEME] startURLSchemeTask: URL=%@", urlSchemeTask.request.URL);
    dispatch_assert_queue(mainDispatchQueueSingleton());
    if (!_cachedBundle) {
        _cachedBundle = [NSBundle bundleWithIdentifier:@"com.apple.WebInspectorUI"];
        if (!_cachedBundle) {
            // 10.9 backport: explicitly load from StagedFrameworks if not auto-soft-linked.
            _cachedBundle = [NSBundle bundleWithPath:@"/System/Library/StagedFrameworks/Safari/WebInspectorUI.framework"];
            NSLog(@"[INSPECTOR-SCHEME] explicit-load WebInspectorUI bundle: %@", _cachedBundle.get());
        }
        // It is an error if WebInspectorUI has not already been soft-linked by the time
        // we load resources from it. And if soft-linking fails, we shouldn't start loads.
        RELEASE_ASSERT(_cachedBundle);
    }

    if (!_fileLoadOperations)
        _fileLoadOperations = adoptNS([[NSMapTable alloc] initWithKeyOptions:NSPointerFunctionsStrongMemory valueOptions:NSPointerFunctionsStrongMemory capacity:5]);

    RetainPtr operation = [NSBlockOperation blockOperationWithBlock:^{
        @try {
        [_fileLoadOperations removeObjectForKey:urlSchemeTask];

        RetainPtr<NSURL> requestURL = urlSchemeTask.request.URL;
        NSLog(@"[INSPECTOR-SCHEME-BLOCK] handling URL=%@ bundle=%@", requestURL.get(), _cachedBundle.get());
        NSLog(@"[INSPECTOR-SCHEME-BLOCK] relativePath=%@", requestURL.get().relativePath);
        RetainPtr<NSURL> fileURLForRequest = [_cachedBundle URLForResource:retainPtr(requestURL.get().relativePath).get() withExtension:@""];
        NSLog(@"[INSPECTOR-SCHEME-BLOCK] fileURL=%@", fileURLForRequest.get());
        if (!fileURLForRequest) {
            LOG_ERROR("Unable to find Web Inspector resource: %@", requestURL.get().absoluteString);
            [urlSchemeTask didFailWithError:[NSError errorWithDomain:NSCocoaErrorDomain code:NSURLErrorFileDoesNotExist userInfo:nil]];
            return;
        }

        NSError *readError = nil;
        // 10.9 backport: -[NSData dataWithContentsOfURL:options:error:] crashes inside Foundation
        // on this OS when passed a file:// URL. Use -[NSData dataWithContentsOfFile:] instead.
        NSData *fileData = nil;
        if ([fileURLForRequest.get() isFileURL])
            fileData = [NSData dataWithContentsOfFile:fileURLForRequest.get().path options:NSDataReadingMappedIfSafe error:&readError];
        else
            fileData = [NSData dataWithContentsOfURL:fileURLForRequest.get() options:0 error:&readError];
        NSLog(@"[INSPECTOR-SCHEME-BLOCK] read fileData=%p len=%zu err=%@", fileData, (size_t)fileData.length, readError);
        if (!fileData) {
            LOG_ERROR("Unable to read data for Web Inspector resource: %@", requestURL.get().absoluteString);
            [urlSchemeTask didFailWithError:[NSError errorWithDomain:NSCocoaErrorDomain code:NSURLErrorResourceUnavailable userInfo:@{
                NSUnderlyingErrorKey: readError,
            }]];
            return;
        }

        // 10.9 backport: MIMETypeRegistry::mimeTypeForExtension crashes on 10.9 (lazy table init
        // hits a null deref). Hard-code MIME types for the few extensions we ever serve.
        NSString *ext = fileURLForRequest.get().pathExtension;
        RetainPtr<NSString> mimeType;
        if ([ext isEqualToString:@"html"]) mimeType = @"text/html";
        else if ([ext isEqualToString:@"js"]) mimeType = @"application/javascript";
        else if ([ext isEqualToString:@"css"]) mimeType = @"text/css";
        else if ([ext isEqualToString:@"svg"]) mimeType = @"image/svg+xml";
        else if ([ext isEqualToString:@"png"]) mimeType = @"image/png";
        else if ([ext isEqualToString:@"gif"]) mimeType = @"image/gif";
        else if ([ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"]) mimeType = @"image/jpeg";
        else if ([ext isEqualToString:@"json"]) mimeType = @"application/json";
        else if ([ext isEqualToString:@"woff"]) mimeType = @"font/woff";
        else if ([ext isEqualToString:@"woff2"]) mimeType = @"font/woff2";
        else mimeType = @"application/octet-stream";

        NSLog(@"[INSPECTOR-SCHEME-BLOCK] mime=%@ fileSize=%zu", mimeType.get(), (size_t)fileData.length);
        RetainPtr<NSMutableDictionary> headerFields = adoptNS(@{
            @"Access-Control-Allow-Origin": @"*",
            @"Content-Length": adoptNS([[NSString alloc] initWithFormat:@"%zu", (size_t)fileData.length]).get(),
            @"Content-Type": mimeType.get(),
        }.mutableCopy);
        NSLog(@"[INSPECTOR-SCHEME-BLOCK] built headerFields=%@", headerFields.get());

        // Allow fetches for resources that use a registered custom URL scheme.
        if (_allowedURLSchemesForCSP && [retainPtr(self.mainResourceURLsForCSP) containsObject:requestURL.get()]) {
            RetainPtr listOfCustomProtocols = adoptNS([[NSString alloc] initWithFormat:@"%@:", retainPtr([retainPtr(_allowedURLSchemesForCSP.get().allObjects) componentsJoinedByString:@": "]).get()]);
            RetainPtr stringForCSPPolicy = adoptNS([[NSString alloc] initWithFormat:@"connect-src * %@; img-src * file: blob: resource: %@", listOfCustomProtocols.get(), listOfCustomProtocols.get()]);
            [headerFields setObject:stringForCSPPolicy.get() forKey:@"Content-Security-Policy"];
            NSLog(@"[INSPECTOR-SCHEME-BLOCK] added CSP");
        }

        RetainPtr<NSHTTPURLResponse> urlResponse = adoptNS([[NSHTTPURLResponse alloc] initWithURL:retainPtr(urlSchemeTask.request.URL).get() statusCode:200 HTTPVersion:nil headerFields:headerFields.get()]);
        NSLog(@"[INSPECTOR-SCHEME-BLOCK] urlResponse=%@", urlResponse.get());
        [urlSchemeTask didReceiveResponse:urlResponse.get()];
        NSLog(@"[INSPECTOR-SCHEME-BLOCK] didReceiveResponse ok");
        [urlSchemeTask didReceiveData:fileData];
        NSLog(@"[INSPECTOR-SCHEME-BLOCK] didReceiveData ok");
        [urlSchemeTask didFinish];
        NSLog(@"[INSPECTOR-SCHEME-BLOCK] didFinish ok");
        } @catch (NSException *e) {
            NSLog(@"[INSPECTOR-SCHEME-BLOCK-EXC] %@ %@", e.name, e.reason);
        }
    }];
    
    [_fileLoadOperations setObject:operation.get() forKey:urlSchemeTask];
    [[NSOperationQueue mainQueue] addOperation:operation.get()];
}

- (void)webView:(WKWebView *)webView stopURLSchemeTask:(id <WKURLSchemeTask>)urlSchemeTask
{
    dispatch_assert_queue(mainDispatchQueueSingleton());
    if (RetainPtr<NSOperation> operation = [_fileLoadOperations objectForKey:urlSchemeTask]) {
        [operation cancel];
        [_fileLoadOperations removeObjectForKey:urlSchemeTask];
    }
}

@end

#endif // PLATFORM(MAC)
