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

// MAVERICKS_BACKPORT: Upstream reduced WebIconDatabase to an empty shell after removing the
// WK2 IconDatabase. Safari 7 still drives favicons through the legacy WK2 C API
// (WKContextGetIconDatabase / WKIconDatabaseSetIconDatabaseClient / WKIconDatabaseTryGetCGImageForURL),
// so we revive it as a minimal in-memory store: pageURL->iconURL and iconURL->icon bytes,
// populated by the icon-loading client and read back by the C API (#49).

#include "APIObject.h"
// MAVERICKS_BACKPORT: extra includes/forward-decls for the revived in-memory icon store's data
// members (pageURL->iconURL and iconURL->bytes maps) and its API::Data / IconDatabaseClient uses (#49).
#include <wtf/HashMap.h>
#include <wtf/text/WTFString.h>

namespace API {
class Data;
class IconDatabaseClient;
}

namespace WebKit {

class WebIconDatabase : public API::ObjectImpl<API::Object::Type::IconDatabase> {
    // MAVERICKS_BACKPORT: revived member surface (upstream left this class an empty shell) — the
    // minimal in-memory favicon store the legacy WK2 icon-database C API drives for Safari 7 (#49).
public:
    static Ref<WebIconDatabase> create();
    ~WebIconDatabase();

    void setClient(std::unique_ptr<API::IconDatabaseClient>&&);

    void setIconDataForPageURL(const WTF::String& pageURL, const WTF::String& iconURL, Ref<API::Data>&&);
    RefPtr<API::Data> iconDataForPageURL(const WTF::String& pageURL);
    WTF::String iconURLForPageURL(const WTF::String& pageURL);
    void removeAllIcons();

private:
    WebIconDatabase();

    std::unique_ptr<API::IconDatabaseClient> m_client;
    HashMap<String, String> m_pageURLToIconURL;
    HashMap<String, RefPtr<API::Data>> m_iconURLToData;
};

} // namespace WebKit

// MAVERICKS_BACKPORT: needed so toImpl(WKIconDatabaseRef) can downcast API::Object -> WebIconDatabase (#49).
SPECIALIZE_TYPE_TRAITS_BEGIN(WebKit::WebIconDatabase)
static bool isType(const API::Object& object) { return object.type() == API::Object::Type::IconDatabase; }
SPECIALIZE_TYPE_TRAITS_END()
