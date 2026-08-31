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
#include "WKResourceCacheManager.h"

// MAVERICKS_BACKPORT: real bodies for the legacy resource-cache manager (the base ships
// return-0/no-op stubs). Safari 7's Privacy pane drives it through
// TrackingDataController::populateWebsiteTrackingData and waits on the callback, so a body
// that never calls back leaves the pane's website list unpopulated forever. The manager
// handle WKContextGetResourceCacheManager returns is the default WKWebsiteDataStore.
#include "APIArray.h"
#include "APIDictionary.h"
#include "APISecurityOrigin.h"
#include "WKAPICast.h"
#include "WKSharedAPICast.h"
#include "WebsiteDataRecord.h"
#include "WebsiteDataStore.h"
#include <wtf/WallTime.h>

// MAVERICKS_BACKPORT: WKResourceCachesToClearInMemoryOnly keeps the disk cache.
static OptionSet<WebKit::WebsiteDataType> wk109CacheTypes(WKResourceCachesToClear cachesToClear)
{
    if (cachesToClear == WKResourceCachesToClearInMemoryOnly)
        return WebKit::WebsiteDataType::MemoryCache;
    return { WebKit::WebsiteDataType::MemoryCache, WebKit::WebsiteDataType::DiskCache };
}

// MAVERICKS_BACKPORT: the manager handle is a WKWebsiteDataStoreRef (see WKContextGetResourceCacheManager).
static WebKit::WebsiteDataStore& wk109StoreForManager(WKResourceCacheManagerRef manager)
{
    return *WebKit::toImpl(reinterpret_cast<WKWebsiteDataStoreRef>(manager));
}

WKTypeID WKResourceCacheManagerGetTypeID()
{
    return WebKit::toAPI(WebKit::WebsiteDataStore::APIType); // MAVERICKS_BACKPORT: real type (base returns 0).
}

// MAVERICKS_BACKPORT: real body (base is an empty stub that never calls back).
void WKResourceCacheManagerGetCacheOrigins(WKResourceCacheManagerRef manager, void* context, WKResourceCacheManagerGetCacheOriginsFunction callback)
{
    if (!callback)
        return;
    wk109StoreForManager(manager).fetchData({ WebKit::WebsiteDataType::MemoryCache, WebKit::WebsiteDataType::DiskCache }, { }, [context, callback](Vector<WebKit::WebsiteDataRecord> records) {
        Vector<RefPtr<API::Object>> origins;
        for (auto& record : records) {
            for (auto& origin : record.origins)
                origins.append(API::SecurityOrigin::create(origin));
        }
        callback(WebKit::toAPI(API::Array::create(WTF::move(origins)).ptr()), nullptr, context);
    });
}

// MAVERICKS_BACKPORT: real body (base is an empty stub).
void WKResourceCacheManagerClearCacheForOrigin(WKResourceCacheManagerRef manager, WKSecurityOriginRef originRef, WKResourceCachesToClear cachesToClear)
{
    auto types = wk109CacheTypes(cachesToClear);
    WebKit::WebsiteDataRecord record;
    for (auto type : types)
        record.add(type, WebKit::toImpl(originRef)->securityOrigin());
    wk109StoreForManager(manager).removeData(types, { record }, [] { });
}

// MAVERICKS_BACKPORT: real body (base is an empty stub).
void WKResourceCacheManagerClearCacheForAllOrigins(WKResourceCacheManagerRef manager, WKResourceCachesToClear cachesToClear)
{
    wk109StoreForManager(manager).removeData(wk109CacheTypes(cachesToClear), WallTime::fromRawSeconds(0), [] { });
}
