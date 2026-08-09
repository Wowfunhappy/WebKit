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
// MAVERICKS_BACKPORT: the restored bodies below run on API::HTTPCookieStore.
#include "APIHTTPCookieStore.h"
#include "APIString.h"
#include "WKAPICast.h"
#include "WebsiteDataStore.h" // MAVERICKS_BACKPORT: since-date deletion runs on WebsiteDataStore::removeData.
#include <WebCore/Cookie.h> // MAVERICKS_BACKPORT: the restored hostname collection walks WebCore::Cookie.
#include <wtf/HashSet.h>
#include <wtf/WallTime.h> // MAVERICKS_BACKPORT: closes the since-date include set above.

using namespace WebKit;

// MAVERICKS_BACKPORT: upstream gutted every body in this file to a no-op when it replaced the legacy
// cookie manager with the per-data-store WKHTTPCookieStore API. Safari 7 has only this one, and imports
// WKCookieManagerSetClient, ...GetHostnamesWithCookies, ...DeleteCookiesForHostname, ...DeleteAllCookies
// and ...StartObservingCookieChanges -- so with the no-ops in place its Privacy pane lists nothing and
// "Remove All Website Data" removes nothing. Restored over API::HTTPCookieStore, which is the same
// machinery the modern API uses; a WKCookieManagerRef is that store.
WKTypeID WKCookieManagerGetTypeID() // MAVERICKS_BACKPORT: a WKCookieManagerRef is an API::HTTPCookieStore.
{
    return WebKit::toAPI(API::HTTPCookieStore::APIType);
}

// MAVERICKS_BACKPORT: restored over API::HTTPCookieStore (see the note above WKCookieManagerGetTypeID).
void WKCookieManagerSetClient(WKCookieManagerRef, const WKCookieManagerClientBase*)
{
    // Cookie-change notifications are delivered through the observer registered by
    // WKCookieManagerStartObservingCookieChanges; this client carries no other callback Safari uses.
}

// MAVERICKS_BACKPORT: restored over API::HTTPCookieStore (see the note above WKCookieManagerGetTypeID).
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

// MAVERICKS_BACKPORT: restored over API::HTTPCookieStore (see the note above WKCookieManagerGetTypeID).
void WKCookieManagerDeleteCookiesForHostname(WKCookieManagerRef cookieManagerRef, WKStringRef hostname)
{
    if (!cookieManagerRef)
        return;
    protect(WebKit::toImpl(cookieManagerRef))->deleteCookiesForHostnames({ WebKit::toWTFString(hostname) }, [] { });
}

// MAVERICKS_BACKPORT: restored over API::HTTPCookieStore (see the note above WKCookieManagerGetTypeID).
void WKCookieManagerDeleteAllCookies(WKCookieManagerRef cookieManagerRef)
{
    if (!cookieManagerRef)
        return;
    protect(WebKit::toImpl(cookieManagerRef))->deleteAllCookies([] { });
}

// MAVERICKS_BACKPORT: restored over API::HTTPCookieStore (see the note above WKCookieManagerGetTypeID).
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

// MAVERICKS_BACKPORT: restored over API::HTTPCookieStore (see the note above WKCookieManagerGetTypeID).
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
}

// MAVERICKS_BACKPORT: restored over API::HTTPCookieStore (see the note above WKCookieManagerGetTypeID).
void WKCookieManagerGetHTTPCookieAcceptPolicy(WKCookieManagerRef cookieManagerRef, void* context, WKCookieManagerGetHTTPCookieAcceptPolicyFunction callback)
{
    if (!cookieManagerRef || !callback)
        return;
    protect(WebKit::toImpl(cookieManagerRef))->getHTTPCookieAcceptPolicy([context, callback] (const WebCore::HTTPCookieAcceptPolicy& policy) {
        callback(WebKit::toAPI(policy), nullptr, context);
    });
}

// MAVERICKS_BACKPORT: restored over API::HTTPCookieStore (see the note above WKCookieManagerGetTypeID).
void WKCookieManagerStartObservingCookieChanges(WKCookieManagerRef)
{
    // API::HTTPCookieStore starts observing when an observer registers; Safari's client carries no
    // cookiesDidChange callback, so there is nothing further to wire up.
}

void WKCookieManagerStopObservingCookieChanges(WKCookieManagerRef)
{
}
