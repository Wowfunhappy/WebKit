// Verify native SecIdentity signatures independently, including modified-input rejection.
#include "config.h"
#include <WebCore/CocoaCurlConnection.h>
#include <WebCore/ResourceError.h>
#include <WebCore/SharedBuffer.h>
#include <wtf/MainThread.h>
#include <Foundation/Foundation.h>
#include <Security/Security.h>
#include <cstdio>
#include <openssl/x509.h>
#include <openssl/evp.h>
#include <openssl/rsa.h>
#include <openssl/ec.h>
#include <openssl/ecdsa.h>
extern "C" OSStatus SecCertificateCopyPublicKey(SecCertificateRef, SecKeyRef*);
using namespace WebCore;
static unsigned failures;
static void signatureTests(SecIdentityRef identity)
{
    SecKeyRef rawPrivate = nullptr, rawPublic = nullptr;
    SecCertificateRef rawCertificate = nullptr;
    RELEASE_ASSERT(!SecIdentityCopyPrivateKey(identity, &rawPrivate));
    RELEASE_ASSERT(!SecIdentityCopyCertificate(identity, &rawCertificate));
    RELEASE_ASSERT(!SecCertificateCopyPublicKey(rawCertificate, &rawPublic));
    auto privateKey = adoptCF(rawPrivate), publicKey = adoptCF(rawPublic);
    auto certificate = adoptCF(rawCertificate);
    auto encoded = adoptCF(SecCertificateCopyData(certificate.get()));
    const uint8_t* next = CFDataGetBytePtr(encoded.get());
    bssl::UniquePtr<X509> x509(d2i_X509(nullptr, &next, CFDataGetLength(encoded.get())));
    RELEASE_ASSERT(x509);
    const EVP_PKEY* key = X509_get0_pubkey(x509.get());
    bool rsa = EVP_PKEY_id(key) == EVP_PKEY_RSA;
    struct Algorithm { const EVP_MD* (*digest)(); SecKeyAlgorithm native; };
    const Algorithm algorithms[] = {
        { EVP_sha1, kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA1 },
        { EVP_sha256, kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA256 },
        { EVP_sha384, kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA384 },
        { EVP_sha512, kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA512 }
    };
    for (auto& algorithm : algorithms) {
        const EVP_MD* md = algorithm.digest();
        const uint8_t input[] = "Native keychain signature verified by BoringSSL";
        uint8_t digest[EVP_MAX_MD_SIZE];
        unsigned length = 0;
        RELEASE_ASSERT(EVP_Digest(input, sizeof(input) - 1, digest, &length, md, nullptr));
        auto data = adoptCF(CFDataCreate(nullptr, digest, length));
        SecKeyAlgorithm native = rsa ? algorithm.native : kSecKeyAlgorithmECDSASignatureDigestX962;
        CFErrorRef rawError = nullptr;
        auto signature = adoptCF(SecKeyCreateSignature(privateKey.get(), native, data.get(), &rawError));
        auto error = adoptCF(rawError);
        bool independent = signature && (rsa
            ? RSA_verify(EVP_MD_type(md), digest, length, CFDataGetBytePtr(signature.get()), CFDataGetLength(signature.get()), EVP_PKEY_get0_RSA(key))
            : ECDSA_verify(0, digest, length, CFDataGetBytePtr(signature.get()), CFDataGetLength(signature.get()), EVP_PKEY_get0_EC_KEY(key)));
        bool nativeVerified = signature && SecKeyVerifySignature(publicKey.get(), native, data.get(), signature.get(), nullptr);
        auto changed = adoptCF(CFDataCreateMutableCopy(nullptr, 0, data.get()));
        CFDataGetMutableBytePtr(changed.get())[0] ^= 1;
        bool rejectsChange = signature && !SecKeyVerifySignature(publicKey.get(), native, changed.get(), signature.get(), nullptr);
        bool passed = independent && nativeVerified && rejectsChange;
        failures += !passed;
        printf("%s SHA%u signature: independent=%d native=%d tamper=%d bytes=%ld %s\n", rsa ? "RSA PKCS1" : "ECDSA", length * 8, independent, nativeVerified, rejectsChange, signature ? CFDataGetLength(signature.get()) : 0, passed ? "PASS" : "FAIL");
        if (error) CFShow(error.get());
    }
}
int main()
{
    @autoreleasepool {
        setvbuf(stdout, nullptr, _IONBF, 0);
        WTF::initializeMainThread();
        char directory[] = "/private/tmp/curl-signature-keychain-XXXXXX";
        RELEASE_ASSERT(mkdtemp(directory));
        NSString* path = [[NSString stringWithUTF8String:directory] stringByAppendingPathComponent:@"fixture.keychain"];
        SecKeychainRef rawKeychain = nullptr;
        RELEASE_ASSERT(!SecKeychainCreate(path.fileSystemRepresentation, 7, "fixture", false, nullptr, &rawKeychain));
        auto keychain = adoptCF(rawKeychain);
        for (NSString* fixture in @[@"identity.p12", @"ec-identity.p12"]) {
            NSData* pkcs12 = [NSData dataWithContentsOfFile:[@"/private/tmp/curl-identity-test" stringByAppendingPathComponent:fixture]];
            NSDictionary* options = @{ (id)kSecImportExportPassphrase: @"fixture", (id)kSecImportExportKeychain: (id)keychain.get() };
            CFArrayRef rawItems = nullptr;
            OSStatus status = SecPKCS12Import((CFDataRef)pkcs12, (CFDictionaryRef)options, &rawItems);
            if (status) { printf("SecPKCS12Import failed: %d\n", status); SecKeychainDelete(keychain.get()); return 1; }
            auto items = adoptCF(rawItems);
            SecIdentityRef identity = (SecIdentityRef)[(NSArray*)items.get() objectAtIndex:0][(id)kSecImportItemIdentity];
            signatureTests(identity);
        }
        RELEASE_ASSERT(!SecKeychainDelete(keychain.get()));
        printf("Native keychain signatures: FAILED=%u\n", failures);
    }
    return failures ? 1 : 0;
}
