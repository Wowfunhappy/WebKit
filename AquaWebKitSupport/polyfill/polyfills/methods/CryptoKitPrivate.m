// CryptoKitPrivate: the RSA blind-signature token classes (RSABSSATokenBlinder, RSABSSATokenWaitingActivation,
// RSABSSATokenReady) that Private Click Measurement's unlinkable tokens are built with. 10.9 ships no
// CryptoKitPrivate.framework; PAL soft-links the framework and then RSABSSATokenBlinder by name, which the
// absent-provider token and the WK_POLYFILL_CLASS registrations below answer. They live in WebCore, which
// links the vendored BoringSSL they are written with.
//
// The scheme is RFC 9474's RSABSSA-SHA384-PSS-Deterministic: SHA-384 for the message hash and MGF1, a
// 48-byte PSS salt, and the token content signed as it is, with no randomizing prefix. A finished token
// verifies as an ordinary RSASSA-PSS signature of its content. The key is a 2048-, 3072- or 4096-bit RSA
// SubjectPublicKeyInfo; its identifier is the SHA-256 of those bytes, which is what
// PrivateClickMeasurementManager recomputes from the key it fetches before it sends a report. A token
// created without content carries 32 random bytes.

#import "../classes/wk_priv_class.h"
#import <Foundation/Foundation.h>

#include <openssl/bn.h>
#include <openssl/bytestring.h>
#include <openssl/digest.h>
#include <openssl/mem.h>
#include <openssl/rand.h>
#include <openssl/rsa.h>
#include <openssl/sha.h>

#define WK_CRYPTOKIT_PRIVATE "/System/Library/PrivateFrameworks/CryptoKitPrivate.framework/CryptoKitPrivate"

// corecrypto's codes for the failures the token operations report.
enum {
    WKRSABSSAErrorInternal = -1,
    WKRSABSSAErrorParameter = -7,
    WKRSABSSAErrorKey = -28,
    WKRSABSSAErrorInvalidSignature = -146,
};

static const size_t WKRSABSSASaltLength = 48;
static const size_t WKRSABSSARandomContentLength = 32;

static BOOL WKRSABSSAFail(NSError **error, NSInteger code, NSString *description)
{
    if (error)
        *error = [NSError errorWithDomain:@"CryptoKitPrivate.RSABSSA" code:code
                                 userInfo:@{ NSLocalizedDescriptionKey: description }];
    return NO;
}

WK_PRIV_CLASS(RSABSSATokenReady) __attribute__((visibility("hidden")))
@interface RSABSSATokenReady : NSObject {
    NSData *_tokenContent;
    NSData *_keyId;
    NSData *_signature;
}
@property (nonatomic, retain, readonly) NSData *tokenContent;
@property (nonatomic, retain, readonly) NSData *keyId;
@property (nonatomic, retain, readonly) NSData *signature;
@end

@class RSABSSATokenBlinder;

WK_PRIV_CLASS(RSABSSATokenWaitingActivation) __attribute__((visibility("hidden")))
@interface RSABSSATokenWaitingActivation : NSObject {
    RSABSSATokenBlinder *_blinder;
    NSData *_content;
    NSData *_blindedMessage;
    BIGNUM *_blindingInverse;
}
- (RSABSSATokenReady *)activateTokenWithServerResponse:(NSData *)serverResponse error:(NSError **)error;
@property (nonatomic, retain, readonly) NSData *blindedMessage;
@end

WK_PRIV_CLASS(RSABSSATokenBlinder) __attribute__((visibility("hidden")))
@interface RSABSSATokenBlinder : NSObject {
@package
    RSA *_publicKey;
    NSData *_keyId;
}
- (instancetype)initWithPublicKey:(NSData *)spkiBytes error:(NSError **)error;
- (RSABSSATokenWaitingActivation *)tokenWaitingActivationWithContent:(NSData *)content error:(NSError **)error;
@property (nonatomic, retain, readonly) NSData *keyId;
@end

@implementation RSABSSATokenReady

- (instancetype)initWithTokenContent:(NSData *)tokenContent keyId:(NSData *)keyId signature:(NSData *)signature
{
    if (!(self = [super init]))
        return nil;
    _tokenContent = [tokenContent copy];
    _keyId = [keyId copy];
    _signature = [signature copy];
    return self;
}

- (void)dealloc
{
    [_tokenContent release];
    [_keyId release];
    [_signature release];
    [super dealloc];
}

- (NSData *)tokenContent { return _tokenContent; }
- (NSData *)keyId { return _keyId; }
- (NSData *)signature { return _signature; }

@end

// The RSASSA-PSS verification the finished token has to pass.
static BOOL WKRSABSSAVerify(RSA *key, NSData *content, const uint8_t *signature, size_t signatureLength)
{
    uint8_t digest[SHA384_DIGEST_LENGTH];
    SHA384(content.bytes, content.length, digest);
    return RSA_verify_pss_mgf1(key, digest, sizeof digest, EVP_sha384(), EVP_sha384(), (int)WKRSABSSASaltLength,
        signature, signatureLength) == 1;
}

@implementation RSABSSATokenWaitingActivation

- (instancetype)initWithBlinder:(RSABSSATokenBlinder *)blinder content:(NSData *)content
    blindedMessage:(NSData *)blindedMessage blindingInverse:(BIGNUM *)blindingInverse
{
    if (!(self = [super init])) {
        BN_clear_free(blindingInverse);
        return nil;
    }
    _blinder = [blinder retain];
    _content = [content copy];
    _blindedMessage = [blindedMessage copy];
    _blindingInverse = blindingInverse;
    return self;
}

- (void)dealloc
{
    [_blinder release];
    [_content release];
    [_blindedMessage release];
    BN_clear_free(_blindingInverse);
    [super dealloc];
}

- (NSData *)blindedMessage { return _blindedMessage; }

// Finalize: unblind the server's blind signature and verify the result.
- (RSABSSATokenReady *)activateTokenWithServerResponse:(NSData *)serverResponse error:(NSError **)error
{
    RSA *key = _blinder->_publicKey;
    size_t modulusBytes = RSA_size(key);
    if (serverResponse.length != modulusBytes) {
        WKRSABSSAFail(error, WKRSABSSAErrorParameter, @"The blind signature is not the size of the key's modulus.");
        return nil;
    }

    NSMutableData *signature = [NSMutableData dataWithLength:modulusBytes];
    BN_CTX *context = BN_CTX_new();
    BIGNUM *blindSignature = BN_bin2bn(serverResponse.bytes, serverResponse.length, NULL);
    BIGNUM *unblinded = BN_new();
    BOOL computed = context && blindSignature && unblinded
        && BN_mod_mul(unblinded, blindSignature, _blindingInverse, RSA_get0_n(key), context)
        && BN_bn2bin_padded(signature.mutableBytes, modulusBytes, unblinded);
    BN_free(unblinded);
    BN_free(blindSignature);
    BN_CTX_free(context);
    if (!computed) {
        WKRSABSSAFail(error, WKRSABSSAErrorInternal, @"The blind signature could not be unblinded.");
        return nil;
    }
    if (!WKRSABSSAVerify(key, _content, signature.bytes, modulusBytes)) {
        WKRSABSSAFail(error, WKRSABSSAErrorInvalidSignature, @"The unblinded signature does not verify with the key.");
        return nil;
    }
    return [[[RSABSSATokenReady alloc] initWithTokenContent:_content keyId:_blinder.keyId signature:signature] autorelease];
}

@end

// The RSAPublicKey inside a SubjectPublicKeyInfo whose algorithm is rsaEncryption or id-RSASSA-PSS.
static RSA *WKRSABSSAParseSubjectPublicKeyInfo(NSData *spkiBytes)
{
    static const uint8_t rsaEncryption[] = { 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01 };
    static const uint8_t rsassaPSS[] = { 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0A };

    CBS input, spki, algorithm, oid, parameters, bitString, rsaPublicKey;
    uint8_t unusedBits;
    CBS_init(&input, spkiBytes.bytes, spkiBytes.length);
    if (!CBS_get_asn1(&input, &spki, CBS_ASN1_SEQUENCE) || CBS_len(&input)
        || !CBS_get_asn1(&spki, &algorithm, CBS_ASN1_SEQUENCE)
        || !CBS_get_asn1(&algorithm, &oid, CBS_ASN1_OBJECT)
        || (CBS_len(&algorithm) && (!CBS_get_any_asn1_element(&algorithm, &parameters, NULL, NULL) || CBS_len(&algorithm)))
        || !CBS_get_asn1(&spki, &bitString, CBS_ASN1_BITSTRING) || CBS_len(&spki)
        || !CBS_get_u8(&bitString, &unusedBits) || unusedBits)
        return NULL;
    if (!CBS_mem_equal(&oid, rsaEncryption, sizeof rsaEncryption) && !CBS_mem_equal(&oid, rsassaPSS, sizeof rsassaPSS))
        return NULL;

    rsaPublicKey = bitString;
    RSA *key = RSA_parse_public_key(&rsaPublicKey);
    if (key && CBS_len(&rsaPublicKey)) {
        RSA_free(key);
        return NULL;
    }
    return key;
}

@implementation RSABSSATokenBlinder

- (instancetype)initWithPublicKey:(NSData *)spkiBytes error:(NSError **)error
{
    if (!(self = [super init]))
        return nil;

    _publicKey = WKRSABSSAParseSubjectPublicKeyInfo(spkiBytes);
    if (!_publicKey) {
        WKRSABSSAFail(error, WKRSABSSAErrorParameter, @"The public key is not an RSA SubjectPublicKeyInfo.");
        [self release];
        return nil;
    }
    unsigned modulusBits = RSA_bits(_publicKey);
    if (modulusBits != 2048 && modulusBits != 3072 && modulusBits != 4096) {
        WKRSABSSAFail(error, WKRSABSSAErrorKey, @"The public key's modulus is not 2048, 3072 or 4096 bits.");
        [self release];
        return nil;
    }

    uint8_t keyId[SHA256_DIGEST_LENGTH];
    SHA256(spkiBytes.bytes, spkiBytes.length, keyId);
    _keyId = [[NSData alloc] initWithBytes:keyId length:sizeof keyId];
    return self;
}

- (void)dealloc
{
    RSA_free(_publicKey);
    [_keyId release];
    [super dealloc];
}

- (NSData *)keyId { return _keyId; }

// Blind: PSS-encode the content and multiply it by r^e for a fresh random r, keeping r^-1 to unblind with.
- (RSABSSATokenWaitingActivation *)tokenWaitingActivationWithContent:(NSData *)content error:(NSError **)error
{
    NSData *message = content;
    if (!message) {
        NSMutableData *random = [NSMutableData dataWithLength:WKRSABSSARandomContentLength];
        RAND_bytes(random.mutableBytes, random.length);
        message = random;
    }

    const BIGNUM *modulus = RSA_get0_n(_publicKey);
    size_t modulusBytes = RSA_size(_publicKey);
    uint8_t digest[SHA384_DIGEST_LENGTH];
    SHA384(message.bytes, message.length, digest);

    NSMutableData *encoded = [NSMutableData dataWithLength:modulusBytes];
    NSMutableData *blinded = [NSMutableData dataWithLength:modulusBytes];
    BN_CTX *context = BN_CTX_new();
    BN_MONT_CTX *montgomery = context ? BN_MONT_CTX_new_for_modulus(modulus, context) : NULL;
    BIGNUM *encodedMessage = NULL;
    BIGNUM *r = BN_new();
    BIGNUM *rInverse = BN_new();
    BIGNUM *x = BN_new();
    int noInverse = 0;
    BOOL computed = montgomery && r && rInverse && x
        && RSA_padding_add_PKCS1_PSS_mgf1(_publicKey, encoded.mutableBytes, digest, EVP_sha384(), EVP_sha384(),
            (int)WKRSABSSASaltLength)
        && (encodedMessage = BN_bin2bn(encoded.bytes, modulusBytes, NULL))
        && BN_rand_range_ex(r, 1, modulus)
        && BN_mod_inverse_blinded(rInverse, &noInverse, r, montgomery, context)
        && BN_mod_exp_mont(x, r, RSA_get0_e(_publicKey), modulus, context, montgomery)
        && BN_mod_mul(x, encodedMessage, x, modulus, context)
        && BN_bn2bin_padded(blinded.mutableBytes, modulusBytes, x);
    OPENSSL_cleanse(encoded.mutableBytes, encoded.length);
    BN_clear_free(encodedMessage);
    BN_clear_free(r);
    BN_clear_free(x);
    BN_MONT_CTX_free(montgomery);
    BN_CTX_free(context);
    if (!computed) {
        BN_clear_free(rInverse);
        WKRSABSSAFail(error, WKRSABSSAErrorInternal, @"The token content could not be blinded.");
        return nil;
    }

    return [[[RSABSSATokenWaitingActivation alloc] initWithBlinder:self content:message blindedMessage:blinded
        blindingInverse:rInverse] autorelease];
}

@end

WK_POLYFILL_CLASS(WK_CRYPTOKIT_PRIVATE, RSABSSATokenBlinder);
WK_POLYFILL_CLASS(WK_CRYPTOKIT_PRIVATE, RSABSSATokenWaitingActivation);
WK_POLYFILL_CLASS(WK_CRYPTOKIT_PRIVATE, RSABSSATokenReady);
