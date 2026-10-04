// Safari's local storage for a clip's site, read from Safari's website data. Safari hands a new clip its
// cookies; a page's state that lives in local storage instead (a dismissed consent notice, a sign-in
// token, a chosen layout) reaches the clip the same way, from the store Safari's WebKit keeps on disk.
// WebCore names each origin's directory and records the origin in it; the store's own salt and WebCore's
// functions find and confirm the directory, which is only read.

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

static NSDictionary<NSString *, NSString *> *itemsInDatabase(const String& path)
{
    sqlite3 *database = nullptr;
    if (sqlite3_open_v2(path.utf8().data(), &database, SQLITE_OPEN_READONLY, nullptr) != SQLITE_OK) {
        sqlite3_close(database);
        return nil;
    }
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

NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *WCSafariLocalStorageForSite(NSURL *nsURL)
{
    URL url { nsURL };
    String host = url.host().convertToASCIILowercase();
    if (host.isEmpty())
        return @{ };
    String storeDirectory = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/WebKit/com.apple.Safari/WebsiteData/Default"];
    auto salt = readSalt(storeDirectory);
    if (!salt)
        return @{ };

    // A page that loads the URL may end up on the other scheme, or on the host with or without "www.".
    String otherHost = host.startsWith("www."_s) ? host.substring(4) : makeString("www."_s, host);
    String scheme = url.protocol().convertToASCIILowercase();
    NSMutableDictionary *storage = [NSMutableDictionary dictionary];
    for (auto candidateScheme : { "https"_s, "http"_s }) {
        for (auto& candidateHost : { host, otherHost }) {
            WebCore::SecurityOriginData origin { candidateScheme, candidateHost, scheme == candidateScheme ? url.port() : std::nullopt };
            String name = WebCore::StorageUtilities::encodeSecurityOriginForFileName(*salt, origin);
            String directory = FileSystem::pathByAppendingComponents(storeDirectory, std::initializer_list<StringView> { name, name });
            auto stored = WebCore::StorageUtilities::readOriginFromFile(FileSystem::pathByAppendingComponent(directory, "origin"_s));
            if (!stored || stored->topOrigin != origin || stored->clientOrigin != origin)
                continue;
            NSDictionary *items = itemsInDatabase(FileSystem::pathByAppendingComponents(directory, std::initializer_list<StringView> { "LocalStorage"_s, "localstorage.sqlite3"_s }));
            if ([items count])
                [storage setObject:items forKey:origin.toString().createNSString().get()];
        }
    }
    return storage;
}
