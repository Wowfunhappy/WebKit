// SecKeyVerifySignature with the RSASSA-PSS algorithms (polyfills/c/Security.c), which 10.9's CSSM does not
// implement: TestWebKitAPI's EventAttribution tests check a Private Click Measurement token this way, with
// kSecKeyAlgorithmRSASignatureMessagePSSSHA384 on a key made by SecKeyCreateWithData. Signatures come from
// BoringSSL with MGF1 over the same hash and a salt as long as the hash.
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <stdio.h>
#include <string.h>

#include <openssl/bn.h>
#include <openssl/bytestring.h>
#include <openssl/digest.h>
#include <openssl/mem.h>
#include <openssl/rsa.h>

#pragma clang diagnostic ignored "-Wunguarded-availability"
#pragma clang diagnostic ignored "-Wunguarded-availability-new"

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-84s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok)
        failures++;
}

static CFDataRef sign(RSA *rsa, const EVP_MD *md, const uint8_t *message, size_t length)
{
    uint8_t digest[EVP_MAX_MD_SIZE];
    unsigned digestLength = 0;
    EVP_Digest(message, length, digest, &digestLength, md, NULL);
    uint8_t signature[512];
    size_t signatureLength = 0;
    RSA_sign_pss_mgf1(rsa, &signatureLength, signature, sizeof signature, digest, digestLength, md, md, RSA_PSS_SALTLEN_DIGEST);
    return CFDataCreate(NULL, signature, (CFIndex)signatureLength);
}

int main(void)
{
    RSA *rsa = RSA_new();
    BIGNUM *e = BN_new();
    BN_set_word(e, 65537);
    RSA_generate_key_ex(rsa, 2048, e, NULL);
    uint8_t *der = NULL;
    size_t derLength = 0;
    RSA_public_key_to_bytes(&der, &derLength, rsa);
    CFDataRef keyData = CFDataCreate(NULL, der, (CFIndex)derLength);
    OPENSSL_free(der);

    const void *keys[] = { kSecAttrKeyType, kSecAttrKeyClass };
    const void *values[] = { kSecAttrKeyTypeRSA, kSecAttrKeyClassPublic };
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    SecKeyRef key = SecKeyCreateWithData(keyData, attributes, NULL);
    check(key != NULL, "SecKeyCreateWithData makes a public key from an RSAPublicKey");
    if (!key) {
        printf("Security-rsa-pss-verify: %d failure(s)\n", failures);
        return 1;
    }

    static const uint8_t message[] = "7JgS5aIQPUm9T5DcT2a91NC1lt2xq5bL";
    CFDataRef messageData = CFDataCreate(NULL, message, sizeof message - 1);
    const struct { CFStringRef message; CFStringRef digest; const EVP_MD *(*md)(void); const char *name; } algorithms[] = {
        { kSecKeyAlgorithmRSASignatureMessagePSSSHA1, kSecKeyAlgorithmRSASignatureDigestPSSSHA1, EVP_sha1, "SHA-1" },
        { kSecKeyAlgorithmRSASignatureMessagePSSSHA256, kSecKeyAlgorithmRSASignatureDigestPSSSHA256, EVP_sha256, "SHA-256" },
        { kSecKeyAlgorithmRSASignatureMessagePSSSHA384, kSecKeyAlgorithmRSASignatureDigestPSSSHA384, EVP_sha384, "SHA-384" },
        { kSecKeyAlgorithmRSASignatureMessagePSSSHA512, kSecKeyAlgorithmRSASignatureDigestPSSSHA512, EVP_sha512, "SHA-512" },
    };
    for (size_t i = 0; i < sizeof algorithms / sizeof algorithms[0]; i++) {
        char what[128];
        CFDataRef signature = sign(rsa, algorithms[i].md(), message, sizeof message - 1);
        CFErrorRef error = NULL;
        snprintf(what, sizeof what, "the message-PSS %s signature verifies", algorithms[i].name);
        check(SecKeyVerifySignature(key, algorithms[i].message, messageData, signature, &error) && !error, what);

        uint8_t digest[EVP_MAX_MD_SIZE];
        unsigned digestLength = 0;
        EVP_Digest(message, sizeof message - 1, digest, &digestLength, algorithms[i].md(), NULL);
        CFDataRef digestData = CFDataCreate(NULL, digest, digestLength);
        snprintf(what, sizeof what, "and as digest-PSS %s over the message's hash", algorithms[i].name);
        check(SecKeyVerifySignature(key, algorithms[i].digest, digestData, signature, &error) && !error, what);

        CFMutableDataRef tampered = CFDataCreateMutableCopy(NULL, 0, signature);
        CFDataGetMutableBytePtr(tampered)[10] ^= 1;
        snprintf(what, sizeof what, "a tampered %s signature is false, and no error", algorithms[i].name);
        check(!SecKeyVerifySignature(key, algorithms[i].message, messageData, tampered, &error) && !error, what);
        CFRelease(tampered);
        CFRelease(digestData);
        CFRelease(signature);
    }

    CFDataRef signature = sign(rsa, EVP_sha384(), message, sizeof message - 1);
    CFErrorRef error = NULL;
    check(!SecKeyVerifySignature(key, kSecKeyAlgorithmRSASignatureMessagePSSSHA256, messageData, signature, &error) && !error,
        "a SHA-384 signature does not verify as SHA-256");
    check(!SecKeyVerifySignature(key, kSecKeyAlgorithmRSASignatureDigestPSSSHA384, messageData, signature, &error) && error,
        "a digest-PSS input that is not a digest is an error");
    if (error)
        CFRelease(error);

    printf("Security-rsa-pss-verify: %d failure(s)\n", failures);
    return failures ? 1 : 0;
}
