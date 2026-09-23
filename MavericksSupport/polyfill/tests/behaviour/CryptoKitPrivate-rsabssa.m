// RSA blind signatures for Private Click Measurement, both halves (polyfills/methods/CryptoKitPrivate.m and
// polyfills/c/libcorecrypto.c), in the topology WebCore and TestWebKitAPI form: the classes and libpolyfill.a
// in one image, a key from 10.9's own corecrypto, and the signer the API tests play the server with.
//
// Interoperability is checked against two outside sources. RFC 9474's RSABSSA-SHA384-PSS-Deterministic
// vector (A.3, also corecrypto's ccrsabssa vector) fixes Finalize bit for bit. The token and
// signature WebKit's PCM announcement (webkit.org/blog/11940) shows a browser producing verify as an
// ordinary RSASSA-PSS SHA-384 signature with a 48-byte salt over the 32-byte token, which is the variant and
// the token size the classes implement.
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdio.h>
#import <string.h>
#import <unistd.h>

#include <openssl/bn.h>
#include <openssl/bytestring.h>
#include <openssl/digest.h>
#include <openssl/mem.h>
#include <openssl/rsa.h>
#include <openssl/sha.h>

// corecrypto, as TestWebKitAPI's CoreCryptoSPI.h declares it.
typedef uint64_t cc_unit;
struct ccrng_state { int (*generate)(struct ccrng_state *, size_t, void *); };
struct ccrsabssa_ciphersuite;
extern const struct ccrsabssa_ciphersuite ccrsabssa_ciphersuite_rsa4096_sha384;
struct ccrng_state *ccrng(int *error);
int ccrsa_generate_key(size_t nbits, void *fk, size_t e_nbytes, const void *e, struct ccrng_state *);
size_t ccrsa_pubkeylength(void *pubk);
size_t ccder_encode_rsa_pub_size(const void *key);
uint8_t *ccder_encode_rsa_pub(const void *key, uint8_t *der, uint8_t *der_end);
int ccrsabssa_sign_blinded_message(const struct ccrsabssa_ciphersuite *, void *key, const uint8_t *blinded_message,
    size_t blinded_message_nbytes, uint8_t *signature, size_t signature_nbytes, struct ccrng_state *blinding_rng);

// ccrsa_full_ctx_decl(ccn_sizeof(4096), ...) in CoreCryptoSPI.h.
#define CCN_SIZEOF(bits) ((((bits) + 63) / 64) * 8)
#define FULL_CTX_SIZE(nbytes) ((24 + 8 + 3 * (nbytes)) + (nbytes) + ((24 + 8) * 2 + 7 * CCN_SIZEOF((nbytes) * 8 / 2 + 1)))

@interface NSObject (RSABSSA)
- (instancetype)initWithPublicKey:(NSData *)spkiBytes error:(NSError **)error;
- (id)tokenWaitingActivationWithContent:(NSData *)content error:(NSError **)error;
- (id)activateTokenWithServerResponse:(NSData *)serverResponse error:(NSError **)error;
- (instancetype)initWithBlinder:(id)blinder content:(NSData *)content blindedMessage:(NSData *)blindedMessage
    blindingInverse:(BIGNUM *)blindingInverse;
@property (readonly) NSData *keyId;
@property (readonly) NSData *blindedMessage;
@property (readonly) NSData *tokenContent;
@property (readonly) NSData *signature;
@end

// RFC 9474 appendix A.3.
static const char vectorP[] =
    "e1f4d7a34802e27c7392a3cea32a262a34dc3691bd87f3f310dc75673488930559c120fd0410194fb8a0da55bd0b8122"
    "7e843fdca6692ae80e5a5d414116d4803fca7d8c30eaaae57e44a1816ebb5c5b0606c536246c7f11985d731684150b63"
    "c9a3ad9e41b04c0b5b27cb188a692c84696b742a80d3cd00ab891f2457443dadfeba6d6daf108602be26d7071803c671"
    "05a5426838e6889d77e8474b29244cefaf418e381b312048b457d73419213063c60ee7b0d81820165864fef93523c963"
    "5c22210956e53a8d96322493ffc58d845368e2416e078e5bcb5d2fd68ae6acfa54f9627c42e84a9d3f2774017e32ebca"
    "06308a12ecc290c7cd1156dcccfb2311";
static const char vectorQ[] =
    "c601a9caea66dc3835827b539db9df6f6f5ae77244692780cd334a006ab353c806426b60718c05245650821d39445d3a"
    "b591ed10a7339f15d83fe13f6a3dfb20b9452c6a9b42eaa62a68c970df3cadb2139f804ad8223d56108dfde30ba7d367"
    "e9b0a7a80c4fdba2fd9dde6661fc73fc2947569d2029f2870fc02d8325acf28c9afa19ecf962daa7916e21afad09eb62"
    "fe9f1cf91b77dc879b7974b490d3ebd2e95426057f35d0a3c9f45f79ac727ab81a519a8b9285932d9b2e5ccd347e59f3"
    "f32ad9ca359115e7da008ab7406707bd0e8e185a5ed8758b5ba266e8828f8d863ae133846304a2936ad7bc7c9803879d"
    "2fc4a28e69291d73dbd799f8bc238385";
static const char vectorN[] =
    "aec4d69addc70b990ea66a5e70603b6fee27aafebd08f2d94cbe1250c556e047a928d635c3f45ee9b66d1bc628a03bac"
    "9b7c3f416fe20dabea8f3d7b4bbf7f963be335d2328d67e6c13ee4a8f955e05a3283720d3e1f139c38e43e0338ad058a"
    "9495c53377fc35be64d208f89b4aa721bf7f7d3fef837be2a80e0f8adf0bcd1eec5bb040443a2b2792fdca522a7472ae"
    "d74f31a1ebe1eebc1f408660a0543dfe2a850f106a617ec6685573702eaaa21a5640a5dcaf9b74e397fa3af18a2f1b7c"
    "03ba91a6336158de420d63188ee143866ee415735d155b7c2d854d795b7bc236cffd71542df34234221a0413e142d8c6"
    "1355cc44d45bda94204974557ac2704cd8b593f035a5724b1adf442e78c542cd4414fce6f1298182fb6d8e53cef1adfd"
    "2e90e1e4deec52999bdc6c29144e8d52a125232c8c6d75c706ea3cc06841c7bda33568c63a6c03817f722b50fcf89823"
    "7d788a4400869e44d90a3020923dc646388abcc914315215fcd1bae11b1c751fd52443aac8f601087d8d42737c18a3fa"
    "11ecd4131ecae017ae0a14acfc4ef85b83c19fed33cfd1cd629da2c4c09e222b398e18d822f77bb378dea3cb360b605e"
    "5aa58b20edc29d000a66bd177c682a17e7eb12a63ef7c2e4183e0d898f3d6bf567ba8ae84f84f1d23bf8b8e261c3729e"
    "2fa6d07b832e07cddd1d14f55325c6f924267957121902dc19b3b32948bdead5";
static const char vectorE[] =
    "010001";
static const char vectorD[] =
    "0d43242aefe1fb2c13fbc66e20b678c4336d20b1808c558b6e62ad16a287077180b177e1f01b12f9c6cd6c52630257cc"
    "ef26a45135a990928773f3bd2fc01a313f1dac97a51cec71cb1fd7efc7adffdeb05f1fb04812c924ed7f4a8269925dad"
    "88bd7dcfbc4ef01020ebfc60cb3e04c54f981fdbd273e69a8a58b8ceb7c2d83fbcbd6f784d052201b88a9848186f2a45"
    "c0d2826870733e6fd9aa46983e0a6e82e35ca20a439c5ee7b502a9062e1066493bdadf8b49eb30d9558ed85abc7afb29"
    "b3c9bc644199654a4676681af4babcea4e6f71fe4565c9c1b85d9985b84ec1abf1a820a9bbebee0df1398aae2c85ab58"
    "0a9f13e7743afd3108eb32100b870648fa6bc17e8abac4d3c99246b1f0ea9f7f93a5dd5458c56d9f3f81ff2216b3c368"
    "0a13591673c43194d8e6fc93fc1e37ce2986bd628ac48088bc723d8fbe293861ca7a9f4a73e9fa63b1b6d0074f5dea2a"
    "624c5249ff3ad811b6255b299d6bc5451ba7477f19c5a0db690c3e6476398b1483d10314afd38bbaf6e2fbdbcd62c3ca"
    "9797a420ca6034ec0a83360a3ee2adf4b9d4ba29731d131b099a38d6a23cc463db754603211260e99d19affc902c915d"
    "7854554aabf608e3ac52c19b8aa26ae042249b17b2d29669b5c859103ee53ef9bdc73ba3c6b537d5c34b6d8f034671d7"
    "f3a8a6966cc4543df223565343154140fd7391c7e7be03e241f4ecfeb877a051";
static const char vectorMessage[] =
    "8f3dc6fb8c4a02f4d6352edf0907822c1210a9b32f9bdda4c45a698c80023aa6b59f8cfec5fdbb36331372ebefedae7d";
static const char vectorInverse[] =
    "80682c48982407b489d53d1261b19ec8627d02b8cda5336750b8cee332ae260de57b02d72609c1e0e9f28e2040fc65b6"
    "f02d56dbd6aa9af8fde656f70495dfb723ba01173d4707a12fddac628ca29f3e32340bd8f7ddb557cf819f6b01e445ad"
    "96f874ba235584ee71f6581f62d4f43bf03f910f6510deb85e8ef06c7f09d9794a008be7ff2529f0ebb69decef646387"
    "dc767b74939265fec0223aa6d84d2a8a1cc912d5ca25b4e144ab8f6ba054b54910176d5737a2cff011da431bd5f2a0d2"
    "d66b9e70b39f4b050e45c0d9c16f02deda9ddf2d00f3e4b01037d7029cd49c2d46a8e1fc2c0c17520af1f4b5e25ba396"
    "afc4cd60c494a4c426448b35b49635b337cfb08e7c22a39b256dd032c00adddafb51a627f99a0e1704170ac1f1912e49"
    "d9db10ec04c19c58f420212973e0cb329524223a6aa56c7937c5dffdb5d966b6cd4cbc26f3201dd25c80960a1a111b32"
    "947bb78973d269fac7f5186530930ed19f68507540eed9e1bab8b00f00d8ca09b3f099aae46180e04e3584bd7ca054df"
    "18a1504b89d1d1675d0966c4ae1407be325cdf623cf13ff13e4a28b594d59e3eadbadf6136eee7a59d6a444c9eb4e219"
    "8e8a974f27a39eb63af2c9af3870488b8adaad444674f512133ad80b9220e09158521614f1faadfe8505ef57b7df6813"
    "048603f0dd04f4280177a11380fbfc861dbcbd7418d62155248dad5fdec0991f";
static const char vectorBlindedMessage[] =
    "10c166c6a711e81c46f45b18e5873cc4f494f003180dd7f115585d871a28930259654fe28a54dab319cc5011204c8373"
    "b50a57b0fdc7a678bd74c523259dfe4fd5ea9f52f170e19dfa332930ad1609fc8a00902d725cfe50685c95e5b2968c9a"
    "2828a21207fcf393d15f849769e2af34ac4259d91dfd98c3a707c509e1af55647efaa31290ddf48e0133b798562af5ea"
    "bd327270ac2fb6c594734ce339a14ea4fe1b9a2f81c0bc230ca523bda17ff42a377266bc2778a274c0ae5ec5a8cbbe36"
    "4fcf0d2403f7ee178d77ff28b67a20c7ceec009182dbcaa9bc99b51ebbf13b7d542be337172c6474f2cd3561219fe0df"
    "a3fb207cff89632091ab841cf38d8aa88af6891539f263adb8eac6402c41b6ebd72984e43666e537f5f5fe27b2b5aa11"
    "4957e9a580730308a5f5a9c63a1eb599f093ab401d0c6003a451931b6d124180305705845060ebba6b0036154fcef3e5"
    "e9f9e4b87e8f084542fd1dd67e7782a5585150181c01eb6d90cb95883837384a5b91dbb606f266059ecc51b5acbaa280"
    "e45cfd2eec8cc1cdb1b7211c8e14805ba683f9b78824b2eb005bc8a7d7179a36c152cb87c8219e5569bba911bb32a1b9"
    "23ca83de0e03fb10fba75d85c55907dda5a2606bf918b056c3808ba496a4d95532212040a5f44f37e1097f26dc27b98a"
    "51837daa78f23e532156296b64352669c94a8a855acf30533d8e0594ace7c442";
static const char vectorBlindSignature[] =
    "364f6a40dbfbc3bbb257943337eeff791a0f290898a6791283bba581d9eac90a6376a837241f5f73a78a5c6746e1306b"
    "a3adab6067c32ff69115734ce014d354e2f259d4cbfb890244fd451a497fe6ecf9aa90d19a2d441162f7eaa7ce3fc4e8"
    "9fd4e76b7ae585be2a2c0fd6fb246b8ac8d58bcb585634e30c9168a434786fe5e0b74bfe8187b47ac091aa571ffea0a8"
    "64cb906d0e28c77a00e8cd8f6aba4317a8cc7bf32ce566bd1ef80c64de041728abe087bee6cadd0b7062bde5ceef308a"
    "23bd1ccc154fd0c3a26110df6193464fc0d24ee189aea8979d722170ba945fdcce9b1b4b63349980f3a92dc2e5418c54"
    "d38a862916926b3f9ca270a8cf40dfb9772bfbdd9a3e0e0892369c18249211ba857f35963d0e05d8da98f1aa0c6bba58"
    "f47487b8f663e395091275f82941830b050b260e4767ce2fa903e75ff8970c98bfb3a08d6db91ab1746c86420ee2e909"
    "bf681cac173697135983c3594b2def673736220452fde4ddec867d40ff42dd3da36c84e3e52508b891a00f50b4f62d11"
    "2edb3b6b6cc3dbd546ba10f36b03f06c0d82aeec3b25e127af545fac28e1613a0517a6095ad18a98ab79f68801e05c17"
    "5e15bae21f821e80c80ab4fdec6fb34ca315e194502b8f3dcf7892b511aee45060e3994cd15e003861bc7220a2babd7b"
    "40eda03382548a34a7110f9b1779bf3ef6011361611e6bc5c0dc851e1509de1a";
static const char vectorSignature[] =
    "6fef8bf9bc182cd8cf7ce45c7dcf0e6f3e518ae48f06f3c670c649ac737a8b8119a34d51641785be151a697ed7825fdf"
    "ece82865123445eab03eb4bb91cecf4d6951738495f8481151b62de869658573df4e50a95c17c31b52e154ae26a04067"
    "d5ecdc1592c287550bb982a5bb9c30fd53a768cee6baabb3d483e9f1e2da954c7f4cf492fe3944d2fe456c1ecaf08403"
    "69e33fb4010e6b44bb1d721840513524d8e9a3519f40d1b81ae34fb7a31ee6b7ed641cb16c2ac999004c2191de020145"
    "7523f5a4700dd649267d9286f5c1d193f1454c9f868a57816bf5ff76c838a2eeb616a3fc9976f65d4371deecfbab2936"
    "2caebdff69c635fe5a2113da4d4d8c24f0b16a0584fa05e80e607c5d9a2f765f1f069f8d4da21f27c2a3b5c984b4ab24"
    "899bef46c6d9323df4862fe51ce300fca40fb539c3bb7fe2dcc9409e425f2d3b95e70e9c49c5feb6ecc9d43442c33d50"
    "003ee936845892fb8be475647da9a080f5bc7f8a716590b3745c2209fe05b17992830ce15f32c7b22cde755c8a2fe50b"
    "d814a0434130b807dc1b7218d4e85342d70695a5d7f29306f25623ad1e8aa08ef71b54b8ee447b5f64e73d09bdd6c3b7"
    "ca224058d7c67cc7551e9241688ada12d859cb7646fbd3ed8b34312f3b49d69802f0eaa11bc4211c2f7a29cd5c01ed01"
    "a39001c5856fab36228f5ee2f2e1110811872fe7c865c42ed59029c706195d52";

// The key, secret token and signature in webkit.org/blog/11940.
static const char blogPublicKey[] =
    "MIICUjA9BgkqhkiG9w0BAQowMKANMAsGCWCGSAFlAwQCAqEaMBgGCSqGSIb3DQEBCDALBglghkgBZQMEAgKiAwIBMAOCAg8A"
    "MIICCgKCAgEAoGhU5Mgsbb51ZbJVPHSgf8c93TJdtkxeKfyxQ5fCpwE2Fe9xJ7tByExdGKj4XO+HFi7npmtEPzR4cRXdsAL7"
    "YcH5UXNbVhXmVcbFCBXks+Ih+jqLwfNac0wPLG5K1Zzhf1gZ++JBzVjw87zvqpWrzzxviuV//0sn/u7f01E1OdaD83110fhf"
    "iXp/Ex62Q2uhcek0hqbqEvyKlLVBOjlJFJc2FLyw+l8+9xd7GcX1ZRyPx4lITvYG7KIbSMrFTfuQNOyJf4DlO97qq08R6Utl"
    "249AnBfLe3ZDbWBnl0fDOwkJgBmbaa7EnRlQ3p6Ir2SY1hNTnzW+p2ceytIMYwTMSES7+j21oeTUC+OmcC/5g05AgxROzUJP"
    "ZdyY33m4Q7lqkHkLAYtdN2TVCP79MuswS+fJJQOD/dDCqq/hk0MySLCbnUGe5lyFBoO5vBMH5k38LjSQuN6jfP7quYA6cOON"
    "zmn842eLT61tIjRoX2czeUJrSmx89SfY8WnFE2fhk9G52cXp6L2Vzr5IV7rOws3ZPw+RnjKnZZaejs0bKGOXC1+jl+u4A5ip"
    "55ohlUjm7lvDtKFAeJ7gajJBtiNnq3s3m/IMkv7ztCQpv0pBxst6MmvNOO0jOQvYkzQbGooI1/qjeDup0BYY67xxyNRaA9V4"
    "CKEJ7j/hznrAmjSiz0LSqTkCAwEAAQ==";
static const char blogToken[] =
    "7JgS5aIQPUm9T5DcT2a91NC1lt2xq5bLjuaJi4A/Wbg=";
static const char blogSignature[] =
    "ThyNW13Z7DTVSj/U8+5oWyG73bskeB2ZtmyG+tZRbuX216mK2F7wgv8piQEFxjDC49O9fPP7DFovcJbGOx3JR7zS7fDq3pYO"
    "Kz/LkF8I2DkLz9jDcgXxgddMRfFsG8ud6FyEtmESiFgF23Nfqnn4JrhC4luDb7JceOdFsNWtXTURYeVcnARhKlcQ8h8Gs0zT"
    "CTGz2LkhwOHUlRYUTnqy5Ng9DiK4Rb9XSaTTPFPK2VJ7PNDmVFtvj1uc2OSxO8AJu9FYF4pv0wQjXjBKy00BF6Qm3m7vZXIw"
    "u7pTHBbXlb7DpJ2/15OblNEZrbS0BbXUzv8gqhz6MqmstltZdDiQZHRNDXabmPX7Rm1NRiy5XBr2oF+YBcSHJ0xV3YEH3Xoe"
    "GN2McBoZCQ7CLhhMcDQLGVBv0L05Wp5rwausxd6Yerf01ebedk5D7RlQmrQ0lMo6fnqm6/F9gEHil2axA8zB/xThPD4ZQ0AR"
    "HkGWQYraQzGq5Xj65CIa1yV174iDcf6ZP18Hvkj1VcQIderLg0oMI6FOFzSYYeWJR0vKSc6C+y6jAX4dPPS+1uKRMBBijdv/"
    "4H9GazAQHhXLGKxaRgbLg+mLXKG4I9YoPVgU/gc/ePeTAyXFs+EgTi5ExpTF2Klv10E8HTtYLAO76FQVjnDNB98dq+XIbFHM"
    "uVKzAaBFr7s=";

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-92s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok)
        failures++;
}

static NSData *hexData(const char *hex)
{
    NSMutableData *data = [NSMutableData dataWithLength:strlen(hex) / 2];
    uint8_t *bytes = data.mutableBytes;
    for (size_t i = 0; i < data.length; i++)
        sscanf(hex + 2 * i, "%2hhx", &bytes[i]);
    return data;
}

static NSData *base64Data(const char *text)
{
    NSMutableString *string = [NSMutableString stringWithUTF8String:text];
    [string replaceOccurrencesOfString:@"-" withString:@"+" options:0 range:NSMakeRange(0, string.length)];
    [string replaceOccurrencesOfString:@"_" withString:@"/" options:0 range:NSMakeRange(0, string.length)];
    while (string.length % 4)
        [string appendString:@"="];
    return [[[NSData alloc] initWithBase64EncodedString:string options:0] autorelease];
}

static BIGNUM *bignum(NSData *data) { return BN_bin2bn(data.bytes, data.length, NULL); }

static NSData *sha256(NSData *data)
{
    uint8_t digest[SHA256_DIGEST_LENGTH];
    SHA256(data.bytes, data.length, digest);
    return [NSData dataWithBytes:digest length:sizeof digest];
}

// The SubjectPublicKeyInfo TestWebKitAPI's wrapPublicKeyWithRSAPSSOID builds: id-RSASSA-PSS with SHA-384,
// MGF1-SHA-384 and a 48-byte salt, or rsaEncryption with NULL parameters.
static NSData *subjectPublicKeyInfo(NSData *rsaPublicKey, BOOL pss)
{
    static const uint8_t rsassaPSS[] = { 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0A };
    static const uint8_t rsaEncryption[] = { 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01 };
    static const uint8_t sha384[] = { 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x02 };
    static const uint8_t mgf1[] = { 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x08 };
    CBB cbb, spki, algorithm, oid, params, tagged, sequence, inner, bits;
    CBB_init(&cbb, 0);
    CBB_add_asn1(&cbb, &spki, CBS_ASN1_SEQUENCE);
    CBB_add_asn1(&spki, &algorithm, CBS_ASN1_SEQUENCE);
    CBB_add_asn1(&algorithm, &oid, CBS_ASN1_OBJECT);
    if (pss) {
        CBB_add_bytes(&oid, rsassaPSS, sizeof rsassaPSS);
        CBB_add_asn1(&algorithm, &params, CBS_ASN1_SEQUENCE);
        CBB_add_asn1(&params, &tagged, CBS_ASN1_CONSTRUCTED | CBS_ASN1_CONTEXT_SPECIFIC | 0);
        CBB_add_asn1(&tagged, &sequence, CBS_ASN1_SEQUENCE);
        CBB_add_asn1(&sequence, &oid, CBS_ASN1_OBJECT);
        CBB_add_bytes(&oid, sha384, sizeof sha384);
        CBB_add_asn1(&params, &tagged, CBS_ASN1_CONSTRUCTED | CBS_ASN1_CONTEXT_SPECIFIC | 1);
        CBB_add_asn1(&tagged, &sequence, CBS_ASN1_SEQUENCE);
        CBB_add_asn1(&sequence, &oid, CBS_ASN1_OBJECT);
        CBB_add_bytes(&oid, mgf1, sizeof mgf1);
        CBB_add_asn1(&sequence, &inner, CBS_ASN1_SEQUENCE);
        CBB_add_asn1(&inner, &oid, CBS_ASN1_OBJECT);
        CBB_add_bytes(&oid, sha384, sizeof sha384);
        CBB_add_asn1(&params, &tagged, CBS_ASN1_CONSTRUCTED | CBS_ASN1_CONTEXT_SPECIFIC | 2);
        CBB_add_asn1_uint64(&tagged, 48);
    } else {
        CBB_add_bytes(&oid, rsaEncryption, sizeof rsaEncryption);
        CBB_add_asn1(&algorithm, &params, CBS_ASN1_NULL);
    }
    CBB_add_asn1(&spki, &bits, CBS_ASN1_BITSTRING);
    CBB_add_u8(&bits, 0);
    CBB_add_bytes(&bits, rsaPublicKey.bytes, rsaPublicKey.length);
    uint8_t *der = NULL;
    size_t derLength = 0;
    CBB_finish(&cbb, &der, &derLength);
    NSData *result = [NSData dataWithBytes:der length:derLength];
    OPENSSL_free(der);
    return result;
}

static NSData *rsaPublicKeyDER(RSA *key)
{
    uint8_t *der = NULL;
    size_t derLength = 0;
    RSA_public_key_to_bytes(&der, &derLength, key);
    NSData *result = [NSData dataWithBytes:der length:derLength];
    OPENSSL_free(der);
    return result;
}

static RSA *parseRSAPublicKey(NSData *der)
{
    CBS cbs;
    CBS_init(&cbs, der.bytes, der.length);
    return RSA_parse_public_key(&cbs);
}

static BOOL verifies(RSA *key, NSData *content, NSData *signature)
{
    uint8_t digest[SHA384_DIGEST_LENGTH];
    SHA384(content.bytes, content.length, digest);
    return RSA_verify_pss_mgf1(key, digest, sizeof digest, EVP_sha384(), EVP_sha384(), 48, signature.bytes, signature.length) == 1;
}

static int signBlinded(void *key, NSData *blinded, NSMutableData *signature)
{
    return ccrsabssa_sign_blinded_message(&ccrsabssa_ciphersuite_rsa4096_sha384, key, blinded.bytes, blinded.length,
        signature.mutableBytes, signature.length, ccrng(NULL));
}

int main(void)
{
    @autoreleasepool {
        static const char frameworkPath[] = "/System/Library/PrivateFrameworks/CryptoKitPrivate.framework/CryptoKitPrivate";
        check(access("/System/Library/PrivateFrameworks/CryptoKitPrivate.framework", F_OK) != 0,
            "this system ships no CryptoKitPrivate.framework, so the premise holds");
        check(dlopen(frameworkPath, RTLD_NOW) != NULL, "dlopen of the absent framework answers with a handle");

        Class blinderClass = objc_getClass("RSABSSATokenBlinder");
        check(blinderClass != Nil, "objc_getClass finds RSABSSATokenBlinder, as PAL's soft link asks for it");
        check(objc_getClass("RSABSSATokenWaitingActivation") && objc_getClass("RSABSSATokenReady"),
            "and the two token classes");
        check(blinderClass && !strcmp(class_getName(blinderClass), "WKMavPolyfillPriv_RSABSSATokenBlinder"),
            "the class is registered under the private name");
        if (!blinderClass) {
            printf("CryptoKitPrivate-rsabssa: %d failure(s)\n", failures);
            return 1;
        }

        // --- The server side TestWebKitAPI plays: a 10.9 corecrypto key and the ccrsabssa signer. ---
        int error = -1;
        struct ccrng_state *rng = ccrng(&error);
        check(rng && error == 0, "ccrng answers a generator and reports success");
        uint8_t random[32] = { 0 };
        uint8_t zero[32] = { 0 };
        check(rng && !rng->generate(rng, sizeof random, random) && memcmp(random, zero, sizeof random),
            "and the generator produces bytes");

        void *serverKey = calloc(1, FULL_CTX_SIZE(512));
        const uint8_t e[] = { 0x01, 0x00, 0x01 };
        check(ccrsa_generate_key(4096, serverKey, sizeof e, e, rng) == 0, "10.9's ccrsa_generate_key makes a 4096-bit key with it");
        check(ccrsa_pubkeylength(serverKey) == 4096, "ccrsa_pubkeylength reports 4096 bits");
        size_t exportSize = ccder_encode_rsa_pub_size(serverKey);
        NSMutableData *rsaPublicKey = [NSMutableData dataWithLength:exportSize];
        ccder_encode_rsa_pub(serverKey, rsaPublicKey.mutableBytes, (uint8_t *)rsaPublicKey.mutableBytes + exportSize);
        RSA *serverPublicKey = parseRSAPublicKey(rsaPublicKey);
        check(serverPublicKey && RSA_bits(serverPublicKey) == 4096, "10.9 encodes the public key as an RSAPublicKey");
        NSData *spki = subjectPublicKeyInfo(rsaPublicKey, YES);

        // --- The client: blind, have the server sign, finalize. ---
        NSError *nsError = nil;
        id blinder = [[[blinderClass alloc] initWithPublicKey:spki error:&nsError] autorelease];
        check(blinder && !nsError, "the blinder takes the id-RSASSA-PSS SubjectPublicKeyInfo");
        check([[blinder keyId] isEqualToData:sha256(spki)],
            "its keyId is the SHA-256 of the key bytes, as PrivateClickMeasurementManager recomputes it");

        id waiting = [blinder tokenWaitingActivationWithContent:nil error:&nsError];
        check(waiting && !nsError && [waiting blindedMessage].length == 512, "a token without content blinds to 512 bytes");
        id second = [blinder tokenWaitingActivationWithContent:nil error:&nsError];
        check(![[second blindedMessage] isEqualToData:[waiting blindedMessage]], "and two such tokens blind differently");

        NSMutableData *blindSignature = [NSMutableData dataWithLength:512];
        check(signBlinded(serverKey, [waiting blindedMessage], blindSignature) == 0, "ccrsabssa_sign_blinded_message signs it");
        id ready = [waiting activateTokenWithServerResponse:blindSignature error:&nsError];
        check(ready && !nsError, "the blind signature activates the token");
        check([ready tokenContent].length == 32, "the token content is 32 random bytes");
        check([[ready keyId] isEqualToData:[blinder keyId]], "the ready token carries the blinder's keyId");
        check([ready signature].length == 512 && verifies(serverPublicKey, [ready tokenContent], [ready signature]),
            "its signature verifies as RSASSA-PSS SHA-384, salt 48, over the token content");

        NSData *content = [@"click fraud prevention" dataUsingEncoding:NSUTF8StringEncoding];
        id withContent = [blinder tokenWaitingActivationWithContent:content error:&nsError];
        signBlinded(serverKey, [withContent blindedMessage], blindSignature);
        id readyWithContent = [withContent activateTokenWithServerResponse:blindSignature error:&nsError];
        check([[readyWithContent tokenContent] isEqualToData:content] && verifies(serverPublicKey, content, [readyWithContent signature]),
            "given content is the token content, and is what is signed");

        // --- Refusals. ---
        nsError = nil;
        check(![waiting activateTokenWithServerResponse:[blindSignature subdataWithRange:NSMakeRange(0, 511)] error:&nsError] && nsError,
            "a blind signature of the wrong size is refused with an error");
        signBlinded(serverKey, [waiting blindedMessage], blindSignature);
        ((uint8_t *)blindSignature.mutableBytes)[100] ^= 1;
        nsError = nil;
        check(![waiting activateTokenWithServerResponse:blindSignature error:&nsError] && nsError,
            "a blind signature that does not unblind to a valid signature is refused");
        nsError = nil;
        check(![[blinderClass alloc] initWithPublicKey:rsaPublicKey error:&nsError] && nsError,
            "a bare RSAPublicKey is not a SubjectPublicKeyInfo");
        RSA *small = RSA_new();
        BIGNUM *f4 = BN_new();
        BN_set_word(f4, 65537);
        RSA_generate_key_ex(small, 1024, f4, NULL);
        nsError = nil;
        check(![[blinderClass alloc] initWithPublicKey:subjectPublicKeyInfo(rsaPublicKeyDER(small), YES) error:&nsError] && nsError,
            "a 1024-bit key is refused");
        RSA *medium = RSA_new();
        RSA_generate_key_ex(medium, 2048, f4, NULL);
        nsError = nil;
        id rsaEncryptionBlinder = [[[blinderClass alloc] initWithPublicKey:subjectPublicKeyInfo(rsaPublicKeyDER(medium), NO) error:&nsError] autorelease];
        check(rsaEncryptionBlinder && !nsError && [[rsaEncryptionBlinder tokenWaitingActivationWithContent:nil error:&nsError] blindedMessage].length == 256,
            "a 2048-bit rsaEncryption SubjectPublicKeyInfo is taken, and blinds to its modulus size");

        NSMutableData *oversized = [NSMutableData dataWithLength:512];
        memset(oversized.mutableBytes, 0xFF, oversized.length);
        check(signBlinded(serverKey, oversized, blindSignature) == -7, "the signer refuses a blinded message not below the modulus");
        BIGNUM *nMinusOne = BN_dup(RSA_get0_n(serverPublicKey));
        BN_sub_word(nMinusOne, 1);
        NSMutableData *limit = [NSMutableData dataWithLength:512];
        BN_bn2bin_padded(limit.mutableBytes, 512, nMinusOne);
        check(signBlinded(serverKey, limit, blindSignature) == -23, "and n - 1, as corecrypto's private operation does");
        check(ccrsabssa_sign_blinded_message(&ccrsabssa_ciphersuite_rsa4096_sha384, serverKey, [waiting blindedMessage].bytes, 511,
            blindSignature.mutableBytes, 512, rng) == -7, "and a blinded message of the wrong length");

        // BlindSign is the RSA private operation: its output raised to e is the blinded message again.
        check(signBlinded(serverKey, [waiting blindedMessage], blindSignature) == 0, "the signer signs the token once more");
        BN_CTX *bnContext = BN_CTX_new();
        BIGNUM *raised = BN_new();
        BN_mod_exp(raised, bignum(blindSignature), RSA_get0_e(serverPublicKey), RSA_get0_n(serverPublicKey), bnContext);
        check(!BN_cmp(raised, bignum([waiting blindedMessage])), "and the blind signature is the e-th root of the blinded message");

        // --- RFC 9474 A.3, RSABSSA-SHA384-PSS-Deterministic. ---
        BIGNUM *p = bignum(hexData(vectorP)), *q = bignum(hexData(vectorQ)), *n = bignum(hexData(vectorN));
        BIGNUM *vectorExponent = bignum(hexData(vectorE)), *d = bignum(hexData(vectorD));
        BIGNUM *pMinusOne = BN_dup(p), *qMinusOne = BN_dup(q), *dmp1 = BN_new(), *dmq1 = BN_new(), *iqmp = BN_new();
        BN_sub_word(pMinusOne, 1);
        BN_sub_word(qMinusOne, 1);
        BN_mod(dmp1, d, pMinusOne, bnContext);
        BN_mod(dmq1, d, qMinusOne, bnContext);
        BN_mod_inverse(iqmp, q, p, bnContext);
        RSA *vectorKey = RSA_new_private_key(n, vectorExponent, d, p, q, dmp1, dmq1, iqmp);
        check(vectorKey != NULL, "the vector's key is consistent");

        NSData *vectorPublicKey = rsaPublicKeyDER(vectorKey);
        id vectorBlinder = [[[blinderClass alloc] initWithPublicKey:subjectPublicKeyInfo(vectorPublicKey, YES) error:&nsError] autorelease];
        id vectorWaiting = [[[objc_getClass("RSABSSATokenWaitingActivation") alloc] initWithBlinder:vectorBlinder
            content:hexData(vectorMessage) blindedMessage:hexData(vectorBlindedMessage)
            blindingInverse:bignum(hexData(vectorInverse))] autorelease];
        id vectorReady = [vectorWaiting activateTokenWithServerResponse:hexData(vectorBlindSignature) error:&nsError];
        check(vectorReady && [[vectorReady signature] isEqualToData:hexData(vectorSignature)],
            "Finalize of the vector's blind_sig with its inv is its sig");
        check(verifies(vectorKey, hexData(vectorMessage), hexData(vectorSignature)),
            "and the vector's sig is a plain RSASSA-PSS signature of msg, the deterministic variant");

        // --- A token a shipping browser produced (webkit.org/blog/11940). ---
        NSData *blogKey = base64Data(blogPublicKey);
        id blogBlinder = [[[blinderClass alloc] initWithPublicKey:blogKey error:&nsError] autorelease];
        check(blogBlinder != nil, "the published PCM token key is accepted");
        CBS blogSPKI, blogOuter, blogAlgorithm, blogBits;
        uint8_t unused;
        CBS_init(&blogSPKI, blogKey.bytes, blogKey.length);
        CBS_get_asn1(&blogSPKI, &blogOuter, CBS_ASN1_SEQUENCE);
        CBS_get_asn1(&blogOuter, &blogAlgorithm, CBS_ASN1_SEQUENCE);
        CBS_get_asn1(&blogOuter, &blogBits, CBS_ASN1_BITSTRING);
        CBS_get_u8(&blogBits, &unused);
        RSA *blogRSA = RSA_parse_public_key(&blogBits);
        NSData *blogTokenContent = base64Data(blogToken);
        check(blogTokenContent.length == 32, "its secret token is 32 bytes");
        check(blogRSA && verifies(blogRSA, blogTokenContent, base64Data(blogSignature)),
            "and its signature verifies as RSASSA-PSS SHA-384, salt 48, over the token itself");

        printf("CryptoKitPrivate-rsabssa: %d failure(s)\n", failures);
        return failures ? 1 : 0;
    }
}
