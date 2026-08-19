// Security: entry points and constants modern WebKit references that 10.9's Security does not export.
#include "wk_polyfill.h"

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <malloc/malloc.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>

// Key-type and keychain attribute values. kSecAttrKeyTypeECSECPrimeRandom is the CFNumber-shaped
// string "73" — Security's algorithm id for ECDSA/EC keys (CSSM_ALGID_ECDSA), which is the value
// keychain queries are matched against.
WK_POLYFILL_CONST("Security", CFStringRef, kSecAttrKeyTypeECSECPrimeRandom, CFSTR("73"));
WK_POLYFILL_CONST("Security", CFStringRef, kSecUseDataProtectionKeychain, CFSTR("u-DataProtectionKeychain"));

// The Secure Enclave / access-control keychain attributes (10.10-10.12+), read by the WebAuthn
// platform authenticator: LocalAuthenticator.mm builds an access control from
// kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, and LocalConnection::createCredentialPrivateKey
// builds the SecKeyCreateRandomKey attribute dictionary from the other five. Token values, per this
// file's convention: 10.9's Security predates tokens, access-control objects and the SecKey algorithm
// API entirely and interprets none of these, and the functions that would consume them are the
// NULL-returning gap-fills below -- so nothing on 10.9 ever compares these strings against
// anything. They are declared for the LOAD, not the value: each is read as a plain argument
// expression, and a weak-imported absent data symbol binds to address 0, so evaluating the argument
// faults before the call it belongs to can fail cleanly.
//
// Do NOT infer from "the platform authenticator cannot work on 10.9" that these are unreachable.
// AuthenticatorManager::filterTransports() does drop AuthenticatorTransport::Internal when
// LocalService::isAvailable() is false (and on 10.9 it always is -- no AuthenticationServices, no
// LocalAuthentication.framework), but VirtualAuthenticatorManager OVERRIDES filterTransports to do
// nothing and hands the REAL LocalAuthenticator a VirtualLocalConnection, which does not override
// createCredentialPrivateKey. A WebDriver addVirtualAuthenticator command therefore runs every line
// above, so "the platform authenticator cannot work on 10.9" does not make these unreachable.
WK_POLYFILL_CONST("Security", CFStringRef, kSecAttrAccessControl, CFSTR("kSecAttrAccessControl"));
WK_POLYFILL_CONST("Security", CFStringRef, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, CFSTR("kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly"));
WK_POLYFILL_CONST("Security", CFStringRef, kSecAttrTokenID, CFSTR("kSecAttrTokenID"));
WK_POLYFILL_CONST("Security", CFStringRef, kSecAttrTokenIDSecureEnclave, CFSTR("kSecAttrTokenIDSecureEnclave"));
WK_POLYFILL_CONST("Security", CFStringRef, kSecUseAuthenticationContext, CFSTR("kSecUseAuthenticationContext"));
// A token, deliberately, where the sibling SecKeyAlgorithm block below spells real "algid:..."
// strings: those are checkable, and this one is not. 10.9 exports no SecKeyAlgorithm constant to
// read the value off, and the only 10.9 consumer is the NULL-returning SecKeyCreateSignature
// gap-fill below, which ignores its algorithm argument. Guessing an "algid:" spelling
// would look authoritative while being unverified; the token is honestly what it is.
WK_POLYFILL_CONST("Security", CFStringRef, kSecKeyAlgorithmECDSASignatureMessageX962SHA256, CFSTR("kSecKeyAlgorithmECDSASignatureMessageX962SHA256"));

// SecKeyAlgorithm identifiers (10.12+). Each is Security's documented "algid:..." string, the value
// SecKey* functions parse to select padding and digest. They are used as opaque selectors here
// (10.9's Security has no SecKey algorithm API — see the SecKey entry points below), so
// the strings only need to be the real ones for any caller that compares them.
WK_POLYFILL_CONST("Security", CFStringRef, kSecKeyAlgorithmECDHKeyExchangeStandard, CFSTR("algid:ecdh:standard"));
WK_POLYFILL_CONST("Security", CFStringRef, kSecKeyAlgorithmECDSASignatureDigestX962, CFSTR("algid:ecdsa:digest-x962"));
WK_POLYFILL_CONST("Security", CFStringRef, kSecKeyAlgorithmRSAEncryptionOAEPSHA1, CFSTR("algid:encrypt:RSA:OAEP-SHA1"));
WK_POLYFILL_CONST("Security", CFStringRef, kSecKeyAlgorithmRSAEncryptionOAEPSHA256, CFSTR("algid:encrypt:RSA:OAEP-SHA256"));
WK_POLYFILL_CONST("Security", CFStringRef, kSecKeyAlgorithmRSAEncryptionOAEPSHA384, CFSTR("algid:encrypt:RSA:OAEP-SHA384"));
WK_POLYFILL_CONST("Security", CFStringRef, kSecKeyAlgorithmRSAEncryptionOAEPSHA512, CFSTR("algid:encrypt:RSA:OAEP-SHA512"));
WK_POLYFILL_CONST("Security", CFStringRef, kSecKeyAlgorithmRSAEncryptionPKCS1, CFSTR("algid:encrypt:RSA:PKCS1"));
WK_POLYFILL_CONST("Security", CFStringRef, kSecKeyAlgorithmRSAEncryptionRaw, CFSTR("algid:encrypt:RSA:raw"));
WK_POLYFILL_CONST("Security", CFStringRef, kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA1, CFSTR("algid:sign:RSA:digest-PKCS1v15:SHA1"));
WK_POLYFILL_CONST("Security", CFStringRef, kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA256, CFSTR("algid:sign:RSA:digest-PKCS1v15:SHA256"));
WK_POLYFILL_CONST("Security", CFStringRef, kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA384, CFSTR("algid:sign:RSA:digest-PKCS1v15:SHA384"));
WK_POLYFILL_CONST("Security", CFStringRef, kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA512, CFSTR("algid:sign:RSA:digest-PKCS1v15:SHA512"));
WK_POLYFILL_CONST("Security", CFStringRef, kSecKeyAlgorithmRSASignatureDigestPSSSHA1, CFSTR("algid:sign:RSA:digest-PSS:SHA1"));
WK_POLYFILL_CONST("Security", CFStringRef, kSecKeyAlgorithmRSASignatureDigestPSSSHA256, CFSTR("algid:sign:RSA:digest-PSS:SHA256"));
WK_POLYFILL_CONST("Security", CFStringRef, kSecKeyAlgorithmRSASignatureDigestPSSSHA384, CFSTR("algid:sign:RSA:digest-PSS:SHA384"));
WK_POLYFILL_CONST("Security", CFStringRef, kSecKeyAlgorithmRSASignatureDigestPSSSHA512, CFSTR("algid:sign:RSA:digest-PSS:SHA512"));
WK_POLYFILL_CONST("Security", CFStringRef, kSecKeyAlgorithmRSASignatureRaw, CFSTR("algid:sign:RSA:raw"));

// ---------------------------------------------------------------------------------------------------
// Security
// ---------------------------------------------------------------------------------------------------

// Failure reporting for the Security entry points below that 10.9 has no implementation for. They
// report failure the way
// the real API does: a CFError is ALWAYS produced when the call fails, because every caller of a
// CFError-returning Security function is entitled to read it. Handing back NULL there is what makes
// a caller construct an NSError from nothing and crash (see LSCopyDefaultApplicationURLForURL below
// for the same failure observed in the wild).
static void mav_reportUnimplemented(CFErrorRef *error)
{
    if (!error)
        return;
    CFStringRef keys[] = { kCFErrorLocalizedDescriptionKey };
    CFStringRef values[] = { CFSTR("This Security API is not available on macOS 10.9") };
    CFDictionaryRef userInfo = CFDictionaryCreate(kCFAllocatorDefault, (const void **)keys,
        (const void **)values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    *error = CFErrorCreate(kCFAllocatorDefault, kCFErrorDomainOSStatus, errSecUnimplemented, userInfo);
    if (userInfo)
        CFRelease(userInfo);
}


// Keychain access-control objects (passkeys / SE-backed keys). Absent on 10.9; callers tolerate null.
// The type id is used in CFGetTypeID comparisons; 0 never matches, so such objects are never seen.
WK_POLYFILL_ABSENT("Security", CFTypeID, SecAccessControlGetTypeID, (void))
{
    return 0;
}

WK_POLYFILL_ABSENT("Security", CFDataRef, SecAccessControlCopyData, (void *accessControl))
{
    (void)accessControl;
    return NULL;
}

WK_POLYFILL_ABSENT("Security", void *, SecAccessControlCreateFromData, (CFAllocatorRef allocator, CFDataRef data, CFErrorRef *error))
{
    (void)allocator; (void)data;
    mav_reportUnimplemented(error);
    return NULL;
}

// The constructor of the same family, and the one WebAuthn actually calls. NULL-plus-CFError is not a
// placeholder here, it is the answer: 10.9 has no access-control object to build, and
// LocalAuthenticator::continueMakeCredentialAfterReceivingLAContext already reads exactly this shape
// -- it adopts the error, raises UnknownError("Couldn't create access control: ...") and returns, so
// the platform authenticator declines instead of proceeding toward a Secure Enclave that is not there.
//
// Unlike its siblings above this one is REACHED. AuthenticatorManager::filterTransports() drops
// AuthenticatorTransport::Internal when LocalService::isAvailable() is false, which on 10.9 it always
// is -- but VirtualAuthenticatorManager overrides filterTransports to do nothing and hands the real
// LocalAuthenticator a VirtualLocalConnection, so a WebDriver addVirtualAuthenticator command runs
// this line, and without this entry the call would branch to address 0.
WK_POLYFILL_ABSENT("Security", SecAccessControlRef, SecAccessControlCreateWithFlags, (CFAllocatorRef allocator, CFTypeRef protection, SecAccessControlCreateFlags flags, CFErrorRef *error))
{
    (void)allocator; (void)protection; (void)flags;
    mav_reportUnimplemented(error);
    return NULL;
}

// Certificate signature hash algorithm. CertificateInfo::containsNonRootSHA1SignedCertificate()
// (WebCore/platform/network/cf/CertificateInfoCFNet.cpp) compares it against
// kSecSignatureHashAlgorithmSHA1 to flag a chain as weakly signed, so a hardcoded "unknown" is not a
// missing feature but a security answer this layer would be inventing: every SHA-1-signed chain would
// come back clean.
//
// 10.9 lacks the accessor, not the information: the signatureAlgorithm AlgorithmIdentifier is in the
// certificate's DER, and 10.9's Security parses it out for SecCertificateCopyValues under
// kSecOIDX509V1SignatureAlgorithm — a section property whose "Algorithm" entry is the dotted OID
// string. Map that OID to the hash the way Security's own
// SecSignatureHashAlgorithmForAlgorithmOid does: by the signature algorithm's digest, across the RSA,
// RSA/OIW, DSA and ECDSA spellings. Unrecognised OIDs report Unknown, which is what the real accessor
// does too.
//
// Everything is reached by name (Security is not linked into every image that force-loads this
// archive) — see the WK_SYSTEM_FN note in wk_polyfill.h.
WK_SYSTEM_FN("Security", CFDictionaryRef, SecCertificateCopyValues, (SecCertificateRef, CFArrayRef, CFErrorRef *));

enum {
    MavSecSignatureHashAlgorithmUnknown = 0,
    MavSecSignatureHashAlgorithmMD2 = 1,
    MavSecSignatureHashAlgorithmMD4 = 2,
    MavSecSignatureHashAlgorithmMD5 = 3,
    MavSecSignatureHashAlgorithmSHA1 = 4,
    MavSecSignatureHashAlgorithmSHA224 = 5,
    MavSecSignatureHashAlgorithmSHA256 = 6,
    MavSecSignatureHashAlgorithmSHA384 = 7,
    MavSecSignatureHashAlgorithmSHA512 = 8,
};

static CFStringRef mav_securityConstant(const char *name, void **cache)
{
    CFStringRef *storage = (CFStringRef *)wk_polyfill_system_symbol("Security", name, cache);
    return storage ? *storage : NULL;
}

// The digest each X.509 signature-algorithm OID signs with. Dotted form, as SecCertificateCopyValues
// reports it.
static int mav_signatureHashAlgorithmForOID(CFStringRef oid)
{
    static const struct { const char *oid; int algorithm; } table[] = {
        // PKCS#1 (RSA)
        { "1.2.840.113549.1.1.2",   MavSecSignatureHashAlgorithmMD2 },      // md2WithRSAEncryption
        { "1.2.840.113549.1.1.3",   MavSecSignatureHashAlgorithmMD4 },      // md4WithRSAEncryption
        { "1.2.840.113549.1.1.4",   MavSecSignatureHashAlgorithmMD5 },      // md5WithRSAEncryption
        { "1.2.840.113549.1.1.5",   MavSecSignatureHashAlgorithmSHA1 },     // sha1WithRSAEncryption
        { "1.2.840.113549.1.1.14",  MavSecSignatureHashAlgorithmSHA224 },   // sha224WithRSAEncryption
        { "1.2.840.113549.1.1.11",  MavSecSignatureHashAlgorithmSHA256 },   // sha256WithRSAEncryption
        { "1.2.840.113549.1.1.12",  MavSecSignatureHashAlgorithmSHA384 },   // sha384WithRSAEncryption
        { "1.2.840.113549.1.1.13",  MavSecSignatureHashAlgorithmSHA512 },   // sha512WithRSAEncryption
        // OIW / X9.57 legacy spellings
        { "1.3.14.3.2.29",          MavSecSignatureHashAlgorithmSHA1 },     // sha1WithRSASignature
        { "1.3.14.3.2.27",          MavSecSignatureHashAlgorithmSHA1 },     // dsaWithSHA1 (OIW)
        { "1.3.14.3.2.13",          MavSecSignatureHashAlgorithmSHA1 },     // dsaWithSHA1 (common OIW)
        { "1.2.840.10040.4.3",      MavSecSignatureHashAlgorithmSHA1 },     // dsa-with-sha1
        { "2.16.840.1.101.3.4.3.1", MavSecSignatureHashAlgorithmSHA224 },   // dsa-with-sha224
        { "2.16.840.1.101.3.4.3.2", MavSecSignatureHashAlgorithmSHA256 },   // dsa-with-sha256
        // ECDSA
        { "1.2.840.10045.4.1",      MavSecSignatureHashAlgorithmSHA1 },     // ecdsa-with-SHA1
        { "1.2.840.10045.4.3.1",    MavSecSignatureHashAlgorithmSHA224 },   // ecdsa-with-SHA224
        { "1.2.840.10045.4.3.2",    MavSecSignatureHashAlgorithmSHA256 },   // ecdsa-with-SHA256
        { "1.2.840.10045.4.3.3",    MavSecSignatureHashAlgorithmSHA384 },   // ecdsa-with-SHA384
        { "1.2.840.10045.4.3.4",    MavSecSignatureHashAlgorithmSHA512 },   // ecdsa-with-SHA512
    };

    if (!oid)
        return MavSecSignatureHashAlgorithmUnknown;
    for (size_t i = 0; i < sizeof(table) / sizeof(table[0]); i++) {
        CFStringRef candidate = CFStringCreateWithCStringNoCopy(kCFAllocatorDefault, table[i].oid,
            kCFStringEncodingASCII, kCFAllocatorNull);
        if (!candidate)
            continue;
        Boolean match = CFEqual(oid, candidate);
        CFRelease(candidate);
        if (match)
            return table[i].algorithm;
    }
    return MavSecSignatureHashAlgorithmUnknown;
}

// The dotted OID out of the kSecOIDX509V1SignatureAlgorithm property: a section whose value is an
// array of leaf properties, the one labelled "Algorithm" carrying the OID string.
static CFStringRef mav_copySignatureAlgorithmOID(CFDictionaryRef values, CFStringRef signatureAlgorithmKey)
{
    static void *labelKeyCache, *valueKeyCache;
    CFStringRef labelKey = mav_securityConstant("kSecPropertyKeyLabel", &labelKeyCache);
    CFStringRef valueKey = mav_securityConstant("kSecPropertyKeyValue", &valueKeyCache);
    if (!values || !signatureAlgorithmKey || !labelKey || !valueKey)
        return NULL;

    CFDictionaryRef property = (CFDictionaryRef)CFDictionaryGetValue(values, signatureAlgorithmKey);
    if (!property || CFGetTypeID(property) != CFDictionaryGetTypeID())
        return NULL;
    CFArrayRef section = (CFArrayRef)CFDictionaryGetValue(property, valueKey);
    if (!section || CFGetTypeID(section) != CFArrayGetTypeID())
        return NULL;

    for (CFIndex i = 0, count = CFArrayGetCount(section); i < count; i++) {
        CFDictionaryRef entry = (CFDictionaryRef)CFArrayGetValueAtIndex(section, i);
        if (!entry || CFGetTypeID(entry) != CFDictionaryGetTypeID())
            continue;
        CFStringRef label = (CFStringRef)CFDictionaryGetValue(entry, labelKey);
        if (!label || CFGetTypeID(label) != CFStringGetTypeID() || !CFEqual(label, CFSTR("Algorithm")))
            continue;
        CFStringRef oid = (CFStringRef)CFDictionaryGetValue(entry, valueKey);
        if (oid && CFGetTypeID(oid) == CFStringGetTypeID())
            return oid;   // borrowed from the property dictionary the caller holds
    }
    return NULL;
}

WK_POLYFILL_ABSENT("Security", int, SecCertificateGetSignatureHashAlgorithm, (SecCertificateRef certificate))
{
    static void *signatureAlgorithmKeyCache;
    CFStringRef signatureAlgorithmKey = mav_securityConstant("kSecOIDX509V1SignatureAlgorithm", &signatureAlgorithmKeyCache);
    if (!certificate || !signatureAlgorithmKey || !WK_SYSTEM(SecCertificateCopyValues))
        return MavSecSignatureHashAlgorithmUnknown;

    CFStringRef keys[] = { signatureAlgorithmKey };
    CFArrayRef requested = CFArrayCreate(kCFAllocatorDefault, (const void **)keys, 1, &kCFTypeArrayCallBacks);
    if (!requested)
        return MavSecSignatureHashAlgorithmUnknown;

    CFDictionaryRef values = WK_SYSTEM(SecCertificateCopyValues)(certificate, requested, NULL);
    CFRelease(requested);
    if (!values)
        return MavSecSignatureHashAlgorithmUnknown;

    int algorithm = mav_signatureHashAlgorithmForOID(mav_copySignatureAlgorithmOID(values, signatureAlgorithmKey));
    CFRelease(values);
    return algorithm;
}

// Certificate validity window (macOS 15 spelling of data every X.509 certificate has carried since
// 1988). 10.9 does not export these two accessors, but it does export the generic property reader they
// are a convenience over, and WebTransport calls them DIRECTLY -- no soft-link, no canLoad_ probe -- so
// an absent symbol is a `callq 0x0`, not a feature that declines.
//
// SecCertificateCopyValues reports each requested OID as a property dictionary whose kSecPropertyKeyValue
// is a CFNumber carrying a CFAbsoluteTime. Verified on this host against a system root: NotBefore
// 455108678.0 -> 2015-06-04 11:04:38 +0000, NotAfter 1086260678.0 -> 2035-06-04 11:04:38 +0000, i.e. the
// 20-year window that certificate really has. So the modern accessors' contract -- "the absolute time at
// which the certificate becomes valid / expires, CFRelease'd by the caller, NULL if unobtainable" -- is
// reproduced exactly, for any caller, not just WebKit's.
//
// Everything is reached by name because Security is not linked into every image that force-loads this
// archive: the OID and key constants through mav_securityConstant, the reader through WK_SYSTEM.
static CFDateRef mav_copyCertificateValidityDate(SecCertificateRef certificate, const char *oidName, void **oidCache)
{
    static void *valueKeyCache;
    CFStringRef oid = mav_securityConstant(oidName, oidCache);
    CFStringRef valueKey = mav_securityConstant("kSecPropertyKeyValue", &valueKeyCache);
    if (!certificate || !oid || !valueKey || !WK_SYSTEM(SecCertificateCopyValues))
        return NULL;

    CFStringRef keys[] = { oid };
    CFArrayRef requested = CFArrayCreate(kCFAllocatorDefault, (const void **)keys, 1, &kCFTypeArrayCallBacks);
    if (!requested)
        return NULL;
    CFDictionaryRef values = WK_SYSTEM(SecCertificateCopyValues)(certificate, requested, NULL);
    CFRelease(requested);
    if (!values)
        return NULL;

    CFDateRef date = NULL;
    CFTypeRef property = CFDictionaryGetValue(values, oid);
    if (property && CFGetTypeID(property) == CFDictionaryGetTypeID()) {
        CFTypeRef value = CFDictionaryGetValue((CFDictionaryRef)property, valueKey);
        if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
            double when = 0;
            if (CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &when))
                date = CFDateCreate(kCFAllocatorDefault, (CFAbsoluteTime)when);
        }
    }
    CFRelease(values);
    return date;   // +1, as the modern accessors return
}

WK_POLYFILL_ABSENT("Security", CFDateRef, SecCertificateCopyNotValidBeforeDate, (SecCertificateRef certificate))
{
    static void *oidCache;
    return mav_copyCertificateValidityDate(certificate, "kSecOIDX509V1ValidityNotBefore", &oidCache);
}

WK_POLYFILL_ABSENT("Security", CFDateRef, SecCertificateCopyNotValidAfterDate, (SecCertificateRef certificate))
{
    static void *oidCache;
    return mav_copyCertificateValidityDate(certificate, "kSecOIDX509V1ValidityNotAfter", &oidCache);
}

// ---------------------------------------------------------------------------------------------------
// Security — the two SecTask code-signing queries absent on 10.9.
//
// 10.9 has SecTaskCreateFromSelf / SecTaskCreateWithAuditToken / SecTaskCopyValueForEntitlement, but
// neither SecTaskCopySigningIdentifier (10.11+) nor SecTaskGetCodeSignStatus. Both are fully
// answerable here, because the kernel holds the answers and csops(2) hands them over: this is the
// same source 10.9's own SecTaskCopyValueForEntitlement reads. Neither touches the target's files,
// which is what lets a sandboxed caller identify a client without read access to its bundle.
//
// The one thing these need that the public API does not give is the pid a SecTaskRef names.
// 10.9's SecTaskCreateWithAuditToken reduces the audit token to a pid and stores just that, so the
// pid IS in the object and dies with it -- no side table, and none of the lifetime hazard a table
// keyed by the SecTaskRef pointer would carry. The offset is found by CALIBRATION rather than
// assumed: build SecTasks from two synthetic tokens carrying distinctive pids and take the offset
// only if both agree. If calibration fails, these report failure; they never invent an answer.
// ---------------------------------------------------------------------------------------------------

extern int csops(pid_t, unsigned int ops, void *useraddr, size_t usersize);

enum {
    MAV_CS_OPS_STATUS = 0,
    MAV_CS_OPS_BLOB = 10,
};

// Offset of the pid inside a 10.9 __SecTask, or -1 if it could not be established.
static long mav_secTaskPidOffsetValue = -1;

static void mav_calibrateSecTaskPidOffset(void)
{
    // Two values implausible as anything else in the object.
    const uint32_t probes[2] = { 0x5a5a5a5a, 0x0badf00d };
    long candidates[2] = { -1, -1 };
    for (unsigned i = 0; i < 2; ++i) {
        audit_token_t token;
        memset(&token, 0, sizeof(token));
        token.val[5] = probes[i]; // audit_token_to_pid() reads val[5]
        SecTaskRef task = SecTaskCreateWithAuditToken(kCFAllocatorDefault, token);
        if (!task)
            return;
        // Bound the scan by the object's real allocation -- a fixed guess would read past the end
        // on exactly the path this calibration exists to detect, where the layout has changed and
        // the pid is not found at all.
        const unsigned char *bytes = (const unsigned char *)task;
        long limit = (long)malloc_size(task);
        for (long candidate = 0; candidate + (long)sizeof(uint32_t) <= limit; candidate += sizeof(uint32_t)) {
            uint32_t value;
            memcpy(&value, bytes + candidate, sizeof(value));
            if (value == probes[i]) {
                candidates[i] = candidate;
                break;
            }
        }
        CFRelease(task);
    }

    // Only trust an offset both probes agree on; otherwise leave it at -1 and report failure.
    if (candidates[0] >= 0 && candidates[0] == candidates[1])
        mav_secTaskPidOffsetValue = candidates[0];
}

static long mav_secTaskPidOffset(void)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, mav_calibrateSecTaskPidOffset);
    return mav_secTaskPidOffsetValue;
}

static pid_t mav_pidForSecTask(SecTaskRef task)
{
    long offset = mav_secTaskPidOffset();
    if (!task || offset < 0)
        return -1;
    uint32_t pid;
    memcpy(&pid, (const unsigned char *)task + offset, sizeof(pid));
    return (pid_t)pid;
}

// Read a process's code signature blob. The kernel states the size itself: given a buffer of at
// least the 8-byte SuperBlob header it fails with ERANGE and copies that header out, whose second
// big-endian word is the length of the whole blob. So ask once for the length, then once for the
// data -- no growth loop, no ceiling, and *outSize is the length of the DATA rather than of some
// buffer that happened to be big enough, which is what keeps the parser's bounds honest.
//
// A target with no code signature at all fails with EINVAL at every size; there is genuinely no
// identifier to report for one, so that is a false return rather than something to retry around.
static bool mav_copyCodeSignatureBlob(pid_t pid, unsigned char **outBlob, size_t *outSize)
{
    unsigned char header[2 * sizeof(uint32_t)];
    memset(header, 0, sizeof(header));
    if (!csops(pid, MAV_CS_OPS_BLOB, header, sizeof(header)))
        return false; // A blob that fits in 8 bytes is not one; refuse rather than parse it.
    if (errno != ERANGE)
        return false;

    uint32_t length;
    memcpy(&length, header + sizeof(uint32_t), sizeof(length));
    length = OSSwapBigToHostInt32(length);
    if (length < sizeof(header))
        return false;

    unsigned char *blob = malloc(length);
    if (!blob)
        return false;
    if (csops(pid, MAV_CS_OPS_BLOB, blob, length)) {
        free(blob);
        return false;
    }

    *outBlob = blob;
    *outSize = length;
    return true;
}

static uint32_t mav_readBigEndian32(const unsigned char *blob, size_t size, size_t offset, bool *ok)
{
    if (offset + sizeof(uint32_t) > size) {
        *ok = false;
        return 0;
    }
    uint32_t value;
    memcpy(&value, blob + offset, sizeof(value));
    return OSSwapBigToHostInt32(value);
}

WK_POLYFILL_ABSENT("Security", CFStringRef, SecTaskCopySigningIdentifier, (SecTaskRef task, CFErrorRef *error))
{
    // A code signature is a SuperBlob of sub-blobs; the signing identifier lives in the
    // CodeDirectory at its identOffset. Every header field is big-endian.
    const uint32_t superBlobMagic = 0xfade0cc0;
    const uint32_t codeDirectoryMagic = 0xfade0c02;

    pid_t pid = mav_pidForSecTask(task);
    unsigned char *blob = NULL;
    size_t size = 0;
    if (pid < 0 || !mav_copyCodeSignatureBlob(pid, &blob, &size)) {
        mav_reportUnimplemented(error);
        return NULL;
    }

    bool ok = true;
    size_t codeDirectory = 0;
    uint32_t magic = mav_readBigEndian32(blob, size, 0, &ok);
    if (ok && magic == superBlobMagic) {
        uint32_t count = mav_readBigEndian32(blob, size, 2 * sizeof(uint32_t), &ok);
        bool found = false;
        for (uint32_t i = 0; ok && i < count; ++i) {
            // Each CS_BlobIndex is { type, offset }, after the 3-word SuperBlob header.
            size_t indexOffset = 3 * sizeof(uint32_t) + (size_t)i * 2 * sizeof(uint32_t) + sizeof(uint32_t);
            uint32_t blobOffset = mav_readBigEndian32(blob, size, indexOffset, &ok);
            if (ok && mav_readBigEndian32(blob, size, blobOffset, &ok) == codeDirectoryMagic) {
                codeDirectory = blobOffset;
                found = true;
                break;
            }
        }
        if (!found)
            ok = false;
    } else if (!ok || magic != codeDirectoryMagic)
        ok = false;

    CFStringRef identifier = NULL;
    if (ok) {
        // CS_CodeDirectory: magic, length, version, flags, hashOffset, identOffset, ...
        uint32_t identifierOffset = mav_readBigEndian32(blob, size, codeDirectory + 5 * sizeof(uint32_t), &ok);
        size_t start = codeDirectory + identifierOffset;
        if (ok && start < size) {
            size_t available = size - start;
            size_t length = strnlen((const char *)blob + start, available);
            if (length && length < available)
                identifier = CFStringCreateWithBytes(kCFAllocatorDefault, blob + start, length, kCFStringEncodingUTF8, false);
        }
    }

    free(blob);
    if (!identifier)
        mav_reportUnimplemented(error);
    return identifier;
}

// Code-sign status flags; WebKit tests `& CS_PLATFORM_BINARY`. The 26.1 SDK declares this
// __API_UNAVAILABLE(macos), which makes even taking its address an error, so re-declare it as
// available for the registry entry below.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wavailability"
__attribute__((availability(macos, introduced=10.0))) uint32_t SecTaskGetCodeSignStatus(SecTaskRef task);
#pragma clang diagnostic pop
WK_POLYFILL_ABSENT("Security", uint32_t, SecTaskGetCodeSignStatus, (SecTaskRef task))
{
    pid_t pid = mav_pidForSecTask(task);
    uint32_t status = 0;
    if (pid < 0 || csops(pid, MAV_CS_OPS_STATUS, &status, sizeof(status)))
        return 0;
    return status;
}

// SecTrust IPC serialization (12.0+). A serialized trust has to carry the state a receiver needs to
// reach the same verdict the sender would: the certificates, the policies they are judged against, any
// custom anchors, whether network fetching is allowed, the verification date, and the result the sender
// computed. All of that is readable on 10.9, and apart from the certificates it is readable without
// evaluating anything (measured: policies + custom anchors + network-fetch + verify time on an
// unevaluated trust leave it kSecTrustResultInvalid and cost 0.0000s).
//
// User exceptions are NOT carried, because 10.9 cannot report them. SecTrustCopyExceptions is not a
// getter for exceptions somebody set — it mints a blanket "accept whatever this chain currently
// reports" blob for any trust, including one that just failed, and there is no getter for what was
// actually set. Carrying its output would hand the receiver a verdict instead of the sender's state:
// measured on a self-signed chain, the sender evaluates kSecTrustResultRecoverableTrustFailure, and a
// receiver given that blob reports kSecTrustResultProceed. Since nothing in this tree sets exceptions
// on a trust that crosses IPC, omitting them is what the platform can honestly report.
//
// Carrying only the chain -- which is what this did before -- was a security-relevant loss, not a
// lossy convenience: a trust that went in bound to a hostname by SecPolicyCreateSSL came back under
// SecPolicyCreateBasicX509, so the receiver evaluated a weaker question than the sender asked. Measured
// against github.com's chain: the original policy and a policy rebuilt through its properties both
// report kSecTrustResultProceed, a rebuilt policy carrying the WRONG hostname reports
// kSecTrustResultRecoverableTrustFailure -- and basic X.509 reports Proceed, accepting a chain the
// hostname-bound question rejects.
//
// 10.9 has no way to install a trust result on a trust object, so a receiver that asks for a verdict
// re-evaluates; carrying the policies, anchors and date is what makes that re-evaluation
// answer the sender's question. The result is carried for a receiver that only wants to know what the
// sender concluded.
static CFStringRef const kMavTrustCertificates = CFSTR("certificates");
static CFStringRef const kMavTrustPolicies = CFSTR("policies");
static CFStringRef const kMavTrustAnchors = CFSTR("anchors");
static CFStringRef const kMavTrustNetworkFetchAllowed = CFSTR("networkFetchAllowed");
static CFStringRef const kMavTrustVerifyDate = CFSTR("verifyDate");
static CFStringRef const kMavTrustResult = CFSTR("result");

// DER for each certificate in an array of SecCertificateRef, and the reverse.
static CFArrayRef mav_certificateDataArray(CFArrayRef certificates)
{
    CFIndex count = certificates ? CFArrayGetCount(certificates) : 0;
    CFMutableArrayRef datas = CFArrayCreateMutable(NULL, count, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; i < count; ++i) {
        SecCertificateRef certificate = (SecCertificateRef)CFArrayGetValueAtIndex(certificates, i);
        CFDataRef der = certificate ? SecCertificateCopyData(certificate) : NULL;
        if (der) {
            CFArrayAppendValue(datas, der);
            CFRelease(der);
        }
    }
    return datas;
}

static CFArrayRef mav_certificateArrayFromData(CFArrayRef datas)
{
    CFIndex count = datas ? CFArrayGetCount(datas) : 0;
    CFMutableArrayRef certificates = CFArrayCreateMutable(NULL, count, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; i < count; ++i) {
        CFDataRef der = (CFDataRef)CFArrayGetValueAtIndex(datas, i);
        if (!der || CFGetTypeID(der) != CFDataGetTypeID())
            continue;
        SecCertificateRef certificate = SecCertificateCreateWithData(NULL, der);
        if (certificate) {
            CFArrayAppendValue(certificates, certificate);
            CFRelease(certificate);
        }
    }
    return certificates;
}

WK_POLYFILL_ABSENT("Security", CFDataRef, SecTrustSerialize, (SecTrustRef trust, CFErrorRef *error))
{
    if (error)
        *error = NULL;
    if (!trust) {
        mav_reportUnimplemented(error);
        return NULL;
    }

    CFMutableDictionaryRef state = CFDictionaryCreateMutable(NULL, 7, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

    CFIndex count = SecTrustGetCertificateCount(trust);
    CFMutableArrayRef certificates = CFArrayCreateMutable(NULL, count, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; i < count; ++i) {
        SecCertificateRef certificate = SecTrustGetCertificateAtIndex(trust, i);
        if (certificate)
            CFArrayAppendValue(certificates, certificate);
    }
    CFArrayRef certificateDatas = mav_certificateDataArray(certificates);
    CFDictionarySetValue(state, kMavTrustCertificates, certificateDatas);
    CFRelease(certificateDatas);
    CFRelease(certificates);

    // A policy travels as the property dictionary that describes it, which is what
    // SecPolicyCreateWithProperties reverses.
    CFArrayRef policies = NULL;
    if (SecTrustCopyPolicies(trust, &policies) == errSecSuccess && policies) {
        CFIndex policyCount = CFArrayGetCount(policies);
        CFMutableArrayRef policyProperties = CFArrayCreateMutable(NULL, policyCount, &kCFTypeArrayCallBacks);
        for (CFIndex i = 0; i < policyCount; ++i) {
            CFDictionaryRef properties = SecPolicyCopyProperties((SecPolicyRef)CFArrayGetValueAtIndex(policies, i));
            if (properties) {
                CFArrayAppendValue(policyProperties, properties);
                CFRelease(properties);
            }
        }
        CFDictionarySetValue(state, kMavTrustPolicies, policyProperties);
        CFRelease(policyProperties);
        CFRelease(policies);
    }

    CFArrayRef anchors = NULL;
    if (SecTrustCopyCustomAnchorCertificates(trust, &anchors) == errSecSuccess && anchors) {
        CFArrayRef anchorDatas = mav_certificateDataArray(anchors);
        CFDictionarySetValue(state, kMavTrustAnchors, anchorDatas);
        CFRelease(anchorDatas);
        CFRelease(anchors);
    }

    Boolean networkFetchAllowed = false;
    if (SecTrustGetNetworkFetchAllowed(trust, &networkFetchAllowed) == errSecSuccess)
        CFDictionarySetValue(state, kMavTrustNetworkFetchAllowed, networkFetchAllowed ? kCFBooleanTrue : kCFBooleanFalse);

    CFAbsoluteTime verifyTime = SecTrustGetVerifyTime(trust);
    if (verifyTime) {
        CFNumberRef date = CFNumberCreate(NULL, kCFNumberDoubleType, &verifyTime);
        CFDictionarySetValue(state, kMavTrustVerifyDate, date);
        CFRelease(date);
    }

    SecTrustResultType trustResult = kSecTrustResultInvalid;
    if (SecTrustGetTrustResult(trust, &trustResult) == errSecSuccess) {
        int32_t value = (int32_t)trustResult;
        CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt32Type, &value);
        CFDictionarySetValue(state, kMavTrustResult, number);
        CFRelease(number);

    }

    CFDataRef data = CFPropertyListCreateData(NULL, state, kCFPropertyListBinaryFormat_v1_0, 0, NULL);
    CFRelease(state);
    if (!data)
        mav_reportUnimplemented(error);
    return data;
}

WK_POLYFILL_ABSENT("Security", SecTrustRef, SecTrustDeserialize, (CFDataRef serializedTrust, CFErrorRef *error))
{
    if (error)
        *error = NULL;
    if (!serializedTrust) {
        mav_reportUnimplemented(error);
        return NULL;
    }
    CFDictionaryRef state = (CFDictionaryRef)CFPropertyListCreateWithData(NULL, serializedTrust, kCFPropertyListImmutable, NULL, NULL);
    if (!state || CFGetTypeID(state) != CFDictionaryGetTypeID()) {
        if (state)
            CFRelease(state);
        mav_reportUnimplemented(error);
        return NULL;
    }

    CFArrayRef certificates = mav_certificateArrayFromData((CFArrayRef)CFDictionaryGetValue(state, kMavTrustCertificates));

    CFArrayRef policyProperties = (CFArrayRef)CFDictionaryGetValue(state, kMavTrustPolicies);
    CFMutableArrayRef policies = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    if (policyProperties && CFGetTypeID(policyProperties) == CFArrayGetTypeID()) {
        CFIndex policyCount = CFArrayGetCount(policyProperties);
        for (CFIndex i = 0; i < policyCount; ++i) {
            CFDictionaryRef properties = (CFDictionaryRef)CFArrayGetValueAtIndex(policyProperties, i);
            if (!properties || CFGetTypeID(properties) != CFDictionaryGetTypeID())
                continue;
            CFTypeRef oid = CFDictionaryGetValue(properties, kSecPolicyOid);
            SecPolicyRef policy = oid ? SecPolicyCreateWithProperties(oid, properties) : NULL;
            if (policy) {
                CFArrayAppendValue(policies, policy);
                CFRelease(policy);
            }
        }
    }
    // A trust with no policy cannot be evaluated at all; basic X.509 is the only honest stand-in when
    // the sender had nothing to describe, and it is never reached for a trust that carried one.
    if (!CFArrayGetCount(policies)) {
        SecPolicyRef basic = SecPolicyCreateBasicX509();
        CFArrayAppendValue(policies, basic);
        CFRelease(basic);
    }

    SecTrustRef trust = NULL;
    OSStatus status = SecTrustCreateWithCertificates(certificates, policies, &trust);
    CFRelease(certificates);
    CFRelease(policies);
    if (status != errSecSuccess || !trust) {
        CFRelease(state);
        mav_reportUnimplemented(error);
        return NULL;
    }

    CFArrayRef anchorDatas = (CFArrayRef)CFDictionaryGetValue(state, kMavTrustAnchors);
    if (anchorDatas && CFGetTypeID(anchorDatas) == CFArrayGetTypeID()) {
        CFArrayRef anchors = mav_certificateArrayFromData(anchorDatas);
        SecTrustSetAnchorCertificates(trust, anchors);
        CFRelease(anchors);
    }

    CFBooleanRef networkFetchAllowed = (CFBooleanRef)CFDictionaryGetValue(state, kMavTrustNetworkFetchAllowed);
    if (networkFetchAllowed && CFGetTypeID(networkFetchAllowed) == CFBooleanGetTypeID())
        SecTrustSetNetworkFetchAllowed(trust, CFBooleanGetValue(networkFetchAllowed));

    CFNumberRef verifyDate = (CFNumberRef)CFDictionaryGetValue(state, kMavTrustVerifyDate);
    if (verifyDate && CFGetTypeID(verifyDate) == CFNumberGetTypeID()) {
        double when = 0;
        if (CFNumberGetValue(verifyDate, kCFNumberDoubleType, &when)) {
            CFDateRef date = CFDateCreate(NULL, when);
            SecTrustSetVerifyDate(trust, date);
            CFRelease(date);
        }
    }

    CFRelease(state);
    return trust;
}

// Attribution of a cross-process trust evaluation to the client. 10.9's Security has no
// client-attribution facility for a trust evaluation at all (it exports SecTaskCreateWithAuditToken
// and AuthorizationCreateWithAuditToken, and nothing that attaches an audit token to a SecTrust), so
// the postcondition -- this evaluation is attributed to that client -- is never established, and the
// status says so. Claiming errSecSuccess would report work the system never did, on the strength of
// what callers happen to tolerate rather than what the platform can do. Telling the truth costs
// nothing: both callers discard the status (ResourceResponseCocoa.mm:99, NetworkSessionCocoa.mm:526),
// and a third caller that checks it gets a correct answer.
WK_POLYFILL_ABSENT("Security", int, SecTrustSetClientAuditToken, (SecTrustRef trust, CFDataRef auditToken))
{
    (void)trust; (void)auditToken;
    return errSecUnimplemented;
}

// SecTrustCopyCertificateChain (Security, 12.0+): rebuild the evaluated chain via the per-index
// accessors 10.9 ships.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
WK_POLYFILL_ABSENT("Security", CFArrayRef, SecTrustCopyCertificateChain, (SecTrustRef trust))
{
    if (!trust)
        return NULL;
    CFIndex count = SecTrustGetCertificateCount(trust);
    if (count <= 0)
        return NULL;
    CFMutableArrayRef chain = CFArrayCreateMutable(kCFAllocatorDefault, count, &kCFTypeArrayCallBacks);
    if (!chain)
        return NULL;
    for (CFIndex i = 0; i < count; i++) {
        SecCertificateRef cert = SecTrustGetCertificateAtIndex(trust, i);
        if (cert)
            CFArrayAppendValue(chain, cert);
    }
    return chain;
}
#pragma clang diagnostic pop

// ---------------------------------------------------------------------------------------------------
// Security — trust evaluation
// ---------------------------------------------------------------------------------------------------

// 10.9's SecTrustEvaluate and SecPolicyCreateRevocation work, so WebKit calls them directly.
// Verified on-host: SecPolicyCreateRevocation returns a real policy, and SecTrustEvaluate on a trust
// built with both an SSL and a revocation policy returns errSecSuccess without faulting in
// compareRevocationPolicies. The trust CFNetwork hands WebKit carries an SSL policy built with the
// server's hostname, and evaluating it unmodified is what checks that hostname.

// SecTrustEvaluateWithError (10.14+) is the error-reporting spelling of SecTrustEvaluate: it reports
// success for the two "trusted" result types and otherwise builds a CFError describing why. Built on
// SecTrustEvaluate above, so it inherits the same real chain evaluation.
static CFStringRef mav_trustResultDescription(SecTrustResultType resultType)
{
    switch (resultType) {
    case kSecTrustResultInvalid: return CFSTR("Error evaluating certificate");
    case kSecTrustResultDeny: return CFSTR("User specified to deny trust");
    case kSecTrustResultUnspecified: return CFSTR("Rejected Certificate");
    case kSecTrustResultRecoverableTrustFailure: return CFSTR("Rejected Certificate");
    case kSecTrustResultFatalTrustFailure: return CFSTR("Bad Certificate");
    case kSecTrustResultOtherError: return CFSTR("Error evaluating certificate");
    case kSecTrustResultProceed: return CFSTR("Proceed");
    default: return CFSTR("Unknown");
    }
}

WK_POLYFILL_ABSENT("Security", bool, SecTrustEvaluateWithError, (SecTrustRef trust, CFErrorRef *error))
{
    SecTrustResultType trustResult = kSecTrustResultInvalid;
    OSStatus status = SecTrustEvaluate(trust, &trustResult);
    if (status == errSecSuccess
        && (trustResult == kSecTrustResultProceed || trustResult == kSecTrustResultUnspecified)) {
        if (error)
            *error = NULL;
        return true;
    }
    if (error) {
        CFStringRef keys[] = { kCFErrorLocalizedDescriptionKey };
        CFStringRef values[] = { mav_trustResultDescription(trustResult) };
        CFDictionaryRef userInfo = CFDictionaryCreate(kCFAllocatorDefault, (const void **)keys,
            (const void **)values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        // Domain/code carry the machine-readable failure; the sentence belongs in userInfo. status is
        // errSecSuccess when the evaluation itself worked but the result is untrusted.
        *error = CFErrorCreate(kCFAllocatorDefault, kCFErrorDomainOSStatus,
            status == errSecSuccess ? errSecNotTrusted : status, userInfo);
        if (userInfo)
            CFRelease(userInfo);
    }
    return false;
}

// The async form (10.14+). 10.9 has neither it nor a trust-evaluation queue of its own, but the whole
// of its contract is "run the synchronous evaluation somewhere else and hand the caller the verdict",
// and the synchronous evaluation is right above -- so this is implementable rather than stubbable, and
// the result is correct for any caller.
//
// It matters that it is implemented. WebTransport calls it DIRECTLY at
// NetworkTransportSessionCocoa.mm:147 -- no soft-link and no canLoad_ probe -- from inside the
// sec_protocol verify block, so an absent symbol is a branch to address 0 in the NetworkProcess on the
// first server-trust challenge, with nothing at the fault site naming it.
//
// Ownership follows the async contract: the trust object and the callback must outlive this call, so
// the trust is retained across the hop and the block is copied by dispatch_async (which transitively
// copies the callback it captures). The CFError produced by the evaluation is +1 and is released after
// the callback has read it, matching what the real API hands a callback that does not retain it.
WK_POLYFILL_ABSENT("Security", OSStatus, SecTrustEvaluateAsyncWithError,
    (SecTrustRef trust, dispatch_queue_t queue, SecTrustWithErrorCallback result))
{
    if (!trust || !queue || !result)
        return errSecParam;

    CFRetain(trust);
    dispatch_async(queue, ^{
        CFErrorRef error = NULL;
        bool trusted = SecTrustEvaluateWithError(trust, &error);
        result(trust, trusted, error);
        if (error)
            CFRelease(error);
        CFRelease(trust);
    });
    return errSecSuccess;
}

// ---------------------------------------------------------------------------------------------------
// Security — SecKey (10.12+)
//
// The modern SecKey OPERATIONS postdate 10.9 and have no 10.9-era equivalent to build them out of:
// 10.9's key API is CSSM-based and cannot produce or consume a SecKeyRef with these semantics. Those
// entry points report "no key / no result" and leave *error unset, which is the outcome callers
// already handle for an unsupported algorithm. WebCrypto's key operations run on libgcrypt in this
// port, so nothing on the live paths depends on them. The claim is about the operations, not about
// every name in this section: SecCertificateCopyKey below is renamed rather than new, and 10.9 does
// export what it needs.
// ---------------------------------------------------------------------------------------------------

// SecCertificateCopyKey (10.14+) is the renamed SecCertificateCopyPublicKey: same job -- hand back the
// certificate's public key as a +1 SecKeyRef -- with the status folded into the return value. 10.9
// exports the older spelling (nm-verified), so this is implementable rather than a stub, and it is
// implemented even though nothing in this tree calls it: a polyfill has to be right for any caller,
// and returning NULL for a key 10.9 can produce would be a fake answer the moment a rebase adds one.
// Reached by name because Security is not linked into every image that force-loads this archive.
WK_SYSTEM_FN("Security", OSStatus, SecCertificateCopyPublicKey, (SecCertificateRef, SecKeyRef *));

WK_POLYFILL_ABSENT("Security", SecKeyRef, SecCertificateCopyKey, (SecCertificateRef certificate))
{
    if (!certificate || !WK_SYSTEM(SecCertificateCopyPublicKey))
        return NULL;
    SecKeyRef key = NULL;
    if (WK_SYSTEM(SecCertificateCopyPublicKey)(certificate, &key) != errSecSuccess)
        return NULL;
    return key;   // +1, as the modern accessor returns
}


WK_POLYFILL_ABSENT("Security", CFDataRef, SecKeyCopyExternalRepresentation, (SecKeyRef key, CFErrorRef *error))
{
    (void)key;
    mav_reportUnimplemented(error);
    return NULL;
}

WK_POLYFILL_ABSENT("Security", SecKeyRef, SecKeyCreateWithData, (CFDataRef keyData, CFDictionaryRef attributes, CFErrorRef *error))
{
    (void)keyData; (void)attributes;
    mav_reportUnimplemented(error);
    return NULL;
}

WK_POLYFILL_ABSENT("Security", SecKeyRef, SecKeyCreateRandomKey, (CFDictionaryRef parameters, CFErrorRef *error))
{
    (void)parameters;
    mav_reportUnimplemented(error);
    return NULL;
}

WK_POLYFILL_ABSENT("Security", CFDataRef, SecKeyCreateSignature, (SecKeyRef key, SecKeyAlgorithm algorithm, CFDataRef dataToSign, CFErrorRef *error))
{
    (void)key; (void)algorithm; (void)dataToSign;
    mav_reportUnimplemented(error);
    return NULL;
}

WK_POLYFILL_ABSENT("Security", Boolean, SecKeyVerifySignature, (SecKeyRef key, SecKeyAlgorithm algorithm, CFDataRef signedData, CFDataRef signature, CFErrorRef *error))
{
    (void)key; (void)algorithm; (void)signedData; (void)signature;
    mav_reportUnimplemented(error);
    return false;
}

WK_POLYFILL_ABSENT("Security", CFDataRef, SecKeyCreateEncryptedData, (SecKeyRef key, SecKeyAlgorithm algorithm, CFDataRef plaintext, CFErrorRef *error))
{
    (void)key; (void)algorithm; (void)plaintext;
    mav_reportUnimplemented(error);
    return NULL;
}

WK_POLYFILL_ABSENT("Security", CFDataRef, SecKeyCreateDecryptedData, (SecKeyRef key, SecKeyAlgorithm algorithm, CFDataRef ciphertext, CFErrorRef *error))
{
    (void)key; (void)algorithm; (void)ciphertext;
    mav_reportUnimplemented(error);
    return NULL;
}

WK_POLYFILL_ABSENT("Security", SecKeyRef, SecKeyCopyPublicKey, (SecKeyRef key))
{
    (void)key;
    return NULL;
}

WK_POLYFILL_ABSENT("Security", CFDictionaryRef, SecKeyCopyAttributes, (SecKeyRef key))
{
    (void)key;
    return NULL;
}

WK_POLYFILL_ABSENT("Security", CFDataRef, SecKeyCopyKeyExchangeResult,
    (SecKeyRef publicKey, SecKeyAlgorithm algorithm, SecKeyRef parameters, CFDictionaryRef requestedSize, CFErrorRef *error))
{
    (void)publicKey; (void)algorithm; (void)parameters; (void)requestedSize;
    mav_reportUnimplemented(error);
    return NULL;
}

// ---------------------------------------------------------------------------------------------------
// Security — SecureTransport ALPN (10.13.4+)
//
// ALPN negotiation postdates 10.9's SecureTransport, and there is no handshake extension to drive it
// with. errSecUnimplemented (-4) is the documented "this call is not implemented" status, which makes
// callers proceed without ALPN — i.e. the protocol is negotiated the pre-ALPN way.
// ---------------------------------------------------------------------------------------------------

WK_POLYFILL_ABSENT("Security", OSStatus, SSLCopyALPNProtocols, (SSLContextRef context, CFArrayRef *protocols))
{
    (void)context;
    if (protocols) *protocols = NULL;
    return errSecUnimplemented;
}

WK_POLYFILL_ABSENT("Security", OSStatus, SSLSetALPNProtocols, (SSLContextRef context, CFArrayRef protocols))
{
    (void)context; (void)protocols;
    return errSecUnimplemented;
}
