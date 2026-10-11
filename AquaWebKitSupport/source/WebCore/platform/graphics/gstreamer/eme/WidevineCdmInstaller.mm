// See WidevineCdmInstaller.h.

#import "config.h"
#import "WidevineCdmInstaller.h"

#if PLATFORM(MAC) && ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)

#import "WidevineCdmArchive.h"
#import "WidevineCdmImage.h"
#import "WidevineFirefoxArchive.h"
#import "WidevineHostFiles.h"
#import <CommonCrypto/CommonDigest.h>
#import <wtf/ASCIICType.h>
#import <errno.h>
#import <fcntl.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <sys/utsname.h>
#import <wtf/FileSystem.h>
#import <wtf/HexNumber.h>
#import <wtf/NeverDestroyed.h>
#import <wtf/OSObjectPtr.h>
#import <wtf/ProcessID.h>
#import <wtf/RunLoop.h>
#import <wtf/Scope.h>
#import <wtf/WorkQueue.h>
#import <wtf/cocoa/SpanCocoa.h>
#import <wtf/cocoa/TypeCastsCocoa.h>
#import <wtf/text/MakeString.h>
#import <wtf/text/StringBuilder.h>
#import <wtf/text/StringToIntegerConversion.h>

namespace WebCore {

class WidevineCdmLease {
public:
    explicit WidevineCdmLease(int descriptor) : m_descriptor(descriptor) { }
    ~WidevineCdmLease() { close(m_descriptor); }
private:
    int m_descriptor;
};

static std::shared_ptr<WidevineCdmLease> lockGeneration(const String& directory, int operation)
{
    auto path = FileSystem::pathByAppendingComponent(directory, ".lease"_s).utf8();
    int descriptor = open(path.data(), O_RDONLY | O_CLOEXEC);
    if (descriptor < 0)
        return nullptr;
    auto lease = std::make_shared<WidevineCdmLease>(descriptor);
    if (flock(descriptor, operation | LOCK_NB))
        return nullptr;
    // The name must still identify the inode locked by this process after a concurrent replacement.
    struct stat held, named;
    if (fstat(descriptor, &held) || stat(path.data(), &named)
        || held.st_dev != named.st_dev || held.st_ino != named.st_ino)
        return nullptr;
    return lease;
}

struct ManifestEntry {
    String url;
    String version;
    String sha512;
};

static constexpr auto moduleFileName = "libwidevinecdm.dylib"_s;
static constexpr auto gapLibraryFileName = "libwidevinegap.dylib"_s;
// How the module names the gap library, which is installed beside it.
static constexpr auto gapLibraryLoadPath = "@loader_path/libwidevinegap.dylib"_s;

} // namespace WebCore

// The update service answers with a document whose <addon> elements each name a plugin.
@interface WebCoreWidevineManifestParser : NSObject <NSXMLParserDelegate> {
@public
    WebCore::ManifestEntry entry;
}
@end

@implementation WebCoreWidevineManifestParser

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qualifiedName attributes:(NSDictionary *)attributes
{
    UNUSED_PARAM(parser);
    UNUSED_PARAM(namespaceURI);
    UNUSED_PARAM(qualifiedName);
    if (![elementName isEqualToString:@"addon"] || ![attributes[@"id"] isEqualToString:@"gmp-widevinecdm"] || ![attributes[@"hashFunction"] isEqualToString:@"sha512"])
        return;
    entry.url = String { dynamic_objc_cast<NSString>(attributes[@"URL"]) };
    entry.version = String { dynamic_objc_cast<NSString>(attributes[@"version"]) };
    entry.sha512 = String { dynamic_objc_cast<NSString>(attributes[@"hashValue"]) };
}

@end

namespace WebCore {

// ------------------------------------------------------------------------------------------
// Fetching

static RetainPtr<NSData> fetch(const String& url, NSTimeInterval timeout)
{
    RetainPtr nsURL = adoptNS([[NSURL alloc] initWithString:url.createNSString().get()]);
    if (!nsURL)
        return nullptr;
    RetainPtr request = adoptNS([[NSMutableURLRequest alloc] initWithURL:nsURL.get()]);
    [request setTimeoutInterval:timeout];

    __block RetainPtr<NSData> body;
    __block RetainPtr<NSURLResponse> response;
    auto finished = adoptOSObject(dispatch_semaphore_create(0));
    RetainPtr task = [[NSURLSession sharedSession] dataTaskWithRequest:request.get() completionHandler:^(NSData *data, NSURLResponse *taskResponse, NSError *error) {
        if (!error) {
            body = data;
            response = taskResponse;
        }
        dispatch_semaphore_signal(finished.get());
    }];
    [task resume];
    dispatch_semaphore_wait(finished.get(), DISPATCH_TIME_FOREVER);

    RetainPtr httpResponse = dynamic_objc_cast<NSHTTPURLResponse>(response.get());
    if (httpResponse && [httpResponse statusCode] != 200)
        return nullptr;
    return body;
}

static std::optional<ManifestEntry> fetchManifest(const String& firefoxVersion, const String& buildID)
{
    // The service answers per product and version, and these coordinates are Firefox's own: the
    // Widevine CDM reaches Firefox as a Gecko Media Plugin, and this is where it asks for it.
    struct utsname system { };
    uname(&system);
    auto url = makeString("https://aus5.mozilla.org/update/3/GMP/"_s, firefoxVersion, "/"_s, buildID, "/Darwin_x86_64-gcc3/en-US/release/Darwin%20"_s,
        String::fromUTF8(system.release), "/default/default/update.xml"_s);

    RetainPtr document = fetch(url, 30);
    if (!document) {
        WTFLogAlways("Widevine: the update service did not answer");
        return std::nullopt;
    }

    RetainPtr parser = adoptNS([[NSXMLParser alloc] initWithData:document.get()]);
    RetainPtr delegate = adoptNS([[WebCoreWidevineManifestParser alloc] init]);
    [parser setDelegate:delegate.get()];
    if (![parser parse])
        return std::nullopt;

    auto& entry = delegate->entry;
    if (entry.url.isEmpty() || entry.version.isEmpty() || entry.sha512.isEmpty()) {
        WTFLogAlways("Widevine: the update service named no module");
        return std::nullopt;
    }
    return entry;
}

static bool matchesDigest(std::span<const uint8_t> bytes, const String& expected)
{
    std::array<uint8_t, CC_SHA512_DIGEST_LENGTH> digest { };
    CC_SHA512(bytes.data(), bytes.size(), digest.data());

    StringBuilder builder;
    for (auto byte : digest)
        builder.append(hex(byte, 2, Lowercase));
    return equalIgnoringASCIICase(builder.toString(), expected);
}

// ------------------------------------------------------------------------------------------
// Installing

// One download under the user's library directory serves every WebKit application this user runs.
// A sandboxed application's search path answers with its container, so it keeps its own.
static String installationRoot()
{
    RetainPtr library = dynamic_objc_cast<NSString>([NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) firstObject]);
    if (!library)
        return { };
    return FileSystem::pathByAppendingComponent(FileSystem::pathByAppendingComponent(String { library.get() }, "WebKit"_s), "WidevineCdm"_s);
}

static String gapLibrarySourcePath()
{
    RetainPtr bundle = [NSBundle bundleForClass:NSClassFromString(@"WebCoreBundleFinder")];
    return FileSystem::pathByAppendingComponent(String { [bundle resourcePath] }, gapLibraryFileName);
}

static bool isVersionName(const String& name)
{
    if (name.isEmpty() || name.startsWith('.') || name.endsWith('.') || name.contains(".."_s))
        return false;
    for (auto& component : name.split('.')) {
        if (component.isEmpty() || !parseInteger<uint64_t>(component))
            return false;
    }
    return true;
}

static bool isNewerVersion(const String& version, const String& than)
{
    auto components = version.split('.');
    auto otherComponents = than.split('.');
    for (size_t i = 0; i < std::max(components.size(), otherComponents.size()); ++i) {
        auto component = i < components.size() ? parseInteger<uint64_t>(components[i]).value_or(0) : 0;
        auto otherComponent = i < otherComponents.size() ? parseInteger<uint64_t>(otherComponents[i]).value_or(0) : 0;
        if (component != otherComponent)
            return component > otherComponent;
    }
    return false;
}

static std::optional<ManifestEntry> fetchFirefoxRelease()
{
    auto data = fetch("https://product-details.mozilla.org/1.0/firefox_versions.json"_s, 30);
    if (!data)
        return std::nullopt;
    RetainPtr dictionary = dynamic_objc_cast<NSDictionary>([NSJSONSerialization JSONObjectWithData:data.get() options:0 error:nil]);
    String version { dynamic_objc_cast<NSString>([dictionary objectForKey:@"LATEST_FIREFOX_VERSION"]) };
    if (!isVersionName(version))
        return std::nullopt;
    auto base = makeString("https://archive.mozilla.org/pub/firefox/releases/"_s, version, "/"_s);
    auto checksums = fetch(makeString(base, "SHA512SUMS"_s), 30);
    if (!checksums)
        return std::nullopt;
    auto archivePath = makeString("update/mac/en-US/firefox-"_s, version, ".complete.mar"_s);
    auto text = String::fromUTF8(span(checksums.get()));
    for (auto& line : text.split('\n')) {
        if (line.length() == 130 + archivePath.length() && line.substring(128) == makeString("  "_s, archivePath))
            return ManifestEntry { makeString(base, archivePath), version, line.left(128) };
    }
    return std::nullopt;
}

static String firefoxBuildID(const String& directory)
{
    auto info = FileSystem::readEntireFile(FileSystem::pathByAppendingComponent(directory, firefoxApplicationInfo));
    if (!info)
        return { };
    for (auto& line : String::fromUTF8(info->span()).split('\n')) {
        if (line.startsWith("BuildID="_s)) {
            auto value = line.substring(8).trim(isASCIIWhitespace);
            if (value.length() == 14 && parseInteger<uint64_t>(value))
                return value;
        }
    }
    return { };
}

static std::optional<WidevineCdmModule> installedModule(const String& root, const String& name)
{
    auto versions = name.split('-');
    if (versions.size() != 2 || !isVersionName(versions[0]) || !isVersionName(versions[1]))
        return std::nullopt;
    auto directory = FileSystem::pathByAppendingComponent(root, name);
    auto lease = lockGeneration(directory, LOCK_SH);
    if (!lease)
        return std::nullopt;
    auto present = [&](ASCIILiteral file) {
        return FileSystem::fileSize(FileSystem::pathByAppendingComponent(directory, file)).value_or(0) > 0;
    };
    for (auto file : { moduleFileName, gapLibraryFileName, widevineOriginalName, widevineSignatureName, firefoxApplicationInfo, firefoxLicense }) {
        if (!present(file))
            return std::nullopt;
    }
    for (auto& file : firefoxHostFiles) {
        if (!present(file.image) || !present(file.signature))
            return std::nullopt;
    }
    if (firefoxBuildID(directory).isEmpty())
        return std::nullopt;
    return WidevineCdmModule { directory, FileSystem::pathByAppendingComponent(directory, moduleFileName), versions[0], versions[1], WTF::move(lease) };
}

static std::optional<WidevineCdmModule> newestInstalledModule(const String& root)
{
    std::optional<WidevineCdmModule> newest;
    for (auto& name : FileSystem::listDirectory(root)) {
        auto module = installedModule(root, name);
        if (module && (!newest || isNewerVersion(module->firefoxVersion, newest->firefoxVersion)
            || (module->firefoxVersion == newest->firefoxVersion && isNewerVersion(module->version, newest->version))))
            newest = WTF::move(module);
    }
    return newest;
}

static bool copyFirefoxFiles(const String& source, const String& destination)
{
    auto copy = [&](ASCIILiteral file) {
        auto target = FileSystem::pathByAppendingComponent(destination, file);
        return FileSystem::makeAllDirectories(FileSystem::parentPath(target))
            && FileSystem::hardLinkOrCopyFile(FileSystem::pathByAppendingComponent(source, file), target);
    };
    for (auto& file : firefoxHostFiles) {
        if (!copy(file.image) || !copy(file.signature))
            return false;
    }
    return copy(firefoxApplicationInfo) && copy(firefoxLicense);
}

static std::optional<WidevineCdmModule> install(const String& root, const ManifestEntry& firefox, const std::optional<WidevineCdmModule>& cached)
{
    auto staging = makeString(root, "/.staging-"_s, getCurrentProcessID());
    FileSystem::deleteNonEmptyDirectory(staging);
    if (!FileSystem::makeAllDirectories(staging))
        return std::nullopt;
    auto removeStaging = makeScopeExit([&] { FileSystem::deleteNonEmptyDirectory(staging); });

    if (cached && cached->firefoxVersion == firefox.version) {
        if (!copyFirefoxFiles(cached->directory, staging))
            return std::nullopt;
    } else {
        WTFLogAlways("Widevine: fetching Firefox %s verification files", firefox.version.utf8().data());
        auto archive = fetch(firefox.url, 600);
        if (!archive || !matchesDigest(span(archive.get()), firefox.sha512)) {
            WTFLogAlways("Widevine: Firefox download failed its release checksum");
            return std::nullopt;
        }
        auto extracted = extractWidevineFirefoxFiles(span(archive.get()), staging);
        if (!extracted) {
            WTFLogAlways("Widevine: %s", extracted.error().utf8().data());
            return std::nullopt;
        }
    }
    auto buildID = firefoxBuildID(staging);
    if (buildID.isEmpty())
        return std::nullopt;
    auto manifest = fetchManifest(firefox.version, buildID);
    if (!manifest || !isVersionName(manifest->version))
        return std::nullopt;
    auto name = makeString(manifest->version, "-"_s, firefox.version);
    if (auto existing = installedModule(root, name))
        return existing;

    WTFLogAlways("Widevine: fetching module %s for Firefox %s", manifest->version.utf8().data(), firefox.version.utf8().data());
    auto archive = fetch(manifest->url, 600);
    if (!archive || !matchesDigest(span(archive.get()), manifest->sha512)) {
        WTFLogAlways("Widevine: CDM download failed its update checksum");
        return std::nullopt;
    }
    auto module = extractWidevineCdmModule(span(archive.get()));
    archive = nullptr;
    if (!module) {
        WTFLogAlways("Widevine: %s", module.error().utf8().data());
        return std::nullopt;
    }
    auto write = [&](ASCIILiteral file, std::span<const uint8_t> bytes) {
        return FileSystem::overwriteEntireFile(FileSystem::pathByAppendingComponent(staging, file), bytes);
    };
    if (!write(widevineOriginalName, module->image.span()) || !write(widevineSignatureName, module->signature.span()))
        return std::nullopt;
    auto prepared = prepareWidevineCdmImage(module->image, gapLibraryLoadPath, gapLibrarySourcePath());
    if (!prepared) {
        WTFLogAlways("Widevine: the module cannot run on this system -- %s", prepared.error().utf8().data());
        return std::nullopt;
    }
    auto gapLibrary = FileSystem::readEntireFile(gapLibrarySourcePath());
    if (!gapLibrary || !write(moduleFileName, module->image.span()) || !write(gapLibraryFileName, gapLibrary->span()))
        return std::nullopt;
    auto notice = makeString("Firefox components are provided by Mozilla under the MPL 2.0 and the licenses in Contents/Resources/license.html.\nSource: https://archive.mozilla.org/pub/firefox/releases/"_s,
        firefox.version, "/source/firefox-"_s, firefox.version, ".source.tar.xz\n"_s).utf8();
    if (!write("NOTICE.txt"_s, byteCast<uint8_t>(notice.span())) || !write(".lease"_s, { }))
        return std::nullopt;

    // Immutable generations keep verification paths valid in every process that has received one.
    auto directory = FileSystem::pathByAppendingComponent(root, name);
    std::shared_ptr<WidevineCdmLease> replacedLease;
    if (FileSystem::fileExists(directory)) {
        replacedLease = lockGeneration(directory, LOCK_EX);
        if (!replacedLease || !FileSystem::deleteNonEmptyDirectory(directory))
            return std::nullopt;
    }
    if (!FileSystem::moveFile(staging, directory))
        return std::nullopt;
    WTFLogAlways("Widevine: installed CDM %s with Firefox %s", manifest->version.utf8().data(), firefox.version.utf8().data());
    return installedModule(root, name);
}

static void removeUnusedGenerations(const String& root)
{
    // UI processes hold a lease from provisioning through handoff; CDM processes hold theirs
    // for the lifetime of the module. flock releases a terminated process's leases as well.
    for (auto& name : FileSystem::listDirectory(root)) {
        auto versions = name.split('-');
        if (versions.size() != 2 || !isVersionName(versions[0]) || !isVersionName(versions[1]))
            continue;
        auto directory = FileSystem::pathByAppendingComponent(root, name);
        if (auto lease = lockGeneration(directory, LOCK_EX))
            FileSystem::deleteNonEmptyDirectory(directory);
    }
}

// ------------------------------------------------------------------------------------------

WidevineCdmInstaller& WidevineCdmInstaller::singleton()
{
    static NeverDestroyed<WidevineCdmInstaller> installer;
    return installer;
}

void WidevineCdmInstaller::ensureModule(CompletionHandler<void(const std::optional<WidevineCdmModule>&)>&& callback)
{
    ASSERT(RunLoop::isMain());
    if (m_hasProvisioned) {
        callback(m_module);
        return;
    }

    m_pendingCallbacks.append(WTF::move(callback));
    if (m_isProvisioning)
        return;
    m_isProvisioning = true;
    provision();
}

void WidevineCdmInstaller::provision()
{
    // The fetch, the retarget and the file work all belong off the main thread, and one queue for
    // the process keeps a second installation from running beside the first.
    static NeverDestroyed<Ref<WorkQueue>> queue = WorkQueue::create("WidevineCdmInstaller queue"_s);
    queue->get().dispatch([] {
        auto answer = [](std::optional<WidevineCdmModule>&& module) {
            RunLoop::mainSingleton().dispatch([module = WTF::move(module)]() mutable {
                WidevineCdmInstaller::singleton().finish(WTF::move(module));
            });
        };

        auto root = installationRoot();
        if (root.isEmpty() || !FileSystem::makeAllDirectories(root)) {
            answer(std::nullopt);
            return;
        }

        auto installed = newestInstalledModule(root);
        if (installed)
            answer(std::make_optional(*installed));
        int lockFD = open(FileSystem::pathByAppendingComponent(root, ".install-lock"_s).utf8().data(), O_CREAT | O_RDWR | O_CLOEXEC, 0600);
        auto unlock = makeScopeExit([&] { if (lockFD >= 0) close(lockFD); });
        if (lockFD < 0 || flock(lockFD, LOCK_EX)) {
            if (!installed)
                answer(std::nullopt);
            return;
        }
        for (auto& name : FileSystem::listDirectory(root)) {
            if (name.startsWith(".staging-"_s))
                FileSystem::deleteNonEmptyDirectory(FileSystem::pathByAppendingComponent(root, name));
        }
        auto cached = newestInstalledModule(root);
        if (!installed && cached) {
            installed = cached;
            answer(std::make_optional(*installed));
        }
        auto firefox = fetchFirefoxRelease();
        auto updated = firefox ? install(root, *firefox, cached) : std::nullopt;
        if (updated)
            removeUnusedGenerations(root);
        if (!installed)
            answer(WTF::move(updated));
    });
}

void WidevineCdmInstaller::finish(std::optional<WidevineCdmModule>&& module)
{
    ASSERT(RunLoop::isMain());
    m_module = WTF::move(module);
    m_isProvisioning = false;
    m_hasProvisioned = true;
    for (auto& callback : std::exchange(m_pendingCallbacks, { }))
        callback(m_module);
}

} // namespace WebCore

#endif // PLATFORM(MAC) && ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)
