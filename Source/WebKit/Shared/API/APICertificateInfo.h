/*
 * Copyright (C) 2013 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

// MAVERICKS_BACKPORT: restored. Upstream deleted API::CertificateInfo along with the
// deprecated WKCertificateInfo C API, but Safari 7 links and calls that API on every
// page commit to drive the address-bar lock and the Show Certificate sheet (#103).
// The wrapper carries the modern SecTrust-backed WebCore::CertificateInfo and, on
// Cocoa, owns the derived certificate-chain CFArray because the 2013 C API vends it
// with Get (borrowed) semantics — Safari 7 never releases what it receives.

#pragma once

#include "APIObject.h"
#include <WebCore/CertificateInfo.h>

#if PLATFORM(COCOA)
namespace WebCore {
class Credential;
}
#endif

namespace API {

class CertificateInfo final : public ObjectImpl<Object::Type::CertificateInfo> {
public:
    static Ref<CertificateInfo> create(const WebCore::CertificateInfo& certificateInfo)
    {
        return adoptRef(*new CertificateInfo(certificateInfo));
    }

#if PLATFORM(COCOA)
    // The 2013 API allows Safari to hand WebKit a raw chain (which may lead with a
    // SecIdentityRef when it comes from the client-certificate chooser panel).
    static Ref<CertificateInfo> create(CFArrayRef certificateChain);
#endif

    explicit CertificateInfo(const WebCore::CertificateInfo& certificateInfo)
        : m_certificateInfo(certificateInfo)
    {
    }

    const WebCore::CertificateInfo& certificateInfo() const { return m_certificateInfo; }

#if PLATFORM(COCOA)
    // Borrowed by WKCertificateInfoGetCertificateChain; lazily derived from the trust
    // unless an explicit chain was provided at creation. Null when there is no trust.
    CFArrayRef certificateChain() const;
#endif

private:
    WebCore::CertificateInfo m_certificateInfo;
#if PLATFORM(COCOA)
    mutable RetainPtr<CFArrayRef> m_certificateChain;
#endif
};

} // namespace API

SPECIALIZE_TYPE_TRAITS_API_OBJECT(CertificateInfo);

#if PLATFORM(COCOA)
namespace WebKit {
// Builds the client-certificate credential WKCredentialCreateWithCertificateInfo
// vends; defined alongside the chain handling in WKCertificateInfoMac.mm.
WebCore::Credential credentialWithCertificateInfo(API::CertificateInfo*);
}
#endif
