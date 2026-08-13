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

    explicit CDMProxyWidevine(const String& keySystem)
        : CDMProxy(keySystem) { }
    virtual ~CDMProxyWidevine() = default;

    void setCdm(RefPtr<WidevineCdm>&&);
    bool decrypt(DecryptionContext&);

private:
    Lock m_cdmLock;
    RefPtr<WidevineCdm> m_cdm WTF_GUARDED_BY_LOCK(m_cdmLock);
};

} // namespace WebCore

#endif // ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)
