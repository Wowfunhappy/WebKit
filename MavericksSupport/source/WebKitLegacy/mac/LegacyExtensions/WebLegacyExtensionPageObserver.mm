#import "config.h"
#import "WebLegacyExtensionPageObserver.h"

#import "WebFrameInternal.h"
#import <JavaScriptCore/APICast.h>
#import <WebCore/DOMWrapperWorld.h>
#import <WebCore/Document.h>
#import <WebCore/JSDOMWindow.h>
#import <WebCore/LocalFrameInlines.h>
#import <WebCore/ScriptController.h>

static const WebLegacyExtensionPageObserver* observer;

void WebSetLegacyExtensionPageObserver(const WebLegacyExtensionPageObserver* newObserver)
{
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
