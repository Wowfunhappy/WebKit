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

bool WebIconDatabase::setIconDataForPageURL(const String& pageURL, const String& iconURL, Ref<API::Data>&& data, IconOrigin origin)
{
    // MAVERICKS_BACKPORT: admit only bytes this build can decode (github #76). There is ONE icon slot
    // per page here, so undecodable bytes are not merely useless — accepting them REPLACES a decodable
    // icon and leaves Safari drawing the generic globe. Which formats those are is not guessed from a
    // MIME type or a file extension: the test is the decode itself, through the same path the C API
    // will use to hand the icon to Safari.
    if (decodeIconData(data.get()).isEmpty())
        return false;

    return storeIcon(pageURL, iconURL, StoredIcon { WTF::move(data), origin });
}

bool WebIconDatabase::reuseStoredIconForPageURL(const String& pageURL, const String& iconURL)
{
    // MAVERICKS_BACKPORT: these bytes are already in the store and already known to decode, so this
    // needs neither the admission test nor another rasterization — only the precedence rule (#49).
    auto stored = m_iconURLToData.get(iconURL);
    if (!stored.data)
        return false;

    return storeIcon(pageURL, iconURL, WTF::move(stored));
}

bool WebIconDatabase::hasNativelyDecodedIconForPageURL(const String& pageURL) const
{
    // A page with no URL yet has no icon, and a null String must not reach HashMap::get.
    if (pageURL.isEmpty())
        return false;

    // MAVERICKS_BACKPORT: the origin of what the PAGE currently points at — deliberately not of what is
    // held for any particular icon URL, so a site that changes its SVG (or cache-busts its URL) can
    // still replace its own rasterized icon (#49).
    auto currentIconURL = m_pageURLToIconURL.get(pageURL);
    if (currentIconURL.isEmpty())
        return false;

    auto current = m_iconURLToData.get(currentIconURL);
    return current.data && current.origin == IconOrigin::NativelyDecoded;
}

bool WebIconDatabase::storeIcon(const String& pageURL, const String& iconURL, StoredIcon&& icon)
{
    // There is nothing to key an icon by for a page that has no URL yet, and a null String must not
    // reach HashMap::set any more than it may reach HashMap::get.
    if (pageURL.isEmpty())
        return false;

    // MAVERICKS_BACKPORT: a rasterized icon stands in for bytes this OS cannot decode at all, so it
    // must not displace an icon that decoded natively — a page declaring both an SVG and a bitmap
    // favicon (github.com declares both) has a real icon already, and which one the single slot ends up
    // holding must not depend on which load finished first. That order-dependence was github #76.
    if (icon.origin == IconOrigin::Rasterized && hasNativelyDecodedIconForPageURL(pageURL))
        return false;

    m_pageURLToIconURL.set(pageURL, iconURL);
    m_iconURLToData.set(iconURL, WTF::move(icon));

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
    return m_iconURLToData.get(iconURL).data;
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
    // MAVERICKS_BACKPORT: an icon being rasterized in the web process right now was requested against
    // the state just cleared; the bump tells its completion handler not to store the result (#49).
    ++m_generation;

    if (m_client)
        m_client->didRemoveAllIcons(*this);
}

} // namespace WebKit
