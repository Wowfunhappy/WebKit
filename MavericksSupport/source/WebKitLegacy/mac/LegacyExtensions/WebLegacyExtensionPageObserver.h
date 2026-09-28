// WebKit 1 hands the WebKit 2 UI-process router every main-world JavaScript global object it creates, so
// the router can give Safari 7 extension pages (the global page and toolbar popovers, which Safari hosts
// in WebKit 1 views) their `browser` namespace. Setting an observer also gives those views the async
// clipboard API.

#pragma once

#include <CoreFoundation/CoreFoundation.h>
#include <JavaScriptCore/JSBase.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    // `frame` identifies a WebFrame for as long as frameWillBeDestroyed has not been called for it.
    void (*didClearWindowObject)(const void* frame, JSGlobalContextRef, CFURLRef documentURL);
    void (*frameWillBeDestroyed)(const void* frame);
} WebLegacyExtensionPageObserver;

__attribute__((visibility("default"))) void WebSetLegacyExtensionPageObserver(const WebLegacyExtensionPageObserver*);

#ifdef __cplusplus
}
#endif

#ifdef __OBJC__
@class WebFrame;

void WebLegacyExtensionPageObserverDidClearWindowObject(WebFrame *);
void WebLegacyExtensionPageObserverFrameWillBeDestroyed(WebFrame *);
#endif
