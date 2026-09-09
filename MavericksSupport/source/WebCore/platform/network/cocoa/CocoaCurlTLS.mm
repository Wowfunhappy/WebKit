/*
 * Copyright (C) 2026. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#include "config.h"
#include "CocoaCurlTLS.h"
#include "CertificateInfo.h"
#include <Foundation/Foundation.h>
#include <openssl/x509.h>
#include <openssl/evp.h>
#include <openssl/rsa.h>
#include <openssl/pool.h>
#include "CocoaCurlClientHello.h"

// the Security framework evaluates server trust and signs with selected native identities.
extern "C" CFTypeRef wk_createProtectionSpace(CFStringRef, int, int, CFStringRef, int, CFArrayRef, SecTrustRef);
@interface NSURLProtectionSpace (CocoaCurlNativeProtectionSpace)
- (instancetype)_initWithCFURLProtectionSpace:(CFTypeRef)space;
@end

namespace WebCore {

static int tlsStateIndex()
{
    static int index = SSL_CTX_get_ex_new_index(0, nullptr, nullptr, nullptr,
        [](void*, void* pointer, CRYPTO_EX_DATA*, int, long, void*) {
            delete static_cast<std::shared_ptr<CocoaCurlTLSState>*>(pointer);
        });
    return index;
}

std::shared_ptr<CocoaCurlTLSState> CocoaCurlTLSState::fromSSL(SSL* ssl)
{
    auto* state = static_cast<std::shared_ptr<CocoaCurlTLSState>*>(SSL_CTX_get_ex_data(SSL_get_SSL_CTX(ssl), tlsStateIndex()));
    return state ? *state : nullptr;
}
static RetainPtr<CFArrayRef> peerCertificates(X509_STORE_CTX* store)
{
    auto result = adoptCF(CFArrayCreateMutable(nullptr, 0, &kCFTypeArrayCallBacks));
    auto append = [&](X509* certificate) {
        int size = i2d_X509(certificate, nullptr);
        if (size <= 0)
            return false;
        Vector<uint8_t> bytes(size);
        auto* next = bytes.mutableSpan().data();
        if (i2d_X509(certificate, &next) != size)
            return false;
        auto data = adoptCF(CFDataCreate(nullptr, bytes.mutableSpan().data(), size));
        auto native = adoptCF(SecCertificateCreateWithData(nullptr, data.get()));
        if (!native)
            return false;
        CFArrayAppendValue(result.get(), native.get());
        return true;
    };
    auto* leaf = X509_STORE_CTX_get0_cert(store);
    if (!leaf || !append(leaf))
        return nullptr;
    auto* chain = X509_STORE_CTX_get0_untrusted(store);
    for (size_t i = 0; chain && i < sk_X509_num(chain); ++i) {
        auto* certificate = sk_X509_value(chain, i);
        if (X509_cmp(leaf, certificate) && !append(certificate))
            return nullptr;
    }
    return result;
}

static bool certificateArraysMatch(CFArrayRef a, CFArrayRef b)
{
    if (!a || !b || CFArrayGetCount(a) != CFArrayGetCount(b))
        return false;
    for (CFIndex i = 0; i < CFArrayGetCount(a); ++i) {
        auto first = adoptCF(SecCertificateCopyData((SecCertificateRef)CFArrayGetValueAtIndex(a, i)));
        auto second = adoptCF(SecCertificateCopyData((SecCertificateRef)CFArrayGetValueAtIndex(b, i)));
        if (!first || !second || !CFEqual(first.get(), second.get()))
            return false;
    }
    return true;
}

static bool evaluateNativeTrust(CocoaCurlTLSState& state, X509_STORE_CTX* store)
{
    state.peerChain = peerCertificates(store);
    // NSURL supplies the native host representation (in particular, IPv6 without URL brackets).
    auto policy = adoptCF(SecPolicyCreateSSL(true, (__bridge CFStringRef)state.url.createNSURL().get().host));
    SecTrustRef trust = nullptr;
    if (!state.peerChain || !policy || SecTrustCreateWithCertificates(state.peerChain.get(), policy.get(), &trust))
        return state.acceptAnyCertificate;
    state.trust = adoptCF(trust);
    if (state.acceptAnyCertificate)
        return true;
    SecTrustResultType result = kSecTrustResultInvalid;
    OSStatus status = SecTrustEvaluate(trust, &result);
    if (!status && (result == kSecTrustResultProceed || result == kSecTrustResultUnspecified))
        return true;
    if (certificateArraysMatch(state.peerChain.get(), state.acceptedChain.get()))
        return true;
    return state.allowedTrust && certificatesMatch(state.allowedTrust.get(), trust);
}

static int verificationStateIndex()
{
    static int index = X509_STORE_CTX_get_ex_new_index(0, nullptr, nullptr, nullptr, nullptr);
    return index;
}

static int verifyCallback(int, X509_STORE_CTX* store)
{
    auto* state = static_cast<CocoaCurlTLSState*>(X509_STORE_CTX_get_ex_data(store, verificationStateIndex()));
    if (!state)
        return 0;
    if (!std::exchange(state->evaluated, true))
        state->accepted = evaluateNativeTrust(*state, store);
    X509_STORE_CTX_set_error(store, state->accepted ? X509_V_OK : X509_V_ERR_CERT_REJECTED);
    return state->accepted;
}

class CocoaCurlTLSVerification::Impl {
public:
    ~Impl()
    {
        X509_STORE_CTX_free(context);
        sk_X509_pop_free(chain, X509_free);
        X509_STORE_free(store);
    }
    CocoaCurlTLSState result;
    X509_STORE* store { X509_STORE_new() };
    X509_STORE_CTX* context { X509_STORE_CTX_new() };
    STACK_OF(X509)* chain { sk_X509_new_null() };
};
CocoaCurlTLSVerification::CocoaCurlTLSVerification()
    : m_impl(std::make_unique<Impl>())
{
}
CocoaCurlTLSVerification::~CocoaCurlTLSVerification() = default;
std::unique_ptr<CocoaCurlTLSVerification> CocoaCurlTLSVerification::create(SSL* ssl, const CocoaCurlTLSState& state)
{
    auto verification = std::unique_ptr<CocoaCurlTLSVerification>(new CocoaCurlTLSVerification);
    auto& impl = *verification->m_impl;
    auto* certificates = SSL_get_peer_full_cert_chain(ssl);
    if (!impl.store || !impl.context || !impl.chain || !certificates || !sk_X509_num(certificates) || verificationStateIndex() < 0)
        return nullptr;
    for (size_t i = 0; i < sk_X509_num(certificates); ++i) {
        auto* copy = X509_dup(sk_X509_value(certificates, i));
        if (!copy || !sk_X509_push(impl.chain, copy)) {
            X509_free(copy);
            return nullptr;
        }
    }
    impl.result.url = state.url.isolatedCopy();
    impl.result.acceptedChain = state.acceptedChain;
    impl.result.allowedTrust = state.allowedTrust;
    impl.result.acceptAnyCertificate = state.acceptAnyCertificate;
    if (!X509_STORE_CTX_init(impl.context, impl.store, sk_X509_value(impl.chain, 0), impl.chain)
        || !X509_STORE_CTX_set_ex_data(impl.context, verificationStateIndex(), &impl.result))
        return nullptr;
    // Run the SSL_CTX_set_verify callback through the normal X509 verification operation, on the trust queue.
    // BoringSSL's custom-verify continuation supplies the asynchronous SSL boundary; no CA store is loaded.
    X509_STORE_CTX_set_verify_cb(impl.context, SSL_CTX_get_verify_callback(SSL_get_SSL_CTX(ssl)));
    return verification;
}
void CocoaCurlTLSVerification::evaluate()
{
    if (X509_verify_cert(m_impl->context) != 1)
        m_impl->result.accepted = false;
    m_impl->result.evaluated = true;
}
void CocoaCurlTLSVerification::apply(CocoaCurlTLSState& state)
{
    state.trust = WTF::move(m_impl->result.trust);
    state.peerChain = WTF::move(m_impl->result.peerChain);
    state.accepted = m_impl->result.accepted;
    state.evaluated = m_impl->result.evaluated;
}
static ssl_verify_result_t verifyAsynchronously(SSL* ssl, uint8_t* alert)
{
    auto state = CocoaCurlTLSState::fromSSL(ssl);
    if (!state) {
        *alert = SSL_AD_INTERNAL_ERROR;
        return ssl_verify_invalid;
    }
    if (state->evaluated)
        return state->accepted ? ssl_verify_ok : ssl_verify_invalid;
    if (!std::exchange(state->verificationRequested, true)) {
        auto verification = CocoaCurlTLSVerification::create(ssl, *state);
        if (!verification || !state->requestVerification || !state->requestVerification(WTF::move(verification))) {
            *alert = SSL_AD_INTERNAL_ERROR;
            return ssl_verify_invalid;
        }
    }
    return ssl_verify_retry;
}
static ssl_private_key_result_t signWithIdentity(SSL* ssl, uint8_t*, size_t*, size_t, uint16_t algorithm, const uint8_t* input, size_t inputSize)
{
    auto state = CocoaCurlTLSState::fromSSL(ssl);
    if (!state || !state->privateKey)
        return ssl_private_key_failure;
    const EVP_MD* digestAlgorithm = SSL_get_signature_algorithm_digest(algorithm);
    if (!digestAlgorithm)
        return ssl_private_key_failure;
    std::array<uint8_t, EVP_MAX_MD_SIZE> digest;
    unsigned digestSize = 0;
    if (!EVP_Digest(input, inputSize, digest.data(), &digestSize, digestAlgorithm, nullptr))
        return ssl_private_key_failure;
    SecKeyAlgorithm nativeAlgorithm = kSecKeyAlgorithmECDSASignatureDigestX962;
    const uint8_t* bytes = digest.data();
    size_t length = digestSize;
    Vector<uint8_t> encoded;
    if (SSL_get_signature_algorithm_key_type(algorithm) == EVP_PKEY_RSA) {
        if (SSL_is_signature_algorithm_rsa_pss(algorithm)) {
            auto* certificate = SSL_get_certificate(ssl);
            auto* key = certificate ? X509_get0_pubkey(certificate) : nullptr;
            auto* rsa = key ? EVP_PKEY_get0_RSA(key) : nullptr;
            if (!rsa)
                return ssl_private_key_failure;
            encoded.resize(RSA_size(rsa));
            if (!RSA_padding_add_PKCS1_PSS_mgf1(rsa, encoded.mutableSpan().data(), digest.data(), digestAlgorithm, digestAlgorithm, RSA_PSS_SALTLEN_DIGEST))
                return ssl_private_key_failure;
            nativeAlgorithm = kSecKeyAlgorithmRSASignatureRaw;
            bytes = encoded.span().data();
            length = encoded.size();
        } else {
            switch (EVP_MD_type(digestAlgorithm)) {
            case NID_sha256: nativeAlgorithm = kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA256; break;
            case NID_sha384: nativeAlgorithm = kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA384; break;
            case NID_sha512: nativeAlgorithm = kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA512; break;
            case NID_sha1: nativeAlgorithm = kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA1; break;
            default: return ssl_private_key_failure;
            }
        }
    }
    // prepare the signing input on the SSL owner, then release the worker while the native key enforces its signing ACL.
    auto data = adoptCF(CFDataCreate(nullptr, bytes, length));
    state->signature = nullptr;
    state->signingError = nullptr;
    state->signingComplete = false;
    if (!data || !state->requestSignature || !state->requestSignature(nativeAlgorithm, WTF::move(data)))
        return ssl_private_key_failure;
    return ssl_private_key_retry;
}

// only the curl worker reads the completed native signature and resumes the original TLS handshake.
static ssl_private_key_result_t completeIdentitySignature(SSL* ssl, uint8_t* output, size_t* outputSize, size_t capacity)
{
    auto state = CocoaCurlTLSState::fromSSL(ssl);
    if (!state)
        return ssl_private_key_failure;
    if (!state->signingComplete)
        return ssl_private_key_retry;
    if (!state->signature || static_cast<size_t>(CFDataGetLength(state->signature.get())) > capacity)
        return ssl_private_key_failure;
    *outputSize = CFDataGetLength(state->signature.get());
    memcpy(output, CFDataGetBytePtr(state->signature.get()), *outputSize);
    state->signature = nullptr;
    return ssl_private_key_success;
}

static int clientCertificateCallback(SSL* ssl, void*)
{
    auto state = CocoaCurlTLSState::fromSSL(ssl);
    if (!state)
        return 0;
    if (!state->identityAnswered) {
        if (!std::exchange(state->identityRequested, true)) {
            if (!state->requestIdentity || !state->requestIdentity(ssl))
                return 0;
        }
        return -1; // BoringSSL suspends CertificateRequest until WebKit answers the challenge.
    }
    if (!state->identity)
        return 1;
    SecCertificateRef leaf = nullptr;
    SecKeyRef key = nullptr;
    if (SecIdentityCopyCertificate(state->identity.get(), &leaf) || SecIdentityCopyPrivateKey(state->identity.get(), &key)) {
        if (leaf)
            CFRelease(leaf);
        return 0;
    }
    auto leafCertificate = adoptCF(leaf);
    state->privateKey = adoptCF(key);
    Vector<CRYPTO_BUFFER*> chain;
    auto append = [&](SecCertificateRef certificate) {
        auto bytes = adoptCF(SecCertificateCopyData(certificate));
        auto* buffer = bytes ? CRYPTO_BUFFER_new(CFDataGetBytePtr(bytes.get()), CFDataGetLength(bytes.get()), nullptr) : nullptr;
        if (buffer)
            chain.append(buffer);
        return !!buffer;
    };
    bool valid = append(leaf);
    for (id certificate in state->clientCertificates.get()) {
        if (CFGetTypeID((__bridge CFTypeRef)certificate) != SecCertificateGetTypeID()) {
            valid = false;
            break;
        }
        if (!CFEqual((__bridge CFTypeRef)certificate, leaf))
            valid &= append((__bridge SecCertificateRef)certificate);
    }
    static const SSL_PRIVATE_KEY_METHOD method { signWithIdentity, nullptr, completeIdentitySignature };
    int installed = valid && SSL_set_chain_and_key(ssl, chain.mutableSpan().data(), chain.size(), nullptr, &method);
    for (auto* buffer : chain)
        CRYPTO_BUFFER_free(buffer);
    return installed;
}

CURLcode CocoaCurlTLSState::install(SSL_CTX* ssl, const std::shared_ptr<CocoaCurlTLSState>& state)
{
    if (!cocoaCurlInstallClientHello(ssl))
        return CURLE_SSL_CIPHER;
    auto retained = std::make_unique<std::shared_ptr<CocoaCurlTLSState>>(state);
    if (tlsStateIndex() < 0 || !SSL_CTX_set_ex_data(ssl, tlsStateIndex(), retained.get()))
        return CURLE_OUT_OF_MEMORY;
    retained.release();
    SSL_CTX_set_verify(ssl, SSL_VERIFY_PEER, verifyCallback);
    SSL_CTX_set_custom_verify(ssl, SSL_VERIFY_PEER, verifyAsynchronously);
    SSL_CTX_set_reverify_on_resume(ssl, 1);
    SSL_CTX_set_cert_cb(ssl, clientCertificateCallback, nullptr);
    state->previousInfoCallback = SSL_CTX_get_info_callback(ssl);
    SSL_CTX_set_info_callback(ssl, [](const SSL* connection, int event, int value) {
        if (auto state = CocoaCurlTLSState::fromSSL(const_cast<SSL*>(connection))) {
            if ((event & SSL_CB_READ_ALERT) == SSL_CB_READ_ALERT)
                state->receivedAlert = value & 0xff;
            if (state->previousInfoCallback)
                state->previousInfoCallback(connection, event, value);
        }
    });
    return CURLE_OK;
}

// BoringSSL's own verification operation carries the connection, so the state is reached through the
// SSL rather than through the X509 context the asynchronous path builds for the trust queue.
static int synchronousVerifyCallback(int, X509_STORE_CTX* store)
{
    auto* connection = static_cast<SSL*>(X509_STORE_CTX_get_ex_data(store, SSL_get_ex_data_X509_STORE_CTX_idx()));
    auto state = connection ? CocoaCurlTLSState::fromSSL(connection) : nullptr;
    if (!state)
        return 0;
    if (!std::exchange(state->evaluated, true))
        state->accepted = evaluateNativeTrust(*state, store);
    X509_STORE_CTX_set_error(store, state->accepted ? X509_V_OK : X509_V_ERR_CERT_REJECTED);
    return state->accepted;
}

CURLcode CocoaCurlTLSState::installSynchronously(SSL_CTX* ssl, const std::shared_ptr<CocoaCurlTLSState>& state)
{
    if (!cocoaCurlInstallClientHello(ssl))
        return CURLE_SSL_CIPHER;
    auto retained = std::make_unique<std::shared_ptr<CocoaCurlTLSState>>(state);
    if (tlsStateIndex() < 0 || !SSL_CTX_set_ex_data(ssl, tlsStateIndex(), retained.get()))
        return CURLE_OUT_OF_MEMORY;
    retained.release();
    SSL_CTX_set_verify(ssl, SSL_VERIFY_PEER, synchronousVerifyCallback);
    SSL_CTX_set_reverify_on_resume(ssl, 1);
    return CURLE_OK;
}

RetainPtr<CFArrayRef> CocoaCurlTLSState::certificateAuthorities(SSL* ssl)
{
    auto names = adoptCF(CFArrayCreateMutable(nullptr, 0, &kCFTypeArrayCallBacks));
    auto* authorities = SSL_get_client_CA_list(ssl);
    for (size_t i = 0; authorities && i < sk_X509_NAME_num(authorities); ++i) {
        auto* name = sk_X509_NAME_value(authorities, i);
        int size = i2d_X509_NAME(name, nullptr);
        if (size <= 0)
            continue;
        Vector<uint8_t> bytes(size);
        auto* next = bytes.mutableSpan().data();
        i2d_X509_NAME(name, &next);
        auto data = adoptCF(CFDataCreate(nullptr, bytes.span().data(), size));
        CFArrayAppendValue(names.get(), data.get());
    }
    return names;
}

RetainPtr<NSURLProtectionSpace> cocoaCurlTLSProtectionSpace(const URL& url, int scheme, CFArrayRef distinguishedNames, SecTrustRef trust)
{
    // CFNetwork's HTTPS server type is 2; the authentication scheme uses its native enum.
    auto space = adoptCF(wk_createProtectionSpace((__bridge CFStringRef)url.createNSURL().get().host, url.port().value_or(443), 2, nullptr, scheme, distinguishedNames, trust));
    return space ? adoptNS([[NSURLProtectionSpace alloc] _initWithCFURLProtectionSpace:space.get()]) : nullptr;
}

} // namespace WebCore
