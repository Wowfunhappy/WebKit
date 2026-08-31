/*
 * Copyright (C) 2012-2018 Apple Inc. All rights reserved.
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
#import "WKWebProcessPlugInInternal.h"

#import "APIArray.h"
#import "WKBundle.h"
#import "WKBundleAPICast.h"
// MAVERICKS_BACKPORT (#137): legacy WKConnection used for the bundle<->app message channel below.
#import "WKConnectionInternal.h"
#import "WKRetainPtr.h"
#import "WKStringCF.h"
#import "WKWebProcessPlugInBrowserContextControllerInternal.h"
// MAVERICKS_BACKPORT (#137): WebPage for webPageProxyIdentifier() used in WKConnection controller registration below.
#import "WebPage.h"
#import <WebCore/WebCoreObjCExtras.h>
#import <wtf/AlignedStorage.h>
#import <wtf/RetainPtr.h>
#import <wtf/StdLibExtras.h>

// MAVERICKS_BACKPORT (#137): private accessor for the legacy WKConnection (defined below).
@interface WKWebProcessPlugInController ()
- (WKConnection *)connection;
@end

@implementation WKWebProcessPlugInController {
    AlignedStorage<WebKit::InjectedBundle> _bundle;
    RetainPtr<id <WKWebProcessPlugIn>> _principalClassInstance;
    // MAVERICKS_BACKPORT (#137): lazily-created legacy WKConnection backing the bundle<->app message channel.
    RetainPtr<WKConnection> _connection;
}

- (void)dealloc
{
    if (WebCoreObjCScheduleDeallocateOnMainRunLoop(WKWebProcessPlugInController.class, self))
        return;

    SUPPRESS_UNCOUNTED_ARG _bundle->~InjectedBundle();

    [super dealloc];
}

static void didCreatePage(WKBundleRef bundle, WKBundlePageRef page, const void* clientInfo)
{
    auto plugInController = (__bridge WKWebProcessPlugInController *)clientInfo;
    RetainPtr principalClassInstance = plugInController->_principalClassInstance.get();

    RefPtr webPage = WebKit::toImpl(page);
    RetainPtr<WKWebProcessPlugInBrowserContextController> controller = protect(wrapper(*webPage));
    // MAVERICKS_BACKPORT (#137): register so this controller round-trips through WKConnection bodies.
    WKConnectionRegisterController(webPage->webPageProxyIdentifier().toUInt64(), controller.get());

    if ([principalClassInstance respondsToSelector:@selector(webProcessPlugIn:didCreateBrowserContextController:)])
        // MAVERICKS_BACKPORT (#137): hand the WKConnection-registered controller (above) to the plug-in.
        [principalClassInstance webProcessPlugIn:plugInController didCreateBrowserContextController:controller.get()];
}

static void willDestroyPage(WKBundleRef bundle, WKBundlePageRef page, const void* clientInfo)
{
    auto plugInController = (__bridge WKWebProcessPlugInController *)clientInfo;
    RetainPtr principalClassInstance = plugInController->_principalClassInstance.get();

    if ([principalClassInstance respondsToSelector:@selector(webProcessPlugIn:willDestroyBrowserContextController:)])
        [principalClassInstance webProcessPlugIn:plugInController willDestroyBrowserContextController:protect(wrapper(*protect(WebKit::toImpl(page)))).get()];
}

// MAVERICKS_BACKPORT (#137): deliver UIProcess->bundle messages (Mail.app -> MailUIWebBundle, e.g.
// MUIMessageKeyMessageContents) to the legacy WKConnection's delegate.
static void didReceiveMessage(WKBundleRef, WKStringRef messageName, WKTypeRef messageBody, const void* clientInfo)
{
    auto plugInController = (__bridge WKWebProcessPlugInController *)clientInfo;
    WKConnection *connection = [plugInController connection];
    RetainPtr<CFStringRef> cfName = adoptCF(WKStringCopyCFString(kCFAllocatorDefault, messageName));
    [connection _dispatchDidReceiveMessageWithName:(__bridge NSString *)cfName.get() serializedBody:messageBody];
}

static void setUpBundleClient(WKWebProcessPlugInController *plugInController, WebKit::InjectedBundle& bundle)
{
    WKBundleClientV1 bundleClient;
    zeroBytes(bundleClient);

    bundleClient.base.version = 1;
    bundleClient.base.clientInfo = (__bridge void*)plugInController;
    bundleClient.didCreatePage = didCreatePage;
    bundleClient.willDestroyPage = willDestroyPage;
    // MAVERICKS_BACKPORT (#137): route UIProcess->bundle messages to the legacy WKConnection delegate.
    bundleClient.didReceiveMessage = didReceiveMessage;

    WKBundleSetClient(toAPI(&bundle), &bundleClient.base);
}

- (void)_setPrincipalClassInstance:(id <WKWebProcessPlugIn>)principalClassInstance
{
    ASSERT(!_principalClassInstance);
    _principalClassInstance = principalClassInstance;

    setUpBundleClient(self, protect(*_bundle));
}

- (id)parameters
{
    return protect(*_bundle)->bundleParameters();
}

// MAVERICKS_BACKPORT (#137): the legacy WKConnection bundle->app message channel. Mail's MailUIWebBundle
// gets this, sets itself as the connection delegate, and posts MUIMessageKeyWebProcessDid{Layout,Paint}
// Content to Mail.app (which sizes/reveals the message body); Mail.app posts MUIMessageKeyMessageContents
// /MessageObject back. We back it with the still-present WKBundlePostMessage IPC (UIProcess side is wired
// in WKProcessGroup); bodies are NSKeyedArchiver-coded into a WKData.
- (WKConnection *)connection
{
    if (!_connection) {
        WKBundleRef bundleRef = toAPI(&*_bundle);
        _connection = adoptNS([[WKConnection alloc] initWithSender:^(NSString *messageName, WKTypeRef serializedBody) {
            WKStringRef wkName = WKStringCreateWithCFString((__bridge CFStringRef)messageName);
            WKBundlePostMessage(bundleRef, wkName, serializedBody);
            WKRelease(wkName);
        }]);
    }
    return _connection.get();
}

static Ref<API::Array> createWKArray(NSArray *array)
{
    NSUInteger count = [array count];
    Vector<RefPtr<API::Object>> strings;
    strings.reserveInitialCapacity(count);
    
    for (id entry in array) {
        if ([entry isKindOfClass:[NSString class]])
            strings.append(adoptRef(WebKit::toImpl(WKStringCreateWithCFString((__bridge CFStringRef)entry))));
    }
    
    return API::Array::create(WTF::move(strings));
}

- (void)extendClassesForParameterCoder:(NSArray *)classes
{
    auto classList = createWKArray(classes);
    protect(*_bundle)->extendClassesForParameterCoder(classList.get());
}

#pragma mark WKObject protocol implementation

- (API::Object&)_apiObject
{
    return *_bundle;
}

@end

@implementation WKWebProcessPlugInController (Private)

- (WKBundleRef)_bundleRef
{
    return toAPI(protect(*_bundle).ptr());
}

@end
