// The raw and JWK EC public-key imports in Source/WebCore/crypto/gcrypt/CryptoKeyECGCrypt.cpp, against the
// vendored libgcrypt. publicKeyPointIsOnCurve makes the same calls as the import helper: invalid
// points must be rejected by either key construction or validation, and valid keys must derive a secret.
#include <gcrypt.h>
#include <stdio.h>
#include <string.h>

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-72s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok)
        failures++;
}

static int publicKeyPointIsOnCurve(gcry_sexp_t publicKey)
{
    gcry_ctx_t context = NULL;
    gcry_error_t error = gcry_mpi_ec_new(&context, publicKey, NULL);
    if (error != GPG_ERR_NO_ERROR)
        return 0;

    gcry_mpi_point_t point = gcry_mpi_ec_get_point("q", context, 1);
    int onCurve = point && gcry_mpi_ec_curve_point(point, context);
    gcry_mpi_point_release(point);
    gcry_ctx_release(context);
    return onCurve;
}

// The key CryptoKeyEC::platformImportRaw builds.
static gcry_sexp_t importRaw(const unsigned char *q, size_t length)
{
    gcry_sexp_t key = NULL;
    if (gcry_sexp_build(&key, NULL, "(public-key(ecc(curve %s)(q %b)))", "NIST P-256", (int)length, q))
        return NULL;
    return key;
}

// gcryptDerive in CryptoAlgorithmECDHGCrypt.cpp: the private scalar, encrypted with the peer's public key.
static int derivesSecret(gcry_sexp_t privateKey, gcry_sexp_t publicKey)
{
    gcry_sexp_t d = gcry_sexp_find_token(privateKey, "d", 0);
    gcry_mpi_t dValue = d ? gcry_sexp_nth_mpi(d, 1, GCRYMPI_FMT_USG) : NULL;
    unsigned char dBytes[64];
    size_t dLength = 0;
    gcry_sexp_t data = NULL, cipher = NULL, s = NULL;
    int derived = dValue && !gcry_mpi_print(GCRYMPI_FMT_USG, dBytes, sizeof dBytes, &dLength, dValue)
        && !gcry_sexp_build(&data, NULL, "(data(flags raw)(value %b))", (int)dLength, dBytes)
        && !gcry_pk_encrypt(&cipher, data, publicKey)
        && (s = gcry_sexp_find_token(cipher, "s", 0));
    gcry_sexp_release(s);
    gcry_sexp_release(cipher);
    gcry_sexp_release(data);
    gcry_mpi_release(dValue);
    gcry_sexp_release(d);
    return derived;
}

int main(void)
{
    gcry_check_version(NULL);
    gcry_control(GCRYCTL_INIT_SECMEM, 16384, NULL);
    gcry_control(GCRYCTL_INITIALIZATION_FINISHED, NULL);

    gcry_sexp_t parameters = NULL, pair = NULL;
    if (gcry_sexp_build(&parameters, NULL, "(genkey(ecc(curve %s)))", "NIST P-256") || gcry_pk_genkey(&pair, parameters)) {
        printf("libgcrypt-ec-public-point: could not generate a P-256 key pair\n");
        return 1;
    }
    gcry_sexp_t privateKey = gcry_sexp_find_token(pair, "private-key", 0);
    gcry_sexp_t peerPublic = gcry_sexp_find_token(pair, "public-key", 0);
    gcry_sexp_t peerQ = peerPublic ? gcry_sexp_find_token(peerPublic, "q", 0) : NULL;
    size_t qLength = 0;
    const char *qData = peerQ ? gcry_sexp_nth_data(peerQ, 1, &qLength) : NULL;
    if (!privateKey || !qData || qLength != 65) {
        printf("libgcrypt-ec-public-point: the generated key pair has no 65-byte q\n");
        return 1;
    }

    unsigned char onCurve[65], yChanged[65], fours[65];
    memcpy(onCurve, qData, 65);
    memcpy(yChanged, onCurve, 65);
    yChanged[64] ^= 1;
    memset(fours, 4, 65);

    gcry_sexp_t valid = importRaw(onCurve, 65);
    gcry_sexp_t offCurve = importRaw(yChanged, 65);
    gcry_sexp_t allFours = importRaw(fours, 65);

    check(!offCurve || !publicKeyPointIsOnCurve(offCurve), "key import rejects the changed-y point");
    check(!allFours || !publicKeyPointIsOnCurve(allFours), "key import rejects 65 bytes of 0x04");
    check(valid && publicKeyPointIsOnCurve(valid), "publicKeyPointIsOnCurve accepts an on-curve point");
    check(valid && derivesSecret(privateKey, valid), "ECDH derives a secret from the on-curve point");

    gcry_sexp_release(allFours);
    gcry_sexp_release(offCurve);
    gcry_sexp_release(valid);
    gcry_sexp_release(peerQ);
    gcry_sexp_release(peerPublic);
    gcry_sexp_release(privateKey);
    gcry_sexp_release(pair);
    gcry_sexp_release(parameters);

    printf("libgcrypt-ec-public-point: %s\n", failures ? "FAILED" : "passed");
    return failures ? 1 : 0;
}
