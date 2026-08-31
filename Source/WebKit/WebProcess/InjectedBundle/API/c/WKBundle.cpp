/*
 * Copyright (C) 2010-2016 Apple Inc. All rights reserved.
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

#include "config.h"
#include "WKBundle.h"

#include "APIArray.h"
#include "APIData.h"
#include "InjectedBundle.h"
#include "InjectedBundleClient.h"
#include "InjectedBundleScriptWorld.h"
#include "WKAPICast.h"
#include "WKBundleAPICast.h"
#include "WKBundlePrivate.h"
#include "WKData.h"
#include "WKMutableArray.h"
#include "WKMutableDictionary.h"
#include "WKNumber.h"
#include "WKRetainPtr.h"
#include "WKString.h"
#include "WebFrame.h"
#include "WebPage.h"
#include "WebPageGroupProxy.h"
#include "WebUserContentController.h" // MAVERICKS_BACKPORT: page-group user content C API below.
#include <WebCore/DatabaseTracker.h>
// MAVERICKS_BACKPORT: UserScript/UserStyleSheet types for the restored legacy page-group user-content C API (below).
#include <WebCore/UserScript.h>
#include <WebCore/UserStyleSheet.h>
#include <WebCore/MemoryRelease.h>
#include <WebCore/ResourceLoadObserver.h>
#include <WebCore/ServiceWorkerThreadProxy.h>

WKTypeID WKBundleGetTypeID()
{
    return WebKit::toAPI(WebKit::InjectedBundle::APIType);
}

void WKBundleSetClient(WKBundleRef bundleRef, WKBundleClientBase *wkClient)
{
    protect(WebKit::toImpl(bundleRef))->setClient(makeUnique<WebKit::InjectedBundleClient>(wkClient));
}

void WKBundleSetServiceWorkerProxyCreationCallback(WKBundleRef bundleRef, void (*callback)(uint64_t))
{
    protect(WebKit::toImpl(bundleRef))->setServiceWorkerProxyCreationCallback(callback);
}

void WKBundlePostMessage(WKBundleRef bundleRef, WKStringRef messageNameRef, WKTypeRef messageBodyRef)
{
    protect(WebKit::toImpl(bundleRef))->postMessage(WebKit::toWTFString(messageNameRef), protect(WebKit::toImpl(messageBodyRef)).get());
}

void WKBundlePostSynchronousMessage(WKBundleRef bundleRef, WKStringRef messageNameRef, WKTypeRef messageBodyRef, WKTypeRef* returnRetainedDataRef)
{
    RefPtr<API::Object> returnData;
    protect(WebKit::toImpl(bundleRef))->postSynchronousMessage(WebKit::toWTFString(messageNameRef), protect(WebKit::toImpl(messageBodyRef)).get(), returnData);
    if (returnRetainedDataRef)
        *returnRetainedDataRef = WebKit::toAPILeakingRef(WTF::move(returnData));
}

void WKBundleGarbageCollectJavaScriptObjects(WKBundleRef bundleRef)
{
    protect(WebKit::toImpl(bundleRef))->garbageCollectJavaScriptObjects();
}

void WKBundleGarbageCollectJavaScriptObjectsOnAlternateThreadForDebugging(WKBundleRef bundleRef, bool waitUntilDone)
{
    protect(WebKit::toImpl(bundleRef))->garbageCollectJavaScriptObjectsOnAlternateThreadForDebugging(waitUntilDone);
}

size_t WKBundleGetJavaScriptObjectsCount(WKBundleRef bundleRef)
{
    return protect(WebKit::toImpl(bundleRef))->javaScriptObjectsCount();
}

void WKBundleAddOriginAccessAllowListEntry(WKBundleRef bundleRef, WKStringRef sourceOrigin, WKStringRef destinationProtocol, WKStringRef destinationHost, bool allowDestinationSubdomains)
{
    protect(WebKit::toImpl(bundleRef))->addOriginAccessAllowListEntry(WebKit::toWTFString(sourceOrigin), WebKit::toWTFString(destinationProtocol), WebKit::toWTFString(destinationHost), allowDestinationSubdomains);
}

void WKBundleRemoveOriginAccessAllowListEntry(WKBundleRef bundleRef, WKStringRef sourceOrigin, WKStringRef destinationProtocol, WKStringRef destinationHost, bool allowDestinationSubdomains)
{
    protect(WebKit::toImpl(bundleRef))->removeOriginAccessAllowListEntry(WebKit::toWTFString(sourceOrigin), WebKit::toWTFString(destinationProtocol), WebKit::toWTFString(destinationHost), allowDestinationSubdomains);
}

void WKBundleResetOriginAccessAllowLists(WKBundleRef bundleRef)
{
    protect(WebKit::toImpl(bundleRef))->resetOriginAccessAllowLists();
}

// MAVERICKS_BACKPORT: legacy page-group user content C API, used by Safari 7's
// injected bundle to install extension content scripts and style sheets.
// Restored from upstream e05340a^ (InjectedBundle::addUserScript and friends):
// the content goes into the user content controller the page group's pages
// share, so each script is registered once per page group.
// Also restored: the OriginAccessWhitelist spellings (renamed AllowList
// upstream) Safari calls for extension cross-origin access.

// Signatures match Safari 7's WebKit (confirmed from Safari's call site:
// Safari::WK::Bundle::addUserScript(BundlePageGroup, BundleScriptWorld,
// String, URL, Array, Array, injectionTime, injectedFrames)) — note the
// script world parameter, which Safari creates with
// WKBundleScriptWorldCreateWorld for extension content scripts.
extern "C" {
WK_EXPORT void WKBundleAddUserScript(WKBundleRef, WKBundlePageGroupRef, WKBundleScriptWorldRef, WKStringRef, WKURLRef, WKArrayRef, WKArrayRef, _WKUserScriptInjectionTime, WKUserContentInjectedFrames);
WK_EXPORT void WKBundleAddUserStyleSheet(WKBundleRef, WKBundlePageGroupRef, WKBundleScriptWorldRef, WKStringRef, WKURLRef, WKArrayRef, WKArrayRef, WKUserContentInjectedFrames);
WK_EXPORT void WKBundleRemoveUserScript(WKBundleRef, WKBundlePageGroupRef, WKBundleScriptWorldRef, WKURLRef);
WK_EXPORT void WKBundleRemoveUserScripts(WKBundleRef, WKBundlePageGroupRef, WKBundleScriptWorldRef);
WK_EXPORT void WKBundleRemoveUserStyleSheet(WKBundleRef, WKBundlePageGroupRef, WKBundleScriptWorldRef, WKURLRef);
WK_EXPORT void WKBundleRemoveUserStyleSheets(WKBundleRef, WKBundlePageGroupRef, WKBundleScriptWorldRef);
WK_EXPORT void WKBundleRemoveAllUserContent(WKBundleRef, WKBundlePageGroupRef);
WK_EXPORT void WKBundleAddOriginAccessWhitelistEntry(WKBundleRef, WKStringRef, WKStringRef, WKStringRef, bool);
WK_EXPORT void WKBundleRemoveOriginAccessWhitelistEntry(WKBundleRef, WKStringRef, WKStringRef, WKStringRef, bool);
}

void WKBundleAddUserScript(WKBundleRef, WKBundlePageGroupRef pageGroupRef, WKBundleScriptWorldRef scriptWorldRef, WKStringRef sourceRef, WKURLRef urlRef, WKArrayRef allowListRef, WKArrayRef blockListRef, _WKUserScriptInjectionTime injectionTime, WKUserContentInjectedFrames injectedFrames)
{
    auto* allowList = WebKit::toImpl(allowListRef);
    auto* blockList = WebKit::toImpl(blockListRef);
    WebCore::UserScript userScript {
        WebKit::toWTFString(sourceRef),
        URL { WebKit::toWTFString(urlRef) },
        allowList ? allowList->toStringVector() : Vector<String>(),
        blockList ? blockList->toStringVector() : Vector<String>(),
        WebKit::toUserScriptInjectionTime(injectionTime),
        WebKit::toUserContentInjectedFrames(injectedFrames)
    };
    WebKit::toImpl(pageGroupRef)->userContentController().addUserScript(*WebKit::toImpl(scriptWorldRef), WTF::move(userScript));
}

void WKBundleAddUserStyleSheet(WKBundleRef, WKBundlePageGroupRef pageGroupRef, WKBundleScriptWorldRef scriptWorldRef, WKStringRef sourceRef, WKURLRef urlRef, WKArrayRef allowListRef, WKArrayRef blockListRef, WKUserContentInjectedFrames injectedFrames)
{
    auto* allowList = WebKit::toImpl(allowListRef);
    auto* blockList = WebKit::toImpl(blockListRef);
    WebCore::UserStyleSheet userStyleSheet {
        WebKit::toWTFString(sourceRef),
        URL { WebKit::toWTFString(urlRef) },
        allowList ? allowList->toStringVector() : Vector<String>(),
        blockList ? blockList->toStringVector() : Vector<String>(),
        WebKit::toUserContentInjectedFrames(injectedFrames)
    };
    WebKit::toImpl(pageGroupRef)->userContentController().addUserStyleSheet(*WebKit::toImpl(scriptWorldRef), WTF::move(userStyleSheet));
}

void WKBundleRemoveUserScript(WKBundleRef, WKBundlePageGroupRef pageGroupRef, WKBundleScriptWorldRef scriptWorldRef, WKURLRef urlRef)
{
    WebKit::toImpl(pageGroupRef)->userContentController().removeUserScriptWithURL(*WebKit::toImpl(scriptWorldRef), URL { WebKit::toWTFString(urlRef) });
}

void WKBundleRemoveUserScripts(WKBundleRef, WKBundlePageGroupRef pageGroupRef, WKBundleScriptWorldRef scriptWorldRef)
{
    WebKit::toImpl(pageGroupRef)->userContentController().removeUserScripts(*WebKit::toImpl(scriptWorldRef));
}

void WKBundleRemoveUserStyleSheet(WKBundleRef, WKBundlePageGroupRef pageGroupRef, WKBundleScriptWorldRef scriptWorldRef, WKURLRef urlRef)
{
    WebKit::toImpl(pageGroupRef)->userContentController().removeUserStyleSheetWithURL(*WebKit::toImpl(scriptWorldRef), URL { WebKit::toWTFString(urlRef) });
}

void WKBundleRemoveUserStyleSheets(WKBundleRef, WKBundlePageGroupRef pageGroupRef, WKBundleScriptWorldRef scriptWorldRef)
{
    WebKit::toImpl(pageGroupRef)->userContentController().removeUserStyleSheets(*WebKit::toImpl(scriptWorldRef));
}

void WKBundleRemoveAllUserContent(WKBundleRef, WKBundlePageGroupRef pageGroupRef)
{
    WebKit::toImpl(pageGroupRef)->userContentController().removeAllUserContent();
}

void WKBundleAddOriginAccessWhitelistEntry(WKBundleRef bundleRef, WKStringRef sourceOrigin, WKStringRef destinationProtocol, WKStringRef destinationHost, bool allowDestinationSubdomains)
{
    WKBundleAddOriginAccessAllowListEntry(bundleRef, sourceOrigin, destinationProtocol, destinationHost, allowDestinationSubdomains);
}

void WKBundleRemoveOriginAccessWhitelistEntry(WKBundleRef bundleRef, WKStringRef sourceOrigin, WKStringRef destinationProtocol, WKStringRef destinationHost, bool allowDestinationSubdomains)
{
    WKBundleRemoveOriginAccessAllowListEntry(bundleRef, sourceOrigin, destinationProtocol, destinationHost, allowDestinationSubdomains);
}

void WKBundleSetAsynchronousSpellCheckingEnabledForTesting(WKBundleRef bundleRef, bool enabled)
{
    protect(WebKit::toImpl(bundleRef))->setAsynchronousSpellCheckingEnabled(enabled);
}

WKArrayRef WKBundleGetLiveDocumentURLsForTesting(WKBundleRef bundleRef, bool excludeDocumentsInPageGroupPages)
{
    auto liveDocuments = protect(WebKit::toImpl(bundleRef))->liveDocumentURLs(excludeDocumentsInPageGroupPages);

    auto liveURLs = adoptWK(WKMutableArrayCreate());

    for (const auto& it : liveDocuments) {
        auto urlInfo = adoptWK(WKMutableDictionaryCreate());

        auto documentIDKey = adoptWK(WKStringCreateWithUTF8CString("id"));
        auto documentURLKey = adoptWK(WKStringCreateWithUTF8CString("url"));

        auto documentIDValue = adoptWK(WebKit::toCopiedAPI(it.key.toString()));
        auto documentURLValue = adoptWK(WebKit::toCopiedAPI(it.value));

        WKDictionarySetItem(urlInfo.get(), documentIDKey.get(), documentIDValue.get());
        WKDictionarySetItem(urlInfo.get(), documentURLKey.get(), documentURLValue.get());

        WKArrayAppendItem(liveURLs.get(), urlInfo.get());
    }
    
    return liveURLs.leakRef();
}

void WKBundleReportException(JSContextRef context, JSValueRef exception)
{
    WebKit::InjectedBundle::reportException(context, exception);
}

void WKBundleSetDatabaseQuota(WKBundleRef bundleRef, uint64_t quota)
{
    // Historically, we've used the following (somewhat nonsensical) string for the databaseIdentifier of local files.
    WebCore::DatabaseTracker::singleton().setQuota(*WebCore::SecurityOriginData::fromDatabaseIdentifier("file__0"_s), quota);
}

void WKBundleReleaseMemory(WKBundleRef)
{
    WebCore::releaseMemory(WTF::Critical::Yes, WTF::Synchronous::Yes);
}

WKDataRef WKBundleCreateWKDataFromUInt8Array(WKBundleRef bundle, JSContextRef context, JSValueRef data)
{
    return WebKit::toAPILeakingRef(protect(WebKit::toImpl(bundle))->createWebDataFromUint8Array(context, data));
}

int WKBundleNumberOfPages(WKBundleRef bundleRef, WKBundleFrameRef frameRef, double pageWidthInPixels, double pageHeightInPixels)
{
    return protect(WebKit::toImpl(bundleRef))->numberOfPages(protect(WebKit::toImpl(frameRef)).get(), pageWidthInPixels, pageHeightInPixels);
}

int WKBundlePageNumberForElementById(WKBundleRef bundleRef, WKBundleFrameRef frameRef, WKStringRef idRef, double pageWidthInPixels, double pageHeightInPixels)
{
    return protect(WebKit::toImpl(bundleRef))->pageNumberForElementById(protect(WebKit::toImpl(frameRef)).get(), WebKit::toWTFString(idRef), pageWidthInPixels, pageHeightInPixels);
}

WKStringRef WKBundlePageSizeAndMarginsInPixels(WKBundleRef bundleRef, WKBundleFrameRef frameRef, int pageIndex, int width, int height, int marginTop, int marginRight, int marginBottom, int marginLeft)
{
    return WebKit::toCopiedAPI(protect(WebKit::toImpl(bundleRef))->pageSizeAndMarginsInPixels(protect(WebKit::toImpl(frameRef)).get(), pageIndex, width, height, marginTop, marginRight, marginBottom, marginLeft));
}

bool WKBundleIsPageBoxVisible(WKBundleRef bundleRef, WKBundleFrameRef frameRef, int pageIndex)
{
    return protect(WebKit::toImpl(bundleRef))->isPageBoxVisible(protect(WebKit::toImpl(frameRef)).get(), pageIndex);
}

bool WKBundleIsProcessingUserGesture(WKBundleRef)
{
    return WebKit::InjectedBundle::isProcessingUserGesture();
}

void WKBundleSetUserStyleSheetLocationForTesting(WKBundleRef bundleRef, WKStringRef location)
{
    protect(WebKit::toImpl(bundleRef))->setUserStyleSheetLocation(WebKit::toWTFString(location));
}

void WKBundleRemoveAllWebNotificationPermissions(WKBundleRef bundleRef, WKBundlePageRef pageRef)
{
    protect(WebKit::toImpl(bundleRef))->removeAllWebNotificationPermissions(protect(WebKit::toImpl(pageRef)).get());
}

WKDataRef WKBundleCopyWebNotificationID(WKBundleRef bundleRef, JSContextRef context, JSValueRef notification)
{
    auto identifier = protect(WebKit::toImpl(bundleRef))->webNotificationID(context, notification);
    if (!identifier)
        return nullptr;

    auto span = identifier->span();
    return WKDataCreate(span.data(), span.size());
}

void WKBundleSetTabKeyCyclesThroughElements(WKBundleRef bundleRef, WKBundlePageRef pageRef, bool enabled)
{
    WebKit::toImpl(bundleRef)->setTabKeyCyclesThroughElements(WebKit::toImpl(pageRef), enabled);
}

void WKBundleClearResourceLoadStatistics(WKBundleRef)
{
    WebCore::ResourceLoadObserver::singleton().clearState();
}

void WKBundleResourceLoadStatisticsNotifyObserver(WKBundleRef, void* context, NotifyObserverCallback callback)
{
    if (!WebCore::ResourceLoadObserver::singleton().hasStatistics())
        return callback(context);

    WebCore::ResourceLoadObserver::singleton().updateCentralStatisticsStore([context, callback] {
        callback(context);
    });
}

void WKBundleExtendClassesForParameterCoder(WKBundleRef bundle, WKArrayRef classes)
{
#if PLATFORM(COCOA)
    RefPtr classList = WebKit::toImpl(classes);
    if (!classList)
        return;

    protect(WebKit::toImpl(bundle))->extendClassesForParameterCoder(*classList);
#endif
}
