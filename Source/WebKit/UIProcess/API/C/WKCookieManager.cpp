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
// AQUAWEBKIT: copy and validate the versioned legacy callback structure using the standard C API client machinery.
#include "APIClient.h"
// AQUAWEBKIT: the bodies below run on API::HTTPCookieStore.
#include "APIHTTPCookieStore.h"
#include "APIString.h"
#include "WKAPICast.h"
#include "WebsiteDataStore.h" // AQUAWEBKIT: since-date deletion runs on WebsiteDataStore::removeData.
#include <WebCore/Cookie.h> // AQUAWEBKIT: the hostname collection walks WebCore::Cookie.
#include <wtf/HashSet.h>
#include <wtf/WallTime.h> // AQUAWEBKIT: closes the since-date include set above.

using namespace WebKit;

// AQUAWEBKIT: Safari 7 registers the version-zero cookie-change callback.
namespace API {
template<> struct ClientTraits<WKCookieManagerClientBase> {
    using Versions = std::tuple<WKCookieManagerClientV0>;
};
}

// AQUAWEBKIT: Safari 7's cookie manager C API operates on API::HTTPCookieStore.
// Its Privacy pane uses these methods to list and remove cookies and observe storage changes.
WKTypeID WKCookieManagerGetTypeID()
{
    // return 0;
    return WebKit::toAPI(API::HTTPCookieStore::APIType); // AQUAWEBKIT: a WKCookieManagerRef is an API::HTTPCookieStore.
}

// AQUAWEBKIT: implemented through API::HTTPCookieStore (see WKCookieManagerGetTypeID).
// AQUAWEBKIT: the client registration belongs to the cookie store.
/*
void WKCookieManagerSetClient(WKCookieManagerRef, const WKCookieManagerClientBase*)
{
}
*/ // AQUAWEBKIT: store-owned client registration.
void WKCookieManagerSetClient(WKCookieManagerRef cookieManagerRef, const WKCookieManagerClientBase* client)
{
    // AQUAWEBKIT: the callback belongs to this cookie store and survives the caller's stack client.
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

// void WKCookieManagerGetHostnamesWithCookies(WKCookieManagerRef, void*, WKCookieManagerGetCookieHostnamesFunction)
// AQUAWEBKIT: implemented through API::HTTPCookieStore (see WKCookieManagerGetTypeID).
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

// void WKCookieManagerDeleteCookiesForHostname(WKCookieManagerRef, WKStringRef)
// AQUAWEBKIT: implemented through API::HTTPCookieStore (see WKCookieManagerGetTypeID).
void WKCookieManagerDeleteCookiesForHostname(WKCookieManagerRef cookieManagerRef, WKStringRef hostname)
{
    if (!cookieManagerRef)
        return;
    protect(WebKit::toImpl(cookieManagerRef))->deleteCookiesForHostnames({ WebKit::toWTFString(hostname) }, [] { });
}

// void WKCookieManagerDeleteAllCookies(WKCookieManagerRef)
// AQUAWEBKIT: implemented through API::HTTPCookieStore (see WKCookieManagerGetTypeID).
void WKCookieManagerDeleteAllCookies(WKCookieManagerRef cookieManagerRef)
{
    if (!cookieManagerRef)
        return;
    protect(WebKit::toImpl(cookieManagerRef))->deleteAllCookies([] { });
}

// void WKCookieManagerDeleteAllCookiesModifiedAfterDate(WKCookieManagerRef, double)
// AQUAWEBKIT: implemented through API::HTTPCookieStore (see WKCookieManagerGetTypeID).
void WKCookieManagerDeleteAllCookiesModifiedAfterDate(WKCookieManagerRef cookieManagerRef, double date)
{
    if (!cookieManagerRef)
        return;
    RefPtr dataStore = protect(WebKit::toImpl(cookieManagerRef))->owningDataStore();
    if (!dataStore)
        return;
    // Seconds since the Unix epoch, which is what WallTime counts from.
    dataStore->removeData(WebKit::WebsiteDataType::Cookies, WallTime::fromRawSeconds(date), [] { });
}

// AQUAWEBKIT: implemented through API::HTTPCookieStore with Safari 7's 2-argument ABI.
// -[Safari::WK::CookieManager setHTTPCookieAcceptPolicy:] tail-jumps here having set only %rdi and
// %esi, so the 4-argument form's context and callback are whatever the caller left in %rdx and %rcx.
// Safari reads the policy back with WKCookieManagerGetHTTPCookieAcceptPolicy.
// void WKCookieManagerSetHTTPCookieAcceptPolicy(WKCookieManagerRef, WKHTTPCookieAcceptPolicy, void*, WKCookieManagerSetHTTPCookieAcceptPolicyFunction)
void WKCookieManagerSetHTTPCookieAcceptPolicy(WKCookieManagerRef cookieManagerRef, WKHTTPCookieAcceptPolicy policy)
{
    if (!cookieManagerRef)
        return;
    // AQUAWEBKIT: Safari 7 has one cookie manager for the whole browser -- the Privacy pane's
    // "Block cookies and other website data" radio -- so the policy it sets is the policy of every
    // session it has. A session created afterwards inherits it through createPrivateStorageSession,
    // which reads the process's cookie jar; one that already exists is reached here.
    //
    // The same radio is where this client says whether cross-site tracking should be prevented (the
    // preference later Safaris push through -[WKWebsiteDataStore _setResourceLoadStatisticsEnabled:]):
    // accepting from anywhere is the choice not to restrict cross-site traffic. A session that has not
    // been told otherwise answers from the same jar through defaultTrackingPreventionEnabled().
    auto acceptPolicy = WebKit::toHTTPCookieAcceptPolicy(policy);
    bool preventTracking = acceptPolicy != WebCore::HTTPCookieAcceptPolicy::AlwaysAccept;
    WebKit::WebsiteDataStore::forEachWebsiteDataStore([acceptPolicy, preventTracking](WebKit::WebsiteDataStore& dataStore) {
        dataStore.setTrackingPreventionEnabled(preventTracking);
        dataStore.cookieStore().setHTTPCookieAcceptPolicy(acceptPolicy, [] { });
    });
}

// void WKCookieManagerGetHTTPCookieAcceptPolicy(WKCookieManagerRef, void*, WKCookieManagerGetHTTPCookieAcceptPolicyFunction)
// AQUAWEBKIT: implemented through API::HTTPCookieStore (see WKCookieManagerGetTypeID).
void WKCookieManagerGetHTTPCookieAcceptPolicy(WKCookieManagerRef cookieManagerRef, void* context, WKCookieManagerGetHTTPCookieAcceptPolicyFunction callback)
{
    if (!cookieManagerRef || !callback)
        return;
    protect(WebKit::toImpl(cookieManagerRef))->getHTTPCookieAcceptPolicy([context, callback] (const WebCore::HTTPCookieAcceptPolicy& policy) {
        callback(WebKit::toAPI(policy), nullptr, context);
    });
}

// AQUAWEBKIT: implemented through API::HTTPCookieStore (see WKCookieManagerGetTypeID).
// AQUAWEBKIT: Start/Stop control the cookie store observer registration.
/*
void WKCookieManagerStartObservingCookieChanges(WKCookieManagerRef)
{
}

void WKCookieManagerStopObservingCookieChanges(WKCookieManagerRef)
{
}
*/ // AQUAWEBKIT: cookie store observer registration.
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
