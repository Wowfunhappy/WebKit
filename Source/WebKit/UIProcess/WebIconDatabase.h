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
#include <CoreGraphics/CoreGraphics.h>
#include <wtf/HashMap.h>
#include <wtf/HashSet.h>
#include <wtf/RetainPtr.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

namespace API {
class Data;
class IconDatabaseClient;
}

namespace WebKit {

// MAVERICKS_BACKPORT: decodes stored favicon bytes into their frames, defined next to the C API that
// hands them to Safari (UIProcess/API/C/cg/WKIconDatabaseCG.cpp) because that is where the platform
// image machinery lives. The store uses it to admit only icons this build can actually turn into an
// image (github #76): with one icon slot per page, accepting undecodable bytes would let them replace
// a good icon and leave Safari drawing the generic globe.
Vector<RetainPtr<CGImageRef>> decodeIconData(API::Data&);

class WebIconDatabase : public API::ObjectImpl<API::Object::Type::IconDatabase> {
    // MAVERICKS_BACKPORT: revived member surface (upstream left this class an empty shell) — the
    // minimal in-memory favicon store the legacy WK2 icon-database C API drives for Safari 7 (#49).
public:
    static Ref<WebIconDatabase> create();
    ~WebIconDatabase();

    void setClient(std::unique_ptr<API::IconDatabaseClient>&&);

    // MAVERICKS_BACKPORT: where a stored icon's bytes came from. Rasterized means the site's own bytes
    // were in a format this OS has no decoder for — on 10.9 that is SVG above all — and the web process
    // rendered them into an .ico instead. Such an icon is a stand-in for one this OS could not read, so
    // it never displaces an icon that decoded on its own, whichever of the two loads finishes first.
    enum class IconOrigin : bool { NativelyDecoded, Rasterized };

    // MAVERICKS_BACKPORT: returns whether the icon was stored — it is rejected when this build cannot
    // decode it (github #76), and a rasterized one is rejected when the page already has a natively
    // decoded icon.
    bool setIconDataForPageURL(const WTF::String& pageURL, const WTF::String& iconURL, Ref<API::Data>&&, IconOrigin = IconOrigin::NativelyDecoded);
    // MAVERICKS_BACKPORT: point a page at icon bytes already held under this icon URL, so a site whose
    // icon had to be rasterized pays for that once rather than on every page of the site. Same
    // precedence rule as above; returns whether the page now holds that icon.
    bool reuseStoredIconForPageURL(const WTF::String& pageURL, const WTF::String& iconURL);
    // MAVERICKS_BACKPORT: the precedence rule as a question, so a caller holding bytes this build
    // cannot decode can tell that rasterizing them would be work whose result the store is already
    // certain to refuse.
    bool hasNativelyDecodedIconForPageURL(const WTF::String& pageURL) const;
    // MAVERICKS_BACKPORT: an icon URL whose bytes have been fetched and turned out to be no icon at all —
    // the error page a site without a /favicon.ico serves for it, or an image nothing here can read and
    // the web process cannot rasterize either. The client fetches icons itself (#112), so without this
    // it would fetch the same dead URL again for every further page of that site; every page of a site
    // declares the same one.
    void noteUnusableIconURL(const WTF::String& iconURL);
    bool isUnusableIconURL(const WTF::String& iconURL) const;
    RefPtr<API::Data> iconDataForPageURL(const WTF::String& pageURL);
    WTF::String iconURLForPageURL(const WTF::String& pageURL);
    void removeAllIcons();
    // MAVERICKS_BACKPORT: bumped by removeAllIcons, so work started against an earlier state of the
    // store (a rasterization in flight in the web process) can tell that its result is stale and must
    // not resurrect an icon Safari has since cleared.
    uint64_t generation() const { return m_generation; }

private:
    WebIconDatabase();

    struct StoredIcon {
        RefPtr<API::Data> data;
        IconOrigin origin { IconOrigin::NativelyDecoded };
    };

    bool storeIcon(const WTF::String& pageURL, const WTF::String& iconURL, StoredIcon&&);

    std::unique_ptr<API::IconDatabaseClient> m_client;
    HashMap<String, String> m_pageURLToIconURL;
    HashMap<String, StoredIcon> m_iconURLToData;
    HashSet<String> m_unusableIconURLs;
    uint64_t m_generation { 0 };
};

} // namespace WebKit

// MAVERICKS_BACKPORT: needed so toImpl(WKIconDatabaseRef) can downcast API::Object -> WebIconDatabase (#49).
SPECIALIZE_TYPE_TRAITS_BEGIN(WebKit::WebIconDatabase)
static bool isType(const API::Object& object) { return object.type() == API::Object::Type::IconDatabase; }
SPECIALIZE_TYPE_TRAITS_END()
