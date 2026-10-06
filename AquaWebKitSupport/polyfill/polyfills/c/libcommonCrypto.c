// libcommonCrypto: 10.9 builds an EC key from any point. CCECCryptorImportKey decodes a binary public key,
// and the public point leading a binary private key, without checking that the point lies on the curve;
// CCECCryptorCreateFromData does the same with coordinates; and CCECCryptorComputeSharedSecret runs ECDH
// on the point the peer key carries. The vendored BoringSSL decides here, for every point 10.9 would
// decode on the five curves it constructs: the coordinates must be below the field prime and satisfy the
// curve equation, or the key is not built and the call returns kCCDecodeError with no key, as 10.9 does
// for an encoding it cannot decode. P-192, which BoringSSL does not name, is built from its SEC 2
// parameters. Inputs 10.9 does not decode as a point on those curves go to 10.9.

#include "wk_polyfill.h"

#include <CommonCrypto/CommonCryptoError.h>
#include <stddef.h>
#include <stdint.h>

#include <openssl/bn.h>
#include <openssl/ec.h>
#include <openssl/nid.h>

typedef struct _CCECCryptor *CCECCryptorRef;
typedef uint32_t CCECKeyExternalFormat;
typedef uint32_t CCECKeyType;
enum { kCCImportKeyBinary = 0 };
enum { ccECKeyPublic = 0, ccECKeyPrivate = 1 };

// SEC 2 secp192r1.
static const uint8_t secp192r1Prime[24] = {
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xFF, 0xFF, 0xFF, 0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
static const uint8_t secp192r1A[24] = {
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xFF, 0xFF, 0xFF, 0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFC };
static const uint8_t secp192r1B[24] = {
    0x64, 0x21, 0x05, 0x19, 0xE5, 0x9C, 0x80, 0xE7, 0x0F, 0xA7, 0xE9, 0xAB,
    0x72, 0x24, 0x30, 0x49, 0xFE, 0xB8, 0xDE, 0xEC, 0xC1, 0x46, 0xB9, 0xB1 };
static const uint8_t secp192r1GeneratorX[24] = {
    0x18, 0x8D, 0xA8, 0x0E, 0xB0, 0x30, 0x90, 0xF6, 0x7C, 0xBF, 0x20, 0xEB,
    0x43, 0xA1, 0x88, 0x00, 0xF4, 0xFF, 0x0A, 0xFD, 0x82, 0xFF, 0x10, 0x12 };
static const uint8_t secp192r1GeneratorY[24] = {
    0x07, 0x19, 0x2B, 0x95, 0xFF, 0xC8, 0xDA, 0x78, 0x63, 0x10, 0x11, 0xED,
    0x6B, 0x24, 0xCD, 0xD5, 0x73, 0xF9, 0x77, 0xA1, 0x1E, 0x79, 0x48, 0x11 };
static const uint8_t secp192r1Order[24] = {
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0x99, 0xDE, 0xF8, 0x36, 0x14, 0x6B, 0xC9, 0xB1, 0xB4, 0xD2, 0x28, 0x31 };

static EC_GROUP *createSecp192r1(void)
{
    BIGNUM *prime = BN_bin2bn(secp192r1Prime, sizeof secp192r1Prime, NULL);
    BIGNUM *a = BN_bin2bn(secp192r1A, sizeof secp192r1A, NULL);
    BIGNUM *b = BN_bin2bn(secp192r1B, sizeof secp192r1B, NULL);
    BIGNUM *generatorX = BN_bin2bn(secp192r1GeneratorX, sizeof secp192r1GeneratorX, NULL);
    BIGNUM *generatorY = BN_bin2bn(secp192r1GeneratorY, sizeof secp192r1GeneratorY, NULL);
    BIGNUM *order = BN_bin2bn(secp192r1Order, sizeof secp192r1Order, NULL);
    EC_GROUP *group = (prime && a && b) ? EC_GROUP_new_curve_GFp(prime, a, b, NULL) : NULL;
    EC_POINT *generator = group ? EC_POINT_new(group) : NULL;
    if (group && !(generator && generatorX && generatorY && order
        && EC_POINT_set_affine_coordinates_GFp(group, generator, generatorX, generatorY, NULL)
        && EC_GROUP_set_generator(group, generator, order, BN_value_one()))) {
        EC_GROUP_free(group);
        group = NULL;
    }
    EC_POINT_free(generator);
    BN_free(order);
    BN_free(generatorY);
    BN_free(generatorX);
    BN_free(b);
    BN_free(a);
    BN_free(prime);
    return group;
}

static int isConstructedCurveSize(size_t bits)
{
    return bits == 192 || bits == 224 || bits == 256 || bits == 384 || bits == 521;
}

static EC_GROUP *createGroup(size_t bits)
{
    switch (bits) {
    case 192:
        return createSecp192r1();
    case 224:
        return EC_GROUP_new_by_curve_name(NID_secp224r1);
    case 256:
        return EC_GROUP_new_by_curve_name(NID_X9_62_prime256v1);
    case 384:
        return EC_GROUP_new_by_curve_name(NID_secp384r1);
    case 521:
        return EC_GROUP_new_by_curve_name(NID_secp521r1);
    }
    return NULL;
}

// The coordinates are big-endian integers of any length, as 10.9 reads them.
static int isPointOnCurve(size_t bits, const uint8_t *x, size_t xLength, const uint8_t *y, size_t yLength)
{
    EC_GROUP *group = createGroup(bits);
    BIGNUM *prime = BN_new();
    BIGNUM *affineX = (x || !xLength) ? BN_bin2bn(x, xLength, NULL) : NULL;
    BIGNUM *affineY = (y || !yLength) ? BN_bin2bn(y, yLength, NULL) : NULL;
    EC_POINT *point = group ? EC_POINT_new(group) : NULL;
    int onCurve = point && prime && affineX && affineY
        && EC_GROUP_get_curve_GFp(group, prime, NULL, NULL, NULL)
        && BN_ucmp(affineX, prime) < 0 && BN_ucmp(affineY, prime) < 0
        && EC_POINT_set_affine_coordinates_GFp(group, point, affineX, affineY, NULL)
        && !EC_POINT_is_at_infinity(group, point)
        && EC_POINT_is_on_curve(group, point, NULL) == 1;
    EC_POINT_free(point);
    BN_free(affineY);
    BN_free(affineX);
    BN_free(prime);
    EC_GROUP_free(group);
    return onCurve;
}

// The binary (ANSI X9.63) keys 10.9 decodes: prefix || X || Y for a public key, followed by the scalar for
// a private one. 10.9 reads X and Y after the uncompressed prefix (04) and both hybrid prefixes (06, 07),
// without comparing a hybrid prefix with the parity of Y.
static int isPointPrefix(uint8_t prefix)
{
    return prefix == 0x04 || prefix == 0x06 || prefix == 0x07;
}

static size_t curveSizeForBinaryKey(CCECKeyType keyType, size_t length)
{
    static const size_t sizes[] = { 192, 224, 256, 384, 521 };
    for (size_t i = 0; i < sizeof sizes / sizeof sizes[0]; i++) {
        size_t fieldBytes = (sizes[i] + 7) / 8;
        if ((keyType == ccECKeyPublic && length == 1 + 2 * fieldBytes) || (keyType == ccECKeyPrivate && length == 1 + 3 * fieldBytes))
            return sizes[i];
    }
    return 0;
}

WK_POLYFILL_REPLACES("/usr/lib/system/libcommonCrypto.dylib", CCCryptorStatus, CCECCryptorImportKey,
    (CCECKeyExternalFormat format, const void *keyPackage, size_t keyPackageLen, CCECKeyType keyType, CCECCryptorRef *key))
{
    size_t bits = (format == kCCImportKeyBinary && keyPackage) ? curveSizeForBinaryKey(keyType, keyPackageLen) : 0;
    const uint8_t *bytes = keyPackage;
    if (bits && isPointPrefix(bytes[0])) {
        size_t fieldBytes = (bits + 7) / 8;
        if (!isPointOnCurve(bits, bytes + 1, fieldBytes, bytes + 1 + fieldBytes, fieldBytes)) {
            if (key)
                *key = NULL;
            return kCCDecodeError;
        }
    }
    return WK_ORIGINAL(CCECCryptorImportKey)(format, keyPackage, keyPackageLen, keyType, key);
}

// 10.9's is this call, made into its own CCECCryptorImportKey.
WK_POLYFILL_REPLACES("/usr/lib/system/libcommonCrypto.dylib", CCCryptorStatus, CCECCryptorImportPublicKey,
    (const void *keyPackage, size_t keyPackageLen, CCECCryptorRef *key))
{
    return CCECCryptorImportKey(kCCImportKeyBinary, keyPackage, keyPackageLen, ccECKeyPublic, key);
}

WK_POLYFILL_REPLACES("/usr/lib/system/libcommonCrypto.dylib", CCCryptorStatus, CCECCryptorCreateFromData,
    (size_t keySize, uint8_t *qX, size_t qXLength, uint8_t *qY, size_t qYLength, CCECCryptorRef *ref))
{
    if (isConstructedCurveSize(keySize) && !isPointOnCurve(keySize, qX, qXLength, qY, qYLength)) {
        *ref = NULL;
        return kCCDecodeError;
    }
    return WK_ORIGINAL(CCECCryptorCreateFromData)(keySize, qX, qXLength, qY, qYLength, ref);
}
