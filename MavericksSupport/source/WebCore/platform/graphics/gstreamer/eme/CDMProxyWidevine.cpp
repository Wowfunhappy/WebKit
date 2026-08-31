// See CDMProxyWidevine.h.

#include "config.h"
#include "CDMProxyWidevine.h"

#if ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)

#include "GStreamerEMEUtilities.h"
#include "Logging.h"
#include <wtf/NeverDestroyed.h>
#include <wtf/TZoneMallocInlines.h>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(CDMProxyFactoryWidevine);

CDMProxyFactoryWidevine& CDMProxyFactoryWidevine::singleton()
{
    static NeverDestroyed<CDMProxyFactoryWidevine> factory;
    return factory;
}

RefPtr<CDMProxy> CDMProxyFactoryWidevine::createCDMProxy(const String& keySystem)
{
    ASSERT(supportsKeySystem(keySystem));
    return adoptRef(new CDMProxyWidevine(keySystem));
}

bool CDMProxyFactoryWidevine::supportsKeySystem(const String& keySystem)
{
    return GStreamerEMEUtilities::isWidevineKeySystem(keySystem) && WidevineCdm::isAvailable();
}

void CDMProxyWidevine::setCdm(RefPtr<WidevineCdm>&& cdm)
{
    Locker locker { m_cdmLock };
    m_cdm = WTF::move(cdm);
}

static constexpr size_t subsampleEntrySizeInBytes = sizeof(uint16_t) + sizeof(uint32_t);

bool CDMProxyWidevine::parseSubsamples(std::span<const uint8_t> buffer, unsigned count, Vector<cdm::SubsampleEntry>& subsamples)
{
    // The count and the buffer both come from the media, so the one has to be checked against the
    // other before it is used to index.
    if (buffer.size() < static_cast<size_t>(count) * subsampleEntrySizeInBytes)
        return false;

    subsamples.reserveInitialCapacity(count);

    for (unsigned index = 0; index < count; ++index) {
        auto entry = buffer.subspan(index * subsampleEntrySizeInBytes, subsampleEntrySizeInBytes);
        uint32_t clearBytes = (static_cast<uint32_t>(entry[0]) << 8) | entry[1];
        uint32_t cipherBytes = (static_cast<uint32_t>(entry[2]) << 24) | (static_cast<uint32_t>(entry[3]) << 16)
            | (static_cast<uint32_t>(entry[4]) << 8) | entry[5];
        subsamples.append({ clearBytes, cipherBytes });
    }

    return true;
}

bool CDMProxyWidevine::decrypt(DecryptionContext& input)
{
    RefPtr<WidevineCdm> cdm;
    {
        Locker locker { m_cdmLock };
        cdm = m_cdm;
    }
    if (!cdm) {
        LOG(EME, "EME - CDMProxyWidevine - no CDM instance attached");
        return false;
    }

    // Block until the license for this key ID arrives, the same way the ClearKey proxy
    // does; the CDM would otherwise report kNoKey for every sample that raced the license.
    KeyIDType keyID { input.keyID };
    auto keyHandle = getOrWaitForKeyHandle(keyID, WTF::move(input.cdmProxyDecryptionClient));
    if (!keyHandle) {
        LOG(EME, "EME - CDMProxyWidevine - key unavailable, not decrypting");
        return false;
    }

    // Arriving is not the same as being usable: a key can be expired, released or in error.
    if (!(*keyHandle)->isStatusCurrentlyValid()) {
        LOG(EME, "EME - CDMProxyWidevine - key %s is not usable, not decrypting", (*keyHandle)->idAsString().utf8().data());
        return false;
    }

    Vector<cdm::SubsampleEntry> subsamples;
    if (!CDMProxyWidevine::parseSubsamples(input.subsamples, input.numSubsamples, subsamples)) {
        LOG(EME, "EME - CDMProxyWidevine - subsample buffer too small for %u subsamples", input.numSubsamples);
        return false;
    }

    cdm::InputBuffer_2 buffer { };
    buffer.data = input.data.data();
    buffer.data_size = input.data.size();
    buffer.encryption_scheme = input.encryptionScheme;
    buffer.key_id = input.keyID.data();
    buffer.key_id_size = input.keyID.size();
    buffer.iv = input.iv.data();
    buffer.iv_size = input.iv.size();
    buffer.subsamples = subsamples.isEmpty() ? nullptr : subsamples.span().data();
    buffer.num_subsamples = subsamples.size();
    buffer.pattern = input.pattern;

    auto status = cdm->decrypt(buffer, input.data);
    if (status != cdm::Status::kSuccess) {
        LOG(EME, "EME - CDMProxyWidevine - decryption failed with status %u", static_cast<unsigned>(status));
        return false;
    }

    return true;
}

cdm::Status CDMProxyWidevine::initializeVideoDecoder(const cdm::VideoDecoderConfig_2& config)
{
    RefPtr<WidevineCdm> cdm;
    {
        Locker locker { m_cdmLock };
        cdm = m_cdm;
    }
    if (!cdm) {
        LOG(EME, "EME - CDMProxyWidevine - no CDM instance attached");
        return cdm::Status::kInitializationError;
    }

    return cdm->initializeVideoDecoder(config);
}

void CDMProxyWidevine::deinitializeVideoDecoder()
{
    RefPtr<WidevineCdm> cdm;
    {
        Locker locker { m_cdmLock };
        cdm = m_cdm;
    }
    if (cdm)
        cdm->deinitializeVideoDecoder();
}

void CDMProxyWidevine::resetVideoDecoder()
{
    RefPtr<WidevineCdm> cdm;
    {
        Locker locker { m_cdmLock };
        cdm = m_cdm;
    }
    if (cdm)
        cdm->resetVideoDecoder();
}

cdm::Status CDMProxyWidevine::decryptAndDecodeFrame(DecodeContext& input, WidevineVideoFrame& frame)
{
    RefPtr<WidevineCdm> cdm;
    {
        Locker locker { m_cdmLock };
        cdm = m_cdm;
    }
    if (!cdm) {
        LOG(EME, "EME - CDMProxyWidevine - no CDM instance attached");
        return cdm::Status::kDecryptError;
    }

    if (input.encryptionScheme != cdm::EncryptionScheme::kUnencrypted) {
        // Block until the license for this key ID arrives, the same way decrypt() does.
        KeyIDType keyID { input.keyID };
        auto keyHandle = getOrWaitForKeyHandle(keyID, WTF::move(input.cdmProxyDecryptionClient));
        if (!keyHandle) {
            LOG(EME, "EME - CDMProxyWidevine - key unavailable, not decoding");
            return cdm::Status::kNoKey;
        }

        if (!(*keyHandle)->isStatusCurrentlyValid()) {
            LOG(EME, "EME - CDMProxyWidevine - key %s is not usable, not decoding", (*keyHandle)->idAsString().utf8().data());
            return cdm::Status::kNoKey;
        }
    }

    // An empty buffer is how the decoder is drained.
    cdm::InputBuffer_2 buffer { };
    buffer.data = input.data.empty() ? nullptr : input.data.data();
    buffer.data_size = input.data.size();
    buffer.encryption_scheme = input.encryptionScheme;
    if (input.encryptionScheme != cdm::EncryptionScheme::kUnencrypted) {
        buffer.key_id = input.keyID.data();
        buffer.key_id_size = input.keyID.size();
        buffer.iv = input.iv.data();
        buffer.iv_size = input.iv.size();
        buffer.subsamples = input.subsamples.empty() ? nullptr : input.subsamples.data();
        buffer.num_subsamples = input.subsamples.size();
        buffer.pattern = input.pattern;
    }
    buffer.timestamp = input.timestamp;

    return cdm->decryptAndDecodeFrame(buffer, frame);
}

} // namespace WebCore

#endif // ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)
