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

#pragma once

// MAVERICKS_BACKPORT: bridges the revived API::IconDatabaseClient interface to Safari 7's
// legacy WK2 C icon-database client (WKIconDatabaseClientV0/V1), so favicon change
// notifications reach the browser (#49).

#include "APIClient.h"
#include "APIIconDatabaseClient.h"
#include "WKAPICast.h"
#include "WKIconDatabase.h"
#include "WKSharedAPICast.h"
#include "WebIconDatabase.h"
#include <wtf/text/WTFString.h>

namespace API {
template<> struct ClientTraits<WKIconDatabaseClientBase> {
    typedef std::tuple<WKIconDatabaseClientV0, WKIconDatabaseClientV1> Versions;
};
}

namespace WebKit {

class WebIconDatabaseClient : public API::Client<WKIconDatabaseClientBase>, public API::IconDatabaseClient {
public:
    explicit WebIconDatabaseClient(const WKIconDatabaseClientBase* client)
    {
        initialize(client);
    }

    void didChangeIconForPageURL(WebIconDatabase& iconDatabase, const String& pageURL) override
    {
        if (m_client.didChangeIconForPageURL)
            m_client.didChangeIconForPageURL(toAPI(&iconDatabase), toURLRef(pageURL.impl()), m_client.base.clientInfo);
    }

    void didRemoveAllIcons(WebIconDatabase& iconDatabase) override
    {
        if (m_client.didRemoveAllIcons)
            m_client.didRemoveAllIcons(toAPI(&iconDatabase), m_client.base.clientInfo);
    }

    // NOTE: iconDataReadyForPageURL only exists in WKIconDatabaseClientV1; API::Client
    // zero-initializes fields absent from lower versions, so the guard below is safe.
    void iconDataReadyForPageURL(WebIconDatabase& iconDatabase, const String& pageURL) override
    {
        if (m_client.iconDataReadyForPageURL)
            m_client.iconDataReadyForPageURL(toAPI(&iconDatabase), toURLRef(pageURL.impl()), m_client.base.clientInfo);
    }
};

} // namespace WebKit
