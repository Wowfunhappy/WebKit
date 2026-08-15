// MAVERICKS_BACKPORT: see CDMWidevine.h.

#include "config.h"
#include "CDMWidevine.h"

#if ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)

#include "CDMKeySystemConfiguration.h"
#include "CDMProxyWidevine.h"
#include "CDMRestrictions.h"
#include "GStreamerEMEUtilities.h"
#include "InitDataRegistry.h"
#include "Logging.h"
#include "SharedBuffer.h"
#include <wtf/FileSystem.h>
#include <wtf/Hasher.h>
#include <wtf/MainThread.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/text/MakeString.h>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(CDMFactoryWidevine);
WTF_MAKE_TZONE_ALLOCATED_IMPL(CDMPrivateWidevine);
WTF_MAKE_TZONE_ALLOCATED_IMPL(CDMInstanceWidevine);

static CDMKeyStatus keyStatusFromCdmKeyStatus(cdm::KeyStatus status)
{
    switch (status) {
    case cdm::KeyStatus::kUsable:
        return CDMKeyStatus::Usable;
    case cdm::KeyStatus::kExpired:
        return CDMKeyStatus::Expired;
    case cdm::KeyStatus::kReleased:
        return CDMKeyStatus::Released;
    case cdm::KeyStatus::kOutputRestricted:
        return CDMKeyStatus::OutputRestricted;
    case cdm::KeyStatus::kOutputDownscaled:
        return CDMKeyStatus::OutputDownscaled;
    case cdm::KeyStatus::kStatusPending:
        return CDMKeyStatus::StatusPending;
    case cdm::KeyStatus::kInternalError:
        break;
    }
    return CDMKeyStatus::InternalError;
}

static CDMMessageType messageTypeFromCdmMessageType(cdm::MessageType type)
{
    switch (type) {
    case cdm::MessageType::kLicenseRenewal:
        return CDMMessageType::LicenseRenewal;
    case cdm::MessageType::kLicenseRelease:
        return CDMMessageType::LicenseRelease;
    case cdm::MessageType::kIndividualizationRequest:
        return CDMMessageType::IndividualizationRequest;
    case cdm::MessageType::kLicenseRequest:
        break;
    }
    return CDMMessageType::LicenseRequest;
}

CDMFactoryWidevine& CDMFactoryWidevine::singleton()
{
    static NeverDestroyed<CDMFactoryWidevine> factory;
    return factory;
}

std::unique_ptr<CDMPrivate> CDMFactoryWidevine::createCDM(const String& keySystem, const String&, const CDMPrivateClient&)
{
    ASSERT_UNUSED(keySystem, supportsKeySystem(keySystem));
    return makeUnique<CDMPrivateWidevine>();
}

bool CDMFactoryWidevine::supportsKeySystem(const String& keySystem)
{
    return GStreamerEMEUtilities::isWidevineKeySystem(keySystem) && WidevineCdm::isAvailable();
}

// What the CDM parses: a cenc pssh box or a WebM key ID. It answers "keyids" with
// kExceptionNotSupportedError, so that type is not offered.
Vector<String> CDMPrivateWidevine::supportedInitDataTypes() const
{
    return { InitDataRegistry::cencName(), InitDataRegistry::webmName() };
}

Vector<String> CDMPrivateWidevine::supportedRobustnesses() const
{
    // The CDM decrypts in software, so only the software tiers are honest here.
    return { emptyString(), "SW_SECURE_CRYPTO"_s, "SW_SECURE_DECODE"_s };
}

bool CDMPrivateWidevine::supportsConfiguration(const CDMKeySystemConfiguration&) const
{
    return true;
}

bool CDMPrivateWidevine::supportsConfigurationWithRestrictions(const CDMKeySystemConfiguration& configuration, const CDMRestrictions& restrictions) const
{
    if (configuration.distinctiveIdentifier == CDMRequirement::Optional && restrictions.distinctiveIdentifierDenied)
        return false;
    if (configuration.persistentState == CDMRequirement::Optional && restrictions.persistentStateDenied)
        return false;
    return supportsConfiguration(configuration);
}

bool CDMPrivateWidevine::supportsSessionTypeWithConfiguration(const CDMSessionType& sessionType, const CDMKeySystemConfiguration& configuration) const
{
    if (sessionType != CDMSessionType::Temporary)
        return false;
    return supportsConfiguration(configuration);
}

CDMRequirement CDMPrivateWidevine::distinctiveIdentifiersRequirement(const CDMKeySystemConfiguration&, const CDMRestrictions& restrictions) const
{
    if (restrictions.distinctiveIdentifierDenied)
        return CDMRequirement::NotAllowed;
    return CDMRequirement::Optional;
}

CDMRequirement CDMPrivateWidevine::persistentStateRequirement(const CDMKeySystemConfiguration&, const CDMRestrictions& restrictions) const
{
    if (restrictions.persistentStateDenied)
        return CDMRequirement::NotAllowed;
    return CDMRequirement::Optional;
}

bool CDMPrivateWidevine::distinctiveIdentifiersAreUniquePerOriginAndClearable(const CDMKeySystemConfiguration&) const
{
    return false;
}

RefPtr<CDMInstance> CDMPrivateWidevine::createInstance()
{
    auto instance = adoptRef(*new CDMInstanceWidevine());
    if (!instance->cdm())
        return nullptr;
    return instance;
}

void CDMPrivateWidevine::loadAndInitialize()
{
}

bool CDMPrivateWidevine::supportsServerCertificates() const
{
    return true;
}

bool CDMPrivateWidevine::supportsSessions() const
{
    return true;
}

bool CDMPrivateWidevine::supportsInitData(const String& initDataType, const SharedBuffer& initData) const
{
    if (initData.isEmpty())
        return false;
    return equalLettersIgnoringASCIICase(initDataType, "cenc"_s) || equalLettersIgnoringASCIICase(initDataType, "webm"_s);
}

RefPtr<SharedBuffer> CDMPrivateWidevine::sanitizeResponse(const SharedBuffer& response) const
{
    return response.makeContiguous();
}

std::optional<String> CDMPrivateWidevine::sanitizeSessionId(const String& sessionId) const
{
    return sessionId;
}

CDMInstanceWidevine::CDMInstanceWidevine()
    : CDMInstanceProxy(GStreamerEMEUtilities::s_WidevineKeySystem)
{
    m_cdm = WidevineCdm::create();
    if (!m_cdm)
        return;

    m_cdm->setClient(WeakPtr { static_cast<WidevineCdmClient&>(*this) });

    RefPtr proxy = this->proxy();
    if (proxy && GStreamerEMEUtilities::isWidevineKeySystem(proxy->keySystem()))
        static_cast<CDMProxyWidevine*>(proxy.get())->setCdm(RefPtr { m_cdm });
}

CDMInstanceWidevine::~CDMInstanceWidevine() = default;

void CDMInstanceWidevine::registerSession(const String& sessionID, CDMInstanceSessionWidevine& session)
{
    m_sessions.set(sessionID, WeakPtr { session });
}

void CDMInstanceWidevine::unregisterSession(const String& sessionID)
{
    m_sessions.remove(sessionID);
}

void CDMInstanceWidevine::cdmSessionMessage(const String& sessionID, cdm::MessageType messageType, Vector<uint8_t>&& message)
{
    if (auto session = m_sessions.get(sessionID))
        session->didReceiveMessage(messageType, WTF::move(message));
}

void CDMInstanceWidevine::cdmSessionKeyStatusesChanged(const String& sessionID, Vector<WidevineKeyStatus>&& statuses)
{
    if (auto session = m_sessions.get(sessionID))
        session->didChangeKeyStatuses(WTF::move(statuses));
}

void CDMInstanceWidevine::cdmSessionExpirationChanged(const String& sessionID, double expirationTime)
{
    if (auto session = m_sessions.get(sessionID))
        session->didChangeExpiration(expirationTime);
}

void CDMInstanceWidevine::cdmSessionClosed(const String& sessionID)
{
    if (auto session = m_sessions.get(sessionID))
        session->didClose();
}

void CDMInstanceWidevine::initializeWithConfiguration(const CDMKeySystemConfiguration&, AllowDistinctiveIdentifiers allowDistinctiveIdentifiers, AllowPersistentState allowPersistentState, SuccessCallback&& callback)
{
    // A CDM allowed to persist keeps one record of its own, in the origin's media-keys storage
    // directory; one that is not, or one whose origin has no such directory, is told so and keeps
    // nothing. Both play: the CDM asks for storage only when it has been told it may have it.
    bool succeeded = m_cdm && m_cdm->initialize(allowDistinctiveIdentifiers == AllowDistinctiveIdentifiers::Yes,
        allowPersistentState == AllowPersistentState::Yes && m_hasStorage);
    callback(succeeded ? SuccessValue::Succeeded : SuccessValue::Failed);
}

void CDMInstanceWidevine::setServerCertificate(Ref<SharedBuffer>&& certificate, SuccessCallback&& callback)
{
    if (!m_cdm) {
        callback(SuccessValue::Failed);
        return;
    }

    auto result = m_cdm->setServerCertificate(certificate->makeContiguous()->span());
    callback(result.succeeded ? SuccessValue::Succeeded : SuccessValue::Failed);
}

void CDMInstanceWidevine::setStorageDirectory(const String& directory)
{
    if (!directory.isEmpty())
        FileSystem::makeAllDirectories(directory);
    m_hasStorage = m_cdm && m_cdm->setStorageDirectory(directory);
}

const String& CDMInstanceWidevine::keySystem() const
{
    static NeverDestroyed<String> s_keySystem { MAKE_STATIC_STRING_IMPL("com.widevine.alpha") };
    return s_keySystem;
}

RefPtr<CDMInstanceSession> CDMInstanceWidevine::createSession()
{
    return adoptRef(new CDMInstanceSessionWidevine(*this));
}

CDMInstanceSessionWidevine::~CDMInstanceSessionWidevine()
{
    if (m_sessionID.isEmpty())
        return;
    if (auto* parent = parentInstance())
        parent->unregisterSession(m_sessionID);
}

CDMInstanceWidevine* CDMInstanceSessionWidevine::parentInstance() const
{
    auto instance = cdmInstanceProxy();
    return static_cast<CDMInstanceWidevine*>(instance.get());
}

void CDMInstanceSessionWidevine::didReceiveMessage(cdm::MessageType messageType, Vector<uint8_t>&& message)
{
    if (m_client)
        m_client->sendMessage(messageTypeFromCdmMessageType(messageType), SharedBuffer::create(message.span()));
}

void CDMInstanceSessionWidevine::didChangeKeyStatuses(Vector<WidevineKeyStatus>&& statuses)
{
    if (!mergeKeyStatuses(statuses))
        return;

    if (auto* parent = parentInstance())
        parent->mergeKeysFrom(m_keyStore);

    if (m_client)
        m_client->updateKeyStatuses(m_keyStore.convertToJSKeyStatusVector());
}

void CDMInstanceSessionWidevine::didChangeExpiration(double)
{
    // CDMInstanceSessionClient carries no expiration channel.
}

void CDMInstanceSessionWidevine::didClose()
{
    if (auto* parent = parentInstance())
        parent->unrefAllKeysFrom(m_keyStore);
    m_keyStore.clear();
}

bool CDMInstanceSessionWidevine::mergeKeyStatuses(const Vector<WidevineKeyStatus>& statuses)
{
    Vector<Ref<KeyHandle>> keys;
    keys.reserveInitialCapacity(statuses.size());
    for (auto& status : statuses) {
        // The content key itself stays inside the CDM; this store only tracks availability.
        KeyIDType keyID = status.keyID;
        keys.append(KeyHandle::create(keyStatusFromCdmKeyStatus(status.status), WTF::move(keyID), KeyHandleValueVariant { Vector<uint8_t> { } }));
    }

    return m_keyStore.addKeys(WTF::move(keys));
}

void CDMInstanceSessionWidevine::requestLicense(LicenseType licenseType, KeyGroupingStrategy, const String& initDataType, Ref<SharedBuffer>&& initData, LicenseCallback&& callback)
{
    auto* parent = parentInstance();
    auto* cdm = parent ? parent->cdm() : nullptr;
    if (!cdm || licenseType != LicenseType::Temporary) {
        callback(SharedBuffer::create(), emptyString(), false, Failed);
        return;
    }

    auto cdmInitDataType = equalLettersIgnoringASCIICase(initDataType, "webm"_s) ? cdm::InitDataType::kWebM : cdm::InitDataType::kCenc;
    auto result = cdm->createSessionAndGenerateRequest(cdm::SessionType::kTemporary, cdmInitDataType, initData->makeContiguous()->span());

    if (!result.succeeded || result.messages.isEmpty()) {
        LOG(EME, "EME - Widevine - could not generate a license request: %s", result.errorMessage.utf8().data());
        callback(SharedBuffer::create(), emptyString(), false, Failed);
        return;
    }

    m_sessionID = result.sessionID;
    parent->registerSession(m_sessionID, *this);

    auto& first = result.messages.first();
    auto message = SharedBuffer::create(first.second.span());
    bool needsIndividualization = first.first == cdm::MessageType::kIndividualizationRequest;
    forwardRemainingMessages(result.messages, 1);

    callOnMainThread([sessionID = m_sessionID, message = WTF::move(message), needsIndividualization, callback = WTF::move(callback)]() mutable {
        callback(WTF::move(message), sessionID, needsIndividualization, Succeeded);
    });
}

// The promise carries one message; a CDM that emitted more says the rest through the session.
void CDMInstanceSessionWidevine::forwardRemainingMessages(const Vector<std::pair<cdm::MessageType, Vector<uint8_t>>>& messages, size_t firstIndex)
{
    for (size_t index = firstIndex; index < messages.size(); ++index) {
        callOnMainThread([weakThis = WeakPtr { *this }, messageType = messages[index].first, bytes = messages[index].second]() mutable {
            if (weakThis)
                weakThis->didReceiveMessage(messageType, WTF::move(bytes));
        });
    }
}

void CDMInstanceSessionWidevine::updateLicense(const String& sessionID, LicenseType, Ref<SharedBuffer>&& response, LicenseUpdateCallback&& callback)
{
    auto* parent = parentInstance();
    auto* cdm = parent ? parent->cdm() : nullptr;
    if (!cdm) {
        callback(false, std::nullopt, std::nullopt, std::nullopt, Failed);
        return;
    }

    auto result = cdm->updateSession(sessionID.isEmpty() ? m_sessionID : sessionID, response->makeContiguous()->span());
    if (!result.succeeded) {
        LOG(EME, "EME - Widevine - license update failed: %s", result.errorMessage.utf8().data());
        callback(false, std::nullopt, std::nullopt, std::nullopt, Failed);
        return;
    }

    std::optional<KeyStatusVector> changedKeys;
    if (result.keyStatuses && mergeKeyStatuses(*result.keyStatuses)) {
        parent->mergeKeysFrom(m_keyStore);
        changedKeys = m_keyStore.convertToJSKeyStatusVector();
    }

    // A CDM that wants another round trip (a service certificate exchange, a renewal)
    // reports it as a further message rather than as a failure.
    std::optional<Message> message;
    if (!result.messages.isEmpty()) {
        auto& emitted = result.messages.first();
        message = Message { messageTypeFromCdmMessageType(emitted.first), SharedBuffer::create(emitted.second.span()) };
        forwardRemainingMessages(result.messages, 1);
    }

    callOnMainThread([weakThis = WeakPtr { *this }, callback = WTF::move(callback), changedKeys = WTF::move(changedKeys),
        expiration = result.expirationTime, message = WTF::move(message), sessionClosed = result.sessionClosed]() mutable {
        if (!weakThis)
            return;
        callback(sessionClosed, WTF::move(changedKeys), WTF::move(expiration), WTF::move(message), Succeeded);
    });
}

void CDMInstanceSessionWidevine::loadSession(LicenseType, const String&, const String&, LoadSessionCallback&& callback)
{
    callback(std::nullopt, std::nullopt, std::nullopt, Failed, SessionLoadFailure::NoSessionData);
}

void CDMInstanceSessionWidevine::closeSession(const String& sessionID, CloseSessionCallback&& callback)
{
    auto* parent = parentInstance();
    if (auto* cdm = parent ? parent->cdm() : nullptr)
        cdm->closeSession(sessionID.isEmpty() ? m_sessionID : sessionID);

    // The CDM has dropped the session, so stop routing its events here.
    if (parent && !m_sessionID.isEmpty())
        parent->unregisterSession(m_sessionID);

    callback();
}

void CDMInstanceSessionWidevine::removeSessionData(const String& sessionID, LicenseType, RemoveSessionDataCallback&& callback)
{
    auto* parent = parentInstance();
    auto* cdm = parent ? parent->cdm() : nullptr;
    if (!cdm) {
        callback({ }, nullptr, Failed);
        return;
    }

    auto result = cdm->removeSession(sessionID.isEmpty() ? m_sessionID : sessionID);
    auto keyStatuses = m_keyStore.allKeysAs(CDMKeyStatus::Released);
    parent->unrefAllKeysFrom(m_keyStore);
    m_keyStore.clear();

    callback(WTF::move(keyStatuses), nullptr, result.succeeded ? Succeeded : Failed);
}

void CDMInstanceSessionWidevine::storeRecordOfKeyUsage(const String&)
{
}

} // namespace WebCore

#endif // ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)
