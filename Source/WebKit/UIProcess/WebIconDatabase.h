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
#include <optional>
#include <wtf/HashMap.h>
#include <wtf/HashSet.h>
#include <wtf/RetainPtr.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

namespace API {
class Data;
class IconDatabaseClient;
class IconLoadingClient;
}

namespace WebCore {
class SQLiteDatabase;
}

namespace WebKit {

class WebPageProxy;

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

    // MAVERICKS_BACKPORT: back the store with the on-disk database at this path — Safari 7 passes
    // ~/Library/Safari/WebpageIcons.db through WKContextSetIconDatabasePath, the same file the
    // pre-deletion icon database kept there, in the same legacy schema (the GTK port's IconDatabase
    // still uses it). Without the disk copy every relaunch starts empty and all of History shows the
    // generic globe, which outlives any fix to icon loading itself (github #112).
    void setDatabasePath(const WTF::String&);
    // MAVERICKS_BACKPORT: WKIconDatabaseClose — Safari is done with icons; close the disk database.
    // Every write goes to disk as it happens, so there is nothing to flush.
    void close();

    // MAVERICKS_BACKPORT: whether the stored icon is old enough that the site may have replaced it —
    // the legacy database refreshed an icon it had held for four days on next use; the stored icon
    // keeps serving while the refetch is in flight, so a stale answer is shown once, not kept forever.
    bool iconNeedsRefresh(const WTF::String& iconURL) const;

    // MAVERICKS_BACKPORT: where a stored icon's bytes came from, which is its precedence. Rasterized
    // means the site's own bytes were in a format this OS has no decoder for — on 10.9 that is SVG
    // above all — and the web process rendered them into an .ico instead: a stand-in for bytes this OS
    // could not read, so it never displaces an icon that decoded on its own, whichever load finished
    // first. Guessed means nobody declared this icon at all — it is the origin's /favicon.ico, fetched
    // at commit so a page abandoned before its head even arrives still gets an icon (#112) — so any
    // icon the page actually declares displaces it. The numeric values are stored in the database.
    enum class IconOrigin : uint8_t { NativelyDecoded = 0, Rasterized = 1, Guessed = 2 };

    // MAVERICKS_BACKPORT: whether this write may reach the on-disk database. A private-browsing page
    // stays SessionOnly — its icons (and which page URLs use them) live in memory like everything else
    // and die with the session, exactly as the pre-deletion IconDatabase kept private-browsing icons
    // off the disk. The page URL alone is a browsing record, so this covers the pending mappings too.
    enum class Persistence : bool { SessionOnly, Persistent };

    // MAVERICKS_BACKPORT: returns whether the icon was stored — it is rejected when this build cannot
    // decode it (github #76), and a rasterized one is rejected when the page already has a natively
    // decoded icon.
    bool setIconDataForPageURL(const WTF::String& pageURL, const WTF::String& iconURL, Ref<API::Data>&&, IconOrigin = IconOrigin::NativelyDecoded, Persistence = Persistence::Persistent);
    // MAVERICKS_BACKPORT: point a page at icon bytes already held under this icon URL, so a site whose
    // icon had to be rasterized pays for that once rather than on every page of the site. Same
    // precedence rule as above; returns whether the page now holds that icon. mappingRank caps the
    // strength of the page's claim: a commit-time guess reusing bytes a DECLARED offer once stored
    // holds them at Guessed rank all the same, so the icon this page itself declares still wins.
    bool reuseStoredIconForPageURL(const WTF::String& pageURL, const WTF::String& iconURL, Persistence = Persistence::Persistent, std::optional<IconOrigin> mappingRank = std::nullopt);
    // MAVERICKS_BACKPORT: record which icon URL a page uses BEFORE its bytes exist, exactly as the
    // pre-deletion IconDatabase committed the mapping before starting a load ("just in case we don't
    // end up loading later"). A fetch that then fails leaves the page pointing at the icon URL, so the
    // page's history entry heals the moment any later visit stores that URL's bytes — without this,
    // one transient network failure leaves the entry on the generic globe with nothing to ever
    // correct it (github #112). Never displaces a mapping the page already has.
    void notePendingIconURLForPageURL(const WTF::String& pageURL, const WTF::String& iconURL, Persistence = Persistence::Persistent, IconOrigin mappingRank = IconOrigin::NativelyDecoded);
    // MAVERICKS_BACKPORT: grant one page's icon claim — its icon URL at its rank, byte-backed or still
    // pending — to a second page URL. A same-document navigation needs exactly this: the document is
    // unchanged, so the icon it holds under its old URL is the icon of the URL it now shows under, and
    // no load will ever commit for that new URL to say so otherwise (#112).
    void carryIconForPageURL(const WTF::String& fromPageURL, const WTF::String& toPageURL, Persistence = Persistence::Persistent);
    // MAVERICKS_BACKPORT: the precedence rule as a question, so a caller holding bytes this build
    // cannot decode can tell that rasterizing them would be work whose result the store is already
    // certain to refuse.
    bool hasNativelyDecodedIconForPageURL(const WTF::String& pageURL) const;
    // MAVERICKS_BACKPORT: the rank of the byte-backed icon the page currently holds, if any — what a
    // commit-time guess consults so it fetches nothing for a page whose icon is already known (#112).
    std::optional<IconOrigin> storedIconOriginForPageURL(const WTF::String& pageURL) const;
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
        // MAVERICKS_BACKPORT: seconds-since-epoch of the last write or reuse, the legacy schema's
        // IconInfo.stamp — ages out icons of sites no longer visited and drives iconNeedsRefresh().
        int64_t stamp { 0 };
        // MAVERICKS_BACKPORT: whether these bytes are in the on-disk database. False for an icon a
        // private-browsing page stored; a later persistent visit that reuses it writes it out then.
        bool onDisk { false };
    };

    // MAVERICKS_BACKPORT: a page's claim on its icon, and how strong that claim is. The rank lives on
    // the MAPPING, not only on the bytes: a commit-time guess that reuses bytes some other page's
    // declared offer stored still holds them as a guess, and must yield to what THIS page declares.
    struct PageMapping {
        WTF::String iconURL;
        IconOrigin rank { IconOrigin::NativelyDecoded };
    };

    bool storeIcon(const WTF::String& pageURL, const WTF::String& iconURL, StoredIcon&&, Persistence, std::optional<IconOrigin> mappingRank = std::nullopt);

    // MAVERICKS_BACKPORT: the disk half of the store (#112). All of these are no-ops when Safari gave
    // no database path (or the file was unusable) — the store then simply lives for the session.
    bool openDatabaseAtPath(const WTF::String&);
    void pruneUnusedIconsFromDatabase();
    void loadFromDatabase();
    std::optional<int64_t> databaseIconIDForIconURL(const WTF::String& iconURL);
    int64_t ensureDatabaseIconRecord(const WTF::String& iconURL);
    // The write helpers report success so StoredIcon::onDisk records only what actually reached the
    // file — a swallowed statement failure here would otherwise mark bytes on-disk that a rolled-back
    // transaction never wrote, and the fast path would then never retry them.
    bool writeIconToDatabase(const WTF::String& iconURL, const StoredIcon&);
    bool writePageMappingToDatabase(const WTF::String& pageURL, const WTF::String& iconURL, IconOrigin mappingRank);
    bool touchDatabaseIconRecord(const WTF::String& iconURL, int64_t stamp);

    std::unique_ptr<API::IconDatabaseClient> m_client;
    HashMap<String, PageMapping> m_pageURLToIconURL;
    HashMap<String, StoredIcon> m_iconURLToData;
    HashSet<String> m_unusableIconURLs;
    uint64_t m_generation { 0 };
    std::unique_ptr<WebCore::SQLiteDatabase> m_db;
};

// MAVERICKS_BACKPORT: WebProcessPoolIconDatabase.cpp owns PageIconLoadingClient; WebProcessPool
// attaches one through this factory so the class need not be visible there.
std::unique_ptr<API::IconLoadingClient> createPageIconLoadingClient(WebPageProxy&, WebIconDatabase&);

} // namespace WebKit

// MAVERICKS_BACKPORT: needed so toImpl(WKIconDatabaseRef) can downcast API::Object -> WebIconDatabase (#49).
SPECIALIZE_TYPE_TRAITS_BEGIN(WebKit::WebIconDatabase)
static bool isType(const API::Object& object) { return object.type() == API::Object::Type::IconDatabase; }
SPECIALIZE_TYPE_TRAITS_END()
