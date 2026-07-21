// The framework entry points modern WebKit calls that 10.9 does not export and that are not graphics:
// Security, CFNetwork, CoreFoundation, CoreServices/LaunchServices, ApplicationServices (AX), AppKit,
// Foundation, DataDetectorsCore and sqlite3 -- plus the CommonCrypto, sandbox and os_state SPI.
//
// Each function below is either (a) runtime-gated by WebKit so it is never actually executed on 10.9,
// (b) a feature genuinely absent on 10.9 whose callers tolerate a null/zero result, or (c) implemented
// for real against the 10.9-available underlying API. The classification is noted per function.
#include "wk_polyfill.h"

#import <Foundation/Foundation.h>
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <CommonCrypto/CommonCrypto.h>
#include <sqlite3.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// ---------------------------------------------------------------------------------------------------
// AppKit / AX — runtime-gated; never executed on 10.9.
// ---------------------------------------------------------------------------------------------------

// drawFocusRing()/ControlMac take a < 10.10 path that draws a plain stroked ring; this is compiled in
// for the >= 10.10 branch only. Definition exists solely to satisfy the bind. (NSFocusRingPlacement,
// CGFocusRingStyle elided to void*/int — never called here.)
WK_POLYFILL_ABSENT("AppKit", int, NSInitializeCGFocusRingStyleForTime, (int placement, void *style, double time), (placement, style, time))
{
    (void)placement; (void)style; (void)time;
    return 0;
}

// Notifies AX of a process suspend/resume. No AX process-suspend tracking on 10.9; return success.
WK_POLYFILL_ABSENT("ApplicationServices", int, _AXUIElementNotifyProcessSuspendStatus, (int status), (status))
{
    (void)status;
    return 0; // kAXErrorSuccess
}

// AccessibilitySupport: "Increase Contrast > Enhance text legibility" accessibility setting (absent on
// 10.9 — the framework that vends it postdates this OS). FontCache::platformInvalidate reads it during
// WebProcess init (a flat-namespace bind, so it must resolve). The setting is off by default.
WK_POLYFILL_ABSENT("ApplicationServices", unsigned char, _AXSEnhanceTextLegibilityEnabled, (void), ())
{
    return 0;
}

// HIServices SPI that tags the calling process with an AX "client type" (e.g. WebKitTesting) so the AX
// runtime can special-case test harnesses. Absent on 10.9 (postdates this OS). The layout-test drivers
// (DumpRenderTree/WebKitTestRunner) call it during accessibility-controller setup; on 10.9 there is no AX
// client-type registry, so a no-op is the correct behavior (the AX tests that depend on it are skipped).
WK_POLYFILL_ABSENT("ApplicationServices", void, _AXSetClientIdentificationOverride, (int clientType), (clientType))
{
    (void)clientType;
}

// LaunchServices UTType predicates added after 10.9 (10.9's LaunchServices has the rest of the UTType
// API — UTTypeConformsTo/UTTypeCopyPreferredTagWithClass/UTTypeCopyDeclaration/etc. — but not these
// two). Both questions ARE answerable on 10.9, so ask LaunchServices rather than guessing:
//
//   declared — UTTypeCopyDeclaration returns the declaring bundle's UTI declaration, and nil for a UTI
//     no installed bundle declares. That is what "declared" means, and it is not a heuristic: on this
//     host public.png/public.jpeg/com.adobe.pdf are declared while public.webp, public.heic and
//     public.avif are NOT, which no name-shaped rule predicts.
//   dynamic — a dynamic UTI is by construction one LaunchServices synthesised under the "dyn." prefix
//     (UTTypeCreatePreferredIdentifierForTag mints them), so the prefix IS the test.
//
// -[UTType isDeclared]/-[UTType isDynamic] in classes.m answer the same two questions and must stay
// the same two answers; they are implemented the same way there.
WK_SYSTEM_FN("CoreServices", CFDictionaryRef, UTTypeCopyDeclaration, (CFStringRef));

WK_POLYFILL_ABSENT("CoreServices", Boolean, UTTypeIsDynamic, (CFStringRef inUTI), (inUTI))
{
    return inUTI && CFStringHasPrefix(inUTI, CFSTR("dyn."));
}

WK_POLYFILL_ABSENT("CoreServices", Boolean, UTTypeIsDeclared, (CFStringRef inUTI), (inUTI))
{
    if (!inUTI || !WK_SYSTEM(UTTypeCopyDeclaration))
        return false;
    CFDictionaryRef declaration = WK_SYSTEM(UTTypeCopyDeclaration)(inUTI);
    if (!declaration)
        return false;
    CFRelease(declaration);
    return true;
}

// ---------------------------------------------------------------------------------------------------
// CFNetwork — features absent on 10.9; callers tolerate null/no-op.
// ---------------------------------------------------------------------------------------------------

// Cross-process handoff of an identified cookie store. 10.9 has no identifying-data API; returning
// null makes CookieStorageUtilsCF fall back to the default shared storage (its own comment notes this).
WK_POLYFILL_ABSENT("CFNetwork", void *, CFHTTPCookieStorageCreateIdentifyingData, (CFAllocatorRef allocator, void *storage), (allocator, storage))
{
    (void)allocator; (void)storage;
    return NULL;
}

WK_POLYFILL_ABSENT("CFNetwork", void *, CFHTTPCookieStorageCreateFromIdentifyingData, (CFAllocatorRef allocator, CFDataRef data), (allocator, data))
{
    (void)allocator; (void)data;
    return NULL;
}

// App Transport Security context (10.11+). No ATS on 10.9: nothing to copy, nothing to set.
WK_POLYFILL_ABSENT("CFNetwork", CFDataRef, _CFNetworkCopyATSContext, (void), ())
{
    return NULL;
}

WK_POLYFILL_ABSENT("CFNetwork", Boolean, _CFNetworkSetATSContext, (CFDataRef context), (context))
{
    (void)context;
    return false;
}

// Per-storage-session cache disable (newer API). The caller guards the call; on 10.9 it is a no-op
// (cache policy is handled through the storage session that is created without an on-disk cache).
WK_POLYFILL_ABSENT("CFNetwork", void, _CFURLStorageSessionDisableCache, (void *storageSession), (storageSession))
{
    (void)storageSession;
}

// ---------------------------------------------------------------------------------------------------
// Network.framework known-tracker lookup — Network.framework is empty on 10.9, so these two entry
// points are absent. ResourceError::blockedTrackerHostName() reads them only when an NSError carries
// an _NSURLErrorNWPathKey, a key the 10.9 loaders never attach; the caller tolerates a null result
// (an empty tracker host name). The nw_path_t / nw_endpoint_t handles are opaque pointers.
// ---------------------------------------------------------------------------------------------------

// Copies the effective remote endpoint from a network path. No such path object is ever produced on
// 10.9, so this returns null.
WK_POLYFILL_ABSENT("Network", const void *, nw_path_copy_effective_remote_endpoint, (const void *path), (path))
{
    (void)path;
    return NULL;
}

// Returns the known-tracker host name an endpoint resolved to, or null when it is not a known tracker.
// On 10.9 there is no tracker-classification engine, so this returns null.
WK_POLYFILL_ABSENT("Network", const char *, nw_endpoint_get_known_tracker_name, (const void *endpoint), (endpoint))
{
    (void)endpoint;
    return NULL;
}

// ---------------------------------------------------------------------------------------------------
// CoreFoundation prefs daemon tuning — optimizations for sandboxed XPC services; no-ops on 10.9.
// ---------------------------------------------------------------------------------------------------

WK_POLYFILL_ABSENT("CoreFoundation", void, _CFPrefsSetDirectModeEnabled, (int enabled), (enabled))
{
    (void)enabled;
}

WK_POLYFILL_ABSENT("CoreFoundation", void, _CFPrefsSetReadOnly, (Boolean flag), (flag))
{
    (void)flag;
}

// ---------------------------------------------------------------------------------------------------
// CoreServices / LaunchServices — called before LS check-in in auxiliary processes; no-op on 10.9.
// ---------------------------------------------------------------------------------------------------

WK_POLYFILL_ABSENT("CoreServices", void, _CSCheckFixDisable, (void), ())
{
}

// ---------------------------------------------------------------------------------------------------
// DataDetectorsCore — 10.9 has the DDResult CF type, just no accessor for its type id.
// ---------------------------------------------------------------------------------------------------

// WTF::CFTypeTrait<DDResultRef>::typeID() (WebCore/editing/cocoa/DataDetection.mm) is this function, so
// it is what every checked_cf_cast<DDResultRef> on a scanner result compares against. 10.9's
// DataDetectorsCore exports DDResultCreateEmpty, so the real id is obtainable: mint one result and read
// its CFGetTypeID. Measured on this host that is 256, CFCopyTypeIDDescription "DDResult", and stable
// across calls. Reporting a sentinel instead made every cast fail and the whole feature look empty.
WK_SYSTEM_FN("/System/Library/PrivateFrameworks/DataDetectorsCore.framework/DataDetectorsCore",
             CFTypeRef, DDResultCreateEmpty, (void));

WK_POLYFILL_ABSENT("/System/Library/PrivateFrameworks/DataDetectorsCore.framework/DataDetectorsCore", CFTypeID, DDResultGetCFTypeID, (void), ())
{
    static CFTypeID typeID;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!WK_SYSTEM(DDResultCreateEmpty))
            return;
        CFTypeRef empty = WK_SYSTEM(DDResultCreateEmpty)();
        if (!empty)
            return;
        typeID = CFGetTypeID(empty);
        CFRelease(empty);
    });
    return typeID;
}

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
WK_POLYFILL_ABSENT("Security", CFTypeID, SecAccessControlGetTypeID, (void), ())
{
    return 0;
}

WK_POLYFILL_ABSENT("Security", CFDataRef, SecAccessControlCopyData, (void *accessControl), (accessControl))
{
    (void)accessControl;
    return NULL;
}

WK_POLYFILL_ABSENT("Security", void *, SecAccessControlCreateFromData, (CFAllocatorRef allocator, CFDataRef data, CFErrorRef *error), (allocator, data, error))
{
    (void)allocator; (void)data;
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

WK_POLYFILL_ABSENT("Security", int, SecCertificateGetSignatureHashAlgorithm, (SecCertificateRef certificate), (certificate))
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

// Process signing identifier. Absent on 10.9; callers use it for telemetry/diagnostics and accept null.
WK_POLYFILL_ABSENT("Security", CFStringRef, SecTaskCopySigningIdentifier, (SecTaskRef task, CFErrorRef *error), (task, error))
{
    (void)task;
    mav_reportUnimplemented(error);
    return NULL;
}

// Code-sign status flags. WebKit tests `& CS_PLATFORM_BINARY`; our frameworks are not platform
// binaries on 10.9, so report no flags (matches the behavior the prior build relied on).
// The 26.1 SDK declares this one __API_UNAVAILABLE(macos), which makes even taking its address an
// error; re-declare it as available so the registry entry below can point at it.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wavailability"
__attribute__((availability(macos, introduced=10.0))) uint32_t SecTaskGetCodeSignStatus(SecTaskRef task);
#pragma clang diagnostic pop
WK_POLYFILL_ABSENT("Security", uint32_t, SecTaskGetCodeSignStatus, (SecTaskRef task), (task))
{
    (void)task;
    return 0;
}

// SecTrust IPC serialization. Both halves are absent on 10.9 and both resolve here, so they only need
// to round-trip with each other: carry the certificate chain (a binary plist of DER datas); the
// receiver rebuilds a SecTrust and re-evaluates with a basic X.509 policy. (Custom anchors/policies
// degrade to the default, but the chain — the part used for display and validation — survives.)
WK_POLYFILL_ABSENT("Security", CFDataRef, SecTrustSerialize, (SecTrustRef trust, CFErrorRef *error), (trust, error))
{
    if (error)
        *error = NULL;
    if (!trust) {
        mav_reportUnimplemented(error);
        return NULL;
    }
    CFIndex count = SecTrustGetCertificateCount(trust);
    CFMutableArrayRef certificates = CFArrayCreateMutable(NULL, count, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; i < count; ++i) {
        SecCertificateRef certificate = SecTrustGetCertificateAtIndex(trust, i);
        CFDataRef der = certificate ? SecCertificateCopyData(certificate) : NULL;
        if (der) {
            CFArrayAppendValue(certificates, der);
            CFRelease(der);
        }
    }
    CFDataRef data = CFPropertyListCreateData(NULL, certificates, kCFPropertyListBinaryFormat_v1_0, 0, NULL);
    CFRelease(certificates);
    if (!data)
        mav_reportUnimplemented(error);
    return data;
}

WK_POLYFILL_ABSENT("Security", SecTrustRef, SecTrustDeserialize, (CFDataRef serializedTrust, CFErrorRef *error), (serializedTrust, error))
{
    if (error)
        *error = NULL;
    if (!serializedTrust) {
        mav_reportUnimplemented(error);
        return NULL;
    }
    CFArrayRef certificateDatas = (CFArrayRef)CFPropertyListCreateWithData(NULL, serializedTrust, kCFPropertyListImmutable, NULL, NULL);
    if (!certificateDatas || CFGetTypeID(certificateDatas) != CFArrayGetTypeID()) {
        if (certificateDatas)
            CFRelease(certificateDatas);
        mav_reportUnimplemented(error);
        return NULL;
    }
    CFIndex count = CFArrayGetCount(certificateDatas);
    CFMutableArrayRef certificates = CFArrayCreateMutable(NULL, count, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; i < count; ++i) {
        CFDataRef der = (CFDataRef)CFArrayGetValueAtIndex(certificateDatas, i);
        SecCertificateRef certificate = SecCertificateCreateWithData(NULL, der);
        if (certificate) {
            CFArrayAppendValue(certificates, certificate);
            CFRelease(certificate);
        }
    }
    CFRelease(certificateDatas);
    SecTrustRef trust = NULL;
    SecPolicyRef policy = SecPolicyCreateBasicX509();
    SecTrustCreateWithCertificates(certificates, policy, &trust);
    CFRelease(policy);
    CFRelease(certificates);
    return trust;
}

// Attribution of a cross-process trust evaluation to the client. Single-system on 10.9: accept it.
WK_POLYFILL_ABSENT("Security", int, SecTrustSetClientAuditToken, (SecTrustRef trust, CFDataRef auditToken), (trust, auditToken))
{
    (void)trust; (void)auditToken;
    return 0; // errSecSuccess
}

// SecTrustCopyCertificateChain (Security, 12.0+): rebuild the evaluated chain via the per-index
// accessors 10.9 ships.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
WK_POLYFILL_ABSENT("Security", CFArrayRef, SecTrustCopyCertificateChain, (SecTrustRef trust), (trust))
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
// Foundation
// ---------------------------------------------------------------------------------------------------

// --- NSEdgeInsetsEqual (10.10+) ------------------------------------------
// WebKit has an undefined ref, so the SDK exposes it as an extern function
// (not static inline) — define the real symbol with the SDK signature.
WK_POLYFILL_ABSENT("Foundation", BOOL, NSEdgeInsetsEqual, (NSEdgeInsets a, NSEdgeInsets b), (a, b))
{
    return a.top == b.top && a.left == b.left
        && a.bottom == b.bottom && a.right == b.right;
}

// ---------------------------------------------------------------------------------------------------
// sqlite3 -- 10.9 ships SQLite 3.7, so the entry points added in later versions are absent.
// ---------------------------------------------------------------------------------------------------

// sqlite3_errstr (SQLite 3.7.15) — 10.9 ships an older SQLite. Map the primary result codes to the same
// strings SQLite uses, so WebCore's diagnostic logging stays meaningful. Used only for error messages.
WK_POLYFILL_ABSENT("/usr/lib/libsqlite3.dylib", const char *, sqlite3_errstr, (int rc), (rc)) {
    switch (rc & 0xff) {
        case 0:  return "not an error";
        case 1:  return "SQL logic error";
        case 2:  return "internal error";
        case 3:  return "access permission denied";
        case 4:  return "query aborted";
        case 5:  return "database is locked";
        case 6:  return "database table is locked";
        case 7:  return "out of memory";
        case 8:  return "attempt to write a readonly database";
        case 9:  return "interrupted";
        case 10: return "disk I/O error";
        case 11: return "database disk image is malformed";
        case 12: return "unknown operation";
        case 13: return "database or disk is full";
        case 14: return "unable to open database file";
        case 15: return "locking protocol";
        case 17: return "database schema has changed";
        case 18: return "string or blob too big";
        case 19: return "constraint failed";
        case 20: return "datatype mismatch";
        case 21: return "library routine called out of sequence";
        case 23: return "authorization denied";
        case 25: return "column index out of range";
        case 26: return "file is not a database";
        case 100: return "another row available";
        case 101: return "no more rows available";
        default: return "unknown error";
    }
}

// sqlite3_bind_blob64 (SQLite 3.8.7 / 10.10+): 10.9 ships SQLite 3.7; forward to sqlite3_bind_blob
// (WebKit blob lengths are always well under INT_MAX).
WK_SYSTEM_FN("/usr/lib/libsqlite3.dylib", int, sqlite3_bind_blob,
    (sqlite3_stmt *, int, const void *, int, void (*)(void *)));
WK_POLYFILL_ABSENT("/usr/lib/libsqlite3.dylib", int, sqlite3_bind_blob64,
    (sqlite3_stmt *statement, int index, const void *data, sqlite3_uint64 length, void (*destructor)(void *)),
    (statement, index, data, length, destructor))
{
    if (!WK_SYSTEM(sqlite3_bind_blob))
        return SQLITE_ERROR;
    return WK_SYSTEM(sqlite3_bind_blob)(statement, index, data, (int)length, destructor);
}

// ---------------------------------------------------------------------------------------------------
// libSystem — diagnostics + audit-token sandbox checks absent on 10.9.
// ---------------------------------------------------------------------------------------------------

typedef struct { unsigned int val[8]; } mav_audit_token_t;

// State-dump (sysdiagnose) handler registration. None on 10.9; return a null handle.
WK_POLYFILL_ABSENT(NULL, unsigned long, os_state_add_handler, (void *queue, void *handler), (queue, handler))
{
    (void)queue; (void)handler;
    return 0;
}

// Audit-token sandbox checks (newer than the pid-based sandbox_check on 10.9). WebKit child processes
// run without the fine-grained profile on this backport, so report "permitted/not-restricted" (0),
// matching the pid-based path's behavior for an unsandboxed process.
WK_POLYFILL_ABSENT(NULL, int, sandbox_check_by_audit_token, (mav_audit_token_t token, const char *operation, int type, ...), (token, operation, type))
{
    (void)token; (void)operation; (void)type;
    return 0;
}

WK_POLYFILL_ABSENT(NULL, bool, sandbox_enable_state_flag, (const char *name, mav_audit_token_t token), (name, token))
{
    (void)name; (void)token;
    return false;
}

// ---------------------------------------------------------------------------------------------------
// CommonCrypto — KDF + one-shot AES-GCM SPI absent on 10.9.
//
// The CCKDFParameters/CCDeriveKey key-derivation API and the one-shot CCCryptorGCMOneshotDecrypt are
// 10.10+ and have no symbol in 10.9's libcommonCrypto (verified: absent; CCHmac and the deprecated
// one-shot CCCryptorGCM ARE present). WebCore reaches them through PAL's CommonCryptoSPI.h — WebCrypto
// HKDF (deriveBits/deriveKey) via CCKDFParametersCreateHkdf + CCDeriveKey, and the Push API's aes128gcm
// payload decryption via CCCryptorGCMOneshotDecrypt. Reimplement each over the 10.9-present primitives
// so the upstream call sites revert to pristine. CCStatus/CCDigestAlgorithm/CCKDFParametersRef are SPI
// (not in the public SDK headers); use their underlying ABI types (int32_t / uint32_t /
// struct CCKDFParameters *) here to avoid redeclaring them. The CCDigestAlgorithm values are the
// CommonDigestSPI enum: kCCDigestSHA1=8, DeprecatedCCDigestSHA224=9, kCCDigestSHA256=10, SHA384=11,
// SHA512=12.
// ---------------------------------------------------------------------------------------------------

// CCCryptorGCM (the deprecated but 10.9-present one-shot GCM) is SPI; forward-declare it.
extern CCCryptorStatus CCCryptorGCM(CCOperation op, CCAlgorithm alg, const void *key, size_t keyLength, const void *iv, size_t ivLen, const void *aData, size_t aDataLen, const void *dataIn, size_t dataInLength, void *dataOut, void *tag, size_t *tagLength);

// One-shot AES-GCM decrypt-and-verify. CCCryptorGCM decrypts and computes the authentication tag over
// the data; compare it to the caller's expected tag in constant time and report kCCDecodeError on
// mismatch (the authenticated-decrypt contract: a forged/wrong tag fails rather than returning
// plaintext — the caller treats any non-success as decryption failure).
WK_POLYFILL_ABSENT(NULL, CCCryptorStatus, CCCryptorGCMOneshotDecrypt,
    (CCAlgorithm alg, const void *key, size_t keyLength, const void *iv, size_t ivLen, const void *aData, size_t aDataLen, const void *dataIn, size_t dataInLength, void *dataOut, const void *tagIn, size_t tagLength),
    (alg, key, keyLength, iv, ivLen, aData, aDataLen, dataIn, dataInLength, dataOut, tagIn, tagLength))
{
    unsigned char computedTag[16];
    if (tagLength > sizeof(computedTag))
        return kCCParamError;
    size_t computedTagLen = tagLength;
    CCCryptorStatus rv = CCCryptorGCM(kCCDecrypt, alg, key, keyLength, iv, ivLen, aData, aDataLen, dataIn, dataInLength, dataOut, computedTag, &computedTagLen);
    if (rv != kCCSuccess)
        return rv;
    const unsigned char *expected = (const unsigned char *)tagIn;
    unsigned char diff = 0;
    for (size_t i = 0; i < tagLength; ++i)
        diff |= (unsigned char)(computedTag[i] ^ expected[i]);
    return diff ? kCCDecodeError : kCCSuccess;
}

// CCKDFParametersRef is `struct CCKDFParameters *` (opaque to callers); complete it here to carry the
// HKDF salt + info(context). CreateHkdf copies them, CCDeriveKey runs extract+expand, Destroy frees.
struct CCKDFParameters {
    void *salt;    size_t saltLen;
    void *context; size_t contextLen;
};

WK_POLYFILL_ABSENT(NULL, int32_t, CCKDFParametersCreateHkdf,
    (struct CCKDFParameters **params, const void *salt, size_t saltLen, const void *context, size_t contextLen),
    (params, salt, saltLen, context, contextLen))
{
    if (!params)
        return kCCParamError;
    struct CCKDFParameters *p = (struct CCKDFParameters *)calloc(1, sizeof(*p));
    if (!p)
        return kCCMemoryFailure;
    if (saltLen) {
        p->salt = malloc(saltLen);
        if (!p->salt) { free(p); return kCCMemoryFailure; }
        memcpy(p->salt, salt, saltLen);
        p->saltLen = saltLen;
    }
    if (contextLen) {
        p->context = malloc(contextLen);
        if (!p->context) { free(p->salt); free(p); return kCCMemoryFailure; }
        memcpy(p->context, context, contextLen);
        p->contextLen = contextLen;
    }
    *params = p;
    return kCCSuccess;
}

WK_POLYFILL_ABSENT(NULL, void, CCKDFParametersDestroy, (struct CCKDFParameters *params), (params))
{
    if (!params)
        return;
    free(params->salt);
    free(params->context);
    free(params);
}

// Map a CCDigestAlgorithm (8..12) to its HMAC algorithm + output length.
static int mav_hkdfDigestInfo(uint32_t digest, CCHmacAlgorithm *hmacAlg, unsigned *hashLen)
{
    switch (digest) {
    case 8:  *hmacAlg = kCCHmacAlgSHA1;   *hashLen = CC_SHA1_DIGEST_LENGTH;   return 1; // kCCDigestSHA1
    case 9:  *hmacAlg = kCCHmacAlgSHA224; *hashLen = CC_SHA224_DIGEST_LENGTH; return 1; // DeprecatedCCDigestSHA224
    case 10: *hmacAlg = kCCHmacAlgSHA256; *hashLen = CC_SHA256_DIGEST_LENGTH; return 1; // kCCDigestSHA256
    case 11: *hmacAlg = kCCHmacAlgSHA384; *hashLen = CC_SHA384_DIGEST_LENGTH; return 1; // kCCDigestSHA384
    case 12: *hmacAlg = kCCHmacAlgSHA512; *hashLen = CC_SHA512_DIGEST_LENGTH; return 1; // kCCDigestSHA512
    default: return 0;
    }
}

// HKDF (RFC 5869): extract PRK = HMAC(salt, IKM), then expand OKM = T(1..N) where
// T(i) = HMAC(PRK, T(i-1) || info || i), truncated to derivedKeyLen.
WK_POLYFILL_ABSENT(NULL, int32_t, CCDeriveKey,
    (const struct CCKDFParameters *params, uint32_t digest, const void *keyDerivationKey, size_t keyDerivationKeyLen, void *derivedKey, size_t derivedKeyLen),
    (params, digest, keyDerivationKey, keyDerivationKeyLen, derivedKey, derivedKeyLen))
{
    if (!params || (!derivedKey && derivedKeyLen))
        return kCCParamError;

    CCHmacAlgorithm hmacAlg;
    unsigned hashLen;
    if (!mav_hkdfDigestInfo(digest, &hmacAlg, &hashLen))
        return kCCParamError;

    // HKDF-Extract (RFC 5869 §2.2): empty salt -> HashLen zero bytes.
    unsigned char prk[CC_SHA512_DIGEST_LENGTH];
    if (params->saltLen)
        CCHmac(hmacAlg, params->salt, params->saltLen, keyDerivationKey, keyDerivationKeyLen, prk);
    else {
        unsigned char zeroSalt[CC_SHA512_DIGEST_LENGTH];
        memset(zeroSalt, 0, hashLen);
        CCHmac(hmacAlg, zeroSalt, hashLen, keyDerivationKey, keyDerivationKeyLen, prk);
    }

    // HKDF-Expand (RFC 5869 §2.3).
    size_t N = (derivedKeyLen + hashLen - 1) / hashLen;
    if (N > 255)
        return kCCParamError;

    unsigned char *input = (unsigned char *)malloc(hashLen + params->contextLen + 1);
    if (!input)
        return kCCMemoryFailure;

    unsigned char T[CC_SHA512_DIGEST_LENGTH];
    size_t Tlen = 0, outOffset = 0;
    for (size_t i = 1; i <= N; ++i) {
        size_t pos = 0;
        if (Tlen) { memcpy(input + pos, T, Tlen); pos += Tlen; }
        if (params->contextLen) { memcpy(input + pos, params->context, params->contextLen); pos += params->contextLen; }
        input[pos++] = (unsigned char)i;
        CCHmac(hmacAlg, prk, hashLen, input, pos, T);
        Tlen = hashLen;
        size_t remain = derivedKeyLen - outOffset;
        size_t copyLen = hashLen < remain ? hashLen : remain;
        memcpy((unsigned char *)derivedKey + outOffset, T, copyLen);
        outOffset += copyLen;
    }
    free(input);
    return kCCSuccess;
}

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

WK_POLYFILL_ABSENT("Security", bool, SecTrustEvaluateWithError, (SecTrustRef trust, CFErrorRef *error), (trust, error))
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

// ---------------------------------------------------------------------------------------------------
// Security — SecKey (10.12+)
//
// The whole modern SecKey API postdates 10.9, and there is no 10.9-era equivalent to build it out of:
// 10.9's key API is CSSM-based and cannot produce or consume a SecKeyRef with these semantics. Every
// entry point therefore reports "no key / no result" and leaves *error unset, which is the outcome
// callers already handle for an unsupported algorithm. WebCrypto's key operations run on libgcrypt
// in this port, so nothing on the live paths depends on these.
// ---------------------------------------------------------------------------------------------------

// SecCertificateCopyKey (10.14+): extracting a SecKeyRef public key from a certificate.
WK_POLYFILL_ABSENT("Security", SecKeyRef, SecCertificateCopyKey, (SecCertificateRef certificate), (certificate))
{
    (void)certificate;
    return NULL;
}


WK_POLYFILL_ABSENT("Security", CFDataRef, SecKeyCopyExternalRepresentation, (SecKeyRef key, CFErrorRef *error), (key, error))
{
    (void)key;
    mav_reportUnimplemented(error);
    return NULL;
}

WK_POLYFILL_ABSENT("Security", SecKeyRef, SecKeyCreateWithData, (CFDataRef keyData, CFDictionaryRef attributes, CFErrorRef *error), (keyData, attributes, error))
{
    (void)keyData; (void)attributes;
    mav_reportUnimplemented(error);
    return NULL;
}

WK_POLYFILL_ABSENT("Security", SecKeyRef, SecKeyCreateRandomKey, (CFDictionaryRef parameters, CFErrorRef *error), (parameters, error))
{
    (void)parameters;
    mav_reportUnimplemented(error);
    return NULL;
}

WK_POLYFILL_ABSENT("Security", CFDataRef, SecKeyCreateSignature, (SecKeyRef key, SecKeyAlgorithm algorithm, CFDataRef dataToSign, CFErrorRef *error), (key, algorithm, dataToSign, error))
{
    (void)key; (void)algorithm; (void)dataToSign;
    mav_reportUnimplemented(error);
    return NULL;
}

WK_POLYFILL_ABSENT("Security", Boolean, SecKeyVerifySignature, (SecKeyRef key, SecKeyAlgorithm algorithm, CFDataRef signedData, CFDataRef signature, CFErrorRef *error), (key, algorithm, signedData, signature, error))
{
    (void)key; (void)algorithm; (void)signedData; (void)signature;
    mav_reportUnimplemented(error);
    return false;
}

WK_POLYFILL_ABSENT("Security", CFDataRef, SecKeyCreateEncryptedData, (SecKeyRef key, SecKeyAlgorithm algorithm, CFDataRef plaintext, CFErrorRef *error), (key, algorithm, plaintext, error))
{
    (void)key; (void)algorithm; (void)plaintext;
    mav_reportUnimplemented(error);
    return NULL;
}

WK_POLYFILL_ABSENT("Security", CFDataRef, SecKeyCreateDecryptedData, (SecKeyRef key, SecKeyAlgorithm algorithm, CFDataRef ciphertext, CFErrorRef *error), (key, algorithm, ciphertext, error))
{
    (void)key; (void)algorithm; (void)ciphertext;
    mav_reportUnimplemented(error);
    return NULL;
}

WK_POLYFILL_ABSENT("Security", SecKeyRef, SecKeyCopyPublicKey, (SecKeyRef key), (key))
{
    (void)key;
    return NULL;
}

WK_POLYFILL_ABSENT("Security", CFDictionaryRef, SecKeyCopyAttributes, (SecKeyRef key), (key))
{
    (void)key;
    return NULL;
}

WK_POLYFILL_ABSENT("Security", CFDataRef, SecKeyCopyKeyExchangeResult,
    (SecKeyRef publicKey, SecKeyAlgorithm algorithm, SecKeyRef parameters, CFDictionaryRef requestedSize, CFErrorRef *error),
    (publicKey, algorithm, parameters, requestedSize, error))
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

WK_POLYFILL_ABSENT("Security", OSStatus, SSLCopyALPNProtocols, (SSLContextRef context, CFArrayRef *protocols), (context, protocols))
{
    (void)context;
    if (protocols) *protocols = NULL;
    return errSecUnimplemented;
}

WK_POLYFILL_ABSENT("Security", OSStatus, SSLSetALPNProtocols, (SSLContextRef context, CFArrayRef protocols), (context, protocols))
{
    (void)context; (void)protocols;
    return errSecUnimplemented;
}

// ---------------------------------------------------------------------------------------------------
// LaunchServices
// ---------------------------------------------------------------------------------------------------

// LSCopyDefaultApplicationURLForURL (10.10+): which application handles this URL. Rebuild it from the
// 10.9-era LaunchServices calls — take the URL's scheme, ask for that scheme's default handler bundle
// id, and resolve the bundle id to the handler's URL — so the answer is the real default handler, not
// a stub. Returns +1 on success, matching the Copy naming.
//
// On failure *outError MUST be set to a non-NULL CFError: callers that see a NULL result immediately
// wrap *outError to report it, and a NULL there aborts them ("Attempted to create a NULL object" in
// Rust's core-foundation, which is what made Codex's "Sign in with ChatGPT" appear to hang). With a
// real error they log it and fall back cleanly.
//
// LSRolesMask is ignored: 10.9's scheme-handler registry records one default handler per scheme with
// no role distinction, so there is nothing to filter on.
typedef UInt32 MavLSRolesMask;
enum { MavLSUnknownCreator = 0, MavLSApplicationNotFoundErr = -10814 };
WK_SYSTEM_FN("CoreServices", CFStringRef, LSCopyDefaultHandlerForURLScheme, (CFStringRef));
WK_SYSTEM_FN("CoreServices", OSStatus, LSFindApplicationForInfo, (OSType, CFStringRef, CFStringRef, void *, CFURLRef *));

WK_POLYFILL_ABSENT("CoreServices", CFURLRef, LSCopyDefaultApplicationURLForURL,
    (CFURLRef inURL, MavLSRolesMask inRoleMask, CFErrorRef *outError), (inURL, inRoleMask, outError))
{
    (void)inRoleMask;
    OSStatus status = MavLSApplicationNotFoundErr;
    CFURLRef applicationURL = NULL;

    CFStringRef scheme = inURL ? CFURLCopyScheme(inURL) : NULL;
    if (scheme) {
        CFStringRef bundleID = WK_SYSTEM(LSCopyDefaultHandlerForURLScheme)
            ? WK_SYSTEM(LSCopyDefaultHandlerForURLScheme)(scheme) : NULL;
        if (bundleID) {
            if (WK_SYSTEM(LSFindApplicationForInfo))
                status = WK_SYSTEM(LSFindApplicationForInfo)(MavLSUnknownCreator, bundleID, NULL, NULL, &applicationURL);
            CFRelease(bundleID);
        }
        CFRelease(scheme);
    }

    if (status != noErr || !applicationURL) {
        if (applicationURL) {
            CFRelease(applicationURL);
            applicationURL = NULL;
        }
        if (outError)
            *outError = CFErrorCreate(kCFAllocatorDefault, kCFErrorDomainOSStatus, status, NULL);
        return NULL;
    }
    return applicationURL;
}

// ---------------------------------------------------------------------------------------------------
// MediaAccessibility — genuinely-absent feature; caller tolerates NULL (case (b)).
// ---------------------------------------------------------------------------------------------------

// MAAudibleMediaPrefCopyPreferDescriptiveVideo was added after 10.9. The MediaAccessibility framework
// itself exists on 10.9, so WebKit's SOFT_LINK library check passes, but dlsym of this symbol returns
// NULL and the SOFT_LINK RELEASE_ASSERTs. 10.9 has no "prefer descriptive video" accessibility
// preference, so return NULL: CaptionUserPreferencesMediaAF::userPrefersTextDescriptions() then reads
// `preferDescriptiveVideo && CFBooleanGetValue(...)` as false and falls back to the base preference.
WK_POLYFILL_ABSENT("MediaAccessibility", CFBooleanRef, MAAudibleMediaPrefCopyPreferDescriptiveVideo, (void), ())
{
    return NULL;
}
