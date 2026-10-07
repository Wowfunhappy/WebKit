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

// AQUAWEBKIT: the legacy local-storage manager. Safari 7's Privacy pane drives it through
// TrackingDataController::populateWebsiteTrackingData and waits on the callback. The manager
// handle WKContextGetKeyValueStorageManager returns is the default WKWebsiteDataStore, so
// these route to WebsiteDataStore, which holds local storage.
#include "APIArray.h"
#include "APIDictionary.h"
#include "APISecurityOrigin.h"
#include "WKAPICast.h"
#include "WKMutableArray.h"
#include "WKSharedAPICast.h"
#include "WebsiteDataRecord.h"
#include "WebsiteDataStore.h"
#include <wtf/WallTime.h>

// AQUAWEBKIT: the manager handle is a WKWebsiteDataStoreRef (see WKContextGetKeyValueStorageManager).
static WebKit::WebsiteDataStore& wk109StoreForManager(WKKeyValueStorageManagerRef manager)
{
    return *WebKit::toImpl(reinterpret_cast<WKWebsiteDataStoreRef>(manager));
}

WKTypeID WKKeyValueStorageManagerGetTypeID()
{
    // return 0;
    return WebKit::toAPI(WebKit::WebsiteDataStore::APIType); // AQUAWEBKIT: the manager handle's type.
}

WKStringRef WKKeyValueStorageManagerGetOriginKey()
{
    // return nullptr;
    return WebKit::toCopiedAPI("WebKeyValueStorageManagerStorageDetailsOriginKey"_s); // AQUAWEBKIT: the legacy details key.
}

WKStringRef WKKeyValueStorageManagerGetCreationTimeKey()
{
    // return nullptr;
    return WebKit::toCopiedAPI("WebKeyValueStorageManagerStorageDetailsCreationTimeKey"_s); // AQUAWEBKIT: the legacy details key.
}

WKStringRef WKKeyValueStorageManagerGetModificationTimeKey()
{
    // return nullptr;
    return WebKit::toCopiedAPI("WebKeyValueStorageManagerStorageDetailsModificationTimeKey"_s); // AQUAWEBKIT: the legacy details key.
}

// void WKKeyValueStorageManagerGetKeyValueStorageOrigins(WKKeyValueStorageManagerRef, void*, WKKeyValueStorageManagerGetKeyValueStorageOriginsFunction)
// AQUAWEBKIT: local-storage origins from WebsiteDataStore.
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

// AQUAWEBKIT: per-origin details from WebsiteDataStore.
// void WKKeyValueStorageManagerGetStorageDetailsByOrigin(WKKeyValueStorageManagerRef, void*, WKKeyValueStorageManagerGetStorageDetailsByOriginFunction)
void WKKeyValueStorageManagerGetStorageDetailsByOrigin(WKKeyValueStorageManagerRef manager, void* context, WKKeyValueStorageManagerGetStorageDetailsByOriginFunction callback)
{
    // AQUAWEBKIT: the per-origin creation and modification times the legacy details
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

// void WKKeyValueStorageManagerDeleteEntriesForOrigin(WKKeyValueStorageManagerRef, WKSecurityOriginRef)
// AQUAWEBKIT: removes the origin's local storage from WebsiteDataStore.
void WKKeyValueStorageManagerDeleteEntriesForOrigin(WKKeyValueStorageManagerRef manager, WKSecurityOriginRef originRef)
{
    WebKit::WebsiteDataRecord record;
    record.add(WebKit::WebsiteDataType::LocalStorage, WebKit::toImpl(originRef)->securityOrigin());
    wk109StoreForManager(manager).removeData(WebKit::WebsiteDataType::LocalStorage, { record }, [] { });
}

// void WKKeyValueStorageManagerDeleteAllEntries(WKKeyValueStorageManagerRef)
// AQUAWEBKIT: removes all local storage from WebsiteDataStore.
void WKKeyValueStorageManagerDeleteAllEntries(WKKeyValueStorageManagerRef manager)
{
    wk109StoreForManager(manager).removeData(WebKit::WebsiteDataType::LocalStorage, WallTime::fromRawSeconds(0), [] { });
}
