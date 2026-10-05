#import "WCSafariExtensions.h"

#import "WCExtensionDatabases.h"
#import "WCExtensionRuntime.h"
#import "WCSafariStorage.h"
#import "WCWebKitSPI.h"
#import <Security/Security.h>
#import <xar/xar.h>

static NSString *libraryPath(NSString *component)
{
    return [[NSHomeDirectory() stringByAppendingPathComponent:@"Library"] stringByAppendingPathComponent:component];
}

// The developer identifier Safari keys an installed extension with: the ten characters a "Safari Developer:
// (<identifier>) <name>" signing certificate names, from the archive's leaf certificate.
static NSString *developerIdentifierOfArchive(NSString *archivePath)
{
    xar_t archive = xar_open(archivePath.fileSystemRepresentation, READ);
    if (!archive)
        return nil;
    NSString *identifier = nil;
    const uint8_t *certificateData = NULL;
    uint32_t certificateLength = 0;
    xar_signature_t signature = xar_signature_first(archive);
    if (signature && !xar_signature_get_x509certificate_data(signature, 0, &certificateData, &certificateLength) && certificateData) {
        NSData *data = [NSData dataWithBytes:certificateData length:certificateLength];
        SecCertificateRef certificate = SecCertificateCreateWithData(kCFAllocatorDefault, (__bridge CFDataRef)data);
        NSString *subject = certificate ? CFBridgingRelease(SecCertificateCopySubjectSummary(certificate)) : nil;
        if (certificate)
            CFRelease(certificate);
        static NSString * const prefix = @"Safari Developer: (";
        static const NSUInteger identifierLength = 10;
        if ([subject hasPrefix:prefix] && subject.length > prefix.length + identifierLength + 2 && [[subject substringWithRange:NSMakeRange(prefix.length + identifierLength, 2)] isEqualToString:@") "]) {
            NSString *candidate = [subject substringWithRange:NSMakeRange(prefix.length, identifierLength)];
            NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"] invertedSet];
            if ([candidate rangeOfCharacterFromSet:invalid].location == NSNotFound)
                identifier = candidate;
        }
    }
    xar_close(archive);
    return identifier;
}

// WebKit's name for the storage of an extension's pages, whose origin's host is the extension's key.
static NSString *originIdentifier(NSString *key)
{
    return [NSString stringWithFormat:@"safari-extension_%@_0", key.lowercaseString];
}

// A directory of storage, its SQLite databases copied consistently and its other files as they are. A
// database's write-ahead log and shared memory are part of what the copy reads.
static BOOL copyStorageDirectory(NSString *source, NSString *destination)
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager createDirectoryAtPath:destination withIntermediateDirectories:YES attributes:nil error:nil])
        return NO;
    for (NSString *name in [fileManager contentsOfDirectoryAtPath:source error:nil]) {
        NSString *sourcePath = [source stringByAppendingPathComponent:name];
        NSString *destinationPath = [destination stringByAppendingPathComponent:name];
        BOOL isDirectory = NO;
        [fileManager fileExistsAtPath:sourcePath isDirectory:&isDirectory];
        BOOL copied;
        if (isDirectory)
            copied = copyStorageDirectory(sourcePath, destinationPath);
        else if ([name hasSuffix:@"-wal"] || [name hasSuffix:@"-shm"])
            copied = YES;
        else if ([fileManager fileExistsAtPath:[sourcePath stringByAppendingString:@"-wal"]] || [name hasSuffix:@".sqlite3"] || [name hasSuffix:@".db"] || [name hasSuffix:@".localstorage"])
            copied = WCCopySQLiteDatabase(sourcePath, destinationPath);
        else
            copied = [fileManager copyItemAtPath:sourcePath toPath:destinationPath error:nil];
        if (!copied)
            return NO;
    }
    return YES;
}

// The directories of an origin's indexed databases, one under each version of WebKit's storage format.
static NSArray<NSString *> *indexedDatabaseDirectories(NSString *indexedDatabases, NSString *origin)
{
    NSMutableArray *directories = [NSMutableArray array];
    for (NSString *version in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:indexedDatabases error:nil])
        [directories addObject:[[indexedDatabases stringByAppendingPathComponent:version] stringByAppendingPathComponent:origin]];
    return directories;
}

// Removes the storage an extension of a clip keeps in the process's directories.
static void removeExtensionStorage(NSString *clipOrigin)
{
    for (NSString *storage in indexedDatabaseDirectories([WCExtensionRuntime indexedDatabaseDirectory], clipOrigin))
        [[NSFileManager defaultManager] removeItemAtPath:storage error:nil];
    WCRemoveExtensionWebSQLDatabases(clipOrigin);
    [[NSFileManager defaultManager] removeItemAtPath:[[WCExtensionRuntime localStorageDirectory] stringByAppendingPathComponent:[clipOrigin stringByAppendingPathExtension:@"localstorage"]] error:nil];
}

static BOOL copyExtensions(NSString *directory, NSString *clipIdentifier, NSMutableArray<NSString *> *clipOrigins)
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *archives = libraryPath(@"Safari/Extensions");
    NSString *bundles = libraryPath(@"Caches/com.apple.Safari/Extensions");
    NSString *safariLocalStorage = libraryPath(@"Safari/LocalStorage");
    NSString *safariDatabases = libraryPath(@"Safari/Databases");
    NSString *localStorage = [WCExtensionRuntime localStorageDirectory];
    NSString *indexedDatabases = [WCExtensionRuntime indexedDatabaseDirectory];
    if (![fileManager createDirectoryAtPath:[directory stringByAppendingPathComponent:@"Extensions"] withIntermediateDirectories:YES attributes:nil error:nil]
        || ![fileManager createDirectoryAtPath:localStorage withIntermediateDirectories:YES attributes:nil error:nil])
        return NO;

    CFPreferencesAppSynchronize(CFSTR("com.apple.Safari"));
    CFPreferencesAppSynchronize(CFSTR("com.apple.Safari.Extensions"));
    NSMutableArray *manifest = [NSMutableArray array];
    NSMutableDictionary *settings = [NSMutableDictionary dictionary];
    // Safari runs no extension while its Extensions preference, on by default, is off.
    Boolean hasExtensionsEnabled = false;
    BOOL extensionsEnabled = CFPreferencesGetAppBooleanValue(CFSTR("ExtensionsEnabled"), CFSTR("com.apple.Safari"), &hasExtensionsEnabled) || !hasExtensionsEnabled;
    NSDictionary *installed = extensionsEnabled ? [NSDictionary dictionaryWithContentsOfFile:[archives stringByAppendingPathComponent:@"Extensions.plist"]] : nil;
    NSArray *entries = installed[@"Installed Extensions"];
    for (NSDictionary *entry in [entries isKindOfClass:[NSArray class]] ? entries : @[ ]) {
        if (![entry isKindOfClass:[NSDictionary class]] || ![entry[@"Enabled"] isKindOfClass:[NSNumber class]] || ![entry[@"Enabled"] boolValue])
            continue;
        NSString *archiveName = entry[@"Archive File Name"];
        NSString *bundleName = entry[@"Bundle Directory Name"];
        if (![archiveName isKindOfClass:[NSString class]] || ![bundleName isKindOfClass:[NSString class]])
            continue;
        NSString *bundle = [bundles stringByAppendingPathComponent:bundleName];
        NSString *bundleIdentifier = [NSDictionary dictionaryWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Info.plist"]][@"CFBundleIdentifier"];
        NSString *developerIdentifier = developerIdentifierOfArchive([archives stringByAppendingPathComponent:archiveName]);
        if (![bundleIdentifier isKindOfClass:[NSString class]] || !developerIdentifier)
            continue;
        NSString *key = [NSString stringWithFormat:@"%@-%@", bundleIdentifier, developerIdentifier];
        if (![fileManager copyItemAtPath:bundle toPath:[[directory stringByAppendingPathComponent:@"Extensions"] stringByAppendingPathComponent:key] error:nil])
            return NO;
        [manifest addObject:@{ @"Key": key }];

        id extensionSettings = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)[@"ExtensionSettings-" stringByAppendingString:key], CFSTR("com.apple.Safari.Extensions")));
        settings[key] = @{ @"Settings": [extensionSettings isKindOfClass:[NSDictionary class]] ? extensionSettings : @{ } };

        // The clip's copy keeps the storage under the origin the extension has in the clip.
        NSString *origin = originIdentifier(key);
        NSString *clipOrigin = originIdentifier([WCExtensionRuntime extensionKey:key ofClip:clipIdentifier]);
        [clipOrigins addObject:clipOrigin];
        NSString *localStorageFile = [origin stringByAppendingPathExtension:@"localstorage"];
        if ([fileManager fileExistsAtPath:[safariLocalStorage stringByAppendingPathComponent:localStorageFile]]
            && !WCCopySQLiteDatabase([safariLocalStorage stringByAppendingPathComponent:localStorageFile], [localStorage stringByAppendingPathComponent:[clipOrigin stringByAppendingPathExtension:@"localstorage"]]))
            return NO;
        for (NSString *source in indexedDatabaseDirectories([safariDatabases stringByAppendingPathComponent:@"___IndexedDB"], origin)) {
            if (![fileManager fileExistsAtPath:source])
                continue;
            NSString *destination = [[indexedDatabases stringByAppendingPathComponent:source.stringByDeletingLastPathComponent.lastPathComponent] stringByAppendingPathComponent:clipOrigin];
            [fileManager removeItemAtPath:destination error:nil];
            if (!copyStorageDirectory(source, destination))
                return NO;
        }
        if (!WCCopyExtensionWebSQLDatabases(safariDatabases, origin, clipOrigin))
            return NO;
    }
    return [settings writeToFile:[directory stringByAppendingPathComponent:@"Settings.plist"] atomically:YES]
        && [manifest writeToFile:[directory stringByAppendingPathComponent:@"Extensions.plist"] atomically:YES];
}

BOOL WCCopySafariExtensions(NSString *directory, NSString *clipIdentifier)
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *partial = [directory stringByAppendingPathExtension:@"partial"];
    [fileManager removeItemAtPath:partial error:nil];
    [fileManager removeItemAtPath:directory error:nil];
    NSMutableArray *clipOrigins = [NSMutableArray array];
    if (!copyExtensions(partial, clipIdentifier, clipOrigins) || ![fileManager moveItemAtPath:partial toPath:directory error:nil]) {
        for (NSString *clipOrigin in clipOrigins)
            removeExtensionStorage(clipOrigin);
        [fileManager removeItemAtPath:partial error:nil];
        return NO;
    }
    return YES;
}

void WCRemoveSafariExtensions(NSString *directory, NSString *clipIdentifier)
{
    NSArray *manifest = [NSArray arrayWithContentsOfFile:[directory stringByAppendingPathComponent:@"Extensions.plist"]];
    for (NSDictionary *entry in manifest) {
        NSString *key = [entry isKindOfClass:[NSDictionary class]] ? entry[@"Key"] : nil;
        if (![key isKindOfClass:[NSString class]])
            continue;
        NSString *keyInClip = [WCExtensionRuntime extensionKey:key ofClip:clipIdentifier];
        WebSecurityOrigin *origin = [[WebSecurityOrigin alloc] initWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"safari-extension://%@", keyInClip]]];
        [[WebStorageManager sharedWebStorageManager] deleteOrigin:origin];
        removeExtensionStorage(originIdentifier(keyInClip));
    }
    [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
}
