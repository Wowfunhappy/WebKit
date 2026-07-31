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

// MAVERICKS_BACKPORT: Revival of the WK2 icon store that Safari 7 needs (#49). Upstream deleted the
// store when it removed the WK2 IconDatabase; this keeps enough state for the legacy C API to answer
// favicon queries, backed by the same on-disk WebpageIcons.db (legacy schema, still used by the GTK
// port's IconDatabase) so History keeps its icons across relaunches (#112).

#include "config.h"
#include "WebIconDatabase.h"

#include "APIData.h"
#include "APIIconDatabaseClient.h"
#include <WebCore/SQLiteDatabase.h>
#include <WebCore/SQLiteStatement.h>
#include <WebCore/SQLiteTransaction.h>
#include <cmath>
#include <wtf/FileSystem.h>
#include <wtf/WallTime.h>

namespace WebKit {

// MAVERICKS_BACKPORT: the legacy WebpageIcons.db schema version, and the lifetimes the GTK port's
// IconDatabase applies to this same schema: an icon unused for 30 days is pruned at open, and one
// held for 4 days is refetched on next use so a site that replaces its favicon is not stale forever.
static constexpr int currentDatabaseVersion = 6;
static constexpr Seconds notUsedIconExpirationTime { 60 * 60 * 24 * 30 };
static constexpr Seconds iconExpirationTime { 60 * 60 * 24 * 4 };

static int64_t nowStamp()
{
    return static_cast<int64_t>(std::floor(WallTime::now().secondsSinceEpoch().seconds()));
}

// MAVERICKS_BACKPORT: precedence of a stored icon (#112). An icon the site declared and this OS decoded
// outranks a rasterized stand-in, which outranks a guessed /favicon.ico nobody declared; an icon never
// displaces one of higher rank, and equal rank replaces, so a site can refresh its own icon.
static unsigned iconOriginRank(WebIconDatabase::IconOrigin origin)
{
    switch (origin) {
    case WebIconDatabase::IconOrigin::Guessed:
        return 0;
    case WebIconDatabase::IconOrigin::Rasterized:
        return 1;
    case WebIconDatabase::IconOrigin::NativelyDecoded:
        return 2;
    }
    return 0;
}

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

void WebIconDatabase::setDatabasePath(const String& path)
{
    // Safari sets the path once at startup; the store never reopens onto a different file.
    if (m_db || path.isEmpty())
        return;

    if (!openDatabaseAtPath(path)) {
        // The file would not open or its tables would not come up: start the file over, as the legacy
        // database's integrity handling did. A file whose version is NEWER than this schema is not
        // taken through here — that one is left for the WebKit that wrote it.
        m_db = nullptr;
        FileSystem::deleteFile(path);
        if (!openDatabaseAtPath(path)) {
            m_db = nullptr;
            return;
        }
    }
    if (!m_db)
        return;

    pruneUnusedIconsFromDatabase();
    loadFromDatabase();
}

void WebIconDatabase::close()
{
    if (!m_db)
        return;
    m_db->close();
    m_db = nullptr;
}

bool WebIconDatabase::openDatabaseAtPath(const String& path)
{
    m_db = makeUnique<WebCore::SQLiteDatabase>();
    FileSystem::makeAllDirectories(FileSystem::parentPath(path));
    if (!m_db->open(path))
        return false;

    // Same version handling as the GTK port's IconDatabase for this same schema.
    if (m_db->tableExists("IconDatabaseInfo"_s)) {
        auto versionStatement = m_db->prepareStatement("SELECT value FROM IconDatabaseInfo WHERE key = 'Version';"_s);
        if (!versionStatement)
            return false;
        int version = versionStatement->step() == SQLITE_ROW ? versionStatement->columnInt(0) : 0;
        if (version > currentDatabaseVersion) {
            m_db->close();
            m_db = nullptr;
            return true;
        }
        if (version < currentDatabaseVersion)
            m_db->clearAllTables();
    }

    // The icon corpus is a couple hundred small images; the default ~3MB of page cache is overkill.
    m_db->executeCommand("PRAGMA cache_size = 200;"_s);

    if (!(m_db->tableExists("PageURL"_s) && m_db->tableExists("IconInfo"_s) && m_db->tableExists("IconData"_s) && m_db->tableExists("IconDatabaseInfo"_s))) {
        m_db->clearAllTables();
        // The legacy DDL, byte for byte (the GTK port creates these same tables).
        if (!m_db->executeCommand("CREATE TABLE PageURL (url TEXT NOT NULL ON CONFLICT FAIL UNIQUE ON CONFLICT REPLACE,iconID INTEGER NOT NULL ON CONFLICT FAIL);"_s))
            return false;
        if (!m_db->executeCommand("CREATE INDEX PageURLIndex ON PageURL (url);"_s))
            return false;
        if (!m_db->executeCommand("CREATE TABLE IconInfo (iconID INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE ON CONFLICT REPLACE, url TEXT NOT NULL ON CONFLICT FAIL UNIQUE ON CONFLICT FAIL, stamp INTEGER);"_s))
            return false;
        if (!m_db->executeCommand("CREATE INDEX IconInfoIndex ON IconInfo (url, iconID);"_s))
            return false;
        if (!m_db->executeCommand("CREATE TABLE IconData (iconID INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE ON CONFLICT REPLACE, data BLOB);"_s))
            return false;
        if (!m_db->executeCommand("CREATE INDEX IconDataIndex ON IconData (iconID);"_s))
            return false;
        if (!m_db->executeCommand("CREATE TABLE IconDatabaseInfo (key TEXT NOT NULL ON CONFLICT FAIL UNIQUE ON CONFLICT REPLACE,value TEXT NOT NULL ON CONFLICT FAIL);"_s))
            return false;
        auto versionInsert = m_db->prepareStatement("INSERT INTO IconDatabaseInfo VALUES ('Version', ?);"_s);
        if (!versionInsert || versionInsert->bindInt(1, currentDatabaseVersion) != SQLITE_OK || !versionInsert->executeCommand())
            return false;
    }

    // The one departure from the legacy schema: which decoder produced the stored bytes has to survive
    // the relaunch, or a rasterized stand-in read back from disk would pass for natively decoded and
    // wrongly block the site's own bitmap icon. An extra column is invisible to readers of the legacy
    // columns; rows from a file the legacy code wrote are all natively decoded, which is the default.
    if (!m_db->prepareStatement("SELECT origin FROM IconInfo LIMIT 1;"_s)) {
        if (!m_db->executeCommand("ALTER TABLE IconInfo ADD COLUMN origin INTEGER NOT NULL DEFAULT 0;"_s))
            return false;
    }
    // And on PageURL the rank of the PAGE'S claim: a guessed mapping to bytes some declared offer
    // stored must come back as a guess, or after a relaunch it would block the page's own icon.
    if (!m_db->prepareStatement("SELECT origin FROM PageURL LIMIT 1;"_s)) {
        if (!m_db->executeCommand("ALTER TABLE PageURL ADD COLUMN origin INTEGER NOT NULL DEFAULT 0;"_s))
            return false;
        // Rows from before this column carried their rank on the byte entry — every mapping was made
        // by a declared offer, whose claim is exactly how its bytes were produced. Defaulting them to
        // NativelyDecoded instead would freeze rasterized icons: their reuse would be refused as a
        // downgrade, so they would never re-stamp, never refresh, and age into the 30-day prune.
        if (!m_db->executeCommand("UPDATE PageURL SET origin = COALESCE((SELECT origin FROM IconInfo WHERE IconInfo.iconID = PageURL.iconID), 0);"_s))
            return false;
    }

    return true;
}

void WebIconDatabase::pruneUnusedIconsFromDatabase()
{
    if (!m_db)
        return;

    auto pruneStatement = m_db->prepareStatement("DELETE FROM IconInfo WHERE stamp <= (?);"_s);
    if (!pruneStatement || pruneStatement->bindInt64(1, static_cast<int64_t>(std::floor((WallTime::now() - notUsedIconExpirationTime).secondsSinceEpoch().seconds()))) != SQLITE_OK)
        return;

    WebCore::SQLiteTransaction transaction(*m_db);
    transaction.begin();
    if (pruneStatement->step() == SQLITE_DONE) {
        m_db->executeCommand("DELETE FROM IconData WHERE iconID NOT IN (SELECT iconID FROM IconInfo);"_s);
        m_db->executeCommand("DELETE FROM PageURL WHERE iconID NOT IN (SELECT iconID FROM IconInfo);"_s);
    }
    transaction.commit();
}

void WebIconDatabase::loadFromDatabase()
{
    if (!m_db)
        return;

    // Icons whose bytes are on disk. Rows without an IconData row are icon URLs whose bytes never
    // arrived — those come back only as the page mappings below, exactly as pending as they were.
    auto iconQuery = m_db->prepareStatement("SELECT IconInfo.url, IconInfo.stamp, IconInfo.origin, IconData.data FROM IconInfo INNER JOIN IconData ON IconInfo.iconID = IconData.iconID;"_s);
    if (!iconQuery)
        return;
    while (iconQuery->step() == SQLITE_ROW) {
        auto iconURL = iconQuery->columnText(0);
        auto blob = iconQuery->columnBlob(3);
        if (iconURL.isEmpty() || blob.isEmpty())
            continue;
        auto origin = IconOrigin::NativelyDecoded;
        switch (iconQuery->columnInt(2)) {
        case 1:
            origin = IconOrigin::Rasterized;
            break;
        case 2:
            origin = IconOrigin::Guessed;
            break;
        }
        m_iconURLToData.set(iconURL, StoredIcon { API::Data::create(blob.span()), origin, iconQuery->columnInt64(1), true });
    }

    auto pageQuery = m_db->prepareStatement("SELECT PageURL.url, IconInfo.url, PageURL.origin FROM PageURL INNER JOIN IconInfo ON PageURL.iconID = IconInfo.iconID;"_s);
    if (!pageQuery)
        return;
    while (pageQuery->step() == SQLITE_ROW) {
        auto pageURL = pageQuery->columnText(0);
        auto iconURL = pageQuery->columnText(1);
        if (pageURL.isEmpty() || iconURL.isEmpty())
            continue;
        auto rank = IconOrigin::NativelyDecoded;
        switch (pageQuery->columnInt(2)) {
        case 1:
            rank = IconOrigin::Rasterized;
            break;
        case 2:
            rank = IconOrigin::Guessed;
            break;
        }
        m_pageURLToIconURL.set(pageURL, PageMapping { iconURL, rank });
    }
}

std::optional<int64_t> WebIconDatabase::databaseIconIDForIconURL(const String& iconURL)
{
    auto statement = m_db->prepareStatement("SELECT iconID FROM IconInfo WHERE url = (?);"_s);
    if (!statement || statement->bindText(1, iconURL) != SQLITE_OK)
        return std::nullopt;
    if (statement->step() != SQLITE_ROW)
        return std::nullopt;
    return statement->columnInt64(0);
}

int64_t WebIconDatabase::ensureDatabaseIconRecord(const String& iconURL)
{
    if (auto iconID = databaseIconIDForIconURL(iconURL))
        return *iconID;

    auto statement = m_db->prepareStatement("INSERT INTO IconInfo (url, stamp) VALUES (?, ?);"_s);
    if (!statement || statement->bindText(1, iconURL) != SQLITE_OK || statement->bindInt64(2, nowStamp()) != SQLITE_OK)
        return 0;
    if (statement->step() != SQLITE_DONE)
        return 0;
    return m_db->lastInsertRowID();
}

bool WebIconDatabase::writeIconToDatabase(const String& iconURL, const StoredIcon& icon)
{
    auto iconID = ensureDatabaseIconRecord(iconURL);
    if (!iconID)
        return false;

    auto infoStatement = m_db->prepareStatement("UPDATE IconInfo SET stamp = ?, origin = ? WHERE iconID = ?;"_s);
    if (!infoStatement || infoStatement->bindInt64(1, icon.stamp) != SQLITE_OK || infoStatement->bindInt(2, static_cast<int>(icon.origin)) != SQLITE_OK || infoStatement->bindInt64(3, iconID) != SQLITE_OK || infoStatement->step() != SQLITE_DONE)
        return false;

    // IconData.iconID is UNIQUE ON CONFLICT REPLACE, so a plain INSERT is also the update.
    auto dataStatement = m_db->prepareStatement("INSERT INTO IconData (iconID, data) VALUES (?, ?);"_s);
    if (!dataStatement || dataStatement->bindInt64(1, iconID) != SQLITE_OK || dataStatement->bindBlob(2, icon.data->span()) != SQLITE_OK)
        return false;
    return dataStatement->step() == SQLITE_DONE;
}

bool WebIconDatabase::writePageMappingToDatabase(const String& pageURL, const String& iconURL, IconOrigin mappingRank)
{
    auto iconID = ensureDatabaseIconRecord(iconURL);
    if (!iconID)
        return false;

    // PageURL.url is UNIQUE ON CONFLICT REPLACE, so a plain INSERT is also the remap.
    auto statement = m_db->prepareStatement("INSERT INTO PageURL (url, iconID, origin) VALUES (?, ?, ?);"_s);
    if (!statement || statement->bindText(1, pageURL) != SQLITE_OK || statement->bindInt64(2, iconID) != SQLITE_OK || statement->bindInt(3, static_cast<int>(mappingRank)) != SQLITE_OK)
        return false;
    return statement->step() == SQLITE_DONE;
}

bool WebIconDatabase::touchDatabaseIconRecord(const String& iconURL, int64_t stamp)
{
    auto statement = m_db->prepareStatement("UPDATE IconInfo SET stamp = ? WHERE url = ?;"_s);
    if (!statement || statement->bindInt64(1, stamp) != SQLITE_OK || statement->bindText(2, iconURL) != SQLITE_OK)
        return false;
    return statement->step() == SQLITE_DONE;
}

bool WebIconDatabase::setIconDataForPageURL(const String& pageURL, const String& iconURL, Ref<API::Data>&& data, IconOrigin origin, Persistence persistence)
{
    // MAVERICKS_BACKPORT: admit only bytes this build can decode (github #76). There is ONE icon slot
    // per page here, so undecodable bytes are not merely useless — accepting them REPLACES a decodable
    // icon and leaves Safari drawing the generic globe. Which formats those are is not guessed from a
    // MIME type or a file extension: the test is the decode itself, through the same path the C API
    // will use to hand the icon to Safari.
    if (decodeIconData(data.get()).isEmpty())
        return false;

    return storeIcon(pageURL, iconURL, StoredIcon { WTF::move(data), origin }, persistence);
}

bool WebIconDatabase::reuseStoredIconForPageURL(const String& pageURL, const String& iconURL, Persistence persistence, std::optional<IconOrigin> mappingRank)
{
    // MAVERICKS_BACKPORT: these bytes are already in the store and already known to decode, so this
    // needs neither the admission test nor another rasterization — only the precedence rule (#49).
    auto stored = m_iconURLToData.get(iconURL);
    if (!stored.data)
        return false;

    return storeIcon(pageURL, iconURL, WTF::move(stored), persistence, mappingRank);
}

void WebIconDatabase::notePendingIconURLForPageURL(const String& pageURL, const String& iconURL, Persistence persistence, IconOrigin mappingRank)
{
    if (pageURL.isEmpty() || iconURL.isEmpty())
        return;

    // Only ever fills a blank — a mapping the page already has to a DIFFERENT icon URL, pending or
    // byte-backed, stands.
    auto addResult = m_pageURLToIconURL.add(pageURL, PageMapping { iconURL, mappingRank });
    if (!addResult.isNewEntry && addResult.iterator->value.iconURL != iconURL)
        return;

    // The disk write runs even when the memory map already held this same mapping: a mapping first
    // recorded by a private-browsing page (SessionOnly) has no row on disk, and this persistent visit
    // is what writes it. PageURL.url is UNIQUE ON CONFLICT REPLACE, so the repeat write is idempotent.
    if (m_db && persistence == Persistence::Persistent) {
        WebCore::SQLiteTransaction transaction(*m_db);
        transaction.begin();
        writePageMappingToDatabase(pageURL, iconURL, addResult.iterator->value.rank);
        transaction.commit();
    }
}

bool WebIconDatabase::iconNeedsRefresh(const String& iconURL) const
{
    if (iconURL.isEmpty())
        return false;

    auto it = m_iconURLToData.find(iconURL);
    if (it == m_iconURLToData.end() || !it->value.data)
        return false;

    return it->value.stamp <= static_cast<int64_t>(std::floor((WallTime::now() - iconExpirationTime).secondsSinceEpoch().seconds()));
}

bool WebIconDatabase::hasNativelyDecodedIconForPageURL(const String& pageURL) const
{
    // A page with no URL yet has no icon, and a null String must not reach HashMap::get.
    if (pageURL.isEmpty())
        return false;

    // MAVERICKS_BACKPORT: the rank of the PAGE'S claim — deliberately not of what is held for any
    // particular icon URL, so a site that changes its SVG (or cache-busts its URL) can still replace
    // its own rasterized icon (#49), and a guessed mapping to natively decoded bytes still yields to
    // the icon the page itself declares (#112).
    auto mapping = m_pageURLToIconURL.get(pageURL);
    if (mapping.iconURL.isEmpty())
        return false;

    auto current = m_iconURLToData.get(mapping.iconURL);
    return current.data && mapping.rank == IconOrigin::NativelyDecoded;
}

std::optional<WebIconDatabase::IconOrigin> WebIconDatabase::storedIconOriginForPageURL(const String& pageURL) const
{
    if (pageURL.isEmpty())
        return std::nullopt;

    auto mapping = m_pageURLToIconURL.get(pageURL);
    if (mapping.iconURL.isEmpty())
        return std::nullopt;

    if (!m_iconURLToData.get(mapping.iconURL).data)
        return std::nullopt;
    return mapping.rank;
}

void WebIconDatabase::noteUnusableIconURL(const String& iconURL)
{
    if (iconURL.isEmpty())
        return;

    m_unusableIconURLs.add(iconURL);
}

bool WebIconDatabase::isUnusableIconURL(const String& iconURL) const
{
    if (iconURL.isEmpty())
        return false;

    return m_unusableIconURLs.contains(iconURL);
}

bool WebIconDatabase::storeIcon(const String& pageURL, const String& iconURL, StoredIcon&& icon, Persistence persistence, std::optional<IconOrigin> mappingRank)
{
    // There is nothing to key an icon by for a page that has no URL yet, and a null String must not
    // reach HashMap::set any more than it may reach HashMap::get.
    if (pageURL.isEmpty())
        return false;

    // The strength of the claim this write makes for the page: normally how the bytes were produced,
    // but a commit-time guess reusing bytes a declared offer stored claims them only as a guess.
    auto rank = mappingRank.value_or(icon.origin);

    // MAVERICKS_BACKPORT: a write never displaces a claim the page holds at higher rank — a rasterized
    // stand-in must not displace an icon that decoded natively (a page declaring both an SVG and a
    // bitmap favicon, as github.com does, has a real icon already, and which one the single slot holds
    // must not depend on which load finished first: that order-dependence was github #76), and a
    // guessed /favicon.ico must not displace anything the page actually declared (#112).
    auto currentMapping = m_pageURLToIconURL.get(pageURL);
    if (!currentMapping.iconURL.isEmpty()) {
        if (m_iconURLToData.get(currentMapping.iconURL).data && iconOriginRank(rank) < iconOriginRank(currentMapping.rank))
            return false;
    }

    icon.stamp = nowStamp();

    if (m_db && persistence == Persistence::Persistent) {
        WebCore::SQLiteTransaction transaction(*m_db);
        transaction.begin();
        // Bytes a reuse passed back through here are usually on disk already — then only the page
        // mapping and the last-use stamp are news. They are NOT on disk when a private-browsing page
        // stored them: this persistent visit is what writes them out.
        auto existing = m_iconURLToData.find(iconURL);
        bool bytesAlreadyOnDisk = existing != m_iconURLToData.end() && existing->value.data == icon.data && existing->value.onDisk;
        bool wroteIcon = bytesAlreadyOnDisk ? touchDatabaseIconRecord(iconURL, icon.stamp) : writeIconToDatabase(iconURL, icon);
        wroteIcon = writePageMappingToDatabase(pageURL, iconURL, rank) && wroteIcon;
        transaction.commit();
        // onDisk must record only what the file really holds: a failed statement or a COMMIT that did
        // not go through (the transaction then rolls back on destruction) leaves nothing written, and
        // claiming otherwise would route every later store through the touch fast path and lose the
        // bytes at relaunch for good. Bytes already on disk from an earlier committed write stay on
        // disk whatever happened to this transaction.
        icon.onDisk = bytesAlreadyOnDisk || (wroteIcon && !transaction.inProgress());
    }

    m_pageURLToIconURL.set(pageURL, PageMapping { iconURL, rank });
    m_iconURLToData.set(iconURL, WTF::move(icon));
    // These bytes are an icon after all, whatever an earlier fetch of this URL concluded.
    m_unusableIconURLs.remove(iconURL);

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

    auto mapping = m_pageURLToIconURL.get(pageURL);
    if (mapping.iconURL.isEmpty())
        return nullptr;
    return m_iconURLToData.get(mapping.iconURL).data;
}

String WebIconDatabase::iconURLForPageURL(const String& pageURL)
{
    if (pageURL.isEmpty())
        return String();

    return m_pageURLToIconURL.get(pageURL).iconURL;
}

void WebIconDatabase::removeAllIcons()
{
    m_pageURLToIconURL.clear();
    m_iconURLToData.clear();
    m_unusableIconURLs.clear();
    // MAVERICKS_BACKPORT: an icon being rasterized in the web process right now was requested against
    // the state just cleared; the bump tells its completion handler not to store the result (#49).
    ++m_generation;

    if (m_db) {
        WebCore::SQLiteTransaction transaction(*m_db);
        transaction.begin();
        m_db->executeCommand("DELETE FROM PageURL;"_s);
        m_db->executeCommand("DELETE FROM IconInfo;"_s);
        m_db->executeCommand("DELETE FROM IconData;"_s);
        transaction.commit();
    }

    if (m_client)
        m_client->didRemoveAllIcons(*this);
}

} // namespace WebKit
