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
// MAVERICKS_BACKPORT: import the Internal header (not the public one) to reach the restored
// _initWithPageRef:/loader-client SPI this file re-implements for QuickLook/Mail.
#import "WKBrowsingContextControllerInternal.h"

#import "PageLoadStateObserver.h"
// MAVERICKS_BACKPORT: the load-delegate protocol, so the sends below are checked against the
// selectors 10.9's clients actually implement. That header is diverged to the pre-2013 spelling of
// the two failure callbacks for exactly this reason -- see the MAVERICKS_BACKPORT note on them.
#import "WKBrowsingContextLoadDelegate.h"
// MAVERICKS_BACKPORT: extra imports backing the restored controller implementation below.
#import "WebPageProxy.h"
#import "WebProcessPool.h"
#import "WKAPICast.h"
#import "WKConnectionInternal.h"
#import "WKData.h"
#import "WKErrorCF.h"
#import "WKFrame.h"
#import "WKPage.h"
// MAVERICKS_BACKPORT: pagination C SPI (WKPageSet/GetPaginationMode etc.) backing the restored
// -[WKBrowsingContextController(Private)] pagination accessors iBooks' BKAssetEpub drives.
#import "WKPagePrivate.h"
#import "WKPageLoaderClient.h"
#import "WKString.h"
#import "WKStringCF.h"
#import "WKType.h"
#import "WKURL.h"
#import "WKURLCF.h"

// MAVERICKS_BACKPORT: the legacy controller's loading/delegate API was gutted
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

// MAVERICKS_BACKPORT: the original WKBrowsingContextController(Private) pagination SPI enum,
// restored so BKAssetEpub's -setPaginationMode: argument type matches (NSInteger-backed). Its
// values line up 1:1 with the C SPI's WKPaginationMode (kWKPaginationMode*), so the accessors
// below map by a direct cast.
typedef NS_ENUM(NSInteger, WKBrowsingContextPaginationMode) {
    WKPaginationModeUnpaginated,
    WKPaginationModeLeftToRight,
    WKPaginationModeRightToLeft,
    WKPaginationModeTopToBottom,
    WKPaginationModeBottomToTop,
};

// MAVERICKS_BACKPORT: bridge the WebKit2 C-SPI page loader client to the legacy
// -[<loadDelegate> browsingContextControllerDid...] callbacks that Web2.qldisplay
// relies on to know when its preview has finished loading (so it can snapshot).
// Only main-frame milestones are forwarded, matching the original SPI semantics.
static WKBrowsingContextController *controllerFromClientInfo(const void *clientInfo)
{
    return (__bridge WKBrowsingContextController *)clientInfo;
}

static void didStartProvisionalLoadForFrame(WKPageRef page, WKFrameRef frame, WKTypeRef, const void *clientInfo)
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

static void didCommitLoadForFrame(WKPageRef page, WKFrameRef frame, WKTypeRef, const void *clientInfo)
{
    if (!WKFrameIsMainFrame(frame))
        return;
    WKBrowsingContextController *controller = controllerFromClientInfo(clientInfo);
    id delegate = [controller loadDelegate];
    if ([delegate respondsToSelector:@selector(browsingContextControllerDidCommitLoad:)])
        [delegate browsingContextControllerDidCommitLoad:controller];
}

static void didFinishLoadForFrame(WKPageRef page, WKFrameRef frame, WKTypeRef, const void *clientInfo)
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

// MAVERICKS_BACKPORT: convert a +1 WKURLRef to an autoreleased NSURL, consuming the WKURLRef.
static NSURL *nsURLFromWKURLConsuming(WKURLRef wkURL)
{
    if (!wkURL)
        return nil;
    CFURLRef cfURL = WKURLCopyCFURL(kCFAllocatorDefault, wkURL); // +1
    WKRelease(wkURL);
    return cfURL ? [(NSURL *)cfURL autorelease] : nil;
}

// MAVERICKS_BACKPORT: convert a +1 WKStringRef to an autoreleased NSString, consuming the WKStringRef.
static NSString *nsStringFromWKStringConsuming(WKStringRef wkString)
{
    if (!wkString)
        return nil;
    CFStringRef cfString = WKStringCopyCFString(kCFAllocatorDefault, wkString); // +1
    WKRelease(wkString);
    return cfString ? [(NSString *)cfString autorelease] : nil;
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

// MAVERICKS_BACKPORT: installed once at controller creation (matching the original
// setUpPageLoaderClient called from -_initWithPageRef:); the callbacks read -loadDelegate
// dynamically, and an embedder that later sets its own loader client through
// WKPageSetPageLoaderClient replaces this one, as on stock (see -setLoadDelegate:).
static void installControllerPageLoaderClient(WKBrowsingContextController *controller, WKPageRef pageRef)
{
    WKPageLoaderClientV0 client;
    memset(&client, 0, sizeof(client));
    client.base.version = 0;
    client.base.clientInfo = (__bridge const void *)controller;
    client.didStartProvisionalLoadForFrame = didStartProvisionalLoadForFrame;
    client.didReceiveServerRedirectForProvisionalLoadForFrame = didReceiveServerRedirectForProvisionalLoadForFrame;
    client.didFailProvisionalLoadWithErrorForFrame = didFailProvisionalLoadWithErrorForFrame;
    client.didCommitLoadForFrame = didCommitLoadForFrame;
    client.didFinishLoadForFrame = didFinishLoadForFrame;
    client.didFailLoadWithErrorForFrame = didFailLoadWithErrorForFrame;
    WKPageSetPageLoaderClient(pageRef, &client.base);
}

- (instancetype)_initWithPageRef:(WKPageRef)pageRef
{
    self = [super init];
    if (!self)
        return nil;
    _pageRef = pageRef;
    if (_pageRef) {
        WKRetain(_pageRef);
        // MAVERICKS_BACKPORT (#137): register so a controller referenced in a WKConnection message body
        // (Mail keys its DidLayout/DidPaintContent and MessageContents by it) round-trips to this object.
        WKConnectionRegisterController(WebKit::toImpl(_pageRef)->identifier().toUInt64(), self);
        installControllerPageLoaderClient(self, _pageRef);
    }
    return self;
}

- (void)dealloc
{
    if (_pageRef) {
        // Drop the loader client first so its clientInfo (self) can't be used after we're
        // gone (installed unconditionally at -_initWithPageRef: time).
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
// MAVERICKS_BACKPORT: like the original controller, this ONLY stores the delegate — the page
// loader client is installed unconditionally at -_initWithPageRef: time (see
// installControllerPageLoaderClient) and its callbacks read the current delegate dynamically.
// Installing a client HERE instead would clobber whatever loader client the embedder set
// directly through WKPageSetPageLoaderClient in the meantime: a WKPage has one loader client,
// and iBooks installs its own (carrying the didLayout layout-milestone callbacks its chapter
// transitions wait on) after creating the view but before its worker calls -setLoadDelegate:
// from the process-group connection handler — with the original ordering iBooks' client wins,
// exactly as on stock.
- (void)setLoadDelegate:(id)loadDelegate
{
    _loadDelegate = loadDelegate;
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

// MAVERICKS_BACKPORT: Mail renders a message by loading its HTML as data (not a URL)
// through this — -[MUIWebDocumentView ...] calls it on the message-view controller.
// Without it Mail throws an unrecognized-selector exception and terminates after the
// message view is built. Route through the still-present WKPageLoadData* C SPI.
- (void)loadData:(NSData *)data MIMEType:(NSString *)MIMEType textEncodingName:(NSString *)encodingName baseURL:(NSURL *)baseURL userData:(id)userData
{
    if (!_pageRef || !data)
        return;
    WKDataRef wkData = WKDataCreate(static_cast<const unsigned char*>(data.bytes), data.length);
    WKStringRef wkMIMEType = MIMEType ? WKStringCreateWithCFString((__bridge CFStringRef)MIMEType) : nullptr;
    WKStringRef wkEncoding = encodingName ? WKStringCreateWithCFString((__bridge CFStringRef)encodingName) : nullptr;
    WKURLRef wkBaseURL = baseURL ? WKURLCreateWithCFURL((__bridge CFURLRef)baseURL) : nullptr;
    // MAVERICKS_BACKPORT (#142): Mail passes its document load context (which carries
    // MUIDocumentLoadContextKeyLoadRemoteContent and other per-load display flags) as userData; the
    // MailUIWebBundle reads it back in -willLoadDataRequest to decide whether to load images/remote
    // content. Dropping it left every (re)load with remote content blocked, so "Load Images" did
    // nothing. Serialize it to a WK object graph (the standard injected-bundle ObjC bridge re-wraps it
    // as an NSDictionary on the bundle side) and route through WKPageLoadDataWithUserData.
    WKTypeRef wkUserData = userData ? WKConnectionCreateSerializedBody(userData) : nullptr;
    WKPageLoadDataWithUserData(_pageRef, wkData, wkMIMEType, wkEncoding, wkBaseURL, wkUserData);
    WKRelease(wkData);
    if (wkMIMEType)
        WKRelease(wkMIMEType);
    if (wkEncoding)
        WKRelease(wkEncoding);
    if (wkBaseURL)
        WKRelease(wkBaseURL);
    if (wkUserData)
        WKRelease(wkUserData);
}

// MAVERICKS_BACKPORT: Mail also drives stop/zoom on the message-view controller
// (wkView.browsingContextController.pageZoom / stopLoading).
- (void)stopLoading
{
    if (_pageRef)
        WKPageStopLoading(_pageRef);
}

- (CGFloat)pageZoom
{
    return _pageRef ? WKPageGetPageZoomFactor(_pageRef) : 1;
}

- (void)setPageZoom:(CGFloat)pageZoom
{
    if (_pageRef)
        WKPageSetPageZoomFactor(_pageRef, pageZoom);
}

// MAVERICKS_BACKPORT: pagination SPI, restored from the original WKBrowsingContextController(Private).
// iBooks' BKAssetEpub lays a book out as columns by sending -setPaginationMode:/-setPaginationBehavesLikeColumns:/
// -setPageLength:/-setGapBetweenPages: on the controller and reading back -pageCount to drive its page turner.
// Our restored controller only had the loader/URL API, so these were unrecognized selectors: -setPaginationMode:
// logged an NSInvalidArgumentException (iBooks catches it) and the book never paginated — it opened stuck on the
// cover with page turns dead. Route through the still-present WKPageSet/Get pagination C SPI on the wrapped page,
// exactly as the original controller did.
- (WKBrowsingContextPaginationMode)paginationMode
{
    return _pageRef ? (WKBrowsingContextPaginationMode)WKPageGetPaginationMode(_pageRef) : WKPaginationModeUnpaginated;
}

- (void)setPaginationMode:(WKBrowsingContextPaginationMode)paginationMode
{
    if (_pageRef)
        WKPageSetPaginationMode(_pageRef, (WKPaginationMode)paginationMode);
}

- (BOOL)paginationBehavesLikeColumns
{
    return _pageRef ? WKPageGetPaginationBehavesLikeColumns(_pageRef) : NO;
}

- (void)setPaginationBehavesLikeColumns:(BOOL)behavesLikeColumns
{
    if (_pageRef)
        WKPageSetPaginationBehavesLikeColumns(_pageRef, behavesLikeColumns);
}

- (CGFloat)pageLength
{
    return _pageRef ? WKPageGetPageLength(_pageRef) : 0;
}

- (void)setPageLength:(CGFloat)pageLength
{
    if (_pageRef)
        WKPageSetPageLength(_pageRef, pageLength);
}

- (CGFloat)gapBetweenPages
{
    return _pageRef ? WKPageGetGapBetweenPages(_pageRef) : 0;
}

- (void)setGapBetweenPages:(CGFloat)gapBetweenPages
{
    if (_pageRef)
        WKPageSetGapBetweenPages(_pageRef, gapBetweenPages);
}

- (NSUInteger)pageCount
{
    return _pageRef ? WKPageGetPageCount(_pageRef) : 0;
}

// MAVERICKS_BACKPORT: text-zoom SPI, restored from the original WKBrowsingContextController(Private).
// iBooks sends -setTextZoom: to scale the book's font size independently of page zoom; without it the
// send is an unrecognized selector (iBooks catches it, but the reader's font-size control no-ops).
- (CGFloat)textZoom
{
    return _pageRef ? WKPageGetTextZoomFactor(_pageRef) : 1;
}

- (void)setTextZoom:(CGFloat)textZoom
{
    if (_pageRef)
        WKPageSetTextZoomFactor(_pageRef, textZoom);
}

// MAVERICKS_BACKPORT (#137): Mail's load-delegate handlers (browsingContextControllerDidStartProvisionalLoad:
// / DidCommitLoad: etc.) read back the controller's current URL/title to update the message-view chrome.
// These read-only accessors were part of the original WKBrowsingContextController SPI Mail compiled
// against; without them Mail throws -[WKBrowsingContextController activeURL]: unrecognized selector and
// terminates the moment the message body actually starts loading. Route through the still-present
// WKPageCopy*/WKPageGet* C SPI on the wrapped page.
- (NSURL *)activeURL
{
    return _pageRef ? nsURLFromWKURLConsuming(WKPageCopyActiveURL(_pageRef)) : nil;
}

- (NSURL *)provisionalURL
{
    return _pageRef ? nsURLFromWKURLConsuming(WKPageCopyProvisionalURL(_pageRef)) : nil;
}

- (NSURL *)committedURL
{
    return _pageRef ? nsURLFromWKURLConsuming(WKPageCopyCommittedURL(_pageRef)) : nil;
}

- (NSString *)title
{
    return _pageRef ? nsStringFromWKStringConsuming(WKPageCopyTitle(_pageRef)) : nil;
}

- (double)estimatedProgress
{
    return _pageRef ? WKPageGetEstimatedProgress(_pageRef) : 0;
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
