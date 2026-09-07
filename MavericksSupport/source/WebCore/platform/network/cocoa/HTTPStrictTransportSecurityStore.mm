/* Copyright (C) 2026. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#import "config.h"
#import "HTTPStrictTransportSecurityStore.h"

// policy lookups read an in-memory snapshot loaded when the store is created; a serial WorkQueue carries event-driven cross-process refreshes and writes.
#import "HTTPParsers.h"
#import "FileMonitor.h"
#import "Logging.h"
#import <wtf/HashMap.h>
#import <Foundation/Foundation.h>
#import <sys/param.h>
#import <wtf/spi/darwin/SandboxSPI.h>
#import <wtf/FileSystem.h>
#import <wtf/FileHandle.h>
#import <wtf/TZoneMallocInlines.h>
#import <wtf/text/MakeString.h>
#import <wtf/text/StringBuilder.h>
#include <cmath>
#include <sys/stat.h>
#include <wtf/Deque.h>
#include <wtf/Lock.h>
#include <wtf/MainThread.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/WorkQueue.h>

namespace WebCore {
WTF_MAKE_TZONE_ALLOCATED_IMPL(HTTPStrictTransportSecurityStore);
String HTTPStrictTransportSecurityStore::defaultStorageDirectory(const String& baseDirectory)
{
    if (!baseDirectory.isEmpty())
        return FileSystem::pathByAppendingComponent(baseDirectory, "HSTS"_s);
    // Extracted from WebsiteDataStoreCocoa's cache directory policy, including its existing application/container identity rules.
    RetainPtr url = [[NSFileManager defaultManager] URLForDirectory:NSCachesDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:NO error:nil];
    RELEASE_ASSERT(url);
    std::array<char, MAXPATHLEN> container { };
    sandbox_container_path_for_pid(getpid(), container.data(), container.size());
    if (!container[0]) {
        RetainPtr<NSString> identifier = [NSBundle mainBundle].bundleIdentifier;
        RetainPtr<NSString> processName = [NSProcessInfo processInfo].processName;
        if ([identifier isEqualToString:@"com.apple.Safari"] && [processName isEqualToString:@"SafariForWebKitDevelopment"])
            identifier = WTF::move(processName);
        else if (!identifier)
            identifier = WTF::move(processName);
        url = [url URLByAppendingPathComponent:identifier.get() isDirectory:YES];
    }
    url = [[url URLByAppendingPathComponent:@"WebKit" isDirectory:YES] URLByAppendingPathComponent:@"HSTS" isDirectory:YES];
    return String(url.get().absoluteURL.path);
}
// The stored file and its monitors are reached under persistenceLock: by the creating thread for the
// initial load, and by the queue for every later refresh, write and for final destruction. The policies
// are a property list, which any thread can read, so a store answers from the stored policies as soon as
// it exists.
struct HTTPStrictTransportSecurityStore::State : std::enable_shared_from_this<State> {
    struct Mutation {
        enum class Kind { Set, Remove, RemoveModifiedSince };
        Kind kind;
        String host;
        Entry entry { };
        WallTime time;
        void apply(HashMap<String, Entry>& entries) const
        {
            switch (kind) {
            case Kind::Set: entries.set(host.isolatedCopy(), entry); break;
            case Kind::Remove: entries.remove(host); break;
            case Kind::RemoveModifiedSince: entries.removeIf([&](const auto& item) { return item.value.modified >= time; }); break;
            }
        }
    };
    struct FileVersion {
        ino_t inode { 0 };
        off_t size { 0 };
        timespec modified { };
        bool operator==(const FileVersion& other) const
        {
            return inode == other.inode && size == other.size && modified.tv_sec == other.modified.tv_sec && modified.tv_nsec == other.modified.tv_nsec;
        }
    };
    State(const String& directory, Ref<WorkQueue>&& queue)
        : directory(directory.isolatedCopy())
        , path(directory.isEmpty() ? emptyString() : FileSystem::pathByAppendingComponent(directory, "HSTS.plist"_s))
        , queue(WTF::move(queue))
    { }
    static FileVersion version(const String& path)
    {
        struct stat status { };
        if (stat(FileSystem::fileSystemRepresentation(path).data(), &status))
            return { };
        return { status.st_ino, status.st_size, status.st_mtimespec };
    }
    // Every owner of the directory shares one advisory lock file, which orders a writing owner's
    // read-modify-write against the others.
    FileSystem::FileHandle fileLock(FileSystem::FileLockMode mode) WTF_REQUIRES_LOCK(persistenceLock)
    {
        return FileSystem::openFile(makeString(path, ".lock"_s), FileSystem::FileOpenMode::ReadWrite, FileSystem::FileAccessPermission::User, mode);
    }
    void publish() WTF_REQUIRES_LOCK(persistenceLock)
    {
        Locker locker { memoryLock };
        entries.clear();
        for (auto& item : storedEntries)
            entries.set(item.key.isolatedCopy(), item.value);
        for (auto& mutation : pending)
            mutation.apply(entries);
    }
    void monitorFile(const String& file, std::unique_ptr<FileMonitor>& monitor) WTF_REQUIRES_LOCK(persistenceLock)
    {
        auto weak = weak_from_this();
        monitor = makeUnique<FileMonitor>(file, queue.copyRef(), [weak](FileMonitor::FileChangeType) {
            if (auto state = weak.lock())
                state->refresh();
        });
    }
    static HashMap<String, Entry> read(const String& path)
    {
        HashMap<String, Entry> policies;
        RetainPtr stored = [NSDictionary dictionaryWithContentsOfFile:path.createNSString().get()];
        for (NSString *host in stored.get()) {
            NSDictionary *policy = [stored.get() objectForKey:host];
            if (![host isKindOfClass:[NSString class]] || ![policy isKindOfClass:[NSDictionary class]])
                continue;
            NSNumber *expires = [policy objectForKey:@"expires"];
            NSNumber *modified = [policy objectForKey:@"modified"];
            if (![expires isKindOfClass:[NSNumber class]] || ![modified isKindOfClass:[NSNumber class]])
                continue;
            policies.set(String(host), Entry { WallTime::fromRawSeconds(expires.doubleValue), WallTime::fromRawSeconds(modified.doubleValue),
                static_cast<bool>([[policy objectForKey:@"subdomains"] boolValue]) });
        }
        return policies;
    }
    // A monitor exists only for a path that exists, and cancels itself when that path is removed. Each
    // pass watches the deepest part of the directory's path that is present -- the directory itself once
    // it is there, and the nearest ancestor until then, whose change is how the directory's arrival is
    // seen -- so a store built before the directory exists, and one whose directory is removed, both go
    // on observing it.
    void monitorDirectoryLocked() WTF_REQUIRES_LOCK(persistenceLock)
    {
        // Another owner can create the next level down between the walk and the attach, whose event the
        // monitor is not yet there to see, so the walk repeats until it agrees with what was attached.
        while (true) {
            auto present = directory;
            while (!present.isEmpty() && !FileSystem::fileExists(present)) {
                auto parent = FileSystem::parentPath(present);
                if (parent == present)
                    break;
                present = parent;
            }
            auto current = version(present);
            if (directoryMonitor && present == watchedDirectory && current.inode == directoryInode)
                return;
            directoryMonitor = nullptr;
            watchedDirectory = present;
            directoryInode = current.inode;
            if (!current.inode)
                return;
            monitorFile(present, directoryMonitor);
        }
    }
    void refreshLocked() WTF_REQUIRES_LOCK(persistenceLock)
    {
        monitorDirectoryLocked();
        auto current = version(path);
        if (observed && current == storedVersion)
            return;
        if (!observed || current.inode != storedVersion.inode) {
            storedMonitor = nullptr;
            if (current.inode)
                monitorFile(path, storedMonitor);
        }
        storedEntries = read(path);
        storedVersion = version(path);
        observed = true;
        publish();
    }
    void refresh()
    {
        // A reader sees whichever whole file is in place; the advisory lock orders a writer's
        // read-modify-write and is taken by write() alone.
        Locker locker { persistenceLock };
        refreshLocked();
    }
    // Runs on the creating thread, so a lookup on a freshly created store reads the stored policies.
    void initialize()
    {
        if (path.isEmpty())
            return;
        refresh();
    }
    void mutate(Mutation&& mutation)
    {
        ASSERT(isMainThread());
        {
            Locker locker { memoryLock };
            mutation.apply(entries);
            if (path.isEmpty())
                return;
            pending.append(WTF::move(mutation));
        }
        queue->dispatch([state = shared_from_this()] { state->write(); });
    }
    // A mutation leaves |pending| once the file holds it, so |entries| answers with it either way and
    // one pass persists everything this owner has queued.
    void write()
    {
        Locker locker { persistenceLock };
        if (!FileSystem::makeAllDirectories(directory)) {
            RELEASE_LOG_ERROR(Network, "Could not create the HTTP Strict Transport Security directory");
            return;
        }
        auto guard = fileLock(FileSystem::FileLockMode::Exclusive);
        if (!guard) {
            RELEASE_LOG_ERROR(Network, "Could not lock the HTTP Strict Transport Security policies for writing");
            return;
        }
        refreshLocked();
        while (true) {
            std::optional<Mutation> mutation;
            {
                Locker memoryLocker { memoryLock };
                if (pending.isEmpty())
                    break;
                mutation = pending.takeFirst();
            }
            mutation->apply(storedEntries);
        }
        RetainPtr policies = adoptNS([[NSMutableDictionary alloc] initWithCapacity:storedEntries.size()]);
        for (auto& policy : storedEntries) {
            [policies setObject:@{
                @"expires": @(policy.value.expires.secondsSinceEpoch().seconds()),
                @"modified": @(policy.value.modified.secondsSinceEpoch().seconds()),
                @"subdomains": @(policy.value.includeSubdomains)
            } forKey:policy.key.createNSString().get()];
        }
        // The replacement is atomic, so a reader sees the previous file or this one and never a partial.
        if (![policies writeToFile:path.createNSString().get() atomically:YES]) {
            RELEASE_LOG_ERROR(Network, "Could not write the HTTP Strict Transport Security policies");
            return;
        }
        // The atomic replacement gives the file a new identity, so its monitor is re-established.
        refreshLocked();
        publish();
    }
    const String directory;
    const String path;
    Ref<WorkQueue> queue;
    Lock memoryLock;
    HashMap<String, Entry> entries WTF_GUARDED_BY_LOCK(memoryLock);
    Deque<Mutation> pending WTF_GUARDED_BY_LOCK(memoryLock);
    Lock persistenceLock;
    HashMap<String, Entry> storedEntries WTF_GUARDED_BY_LOCK(persistenceLock);
    std::unique_ptr<FileMonitor> directoryMonitor WTF_GUARDED_BY_LOCK(persistenceLock);
    String watchedDirectory WTF_GUARDED_BY_LOCK(persistenceLock);
    ino_t directoryInode WTF_GUARDED_BY_LOCK(persistenceLock) { 0 };
    std::unique_ptr<FileMonitor> storedMonitor WTF_GUARDED_BY_LOCK(persistenceLock);
    FileVersion storedVersion WTF_GUARDED_BY_LOCK(persistenceLock);
    bool observed WTF_GUARDED_BY_LOCK(persistenceLock) { false };
};

HTTPStrictTransportSecurityStore::HTTPStrictTransportSecurityStore(const String& directory, Access access)
    : m_access(access)
{
    ASSERT(isMainThread());
    static NeverDestroyed<Ref<WorkQueue>> queue(WorkQueue::create("HSTS storage"_s));
    auto make = [&] {
        auto state = std::shared_ptr<State>(new State(directory, queue.get().copyRef()), [](State* state) {
            state->queue->dispatch([state] { delete state; });
        });
        state->initialize();
        return state;
    };
    // A directory with no policy file is per-instance; every owner of a stored directory in this
    // process shares one State, so a policy one owner records is the answer every other owner gives.
    if (directory.isEmpty()) {
        m_state = make();
        return;
    }
    static NeverDestroyed<HashMap<String, std::weak_ptr<State>>> shared;
    static NeverDestroyed<Lock> sharedLock;
    Locker locker { sharedLock.get() };
    auto& slot = shared.get().add(directory, std::weak_ptr<State> { }).iterator->value;
    if (auto existing = slot.lock()) {
        m_state = WTF::move(existing);
        return;
    }
    m_state = make();
    slot = m_state;
}
HTTPStrictTransportSecurityStore::~HTTPStrictTransportSecurityStore() = default;

bool HTTPStrictTransportSecurityStore::shouldUpgrade(const URL& url) const
{
    if (!url.protocolIsInHTTPFamily() || url.host().isEmpty() || URL::hostIsIPAddress(url.host()))
        return false;
    Locker locker { m_state->memoryLock };
    auto host = url.host().toString().convertToASCIILowercase();
    bool subdomain = false;
    while (!host.isEmpty()) {
        auto found = m_state->entries.find(host);
        if (found != m_state->entries.end() && found->value.expires > WallTime::now() && (!subdomain || found->value.includeSubdomains))
            return true;
        auto dot = host.find('.');
        if (dot == notFound)
            break;
        host = host.substring(dot + 1);
        subdomain = true;
    }
    return false;
}

void HTTPStrictTransportSecurityStore::receiveHeader(const URL& url, const String& field)
{
    if (!url.protocolIs("https"_s) || url.host().isEmpty() || URL::hostIsIPAddress(url.host()))
        return;
    std::optional<double> maxAge;
    bool includeSubdomains = false;
    HashSet<String> names;
    unsigned position = 0;
    auto skipWhitespace = [&] { while (position < field.length() && (field[position] == ' ' || field[position] == '\t')) ++position; };
    // RFC 6797 permits empty directives and quoted extension values containing semicolons. Unescape values before applying each directive's grammar.
    while (position < field.length()) {
        skipWhitespace();
        if (position == field.length())
            break;
        if (field[position] == ';') {
            ++position;
            continue;
        }
        auto start = position;
        while (position < field.length() && field[position] != '=' && field[position] != ';' && field[position] != ' ' && field[position] != '\t')
            ++position;
        auto name = field.substring(start, position - start).convertToASCIILowercase();
        if (!isValidHTTPToken(name) || !names.add(name).isNewEntry)
            return;
        skipWhitespace();
        bool hasValue = position < field.length() && field[position] == '=';
        String value;
        if (hasValue) {
            ++position;
            skipWhitespace();
            if (position < field.length() && field[position] == '"') {
                ++position;
                StringBuilder unescaped;
                bool closed = false;
                while (position < field.length()) {
                    auto character = field[position++];
                    if (character == '"') {
                        closed = true;
                        break;
                    }
                    if (character == '\\') {
                        if (position == field.length())
                            return;
                        character = field[position++];
                    }
                    if ((character < 0x20 && character != '\t') || character == 0x7f || character > 0xff)
                        return;
                    unescaped.append(character);
                }
                if (!closed)
                    return;
                value = unescaped.toString();
            } else {
                auto valueStart = position;
                while (position < field.length() && field[position] != ';' && field[position] != ' ' && field[position] != '\t')
                    ++position;
                value = field.substring(valueStart, position - valueStart);
                if (!isValidHTTPToken(value))
                    return;
            }
            skipWhitespace();
        }
        if (position < field.length() && field[position] != ';')
            return;
        if (name == "max-age"_s) {
            if (!hasValue || value.isEmpty())
                return;
            double seconds = 0;
            for (auto character : StringView(value).codeUnits()) {
                if (!isASCIIDigit(character))
                    return;
                seconds = seconds * 10 + character - '0';
            }
            // The wire grammar places no size limit on delta-seconds. Infinity represents an expiration beyond the clock's range, rather than rejecting a valid policy.
            maxAge = seconds;
        } else if (name == "includesubdomains"_s) {
            if (hasValue)
                return;
            includeSubdomains = true;
        }
    }
    if (!maxAge)
        return;
    auto host = url.host().toString().convertToASCIILowercase();
    if (!*maxAge) {
        removeHost(host);
        return;
    }
    auto now = WallTime::now();
    Entry policy { now + Seconds(*maxAge), now, includeSubdomains };
    setEntry(host, policy);
}

void HTTPStrictTransportSecurityStore::setEntry(const String& host, const Entry& entry)
{
    if (m_access == Access::ReadOnly)
        return;
    m_state->mutate({ State::Mutation::Kind::Set, host.isolatedCopy(), entry, { } });
}

HashSet<String> HTTPStrictTransportSecurityStore::hosts() const
{
    HashSet<String> result;
    Locker locker { m_state->memoryLock };
    for (const auto& policy : m_state->entries) {
        if (policy.value.expires > WallTime::now())
            result.add(policy.key.isolatedCopy());
    }
    return result;
}

void HTTPStrictTransportSecurityStore::removeHost(const String& host)
{
    if (m_access == Access::ReadOnly)
        return;
    m_state->mutate({ State::Mutation::Kind::Remove, host.convertToASCIILowercase().isolatedCopy(), { }, { } });
}

void HTTPStrictTransportSecurityStore::removeModifiedSince(WallTime time)
{
    if (m_access == Access::ReadOnly)
        return;
    m_state->mutate({ State::Mutation::Kind::RemoveModifiedSince, { }, { }, time });
}
}

// The CFNetwork host query the polyfill layer answers from this store: one read-only view of the
// application's persistent policies, shared by every caller in the process.
extern "C" WEBCORE_EXPORT bool WebCoreIsKnownHSTSHost(CFURLRef url)
{
    static NeverDestroyed<WebCore::HTTPStrictTransportSecurityStore> store(WebCore::HTTPStrictTransportSecurityStore::defaultStorageDirectory(), WebCore::HTTPStrictTransportSecurityStore::Access::ReadOnly);
    return store->shouldUpgrade(URL(url));
}
