// SecKeyCopyPublicKey and SecKeyCopyExternalRepresentation (polyfills/c/Security.c) for the keys WebKit's
// WebAuthn code makes: SecKeyCreateRandomKey pairs and SecKeyCreateWithData private keys, EC and RSA.
// The public half must be the key's own, which a signature by the private key and a BoringSSL verification
// against the public half's representation proves; a private key's representation must round-trip
// through SecKeyCreateWithData. Keys
// are made and released in a loop so that each new key lands where an earlier one lived.
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <openssl/bytestring.h>
#include <openssl/ec_key.h>
#include <openssl/ecdsa.h>
#include <openssl/nid.h>
#include <openssl/rsa.h>
#include <openssl/sha.h>
#include <stdio.h>
#include <string.h>

#pragma clang diagnostic ignored "-Wunguarded-availability"
#pragma clang diagnostic ignored "-Wunguarded-availability-new"

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-84s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok)
        failures++;
}

static SecKeyRef randomKey(bool isEC)
{
    int bits = isEC ? 256 : 2048;
    CFNumberRef size = CFNumberCreate(NULL, kCFNumberIntType, &bits);
    const void *keys[] = { kSecAttrKeyType, kSecAttrKeySizeInBits };
    const void *values[] = { isEC ? kSecAttrKeyTypeECSECPrimeRandom : kSecAttrKeyTypeRSA, size };
    CFDictionaryRef parameters = CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    SecKeyRef key = SecKeyCreateRandomKey(parameters, NULL);
    CFRelease(parameters);
    CFRelease(size);
    return key;
}

static SecKeyRef privateKeyWithData(CFDataRef data, bool isEC)
{
    const void *keys[] = { kSecAttrKeyType, kSecAttrKeyClass };
    const void *values[] = { isEC ? kSecAttrKeyTypeECSECPrimeRandom : kSecAttrKeyTypeRSA, kSecAttrKeyClassPrivate };
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    SecKeyRef key = SecKeyCreateWithData(data, attributes, NULL);
    CFRelease(attributes);
    return key;
}

// Whether `publicKey`'s representation verifies, in BoringSSL, what `privateKey` signs: an EC key signs the
// SHA-256 of the message (ECDSA, X9.62), an RSA key signs the message as a SHA-256 digest (PKCS#1 v1.5).
static bool halvesMatch(SecKeyRef privateKey, SecKeyRef publicKey, bool isEC)
{
    static const uint8_t digest[32] = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
                                        17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32 };
    SecKeyAlgorithm algorithm = isEC ? kSecKeyAlgorithmECDSASignatureMessageX962SHA256 : kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA256;
    CFDataRef message = CFDataCreate(NULL, digest, sizeof(digest));
    CFDataRef signature = SecKeyCreateSignature(privateKey, algorithm, message, NULL);
    CFDataRef publicBytes = SecKeyCopyExternalRepresentation(publicKey, NULL);
    bool verified = false;
    if (signature && publicBytes && isEC) {
        EC_KEY *key = EC_KEY_new_by_curve_name(NID_X9_62_prime256v1);
        const uint8_t *point = CFDataGetBytePtr(publicBytes);
        uint8_t hashed[SHA256_DIGEST_LENGTH];
        SHA256(digest, sizeof(digest), hashed);
        verified = key && EC_KEY_oct2key(key, point, (size_t)CFDataGetLength(publicBytes), NULL)
            && ECDSA_verify(0, hashed, sizeof(hashed), CFDataGetBytePtr(signature), (size_t)CFDataGetLength(signature), key) == 1;
        EC_KEY_free(key);
    } else if (signature && publicBytes) {
        CBS cbs;
        CBS_init(&cbs, CFDataGetBytePtr(publicBytes), (size_t)CFDataGetLength(publicBytes));
        RSA *key = RSA_parse_public_key(&cbs);
        verified = key && RSA_verify(NID_sha256, digest, sizeof(digest), CFDataGetBytePtr(signature), (size_t)CFDataGetLength(signature), key) == 1;
        RSA_free(key);
    }
    if (publicBytes)
        CFRelease(publicBytes);
    if (signature)
        CFRelease(signature);
    CFRelease(message);
    return verified;
}

static void exercise(bool isEC)
{
    const char *name = isEC ? "EC P-256" : "RSA 2048";
    int generatedMatches = 0, importedMatches = 0, roundTrips = 0, publicPrefixes = 0;
    const int rounds = 20;
    for (int i = 0; i < rounds; ++i) {
        SecKeyRef generated = randomKey(isEC);
        SecKeyRef generatedPublic = generated ? SecKeyCopyPublicKey(generated) : NULL;
        if (generatedPublic && halvesMatch(generated, generatedPublic, isEC))
            generatedMatches++;

        CFDataRef representation = generated ? SecKeyCopyExternalRepresentation(generated, NULL) : NULL;
        CFDataRef publicRepresentation = generatedPublic ? SecKeyCopyExternalRepresentation(generatedPublic, NULL) : NULL;
        // An EC private key's representation is its public point followed by the scalar.
        if (isEC && representation && publicRepresentation && CFDataGetLength(representation) == 97
            && CFDataGetLength(publicRepresentation) == 65
            && !memcmp(CFDataGetBytePtr(representation), CFDataGetBytePtr(publicRepresentation), 65))
            publicPrefixes++;
        if (generatedPublic)
            CFRelease(generatedPublic);
        if (generated)
            CFRelease(generated);

        SecKeyRef imported = representation ? privateKeyWithData(representation, isEC) : NULL;
        SecKeyRef importedPublic = imported ? SecKeyCopyPublicKey(imported) : NULL;
        if (importedPublic && halvesMatch(imported, importedPublic, isEC))
            importedMatches++;
        CFDataRef again = imported ? SecKeyCopyExternalRepresentation(imported, NULL) : NULL;
        if (again && representation && CFEqual(again, representation))
            roundTrips++;
        if (again)
            CFRelease(again);
        if (importedPublic)
            CFRelease(importedPublic);
        if (imported)
            CFRelease(imported);
        if (publicRepresentation)
            CFRelease(publicRepresentation);
        if (representation)
            CFRelease(representation);
    }
    char what[128];
    snprintf(what, sizeof what, "%s: SecKeyCreateRandomKey's public half verifies its signatures (%d/%d)", name, generatedMatches, rounds);
    check(generatedMatches == rounds, what);
    snprintf(what, sizeof what, "%s: SecKeyCreateWithData's public half verifies its signatures (%d/%d)", name, importedMatches, rounds);
    check(importedMatches == rounds, what);
    snprintf(what, sizeof what, "%s: a private key's representation round-trips (%d/%d)", name, roundTrips, rounds);
    check(roundTrips == rounds, what);
    if (isEC) {
        snprintf(what, sizeof what, "%s: the private representation is 04||X||Y||K over the public point (%d/%d)", name, publicPrefixes, rounds);
        check(publicPrefixes == rounds, what);
    }
}

int main(void)
{
    exercise(true);
    exercise(false);
    return failures ? 1 : 0;
}
