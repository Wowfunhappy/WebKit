// Safari's local storage for a clip's site, read from Safari's website data. Safari hands a new clip its
// cookies; a page's state that lives in local storage instead (a dismissed consent notice, a sign-in
// token, a chosen layout) reaches the clip the same way, from the store Safari's WebKit keeps on disk.
// WebCore names each origin's directory and records the origin in it; the store's own salt and WebCore's
// functions find and confirm the directory, which is only read. Indexed databases Safari holds for the
// site, which a page keeps a sign-in in as often as local storage, reach the clip's own store the first
// time the clip loads the site.

#include "cmakeconfig.h"

#include <wtf/Platform.h>
#include <JavaScriptCore/JSExportMacros.h>
#include <WebCore/PlatformExportMacros.h>
#include <pal/ExportMacros.h>

#include <WebCore/ClientOrigin.h>
#include <WebCore/SecurityOriginData.h>
#include <WebCore/StorageUtilities.h>
#include <wtf/FileSystem.h>
#include <wtf/URL.h>
#include <wtf/text/WTFString.h>

#import "WCSafariStorage.h"

#import <sqlite3.h>

static std::optional<FileSystem::Salt> readSalt(const String& storeDirectory)
{
    auto contents = FileSystem::readEntireFile(FileSystem::pathByAppendingComponent(storeDirectory, "salt"_s));
    FileSystem::Salt salt;
    if (!contents || contents->size() != salt.size())
        return std::nullopt;
    std::ranges::copy(*contents, salt.begin());
    return salt;
}

// Opens one of Safari's databases to read it. 10.9's SQLite reads a database in write-ahead-log mode only
// through a connection that can make the database's shared-memory file, which a database Safari has closed
// lacks; the connection only reads.
static sqlite3 *openSafariDatabase(const String& path)
{
    sqlite3 *database = nullptr;
    if (sqlite3_open_v2(path.utf8().data(), &database, SQLITE_OPEN_READWRITE, nullptr) != SQLITE_OK) {
        sqlite3_close(database);
        return nullptr;
    }
    return database;
}

static NSDictionary<NSString *, NSString *> *itemsInDatabase(const String& path)
{
    sqlite3 *database = openSafariDatabase(path);
    if (!database)
        return nil;
    NSMutableDictionary *items = [NSMutableDictionary dictionary];
    sqlite3_stmt *statement = nullptr;
    if (sqlite3_prepare_v2(database, "SELECT key, value FROM ItemTable", -1, &statement, nullptr) == SQLITE_OK) {
        while (sqlite3_step(statement) == SQLITE_ROW) {
            auto* key = reinterpret_cast<const char*>(sqlite3_column_text(statement, 0));
            if (!key)
                continue;
            // A value is its UTF-16 code units.
            const void* value = sqlite3_column_blob(statement, 1);
            int valueLength = sqlite3_column_bytes(statement, 1);
            NSString *string = [[NSString alloc] initWithBytes:value ?: "" length:valueLength encoding:NSUTF16LittleEndianStringEncoding];
            if (string)
                [items setObject:string forKey:@(key)];
            [string release];
        }
    }
    sqlite3_finalize(statement);
    sqlite3_close(database);
    return items;
}

static String originDirectory(const String& storeDirectory, const FileSystem::Salt& salt, const WebCore::SecurityOriginData& origin)
{
    String name = WebCore::StorageUtilities::encodeSecurityOriginForFileName(salt, origin);
    return FileSystem::pathByAppendingComponents(storeDirectory, std::initializer_list<StringView> { name, name });
}

// The live database at the path, copied whole to a new file at the other path.
static bool copyDatabase(const String& sourcePath, const String& destinationPath)
{
    sqlite3 *source = openSafariDatabase(sourcePath);
    sqlite3 *destination = nullptr;
    bool copied = false;
    if (source && sqlite3_open_v2(destinationPath.utf8().data(), &destination, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nullptr) == SQLITE_OK) {
        if (sqlite3_backup *backup = sqlite3_backup_init(destination, "main", source, "main")) {
            copied = sqlite3_backup_step(backup, -1) == SQLITE_DONE;
            copied = sqlite3_backup_finish(backup) == SQLITE_OK && copied;
        }
    }
    sqlite3_close(destination);
    sqlite3_close(source);
    return copied;
}

// Each of Safari's indexed databases for the origin that the clip's store lacks goes into the clip's store
// whole, with its blob files, under the name WebKit gives it from the database's name. A database the clip's page has opened
// already has its directory, and the copy is made beside it and moved into place only while the name
// is free.
static void importIndexedDatabases(const String& safariOriginDirectory, const String& clipStoreDirectory, const FileSystem::Salt& clipSalt, const WebCore::SecurityOriginData& origin)
{
    String safariDatabases = FileSystem::pathByAppendingComponent(safariOriginDirectory, "IndexedDB"_s);
    auto names = FileSystem::listDirectory(safariDatabases);
    if (names.isEmpty())
        return;
    String clipOriginDirectory = originDirectory(clipStoreDirectory, clipSalt, origin);
    String clipDatabases = FileSystem::pathByAppendingComponent(clipOriginDirectory, "IndexedDB"_s);
    for (auto& name : names) {
        String source = FileSystem::pathByAppendingComponents(safariDatabases, std::initializer_list<StringView> { name, "IndexedDB.sqlite3"_s });
        String destination = FileSystem::pathByAppendingComponent(clipDatabases, name);
        if (!FileSystem::fileExists(source) || FileSystem::fileExists(destination))
            continue;
        if (!FileSystem::makeAllDirectories(clipDatabases))
            return;
        WebCore::StorageUtilities::writeOriginToFile(FileSystem::pathByAppendingComponent(clipOriginDirectory, "origin"_s), WebCore::ClientOrigin { origin, origin });
        String staging = FileSystem::pathByAppendingComponent(clipDatabases, makeString(".import-"_s, name));
        FileSystem::deleteNonEmptyDirectory(staging);
        if (!FileSystem::makeAllDirectories(staging))
            continue;
        bool copied = copyDatabase(source, FileSystem::pathByAppendingComponent(staging, "IndexedDB.sqlite3"_s));
        // A Blob or File a record holds is a file of its own beside the database, which the record names.
        // It is written before its record and never changes, so the files there after the copy include
        // every one the copy names.
        String sourceDirectory = FileSystem::pathByAppendingComponent(safariDatabases, name);
        for (auto& file : FileSystem::listDirectory(sourceDirectory)) {
            if (copied && file.endsWith(".blob"_s))
                copied = FileSystem::copyFile(FileSystem::pathByAppendingComponent(staging, file), FileSystem::pathByAppendingComponent(sourceDirectory, file));
        }
        if (!copied || rename(staging.utf8().data(), destination.utf8().data()))
            FileSystem::deleteNonEmptyDirectory(staging);
    }
}

BOOL WCCopySQLiteDatabase(NSString *sourcePath, NSString *destinationPath)
{
    return copyDatabase(sourcePath, destinationPath);
}

NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *WCTakeSafariStorageForSite(NSURL *nsURL)
{
    static dispatch_queue_t queue = dispatch_queue_create("WebClip Safari storage", DISPATCH_QUEUE_SERIAL);
    __block NSDictionary *storage = nil;
    dispatch_sync(queue, ^{
        URL url { nsURL };
        String host = url.host().convertToASCIILowercase();
        if (host.isEmpty())
            return;
        String storeDirectory = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/WebKit/com.apple.Safari/WebsiteData/Default"];
        auto salt = readSalt(storeDirectory);
        if (!salt)
            return;
        // The clip's web views keep their data in the application's default store. Its network process
        // makes the store's salt when it starts, and the clip's load starts that process only after this.
        String clipStoreDirectory = [NSHomeDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"Library/WebKit/%@/WebsiteData/Default", [[NSBundle mainBundle] bundleIdentifier]]];
        auto clipSalt = FileSystem::readOrMakeSalt(FileSystem::pathByAppendingComponent(clipStoreDirectory, "salt"_s));

        // A page that loads the URL may end up on the other scheme, or on the host with or without "www.".
        String otherHost = host.startsWith("www."_s) ? host.substring(4) : makeString("www."_s, host);
        String scheme = url.protocol().convertToASCIILowercase();
        NSMutableDictionary *items = [NSMutableDictionary dictionary];
        for (auto candidateScheme : { "https"_s, "http"_s }) {
            for (auto& candidateHost : { host, otherHost }) {
                WebCore::SecurityOriginData origin { candidateScheme, candidateHost, scheme == candidateScheme ? url.port() : std::nullopt };
                String directory = originDirectory(storeDirectory, *salt, origin);
                auto stored = WebCore::StorageUtilities::readOriginFromFile(FileSystem::pathByAppendingComponent(directory, "origin"_s));
                if (!stored || stored->topOrigin != origin || stored->clientOrigin != origin)
                    continue;
                NSDictionary *originItems = itemsInDatabase(FileSystem::pathByAppendingComponents(directory, std::initializer_list<StringView> { "LocalStorage"_s, "localstorage.sqlite3"_s }));
                if ([originItems count])
                    [items setObject:originItems forKey:origin.toString().createNSString().get()];
                if (clipSalt)
                    importIndexedDatabases(directory, clipStoreDirectory, *clipSalt, origin);
            }
        }
        storage = [items retain];
    });
    return [storage autorelease] ?: @{ };
}
