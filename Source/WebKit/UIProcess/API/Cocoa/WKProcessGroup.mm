/*
 * Copyright (C) 2013 Apple Inc. All rights reserved.
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

// MAVERICKS_BACKPORT: minimal restoration of the legacy WebKit2 ObjC WKProcessGroup,
// removed upstream. QuickLook's Web2.qldisplay creates one to back its WKView.
// We wrap a WKContextRef (WebProcessPool) created through the still-present C
// SPI; WKView pulls it back out via -_contextRef (WKProcessGroupInternal.h).

#import "config.h"
#import "WKProcessGroupInternal.h"

#import "WKAPICast.h"
#import "WKConnectionInternal.h"
#import "WKContext.h"
#import "WKContextInjectedBundleClient.h"
#import "WKData.h"
#import "WKString.h"
#import "WKStringCF.h"
#import "WKType.h"
// MAVERICKS_BACKPORT: the pool's web-process-launch observer drives the legacy
// didCreateConnection delegate callback (see -_webProcessDidFinishLaunching).
#import "WebProcessPool.h"
#import <wtf/RetainPtr.h>

@interface WKProcessGroup ()
- (void)_webProcessDidFinishLaunching;
@end

@implementation WKProcessGroup {
    WKContextRef _context;
    id <WKProcessGroupDelegate> _delegate; // assign: Mail owns the process group and outlives it.
    WKConnection *_connection;             // app-side end of the bundle<->app channel.
    BOOL _bundleConnectionEstablished;     // MAVERICKS_BACKPORT: a web process (and thus its injected bundle) has launched for this context.
}

// MAVERICKS_BACKPORT (#137): bundle->app messages (MailUIWebBundle -> Mail.app, e.g.
// MUIMessageKeyWebProcessDidLayoutContent) arrive here and are dispatched to the WKConnection delegate.
static void didReceiveMessageFromInjectedBundle(WKContextRef, WKStringRef messageName, WKTypeRef messageBody, const void* clientInfo)
{
    WKProcessGroup *processGroup = (__bridge WKProcessGroup *)clientInfo;
    WKConnection *connection = processGroup->_connection;
    RetainPtr<CFStringRef> cfName = adoptCF(WKStringCopyCFString(kCFAllocatorDefault, messageName));
    if (!connection)
        return;
    [connection _dispatchDidReceiveMessageWithName:(__bridge NSString *)cfName.get() serializedBody:messageBody];
}

// MAVERICKS_BACKPORT: asked once per web-process launch while the process's creation parameters
// are assembled. The original WKProcessGroup forwarded this to the delegate's
// -processGroupWillCreateConnectionToWebProcessPlugIn: and shipped the returned object graph to
// the injected bundle, which receives it as -webProcessPlugIn:initializeWithObject:'s object.
// iBooks' BKDocumentWorker returns its pluginInitializationDictionaryForBook: dictionary here
// (bookContentsPath, sinf/resource data, sandbox-extension tokens, pagination mode); without it
// the bundle's BKURLProtocol has no book info and throws on the first load's policy check.
// ObjCObjectGraph was removed upstream, so the graph travels NSKeyedArchiver-coded in a WKData
// (same transport as WKConnection message bodies); InjectedBundleMac decodes it.
static WKTypeRef getInjectedBundleInitializationUserData(WKContextRef, const void* clientInfo)
{
    WKProcessGroup *processGroup = (__bridge WKProcessGroup *)clientInfo;
    id <WKProcessGroupDelegate> delegate = processGroup->_delegate;
    if (![delegate respondsToSelector:@selector(processGroupWillCreateConnectionToWebProcessPlugIn:)])
        return nullptr;

    id userData = [delegate processGroupWillCreateConnectionToWebProcessPlugIn:processGroup];
    if (!userData)
        return nullptr;

    // NOTE: unlike the removed ObjCObjectGraph, this transport carries plist-style object
    // graphs only (NSKeyedArchiver-codable classes) — it cannot carry WebKit wrapper objects
    // such as WKBrowsingContextHandle. iBooks' dictionary (strings, numbers, NSData arrays)
    // is within that; an embedder handing back anything else must fail LOUDLY here, not get
    // silently degraded to nil user data (which surfaces as an undebuggable bundle-side hang).
    NSError *archiveError = nil;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:userData requiringSecureCoding:NO error:&archiveError];
    if (!data) {
        NSLog(@"WKProcessGroup: FAILED to archive the injected-bundle initialization user data (%@) — the bundle's plug-in will be initialized with a nil object. The archiver transport carries NSKeyedArchiver-codable graphs only.", archiveError);
        return nullptr;
    }
    return WKDataCreate(static_cast<const unsigned char*>(data.bytes), data.length);
}

- (instancetype)init
{
    return [self initWithInjectedBundleURL:nil];
}

- (instancetype)initWithInjectedBundleURL:(NSURL *)bundleURL
{
    self = [super init];
    if (!self)
        return nil;

    if (bundleURL) {
        WKStringRef path = WKStringCreateWithCFString((__bridge CFStringRef)[bundleURL path]);
        _context = WKContextCreateWithInjectedBundlePath(path);
        WKRelease(path);
    } else
        _context = WKContextCreate();

    // Route bundle->app messages and supply the per-launch bundle initialization user data.
    // Installed here (not when the delegate is set) so getInjectedBundleInitializationUserData
    // is in place before the first web process launches.
    WKContextInjectedBundleClientV1 injectedBundleClient;
    memset(&injectedBundleClient, 0, sizeof(injectedBundleClient));
    injectedBundleClient.base.version = 1;
    injectedBundleClient.base.clientInfo = (__bridge void*)self;
    injectedBundleClient.didReceiveMessageFromInjectedBundle = didReceiveMessageFromInjectedBundle;
    injectedBundleClient.getInjectedBundleInitializationUserData = getInjectedBundleInitializationUserData;
    WKContextSetInjectedBundleClient(_context, &injectedBundleClient.base);

    // MAVERICKS_BACKPORT: in real WebKit2 the WKContextConnectionClient's didCreateConnection —
    // the callback behind -processGroup:didCreateConnectionToWebProcessPlugIn: — fired when a
    // web process of this context launched and its injected bundle connected back to the UI
    // process. Observe launches through the pool so the delegate callback keeps that timing
    // (see -_webProcessDidFinishLaunching). `self` is unretained; the handler is cleared in
    // -dealloc before the context is released.
    WKProcessGroup *unretainedSelf = self;
    WebKit::toImpl(_context)->setWebProcessDidFinishLaunchingHandler([unretainedSelf] {
        [unretainedSelf _webProcessDidFinishLaunching];
    });

    return self;
}

- (void)dealloc
{
    if (_context) {
        // MAVERICKS_BACKPORT: drop the pool's unretained reference to self before releasing the
        // context (the pool can outlive this wrapper if something else retains it).
        WebKit::toImpl(_context)->setWebProcessDidFinishLaunchingHandler(nullptr);
        WKContextSetInjectedBundleClient(_context, nullptr);
        WKRelease(_context);
    }
    [_connection _dispatchDidClose];
    [_connection release];
    [super dealloc];
}

- (id <WKProcessGroupDelegate>)delegate
{
    return _delegate;
}

// Create the app-side WKConnection (sends to the injected bundle); Mail and iBooks set
// themselves as the connection's delegate once it is handed over in
// -processGroup:didCreateConnectionToWebProcessPlugIn:.
- (void)_ensureConnection
{
    if (_connection)
        return;

    WKContextRef context = _context;
    _connection = [[WKConnection alloc] initWithSender:^(NSString *messageName, WKTypeRef serializedBody) {
        WKStringRef wkName = WKStringCreateWithCFString((__bridge CFStringRef)messageName);
        WKContextPostMessageToInjectedBundle(context, wkName, serializedBody);
        WKRelease(wkName);
    }];
}

- (void)_deliverConnectionToDelegate
{
    id <WKProcessGroupDelegate> delegate = _delegate;
    if (!delegate || ![delegate respondsToSelector:@selector(processGroup:didCreateConnectionToWebProcessPlugIn:)])
        return;
    [self _ensureConnection];
    [delegate processGroup:self didCreateConnectionToWebProcessPlugIn:_connection];
}

// MAVERICKS_BACKPORT: fired (on the main thread) whenever a web process of this context finishes
// launching — the point where real WebKit2 fired the WKContextConnectionClient's
// didCreateConnection. Embedders sequence their bundle messaging on this callback: iBooks'
// BKDocumentWorker sends BKEpubWebProcessPlugInMessageUpdateBookInfo from its handler before it
// loads any book resource, so the bundle-side BKURLProtocol knows the book's contents path by the
// time the first load's policy check calls +canInitWithRequest: (with no book info it throws on
// [path hasPrefix:nil] and the web process dies). Delivery is deferred one turn: the pool is in
// the middle of processDidFinishLaunching bookkeeping, and the handler may reenter WebKit
// (set page clients, post messages, start loads). Firing per launch also matches the original
// per-web-process semantics — a relaunch after a web process crash re-notifies the delegate,
// which re-sends its bundle state, exactly as on stock.
- (void)_webProcessDidFinishLaunching
{
    _bundleConnectionEstablished = YES;
    [self retain];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _deliverConnectionToDelegate];
        [self release];
    });
}

- (void)setDelegate:(id <WKProcessGroupDelegate>)delegate
{
    _delegate = delegate;

    if (!delegate || !_context)
        return;

    [self _ensureConnection];

    // MAVERICKS_BACKPORT: a delegate installed after the bundle connection already exists would
    // otherwise never hear about it (didCreateConnection fires at web-process launch, above).
    // iBooks reuses one process group across documents and swaps a fresh BKDocumentWorker in as
    // the delegate for each; each worker needs the connection to send its book info. Deliver on
    // the next turn so the caller's synchronous setup finishes first, and only if this delegate
    // is still current by then (a newer -setDelegate: schedules its own delivery).
    if (!_bundleConnectionEstablished)
        return;
    [self retain];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (_delegate == delegate)
            [self _deliverConnectionToDelegate];
        [self release];
    });
}

- (WKContextRef)_contextRef
{
    return _context;
}

@end
