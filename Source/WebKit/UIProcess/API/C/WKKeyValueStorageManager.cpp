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
#include "WKKeyValueStorageManager.h"

// MAVERICKS_BACKPORT: real bodies for the legacy local-storage manager (the base ships
// return-0/null/no-op stubs). Safari 7's Privacy pane drives it through
// TrackingDataController::populateWebsiteTrackingData and waits on the callback, so a body
// that never calls back leaves the pane's website list unpopulated forever. The manager
// handle WKContextGetKeyValueStorageManager returns is the default WKWebsiteDataStore, so
// these route to WebsiteDataStore, which is where local storage lives now.
#include "APIArray.h"
#include "APIDictionary.h"
#include "APISecurityOrigin.h"
#include "WKAPICast.h"
#include "WKMutableArray.h"
#include "WKSharedAPICast.h"
#include "WebsiteDataRecord.h"
#include "WebsiteDataStore.h"
#include <wtf/WallTime.h>

// MAVERICKS_BACKPORT: the manager handle is a WKWebsiteDataStoreRef (see WKContextGetKeyValueStorageManager).
static WebKit::WebsiteDataStore& wk109StoreForManager(WKKeyValueStorageManagerRef manager)
{
    return *WebKit::toImpl(reinterpret_cast<WKWebsiteDataStoreRef>(manager));
}

WKTypeID WKKeyValueStorageManagerGetTypeID()
{
    return WebKit::toAPI(WebKit::WebsiteDataStore::APIType); // MAVERICKS_BACKPORT: real type (base returns 0).
}

WKStringRef WKKeyValueStorageManagerGetOriginKey()
{
    return WebKit::toCopiedAPI("WebKeyValueStorageManagerStorageDetailsOriginKey"_s); // MAVERICKS_BACKPORT: real key (base returns null).
}

WKStringRef WKKeyValueStorageManagerGetCreationTimeKey()
{
    return WebKit::toCopiedAPI("WebKeyValueStorageManagerStorageDetailsCreationTimeKey"_s); // MAVERICKS_BACKPORT: real key (base returns null).
}

WKStringRef WKKeyValueStorageManagerGetModificationTimeKey()
{
    return WebKit::toCopiedAPI("WebKeyValueStorageManagerStorageDetailsModificationTimeKey"_s); // MAVERICKS_BACKPORT: real key (base returns null).
}

// MAVERICKS_BACKPORT: real body (base is an empty stub that never calls back).
void WKKeyValueStorageManagerGetKeyValueStorageOrigins(WKKeyValueStorageManagerRef manager, void* context, WKKeyValueStorageManagerGetKeyValueStorageOriginsFunction callback)
{
    if (!callback)
        return;
    wk109StoreForManager(manager).fetchData(WebKit::WebsiteDataType::LocalStorage, { }, [context, callback](Vector<WebKit::WebsiteDataRecord> records) {
        Vector<RefPtr<API::Object>> origins;
        for (auto& record : records) {
            for (auto& origin : record.origins)
                origins.append(API::SecurityOrigin::create(origin));
        }
        callback(WebKit::toAPI(API::Array::create(WTF::move(origins)).ptr()), nullptr, context);
    });
}

// MAVERICKS_BACKPORT: real body (base is an empty stub that never calls back).
void WKKeyValueStorageManagerGetStorageDetailsByOrigin(WKKeyValueStorageManagerRef manager, void* context, WKKeyValueStorageManagerGetStorageDetailsByOriginFunction callback)
{
    // MAVERICKS_BACKPORT: the per-origin creation and modification times the legacy details
    // dictionary carried are not tracked by WebsiteDataStore, so each entry reports the origin
    // alone under the origin key above.
    if (!callback)
        return;
    wk109StoreForManager(manager).fetchData(WebKit::WebsiteDataType::LocalStorage, { }, [context, callback](Vector<WebKit::WebsiteDataRecord> records) {
        Vector<RefPtr<API::Object>> details;
        for (auto& record : records) {
            for (auto& origin : record.origins) {
                API::Dictionary::MapType map;
                map.set("WebKeyValueStorageManagerStorageDetailsOriginKey"_s, API::SecurityOrigin::create(origin));
                details.append(API::Dictionary::create(WTF::move(map)));
            }
        }
        callback(WebKit::toAPI(API::Array::create(WTF::move(details)).ptr()), nullptr, context);
    });
}

// MAVERICKS_BACKPORT: real body (base is an empty stub).
void WKKeyValueStorageManagerDeleteEntriesForOrigin(WKKeyValueStorageManagerRef manager, WKSecurityOriginRef originRef)
{
    WebKit::WebsiteDataRecord record;
    record.add(WebKit::WebsiteDataType::LocalStorage, WebKit::toImpl(originRef)->securityOrigin());
    wk109StoreForManager(manager).removeData(WebKit::WebsiteDataType::LocalStorage, { record }, [] { });
}

// MAVERICKS_BACKPORT: real body (base is an empty stub).
void WKKeyValueStorageManagerDeleteAllEntries(WKKeyValueStorageManagerRef manager)
{
    wk109StoreForManager(manager).removeData(WebKit::WebsiteDataType::LocalStorage, WallTime::fromRawSeconds(0), [] { });
}
