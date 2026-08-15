// MAVERICKS_BACKPORT: see WidevineCdmModule.h.

#include "config.h"
#include "WidevineCdmModule.h"

#if ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)

#include "WidevineCdmLocation.h"

#include <dlfcn.h>
#include <sys/time.h>
#include <wtf/ASCIICType.h>
#include <wtf/FileSystem.h>
#include <wtf/MainThread.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/RunLoop.h>
#include <wtf/Scope.h>

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
    CreateCdmInstanceFunction createInstance { nullptr };
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

        module.handle = dlopen(path.utf8().data(), RTLD_NOW | RTLD_LOCAL);
        if (!module.handle) {
            WTFLogAlways("Widevine: cannot load %s: %s", path.utf8().data(), dlerror());
            return module;
        }

        auto initialize = reinterpret_cast<InitializeCdmModuleFunction>(dlsym(module.handle, "InitializeCdmModule_4"));
        module.createInstance = reinterpret_cast<CreateCdmInstanceFunction>(dlsym(module.handle, "CreateCdmInstance"));
        if (!initialize || !module.createInstance) {
            WTFLogAlways("Widevine: %s does not export the CDM module entry points", path.utf8().data());
            dlclose(module.handle);
            module.handle = nullptr;
            module.createInstance = nullptr;
            return module;
        }

        initialize();
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
// and what clearing a site's data removes.
class RecordStore : public RefCounted<RecordStore> {
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

class FileIORecord final : public cdm::FileIO {
public:
    FileIORecord(cdm::FileIOClient& client, Ref<RecordStore>&& store)
        : m_client(client)
        , m_store(WTF::move(store))
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
        m_name = String::fromUTF8(std::span { name, size });
        if (!isValidName(m_name)) {
            m_name = { };
            m_client.OnOpenComplete(cdm::FileIOClient::Status::kError);
            return;
        }
        m_client.OnOpenComplete(cdm::FileIOClient::Status::kSuccess);
    }

    void Read() final
    {
        if (m_name.isEmpty()) {
            m_client.OnReadComplete(cdm::FileIOClient::Status::kError, nullptr, 0);
            return;
        }
        auto contents = m_store->read(m_name);
        m_client.OnReadComplete(cdm::FileIOClient::Status::kSuccess, contents.span().data(), contents.size());
    }

    void Write(const uint8_t* data, uint32_t size) final
    {
        bool written = !m_name.isEmpty() && m_store->write(m_name, std::span { data, data ? size : 0u });
        m_client.OnWriteComplete(written ? cdm::FileIOClient::Status::kSuccess : cdm::FileIOClient::Status::kError);
    }

    void Close() final { delete this; }

private:
    ~FileIORecord() final = default;

    cdm::FileIOClient& m_client;
    const Ref<RecordStore> m_store;
    String m_name;
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

    void OnInitialized(bool success) final { result.succeeded = success; }

    void OnResolveKeyStatusPromise(uint32_t, cdm::KeyStatus) final { result.succeeded = true; }

    void OnResolveNewSessionPromise(uint32_t, const char* sessionID, uint32_t sessionIDSize) final
    {
        result.sessionID = String::fromUTF8(std::span { sessionID, sessionIDSize });
        result.succeeded = true;
    }

    void OnResolvePromise(uint32_t) final { result.succeeded = true; }

    void OnRejectPromise(uint32_t, cdm::Exception, uint32_t, const char* errorMessage, uint32_t errorMessageSize) final
    {
        result.succeeded = false;
        result.errorMessage = String::fromUTF8(std::span { errorMessage, errorMessageSize });
    }

    void OnSessionMessage(const char* sessionID, uint32_t sessionIDSize, cdm::MessageType messageType, const char* message, uint32_t messageSize) final
    {
        Vector<uint8_t> bytes { std::span { reinterpret_cast<const uint8_t*>(message), messageSize } };
        if (isInCall) {
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

        if (isInCall) {
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
        if (isInCall) {
            result.expirationTime = newExpiryTime;
            return;
        }
        dispatchToClient([id = sessionIDString(sessionID, sessionIDSize), newExpiryTime](auto& client) {
            client.cdmSessionExpirationChanged(id, newExpiryTime);
        });
    }

    void OnSessionClosed(const char* sessionID, uint32_t sessionIDSize) final
    {
        if (isInCall) {
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
    // also the answer when the origin has no storage directory to keep a record in.
    cdm::FileIO* CreateFileIO(cdm::FileIOClient* client) final
    {
        if (!client || !allowsPersistentState || !records->hasDirectory())
            return nullptr;
        return new FileIORecord(*client, records.copyRef());
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

// Answered from the file's presence rather than by loading it: this runs whenever a page asks
// whether the key system is supported, and the module is a large mapping to take on for a
// question. The UIProcess names the module to this process once it has installed it (see
// WidevineCdmLocation.h), so a first page to ask is answered no and the one after it yes. A module
// that is present but unusable surfaces as a failed createInstance() below, which rejects
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
    if (m_cdm)
        m_cdm->TimerExpired(context);
}

void WidevineCdm::deliverOutputProtectionStatus()
{
    Locker locker { m_lock };
    if (m_cdm)
        m_cdm->OnQueryOutputProtectionStatus(cdm::QueryResult::kQuerySucceeded, cdm::OutputLinkTypes::kLinkTypeInternal, cdm::OutputProtectionMethods::kProtectionNone);
}

void WidevineCdm::deliverStorageId(uint32_t version)
{
    Locker locker { m_lock };
    if (m_cdm)
        m_cdm->OnStorageId(version, nullptr, 0);
}

void WidevineCdm::deliverPlatformChallengeResponse()
{
    cdm::PlatformChallengeResponse response { };

    Locker locker { m_lock };
    if (m_cdm)
        m_cdm->OnPlatformChallengeResponse(response);
}

WidevineCdm::~WidevineCdm()
{
    Locker locker { m_lock };
    // Destroy() can call back into the host; drop the routes out of it first so a late
    // callback is discarded rather than reaching a half-destroyed object.
    m_host->owner = nullptr;
    m_host->client = nullptr;
    if (m_cdm)
        m_cdm->Destroy();
    m_cdm = nullptr;
}

bool WidevineCdm::initialize(bool allowDistinctiveIdentifier, bool allowPersistentState)
{
    Locker locker { m_lock };
    if (!m_cdm)
        return false;

    m_host->result = { };
    m_host->isInCall = true;
    m_host->allowsPersistentState = allowPersistentState;
    auto leaveCall = makeScopeExit([&] { m_host->isInCall = false; });
    m_cdm->Initialize(allowDistinctiveIdentifier, allowPersistentState, false);
    return m_host->result.succeeded;
}

WidevineCdmCallResult WidevineCdm::setServerCertificate(std::span<const uint8_t> certificate)
{
    Locker locker { m_lock };
    if (!m_cdm)
        return { };

    m_host->result = { };
    m_host->isInCall = true;
    auto leaveCall = makeScopeExit([&] { m_host->isInCall = false; });
    m_cdm->SetServerCertificate(0, certificate.data(), certificate.size());
    return WTF::move(m_host->result);
}

WidevineCdmCallResult WidevineCdm::createSessionAndGenerateRequest(cdm::SessionType sessionType, cdm::InitDataType initDataType, std::span<const uint8_t> initData)
{
    Locker locker { m_lock };
    if (!m_cdm)
        return { };

    m_host->result = { };
    m_host->isInCall = true;
    auto leaveCall = makeScopeExit([&] { m_host->isInCall = false; });
    m_cdm->CreateSessionAndGenerateRequest(0, sessionType, initDataType, initData.data(), initData.size());
    return WTF::move(m_host->result);
}

WidevineCdmCallResult WidevineCdm::updateSession(const String& sessionID, std::span<const uint8_t> response)
{
    auto sessionIDUTF8 = sessionID.utf8();

    Locker locker { m_lock };
    if (!m_cdm)
        return { };

    m_host->result = { };
    m_host->isInCall = true;
    auto leaveCall = makeScopeExit([&] { m_host->isInCall = false; });
    m_cdm->UpdateSession(0, sessionIDUTF8.data(), sessionIDUTF8.length(), response.data(), response.size());
    return WTF::move(m_host->result);
}

WidevineCdmCallResult WidevineCdm::closeSession(const String& sessionID)
{
    auto sessionIDUTF8 = sessionID.utf8();

    Locker locker { m_lock };
    if (!m_cdm)
        return { };

    m_host->result = { };
    m_host->isInCall = true;
    auto leaveCall = makeScopeExit([&] { m_host->isInCall = false; });
    m_cdm->CloseSession(0, sessionIDUTF8.data(), sessionIDUTF8.length());
    return WTF::move(m_host->result);
}

WidevineCdmCallResult WidevineCdm::removeSession(const String& sessionID)
{
    auto sessionIDUTF8 = sessionID.utf8();

    Locker locker { m_lock };
    if (!m_cdm)
        return { };

    m_host->result = { };
    m_host->isInCall = true;
    auto leaveCall = makeScopeExit([&] { m_host->isInCall = false; });
    m_cdm->RemoveSession(0, sessionIDUTF8.data(), sessionIDUTF8.length());
    return WTF::move(m_host->result);
}

cdm::Status WidevineCdm::decrypt(const cdm::InputBuffer_2& input, std::span<uint8_t> inOut)
{
    DecryptedBlock block;

    Locker locker { m_lock };
    if (!m_cdm)
        return cdm::Status::kDecryptError;

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
