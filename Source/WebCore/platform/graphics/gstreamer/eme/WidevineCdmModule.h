// MAVERICKS_BACKPORT: host for a Chromium-API Content Decryption Module, which is how Widevine
// ships. Google's module implements cdm::ContentDecryptionModule_11 and performs its own AES, so
// this file supplies the cdm::Host_11 it calls back into and serializes access to it. Where the
// module is, and how it got there, is WidevineCdmLocation.h and WebKit's WidevineCdmInstaller.

#pragma once

#if ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)

#include <cdm/content_decryption_module.h>
#include <wtf/AbstractRefCountedAndCanMakeWeakPtr.h>
#include <wtf/Lock.h>
#include <wtf/ThreadSafeWeakPtr.h>
#include <wtf/Vector.h>
#include <wtf/WeakPtr.h>
#include <wtf/text/WTFString.h>

namespace WebCore {

struct WidevineKeyStatus {
    Vector<uint8_t> keyID;
    cdm::KeyStatus status { cdm::KeyStatus::kUsable };
};

// The CDM also speaks on its own account -- a renewal message when a license nears
// expiry, a key that stopped being usable, a session it closed. Those arrive outside
// any call and are delivered here.
class WidevineCdmClient : public AbstractRefCountedAndCanMakeWeakPtr<WidevineCdmClient> {
public:
    virtual ~WidevineCdmClient() = default;

    virtual void cdmSessionMessage(const String& sessionID, cdm::MessageType, Vector<uint8_t>&&) = 0;
    virtual void cdmSessionKeyStatusesChanged(const String& sessionID, Vector<WidevineKeyStatus>&&) = 0;
    virtual void cdmSessionExpirationChanged(const String& sessionID, double expirationTime) = 0;
    virtual void cdmSessionClosed(const String& sessionID) = 0;
};

// What a call produced. The CDM reports a call's own outcome through host callbacks it
// invokes synchronously, before the call returns, so this is complete when it hands
// control back.
struct WidevineCdmCallResult {
    bool succeeded { false };
    String errorMessage;
    String sessionID;
    Vector<std::pair<cdm::MessageType, Vector<uint8_t>>> messages;
    std::optional<Vector<WidevineKeyStatus>> keyStatuses;
    bool hasAdditionalUsableKey { false };
    std::optional<double> expirationTime;
    bool sessionClosed { false };
};

class WidevineCdm : public ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr<WidevineCdm> {
    WTF_MAKE_NONCOPYABLE(WidevineCdm);
public:
    static bool isAvailable();
    static RefPtr<WidevineCdm> create();
    ~WidevineCdm();

    void setClient(WeakPtr<WidevineCdmClient>&&);

    // Where the CDM's own records go; false when there is nowhere to put them, which is a session
    // the CDM must be told cannot persist.
    bool setStorageDirectory(const String&);

    bool initialize(bool allowDistinctiveIdentifier, bool allowPersistentState);

    WidevineCdmCallResult setServerCertificate(std::span<const uint8_t>);
    WidevineCdmCallResult createSessionAndGenerateRequest(cdm::SessionType, cdm::InitDataType, std::span<const uint8_t> initData);
    WidevineCdmCallResult updateSession(const String& sessionID, std::span<const uint8_t> response);
    WidevineCdmCallResult closeSession(const String& sessionID);
    WidevineCdmCallResult removeSession(const String& sessionID);

    // Called on GStreamer streaming threads. Writes the plaintext over |inOut|,
    // which must hold the ciphertext on entry.
    cdm::Status decrypt(const cdm::InputBuffer_2&, std::span<uint8_t> inOut);

private:
    class Host;
    friend class Host;

    // Handed to the module so it can fetch the host it calls back into.
    static void* cdmHostForInterfaceVersion(int, void* userData);

    // The answers the CDM waits for after asking the host for something. Each runs on the
    // main thread rather than inline from the request, because the CDM is mid-call and
    // holds a borrow of itself that a re-entrant call would trip over.
    void timerExpired(void* context);
    void deliverOutputProtectionStatus();
    void deliverStorageId(uint32_t version);
    void deliverPlatformChallengeResponse();

    WidevineCdm(cdm::ContentDecryptionModule_11&, std::unique_ptr<Host>&&);

    // The CDM is not internally synchronized and is reached from both the main
    // thread (session management) and streaming threads (decryption).
    Lock m_lock;
    cdm::ContentDecryptionModule_11* m_cdm WTF_GUARDED_BY_LOCK(m_lock) { nullptr };
    std::unique_ptr<Host> m_host;
};

} // namespace WebCore

#endif // ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)
