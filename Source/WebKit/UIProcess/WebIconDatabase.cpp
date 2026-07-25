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

// MAVERICKS_BACKPORT: In-memory revival of the WK2 icon store that Safari 7 needs (#49).
// Upstream deleted the store when it removed the WK2 IconDatabase; this keeps just enough
// state for the legacy C API to answer favicon queries.

#include "config.h"
#include "WebIconDatabase.h"

#include "APIData.h"
#include "APIIconDatabaseClient.h"

namespace WebKit {

Ref<WebIconDatabase> WebIconDatabase::create()
{
    return adoptRef(*new WebIconDatabase);
}

WebIconDatabase::WebIconDatabase() = default;

WebIconDatabase::~WebIconDatabase() = default;

void WebIconDatabase::setClient(std::unique_ptr<API::IconDatabaseClient>&& client)
{
    m_client = WTF::move(client);
}

bool WebIconDatabase::setIconDataForPageURL(const String& pageURL, const String& iconURL, Ref<API::Data>&& data)
{
    // MAVERICKS_BACKPORT: admit only bytes this build can decode (github #76). There is ONE icon slot
    // per page here, so undecodable bytes are not merely useless — accepting them REPLACES a decodable
    // icon and leaves Safari drawing the generic globe. Which formats those are is not guessed from a
    // MIME type or a file extension: the test is the decode itself, through the same path the C API
    // will use to hand the icon to Safari.
    if (decodeIconData(data.get()).isEmpty())
        return false;

    m_pageURLToIconURL.set(pageURL, iconURL);
    m_iconURLToData.set(iconURL, data.ptr());

    if (m_client) {
        m_client->didChangeIconForPageURL(*this, pageURL);
        m_client->iconDataReadyForPageURL(*this, pageURL);
    }
    return true;
}

RefPtr<API::Data> WebIconDatabase::iconDataForPageURL(const String& pageURL)
{
    // Safari queries with a null URL for pages that have no URL yet (e.g. a fresh new tab), and a
    // null String must not reach HashMap::get (hashing it dereferences a null StringImpl).
    if (pageURL.isEmpty())
        return nullptr;

    auto iconURL = m_pageURLToIconURL.get(pageURL);
    if (iconURL.isEmpty())
        return nullptr;
    return m_iconURLToData.get(iconURL);
}

String WebIconDatabase::iconURLForPageURL(const String& pageURL)
{
    if (pageURL.isEmpty())
        return String();

    return m_pageURLToIconURL.get(pageURL);
}

void WebIconDatabase::removeAllIcons()
{
    m_pageURLToIconURL.clear();
    m_iconURLToData.clear();

    if (m_client)
        m_client->didRemoveAllIcons(*this);
}

} // namespace WebKit
