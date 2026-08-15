// MAVERICKS_BACKPORT: the com.widevine.alpha key system, backed by the Chromium-API CDM
// wrapped by WidevineCdmModule. Shaped like the Thunder backend, which is upstream's other
// external-CDM key system: the CDM owns the sessions and the content keys.

#pragma once

#if ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)

#include "CDMFactory.h"
#include "CDMInstance.h"
#include "CDMInstanceSession.h"
#include "CDMPrivate.h"
#include "CDMProxy.h"
#include "WidevineCdmModule.h"
#include <wtf/TZoneMalloc.h>

namespace WebCore {

class CDMFactoryWidevine final : public CDMFactory {
    WTF_MAKE_TZONE_ALLOCATED(CDMFactoryWidevine);
public:
    static CDMFactoryWidevine& NODELETE singleton();

    virtual ~CDMFactoryWidevine() = default;

    // Do nothing since this is a singleton object.
    void ref() const final { }
    void deref() const final { }

    std::unique_ptr<CDMPrivate> createCDM(const String& keySystem, const String& mediaKeysHashSalt, const CDMPrivateClient&) final;
    bool supportsKeySystem(const String&) final;

private:
    friend class NeverDestroyed<CDMFactoryWidevine>;
    CDMFactoryWidevine() = default;
};

class CDMPrivateWidevine final : public CDMPrivate {
    WTF_MAKE_TZONE_ALLOCATED(CDMPrivateWidevine);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(CDMPrivateWidevine);
public:
    CDMPrivateWidevine() = default;
    virtual ~CDMPrivateWidevine() = default;

    Vector<String> supportedInitDataTypes() const final;
    Vector<String> supportedRobustnesses() const final;
    bool supportsConfiguration(const CDMKeySystemConfiguration&) const final;
    bool supportsConfigurationWithRestrictions(const CDMKeySystemConfiguration&, const CDMRestrictions&) const final;
    bool supportsSessionTypeWithConfiguration(const CDMSessionType&, const CDMKeySystemConfiguration&) const final;
    CDMRequirement distinctiveIdentifiersRequirement(const CDMKeySystemConfiguration&, const CDMRestrictions&) const final;
    CDMRequirement persistentStateRequirement(const CDMKeySystemConfiguration&, const CDMRestrictions&) const final;
    bool distinctiveIdentifiersAreUniquePerOriginAndClearable(const CDMKeySystemConfiguration&) const final;
    RefPtr<CDMInstance> createInstance() final;
    void loadAndInitialize() final;
    bool supportsServerCertificates() const final;
    bool supportsSessions() const final;
    bool supportsInitData(const String&, const SharedBuffer&) const final;
    RefPtr<SharedBuffer> sanitizeResponse(const SharedBuffer&) const final;
    std::optional<String> sanitizeSessionId(const String&) const final;
};

class CDMInstanceSessionWidevine;

// The CDM addresses its unsolicited events by session id, so the instance keeps the
// sessions it created and hands each event to the one it names.
class CDMInstanceWidevine final : public CDMInstanceProxy, public WidevineCdmClient {
    WTF_MAKE_TZONE_ALLOCATED(CDMInstanceWidevine);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(CDMInstanceWidevine);
public:
    CDMInstanceWidevine();
    virtual ~CDMInstanceWidevine();

    void registerSession(const String& sessionID, CDMInstanceSessionWidevine&);
    void unregisterSession(const String& sessionID);

    // WidevineCdmClient holds a weak reference, which WTF requires to be backed by a
    // countable one; this instance is already reference counted as a CDMInstance.
    void ref() const final { CDMInstanceProxy::ref(); }
    void deref() const final { CDMInstanceProxy::deref(); }

    ImplementationType implementationType() const final { return ImplementationType::Widevine; }
    void initializeWithConfiguration(const CDMKeySystemConfiguration&, AllowDistinctiveIdentifiers, AllowPersistentState, SuccessCallback&&) final;
    void setServerCertificate(Ref<SharedBuffer>&&, SuccessCallback&&) final;
    void setStorageDirectory(const String&) final;
    const String& keySystem() const final;
    RefPtr<CDMInstanceSession> createSession() final;

    WidevineCdm* cdm() const { return m_cdm.get(); }

private:
    // WidevineCdmClient
    void cdmSessionMessage(const String& sessionID, cdm::MessageType, Vector<uint8_t>&&) final;
    void cdmSessionKeyStatusesChanged(const String& sessionID, Vector<WidevineKeyStatus>&&) final;
    void cdmSessionExpirationChanged(const String& sessionID, double) final;
    void cdmSessionClosed(const String& sessionID) final;

    RefPtr<WidevineCdm> m_cdm;
    // Whether the CDM has somewhere to keep its own record (see initializeWithConfiguration).
    bool m_hasStorage { false };
    HashMap<String, WeakPtr<CDMInstanceSessionWidevine>> m_sessions;
};

class CDMInstanceSessionWidevine final : public CDMInstanceSessionProxy {
public:
    explicit CDMInstanceSessionWidevine(CDMInstanceWidevine& parent)
        : CDMInstanceSessionProxy(parent) { }
    ~CDMInstanceSessionWidevine();

    void requestLicense(LicenseType, KeyGroupingStrategy, const String& initDataType, Ref<SharedBuffer>&& initData, LicenseCallback&&) final;
    void updateLicense(const String&, LicenseType, Ref<SharedBuffer>&&, LicenseUpdateCallback&&) final;
    void loadSession(LicenseType, const String&, const String&, LoadSessionCallback&&) final;
    void closeSession(const String&, CloseSessionCallback&&) final;
    void removeSessionData(const String&, LicenseType, RemoveSessionDataCallback&&) final;
    void storeRecordOfKeyUsage(const String&) final;

    void setClient(WeakPtr<CDMInstanceSessionClient>&& client) final { m_client = WTF::move(client); }
    void clearClient() final { m_client.clear(); }

    // Events the CDM raised on its own, forwarded by the instance.
    void didReceiveMessage(cdm::MessageType, Vector<uint8_t>&&);
    void didChangeKeyStatuses(Vector<WidevineKeyStatus>&&);
    void didChangeExpiration(double);
    void didClose();

private:
    CDMInstanceWidevine* parentInstance() const;

    // Mirrors the key IDs and statuses the CDM reports, so the decryptors waiting in
    // CDMProxy can be released once a license lands.
    bool mergeKeyStatuses(const Vector<WidevineKeyStatus>&);
    void forwardRemainingMessages(const Vector<std::pair<cdm::MessageType, Vector<uint8_t>>>&, size_t firstIndex);

    String m_sessionID;
    KeyStore m_keyStore;
    WeakPtr<CDMInstanceSessionClient> m_client;
};

} // namespace WebCore

SPECIALIZE_TYPE_TRAITS_CDM_INSTANCE(WebCore::CDMInstanceWidevine, WebCore::CDMInstance::ImplementationType::Widevine);

#endif // ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)
