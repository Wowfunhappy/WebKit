// libcorecrypto: the RSA blind-signature signer (ccrsabssa, RFC 9474's BlindSign) and the two entry points
// around it that 10.9's corecrypto lacks. 10.9 has the RSA key itself -- ccrsa_generate_key and the
// ccder_encode_rsa_* serialisers -- so a key is always one 10.9's corecrypto built, and it reaches the
// vendored BoringSSL as the PKCS #1 RSAPrivateKey that corecrypto encodes it to.

#include "wk_polyfill.h"

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <openssl/bn.h>
#include <openssl/bytestring.h>
#include <openssl/mem.h>
#include <openssl/rand.h>
#include <openssl/rsa.h>

#define CORECRYPTO "/usr/lib/system/libcorecrypto.dylib"

typedef uint64_t cc_unit;
typedef size_t cc_size;
struct ccrsa_full_ctx;
struct ccrsa_pub_ctx;
struct ccdigest_info;
typedef struct ccrsa_full_ctx *ccrsa_full_ctx_t;
typedef struct ccrsa_pub_ctx *ccrsa_pub_ctx_t;

enum {
    CCERR_OK = 0,
    CCERR_PARAMETER = -7,
    CCERR_MEMORY = -8,
    CCRSA_INVALID_INPUT = -23,
    CCRSA_PRIVATE_OP_ERROR = -27,
    CCRSA_KEY_ERROR = -28,
};

struct ccrng_state {
    int (*generate)(struct ccrng_state *rng, size_t outlen, void *out);
};

struct ccrsabssa_ciphersuite {
    size_t rsa_modulus_nbits;
    const struct ccdigest_info *(*di)(void);
    size_t salt_size_nbytes;
};

// 10.9's corecrypto.
const struct ccdigest_info *ccsha384_di(void);
int ccrsa_get_pubkey_components(ccrsa_pub_ctx_t pubkey, uint8_t *modulus, size_t *modulusLength,
                                uint8_t *exponent, size_t *exponentLength);
size_t ccder_encode_rsa_priv_size(ccrsa_full_ctx_t key);
uint8_t *ccder_encode_rsa_priv(ccrsa_full_ctx_t key, const uint8_t *der, uint8_t *der_end);

// The process RNG. Every caller gets the same state; its generator is BoringSSL's CSPRNG.
static int wk_ccrng_generate(struct ccrng_state *rng, size_t outlen, void *out)
{
    (void)rng;
    RAND_bytes(out, outlen);
    return CCERR_OK;
}

static struct ccrng_state wk_ccrng_state = { wk_ccrng_generate };

WK_POLYFILL_ABSENT(CORECRYPTO, struct ccrng_state *, ccrng, (int *error))
{
    if (error)
        *error = CCERR_OK;
    return &wk_ccrng_state;
}

// The bit length of the key's modulus. The key's first word, ccrsa_ctx_n, bounds the modulus's size;
// corecrypto reports the modulus's bytes.
WK_POLYFILL_ABSENT(CORECRYPTO, size_t, ccrsa_pubkeylength, (ccrsa_pub_ctx_t pubk))
{
    size_t capacity = *(const cc_size *)pubk * sizeof(cc_unit);
    uint8_t *modulus = malloc(capacity);
    uint8_t *exponent = malloc(capacity);
    size_t modulusLength = capacity;
    size_t exponentLength = capacity;
    size_t bits = 0;
    if (modulus && exponent
        && !ccrsa_get_pubkey_components(pubk, modulus, &modulusLength, exponent, &exponentLength)) {
        size_t leading = 0;
        while (leading < modulusLength && !modulus[leading])
            leading++;
        if (leading < modulusLength) {
            bits = (modulusLength - leading) * 8;
            for (uint8_t top = modulus[leading]; !(top & 0x80); top <<= 1)
                bits--;
        }
    }
    free(modulus);
    free(exponent);
    return bits;
}

// RSABSSA with SHA-384 as the message hash and the MGF1 hash, and a 48-byte PSS salt.
const struct ccrsabssa_ciphersuite ccrsabssa_ciphersuite_rsa4096_sha384 = {
    .rsa_modulus_nbits = 4096,
    .di = ccsha384_di,
    .salt_size_nbytes = 48,
};
WK_PF_ENTRY(ccrsabssa_ciphersuite_rsa4096_sha384, CORECRYPTO, &ccrsabssa_ciphersuite_rsa4096_sha384,
            WK_POLYFILL_CONSTANT, WK_POLYFILL_GAP_FILL);

static RSA *wk_ccrsa_copy_private_key(ccrsa_full_ctx_t key)
{
    size_t derSize = ccder_encode_rsa_priv_size(key);
    uint8_t *der = malloc(derSize);
    if (!der)
        return NULL;
    RSA *rsa = NULL;
    const uint8_t *start = ccder_encode_rsa_priv(key, der, der + derSize);
    if (start) {
        CBS cbs;
        CBS_init(&cbs, start, (size_t)(der + derSize - start));
        rsa = RSA_parse_private_key(&cbs);
        if (rsa && CBS_len(&cbs)) {
            RSA_free(rsa);
            rsa = NULL;
        }
    }
    OPENSSL_cleanse(der, derSize);
    free(der);
    return rsa;
}

// BlindSign: the RSA private-key operation on the client's blinded message. BoringSSL's private operation
// blinds its exponentiation with its own CSPRNG and checks the result against the public exponent, the
// two protections blinding_rng serves in corecrypto.
WK_POLYFILL_ABSENT(CORECRYPTO, int, ccrsabssa_sign_blinded_message,
    (const struct ccrsabssa_ciphersuite *ciphersuite, const ccrsa_full_ctx_t key,
     const uint8_t *blinded_message, const size_t blinded_message_nbytes,
     uint8_t *signature, const size_t signature_nbytes, struct ccrng_state *blinding_rng))
{
    (void)blinding_rng;
    size_t modulusBits = ccrsa_pubkeylength((ccrsa_pub_ctx_t)key);
    if (modulusBits != ciphersuite->rsa_modulus_nbits)
        return CCERR_PARAMETER;
    size_t modulusBytes = (modulusBits + 7) / 8;
    if (signature_nbytes != modulusBytes || blinded_message_nbytes != modulusBytes)
        return CCERR_PARAMETER;

    RSA *rsa = wk_ccrsa_copy_private_key(key);
    if (!rsa)
        return CCRSA_KEY_ERROR;

    int status = CCERR_MEMORY;
    uint8_t *result = malloc(modulusBytes);
    BIGNUM *input = BN_bin2bn(blinded_message, blinded_message_nbytes, NULL);
    BIGNUM *limit = BN_dup(RSA_get0_n(rsa));
    if (!result || !input || !limit)
        goto done;
    if (BN_ucmp(input, limit) >= 0) {
        status = CCERR_PARAMETER;
        goto done;
    }
    if (!BN_sub_word(limit, 1))
        goto done;
    if (BN_ucmp(input, limit) >= 0) {
        status = CCRSA_INVALID_INPUT;
        goto done;
    }

    size_t resultLength = 0;
    status = RSA_decrypt(rsa, &resultLength, result, modulusBytes, blinded_message, blinded_message_nbytes, RSA_NO_PADDING)
        && resultLength == modulusBytes ? CCERR_OK : CCRSA_PRIVATE_OP_ERROR;
    if (status == CCERR_OK)
        memcpy(signature, result, modulusBytes);

done:
    if (result) {
        OPENSSL_cleanse(result, modulusBytes);
        free(result);
    }
    BN_free(input);
    BN_free(limit);
    RSA_free(rsa);
    return status;
}
