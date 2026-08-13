/*
 * Copyright (C) 2026 Jonathan Waldman
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above
 *    copyright notice, this list of conditions and the following
 *    disclaimer in the documentation and/or other materials provided
 *    with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

// MAVERICKS_BACKPORT: see CDMProxyWidevine.h.

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

// GStreamer hands subsamples over as big-endian (uint16 clear, uint32 encrypted) pairs.
static constexpr size_t subsampleEntrySizeInBytes = sizeof(uint16_t) + sizeof(uint32_t);

static Vector<cdm::SubsampleEntry> parseSubsamples(std::span<const uint8_t> buffer, unsigned count)
{
    Vector<cdm::SubsampleEntry> subsamples;
    subsamples.reserveInitialCapacity(count);

    for (unsigned index = 0; index < count; ++index) {
        auto entry = buffer.subspan(index * subsampleEntrySizeInBytes, subsampleEntrySizeInBytes);
        uint32_t clearBytes = (static_cast<uint32_t>(entry[0]) << 8) | entry[1];
        uint32_t cipherBytes = (static_cast<uint32_t>(entry[2]) << 24) | (static_cast<uint32_t>(entry[3]) << 16)
            | (static_cast<uint32_t>(entry[4]) << 8) | entry[5];
        subsamples.append({ clearBytes, cipherBytes });
    }

    return subsamples;
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

    if (input.numSubsamples && input.subsamples.size() < input.numSubsamples * subsampleEntrySizeInBytes) {
        LOG(EME, "EME - CDMProxyWidevine - subsample buffer too small for %u subsamples", input.numSubsamples);
        return false;
    }

    auto subsamples = parseSubsamples(input.subsamples, input.numSubsamples);

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

} // namespace WebCore

#endif // ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)
