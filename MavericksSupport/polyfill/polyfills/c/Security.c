// Security: entry points and constants modern WebKit references that 10.9's Security does not export.
#include "wk_polyfill.h"
#include "wk_trust.h"

#include <CommonCrypto/CommonDigest.h>
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <Security/cssmtype.h>
#include <Security/cssmapple.h>
#include <objc/message.h>
#include <objc/runtime.h>
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
// file's convention: 10.9's Security predates tokens and access-control objects entirely, and
// SecKeyCreateRandomKey below hands its dictionary to SecKeyGeneratePair, which reads the key type and
// size and ignores the rest -- so nothing on 10.9 compares these five strings against anything. They
// are declared for the LOAD, not the value: each is read as a plain argument
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
// The message-signing variant: it digests its input and then signs, where the sibling digest-x962
// identifier below signs a digest the caller already computed. It is the one algorithm WebKit's
// WebAuthn code actually passes (LocalAuthenticator.mm, VirtualAuthenticatorUtils.mm).
WK_POLYFILL_CONST("Security", CFStringRef, kSecKeyAlgorithmECDSASignatureMessageX962SHA256, CFSTR("algid:sign:ECDSA:message-x962:SHA-256"));

// SecKeyAlgorithm identifiers (10.12+). 10.9's Security has no SecKeyAlgorithm API at all, so there is
// no value to read off this OS and nothing here interprets these strings but this file: the SecKey
// entry points below match them against each other with CFEqual to pick a digest and a padding. They
// are this layer's own selectors, spelled to one scheme -- algid:<operation>:<algorithm>:<variant> --
// so that they are distinct and readable, not because the spelling is checkable against a source.
WK_POLYFILL_CONST("Security", CFStringRef, kSecKeyAlgorithmECDHKeyExchangeStandard, CFSTR("algid:keyexchange:ECDH:standard"));
WK_POLYFILL_CONST("Security", CFStringRef, kSecKeyAlgorithmECDSASignatureDigestX962, CFSTR("algid:sign:ECDSA:digest-x962"));
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
static void mav_reportOSStatus(CFErrorRef *error, OSStatus status)
{
    if (error)
        *error = CFErrorCreate(kCFAllocatorDefault, kCFErrorDomainOSStatus, status, NULL);
}

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

    // One C-string extraction, then byte compares: this runs per certificate of every TLS handshake,
    // and a CFString is allocated per table row otherwise. A dotted OID longer than the buffer is one
    // the table does not name.
    char dotted[64];
    if (!oid || !CFStringGetCString(oid, dotted, sizeof(dotted), kCFStringEncodingASCII))
        return MavSecSignatureHashAlgorithmUnknown;
    for (size_t i = 0; i < sizeof(table) / sizeof(table[0]); i++) {
        if (!strcmp(dotted, table[i].oid))
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

// SecTrust IPC serialization (12.0+). A serialized trust carries the state a receiver needs to reach
// the same verdict the sender would: the certificates, the policies they are judged against, any custom
// anchors, whether network fetching is allowed, and the verification date. All of that is readable on
// 10.9, and apart from the certificates it is readable without evaluating anything (measured: policies
// + custom anchors + network-fetch + verify time on an unevaluated trust leave it
// kSecTrustResultInvalid and cost 0.0000s).
//
// User exceptions are NOT carried, because 10.9 cannot report them. SecTrustCopyExceptions is not a
// getter for exceptions somebody set -- it mints a blanket "accept whatever this chain currently
// reports" blob for any trust, including one that just failed, and there is no getter for what was
// actually set. Carrying its output would hand the receiver a verdict instead of the sender's state:
// measured on a self-signed chain, the sender evaluates kSecTrustResultRecoverableTrustFailure, and a
// receiver given that blob reports kSecTrustResultProceed. Since nothing in this tree sets exceptions
// on a trust that crosses IPC, omitting them is what the platform can honestly report.
//
// The policies decide the question the receiver asks, so they travel by what they are made of rather
// than by the dictionary that describes them: SecPolicyCopyProperties reports a name and an OID and
// says nothing about the client/server direction, and SecPolicyCreateWithProperties writes a server
// name back with its NUL included, so "example.org" returns as 12 bytes. A trust that names no policy
// is one this cannot rebuild, and it answers NULL: a receiver handed a policy the sender never asked
// for would evaluate a weaker question. Measured against github.com's chain, a policy carrying the
// WRONG hostname reports kSecTrustResultRecoverableTrustFailure where the right one reports Proceed,
// and basic X.509 reports Proceed for both -- accepting a chain the hostname-bound question rejects.
//
// 10.9 has no way to install a trust result on a trust object, so a receiver that asks for a verdict
// re-evaluates; carrying the policies, anchors and date is what makes that re-evaluation answer the
// sender's question.
static CFStringRef const kMavTrustCertificates = CFSTR("certificates");
static CFStringRef const kMavTrustPolicies = CFSTR("policies");
static CFStringRef const kMavTrustAnchors = CFSTR("anchors");
static CFStringRef const kMavTrustNetworkFetchAllowed = CFSTR("networkFetchAllowed");
static CFStringRef const kMavTrustVerifyDate = CFSTR("verifyDate");
static CFStringRef const kMavPolicyOID = CFSTR("oid");
static CFStringRef const kMavPolicyServerName = CFSTR("serverName");
static CFStringRef const kMavPolicyFlags = CFSTR("flags");

// DER for each certificate in an array of SecCertificateRef, and the reverse. An element that cannot
// be converted fails the whole array: the receiver gets every certificate the sender had, or none.
static CFArrayRef mav_certificateDataArray(CFArrayRef certificates)
{
    if (!certificates || CFGetTypeID(certificates) != CFArrayGetTypeID())
        return NULL;
    CFIndex count = CFArrayGetCount(certificates);
    CFMutableArrayRef datas = CFArrayCreateMutable(NULL, count, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; i < count; ++i) {
        SecCertificateRef certificate = (SecCertificateRef)CFArrayGetValueAtIndex(certificates, i);
        CFDataRef der = certificate && CFGetTypeID(certificate) == SecCertificateGetTypeID()
            ? SecCertificateCopyData(certificate) : NULL;
        if (!der) {
            CFRelease(datas);
            return NULL;
        }
        CFArrayAppendValue(datas, der);
        CFRelease(der);
    }
    return datas;
}

static CFArrayRef mav_certificateArrayFromData(CFArrayRef datas)
{
    if (!datas || CFGetTypeID(datas) != CFArrayGetTypeID())
        return NULL;
    CFIndex count = CFArrayGetCount(datas);
    CFMutableArrayRef certificates = CFArrayCreateMutable(NULL, count, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; i < count; ++i) {
        CFDataRef der = (CFDataRef)CFArrayGetValueAtIndex(datas, i);
        SecCertificateRef certificate = der && CFGetTypeID(der) == CFDataGetTypeID()
            ? SecCertificateCreateWithData(NULL, der) : NULL;
        if (!certificate) {
            CFRelease(certificates);
            return NULL;
        }
        CFArrayAppendValue(certificates, certificate);
        CFRelease(certificate);
    }
    return certificates;
}

// The certificates a trust was created with. 10.9's SecTrust accessors report the evaluated chain --
// SecTrustGetCertificateCount runs the evaluation to produce it, and a three-certificate input comes
// back as the one certificate the evaluator kept -- and SecTrustCopyInputCertificates does not exist
// here. Security's Trust object keeps the caller's array in a CFArray field at this offset from the
// SecTrustRef, measured on 10.9.5 (malloc_size 352) as the only certificate array present before an
// evaluation and unchanged by one. Reading it costs no evaluation. The field is checked before it is
// believed: it must be a heap CFArray of SecCertificates whose first element is the trust's leaf --
// SecTrustGetCertificateAtIndex(trust, 0) answers without evaluating, evaluated or not -- and anything
// else is NULL.
enum { kMavTrustInputCertificatesOffset = 0x98 };

CFArrayRef wk_trustInputCertificates(SecTrustRef trust)
{
    if (malloc_size(trust) < kMavTrustInputCertificatesOffset + sizeof(CFArrayRef))
        return NULL;
    CFArrayRef certificates = *(CFArrayRef *)((const char *)trust + kMavTrustInputCertificatesOffset);
    if (!certificates || ((uintptr_t)certificates & (sizeof(void *) - 1)) || !malloc_size(certificates)
        || CFGetTypeID(certificates) != CFArrayGetTypeID())
        return NULL;
    CFIndex count = CFArrayGetCount(certificates);
    if (count < 1)
        return NULL;
    for (CFIndex i = 0; i < count; ++i) {
        const void *certificate = CFArrayGetValueAtIndex(certificates, i);
        if (!certificate || !malloc_size(certificate) || CFGetTypeID(certificate) != SecCertificateGetTypeID())
            return NULL;
    }

    SecCertificateRef leaf = SecTrustGetCertificateAtIndex(trust, 0);
    CFDataRef leafDER = leaf ? SecCertificateCopyData(leaf) : NULL;
    CFDataRef firstDER = SecCertificateCopyData((SecCertificateRef)CFArrayGetValueAtIndex(certificates, 0));
    bool sameLeaf = leafDER && firstDER && CFEqual(leafDER, firstDER);
    if (leafDER)
        CFRelease(leafDER);
    if (firstDER)
        CFRelease(firstDER);
    return sameLeaf ? certificates : NULL;
}

// A policy, as the OID that names it and the options it carries. SecPolicyGetValue hands back the
// option block a policy was made with -- for SSL that is CSSM_APPLE_TP_SSL_OPTIONS, whose ServerName is
// a pointer into the policy, so the name is copied out by length rather than shipped as the pointer it
// is. Its flags carry the bit that says whether the policy asks the client question or the server one,
// which no property dictionary on this OS reports.
//
// A policy this cannot describe, or cannot rebuild, fails the whole serialization. Dropping one would
// hand the receiver a subset of the sender's checks -- a weaker question, silently.
static bool mav_oidEquals(const CSSM_OID *a, const CSSM_OID *b)
{
    return a && b && a->Length == b->Length && a->Data && b->Data && !memcmp(a->Data, b->Data, a->Length);
}

static CFDictionaryRef mav_copyPolicyDescription(SecPolicyRef policy)
{
    if (!policy)
        return NULL;
    CSSM_OID oid;
    memset(&oid, 0, sizeof(oid));
    if (SecPolicyGetOID(policy, &oid) != errSecSuccess || !oid.Data || !oid.Length)
        return NULL;

    // Only the policies this can put back are worth describing: an SSL policy by its options, and a
    // basic X.509 policy, which carries none. A revocation policy names its methods in neither
    // SecPolicyGetValue (empty on this OS) nor SecPolicyCopyProperties (OID only), so it cannot be
    // rebuilt as the policy it was and is refused rather than rebuilt as a weaker one.
    bool isSSL = mav_oidEquals(&oid, &CSSMOID_APPLE_TP_SSL);
    if (!isSSL && !mav_oidEquals(&oid, &CSSMOID_APPLE_X509_BASIC))
        return NULL;

    CFMutableDictionaryRef description = CFDictionaryCreateMutable(NULL, 3, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    if (!description)
        return NULL;
    CFDataRef oidData = CFDataCreate(NULL, oid.Data, (CFIndex)oid.Length);
    CFDictionarySetValue(description, kMavPolicyOID, oidData);
    CFRelease(oidData);
    if (!isSSL)
        return description;

    CSSM_DATA value;
    memset(&value, 0, sizeof(value));
    const CSSM_APPLE_TP_SSL_OPTIONS *options = NULL;
    if (SecPolicyGetValue(policy, &value) == errSecSuccess && value.Data
        && value.Length >= sizeof(CSSM_APPLE_TP_SSL_OPTIONS)) {
        const CSSM_APPLE_TP_SSL_OPTIONS *candidate = (const CSSM_APPLE_TP_SSL_OPTIONS *)value.Data;
        if (candidate->Version == CSSM_APPLE_TP_SSL_OPTS_VERSION)
            options = candidate;
    }
    // An SSL policy that names no host is a real policy on this OS; one whose options cannot be read is
    // not the same thing, and must not arrive as one.
    if (!options) {
        CFRelease(description);
        return NULL;
    }
    if (options->ServerNameLen) {
        if (!options->ServerName) {
            CFRelease(description);
            return NULL;
        }
        CFDataRef name = CFDataCreate(NULL, (const uint8_t *)options->ServerName, (CFIndex)options->ServerNameLen);
        CFDictionarySetValue(description, kMavPolicyServerName, name);
        CFRelease(name);
    }
    int32_t flags = (int32_t)options->Flags;
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt32Type, &flags);
    CFDictionarySetValue(description, kMavPolicyFlags, number);
    CFRelease(number);
    return description;
}

// The inverse, built with the concrete constructors: SecPolicyCreateWithProperties is what writes a
// server name back with its terminator included.
static SecPolicyRef mav_createPolicyFromDescription(CFDictionaryRef description)
{
    CFDataRef oidData = (CFDataRef)CFDictionaryGetValue(description, kMavPolicyOID);
    if (!oidData || CFGetTypeID(oidData) != CFDataGetTypeID())
        return NULL;
    CSSM_OID oid;
    oid.Data = (uint8_t *)CFDataGetBytePtr(oidData);
    oid.Length = (CSSM_SIZE)CFDataGetLength(oidData);

    if (mav_oidEquals(&oid, &CSSMOID_APPLE_X509_BASIC))
        return SecPolicyCreateBasicX509();
    if (!mav_oidEquals(&oid, &CSSMOID_APPLE_TP_SSL))
        return NULL;

    CFNumberRef number = (CFNumberRef)CFDictionaryGetValue(description, kMavPolicyFlags);
    if (!number || CFGetTypeID(number) != CFNumberGetTypeID())
        return NULL;
    int32_t flags = 0;
    CFNumberGetValue(number, kCFNumberSInt32Type, &flags);

    CFDataRef nameData = (CFDataRef)CFDictionaryGetValue(description, kMavPolicyServerName);
    CFStringRef name = NULL;
    if (nameData) {
        if (CFGetTypeID(nameData) != CFDataGetTypeID())
            return NULL;
        name = CFStringCreateWithBytes(NULL, CFDataGetBytePtr(nameData), CFDataGetLength(nameData),
            kCFStringEncodingUTF8, false);
        if (!name)
            return NULL;
    }
    SecPolicyRef policy = SecPolicyCreateSSL(!(flags & CSSM_APPLE_TP_SSL_CLIENT), name);
    if (name)
        CFRelease(name);
    return policy;
}

WK_POLYFILL_ABSENT("Security", CFDataRef, SecTrustSerialize, (SecTrustRef trust, CFErrorRef *error))
{
    if (error)
        *error = NULL;
    if (!trust) {
        mav_reportOSStatus(error, errSecParam);
        return NULL;
    }

    // The sender's own certificates, read without an evaluation. A blob is written only from state the
    // receiver can put back whole; anything short of that fails here rather than deserializing as a
    // different trust.
    CFArrayRef certificateDatas = mav_certificateDataArray(wk_trustInputCertificates(trust));
    if (!certificateDatas) {
        mav_reportOSStatus(error, errSecParam);
        return NULL;
    }
    CFMutableDictionaryRef state = CFDictionaryCreateMutable(NULL, 7, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(state, kMavTrustCertificates, certificateDatas);
    CFRelease(certificateDatas);

    // A policy travels as its OID and the option block it carries, which is what it is made of.
    // SecPolicyCopyProperties reports only a name and an OID on this OS -- it says nothing about the
    // client/server direction -- and SecPolicyCreateWithProperties writes the name back with its NUL
    // included, so a hostname that went in as "example.org" came back as "example.org\0". Reading the
    // options and rebuilding with SecPolicyCreateSSL keeps both.
    CFArrayRef policies = NULL;
    CFIndex policyCount = SecTrustCopyPolicies(trust, &policies) == errSecSuccess && policies ? CFArrayGetCount(policies) : 0;
    if (!policyCount) {
        if (policies)
            CFRelease(policies);
        CFRelease(state);
        mav_reportOSStatus(error, errSecParam);
        return NULL;
    }
    CFMutableArrayRef described = CFArrayCreateMutable(NULL, policyCount, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; i < policyCount; ++i) {
        CFDictionaryRef one = mav_copyPolicyDescription((SecPolicyRef)CFArrayGetValueAtIndex(policies, i));
        if (!one) {
            CFRelease(described);
            CFRelease(policies);
            CFRelease(state);
            mav_reportOSStatus(error, errSecParam);
            return NULL;
        }
        CFArrayAppendValue(described, one);
        CFRelease(one);
    }
    CFDictionarySetValue(state, kMavTrustPolicies, described);
    CFRelease(described);
    CFRelease(policies);

    CFArrayRef anchors = NULL;
    if (SecTrustCopyCustomAnchorCertificates(trust, &anchors) == errSecSuccess && anchors) {
        CFArrayRef anchorDatas = mav_certificateDataArray(anchors);
        CFRelease(anchors);
        if (!anchorDatas) {
            CFRelease(state);
            mav_reportOSStatus(error, errSecParam);
            return NULL;
        }
        CFDictionarySetValue(state, kMavTrustAnchors, anchorDatas);
        CFRelease(anchorDatas);
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

    CFDataRef data = CFPropertyListCreateData(NULL, state, kCFPropertyListBinaryFormat_v1_0, 0, NULL);
    CFRelease(state);
    if (!data)
        mav_reportOSStatus(error, errSecAllocate);
    return data;
}

WK_POLYFILL_ABSENT("Security", SecTrustRef, SecTrustDeserialize, (CFDataRef serializedTrust, CFErrorRef *error))
{
    if (error)
        *error = NULL;
    if (!serializedTrust) {
        mav_reportOSStatus(error, errSecParam);
        return NULL;
    }
    CFDictionaryRef state = (CFDictionaryRef)CFPropertyListCreateWithData(NULL, serializedTrust, kCFPropertyListImmutable, NULL, NULL);
    if (!state || CFGetTypeID(state) != CFDictionaryGetTypeID()) {
        if (state)
            CFRelease(state);
        mav_reportOSStatus(error, errSecDecode);
        return NULL;
    }

    CFArrayRef certificates = mav_certificateArrayFromData((CFArrayRef)CFDictionaryGetValue(state, kMavTrustCertificates));
    if (!certificates || !CFArrayGetCount(certificates)) {
        if (certificates)
            CFRelease(certificates);
        CFRelease(state);
        mav_reportOSStatus(error, errSecDecode);
        return NULL;
    }

    CFArrayRef policyProperties = (CFArrayRef)CFDictionaryGetValue(state, kMavTrustPolicies);
    CFMutableArrayRef policies = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    if (policyProperties && CFGetTypeID(policyProperties) == CFArrayGetTypeID()) {
        CFIndex policyCount = CFArrayGetCount(policyProperties);
        for (CFIndex i = 0; i < policyCount; ++i) {
            CFDictionaryRef properties = (CFDictionaryRef)CFArrayGetValueAtIndex(policyProperties, i);
            SecPolicyRef policy = (properties && CFGetTypeID(properties) == CFDictionaryGetTypeID())
                ? mav_createPolicyFromDescription(properties) : NULL;
            if (!policy) {
                CFRelease(certificates);
                CFRelease(policies);
                CFRelease(state);
                mav_reportOSStatus(error, errSecDecode);
                return NULL;
            }
            CFArrayAppendValue(policies, policy);
            CFRelease(policy);
        }
    }

    SecTrustRef trust = NULL;
    OSStatus status = CFArrayGetCount(policies) ? SecTrustCreateWithCertificates(certificates, policies, &trust)
                                                : errSecDecode;
    CFRelease(certificates);
    CFRelease(policies);
    if (status != errSecSuccess || !trust) {
        CFRelease(state);
        mav_reportOSStatus(error, status);
        return NULL;
    }

    CFArrayRef anchorDatas = (CFArrayRef)CFDictionaryGetValue(state, kMavTrustAnchors);
    if (anchorDatas) {
        CFArrayRef anchors = mav_certificateArrayFromData(anchorDatas);
        if (!anchors) {
            CFRelease(trust);
            CFRelease(state);
            mav_reportOSStatus(error, errSecDecode);
            return NULL;
        }
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

// SecTrustCopyCertificateChain (Security, 12.0+): the evaluated chain, whole or not at all, via the
// per-index accessors 10.9 ships.
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
        if (!cert) {
            CFRelease(chain);
            return NULL;
        }
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
// The modern SecKey API is a renaming of operations 10.9 already performs through CSSM: SecKeyRawSign,
// SecKeyRawVerify, SecKeyEncrypt, SecKeyDecrypt, SecKeyGeneratePair, SecKeyGetBlockSize, SecItemImport
// and SecItemExport are all exported by this OS (nm-verified), and each modern entry point below is
// expressed in terms of one of them. The vocabulary differs -- modern callers name a SecKeyAlgorithm
// where CSSM takes a SecPadding -- so the translation is a table, and an algorithm with no CSSM
// padding to name it reports absence through *error rather than guessing at one.
//
// Measured on this OS against an imported RSA key and a generated RSA/EC pair: RawSign accepts the
// PKCS1, PKCS1SHA1 and PKCS1SHA256 paddings, RawVerify answers errSecVerifyFailed (-67808) for a
// wrong digest and noErr for a right one, Encrypt/Decrypt round-trip under PKCS1, GeneratePair makes
// both RSA and EC keys, ECDSA signs under kSecPaddingNone, and SecItemExport exports a public key.
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


// 10.9's CSSM key API, all exported by this OS. Reached by name because Security is not linked into
// every image that force-loads this archive.
WK_SYSTEM_FN("Security", OSStatus, SecKeyRawSign, (SecKeyRef, uint32_t, const uint8_t *, size_t, uint8_t *, size_t *));
WK_SYSTEM_FN("Security", OSStatus, SecKeyRawVerify, (SecKeyRef, uint32_t, const uint8_t *, size_t, const uint8_t *, size_t));
WK_SYSTEM_FN("Security", OSStatus, SecKeyEncrypt, (SecKeyRef, uint32_t, const uint8_t *, size_t, uint8_t *, size_t *));
WK_SYSTEM_FN("Security", OSStatus, SecKeyDecrypt, (SecKeyRef, uint32_t, const uint8_t *, size_t, uint8_t *, size_t *));
WK_SYSTEM_FN("Security", OSStatus, SecKeyGeneratePair, (CFDictionaryRef, SecKeyRef *, SecKeyRef *));
WK_SYSTEM_FN("Security", size_t, SecKeyGetBlockSize, (SecKeyRef));
WK_SYSTEM_FN("Security", OSStatus, SecKeyGetCSSMKey, (SecKeyRef, const CSSM_KEY **));
WK_SYSTEM_FN("Security", OSStatus, SecItemExport, (CFTypeRef, SecExternalFormat, SecItemImportExportFlags,
    const SecItemImportExportKeyParameters *, CFDataRef *));
WK_SYSTEM_FN("Security", OSStatus, SecItemImport, (CFDataRef, CFStringRef, SecExternalFormat *,
    SecExternalItemType *, SecItemImportExportFlags, const SecItemImportExportKeyParameters *,
    SecKeychainRef, CFArrayRef *));

// SecPadding values. The 10.9 SDK declares the digest-carrying ones for iOS only, so they are spelled
// numerically here; this OS's implementation accepts them (measured above).
#define MAV_SEC_PADDING_NONE          0u
#define MAV_SEC_PADDING_PKCS1         1u
#define MAV_SEC_PADDING_PKCS1_SHA1    0x8002u
#define MAV_SEC_PADDING_PKCS1_SHA224  0x8003u
#define MAV_SEC_PADDING_PKCS1_SHA256  0x8004u
#define MAV_SEC_PADDING_PKCS1_SHA384  0x8005u
#define MAV_SEC_PADDING_PKCS1_SHA512  0x8006u

// Which digest, if any, the operation applies to its input before signing. A "digest-" algorithm is
// handed a hash the caller computed; a "message-" algorithm is handed the message and hashes it
// first. CSSM's SecKeyRawSign only ever signs a digest, so the message variants supply that step
// themselves, from CommonCrypto.
typedef enum {
    MAV_DIGEST_NONE = 0,
    MAV_DIGEST_SHA1,
    MAV_DIGEST_SHA256,
    MAV_DIGEST_SHA384,
    MAV_DIGEST_SHA512,
} mav_digest;

// A modern SecKeyAlgorithm names the digest as well as the padding; CSSM's SecPadding is the same
// choice under the older spelling. An algorithm with no entry here is one 10.9 cannot express -- OAEP
// is the notable case, since kSecPaddingOAEP is iOS-only -- and its caller is told so.
static bool mav_secPaddingForAlgorithm(CFStringRef algorithm, uint32_t *padding, mav_digest *digest)
{
    // These identifiers are declared above by this same file; taking their address is what the layer
    // exists to do, so the availability warning they necessarily raise is silenced here as elsewhere.
    _Pragma("clang diagnostic push")
    _Pragma("clang diagnostic ignored \"-Wunguarded-availability\"")
    _Pragma("clang diagnostic ignored \"-Wunguarded-availability-new\"")
    static const struct { const CFStringRef *name; uint32_t padding; mav_digest digest; } table[] = {
        { &kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA1,   MAV_SEC_PADDING_PKCS1_SHA1,   MAV_DIGEST_NONE },
        { &kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA256, MAV_SEC_PADDING_PKCS1_SHA256, MAV_DIGEST_NONE },
        { &kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA384, MAV_SEC_PADDING_PKCS1_SHA384, MAV_DIGEST_NONE },
        { &kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA512, MAV_SEC_PADDING_PKCS1_SHA512, MAV_DIGEST_NONE },
        { &kSecKeyAlgorithmECDSASignatureDigestX962,         MAV_SEC_PADDING_NONE,         MAV_DIGEST_NONE },
        { &kSecKeyAlgorithmECDSASignatureMessageX962SHA256,  MAV_SEC_PADDING_NONE,         MAV_DIGEST_SHA256 },
        { &kSecKeyAlgorithmRSAEncryptionPKCS1,               MAV_SEC_PADDING_PKCS1,        MAV_DIGEST_NONE },
        { &kSecKeyAlgorithmRSAEncryptionRaw,                 MAV_SEC_PADDING_NONE,         MAV_DIGEST_NONE },
        { &kSecKeyAlgorithmRSASignatureRaw,                  MAV_SEC_PADDING_NONE,         MAV_DIGEST_NONE },
    };
    _Pragma("clang diagnostic pop")
    if (!algorithm)
        return false;
    for (size_t i = 0; i < sizeof(table) / sizeof(table[0]); ++i) {
        if (CFEqual(algorithm, *table[i].name)) {
            *padding = table[i].padding;
            *digest = table[i].digest;
            return true;
        }
    }
    return false;
}

// The message variants' digest step. CommonCrypto ships on this OS, so a "message-" algorithm is
// digest-then-sign rather than something 10.9 cannot do.
static CFDataRef mav_copyDigest(mav_digest digest, CFDataRef input)
{
    uint8_t buffer[CC_SHA512_DIGEST_LENGTH];
    CC_LONG length = (CC_LONG)CFDataGetLength(input);
    const void *bytes = CFDataGetBytePtr(input);
    CFIndex produced = 0;
    switch (digest) {
    case MAV_DIGEST_SHA1:   CC_SHA1(bytes, length, buffer);   produced = CC_SHA1_DIGEST_LENGTH; break;
    case MAV_DIGEST_SHA256: CC_SHA256(bytes, length, buffer); produced = CC_SHA256_DIGEST_LENGTH; break;
    case MAV_DIGEST_SHA384: CC_SHA384(bytes, length, buffer); produced = CC_SHA384_DIGEST_LENGTH; break;
    case MAV_DIGEST_SHA512: CC_SHA512(bytes, length, buffer); produced = CC_SHA512_DIGEST_LENGTH; break;
    case MAV_DIGEST_NONE:   return NULL;
    }
    // No default label: every enumerator stays cased so a new one trips -Wswitch. A value from outside
    // the set reaches here having hashed nothing, and an empty buffer is not the digest of anything.
    if (!produced)
        return NULL;
    return CFDataCreate(kCFAllocatorDefault, buffer, produced);
}

// Sign, verify, encrypt and decrypt all shape the same way: translate the algorithm, size the output
// from the key's block size, and hand the CSSM entry point the buffer.
static CFDataRef mav_secKeyTransform(SecKeyRef key, CFStringRef algorithm, CFDataRef input,
    OSStatus (*operation)(SecKeyRef, uint32_t, const uint8_t *, size_t, uint8_t *, size_t *), CFErrorRef *error)
{
    uint32_t padding = 0;
    mav_digest digest = MAV_DIGEST_NONE;
    if (!key || !input || !operation || !mav_secPaddingForAlgorithm(algorithm, &padding, &digest)) {
        mav_reportUnimplemented(error);
        return NULL;
    }
    if (!WK_SYSTEM(SecKeyGetBlockSize)) {
        mav_reportUnimplemented(error);
        return NULL;
    }

    // A message algorithm signs the hash of its input; a digest algorithm is handed the hash already.
    CFDataRef digested = NULL;
    if (digest != MAV_DIGEST_NONE) {
        digested = mav_copyDigest(digest, input);
        if (!digested) {
            mav_reportOSStatus(error, errSecInternalError);
            return NULL;
        }
        input = digested;
    }

    // An ECDSA signature is DER and runs past the block size, so the buffer carries the headroom the
    // encoding needs; the call reports how much it used.
    size_t capacity = WK_SYSTEM(SecKeyGetBlockSize)(key) + 32;
    uint8_t *buffer = (uint8_t *)malloc(capacity);
    if (!buffer) {
        if (digested)
            CFRelease(digested);
        mav_reportOSStatus(error, errSecAllocate);
        return NULL;
    }

    size_t produced = capacity;
    OSStatus status = operation(key, padding, CFDataGetBytePtr(input), (size_t)CFDataGetLength(input),
        buffer, &produced);
    if (digested)
        CFRelease(digested);
    if (status != errSecSuccess) {
        free(buffer);
        mav_reportOSStatus(error, status);
        return NULL;
    }

    CFDataRef result = CFDataCreate(kCFAllocatorDefault, buffer, (CFIndex)produced);
    free(buffer);
    if (!result)
        mav_reportOSStatus(error, errSecAllocate);
    return result;
}

// SecKeyCopyExternalRepresentation's contract is the bare representation of a public key: PKCS#1
// RSAPublicKey for RSA, the ANSI X9.63 uncompressed point 04||X||Y for EC. SecItemExport's shape
// follows the key's CSSM blob format rather than its algorithm, so it is not one shape to strip:
// measured on this OS, a certificate-derived RSA key (KeyHeader.Format PKCS1) exports the bare
// PKCS#1 already, while a generated RSA key (format NONE) and every EC key export a
// SubjectPublicKeyInfo -- SEQUENCE { AlgorithmIdentifier, BIT STRING } -- whose BIT STRING carries
// the bare form. These two put that wrapper on and take it off so both directions meet the system's
// contract whichever shape the export chose.
//
// Minimal DER: a definite-length tag whose length is short-form (< 0x80) or long-form (0x8n followed
// by n length bytes). Nothing here parses beyond the two nested headers it has to step over.
static bool mav_derReadHeader(const uint8_t *bytes, size_t length, size_t *offset, uint8_t *tag, size_t *contentLength)
{
    size_t at = *offset;
    // Every bound is a subtraction from the remaining length: a long-form size is attacker-shaped and
    // an addition would wrap past it.
    if (at > length || length - at < 2)
        return false;
    *tag = bytes[at++];
    size_t size = bytes[at++];
    if (size & 0x80) {
        size_t count = size & 0x7f;
        if (!count || count > sizeof(size_t) || count > length - at)
            return false;
        size = 0;
        for (size_t i = 0; i < count; ++i)
            size = (size << 8) | bytes[at++];
    }
    if (size > length - at)
        return false;
    *contentLength = size;
    *offset = at;
    return true;
}

// The BIT STRING contents of a SubjectPublicKeyInfo, minus its unused-bits octet.
static CFDataRef mav_copySubjectPublicKeyBits(CFDataRef spki)
{
    const uint8_t *bytes = CFDataGetBytePtr(spki);
    size_t length = (size_t)CFDataGetLength(spki);
    size_t offset = 0, size = 0;
    uint8_t tag = 0;

    if (!mav_derReadHeader(bytes, length, &offset, &tag, &size) || tag != 0x30)
        return NULL;
    size_t end = offset + size;

    // What the outer SEQUENCE opens with tells the two shapes apart with no overlap.
    if (!mav_derReadHeader(bytes, end, &offset, &tag, &size))
        return NULL;
    // PKCS#1 RSAPublicKey -- SEQUENCE { INTEGER, INTEGER } -- is already the bare representation.
    if (tag == 0x02)
        return CFDataCreateCopy(kCFAllocatorDefault, spki);
    if (tag != 0x30)
        return NULL;
    offset += size; // step over the AlgorithmIdentifier
    if (!mav_derReadHeader(bytes, end, &offset, &tag, &size) || tag != 0x03 || !size)
        return NULL;
    // The first content octet of a BIT STRING counts its unused trailing bits; a key has none.
    return CFDataCreate(kCFAllocatorDefault, bytes + offset + 1, (CFIndex)(size - 1));
}

// DER requires the shortest length encoding that fits: one byte below 128, then 0x81 and a byte, then
// 0x82 and two. A 4096-bit RSA SubjectPublicKeyInfo needs the last of those.
static size_t mav_derHeaderLength(size_t contentLength)
{
    if (contentLength < 0x80)
        return 2;
    return contentLength <= 0xff ? 3 : 4;
}

static bool mav_derAppendHeader(CFMutableDataRef data, uint8_t tag, size_t contentLength)
{
    uint8_t header[4];
    header[0] = tag;
    if (contentLength < 0x80) {
        header[1] = (uint8_t)contentLength;
        CFDataAppendBytes(data, header, 2);
        return true;
    }
    if (contentLength <= 0xff) {
        header[1] = 0x81;
        header[2] = (uint8_t)contentLength;
        CFDataAppendBytes(data, header, 3);
        return true;
    }
    if (contentLength > 0xffff)
        return false; // past the two-byte long form, which is all this writer emits
    header[1] = 0x82;
    header[2] = (uint8_t)(contentLength >> 8);
    header[3] = (uint8_t)contentLength;
    CFDataAppendBytes(data, header, 4);
    return true;
}

static bool mav_isECKeyType(CFStringRef keyType)
{
    if (!keyType || CFGetTypeID(keyType) != CFStringGetTypeID())
        return false;
    // 10.9 names key types by CSSM algorithm id: "42" is RSA, "73" is ECDSA, which is the value
    // kSecAttrKeyTypeECSECPrimeRandom carries here and kSecAttrKeyTypeEC carries on this OS.
    return CFStringCompare(keyType, CFSTR("73"), 0) == kCFCompareEqualTo;
}

// A PKCS#1 RSAPublicKey, wrapped as SubjectPublicKeyInfo with the rsaEncryption AlgorithmIdentifier.
// SecItemImport reads only the wrapped form: measured on this OS, handing it 10.9's own bare PKCS#1
// export answers errSecUnknownFormat, so the bare representation this API's contract names has to be
// put back into the shape the importer reads.
static CFDataRef mav_copyRSASubjectPublicKeyInfo(CFDataRef pkcs1)
{
    // AlgorithmIdentifier ::= SEQUENCE { rsaEncryption, NULL }
    static const uint8_t rsaEncryption[] = { 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01,
                                             0x05, 0x00 };
    size_t keyLength = (size_t)CFDataGetLength(pkcs1);
    if (!keyLength)
        return NULL;

    size_t algorithmContent = sizeof(rsaEncryption);
    // BIT STRING carries one leading octet for its unused-bit count.
    size_t bitStringContent = keyLength + 1;
    size_t sequenceContent = mav_derHeaderLength(algorithmContent) + algorithmContent
        + mav_derHeaderLength(bitStringContent) + bitStringContent;

    CFMutableDataRef spki = CFDataCreateMutable(kCFAllocatorDefault, 0);
    if (!spki)
        return NULL;
    if (!mav_derAppendHeader(spki, 0x30, sequenceContent)
        || !mav_derAppendHeader(spki, 0x30, algorithmContent)) {
        CFRelease(spki);
        return NULL;
    }
    CFDataAppendBytes(spki, rsaEncryption, (CFIndex)sizeof(rsaEncryption));
    if (!mav_derAppendHeader(spki, 0x03, bitStringContent)) {
        CFRelease(spki);
        return NULL;
    }
    const uint8_t unusedBits = 0x00;
    CFDataAppendBytes(spki, &unusedBits, 1);
    CFDataAppendBytes(spki, CFDataGetBytePtr(pkcs1), (CFIndex)keyLength);
    return spki;
}

// The namedCurve OID for an uncompressed X9.63 point, read off the point's own length. Only the three
// prime curves SecItemImport accepts are named; a length matching none of them is not a point this OS
// can import, and says so by returning NULL rather than by guessing a curve.
static const uint8_t *mav_ecNamedCurveOID(size_t pointLength, size_t *oidLength)
{
    static const uint8_t p256[] = { 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07 };
    static const uint8_t p384[] = { 0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x22 };
    static const uint8_t p521[] = { 0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x23 };
    switch (pointLength) {
    case 65:  *oidLength = sizeof(p256); return p256;
    case 97:  *oidLength = sizeof(p384); return p384;
    case 133: *oidLength = sizeof(p521); return p521;
    }
    return NULL;
}

// An X9.63 point, wrapped as SubjectPublicKeyInfo with the id-ecPublicKey AlgorithmIdentifier.
static CFDataRef mav_copyECSubjectPublicKeyInfo(CFDataRef point)
{
    static const uint8_t idECPublicKey[] = { 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01 };

    size_t pointLength = (size_t)CFDataGetLength(point);
    size_t curveLength = 0;
    const uint8_t *curve = mav_ecNamedCurveOID(pointLength, &curveLength);
    if (!curve)
        return NULL;
    if (CFDataGetBytePtr(point)[0] != 0x04)
        return NULL; // not an uncompressed point

    // AlgorithmIdentifier ::= SEQUENCE { id-ecPublicKey, namedCurve }
    size_t algorithmContent = sizeof(idECPublicKey) + curveLength;
    // BIT STRING carries one leading octet for its unused-bit count.
    size_t bitStringContent = pointLength + 1;
    size_t sequenceContent = mav_derHeaderLength(algorithmContent) + algorithmContent
        + mav_derHeaderLength(bitStringContent) + bitStringContent;

    CFMutableDataRef spki = CFDataCreateMutable(kCFAllocatorDefault, 0);
    if (!spki)
        return NULL;
    if (!mav_derAppendHeader(spki, 0x30, sequenceContent)
        || !mav_derAppendHeader(spki, 0x30, algorithmContent)) {
        CFRelease(spki);
        return NULL;
    }
    CFDataAppendBytes(spki, idECPublicKey, (CFIndex)sizeof(idECPublicKey));
    CFDataAppendBytes(spki, curve, (CFIndex)curveLength);
    if (!mav_derAppendHeader(spki, 0x03, bitStringContent)) {
        CFRelease(spki);
        return NULL;
    }
    const uint8_t unusedBits = 0x00;
    CFDataAppendBytes(spki, &unusedBits, 1);
    CFDataAppendBytes(spki, CFDataGetBytePtr(point), (CFIndex)pointLength);
    return spki;
}

// A private EC key's bare representation is the X9.63 concatenation 04||X||Y||K -- the uncompressed
// point followed by the private scalar, all three at the curve's field width, so the total length
// gives that width as (length - 1) / 3. SecItemImport reads a SEC1 ECPrivateKey instead, so the
// concatenation is rewritten into one; the point is handed back separately for the caller to keep as
// the key's public half.
//
//   ECPrivateKey ::= SEQUENCE { version INTEGER (1), privateKey OCTET STRING,
//                               parameters [0] namedCurve OID, publicKey [1] BIT STRING }
static CFDataRef mav_copyECPrivateKey(CFDataRef x963, CFDataRef *publicPoint)
{
    size_t length = (size_t)CFDataGetLength(x963);
    if (length < 4 || (length - 1) % 3)
        return NULL;
    size_t fieldLength = (length - 1) / 3;
    size_t pointLength = length - fieldLength;
    const uint8_t *bytes = CFDataGetBytePtr(x963);
    if (bytes[0] != 0x04)
        return NULL; // not an uncompressed point
    size_t curveLength = 0;
    const uint8_t *curve = mav_ecNamedCurveOID(pointLength, &curveLength);
    if (!curve)
        return NULL;

    // BIT STRING carries one leading octet for its unused-bit count.
    size_t bitStringContent = pointLength + 1;
    size_t publicKeyContent = mav_derHeaderLength(bitStringContent) + bitStringContent;
    size_t versionLength = 3;
    size_t sequenceContent = versionLength
        + mav_derHeaderLength(fieldLength) + fieldLength
        + mav_derHeaderLength(curveLength) + curveLength
        + mav_derHeaderLength(publicKeyContent) + publicKeyContent;

    CFMutableDataRef der = CFDataCreateMutable(kCFAllocatorDefault, 0);
    if (!der)
        return NULL;
    const uint8_t version[] = { 0x02, 0x01, 0x01 }; // INTEGER ecPrivkeyVer1
    if (!mav_derAppendHeader(der, 0x30, sequenceContent)) {
        CFRelease(der);
        return NULL;
    }
    CFDataAppendBytes(der, version, (CFIndex)sizeof(version));
    if (!mav_derAppendHeader(der, 0x04, fieldLength)) {
        CFRelease(der);
        return NULL;
    }
    CFDataAppendBytes(der, bytes + pointLength, (CFIndex)fieldLength);
    if (!mav_derAppendHeader(der, 0xa0, curveLength)) {
        CFRelease(der);
        return NULL;
    }
    CFDataAppendBytes(der, curve, (CFIndex)curveLength);
    if (!mav_derAppendHeader(der, 0xa1, publicKeyContent)
        || !mav_derAppendHeader(der, 0x03, bitStringContent)) {
        CFRelease(der);
        return NULL;
    }
    const uint8_t unusedBits = 0x00;
    CFDataAppendBytes(der, &unusedBits, 1);
    CFDataAppendBytes(der, bytes, (CFIndex)pointLength);

    if (publicPoint)
        *publicPoint = CFDataCreate(kCFAllocatorDefault, bytes, (CFIndex)pointLength);
    return der;
}

// The public half of an EC key the caller supplied a point for, imported so SecKeyCopyPublicKey can
// hand it back.
static SecKeyRef mav_createECPublicKey(CFDataRef point)
{
    CFDataRef spki = mav_copyECSubjectPublicKeyInfo(point);
    if (!spki || !WK_SYSTEM(SecItemImport)) {
        if (spki)
            CFRelease(spki);
        return NULL;
    }
    SecExternalFormat format = kSecFormatOpenSSL;
    SecExternalItemType itemType = kSecItemTypePublicKey;
    SecItemImportExportKeyParameters params;
    memset(&params, 0, sizeof(params));
    params.version = SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION;
    CFArrayRef items = NULL;
    OSStatus status = WK_SYSTEM(SecItemImport)(spki, NULL, &format, &itemType, 0, &params, NULL, &items);
    CFRelease(spki);
    SecKeyRef key = NULL;
    if (status == errSecSuccess && items && CFArrayGetCount(items)) {
        CFTypeRef item = CFArrayGetValueAtIndex(items, 0);
        if (item && CFGetTypeID(item) == SecKeyGetTypeID())
            key = (SecKeyRef)CFRetain(item);
    }
    if (items)
        CFRelease(items);
    return key;
}

// A private key carries its public half as an association, which SecKeyCopyPublicKey reads back. The
// association is torn down with the private key, so there is no registry to outlive it.
static const void *mav_publicKeyAssociationKey(void)
{
    // The SEL is the one address every image's copy of this archive agrees on.
    static const void *key;
    if (!key)
        key = (const void *)sel_registerName("wk_secKeyPublicHalf");
    return key;
}

static void mav_setPublicKeyHalf(SecKeyRef privateKey, SecKeyRef publicKey)
{
    objc_setAssociatedObject((id)(void *)privateKey, mav_publicKeyAssociationKey(),
        (id)publicKey, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

WK_POLYFILL_ABSENT("Security", CFDataRef, SecKeyCopyExternalRepresentation, (SecKeyRef key, CFErrorRef *error))
{
    if (!key || !WK_SYSTEM(SecItemExport)) {
        mav_reportUnimplemented(error);
        return NULL;
    }
    CFDataRef exported = NULL;
    OSStatus status = WK_SYSTEM(SecItemExport)(key, kSecFormatOpenSSL, 0, NULL, &exported);
    if (status != errSecSuccess) {
        // A keychain-less private key cannot be exported without a passphrase, which this API has no
        // way to carry; that is the status the caller is told.
        if (exported)
            CFRelease(exported);
        mav_reportOSStatus(error, status);
        return NULL;
    }

    CFDataRef bare = mav_copySubjectPublicKeyBits(exported);
    CFRelease(exported);
    if (!bare)
        mav_reportOSStatus(error, errSecDecode);
    return bare;
}

WK_POLYFILL_ABSENT("Security", SecKeyRef, SecKeyCreateWithData, (CFDataRef keyData, CFDictionaryRef attributes, CFErrorRef *error))
{
    if (!keyData || !attributes || !WK_SYSTEM(SecItemImport)) {
        mav_reportUnimplemented(error);
        return NULL;
    }

    CFStringRef keyClass = (CFStringRef)CFDictionaryGetValue(attributes, kSecAttrKeyClass);
    SecExternalItemType itemType = kSecItemTypePublicKey;
    if (keyClass && CFGetTypeID(keyClass) == CFStringGetTypeID()
        && CFStringCompare(keyClass, kSecAttrKeyClassPrivate, 0) == kCFCompareEqualTo)
        itemType = kSecItemTypePrivateKey;

    // This API takes the bare representation: PKCS#1 for RSA, the ANSI X9.63 uncompressed point for an
    // EC public key and that point concatenated with the private scalar for an EC private one.
    // SecItemImport reads a SubjectPublicKeyInfo for the first of those and a SEC1 ECPrivateKey for the
    // second, so both are wrapped back into the shape it reads -- the inverse of what
    // SecKeyCopyExternalRepresentation strips off. A PKCS#1 RSAPrivateKey is already that shape.
    CFStringRef keyType = (CFStringRef)CFDictionaryGetValue(attributes, kSecAttrKeyType);
    CFDataRef wrapped = NULL;
    CFDataRef publicPoint = NULL;
    if (mav_isECKeyType(keyType))
        wrapped = itemType == kSecItemTypePrivateKey ? mav_copyECPrivateKey(keyData, &publicPoint)
                                                     : mav_copyECSubjectPublicKeyInfo(keyData);
    else if (itemType == kSecItemTypePublicKey)
        wrapped = mav_copyRSASubjectPublicKeyInfo(keyData);

    SecExternalFormat format = kSecFormatOpenSSL;
    SecItemImportExportKeyParameters params;
    memset(&params, 0, sizeof(params));
    params.version = SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION;

    CFArrayRef items = NULL;
    OSStatus status = WK_SYSTEM(SecItemImport)(wrapped ? wrapped : keyData, NULL, &format, &itemType,
        0, &params, NULL, &items);
    if (wrapped)
        CFRelease(wrapped);
    if (status != errSecSuccess || !items || !CFArrayGetCount(items)) {
        if (items)
            CFRelease(items);
        if (publicPoint)
            CFRelease(publicPoint);
        mav_reportOSStatus(error, status == errSecSuccess ? errSecDecode : status);
        return NULL;
    }

    CFTypeRef item = CFArrayGetValueAtIndex(items, 0);
    SecKeyRef key = (item && CFGetTypeID(item) == SecKeyGetTypeID()) ? (SecKeyRef)CFRetain(item) : NULL;
    CFRelease(items);
    if (key && publicPoint) {
        SecKeyRef publicKey = mav_createECPublicKey(publicPoint);
        if (publicKey) {
            mav_setPublicKeyHalf(key, publicKey);
            CFRelease(publicKey);
        }
    }
    if (publicPoint)
        CFRelease(publicPoint);
    if (!key)
        mav_reportOSStatus(error, errSecDecode);
    return key;
}

WK_POLYFILL_ABSENT("Security", SecKeyRef, SecKeyCreateRandomKey, (CFDictionaryRef parameters, CFErrorRef *error))
{
    if (!parameters || !WK_SYSTEM(SecKeyGeneratePair)) {
        mav_reportUnimplemented(error);
        return NULL;
    }
    SecKeyRef publicKey = NULL;
    SecKeyRef privateKey = NULL;
    OSStatus status = WK_SYSTEM(SecKeyGeneratePair)(parameters, &publicKey, &privateKey);
    if (status != errSecSuccess || !privateKey) {
        if (publicKey)
            CFRelease(publicKey);
        if (privateKey)
            CFRelease(privateKey);
        mav_reportOSStatus(error, status == errSecSuccess ? errSecInternalError : status);
        return NULL;
    }
    // SecKeyCopyPublicKey is the caller's next call; the pair's public half is what it wants.
    if (publicKey) {
        mav_setPublicKeyHalf(privateKey, publicKey);
        CFRelease(publicKey);
    }
    return privateKey; // +1, as the modern constructor returns
}

WK_POLYFILL_ABSENT("Security", CFDataRef, SecKeyCreateSignature, (SecKeyRef key, SecKeyAlgorithm algorithm, CFDataRef dataToSign, CFErrorRef *error))
{
    return mav_secKeyTransform(key, algorithm, dataToSign, WK_SYSTEM(SecKeyRawSign), error);
}

WK_POLYFILL_ABSENT("Security", Boolean, SecKeyVerifySignature, (SecKeyRef key, SecKeyAlgorithm algorithm, CFDataRef signedData, CFDataRef signature, CFErrorRef *error))
{
    uint32_t padding = 0;
    mav_digest digest = MAV_DIGEST_NONE;
    if (!key || !signedData || !signature || !WK_SYSTEM(SecKeyRawVerify)
        || !mav_secPaddingForAlgorithm(algorithm, &padding, &digest)) {
        mav_reportUnimplemented(error);
        return false;
    }
    CFDataRef digested = NULL;
    if (digest != MAV_DIGEST_NONE) {
        digested = mav_copyDigest(digest, signedData);
        if (!digested) {
            mav_reportOSStatus(error, errSecInternalError);
            return false;
        }
        signedData = digested;
    }
    OSStatus status = WK_SYSTEM(SecKeyRawVerify)(key, padding,
        CFDataGetBytePtr(signedData), (size_t)CFDataGetLength(signedData),
        CFDataGetBytePtr(signature), (size_t)CFDataGetLength(signature));
    if (digested)
        CFRelease(digested);
    if (status == errSecSuccess)
        return true;
    // errSecVerifyFailed (-67808) is what this OS answers for a signature that simply does not verify
    // -- measured across every padding in the table above -- and that is a false, not an error.
    // Anything else is a failure to perform the check at all, and the caller is told.
    if (status != errSecVerifyFailed)
        mav_reportOSStatus(error, status);
    return false;
}

WK_POLYFILL_ABSENT("Security", CFDataRef, SecKeyCreateEncryptedData, (SecKeyRef key, SecKeyAlgorithm algorithm, CFDataRef plaintext, CFErrorRef *error))
{
    return mav_secKeyTransform(key, algorithm, plaintext, WK_SYSTEM(SecKeyEncrypt), error);
}

WK_POLYFILL_ABSENT("Security", CFDataRef, SecKeyCreateDecryptedData, (SecKeyRef key, SecKeyAlgorithm algorithm, CFDataRef ciphertext, CFErrorRef *error))
{
    return mav_secKeyTransform(key, algorithm, ciphertext, WK_SYSTEM(SecKeyDecrypt), error);
}

// The public half a key was created with: the other half of a generated pair, or the point an imported
// EC private key carried. 10.9 stores a SecKey as CSSM_KEYBLOB_REFERENCE and exports no accessor
// between the halves of a pair, so a key that arrived with neither has none to hand back.
WK_POLYFILL_ABSENT("Security", SecKeyRef, SecKeyCopyPublicKey, (SecKeyRef key))
{
    if (!key)
        return NULL;
    SecKeyRef publicKey = (SecKeyRef)objc_getAssociatedObject((id)(void *)key, mav_publicKeyAssociationKey());
    if (!publicKey || CFGetTypeID(publicKey) != SecKeyGetTypeID())
        return NULL;
    return (SecKeyRef)CFRetain(publicKey);
}

// 10.9 keeps a key's real shape in its CSSM header, which SecKeyGetCSSMKey vends: the logical size in
// bits (not the block size -- those differ for EC), the CSSM algorithm id, and the public/private
// class. The modern dictionary spells the same three.
WK_POLYFILL_ABSENT("Security", CFDictionaryRef, SecKeyCopyAttributes, (SecKeyRef key))
{
    const CSSM_KEY *cssmKey = NULL;
    if (!key || !WK_SYSTEM(SecKeyGetCSSMKey)
        || WK_SYSTEM(SecKeyGetCSSMKey)(key, &cssmKey) != errSecSuccess || !cssmKey)
        return NULL;

    CFMutableDictionaryRef attributes = CFDictionaryCreateMutable(kCFAllocatorDefault, 3,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!attributes)
        return NULL;

    long bits = (long)cssmKey->KeyHeader.LogicalKeySizeInBits;
    CFNumberRef size = CFNumberCreate(kCFAllocatorDefault, kCFNumberLongType, &bits);
    if (size) {
        CFDictionarySetValue(attributes, kSecAttrKeySizeInBits, size);
        CFRelease(size);
    }

    // The key-type values are the CSSM algorithm ids these constants carry on this OS.
    if (cssmKey->KeyHeader.AlgorithmId == CSSM_ALGID_RSA)
        CFDictionarySetValue(attributes, kSecAttrKeyType, kSecAttrKeyTypeRSA);
    else if (cssmKey->KeyHeader.AlgorithmId == CSSM_ALGID_ECDSA)
        CFDictionarySetValue(attributes, kSecAttrKeyType, kSecAttrKeyTypeECSECPrimeRandom);

    if (cssmKey->KeyHeader.KeyClass == CSSM_KEYCLASS_PRIVATE_KEY)
        CFDictionarySetValue(attributes, kSecAttrKeyClass, kSecAttrKeyClassPrivate);
    else if (cssmKey->KeyHeader.KeyClass == CSSM_KEYCLASS_PUBLIC_KEY)
        CFDictionarySetValue(attributes, kSecAttrKeyClass, kSecAttrKeyClassPublic);

    return attributes;
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
