// See WidevineCdmInstaller.h.

#import "config.h"
#import "WidevineCdmInstaller.h"

#if PLATFORM(MAC) && ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)

#import "WidevineCdmArchive.h"
#import "WidevineCdmImage.h"
#import <CommonCrypto/CommonDigest.h>
#import <errno.h>
#import <signal.h>
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

static std::optional<ManifestEntry> fetchManifest()
{
    // The service answers per product and version, and these coordinates are Firefox's own: the
    // Widevine CDM reaches Firefox as a Gecko Media Plugin, and this is where it asks for it.
    struct utsname system { };
    uname(&system);
    auto url = makeString("https://aus5.mozilla.org/update/3/GMP/140.0/20260101000000/Darwin_x86_64-gcc3/en-US/release/Darwin%20"_s,
        String::fromUTF8(system.release), "/default/default/update.xml"_s);

    RetainPtr document = fetch(url, 30);
    if (!document) {
        WTFLogAlways("Widevine: the update service did not answer");
        return std::nullopt;
    }

    RetainPtr parser = adoptNS([[NSXMLParser alloc] initWithData:document.get()]);
    RetainPtr delegate = adoptNS([[WebCoreWidevineManifestParser alloc] init]);
    [parser setDelegate:delegate.get()];
    [parser parse];

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

static std::optional<WidevineCdmModule> installedModule(const String& root, const String& version)
{
    auto directory = FileSystem::pathByAppendingComponent(root, version);
    auto path = FileSystem::pathByAppendingComponent(directory, moduleFileName);
    if (!FileSystem::fileExists(path) || !FileSystem::fileExists(FileSystem::pathByAppendingComponent(directory, gapLibraryFileName)))
        return std::nullopt;
    return WidevineCdmModule { directory, path, version };
}

// A staging or replaced directory is named after the process using it, so one whose process is
// gone belongs to an install that did not finish.
static bool processIsRunning(StringView pid)
{
    auto identifier = parseInteger<int>(pid);
    if (!identifier || *identifier <= 0)
        return false;
    return !kill(*identifier, 0) || errno == EPERM;
}

// A directory in the installation root is a version of the module only if it is named like one.
// Anything else there -- a staging directory, something a user dropped in -- is not a version and
// is neither chosen nor removed.
static bool isVersionName(const String& name)
{
    auto components = name.split('.');
    if (components.isEmpty())
        return false;
    for (auto& component : components) {
        if (component.isEmpty() || !parseInteger<uint64_t>(component))
            return false;
    }
    return true;
}

// Versions are dotted numbers, so they are ordered by component rather than by text: 4.10 follows
// 4.9. An installation normally leaves one behind, and this is what picks among the rest when a
// cleanup did not finish.
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

static std::optional<WidevineCdmModule> newestInstalledModule(const String& root)
{
    std::optional<WidevineCdmModule> newest;
    for (auto& name : FileSystem::listDirectory(root)) {
        if (!isVersionName(name))
            continue;
        auto module = installedModule(root, name);
        if (module && (!newest || isNewerVersion(module->version, newest->version)))
            newest = WTF::move(module);
    }
    return newest;
}

// |versionInUse| is a module this installer has already answered with, which stays where it is
// however old it becomes: it is opened when a page reaches EME, which can be long after this
// runs.
static std::optional<WidevineCdmModule> install(const String& root, const ManifestEntry& manifest, const String& versionInUse)
{
    WTFLogAlways("Widevine: fetching module %s", manifest.version.utf8().data());
    RetainPtr archive = fetch(manifest.url, 600);
    if (!archive) {
        WTFLogAlways("Widevine: the module did not download");
        return std::nullopt;
    }

    auto archiveBytes = span(archive.get());
    if (!matchesDigest(archiveBytes, manifest.sha512)) {
        WTFLogAlways("Widevine: the module does not match the digest the update service published");
        return std::nullopt;
    }

    auto module = extractWidevineCdmModule(archiveBytes);
    archive = nullptr;
    if (!module) {
        WTFLogAlways("Widevine: %s", module.error().utf8().data());
        return std::nullopt;
    }
    auto image = WTF::move(module.value());

    auto prepared = prepareWidevineCdmImage(image, gapLibraryLoadPath, gapLibrarySourcePath());
    if (!prepared) {
        WTFLogAlways("Widevine: the module cannot run on this system -- %s", prepared.error().utf8().data());
        return std::nullopt;
    }

    auto gapLibrary = FileSystem::readEntireFile(gapLibrarySourcePath());
    if (!gapLibrary) {
        WTFLogAlways("Widevine: the gap library is missing from %s", gapLibrarySourcePath().utf8().data());
        return std::nullopt;
    }

    // The installation is assembled beside the directory it will occupy and moved into place
    // whole, so a half-written one is never something a loading process can find.
    auto staging = makeString(root, "/.staging-"_s, getCurrentProcessID());
    FileSystem::deleteNonEmptyDirectory(staging);
    if (!FileSystem::makeAllDirectories(staging))
        return std::nullopt;
    auto removeStaging = makeScopeExit([&] { FileSystem::deleteNonEmptyDirectory(staging); });

    if (!FileSystem::overwriteEntireFile(FileSystem::pathByAppendingComponent(staging, moduleFileName), image.span())
        || !FileSystem::overwriteEntireFile(FileSystem::pathByAppendingComponent(staging, gapLibraryFileName), gapLibrary->span())) {
        WTFLogAlways("Widevine: the module could not be written to %s", staging.utf8().data());
        return std::nullopt;
    }

    // What is installed is given up only once its replacement is in place: it moves aside, and
    // back again if the replacement cannot be moved in, so the version that is opened is
    // whichever module is complete.
    auto directory = FileSystem::pathByAppendingComponent(root, manifest.version);
    auto displaced = makeString(root, "/.replaced-"_s, getCurrentProcessID());
    FileSystem::deleteNonEmptyDirectory(displaced);
    bool displacedPrevious = FileSystem::moveFile(directory, displaced);
    auto removeDisplaced = makeScopeExit([&] {
        if (displacedPrevious)
            FileSystem::deleteNonEmptyDirectory(displaced);
    });

    if (!FileSystem::moveFile(staging, directory)) {
        WTFLogAlways("Widevine: the module could not be moved into %s", directory.utf8().data());
        if (displacedPrevious) {
            // Whether or not the restore takes, this is the only complete copy left, so it is not
            // deleted on the way out: a restore that failed leaves it under a name a later
            // process collects once this one is gone.
            FileSystem::moveFile(displaced, directory);
            displacedPrevious = false;
        }
        return std::nullopt;
    }

    // An update takes the versions it replaces with it, along with anything a process that died
    // mid-install left behind. A staging or replaced directory this process is using is named
    // after its own pid, and another WebKit process may be using one beside it.
    auto ownStagingName = makeString(".staging-"_s, getCurrentProcessID());
    auto ownDisplacedName = makeString(".replaced-"_s, getCurrentProcessID());
    for (auto& name : FileSystem::listDirectory(root)) {
        bool isVersion = isVersionName(name) && name != manifest.version && name != versionInUse;
        bool isAbandoned = (name.startsWith(".staging-"_s) || name.startsWith(".replaced-"_s))
            && name != ownStagingName && name != ownDisplacedName
            && !processIsRunning(name.substring(name.reverseFind('-') + 1));
        if (isVersion || isAbandoned)
            FileSystem::deleteNonEmptyDirectory(FileSystem::pathByAppendingComponent(root, name));
    }
    WTFLogAlways("Widevine: installed module %s", manifest.version.utf8().data());
    return installedModule(root, manifest.version);
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

        // What is installed answers the page, which is what keeps a page that wants Widevine from
        // waiting on the network at all. Google replaces the module from time to time, so the
        // update service is then asked once per process and a newer module installed for the next
        // launch -- the one already answered with is mapped by then.
        auto installed = newestInstalledModule(root);
        if (installed) {
            auto version = installed->version;
            answer(WTF::move(installed));
            auto manifest = fetchManifest();
            if (manifest && manifest->version != version)
                install(root, *manifest, version);
            return;
        }

        auto manifest = fetchManifest();
        answer(manifest ? install(root, *manifest, { }) : std::nullopt);
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
