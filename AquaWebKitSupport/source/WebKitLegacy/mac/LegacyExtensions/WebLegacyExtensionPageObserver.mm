#import "config.h"
#import "WebLegacyExtensionPageObserver.h"

#import "WebFrameInternal.h"
#import "WebPreferenceKeysPrivate.h"
#import <JavaScriptCore/APICast.h>
#import <WebCore/BroadcastChannelRegistry.h>
#import <WebCore/DOMWrapperWorld.h>
#import <WebCore/Document.h>
#import <WebCore/JSDOMWindow.h>
#import <WebCore/LocalFrameInlines.h>
#import <WebCore/ScriptController.h>
#import <wtf/NeverDestroyed.h>

static const WebLegacyExtensionPageObserver* observer;

// The preference identifiers of the extension views: Safari 7's global page, popovers and extension bars, and
// the router's devtools pages (LegacyExtensionDevTools). As extension pages, they have the async clipboard API,
// BroadcastChannel, SharedWorker and Web Locks a WebKit 2 view has by default, and write the clipboard whenever
// they ask, as a WebExtension's pages with clipboardWrite do.
static void registerExtensionViewPreferenceDefaults()
{
    NSMutableDictionary *defaults = [NSMutableDictionary dictionary];
    for (NSString *identifier in @[ @"ExtensionGlobalPage", @"ExtensionPopover", @"ExtensionBar", @"ExtensionDevToolsPage" ]) {
        defaults[[identifier stringByAppendingString:WebKitAsyncClipboardAPIEnabledPreferenceKey]] = @YES;
        defaults[[identifier stringByAppendingString:WebKitJavaScriptCanAccessClipboardPreferenceKey]] = @YES;
        defaults[[identifier stringByAppendingString:@"WebKitBroadcastChannelEnabled"]] = @YES;
        defaults[[identifier stringByAppendingString:@"WebKitSharedWorkerEnabled"]] = @YES;
        defaults[[identifier stringByAppendingString:@"WebKitWebLocksAPIEnabled"]] = @YES;
    }
    [[NSUserDefaults standardUserDefaults] registerDefaults:defaults];
}

static RefPtr<WebCore::BroadcastChannelRegistry>& broadcastChannelRegistry()
{
    static NeverDestroyed<RefPtr<WebCore::BroadcastChannelRegistry>> registry;
    return registry;
}

void WebSetLegacyExtensionBroadcastChannelRegistry(WebCore::BroadcastChannelRegistry& registry)
{
    broadcastChannelRegistry() = &registry;
}

WebCore::BroadcastChannelRegistry* WebLegacyExtensionBroadcastChannelRegistry()
{
    return broadcastChannelRegistry().get();
}

void WebSetLegacyExtensionPageObserver(const WebLegacyExtensionPageObserver* newObserver)
{
    if (newObserver && !observer)
        registerExtensionViewPreferenceDefaults();
    observer = newObserver;
}

void WebLegacyExtensionPageObserverDidClearWindowObject(WebFrame *webFrame)
{
    if (!observer)
        return;
    RefPtr frame = core(webFrame);
    if (!frame)
        return;
    RefPtr document = frame->document();
    if (!document)
        return;
    auto* globalObject = frame->script().globalObject(WebCore::mainThreadNormalWorldSingleton());
    observer->didClearWindowObject((__bridge const void*)webFrame, toGlobalRef(globalObject), document->url().createCFURL().get());
}

void WebLegacyExtensionPageObserverFrameWillBeDestroyed(WebFrame *webFrame)
{
    if (observer)
        observer->frameWillBeDestroyed((__bridge const void*)webFrame);
}
