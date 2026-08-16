// MAVERICKS_BACKPORT: the CDMProxy for Widevine. The content keys live inside the CDM
// and are never handed out, so samples are decrypted by the CDM itself; the key store
// this inherits carries key IDs and statuses, which is what the decryptor waits on.

#pragma once

#if ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)

#include "CDMProxy.h"
#include "WidevineCdmModule.h"
#include <wtf/Lock.h>
#include <wtf/TZoneMalloc.h>

namespace WebCore {

class CDMProxyFactoryWidevine final : public CDMProxyFactory {
    WTF_MAKE_TZONE_ALLOCATED(CDMProxyFactoryWidevine);
public:
    static CDMProxyFactoryWidevine& singleton();
    ~CDMProxyFactoryWidevine() = default;

private:
    friend class NeverDestroyed<CDMProxyFactoryWidevine>;
    CDMProxyFactoryWidevine() = default;

    RefPtr<CDMProxy> createCDMProxy(const String&) final;
    bool supportsKeySystem(const String&) final;
};

class CDMProxyWidevine final : public CDMProxy {
public:
    struct DecryptionContext {
        std::span<const uint8_t> keyID;
        std::span<const uint8_t> iv;
        std::span<uint8_t> data;
        std::span<const uint8_t> subsamples;
        unsigned numSubsamples { 0 };
        cdm::EncryptionScheme encryptionScheme { cdm::EncryptionScheme::kCenc };
        cdm::Pattern pattern { 0, 0 };
        WeakPtr<CDMProxyDecryptionClient> cdmProxyDecryptionClient;
    };

    // What the CDM decodes for itself. The subsamples arrive already parsed because converting
    // the bitstream to the Annex-B the CDM decodes moves the clear byte counts.
    struct DecodeContext {
        std::span<const uint8_t> keyID;
        std::span<const uint8_t> iv;
        std::span<const uint8_t> data;
        std::span<const cdm::SubsampleEntry> subsamples;
        cdm::EncryptionScheme encryptionScheme { cdm::EncryptionScheme::kCenc };
        cdm::Pattern pattern { 0, 0 };
        int64_t timestamp { 0 };
        WeakPtr<CDMProxyDecryptionClient> cdmProxyDecryptionClient;
    };

    explicit CDMProxyWidevine(const String& keySystem)
        : CDMProxy(keySystem) { }
    virtual ~CDMProxyWidevine() = default;

    void setCdm(RefPtr<WidevineCdm>&&);
    bool decrypt(DecryptionContext&);

    cdm::Status initializeVideoDecoder(const cdm::VideoDecoderConfig_2&);
    void deinitializeVideoDecoder();
    void resetVideoDecoder();
    cdm::Status decryptAndDecodeFrame(DecodeContext&, WidevineVideoFrame&);

    // GStreamer carries subsamples as big-endian (uint16 clear, uint32 encrypted) pairs. False
    // when the buffer the media supplied is too small for the count it claims.
    static bool parseSubsamples(std::span<const uint8_t>, unsigned count, Vector<cdm::SubsampleEntry>&);

private:
    Lock m_cdmLock;
    RefPtr<WidevineCdm> m_cdm WTF_GUARDED_BY_LOCK(m_cdmLock);
};

} // namespace WebCore

#endif // ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)
