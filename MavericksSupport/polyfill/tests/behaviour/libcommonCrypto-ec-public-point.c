// The CommonCrypto EC key constructor polyfills (polyfills/c/libcommonCrypto.c): CCECCryptorImportKey,
// CCECCryptorImportPublicKey and CCECCryptorCreateFromData build a key only from a point on the curve.
// Every off-curve case below is one 10.9's own constructors accept and run ECDH on. The on-curve keys
// come from 10.9's CCECCryptorGeneratePair for P-192, P-256 and P-384; P-224 and P-521 are exercised with
// off-curve input only, since 10.9's key generation and private import for those two sizes corrupt the
// heap. Malformed P-256 encodings stay rejected.
#include <CommonCrypto/CommonCryptoError.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef struct _CCECCryptor *CCECCryptorRef;
extern CCCryptorStatus CCECCryptorImportKey(uint32_t format, const void *keyPackage, size_t keyPackageLen, uint32_t keyType, CCECCryptorRef *key);
extern CCCryptorStatus CCECCryptorImportPublicKey(const void *keyPackage, size_t keyPackageLen, CCECCryptorRef *key);
extern CCCryptorStatus CCECCryptorCreateFromData(size_t keySize, uint8_t *qX, size_t qXLength, uint8_t *qY, size_t qYLength, CCECCryptorRef *ref);
extern CCCryptorStatus CCECCryptorExportKey(uint32_t format, void *keyPackage, size_t *keyPackageLen, uint32_t keyType, CCECCryptorRef key);
extern CCCryptorStatus CCECCryptorGeneratePair(size_t keySize, CCECCryptorRef *publicKey, CCECCryptorRef *privateKey);
extern CCCryptorStatus CCECCryptorComputeSharedSecret(CCECCryptorRef privateKey, CCECCryptorRef publicKey, void *out, size_t *outLen);
extern void CCECCryptorRelease(CCECCryptorRef);

enum { kCCImportKeyBinary = 0, ccECKeyPublic = 0, ccECKeyPrivate = 1 };

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-84s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok)
        failures++;
}

// A constructed key, released after the caller's verdict: accepted means a status of success and a key.
static CCECCryptorRef accepted(CCCryptorStatus status, CCECCryptorRef key)
{
    if (status == kCCSuccess && key)
        return key;
    if (key)
        CCECCryptorRelease(key);
    return NULL;
}

static int derivesSecret(CCECCryptorRef privateKey, CCECCryptorRef peer)
{
    uint8_t secret[80];
    size_t secretLength = sizeof secret;
    return privateKey && peer && CCECCryptorComputeSharedSecret(privateKey, peer, secret, &secretLength) == kCCSuccess && secretLength;
}

static void expect(CCECCryptorRef key, int shouldAccept, CCECCryptorRef privateKey, const char *what)
{
    char line[160];
    snprintf(line, sizeof line, "%s is %s", what, shouldAccept ? "accepted and agrees on a secret" : "rejected");
    check(shouldAccept ? (key && derivesSecret(privateKey, key)) : !key, line);
    if (key)
        CCECCryptorRelease(key);
}

static CCECCryptorRef importKey(const uint8_t *bytes, size_t length, uint32_t keyType)
{
    CCECCryptorRef key = NULL;
    CCCryptorStatus status = CCECCryptorImportKey(kCCImportKeyBinary, bytes, length, keyType, &key);
    return accepted(status, key);
}

static CCECCryptorRef importPublicKey(const uint8_t *bytes, size_t length)
{
    CCECCryptorRef key = NULL;
    CCCryptorStatus status = CCECCryptorImportPublicKey(bytes, length, &key);
    return accepted(status, key);
}

static CCECCryptorRef createFromData(size_t bits, uint8_t *x, size_t xLength, uint8_t *y, size_t yLength)
{
    CCECCryptorRef key = NULL;
    CCCryptorStatus status = CCECCryptorCreateFromData(bits, x, xLength, y, yLength, &key);
    return accepted(status, key);
}

// P-192, P-256, P-384: every constructor, on-curve and off-curve, from a 10.9-generated key pair.
static void checkGeneratedCurve(size_t bits)
{
    size_t fieldBytes = (bits + 7) / 8, publicLength = 1 + 2 * fieldBytes, privateLength = 1 + 3 * fieldBytes;
    CCECCryptorRef publicKey = NULL, privateKey = NULL;
    uint8_t publicBytes[1 + 2 * 66], privateBytes[1 + 3 * 66];
    size_t exportedPublic = sizeof publicBytes, exportedPrivate = sizeof privateBytes;
    printf(" P-%zu\n", bits);
    if (CCECCryptorGeneratePair(bits, &publicKey, &privateKey) != kCCSuccess
        || CCECCryptorExportKey(kCCImportKeyBinary, publicBytes, &exportedPublic, ccECKeyPublic, publicKey) != kCCSuccess
        || CCECCryptorExportKey(kCCImportKeyBinary, privateBytes, &exportedPrivate, ccECKeyPrivate, privateKey) != kCCSuccess
        || exportedPublic != publicLength || exportedPrivate != privateLength) {
        check(0, "10.9 generates and exports a key pair");
        return;
    }

    uint8_t changedPublic[sizeof publicBytes], changedPrivate[sizeof privateBytes];
    memcpy(changedPublic, publicBytes, publicLength);
    changedPublic[publicLength - 1] ^= 1;
    memcpy(changedPrivate, privateBytes, privateLength);
    changedPrivate[publicLength - 1] ^= 1;
    uint8_t *x = publicBytes + 1, *y = publicBytes + 1 + fieldBytes;
    uint8_t *changedY = changedPublic + 1 + fieldBytes;
    uint8_t paddedX[1 + 66] = { 0 };
    memcpy(paddedX + 1, x, fieldBytes);

    expect(importKey(publicBytes, publicLength, ccECKeyPublic), 1, privateKey, "CCECCryptorImportKey, on-curve public key");
    expect(importKey(changedPublic, publicLength, ccECKeyPublic), 0, privateKey, "CCECCryptorImportKey, public key with y changed in its last bit");
    expect(importKey(privateBytes, privateLength, ccECKeyPrivate), 1, privateKey, "CCECCryptorImportKey, private key with an on-curve public point");
    expect(importKey(changedPrivate, privateLength, ccECKeyPrivate), 0, privateKey, "CCECCryptorImportKey, private key whose public point has y changed");
    expect(importPublicKey(publicBytes, publicLength), 1, privateKey, "CCECCryptorImportPublicKey, on-curve key");
    expect(importPublicKey(changedPublic, publicLength), 0, privateKey, "CCECCryptorImportPublicKey, key with y changed in its last bit");
    expect(createFromData(bits, x, fieldBytes, y, fieldBytes), 1, privateKey, "CCECCryptorCreateFromData, on-curve coordinates");
    expect(createFromData(bits, paddedX, fieldBytes + 1, y, fieldBytes), 1, privateKey, "CCECCryptorCreateFromData, on-curve x with a leading zero byte");
    expect(createFromData(bits, x, fieldBytes, changedY, fieldBytes), 0, privateKey, "CCECCryptorCreateFromData, y changed in its last bit");

    // 10.9 decodes the hybrid prefixes 06 and 07 like 04, whatever the parity of y.
    static const uint8_t hybridPrefixes[] = { 0x06, 0x07 };
    for (size_t i = 0; i < sizeof hybridPrefixes; i++) {
        uint8_t prefix = hybridPrefixes[i];
        char what[160];
        publicBytes[0] = changedPublic[0] = privateBytes[0] = changedPrivate[0] = prefix;
        snprintf(what, sizeof what, "CCECCryptorImportKey, on-curve public key under prefix %02x", prefix);
        expect(importKey(publicBytes, publicLength, ccECKeyPublic), 1, privateKey, what);
        snprintf(what, sizeof what, "CCECCryptorImportKey, public key under prefix %02x with y changed", prefix);
        expect(importKey(changedPublic, publicLength, ccECKeyPublic), 0, privateKey, what);
        snprintf(what, sizeof what, "CCECCryptorImportKey, private key with an on-curve public point under prefix %02x", prefix);
        expect(importKey(privateBytes, privateLength, ccECKeyPrivate), 1, privateKey, what);
        snprintf(what, sizeof what, "CCECCryptorImportKey, private key under prefix %02x whose public point has y changed", prefix);
        expect(importKey(changedPrivate, privateLength, ccECKeyPrivate), 0, privateKey, what);
        snprintf(what, sizeof what, "CCECCryptorImportPublicKey, on-curve key under prefix %02x", prefix);
        expect(importPublicKey(publicBytes, publicLength), 1, privateKey, what);
        snprintf(what, sizeof what, "CCECCryptorImportPublicKey, key under prefix %02x with y changed", prefix);
        expect(importPublicKey(changedPublic, publicLength), 0, privateKey, what);
    }

    CCECCryptorRelease(publicKey);
    CCECCryptorRelease(privateKey);
}

// P-224, P-521: every constructor rejects a point of 0x04 bytes.
static void checkOffCurveOnly(size_t bits)
{
    size_t fieldBytes = (bits + 7) / 8;
    uint8_t fours[1 + 3 * 66];
    memset(fours, 4, sizeof fours);
    char what[120];
    printf(" P-%zu\n", bits);
    snprintf(what, sizeof what, "CCECCryptorImportKey, %zu bytes of 0x04 as a public key", 1 + 2 * fieldBytes);
    expect(importKey(fours, 1 + 2 * fieldBytes, ccECKeyPublic), 0, NULL, what);
    snprintf(what, sizeof what, "CCECCryptorImportKey, %zu bytes of 0x04 as a private key", 1 + 3 * fieldBytes);
    expect(importKey(fours, 1 + 3 * fieldBytes, ccECKeyPrivate), 0, NULL, what);
    expect(importPublicKey(fours, 1 + 2 * fieldBytes), 0, NULL, "CCECCryptorImportPublicKey, 0x04 bytes");
    expect(createFromData(bits, fours, fieldBytes, fours, fieldBytes), 0, NULL, "CCECCryptorCreateFromData, 0x04-byte coordinates");
}

// LayoutTests/http/wpt/push-api/constants.js VALID_SERVER_KEY.
static const uint8_t pushServerKey[65] = { 4, 13, 71, 199, 60, 162, 213, 21, 12, 213, 190, 112, 143, 27, 39, 238, 113, 177, 2, 204, 240, 218, 238, 181, 155, 94, 184, 139, 115, 43, 0, 140, 71, 23, 166, 10, 230, 30, 18, 13, 136, 156, 249, 212, 110, 83, 244, 66, 60, 39, 192, 229, 170, 189, 162, 52, 176, 147, 150, 54, 18, 96, 165, 4, 251 };

static void checkP256Encodings(void)
{
    uint8_t bytes[66];
    printf(" P-256 encodings\n");
    memset(bytes, 4, 65);
    expect(importKey(bytes, 65, ccECKeyPublic), 0, NULL, "65 bytes of 0x04 (the WPT push-api INVALID_SERVER_KEY)");
    memset(bytes, 0, 65);
    bytes[0] = 4;
    expect(importKey(bytes, 65, ccECKeyPublic), 0, NULL, "04 || (0, 0)");
    memset(bytes, 0, 65);
    expect(importKey(bytes, 1, ccECKeyPublic), 0, NULL, "the one-byte point at infinity");
    expect(importKey(bytes, 65, ccECKeyPublic), 0, NULL, "65 zero bytes");
    memcpy(bytes, pushServerKey, 65);
    bytes[0] = 3;
    expect(importKey(bytes, 65, ccECKeyPublic), 0, NULL, "the push-api VALID_SERVER_KEY under a compressed-form prefix");
    expect(importKey(pushServerKey, 64, ccECKeyPublic), 0, NULL, "the push-api VALID_SERVER_KEY truncated to 64 bytes");
    memcpy(bytes, pushServerKey, 65);
    bytes[65] = 0;
    expect(importKey(bytes, 66, ccECKeyPublic), 0, NULL, "the push-api VALID_SERVER_KEY with a trailing byte");
    CCECCryptorRef key = importKey(pushServerKey, 65, ccECKeyPublic);
    check(key != NULL, "the push-api VALID_SERVER_KEY imports");
    if (key)
        CCECCryptorRelease(key);
}

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    checkGeneratedCurve(192);
    checkGeneratedCurve(256);
    checkGeneratedCurve(384);
    checkOffCurveOnly(224);
    checkOffCurveOnly(521);
    checkP256Encodings();
    printf("libcommonCrypto-ec-public-point: %s\n", failures ? "FAILED" : "passed");
    return failures ? 1 : 0;
}
