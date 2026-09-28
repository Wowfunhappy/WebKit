#import "config.h"
#import "WebLegacyExtensionPageObserver.h"

#import "WebFrameInternal.h"
#import "WebPreferenceKeysPrivate.h"
#import <JavaScriptCore/APICast.h>
#import <WebCore/DOMWrapperWorld.h>
#import <WebCore/Document.h>
#import <WebCore/JSDOMWindow.h>
#import <WebCore/LocalFrameInlines.h>
#import <WebCore/ScriptController.h>

static const WebLegacyExtensionPageObserver* observer;

// Safari 7 keeps its extension views' preferences under these identifiers: the global page, popovers and
// extension bars. As extension pages, they have the async clipboard API a WebKit 2 view has by default.
static void registerExtensionViewPreferenceDefaults()
{
    NSMutableDictionary *defaults = [NSMutableDictionary dictionary];
    for (NSString *identifier in @[ @"ExtensionGlobalPage", @"ExtensionPopover", @"ExtensionBar" ])
        defaults[[identifier stringByAppendingString:WebKitAsyncClipboardAPIEnabledPreferenceKey]] = @YES;
    [[NSUserDefaults standardUserDefaults] registerDefaults:defaults];
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
