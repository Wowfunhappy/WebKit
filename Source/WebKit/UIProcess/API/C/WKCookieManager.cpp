/*
 * Copyright (C) 2011 Apple Inc. All rights reserved.
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
#include "WKCookieManager.h"

#include "APIArray.h"
// MAVERICKS_BACKPORT: copy and validate the versioned legacy callback structure using the standard C API client machinery.
#include "APIClient.h"
// MAVERICKS_BACKPORT: the restored bodies below run on API::HTTPCookieStore.
#include "APIHTTPCookieStore.h"
#include "APIString.h"
#include "WKAPICast.h"
#include "WebsiteDataStore.h" // MAVERICKS_BACKPORT: since-date deletion runs on WebsiteDataStore::removeData.
#include <WebCore/Cookie.h> // MAVERICKS_BACKPORT: the restored hostname collection walks WebCore::Cookie.
#include <wtf/HashSet.h>
#include <wtf/WallTime.h> // MAVERICKS_BACKPORT: closes the since-date include set above.

using namespace WebKit;

// MAVERICKS_BACKPORT: Safari 7 registers the version-zero cookie-change callback.
namespace API {
template<> struct ClientTraits<WKCookieManagerClientBase> {
    using Versions = std::tuple<WKCookieManagerClientV0>;
};
}

// MAVERICKS_BACKPORT: Safari 7's cookie manager C API operates on API::HTTPCookieStore.
// Its Privacy pane uses these methods to list and remove cookies and observe storage changes.
WKTypeID WKCookieManagerGetTypeID() // MAVERICKS_BACKPORT: a WKCookieManagerRef is an API::HTTPCookieStore.
{
    return WebKit::toAPI(API::HTTPCookieStore::APIType);
}

// MAVERICKS_BACKPORT: implemented through API::HTTPCookieStore (see WKCookieManagerGetTypeID).
// MAVERICKS_BACKPORT: the client registration belongs to the cookie store.
/*
void WKCookieManagerSetClient(WKCookieManagerRef, const WKCookieManagerClientBase*)
{
}
*/ // MAVERICKS_BACKPORT: store-owned client registration.
void WKCookieManagerSetClient(WKCookieManagerRef cookieManagerRef, const WKCookieManagerClientBase* client)
{
    // MAVERICKS_BACKPORT: the callback belongs to this cookie store and survives the caller's stack client.
    if (!cookieManagerRef)
        return;
    API::Client<WKCookieManagerClientBase> copiedClient;
    copiedClient.initialize(client);
    auto callback = copiedClient.client().cookiesDidChange;
    auto info = copiedClient.client().base.clientInfo;
    Ref store = *WebKit::toImpl(cookieManagerRef);
    if (!callback) {
        store->setLegacyCookieChangeCallback({ });
        return;
    }
    store->setLegacyCookieChangeCallback([callback, info](API::HTTPCookieStore& changedStore) {
        callback(reinterpret_cast<WKCookieManagerRef>(WebKit::toAPI(&changedStore)), info);
    });
}

// MAVERICKS_BACKPORT: implemented through API::HTTPCookieStore (see WKCookieManagerGetTypeID).
void WKCookieManagerGetHostnamesWithCookies(WKCookieManagerRef cookieManagerRef, void* context, WKCookieManagerGetCookieHostnamesFunction callback)
{
    if (!cookieManagerRef || !callback)
        return;
    protect(WebKit::toImpl(cookieManagerRef))->cookies([context, callback] (Vector<WebCore::Cookie>&& cookies) {
        HashSet<String> hostnames;
        for (auto& cookie : cookies)
            hostnames.add(cookie.domain);
        auto hostnameStrings = WTF::map(hostnames, [] (auto& hostname) -> RefPtr<API::Object> {
            return API::String::create(hostname);
        });
        callback(WebKit::toAPI(API::Array::create(WTF::move(hostnameStrings)).ptr()), nullptr, context);
    });
}

// MAVERICKS_BACKPORT: implemented through API::HTTPCookieStore (see WKCookieManagerGetTypeID).
void WKCookieManagerDeleteCookiesForHostname(WKCookieManagerRef cookieManagerRef, WKStringRef hostname)
{
    if (!cookieManagerRef)
        return;
    protect(WebKit::toImpl(cookieManagerRef))->deleteCookiesForHostnames({ WebKit::toWTFString(hostname) }, [] { });
}

// MAVERICKS_BACKPORT: implemented through API::HTTPCookieStore (see WKCookieManagerGetTypeID).
void WKCookieManagerDeleteAllCookies(WKCookieManagerRef cookieManagerRef)
{
    if (!cookieManagerRef)
        return;
    protect(WebKit::toImpl(cookieManagerRef))->deleteAllCookies([] { });
}

// MAVERICKS_BACKPORT: implemented through API::HTTPCookieStore (see WKCookieManagerGetTypeID).
void WKCookieManagerDeleteAllCookiesModifiedAfterDate(WKCookieManagerRef cookieManagerRef, double date)
{
    if (!cookieManagerRef)
        return;
    RefPtr dataStore = protect(WebKit::toImpl(cookieManagerRef))->owningDataStore();
    if (!dataStore)
        return;
    // Seconds since the Unix epoch: this API's original implementation handed the value straight to
    // +[NSDate dateWithTimeIntervalSince1970:], which is what WallTime counts from.
    dataStore->removeData(WebKit::WebsiteDataType::Cookies, WallTime::fromRawSeconds(date), [] { });
}

// MAVERICKS_BACKPORT: restored over API::HTTPCookieStore (see the note above WKCookieManagerGetTypeID),
// with Safari 7's 2-argument ABI. -[Safari::WK::CookieManager setHTTPCookieAcceptPolicy:] tail-jumps
// here having set only %rdi and %esi, so the context and callback upstream added in the 4-argument form
// are whatever the caller left in %rdx and %rcx: a non-null garbage %rcx gets called as the completion
// handler, from the reply handler for WebCookieManager::SetHTTPCookieAcceptPolicy. The legacy contract
// reports nothing back -- Safari drives the preference one way and reads it with
// WKCookieManagerGetHTTPCookieAcceptPolicy.
void WKCookieManagerSetHTTPCookieAcceptPolicy(WKCookieManagerRef cookieManagerRef, WKHTTPCookieAcceptPolicy policy)
{
    if (!cookieManagerRef)
        return;
    // MAVERICKS_BACKPORT: Safari 7 has one cookie manager for the whole browser -- the Privacy pane's
    // "Block cookies and other website data" radio -- so the policy it sets is the policy of every
    // session it has. A session created afterwards inherits it through createPrivateStorageSession,
    // which reads the process's cookie jar; one that already exists is reached here.
    //
    // The same radio is where this client says whether cross-site tracking should be prevented, the
    // preference Safari 11 moved to its own checkbox and pushes through
    // -[WKWebsiteDataStore _setResourceLoadStatisticsEnabled:]: accepting from anywhere is the choice
    // not to restrict cross-site traffic, and without it ThirdPartyCookieBlockingMode::All blocks
    // every third-party cookie at all three radio positions. A session that has not been told
    // otherwise answers from the same jar through defaultTrackingPreventionEnabled().
    auto acceptPolicy = WebKit::toHTTPCookieAcceptPolicy(policy);
    bool preventTracking = acceptPolicy != WebCore::HTTPCookieAcceptPolicy::AlwaysAccept;
    WebKit::WebsiteDataStore::forEachWebsiteDataStore([acceptPolicy, preventTracking](WebKit::WebsiteDataStore& dataStore) {
        dataStore.setTrackingPreventionEnabled(preventTracking);
        dataStore.cookieStore().setHTTPCookieAcceptPolicy(acceptPolicy, [] { });
    });
/* MAVERICKS_BACKPORT: upstream's 4-argument body kept here so upstream merges see the original text; not built on this backport (see above).
void WKCookieManagerSetHTTPCookieAcceptPolicy(WKCookieManagerRef cookieManagerRef, WKHTTPCookieAcceptPolicy policy, void* context, WKCookieManagerSetHTTPCookieAcceptPolicyFunction callback)
{
    if (!cookieManagerRef) {
        if (callback)
            callback(nullptr, context);
        return;
    }
    protect(WebKit::toImpl(cookieManagerRef))->setHTTPCookieAcceptPolicy(WebKit::toHTTPCookieAcceptPolicy(policy), [context, callback] {
        if (callback)
            callback(nullptr, context);
    });
MAVERICKS_BACKPORT */
}

// MAVERICKS_BACKPORT: implemented through API::HTTPCookieStore (see WKCookieManagerGetTypeID).
void WKCookieManagerGetHTTPCookieAcceptPolicy(WKCookieManagerRef cookieManagerRef, void* context, WKCookieManagerGetHTTPCookieAcceptPolicyFunction callback)
{
    if (!cookieManagerRef || !callback)
        return;
    protect(WebKit::toImpl(cookieManagerRef))->getHTTPCookieAcceptPolicy([context, callback] (const WebCore::HTTPCookieAcceptPolicy& policy) {
        callback(WebKit::toAPI(policy), nullptr, context);
    });
}

// MAVERICKS_BACKPORT: implemented through API::HTTPCookieStore (see WKCookieManagerGetTypeID).
// MAVERICKS_BACKPORT: Start/Stop control the cookie store observer registration.
/*
void WKCookieManagerStartObservingCookieChanges(WKCookieManagerRef)
{
}

void WKCookieManagerStopObservingCookieChanges(WKCookieManagerRef)
{
}
*/ // MAVERICKS_BACKPORT: cookie store observer registration.
void WKCookieManagerStartObservingCookieChanges(WKCookieManagerRef cookieManagerRef)
{
    if (cookieManagerRef)
        protect(WebKit::toImpl(cookieManagerRef))->startObservingLegacyCookieChanges();
}

void WKCookieManagerStopObservingCookieChanges(WKCookieManagerRef cookieManagerRef)
{
    if (cookieManagerRef)
        protect(WebKit::toImpl(cookieManagerRef))->stopObservingLegacyCookieChanges();
}
