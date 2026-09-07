/* Copyright (C) 2026. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#pragma once

// browser-owned dynamic HSTS, shared by transport and website-data APIs.
#include <wtf/HashMap.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/HashSet.h>
#include <wtf/URL.h>
#include <wtf/WallTime.h>
#include <memory>

namespace WebCore {
class SQLiteDatabase;
class HTTPStrictTransportSecurityStore {
    WTF_MAKE_TZONE_ALLOCATED(HTTPStrictTransportSecurityStore);
public:
    enum class Access { ReadWrite, ReadOnly };
    WEBCORE_EXPORT static String defaultStorageDirectory(const String& baseDirectory = { });
    WEBCORE_EXPORT explicit HTTPStrictTransportSecurityStore(const String& directory = { }, Access = Access::ReadWrite);
    WEBCORE_EXPORT ~HTTPStrictTransportSecurityStore();
    WEBCORE_EXPORT bool shouldUpgrade(const URL&) const;
    WEBCORE_EXPORT void receiveHeader(const URL&, const String&);
    WEBCORE_EXPORT HashSet<String> hosts() const;
    WEBCORE_EXPORT void removeHost(const String&);
    WEBCORE_EXPORT void removeModifiedSince(WallTime);
private:
    struct Entry {
        WallTime expires;
        WallTime modified;
        bool includeSubdomains;
    };
    struct State;
    void setEntry(const String&, const Entry&);
    Access m_access;
    std::shared_ptr<State> m_state;
};
}
