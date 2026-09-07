/*
 * Copyright (C) 2026. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#pragma once

// native trust and selected keychain identities bind Cocoa curl TLS connections.
#include <Security/Security.h>
#include <curl/curl.h>
#include <openssl/ssl.h>
#include <wtf/Function.h>
#include <wtf/RetainPtr.h>
#include <wtf/URL.h>

OBJC_CLASS NSArray;
OBJC_CLASS NSURLProtectionSpace;

namespace WebCore {
class CocoaCurlTLSVerification;
struct CocoaCurlTLSState {
    WEBCORE_EXPORT static CURLcode install(SSL_CTX*, const std::shared_ptr<CocoaCurlTLSState>&);
    WEBCORE_EXPORT static std::shared_ptr<CocoaCurlTLSState> fromSSL(SSL*);
    WEBCORE_EXPORT static RetainPtr<CFArrayRef> certificateAuthorities(SSL*);
    URL url;
    Function<bool(SSL*)> requestIdentity;
    Function<bool(std::unique_ptr<CocoaCurlTLSVerification>&&)> requestVerification;
    // native signing may display keychain UI; its result resumes BoringSSL asynchronously.
    Function<bool(SecKeyAlgorithm, RetainPtr<CFDataRef>&&)> requestSignature;
    RetainPtr<SecTrustRef> trust;
    RetainPtr<SecTrustRef> allowedTrust;
    RetainPtr<CFArrayRef> peerChain;
    RetainPtr<CFArrayRef> acceptedChain;
    RetainPtr<SecIdentityRef> identity;
    RetainPtr<SecKeyRef> privateKey;
    RetainPtr<CFErrorRef> signingError;
    RetainPtr<CFDataRef> signature;
    bool signingComplete { false };
    void (*previousInfoCallback)(const SSL*, int, int) { nullptr };
    int receivedAlert { -1 };
    RetainPtr<NSArray> clientCertificates;
    bool evaluated { false };
    bool verificationRequested { false };
    bool accepted { false };
    bool identityRequested { false };
    bool identityAnswered { false };
};

// The verification operation owns a separate X509 context and native result. SSL/easy handles stay on their curl worker.
class CocoaCurlTLSVerification {
public:
    static std::unique_ptr<CocoaCurlTLSVerification> create(SSL*, const CocoaCurlTLSState&);
    ~CocoaCurlTLSVerification();
    void evaluate();
    void apply(CocoaCurlTLSState&);
private:
    CocoaCurlTLSVerification();
    class Impl;
    std::unique_ptr<Impl> m_impl;
};

WEBCORE_EXPORT RetainPtr<NSURLProtectionSpace> cocoaCurlTLSProtectionSpace(const URL&, int scheme, CFArrayRef distinguishedNames, SecTrustRef);
} // namespace WebCore
