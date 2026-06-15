/*
 * Copyright (C) 2011-2023 Apple Inc. All rights reserved.
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
#import "WKBrowsingContextControllerInternal.h"

#import "PageLoadStateObserver.h"
#import "WebProcessPool.h"
#import "WKErrorCF.h"
#import "WKFrame.h"
#import "WKPage.h"
#import "WKPageLoaderClient.h"
#import "WKType.h"
#import "WKURL.h"
#import "WKURLCF.h"

// 10.9 backport: the legacy controller's loading/delegate API was gutted
// upstream. QuickLook's Web2.qldisplay needs a controller it can pull off a
// WKView (-[WKView browsingContextController]) and drive. It loads/observes via
// the C SPI (WKPageLoad*, WKPageSetPageLoaderClient) on the page it gets from
// the view, so the controller here only needs to wrap a WKPageRef, vend it, and
// honor the few ObjC convenience selectors the bundle may send.
@interface WKBrowsingContextController () {
    WKPageRef _pageRef;
    id _loadDelegate;
}
- (id)loadDelegate;
@end

// 10.9 backport: bridge the WebKit2 C-SPI page loader client to the legacy
// -[<loadDelegate> browsingContextControllerDid...] callbacks that Web2.qldisplay
// relies on to know when its preview has finished loading (so it can snapshot).
// Only main-frame milestones are forwarded, matching the original SPI semantics.
static WKBrowsingContextController *controllerFromClientInfo(const void *clientInfo)
{
    return (__bridge WKBrowsingContextController *)clientInfo;
}

static void didStartProvisionalLoadForFrame(WKPageRef, WKFrameRef frame, WKTypeRef, const void *clientInfo)
{
    if (!WKFrameIsMainFrame(frame))
        return;
    WKBrowsingContextController *controller = controllerFromClientInfo(clientInfo);
    id delegate = [controller loadDelegate];
    if ([delegate respondsToSelector:@selector(browsingContextControllerDidStartProvisionalLoad:)])
        [delegate browsingContextControllerDidStartProvisionalLoad:controller];
}

static void didReceiveServerRedirectForProvisionalLoadForFrame(WKPageRef, WKFrameRef frame, WKTypeRef, const void *clientInfo)
{
    if (!WKFrameIsMainFrame(frame))
        return;
    WKBrowsingContextController *controller = controllerFromClientInfo(clientInfo);
    id delegate = [controller loadDelegate];
    if ([delegate respondsToSelector:@selector(browsingContextControllerDidReceiveServerRedirectForProvisionalLoad:)])
        [delegate browsingContextControllerDidReceiveServerRedirectForProvisionalLoad:controller];
}

static void didCommitLoadForFrame(WKPageRef, WKFrameRef frame, WKTypeRef, const void *clientInfo)
{
    if (!WKFrameIsMainFrame(frame))
        return;
    WKBrowsingContextController *controller = controllerFromClientInfo(clientInfo);
    id delegate = [controller loadDelegate];
    if ([delegate respondsToSelector:@selector(browsingContextControllerDidCommitLoad:)])
        [delegate browsingContextControllerDidCommitLoad:controller];
}

static void didFinishLoadForFrame(WKPageRef, WKFrameRef frame, WKTypeRef, const void *clientInfo)
{
    if (!WKFrameIsMainFrame(frame))
        return;
    WKBrowsingContextController *controller = controllerFromClientInfo(clientInfo);
    id delegate = [controller loadDelegate];
    if ([delegate respondsToSelector:@selector(browsingContextControllerDidFinishLoad:)])
        [delegate browsingContextControllerDidFinishLoad:controller];
}

static NSError *nsErrorFromWKError(WKErrorRef error)
{
    if (!error)
        return nil;
    // MRC: WKErrorCopyCFError returns +1; balance via autorelease (toll-free bridge).
    CFErrorRef cfError = WKErrorCopyCFError(kCFAllocatorDefault, error);
    return [(NSError *)cfError autorelease];
}

static void didFailProvisionalLoadWithErrorForFrame(WKPageRef, WKFrameRef frame, WKErrorRef error, WKTypeRef, const void *clientInfo)
{
    if (!WKFrameIsMainFrame(frame))
        return;
    WKBrowsingContextController *controller = controllerFromClientInfo(clientInfo);
    id delegate = [controller loadDelegate];
    if ([delegate respondsToSelector:@selector(browsingContextControllerDidFailProvisionalLoad:withError:)])
        [delegate browsingContextControllerDidFailProvisionalLoad:controller withError:nsErrorFromWKError(error)];
}

static void didFailLoadWithErrorForFrame(WKPageRef, WKFrameRef frame, WKErrorRef error, WKTypeRef, const void *clientInfo)
{
    if (!WKFrameIsMainFrame(frame))
        return;
    WKBrowsingContextController *controller = controllerFromClientInfo(clientInfo);
    id delegate = [controller loadDelegate];
    if ([delegate respondsToSelector:@selector(browsingContextControllerDidFailLoad:withError:)])
        [delegate browsingContextControllerDidFailLoad:controller withError:nsErrorFromWKError(error)];
}

ALLOW_DEPRECATED_IMPLEMENTATIONS_BEGIN
@implementation WKBrowsingContextController
ALLOW_DEPRECATED_IMPLEMENTATIONS_END

- (instancetype)_initWithPageRef:(WKPageRef)pageRef
{
    self = [super init];
    if (!self)
        return nil;
    _pageRef = pageRef;
    if (_pageRef)
        WKRetain(_pageRef);
    return self;
}

- (void)dealloc
{
    if (_pageRef) {
        // Drop the loader client first so its clientInfo (self) can't be used
        // after we're gone.
        if (_loadDelegate)
            WKPageSetPageLoaderClient(_pageRef, nullptr);
        WKRelease(_pageRef);
    }
    [super dealloc];
}

- (WKPageRef)_pageRefInternal
{
    return _pageRef;
}

// Web2.qldisplay calls -pageRef to obtain the page for its own C-SPI clients.
- (WKPageRef)pageRef
{
    return _pageRef;
}

// Web2.qldisplay installs its observer via -setLoadDelegate:; -setDelegate: is
// kept as an alias for any caller compiled against the older spelling. The
// delegate is unretained (the delegate owns the controller).
- (void)setLoadDelegate:(id)loadDelegate
{
    _loadDelegate = loadDelegate;

    if (!_pageRef)
        return;

    if (loadDelegate) {
        WKPageLoaderClientV0 client;
        memset(&client, 0, sizeof(client));
        client.base.version = 0;
        client.base.clientInfo = (__bridge const void *)self;
        client.didStartProvisionalLoadForFrame = didStartProvisionalLoadForFrame;
        client.didReceiveServerRedirectForProvisionalLoadForFrame = didReceiveServerRedirectForProvisionalLoadForFrame;
        client.didFailProvisionalLoadWithErrorForFrame = didFailProvisionalLoadWithErrorForFrame;
        client.didCommitLoadForFrame = didCommitLoadForFrame;
        client.didFinishLoadForFrame = didFinishLoadForFrame;
        client.didFailLoadWithErrorForFrame = didFailLoadWithErrorForFrame;
        WKPageSetPageLoaderClient(_pageRef, &client.base);
    } else
        WKPageSetPageLoaderClient(_pageRef, nullptr);
}

- (id)loadDelegate
{
    return _loadDelegate;
}

- (void)setDelegate:(id)delegate
{
    [self setLoadDelegate:delegate];
}

- (id)delegate
{
    return _loadDelegate;
}

- (void)loadRequest:(NSURLRequest *)request
{
    if (!_pageRef || !request.URL)
        return;
    WKURLRef url = WKURLCreateWithCFURL((__bridge CFURLRef)request.URL);
    WKPageLoadURL(_pageRef, url);
    WKRelease(url);
}

- (void)loadFileURL:(NSURL *)URL restrictToFilesWithin:(NSURL *)allowedDirectory
{
    if (!_pageRef || !URL)
        return;
    WKURLRef fileURL = WKURLCreateWithCFURL((__bridge CFURLRef)URL);
    WKURLRef resourceDirectoryURL = allowedDirectory ? WKURLCreateWithCFURL((__bridge CFURLRef)allowedDirectory) : nullptr;
    WKPageLoadFile(_pageRef, fileURL, resourceDirectoryURL);
    WKRelease(fileURL);
    if (resourceDirectoryURL)
        WKRelease(resourceDirectoryURL);
}

#pragma mark Loading

+ (void)registerSchemeForCustomProtocol:(NSString *)scheme
{
    if ([NSThread isMainThread])
        WebKit::WebProcessPool::registerGlobalURLSchemeAsHavingCustomProtocolHandlers(scheme);
    else {
        // This cannot be RunLoop::mainSingleton().dispatch because it is called before the main runloop is initialized. See rdar://problem/73615999
        WorkQueue::mainSingleton().dispatch([scheme = retainPtr(scheme)] {
            WebKit::WebProcessPool::registerGlobalURLSchemeAsHavingCustomProtocolHandlers(scheme.get());
        });
    }
}

+ (void)unregisterSchemeForCustomProtocol:(NSString *)scheme
{
    if ([NSThread isMainThread])
        WebKit::WebProcessPool::unregisterGlobalURLSchemeAsHavingCustomProtocolHandlers(scheme);
    else {
        // This cannot be RunLoop::mainSingleton().dispatch because it is called before the main runloop is initialized. See rdar://problem/73615999
        WorkQueue::mainSingleton().dispatch([scheme = retainPtr(scheme)] {
            WebKit::WebProcessPool::unregisterGlobalURLSchemeAsHavingCustomProtocolHandlers(scheme.get());
        });
    }
}

@end
