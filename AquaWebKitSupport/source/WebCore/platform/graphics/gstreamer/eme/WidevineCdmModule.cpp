// See WidevineCdmModule.h.

#include "config.h"
#include "WidevineCdmModule.h"

#if ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)

#include "WidevineCdmLocation.h"
#include "WidevineHostFiles.h"

#include <CoreGraphics/CoreGraphics.h>
#include <IOKit/IOKitLib.h>
#include <cdm/content_decryption_module_ext.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <pal/crypto/CryptoDigest.h>
#include <sys/file.h>
#include <sys/time.h>
#include <wtf/ASCIICType.h>
#include <wtf/FileSystem.h>
#include <wtf/MainThread.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/RetainPtr.h>
#include <wtf/RunLoop.h>
#include <wtf/Scope.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/text/CString.h>

namespace WebCore {

static constexpr auto widevineKeySystemName = "com.widevine.alpha"_s;

static String& modulePathStorage()
{
    static NeverDestroyed<String> path;
    return path;
}

const String& widevineCdmModulePath()
{
    ASSERT(isMainThread());
    return modulePathStorage();
}

void setWidevineCdmModulePath(const String& path)
{
    ASSERT(isMainThread());
    modulePathStorage() = path;
}

namespace {

using InitializeCdmModuleFunction = void (*)();
using CreateCdmInstanceFunction = void* (*)(int cdmInterfaceVersion, const char* keySystem, uint32_t keySystemSize,
    void* (*getCdmHostFunction)(int, void*), void* userData);

struct CdmModule {
    void* handle { nullptr };
    int leaseFD { -1 };
    CreateCdmInstanceFunction createInstance { nullptr };
    std::array<CString, 4> verificationPaths;
    Vector<cdm::HostFile> hostFiles;
};

// InitializeCdmModule() is per-module, so the library is loaded and initialized once
// and every CDM instance is created from it.
static const CdmModule& cdmModule()
{
    static NeverDestroyed<CdmModule> module = [] {
        CdmModule module;
        auto path = widevineCdmModulePath();
        if (path.isEmpty())
            return module;

        auto directory = FileSystem::parentPath(path);
        module.leaseFD = open(FileSystem::pathByAppendingComponent(directory, ".lease"_s).utf8().data(), O_RDONLY | O_CLOEXEC);
        if (module.leaseFD < 0 || flock(module.leaseFD, LOCK_SH | LOCK_NB)) {
            if (module.leaseFD >= 0)
                close(module.leaseFD);
            module.leaseFD = -1;
            WTFLogAlways("Widevine: cannot retain the installed generation");
            return module;
        }
        module.handle = dlopen(path.utf8().data(), RTLD_NOW | RTLD_LOCAL);
        if (!module.handle) {
            WTFLogAlways("Widevine: cannot load %s: %s", path.utf8().data(), dlerror());
            return module;
        }

        auto initialize = reinterpret_cast<InitializeCdmModuleFunction>(dlsym(module.handle, "InitializeCdmModule_4"));
        auto createInstance = reinterpret_cast<CreateCdmInstanceFunction>(dlsym(module.handle, "CreateCdmInstance"));
        auto verify = reinterpret_cast<decltype(&VerifyCdmHost_0)>(dlsym(module.handle, "VerifyCdmHost_0"));
        using SetHostPaths = int (*)(const char*, const char*, const void*, const void*);
        auto setHostPaths = reinterpret_cast<SetHostPaths>(dlsym(module.handle, "WidevineSetHostPaths"));
        if (!initialize || !createInstance || !verify || !setHostPaths) {
            WTFLogAlways("Widevine: %s does not export the CDM module entry points", path.utf8().data());
            dlclose(module.handle);
            module.handle = nullptr;
            module.createInstance = nullptr;
            return module;
        }

        std::array<WidevineHostFileNames, 4> names {
            WidevineHostFileNames { widevineOriginalName, widevineSignatureName },
            firefoxHostFiles[0], firefoxHostFiles[1], firefoxHostFiles[2]
        };
        Vector<int> descriptors;
        bool transferred = false;
        auto closeFiles = makeScopeExit([&] {
            if (transferred)
                return;
            for (int descriptor : descriptors) {
                if (descriptor >= 0)
                    close(descriptor);
            }
        });
        for (size_t i = 0; i < names.size(); ++i) {
            module.verificationPaths[i] = FileSystem::pathByAppendingComponent(directory, names[i].image).utf8();
            auto signature = FileSystem::pathByAppendingComponent(directory, names[i].signature).utf8();
            int imageFD = open(module.verificationPaths[i].data(), O_RDONLY | O_CLOEXEC);
            int signatureFD = open(signature.data(), O_RDONLY | O_CLOEXEC);
            descriptors.append(imageFD);
            descriptors.append(signatureFD);
            module.hostFiles.append(cdm::HostFile { module.verificationPaths[i].data(), imageFD, signatureFD });
            if (imageFD < 0 || signatureFD < 0) {
                WTFLogAlways("Widevine: cannot open verification files for %s", module.verificationPaths[i].data());
                return module;
            }
        }
        if (!setHostPaths(module.verificationPaths[0].data(), module.verificationPaths[1].data(),
                reinterpret_cast<const void*>(initialize), reinterpret_cast<const void*>(&cdmModule))) {
            WTFLogAlways("Widevine: cannot configure CDM host paths");
            return module;
        }
        transferred = true;
        if (!verify(module.hostFiles.span().data(), module.hostFiles.size())) {
            WTFLogAlways("Widevine: host verification could not start");
            return module;
        }
        WTFLogAlways("Widevine: host verification started with %zu signed files", module.hostFiles.size());
        initialize();
        module.createInstance = createInstance;
        return module;
    }();
    return module;
}

// A cdm::Buffer backed by plain heap storage. The CDM allocates these through the host
// for decrypted output and destroys them when it is done.
class HeapBuffer final : public cdm::Buffer {
public:
    static HeapBuffer* create(uint32_t capacity) { return new HeapBuffer(capacity); }

    void Destroy() final { delete this; }
    uint32_t Capacity() const final { return static_cast<uint32_t>(m_data.size()); }
    uint8_t* Data() final { return m_data.mutableSpan().data(); }
    void SetSize(uint32_t size) final { m_size = std::min(size, Capacity()); }
    uint32_t Size() const final { return m_size; }

private:
    explicit HeapBuffer(uint32_t capacity)
        : m_data(capacity)
    {
    }
    ~HeapBuffer() final = default;

    Vector<uint8_t> m_data;
    uint32_t m_size { 0 };
};

// The CDM keeps state of its own -- one small record, opened by name. It goes in the origin's
// media-keys storage directory, which is where the rest of a key system's persistent data lives
// and what clearing a site's data removes. Every entry point into the CDM holds WidevineCdm's lock,
// so the callbacks the CDM makes back out of one hold it too, and the directory is reached only from
// there. The reference count is not: CreateFileIO() takes one on whichever thread the CDM is on, and
// a record drops its own on the main thread, so the count is atomic.
class RecordStore : public ThreadSafeRefCounted<RecordStore> {
public:
    static Ref<RecordStore> create() { return adoptRef(*new RecordStore); }

    void setDirectory(const String& directory) { m_directory = directory; }
    bool hasDirectory() const { return !m_directory.isEmpty(); }

    Vector<uint8_t> read(const String& name)
    {
        // A record that was never written reads back empty, which is what a first run is.
        auto contents = FileSystem::readEntireFile(FileSystem::pathByAppendingComponent(m_directory, name));
        return contents ? WTF::move(*contents) : Vector<uint8_t> { };
    }

    bool write(const String& name, std::span<const uint8_t> bytes)
    {
        return FileSystem::makeAllDirectories(m_directory)
            && FileSystem::overwriteEntireFile(FileSystem::pathByAppendingComponent(m_directory, name), bytes);
    }

private:
    String m_directory;
};

class DecryptedBlock final : public cdm::DecryptedBlock {
public:
    DecryptedBlock() = default;
    ~DecryptedBlock() final
    {
        if (m_buffer)
            m_buffer->Destroy();
    }

    void SetDecryptedBuffer(cdm::Buffer* buffer) final { m_buffer = buffer; }
    cdm::Buffer* DecryptedBuffer() final { return m_buffer; }
    void SetTimestamp(int64_t timestamp) final { m_timestamp = timestamp; }
    int64_t Timestamp() const final { return m_timestamp; }

private:
    cdm::Buffer* m_buffer { nullptr };
    int64_t m_timestamp { 0 };
};

} // namespace

// One record the CDM opens by name. The CDM calls these from whichever thread it is on -- Decrypt()
// and DecryptAndDecodeFrame() run on GStreamer streaming threads -- and the interface defines every
// FileIOClient response as asynchronous, so each call hops to the main thread and is answered there.
// Ordering carries the rest: the hops run in the order they were made, so the one Close() makes,
// which destroys the record, runs after every answer already queued from it.
class FileIORecord final : public cdm::FileIO {
public:
    FileIORecord(cdm::FileIOClient& client, Ref<RecordStore>&& store, const ThreadSafeWeakPtr<WidevineCdm>& owner)
        : m_client(client)
        , m_store(WTF::move(store))
        , m_owner(owner)
    {
    }

    // The name the CDM may ask for, as the interface defines it: letters, digits, '.', '_' and
    // '-', not opening with '_', and no longer than 256 characters. It reaches a file path here,
    // so it is checked rather than trusted.
    static bool isValidName(const String& name)
    {
        if (name.isEmpty() || name.length() > 256 || name[0] == '_' || name == "."_s || name == ".."_s)
            return false;
        for (auto character : StringView { name }.codeUnits()) {
            if (!isASCIIAlphanumeric(character) && character != '.' && character != '_' && character != '-')
                return false;
        }
        return true;
    }

    void Open(const char* name, uint32_t size) final
    {
        // The CDM owns these bytes for the length of the call only, so the name is copied out here
        // rather than on the main thread.
        answerOnMainThread([this, requested = String::fromUTF8(std::span { name, size }).isolatedCopy()] {
            bool isValid = isValidName(requested);
            m_name = isValid ? requested : String { };
            m_client.OnOpenComplete(isValid ? cdm::FileIOClient::Status::kSuccess : cdm::FileIOClient::Status::kError);
        });
    }

    void Read() final
    {
        answerOnMainThread([this] {
            if (m_name.isEmpty()) {
                m_client.OnReadComplete(cdm::FileIOClient::Status::kError, nullptr, 0);
                return;
            }
            // A record that was never written reads back empty, which is what a first run is.
            auto contents = m_store->read(m_name);
            m_client.OnReadComplete(cdm::FileIOClient::Status::kSuccess, contents.span().data(), contents.size());
        });
    }

    void Write(const uint8_t* data, uint32_t size) final
    {
        // Copied for the same reason the name above is: the write happens on a later turn, by which
        // time the CDM's buffer is its own again.
        answerOnMainThread([this, bytes = Vector<uint8_t> { std::span { data, data ? size : 0u } }] {
            bool written = !m_name.isEmpty() && m_store->write(m_name, bytes.span());
            m_client.OnWriteComplete(written ? cdm::FileIOClient::Status::kSuccess : cdm::FileIOClient::Status::kError);
        });
    }

    void Close() final
    {
        RunLoop::mainSingleton().dispatch([this] { delete this; });
    }

private:
    ~FileIORecord() final = default;

    // An answer re-enters the CDM, which is not internally synchronized and may be inside Decrypt()
    // on a streaming thread, so it goes out under the lock every other entry point here takes. A CDM
    // already torn down has no owner left to reach, and its answer is dropped.
    template<typename Answer> void answerOnMainThread(Answer&& answer)
    {
        RunLoop::mainSingleton().dispatch([owner = m_owner, answer = WTF::move(answer)]() mutable {
            RefPtr cdm = owner.get();
            if (!cdm)
                return;
            cdm->deliverFileIOAnswer([&] { answer(); });
        });
    }

    cdm::FileIOClient& m_client;
    const Ref<RecordStore> m_store;
    const ThreadSafeWeakPtr<WidevineCdm> m_owner;
    String m_name;
};

class WidevineCdm::Host final : public cdm::Host_11 {
public:
    Host() = default;

    // Weak: a callback can arrive while the CDM is being created (before this is set) or from
    // inside Destroy() while it is being torn down, and neither may take a strong reference.
    ThreadSafeWeakPtr<WidevineCdm> owner;
    WeakPtr<WidevineCdmClient> client;

    // Collected while a CDM call runs, then handed back to the caller. Anything the CDM
    // says outside a call goes to the client instead.
    WidevineCdmCallResult result;
    bool isInCall { false };
    bool isInitializing { false };

    // Each call is issued under its own promise id, which is how the CDM names the call it is
    // answering when the answer arrives after that call returned.
    uint32_t nextPromiseID { 1 };

    // The session the running call is for, as the CDM spells it; a create learns it from the
    // promise it resolves. An event naming any other session belongs to that session.
    CString callSessionID;

    uint32_t beginCall(CString&& sessionID = { })
    {
        result = { };
        result.promiseID = nextPromiseID++;
        callSessionID = WTF::move(sessionID);
        isInCall = true;
        return result.promiseID;
    }

    bool reportsForCurrentCall(const char* sessionID, uint32_t sessionIDSize) const
    {
        return isInCall && !callSessionID.isNull() && equalSpans(callSessionID.span(), std::span { sessionID, sessionIDSize });
    }

    // A promise settled while a call runs belongs to that call only if it was issued under that
    // call's id; one left pending by an earlier call can be settled from inside a later one.
    bool settlesCurrentCall(uint32_t promiseID) const { return isInCall && promiseID == result.promiseID; }

    // Where the CDM's own records go (see RecordStore), and whether it was told it may keep any.
    const Ref<RecordStore> records { RecordStore::create() };
    bool allowsPersistentState { false };

    cdm::Buffer* Allocate(uint32_t capacity) final { return HeapBuffer::create(capacity); }

    void SetTimer(int64_t delayMs, void* context) final
    {
        RunLoop::mainSingleton().dispatchAfter(Seconds::fromMilliseconds(delayMs), [owner = owner, context] {
            if (RefPtr cdm = owner.get())
                cdm->timerExpired(context);
        });
    }

    cdm::Time GetCurrentWallTime() final
    {
        struct timeval now { };
        gettimeofday(&now, nullptr);
        return now.tv_sec + now.tv_usec / 1000000.0;
    }

    // Initialize() is answered by this rather than by a promise, so it settles the call that is
    // initializing, or reaches the client when that call has already returned.
    void OnInitialized(bool success) final
    {
        if (isInCall && isInitializing) {
            result.succeeded = success;
            result.settled = true;
            return;
        }
        dispatchToClient([success](auto& client) {
            client.cdmInitialized(success);
        });
    }

    void OnResolveKeyStatusPromise(uint32_t promiseID, cdm::KeyStatus) final
    {
        OnResolvePromise(promiseID);
    }

    void OnResolveNewSessionPromise(uint32_t promiseID, const char* sessionID, uint32_t sessionIDSize) final
    {
        if (settlesCurrentCall(promiseID)) {
            callSessionID = CString(std::span { sessionID, sessionIDSize });
            result.sessionID = String::fromUTF8(std::span { sessionID, sessionIDSize });
            result.succeeded = true;
            result.settled = true;
            return;
        }
        dispatchToClient([promiseID, id = sessionIDString(sessionID, sessionIDSize)](auto& client) {
            client.cdmSessionCreated(promiseID, id);
        });
    }

    void OnResolvePromise(uint32_t promiseID) final
    {
        if (settlesCurrentCall(promiseID)) {
            result.succeeded = true;
            result.settled = true;
            return;
        }
        dispatchToClient([promiseID](auto& client) {
            client.cdmPromiseResolved(promiseID);
        });
    }

    void OnRejectPromise(uint32_t promiseID, cdm::Exception, uint32_t, const char* errorMessage, uint32_t errorMessageSize) final
    {
        if (settlesCurrentCall(promiseID)) {
            result.succeeded = false;
            result.settled = true;
            result.errorMessage = String::fromUTF8(std::span { errorMessage, errorMessageSize });
            return;
        }
        dispatchToClient([promiseID](auto& client) {
            client.cdmPromiseRejected(promiseID);
        });
    }

    void OnSessionMessage(const char* sessionID, uint32_t sessionIDSize, cdm::MessageType messageType, const char* message, uint32_t messageSize) final
    {
        Vector<uint8_t> bytes { std::span { reinterpret_cast<const uint8_t*>(message), messageSize } };
        if (reportsForCurrentCall(sessionID, sessionIDSize)) {
            result.messages.append({ messageType, WTF::move(bytes) });
            return;
        }
        dispatchToClient([id = sessionIDString(sessionID, sessionIDSize), messageType, bytes = WTF::move(bytes)](auto& client) mutable {
            client.cdmSessionMessage(id, messageType, WTF::move(bytes));
        });
    }

    void OnSessionKeysChange(const char* sessionID, uint32_t sessionIDSize, bool hasAdditionalUsableKey, const cdm::KeyInformation* keysInfo, uint32_t keysInfoCount) final
    {
        Vector<WidevineKeyStatus> statuses;
        statuses.reserveInitialCapacity(keysInfoCount);
        for (uint32_t i = 0; i < keysInfoCount; ++i) {
            auto keyID = std::span { keysInfo[i].key_id, keysInfo[i].key_id_size };
            statuses.append({ Vector<uint8_t>(keyID), keysInfo[i].status });
        }

        if (reportsForCurrentCall(sessionID, sessionIDSize)) {
            result.keyStatuses = WTF::move(statuses);
            result.hasAdditionalUsableKey = hasAdditionalUsableKey;
            return;
        }
        dispatchToClient([id = sessionIDString(sessionID, sessionIDSize), statuses = WTF::move(statuses)](auto& client) mutable {
            client.cdmSessionKeyStatusesChanged(id, WTF::move(statuses));
        });
    }

    void OnExpirationChange(const char* sessionID, uint32_t sessionIDSize, cdm::Time newExpiryTime) final
    {
        if (reportsForCurrentCall(sessionID, sessionIDSize)) {
            result.expirationTime = newExpiryTime;
            return;
        }
        dispatchToClient([id = sessionIDString(sessionID, sessionIDSize), newExpiryTime](auto& client) {
            client.cdmSessionExpirationChanged(id, newExpiryTime);
        });
    }

    void OnSessionClosed(const char* sessionID, uint32_t sessionIDSize) final
    {
        if (reportsForCurrentCall(sessionID, sessionIDSize)) {
            result.sessionClosed = true;
            return;
        }
        dispatchToClient([id = sessionIDString(sessionID, sessionIDSize)](auto& client) {
            client.cdmSessionClosed(id);
        });
    }

    // A machine with no platform key cannot sign a challenge; the API spells that failure as a
    // response whose every field is zero.
    void SendPlatformChallenge(const char*, uint32_t, const char*, uint32_t) final
    {
        RunLoop::mainSingleton().dispatch([owner = owner] {
            if (RefPtr cdm = owner.get())
                cdm->deliverPlatformChallengeResponse();
        });
    }

    void EnableOutputProtection(uint32_t) final { }

    void QueryOutputProtectionStatus() final
    {
        RunLoop::mainSingleton().dispatch([owner = owner] {
            if (RefPtr cdm = owner.get())
                cdm->deliverOutputProtectionStatus();
        });
    }

    void OnDeferredInitializationDone(cdm::StreamType, cdm::Status) final { }

    // The interface spells a CDM that may not persist as one whose CreateFileIO() fails, which is
    // also the answer when the origin has no storage directory to keep a record in. This is the one
    // host entry point that answers inline rather than on the main thread, because the interface
    // wants the record back from the call; what it reads was settled by initialize() before the CDM
    // could ask, and the record it hands over does its own work on the main thread.
    cdm::FileIO* CreateFileIO(cdm::FileIOClient* client) final
    {
        if (!client || !allowsPersistentState || !records->hasDirectory())
            return nullptr;
        return new FileIORecord(*client, records.copyRef(), owner);
    }

    void RequestStorageId(uint32_t version) final
    {
        RunLoop::mainSingleton().dispatch([owner = owner, version] {
            if (RefPtr cdm = owner.get())
                cdm->deliverStorageId(version);
        });
    }

    void ReportMetrics(cdm::MetricName, uint64_t) final { }

private:
    static String sessionIDString(const char* sessionID, uint32_t size)
    {
        return String::fromUTF8(std::span { sessionID, size }).isolatedCopy();
    }

    template<typename Callback> void dispatchToClient(Callback&& callback)
    {
        RunLoop::mainSingleton().dispatch([weakClient = client, callback = WTF::move(callback)]() mutable {
            if (auto* client = weakClient.get())
                callback(*client);
        });
    }
};

void* WidevineCdm::cdmHostForInterfaceVersion(int interfaceVersion, void* userData)
{
    if (interfaceVersion != cdm::Host_11::kVersion)
        return nullptr;
    return static_cast<cdm::Host_11*>(static_cast<Host*>(userData));
}

// Answered from the file's presence rather than by loading it: the module is a large mapping to
// take on for a question. Both callers -- CDMFactoryWidevine and CDMProxyWidevine -- run after the
// key system has been allowed, and allowing it is what installs the module and names it to this
// process (see WidevineCdmLocation.h), so the path this reads is already set. A module that is
// present but unusable surfaces as a failed createInstance() below, which rejects
// requestMediaKeySystemAccess().
bool WidevineCdm::isAvailable()
{
    auto& path = widevineCdmModulePath();
    return !path.isEmpty() && FileSystem::fileExists(path);
}

RefPtr<WidevineCdm> WidevineCdm::create()
{
    auto& module = cdmModule();
    if (!module.createInstance)
        return nullptr;

    auto host = makeUniqueWithoutFastMallocCheck<Host>();
    auto* instance = module.createInstance(cdm::ContentDecryptionModule_11::kVersion, widevineKeySystemName.characters(),
        widevineKeySystemName.length(), &WidevineCdm::cdmHostForInterfaceVersion, host.get());
    if (!instance)
        return nullptr;

    return adoptRef(*new WidevineCdm(*static_cast<cdm::ContentDecryptionModule_11*>(instance), WTF::move(host)));
}

WidevineCdm::WidevineCdm(cdm::ContentDecryptionModule_11& cdm, std::unique_ptr<Host>&& host)
    : m_cdm(&cdm)
    , m_host(WTF::move(host))
{
    m_host->owner = ThreadSafeWeakPtr<WidevineCdm> { *this };
}

void WidevineCdm::setClient(WeakPtr<WidevineCdmClient>&& client)
{
    Locker locker { m_lock };
    m_host->client = WTF::move(client);
}

bool WidevineCdm::setStorageDirectory(const String& directory)
{
    Locker locker { m_lock };
    m_host->records->setDirectory(directory);
    return m_host->records->hasDirectory();
}

void WidevineCdm::timerExpired(void* context)
{
    Locker locker { m_lock };
    m_cdm->TimerExpired(context);
}

// The link each active display is reached over. A built-in panel is an internal link; anything else
// this platform cannot name, so it is reported as unknown rather than guessed at -- the answer is a
// licence-policy input. No link carries a protection method here.
static uint32_t activeOutputLinkTypes()
{
    uint32_t displayCount = 0;
    if (CGGetActiveDisplayList(0, nullptr, &displayCount) != kCGErrorSuccess || !displayCount)
        return cdm::OutputLinkTypes::kLinkTypeUnknown;

    Vector<CGDirectDisplayID> displays(displayCount);
    if (CGGetActiveDisplayList(displayCount, displays.mutableSpan().data(), &displayCount) != kCGErrorSuccess)
        return cdm::OutputLinkTypes::kLinkTypeUnknown;

    uint32_t linkTypes = 0;
    for (uint32_t i = 0; i < displayCount; ++i)
        linkTypes |= CGDisplayIsBuiltin(displays[i]) ? cdm::OutputLinkTypes::kLinkTypeInternal : cdm::OutputLinkTypes::kLinkTypeUnknown;
    return linkTypes ? linkTypes : cdm::OutputLinkTypes::kLinkTypeUnknown;
}

void WidevineCdm::deliverOutputProtectionStatus()
{
    auto linkTypes = activeOutputLinkTypes();

    Locker locker { m_lock };
    m_cdm->OnQueryOutputProtectionStatus(cdm::QueryResult::kQuerySucceeded, linkTypes, cdm::OutputProtectionMethods::kProtectionNone);
}

// The machine this is running on, as the platform expert names it. It survives everything below the
// hardware, so it is the part of the storage id that does not travel when a profile is copied.
static String platformUUID()
{
    io_service_t platformExpert = IOServiceGetMatchingService(MACH_PORT_NULL, IOServiceMatching("IOPlatformExpertDevice"));
    if (!platformExpert)
        return { };
    auto uuid = adoptCF(static_cast<CFStringRef>(IORegistryEntryCreateCFProperty(platformExpert, CFSTR(kIOPlatformUUIDKey), kCFAllocatorDefault, 0)));
    IOObjectRelease(platformExpert);
    return uuid ? String { uuid.get() } : String { };
}

void WidevineCdm::setStorageIdSeed(const String& seed)
{
    Locker locker { m_lock };
    m_storageID = { };
    auto device = platformUUID();
    if (seed.isEmpty() || device.isEmpty())
        return;

    auto digest = PAL::Crypto::CryptoDigest::create(PAL::Crypto::CryptoDigest::Algorithm::SHA_256);
    auto deviceUTF8 = device.utf8();
    digest->addBytes(byteCast<uint8_t>(deviceUTF8.span()));
    auto seedUTF8 = seed.utf8();
    digest->addBytes(byteCast<uint8_t>(seedUTF8.span()));
    m_storageID = digest->computeHash();
}

// The storage id is what the CDM keys its own local secure storage with; the interface forbids it
// leaving the device, so it never reaches a licence server. Version 1 is the one the interface
// defines, and a request names a version or asks with 0 for the newest one on offer. It hashes the
// machine's platform UUID together with the origin's media-keys hash salt, so it is stable for as
// long as that origin's site data is, differs between origins, differs between machines, and goes
// away when that data is cleared. An origin with no salt has no storage id, which the interface
// spells as an empty answer, as it does a version it cannot supply.
void WidevineCdm::deliverStorageId(uint32_t version)
{
    Locker locker { m_lock };
    if (m_storageID.isEmpty() || (version && version != 1)) {
        m_cdm->OnStorageId(version, nullptr, 0);
        return;
    }

    m_cdm->OnStorageId(1, m_storageID.span().data(), m_storageID.size());
}

void WidevineCdm::deliverFileIOAnswer(Function<void()>&& answer)
{
    Locker locker { m_lock };
    answer();
}

void WidevineCdm::deliverPlatformChallengeResponse()
{
    cdm::PlatformChallengeResponse response { };

    Locker locker { m_lock };
    m_cdm->OnPlatformChallengeResponse(response);
}

WidevineCdm::~WidevineCdm()
{
    Locker locker { m_lock };
    // Destroy() can call back into the host; drop the routes out of it first so a late
    // callback is discarded rather than reaching a half-destroyed object.
    m_host->owner = nullptr;
    m_host->client = nullptr;
    m_cdm->Destroy();
}

WidevineCdmCallResult WidevineCdm::initialize(bool allowDistinctiveIdentifier, bool allowPersistentState)
{
    Locker locker { m_lock };
    m_host->beginCall();
    m_host->isInitializing = true;
    m_host->allowsPersistentState = allowPersistentState;
    auto leaveCall = makeScopeExit([&] {
        m_host->isInCall = false;
        m_host->isInitializing = false;
    });
    m_cdm->Initialize(allowDistinctiveIdentifier, allowPersistentState, false);
    return WTF::move(m_host->result);
}

WidevineCdmCallResult WidevineCdm::setServerCertificate(std::span<const uint8_t> certificate)
{
    Locker locker { m_lock };
    auto promiseID = m_host->beginCall();
    auto leaveCall = makeScopeExit([&] { m_host->isInCall = false; });
    m_cdm->SetServerCertificate(promiseID, certificate.data(), certificate.size());
    return WTF::move(m_host->result);
}

WidevineCdmCallResult WidevineCdm::createSessionAndGenerateRequest(cdm::SessionType sessionType, cdm::InitDataType initDataType, std::span<const uint8_t> initData)
{
    Locker locker { m_lock };
    auto promiseID = m_host->beginCall();
    auto leaveCall = makeScopeExit([&] { m_host->isInCall = false; });
    m_cdm->CreateSessionAndGenerateRequest(promiseID, sessionType, initDataType, initData.data(), initData.size());
    return WTF::move(m_host->result);
}

WidevineCdmCallResult WidevineCdm::updateSession(const String& sessionID, std::span<const uint8_t> response)
{
    auto sessionIDUTF8 = sessionID.utf8();

    Locker locker { m_lock };
    auto promiseID = m_host->beginCall(CString { sessionIDUTF8 });
    auto leaveCall = makeScopeExit([&] { m_host->isInCall = false; });
    m_cdm->UpdateSession(promiseID, sessionIDUTF8.data(), sessionIDUTF8.length(), response.data(), response.size());
    return WTF::move(m_host->result);
}

WidevineCdmCallResult WidevineCdm::closeSession(const String& sessionID)
{
    auto sessionIDUTF8 = sessionID.utf8();

    Locker locker { m_lock };
    auto promiseID = m_host->beginCall(CString { sessionIDUTF8 });
    auto leaveCall = makeScopeExit([&] { m_host->isInCall = false; });
    m_cdm->CloseSession(promiseID, sessionIDUTF8.data(), sessionIDUTF8.length());
    return WTF::move(m_host->result);
}

WidevineCdmCallResult WidevineCdm::removeSession(const String& sessionID)
{
    auto sessionIDUTF8 = sessionID.utf8();

    Locker locker { m_lock };
    auto promiseID = m_host->beginCall(CString { sessionIDUTF8 });
    auto leaveCall = makeScopeExit([&] { m_host->isInCall = false; });
    m_cdm->RemoveSession(promiseID, sessionIDUTF8.data(), sessionIDUTF8.length());
    return WTF::move(m_host->result);
}

WidevineVideoFrame::~WidevineVideoFrame()
{
    if (m_buffer)
        m_buffer->Destroy();
}

void WidevineVideoFrame::SetFormat(cdm::VideoFormat format) { m_format = format; }
cdm::VideoFormat WidevineVideoFrame::Format() const { return m_format; }
void WidevineVideoFrame::SetSize(cdm::Size size) { m_size = size; }
cdm::Size WidevineVideoFrame::Size() const { return m_size; }
cdm::Buffer* WidevineVideoFrame::FrameBuffer() { return m_buffer; }
void WidevineVideoFrame::SetTimestamp(int64_t timestamp) { m_timestamp = timestamp; }
int64_t WidevineVideoFrame::Timestamp() const { return m_timestamp; }

void WidevineVideoFrame::SetFrameBuffer(cdm::Buffer* buffer)
{
    if (m_buffer && m_buffer != buffer)
        m_buffer->Destroy();
    m_buffer = buffer;
}

static bool isKnownPlane(cdm::VideoPlane plane)
{
    return plane == cdm::kYPlane || plane == cdm::kUPlane || plane == cdm::kVPlane;
}

void WidevineVideoFrame::SetPlaneOffset(cdm::VideoPlane plane, uint32_t offset)
{
    if (isKnownPlane(plane))
        m_planeOffsets[plane] = offset;
}

uint32_t WidevineVideoFrame::PlaneOffset(cdm::VideoPlane plane)
{
    return isKnownPlane(plane) ? m_planeOffsets[plane] : 0;
}

void WidevineVideoFrame::SetStride(cdm::VideoPlane plane, uint32_t stride)
{
    if (isKnownPlane(plane))
        m_strides[plane] = stride;
}

uint32_t WidevineVideoFrame::Stride(cdm::VideoPlane plane)
{
    return isKnownPlane(plane) ? m_strides[plane] : 0;
}

std::span<const uint8_t> WidevineVideoFrame::plane(cdm::VideoPlane plane) const
{
    if (!m_buffer || !isKnownPlane(plane))
        return { };

    uint32_t offset = m_planeOffsets[plane];
    uint32_t rows = plane == cdm::kYPlane ? m_size.height : (m_size.height + 1) / 2;
    uint64_t length = static_cast<uint64_t>(m_strides[plane]) * rows;
    if (offset > m_buffer->Size() || length > m_buffer->Size() - offset)
        return { };

    return std::span { m_buffer->Data() + offset, static_cast<size_t>(length) };
}

cdm::Status WidevineCdm::initializeVideoDecoder(const cdm::VideoDecoderConfig_2& config)
{
    Locker locker { m_lock };
    return m_cdm->InitializeVideoDecoder(config);
}

void WidevineCdm::deinitializeVideoDecoder()
{
    Locker locker { m_lock };
    m_cdm->DeinitializeDecoder(cdm::kStreamTypeVideo);
}

void WidevineCdm::resetVideoDecoder()
{
    Locker locker { m_lock };
    m_cdm->ResetDecoder(cdm::kStreamTypeVideo);
}

cdm::Status WidevineCdm::decryptAndDecodeFrame(const cdm::InputBuffer_2& input, WidevineVideoFrame& frame)
{
    Locker locker { m_lock };
    return m_cdm->DecryptAndDecodeFrame(input, &frame);
}

cdm::Status WidevineCdm::decrypt(const cdm::InputBuffer_2& input, std::span<uint8_t> inOut)
{
    DecryptedBlock block;

    Locker locker { m_lock };
    auto status = m_cdm->Decrypt(input, &block);
    if (status != cdm::Status::kSuccess)
        return status;

    auto* decrypted = block.DecryptedBuffer();
    if (!decrypted || decrypted->Size() != inOut.size())
        return cdm::Status::kDecryptError;

    memcpySpan(inOut, std::span { decrypted->Data(), decrypted->Size() });
    return cdm::Status::kSuccess;
}

} // namespace WebCore

#endif // ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)
