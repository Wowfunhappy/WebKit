// The framework entry points modern WebKit calls that 10.9 does not export and that are not graphics:
// Security, CFNetwork, CoreFoundation, CoreServices/LaunchServices, ApplicationServices (AX), AppKit,
// Foundation, DataDetectorsCore and sqlite3 -- plus the CommonCrypto, sandbox and os_state SPI.
//
// Each function below is either (a) runtime-gated by WebKit so it is never actually executed on 10.9,
// (b) a feature genuinely absent on 10.9 whose callers tolerate a null/zero result, or (c) implemented
// for real against the 10.9-available underlying API. The classification is noted per function.
#include "wk_polyfill.h"

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <CommonCrypto/CommonCrypto.h>
#include <pthread.h>
#include <sqlite3.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// ---------------------------------------------------------------------------------------------------
// AppKit / AX — runtime-gated; never executed on 10.9.
// ---------------------------------------------------------------------------------------------------

// Notifies AX of a process suspend/resume. No AX process-suspend tracking on 10.9; return success.
WK_POLYFILL_ABSENT("ApplicationServices", int, _AXUIElementNotifyProcessSuspendStatus, (int status))
{
    (void)status;
    return 0; // kAXErrorSuccess
}

// AccessibilitySupport: "Increase Contrast > Enhance text legibility" accessibility setting (absent on
// 10.9 — the framework that vends it postdates this OS). FontCache::platformInvalidate reads it during
// WebProcess init (a flat-namespace bind, so it must resolve). The setting is off by default.
WK_POLYFILL_ABSENT("ApplicationServices", unsigned char, _AXSEnhanceTextLegibilityEnabled, (void))
{
    return 0;
}

// HIServices SPI that tags the calling process with an AX "client type" (e.g. WebKitTesting) so the AX
// runtime can special-case test harnesses. Absent on 10.9 (postdates this OS). The layout-test drivers
// (DumpRenderTree/WebKitTestRunner) call it during accessibility-controller setup; on 10.9 there is no AX
// client-type registry, so a no-op is the correct behavior (the AX tests that depend on it are skipped).
WK_POLYFILL_ABSENT("ApplicationServices", void, _AXSetClientIdentificationOverride, (int clientType))
{
    (void)clientType;
}

// The secondary-accessibility-thread SPI (_AXUIElementRequestServicedBySecondaryAXThread,
// _AXUIElementUseSecondaryAXThread) is NOT polyfilled, deliberately. It is absent from 10.9, but the
// only code that names it is the isolated tree, which this port compiles out --
// ENABLE(ACCESSIBILITY_ISOLATED_TREE) is 0 because every platform entry point the feature stands on
// postdates this OS. The build reads that from the CMake option (Source/cmake/OptionsMac.cmake leaves
// upstream's OFF default alone); PlatformEnableCocoa.h carries the same value for builds with no
// cmakeconfig.h. Supplying answers for calls nothing makes would put entries in this layer whose
// stated reason is a configuration the port does not run.
// If the flag ever goes back to upstream's 1, these two come back with it.

// _AXGetClientForCurrentRequestUntrusted reports which assistive client (VoiceOver, a test harness, ...) is
// servicing the current accessibility request. Absent on 10.9 (postdates this OS) and referenced as a direct
// extern (not soft-linked), so a call would dyld-halt WebContent on the text-input path
// (AXObjectCache::shouldSpellCheck / clientIsInTestMode). 10.9 has no AX client-type registry, so the neutral
// answer is kAXClientTypeNoActiveRequestFound (0) — no active request, hence no test/VoiceOver client.
WK_POLYFILL_ABSENT("ApplicationServices", int, _AXGetClientForCurrentRequestUntrusted, (void))
{
    return 0; // kAXClientTypeNoActiveRequestFound
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

WK_POLYFILL_ABSENT("CoreServices", Boolean, UTTypeIsDynamic, (CFStringRef inUTI))
{
    return inUTI && CFStringHasPrefix(inUTI, CFSTR("dyn."));
}

WK_POLYFILL_ABSENT("CoreServices", Boolean, UTTypeIsDeclared, (CFStringRef inUTI))
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

// Cross-process handoff of an identified cookie store: one process turns its storage into an opaque
// CFData, another turns that CFData back into the same store. 10.9 lacks the identifying-data pair, but it
// has the two halves the pair is made of -- CFHTTPCookieStorageCreateArchive and
// CFHTTPCookieStorageCreateFromArchive, both exported (note: no leading underscore in the C names) and
// both taking (allocator, thing), read off the disassembly. The archive is a CFArray of cookie property
// dictionaries -- CFHTTPCookieStorageCreateFromArchive's first act is CFArrayGetCount on it -- so a
// property list carries it across the process boundary as the CFData the API's shape requires.
//
// Measured on this host: an in-memory storage archives to a 5-element CFArray, serializes to 62 bytes,
// and rehydrates into a live storage. Returning NULL here instead would be a fake value: it forces a
// NULL check into CookieStorageUtilsCF and makes NetworkProcess skip installing the shared storage at
// all, so the process silently runs on a different cookie jar than the one it was handed.
// Resolved with dlsym, not declared extern: both live in 10.9's CFNetwork but neither is in the 26.1
// SDK's stub library, so a link-time reference fails to build even though the call works at runtime.
typedef CFArrayRef (*wk_cookieArchiveCreate)(CFAllocatorRef, void *);
typedef void *(*wk_cookieArchiveRestore)(CFAllocatorRef, CFArrayRef);

static wk_cookieArchiveCreate wk_cookieStorageCreateArchive(void)
{
    static wk_cookieArchiveCreate function;
    static bool resolved;
    if (!resolved) {
        function = (wk_cookieArchiveCreate)dlsym(RTLD_DEFAULT, "CFHTTPCookieStorageCreateArchive");
        resolved = true;
    }
    return function;
}

static wk_cookieArchiveRestore wk_cookieStorageCreateFromArchive(void)
{
    static wk_cookieArchiveRestore function;
    static bool resolved;
    if (!resolved) {
        function = (wk_cookieArchiveRestore)dlsym(RTLD_DEFAULT, "CFHTTPCookieStorageCreateFromArchive");
        resolved = true;
    }
    return function;
}

WK_POLYFILL_ABSENT("CFNetwork", CFDataRef, CFHTTPCookieStorageCreateIdentifyingData, (CFAllocatorRef allocator, void *storage))
{
    if (!storage)
        return NULL;
    wk_cookieArchiveCreate createArchive = wk_cookieStorageCreateArchive();
    CFArrayRef archive = createArchive ? createArchive(allocator, storage) : NULL;
    if (!archive)
        return NULL;
    CFDataRef data = CFPropertyListCreateData(allocator, archive, kCFPropertyListBinaryFormat_v1_0, 0, NULL);
    CFRelease(archive);
    return data;
}

WK_POLYFILL_ABSENT("CFNetwork", void *, CFHTTPCookieStorageCreateFromIdentifyingData, (CFAllocatorRef allocator, CFDataRef data))
{
    if (!data)
        return NULL;
    CFArrayRef archive = (CFArrayRef)CFPropertyListCreateWithData(allocator, data, kCFPropertyListMutableContainers, NULL, NULL);
    if (!archive)
        return NULL;
    wk_cookieArchiveRestore restoreArchive = wk_cookieStorageCreateFromArchive();
    void *storage = NULL;
    if (restoreArchive && CFGetTypeID(archive) == CFArrayGetTypeID())
        storage = restoreArchive(allocator, archive);
    CFRelease(archive);
    return storage;
}

// App Transport Security context (10.11+). No ATS on 10.9: nothing to copy, nothing to set.
WK_POLYFILL_ABSENT("CFNetwork", CFDataRef, _CFNetworkCopyATSContext, (void))
{
    return NULL;
}

WK_POLYFILL_ABSENT("CFNetwork", Boolean, _CFNetworkSetATSContext, (CFDataRef context))
{
    (void)context;
    return false;
}

// Per-storage-session cache disable (newer API). The caller guards the call; on 10.9 it is a no-op
// (cache policy is handled through the storage session that is created without an on-disk cache).
WK_POLYFILL_ABSENT("CFNetwork", void, _CFURLStorageSessionDisableCache, (void *storageSession))
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
WK_POLYFILL_ABSENT("Network", const void *, nw_path_copy_effective_remote_endpoint, (const void *path))
{
    (void)path;
    return NULL;
}

// Returns the known-tracker host name an endpoint resolved to, or null when it is not a known tracker.
// On 10.9 there is no tracker-classification engine, so this returns null.
WK_POLYFILL_ABSENT("Network", const char *, nw_endpoint_get_known_tracker_name, (const void *endpoint))
{
    (void)endpoint;
    return NULL;
}

// Copies the proxy endpoint a connection was established through. NetworkSessionCocoa reads this to
// report a proxy's host name to Web Inspector; it comes off an NSURLSessionTaskTransactionMetrics
// _establishmentReport, and 10.9 has no such metrics object at all, so there is never a report to
// describe and null is the accurate answer. The caller already treats null as "no proxy name".
WK_POLYFILL_ABSENT("Network", const void *, nw_establishment_report_copy_proxy_endpoint, (const void *report))
{
    (void)report;
    return NULL;
}

// Returns an endpoint's host name. Reachable only with an endpoint from the call above, which 10.9
// never produces.
WK_POLYFILL_ABSENT("Network", const char *, nw_endpoint_get_hostname, (const void *endpoint))
{
    (void)endpoint;
    return NULL;
}

// ---------------------------------------------------------------------------------------------------
// CoreFoundation prefs daemon tuning — optimizations for sandboxed XPC services; no-ops on 10.9.
// ---------------------------------------------------------------------------------------------------

WK_POLYFILL_ABSENT("CoreFoundation", void, _CFPrefsSetDirectModeEnabled, (int enabled))
{
    (void)enabled;
}

WK_POLYFILL_ABSENT("CoreFoundation", void, _CFPrefsSetReadOnly, (Boolean flag))
{
    (void)flag;
}

// ---------------------------------------------------------------------------------------------------
// CoreServices / LaunchServices — called before LS check-in in auxiliary processes; no-op on 10.9.
// ---------------------------------------------------------------------------------------------------

WK_POLYFILL_ABSENT("CoreServices", void, _CSCheckFixDisable, (void))
{
}

// ---------------------------------------------------------------------------------------------------
// DataDetectorsCore — 10.9 has the DDResult CF type, just no accessor for its type id; and it can build
// a scanner but not the phone-number DFA the telephone-number detector asks for.
// ---------------------------------------------------------------------------------------------------

#define MAV_DATA_DETECTORS_CORE \
    "/System/Library/PrivateFrameworks/DataDetectorsCore.framework/DataDetectorsCore"

// WTF::CFTypeTrait<DDResultRef>::typeID() (WebCore/editing/cocoa/DataDetection.mm) is this function, so
// it is what every checked_cf_cast<DDResultRef> on a scanner result compares against. 10.9's
// DataDetectorsCore exports DDResultCreateEmpty, so the real id is obtainable: mint one result and read
// its CFGetTypeID. Measured on this host that is 256, CFCopyTypeIDDescription "DDResult", and stable
// across calls. Reporting a sentinel instead made every cast fail and the whole feature look empty.
WK_SYSTEM_FN(MAV_DATA_DETECTORS_CORE, CFTypeRef, DDResultCreateEmpty, (void));

WK_POLYFILL_ABSENT(MAV_DATA_DETECTORS_CORE, CFTypeID, DDResultGetCFTypeID, (void))
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

// The phone-number DFA scanner, the three entry points WebCore/platform/cocoa/TelephoneNumberDetectorCocoa.cpp
// is written against: DDDFACacheCreateFromFramework() loads a phone-number DFA out of DataDetectorsCore's
// own bundle, DDDFAScannerCreateFromCache() wraps it in a scanner, and DDDFAScannerFirstResultInUnicharArray()
// reports the first phone number in a UTF-16 buffer. TelephoneNumberDetector::isSupported() is "did the
// cache load", and on this platform it gates Editor::scanSelectionForTelephoneNumbers, which marks the
// phone numbers in a selection (the parser's tel:-link creation, the other caller, is iOS-only);
// ProcessWarming::prewarmGlobally builds the scanner in every WebContent process.
//
// 10.9's DataDetectorsCore (354.5) builds that cache from a CFPlugIn bundle — PlugIns/PhoneNumbers.plugin
// inside its own framework — which this OS does not ship: there is no PlugIns directory, and the
// framework's code signature lists Resources/ only, so it never shipped one. DDDFACacheCreateFromFramework
// therefore CANNOT succeed here. It CFBundleCreates the missing plugin, logs
//   Could not load the plugin PlugIns/PhoneNumbers.plugin/ -- file:///System/.../DataDetectorsCore.framework/
// once per WebContent launch, and returns NULL — leaving phone-number detection off altogether.
//
// Only that one packaging of the capability is missing. The scanner API is complete and works: a plain
// DDScannerCreate(DDScannerTypeStandard) built from the DFA caches in the framework's Resources returns
// PhoneNumber results with correct UTF-16 ranges (measured on this host: "415-555-1234", "(212) 555-0199",
// "+1 (800) 275-2273", "1-800-FLOWERS" are all found, in text that also holds URLs, dates and addresses).
// So the DFA trio is re-implemented on top of it, keeping the contract WebKit expects: a cache handle that
// is non-NULL exactly when detection works, and a first-match-in-buffer query in buffer-relative offsets.
// Results are stricter than a raw DFA's, since a full scan validates and binds what it matches — a
// telephone-number marker over a real phone number is what the caller wants.
//
// A scanner is not documented as thread-safe and this one is a process-wide singleton (WebKit builds it
// under call_once and calls find() from wherever a selection or a parse happens), so scans are serialised.

WK_SYSTEM_FN(MAV_DATA_DETECTORS_CORE, CFTypeRef, DDScannerCreate, (CFIndex type, CFIndex options, CFErrorRef *error));
WK_SYSTEM_FN(MAV_DATA_DETECTORS_CORE, void, DDScannerReset, (CFTypeRef scanner));
WK_SYSTEM_FN(MAV_DATA_DETECTORS_CORE, CFTypeRef, DDScanQueryCreateFromString, (CFAllocatorRef allocator, CFStringRef string, CFRange range));
WK_SYSTEM_FN(MAV_DATA_DETECTORS_CORE, Boolean, DDScannerScanQuery, (CFTypeRef scanner, CFTypeRef query));
WK_SYSTEM_FN(MAV_DATA_DETECTORS_CORE, CFArrayRef, DDScannerCopyResultsWithOptions, (CFTypeRef scanner, CFIndex options));
WK_SYSTEM_FN(MAV_DATA_DETECTORS_CORE, CFStringRef, DDResultGetType, (CFTypeRef result));
WK_SYSTEM_FN(MAV_DATA_DETECTORS_CORE, CFRange, DDResultGetRange, (CFTypeRef result));
WK_SYSTEM_FN(MAV_DATA_DETECTORS_CORE, CFArrayRef, DDResultGetSubResults, (CFTypeRef result));
WK_SYSTEM_FN(MAV_DATA_DETECTORS_CORE, CFTypeID, DDDFAScannerGetCFTypeID, (void));

// The cache handle WebKit adopts and hands back to DDDFAScannerCreateFromCache. There is no DFA to
// carry — the scanner below holds all the state — so it is an identity, not a structure: a constant
// CFString, which retains and releases like the CF object WebKit's RetainPtr expects.
static CFTypeRef mav_phoneNumberCacheSentinel(void)
{
    return CFSTR("com.apple.WebKit.mavericks.PhoneNumberDFACache");
}

// A DDC phone-number result always covers ASCII digits: on this host CALL-NOW, ONE-EIGHT-HUNDRED-FLOWERS
// and ABC-DEFG produce nothing, while 1-800-FLOWERS is found through its "1" and "800". Any non-ASCII
// character ends the question rather than answering it, so other digit forms are never assumed away.
static bool mav_mayHoldPhoneNumber(const UniChar *characters, unsigned length)
{
    for (unsigned i = 0; i < length; i++) {
        if (characters[i] > 0x7F || (characters[i] >= '0' && characters[i] <= '9'))
            return true;
    }
    return false;
}

// The earliest-starting phone number in a result tree. A phone number can arrive as a result in its own
// right or as a sub-result of a larger one (a contact block, say), and the DFA this stands in for would
// have matched it either way. The depth cap is a guard on recursion, not a property of the data.
static void mav_notePhoneNumber(CFTypeRef result, CFRange *earliest, unsigned depth)
{
    if (!result)
        return;

    CFStringRef type = WK_SYSTEM(DDResultGetType)(result);
    if (type && CFEqual(type, CFSTR("PhoneNumber"))) {
        CFRange range = WK_SYSTEM(DDResultGetRange)(result);
        if (range.length > 0 && (earliest->location == kCFNotFound || range.location < earliest->location))
            *earliest = range;
        return;
    }

    if (depth >= 4 || !WK_SYSTEM(DDResultGetSubResults))
        return;
    CFArrayRef subResults = WK_SYSTEM(DDResultGetSubResults)(result);
    for (CFIndex i = 0, count = subResults ? CFArrayGetCount(subResults) : 0; i < count; i++)
        mav_notePhoneNumber(CFArrayGetValueAtIndex(subResults, i), earliest, depth + 1);
}

WK_POLYFILL_REPLACES(MAV_DATA_DETECTORS_CORE, void *, DDDFACacheCreateFromFramework, (void))
{
    // Non-NULL is what makes TelephoneNumberDetector::isSupported() true, so it is claimed only when the
    // scanner API this is implemented on is actually reachable.
    if (!WK_SYSTEM(DDScannerCreate) || !WK_SYSTEM(DDScanQueryCreateFromString) || !WK_SYSTEM(DDScannerScanQuery)
        || !WK_SYSTEM(DDScannerCopyResultsWithOptions) || !WK_SYSTEM(DDResultGetType) || !WK_SYSTEM(DDResultGetRange))
        return NULL;
    return (void *)CFRetain(mav_phoneNumberCacheSentinel());
}

WK_POLYFILL_REPLACES(MAV_DATA_DETECTORS_CORE, void *, DDDFAScannerCreateFromCache, (void *cache))
{
    if ((CFTypeRef)cache != mav_phoneNumberCacheSentinel())
        return WK_ORIGINAL(DDDFAScannerCreateFromCache) ? WK_ORIGINAL(DDDFAScannerCreateFromCache)(cache) : NULL;
    return (void *)WK_SYSTEM(DDScannerCreate)(0 /* DDScannerTypeStandard */, 0, NULL);
}

WK_POLYFILL_REPLACES(MAV_DATA_DETECTORS_CORE, Boolean, DDDFAScannerFirstResultInUnicharArray,
                     (void *scanner, const UniChar *characters, unsigned length, int *startPosition, int *endPosition))
{
    if (!scanner || !characters || !length || !startPosition || !endPosition)
        return false;

    // A real DFA scanner — one this process got from DataDetectorsCore rather than from the polyfill
    // above — is answered by DataDetectorsCore.
    if (WK_SYSTEM(DDDFAScannerGetCFTypeID) && CFGetTypeID((CFTypeRef)scanner) == WK_SYSTEM(DDDFAScannerGetCFTypeID)())
        return WK_ORIGINAL(DDDFAScannerFirstResultInUnicharArray)
            ? WK_ORIGINAL(DDDFAScannerFirstResultInUnicharArray)(scanner, characters, length, startPosition, endPosition)
            : false;

    // The scanner came from the polyfill above, which builds one only when all of these resolve; the
    // check is here so that this never becomes an indirect call through NULL.
    if (!WK_SYSTEM(DDScanQueryCreateFromString) || !WK_SYSTEM(DDScannerScanQuery) || !WK_SYSTEM(DDScannerCopyResultsWithOptions)
        || !WK_SYSTEM(DDResultGetType) || !WK_SYSTEM(DDResultGetRange))
        return false;

    if (!mav_mayHoldPhoneNumber(characters, length))
        return false;

    // The caller's buffer outlives this call and nothing here keeps the string, so the characters are
    // scanned in place rather than copied — Editor hands over a whole selection.
    CFStringRef text = CFStringCreateWithCharactersNoCopy(kCFAllocatorDefault, characters, length, kCFAllocatorNull);
    if (!text)
        return false;

    CFRange earliest = { kCFNotFound, 0 };
    static pthread_mutex_t scanLock = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&scanLock);

    if (WK_SYSTEM(DDScannerReset))
        WK_SYSTEM(DDScannerReset)((CFTypeRef)scanner);

    CFTypeRef query = WK_SYSTEM(DDScanQueryCreateFromString)(kCFAllocatorDefault, text, CFRangeMake(0, length));
    if (query) {
        if (WK_SYSTEM(DDScannerScanQuery)((CFTypeRef)scanner, query)) {
            CFArrayRef results = WK_SYSTEM(DDScannerCopyResultsWithOptions)((CFTypeRef)scanner, 1 /* DDScannerCopyResultsOptionsNoOverlap */);
            for (CFIndex i = 0, count = results ? CFArrayGetCount(results) : 0; i < count; i++)
                mav_notePhoneNumber(CFArrayGetValueAtIndex(results, i), &earliest, 0);
            if (results)
                CFRelease(results);
        }
        CFRelease(query);
    }

    pthread_mutex_unlock(&scanLock);
    CFRelease(text);

    if (earliest.location == kCFNotFound)
        return false;
    *startPosition = (int)earliest.location;
    *endPosition = (int)(earliest.location + earliest.length);
    return true;
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

// Process signing identifier. Absent on 10.9; callers use it for telemetry/diagnostics and accept null.
WK_POLYFILL_ABSENT("Security", CFStringRef, SecTaskCopySigningIdentifier, (SecTaskRef task, CFErrorRef *error))
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
WK_POLYFILL_ABSENT("Security", uint32_t, SecTaskGetCodeSignStatus, (SecTaskRef task))
{
    (void)task;
    return 0;
}

// SecTrust IPC serialization. Both halves are absent on 10.9 and both resolve here, so they only need
// to round-trip with each other: carry the certificate chain (a binary plist of DER datas); the
// receiver rebuilds a SecTrust and re-evaluates with a basic X.509 policy. (Custom anchors/policies
// degrade to the default, but the chain — the part used for display and validation — survives.)
WK_POLYFILL_ABSENT("Security", CFDataRef, SecTrustSerialize, (SecTrustRef trust, CFErrorRef *error))
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

WK_POLYFILL_ABSENT("Security", SecTrustRef, SecTrustDeserialize, (CFDataRef serializedTrust, CFErrorRef *error))
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
// Foundation
// ---------------------------------------------------------------------------------------------------

// --- NSEdgeInsetsEqual (10.10+) ------------------------------------------
// WebKit has an undefined ref, so the SDK exposes it as an extern function
// (not static inline) — define the real symbol with the SDK signature.
WK_POLYFILL_ABSENT("Foundation", BOOL, NSEdgeInsetsEqual, (NSEdgeInsets a, NSEdgeInsets b))
{
    return a.top == b.top && a.left == b.left
        && a.bottom == b.bottom && a.right == b.right;
}

// ---------------------------------------------------------------------------------------------------
// sqlite3 -- 10.9 ships SQLite 3.7, so the entry points added in later versions are absent.
// ---------------------------------------------------------------------------------------------------

// sqlite3_errstr (SQLite 3.7.15) — 10.9 ships an older SQLite. Map the primary result codes to the same
// strings SQLite uses, so WebCore's diagnostic logging stays meaningful. Used only for error messages.
WK_POLYFILL_ABSENT("/usr/lib/libsqlite3.dylib", const char *, sqlite3_errstr, (int rc)) {
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
    (sqlite3_stmt *statement, int index, const void *data, sqlite3_uint64 length, void (*destructor)(void *)))
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
WK_POLYFILL_ABSENT(NULL, unsigned long, os_state_add_handler, (void *queue, void *handler))
{
    (void)queue; (void)handler;
    return 0;
}

// Audit-token sandbox checks (newer than the pid-based sandbox_check on 10.9). WebKit child processes
// run without the fine-grained profile on this backport, so report "permitted/not-restricted" (0),
// matching the pid-based path's behavior for an unsandboxed process.
WK_POLYFILL_ABSENT(NULL, int, sandbox_check_by_audit_token, (mav_audit_token_t token, const char *operation, int type, ...))
{
    (void)token; (void)operation; (void)type;
    return 0;
}

WK_POLYFILL_ABSENT(NULL, bool, sandbox_enable_state_flag, (const char *name, mav_audit_token_t token))
{
    (void)name; (void)token;
    return false;
}

// ---------------------------------------------------------------------------------------------------
// libSystem — sandbox extension issuing and profile compilation absent on 10.9.
//
// 10.9 has the process-agnostic issuers (sandbox_extension_issue_file / _mach / _generic, plus
// _consume and _release) and the full compile/apply profile API (sandbox_create_params, _set_param,
// _free_params, sandbox_compile_file / _string, sandbox_apply, _free_profile, SANDBOX_BUILD_ID) in
// /usr/lib/libsandbox.1.dylib, reached via the -lsandbox the WebKit link already passes. Absent are
// only the audit-token variants: the "_to_process" issuers, the IOKit registry-entry-class issuers,
// sandbox_check_by_audit_token, sandbox_enable_state_flag, and the SANDBOX_EXTENSION_NO_REPORT /
// SANDBOX_EXTENSION_USER_INTENT flags. Only those are polyfilled here.
// ---------------------------------------------------------------------------------------------------

extern char *sandbox_extension_issue_file(const char *extension_class, const char *path, uint32_t flags);
extern char *sandbox_extension_issue_mach(const char *extension_class, const char *name, uint32_t flags);

// The "_to_process" issuers bind an extension to one target process by audit token; 10.9 only has the
// process-agnostic form, which yields an extension token any process can consume. The token still
// travels over the same trusted IPC channel to the same child, so the grant reaching its intended
// consumer is unchanged -- it simply is not additionally scoped to that process by the kernel.
WK_POLYFILL_ABSENT(NULL, char *, sandbox_extension_issue_file_to_process, (const char *extension_class, const char *path, uint32_t flags, mav_audit_token_t token))
{
    (void)token;
    return sandbox_extension_issue_file(extension_class, path, flags);
}

WK_POLYFILL_ABSENT(NULL, char *, sandbox_extension_issue_mach_to_process, (const char *extension_class, const char *name, uint32_t flags, mav_audit_token_t token))
{
    (void)token;
    return sandbox_extension_issue_mach(extension_class, name, flags);
}

// 10.9's sandbox has no IOKit registry-entry-class extension class, and no other extension class stands
// in for it (a generic or file extension is not consumable as an IOKit one). Report "could not issue"
// -- the honest answer -- which is the same NULL upstream handles when the sandbox declines.
WK_POLYFILL_ABSENT(NULL, char *, sandbox_extension_issue_iokit_registry_entry_class, (const char *extension_class, const char *registry_entry_class, uint32_t flags))
{
    (void)extension_class; (void)registry_entry_class; (void)flags;
    return NULL;
}

WK_POLYFILL_ABSENT(NULL, char *, sandbox_extension_issue_iokit_registry_entry_class_to_process, (const char *extension_class, const char *registry_entry_class, uint32_t flags, mav_audit_token_t token))
{
    (void)extension_class; (void)registry_entry_class; (void)flags; (void)token;
    return NULL;
}

// sandbox_create_params / _set_param / _free_params / sandbox_compile_file / _string / sandbox_apply /
// _free_profile are all present in /usr/lib/libsandbox.1.dylib on 10.9 and bind directly; they are not
// polyfilled.

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
    (CCAlgorithm alg, const void *key, size_t keyLength, const void *iv, size_t ivLen, const void *aData, size_t aDataLen, const void *dataIn, size_t dataInLength, void *dataOut, const void *tagIn, size_t tagLength))
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
    (struct CCKDFParameters **params, const void *salt, size_t saltLen, const void *context, size_t contextLen))
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

WK_POLYFILL_ABSENT(NULL, void, CCKDFParametersDestroy, (struct CCKDFParameters *params))
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
    (const struct CCKDFParameters *params, uint32_t digest, const void *keyDerivationKey, size_t keyDerivationKeyLen, void *derivedKey, size_t derivedKeyLen))
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
//
// Its two siblings, LSCopyApplicationURLsForBundleIdentifier and
// LSCopyDefaultApplicationURLForContentType, live in polyfills/shared/launchservices.c instead:
// GLib's gosxappinfo calls them, so the media build compiles them too.
typedef UInt32 MavLSRolesMask;
enum { MavLSUnknownCreator = 0, MavLSApplicationNotFoundErr = -10814 };
WK_SYSTEM_FN("CoreServices", CFStringRef, LSCopyDefaultHandlerForURLScheme, (CFStringRef));
WK_SYSTEM_FN("CoreServices", OSStatus, LSFindApplicationForInfo, (OSType, CFStringRef, CFStringRef, void *, CFURLRef *));

WK_POLYFILL_ABSENT("CoreServices", CFURLRef, LSCopyDefaultApplicationURLForURL,
    (CFURLRef inURL, MavLSRolesMask inRoleMask, CFErrorRef *outError))
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
WK_POLYFILL_ABSENT("MediaAccessibility", CFBooleanRef, MAAudibleMediaPrefCopyPreferDescriptiveVideo, (void))
{
    return NULL;
}


// ---------------------------------------------------------------------------------------------
// Mach: two kernel routines whose MIG subsystems 10.9 predates.

#include <mach/mach.h>

// mach_voucher_deallocate (10.10+). A voucher is a port name in the task's IPC space, and
// deallocating one is releasing that name -- which is what mach_port_deallocate does, and what this
// routine is defined as. 10.9's kernel has no voucher subsystem at all, so no message it delivers
// ever carries one (MACH_MSGH_BITS_HAS_VOUCHER is never set) and IPC::ImportanceAssertion never gets
// as far as calling this; it is implemented properly regardless, so it is right for a caller that
// does hold a name.
WK_POLYFILL_ABSENT(NULL, kern_return_t, mach_voucher_deallocate, (mach_port_name_t voucher))
{
    if (voucher == MACH_PORT_NULL)
        return KERN_SUCCESS;
    return mach_port_deallocate(mach_task_self(), voucher);
}

// IOSurfaceSetOwnershipIdentity (macOS 14.4) attributes an IOSurface's pages to another task's
// phys_footprint ledger. 10.9's IOSurface has no ledger-ownership call and no ledger to move pages
// into, so KERN_NOT_SUPPORTED is the honest answer -- the same one task_create_identity_token below
// and mach_memory_entry_ownership in runtime.m give, for the same absent-kernel-facility reason.
//
// IOSurface::setOwnershipIdentity (WebCore IOSurface.mm:791) reads the result and only
// RELEASE_LOG_ERRORs, and today it returns at :789 because a ProcessIdentity can never be non-empty
// on 10.9 (its constructor's task_create_identity_token fails). That value guard is why the call is
// unreachable now -- but it is a guard on a VALUE several frames from here, not a soft-link probe, so
// nothing about it is visible to the linker and nothing preserves it across a rebase. IOSurface.framework
// itself IS present on 10.9, but WebKit does not soft-link this symbol (no __TEXT,__cstring literal for
// it in WebCore), so there is no canLoad_ probe a gap-fill could flip.
WK_POLYFILL_ABSENT("IOSurface", kern_return_t, IOSurfaceSetOwnershipIdentity,
    (IOSurfaceRef buffer, task_id_token_t task_id_token, int newLedgerTag, uint32_t newLedgerOptions))
{
    (void)buffer; (void)task_id_token; (void)newLedgerTag; (void)newLedgerOptions;
    return KERN_NOT_SUPPORTED;
}

// task_create_identity_token (12+) mints the token that lets a process attribute memory (IOSurfaces,
// CG backing stores) to another process's ledger. 10.9's kernel has no identity-token subsystem and
// no per-process memory ledger to attribute to, so there is no token to hand back and the honest
// answer is the one a kernel without the routine gives: KERN_NOT_SUPPORTED. That is a case upstream
// already handles -- ProcessIdentity's constructor logs the failure and leaves itself empty, which
// makes `operator bool()` false, which is how every attribution call site is gated. So restoring
// HAVE(TASK_IDENTITY_TOKEN) to upstream costs nothing at runtime: the attribution simply does not
// happen, exactly as when the flag was off.
WK_POLYFILL_ABSENT(NULL, kern_return_t, task_create_identity_token, (task_t task, task_id_token_t *token))
{
    (void)task;
    if (token)
        *token = MACH_PORT_NULL;
    return KERN_NOT_SUPPORTED;
}

// ---------------------------------------------------------------------------------------------
// CoreMedia tagged buffer groups / CMTag (macOS 14+).
//
// This is the stereoscopic-video vocabulary: a "tagged buffer group" carries several pixel buffers
// for one sample (a left-eye and a right-eye image, say), and CMTags label which is which. 10.9 has
// none of it, and nothing on this OS can produce it -- a sample's media type is never
// kCMMediaType_TaggedBufferGroup, which is the runtime test every one of these calls sits behind in
// VideoMediaSampleRenderer::imageForSample(). So the honest implementation is the empty group: no
// buffers, no tags, nothing contained. That is also exactly what upstream's own code does with a
// monoscopic sample, so it takes the plain CMSampleBufferGetImageBuffer path unchanged.
//
// These live here rather than in graphics.c beside the other CoreMedia polyfills because CMTag is
// passed and returned BY VALUE, so getting the ABI right requires the modern SDK's declaration --
// and graphics.c compiles against the 10.9 headers, which have no CMTag at all.
#import <CoreMedia/CoreMedia.h>

WK_POLYFILL_ABSENT("CoreMedia", CMTaggedBufferGroupRef, CMSampleBufferGetTaggedBufferGroup,
    (CMSampleBufferRef sampleBuffer))
{
    (void)sampleBuffer;
    return NULL;
}

WK_POLYFILL_ABSENT("CoreMedia", CMItemCount, CMTaggedBufferGroupGetCount, (CMTaggedBufferGroupRef group))
{
    (void)group;
    return 0;
}

WK_POLYFILL_ABSENT("CoreMedia", CMTagCollectionRef, CMTaggedBufferGroupGetTagCollectionAtIndex,
    (CMTaggedBufferGroupRef group, CFIndex index))
{
    (void)group; (void)index;
    return NULL;   // consistent with a count of 0: there is no index to be at
}

WK_POLYFILL_ABSENT("CoreMedia", CVPixelBufferRef, CMTaggedBufferGroupGetCVPixelBufferAtIndex,
    (CMTaggedBufferGroupRef group, CFIndex index))
{
    (void)group; (void)index;
    return NULL;
}

WK_POLYFILL_ABSENT("CoreMedia", Boolean, CMTagCollectionContainsTag,
    (CMTagCollectionRef tagCollection, CMTag tag))
{
    (void)tagCollection; (void)tag;
    return false;   // an empty collection contains nothing
}

WK_POLYFILL_ABSENT("CoreMedia", OSStatus, CMTagCollectionGetTagsWithCategory,
    (CMTagCollectionRef tagCollection, CMTagCategory category, CMTag *tagBuffer,
     CMItemCount tagBufferCount, CMItemCount *numberOfTagsCopied))
{
    (void)tagCollection; (void)category; (void)tagBuffer; (void)tagBufferCount;
    // Succeeding with nothing copied is how the real routine reports "no tags of that category",
    // and it is what the caller checks: upstream requires numberOfTagsCopied == 1 to use the tag.
    if (numberOfTagsCopied)
        *numberOfTagsCopied = 0;
    return noErr;
}

WK_POLYFILL_ABSENT("CoreMedia", int64_t, CMTagGetSInt64Value, (CMTag tag))
{
    (void)tag;
    return 0;
}

// The tag constants, composed exactly as CMTag.h documents them: kCMTagInvalid is the sentinel whose
// dataType is kCMTagDataType_Invalid (what CMTAG_IS_VALID tests), and the two stereo tags are
// category kCMTagCategory_StereoView carrying the matching kCMStereoView_* flag. So these are the
// real values, not placeholders -- though nothing on 10.9 can produce a tag to compare them against.
WK_POLYFILL_CONST("CoreMedia", CMTag, kCMTagInvalid,
                  ((CMTag){ kCMTagCategory_Undefined, kCMTagDataType_Invalid, 0 }));
WK_POLYFILL_CONST("CoreMedia", CMTag, kCMTagStereoLeftEye,
                  ((CMTag){ kCMTagCategory_StereoView, kCMTagDataType_Flags, kCMStereoView_LeftEye }));
WK_POLYFILL_CONST("CoreMedia", CMTag, kCMTagStereoRightEye,
                  ((CMTag){ kCMTagCategory_StereoView, kCMTagDataType_Flags, kCMStereoView_RightEye }));

// The hero-eye format-description extension: which eye to show when a stereo pair is presented
// monoscopically. 10.9 writes no format-description extensions of this kind and reads none, so this
// key is only ever looked up in dictionaries that cannot contain it -- CMFormatDescriptionGetExtension
// returns NULL and upstream falls through to its LayerID=0 path. The spellings match the constants'
// names, so a log or a debugger shows something meaningful.
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionExtension_HeroEye, CFSTR("HeroEye"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionHeroEye_Left, CFSTR("LeftEye"));

// os_retain / os_release (10.10+). WHY THIS EXISTS, since it is easy to conclude it does not need to:
// <os/object.h> defines these as MACROS (`[object retain]`) when OS_OBJECT_USE_OBJC is 1, which it is in
// any ObjC or ObjC++ translation unit — so probing them from a .mm file says "macro, no linker symbol,
// nothing to polyfill". That probe is misleading. In a plain C++ TU, which is most of JavaScriptCore,
// OS_OBJECT_USE_OBJC is 0 and they are ORDINARY FUNCTIONS — absent from 10.9's libSystem, so
// JavaScriptCore fails to load with "Symbol not found: _os_retain". (Measured, after I removed an in-tree
// #ifndef os_retain shim from wtf/OSObjectPtr.h believing it was dead code.)
//
// Every os_object_t 10.9 knows is a libdispatch object, and dispatch_retain/dispatch_release are present
// here (nm-verified) and already do the right thing whichever way libdispatch was built: with
// OS_OBJECT_USE_OBJC they forward to the ObjC retain/release the object actually uses, without it they run
// the plain refcount. So these forward rather than reimplement, which also keeps them correct for any
// os_object_t that is not a dispatch object.
//
// The #undefs are needed because THIS file is ObjC, so the macros above are in scope here.
#undef os_retain
#undef os_release

WK_SYSTEM_FN(NULL, void, dispatch_retain, (void *));
WK_SYSTEM_FN(NULL, void, dispatch_release, (void *));

WK_POLYFILL_ABSENT(NULL, void *, os_retain, (void *object))
{
    if (object && WK_SYSTEM(dispatch_retain))
        WK_SYSTEM(dispatch_retain)(object);
    return object;
}

WK_POLYFILL_ABSENT(NULL, void, os_release, (void *object))
{
    if (object && WK_SYSTEM(dispatch_release))
        WK_SYSTEM(dispatch_release)(object);
}

// os_transaction_create (10.10+). The XPC service entry point (Shared/EntryPointUtilities/Cocoa/
// XPCService/XPCServiceEntryPoint) creates one os_transaction to keep the child process alive across
// its initializer; on 10.9 that symbol is absent from libSystem, so every WebContent/Networking/GPU
// child crashed at launch on a lazy bind of _os_transaction_create (EXC_BREAKPOINT in
// dyld::fastBindLazySymbol from NetworkServiceInitializer / WebContentServiceInitializer).
//
// os_transaction is purely a process-lifecycle assertion introduced with the os_object refactor; 10.9
// has no equivalent, and the child's real lifecycle is held by xpc_transaction (xpc_transaction_exit_clean
// is used in the same file). Returning NULL means "no transaction": adoptOSObject(NULL) yields an empty
// OSObjectPtr, and the os_retain/os_release polyfills above are NULL-safe, so nothing dereferences it.
WK_POLYFILL_ABSENT(NULL, void *, os_transaction_create, (const char *description))
{
    (void)description;
    return NULL;
}

// voucher_replace_default_voucher (10.10+). The same XPC service entry point calls this right after
// InitializeWebKit2() to adopt the mach voucher XPC propagated to the child; on 10.9 the voucher API
// does not exist, so the child crashed at launch on a lazy bind of _voucher_replace_default_voucher
// (same fastBindLazySymbol path as os_transaction_create above). 10.9 has no voucher propagation, so
// leaving the task default voucher untouched is the correct behaviour — a no-op.
WK_POLYFILL_ABSENT(NULL, void, voucher_replace_default_voucher, (void))
{
}

// dispatch_activate (10.11+). A dispatch source/queue created suspended is started with either
// dispatch_activate (one-way, idempotent "make active") or dispatch_resume; on a freshly-created object
// that the caller has not otherwise suspended they are equivalent, and dispatch_resume is present on
// 10.9. WebKit's callers activate once, immediately after configuring a source — e.g.
// VideoMediaSampleRenderer.mm creates a DISPATCH_SOURCE_TYPE_TIMER and calls dispatch_activate on it —
// so forwarding to dispatch_resume reproduces the real behaviour. (Not idempotent the way activate is,
// but WebKit never activates the same object twice.) Without this, the absent symbol lazy-bind-crashed
// the process on the renderer's timer setup. The signature must match <dispatch/dispatch.h>'s
// declaration (dispatch_object_t, not void*), which is present in the SDK even though the symbol is not
// on 10.9; dispatch_resume IS on 10.9 and lives in always-linked libdispatch, so a direct call is safe.
WK_POLYFILL_ABSENT(NULL, void, dispatch_activate, (dispatch_object_t object))
{
    if (object)
        dispatch_resume(object);
}

// ---------------------------------------------------------------------------------------------
// Network.framework (10.14+) and Metal (10.11+) — frameworks 10.9 does not have AT ALL.
//
// WebKit2 weak-links both, so every reference below binds to address 0 and a call branches there.
// The call sites do guard today: WebTransport's are behind canLoad_Network_* probes
// (NetworkTransportSessionCocoa.mm:258-262 returns nullptr before reaching any nw_* call), and
// ScopedRenderingResourcesRequestCocoa.mm's MTLCopyAllDevices sits under ENABLE(GPU_PROCESS), which is
// off. These entries are not written because those guards are believed broken; they are written
// because "the call site guards it" is a property of TODAY's call sites, invisible to the linker, and
// re-verified only by someone remembering to. A defined failure is the difference between a future
// unguarded call returning nil and jumping to 0.
//
// Gap-filling these is regression-free precisely BECAUSE the framework is absent, and that is what
// makes the set decidable rather than a judgement call. A gap-fill can only flip a soft-link probe
// when the provider is loadable: handleCanSeeProvider() in wk_polyfill_runtime.c requires
// `provider != NULL && handle == provider`, and a framework that cannot be dlopened yields a NULL
// provider, so no canLoad_Network_*/canLoad_Metal_* probe can ever match one of these. Those probes
// keep answering false and the call sites keep taking their own absent-API paths. (Contrast the
// SecCertificateCopyNotValidAfterDate family: absent on 10.9, but Security.framework IS present, so a
// gap-fill there COULD flip a probe and make a caller believe a feature exists. Those stay inventory,
// and check-absent-references.sh splits the two cases on exactly this rule.)
//
// The signatures use opaque pointers rather than nw_*/MTL types: those headers describe frameworks
// that are not here, and this file deliberately does not include them. Every parameter is
// pointer-sized or an integer, so the ABI matches whatever a caller was compiled against; only the
// answers matter, and the answer everywhere is "nothing was created, nothing was sent".

WK_POLYFILL_ABSENT("Network", void *, nw_endpoint_create_url, (const char *url))
{ (void)url; return NULL; }
WK_POLYFILL_ABSENT("Network", void *, nw_group_descriptor_create_multiplex, (void *endpoint))
{ (void)endpoint; return NULL; }
WK_POLYFILL_ABSENT("Network", void *, nw_connection_group_create, (void *descriptor, void *parameters))
{ (void)descriptor; (void)parameters; return NULL; }
WK_POLYFILL_ABSENT("Network", void, nw_connection_group_set_queue, (void *group, void *queue))
{ (void)group; (void)queue; }
WK_POLYFILL_ABSENT("Network", void, nw_connection_group_set_state_changed_handler, (void *group, void *handler))
{ (void)group; (void)handler; }
WK_POLYFILL_ABSENT("Network", void, nw_connection_group_set_new_connection_handler, (void *group, void *handler))
{ (void)group; (void)handler; }
WK_POLYFILL_ABSENT("Network", void, nw_connection_group_start, (void *group))
{ (void)group; }
WK_POLYFILL_ABSENT("Network", void, nw_connection_group_cancel, (void *group))
{ (void)group; }
WK_POLYFILL_ABSENT("Network", void *, nw_connection_group_extract_connection, (void *group, void *endpoint, void *protocol))
{ (void)group; (void)endpoint; (void)protocol; return NULL; }
WK_POLYFILL_ABSENT("Network", void *, nw_connection_group_copy_protocol_metadata, (void *group, void *definition))
{ (void)group; (void)definition; return NULL; }
WK_POLYFILL_ABSENT("Network", void, nw_connection_start, (void *connection))
{ (void)connection; }
WK_POLYFILL_ABSENT("Network", void, nw_connection_cancel, (void *connection))
{ (void)connection; }
WK_POLYFILL_ABSENT("Network", void, nw_connection_set_queue, (void *connection, void *queue))
{ (void)connection; (void)queue; }
WK_POLYFILL_ABSENT("Network", void, nw_connection_set_state_changed_handler, (void *connection, void *handler))
{ (void)connection; (void)handler; }
WK_POLYFILL_ABSENT("Network", void, nw_connection_send, (void *connection, void *content, void *context, bool is_complete, void *completion))
{ (void)connection; (void)content; (void)context; (void)is_complete; (void)completion; }
WK_POLYFILL_ABSENT("Network", void, nw_connection_receive, (void *connection, uint32_t minimum, uint32_t maximum, void *completion))
{ (void)connection; (void)minimum; (void)maximum; (void)completion; }
WK_POLYFILL_ABSENT("Network", void *, nw_connection_copy_protocol_metadata, (void *connection, void *definition))
{ (void)connection; (void)definition; return NULL; }
// nw_error_domain_t's "no error" member is 0, which is also the honest answer for an error object that
// could never have been produced here.
WK_POLYFILL_ABSENT("Network", int, nw_error_get_error_domain, (void *error))
{ (void)error; return 0; }
WK_POLYFILL_ABSENT("Network", int, nw_error_get_error_code, (void *error))
{ (void)error; return 0; }
WK_POLYFILL_ABSENT("Network", void, nw_quic_set_max_datagram_frame_size, (void *options, uint16_t size))
{ (void)options; (void)size; }
WK_POLYFILL_ABSENT("Network", void *, nw_tls_copy_sec_protocol_options, (void *options))
{ (void)options; return NULL; }
// The three sec_* entries are DECLARED by Security.framework's headers (SecProtocolTypes.h,
// SecProtocolOptions.h) even though Network.framework is what implements them, so unlike the nw_*
// entries above these must use the real SDK types -- this file includes <Security/Security.h>.
WK_POLYFILL_ABSENT("Network", void, sec_protocol_options_set_peer_authentication_required, (sec_protocol_options_t options, bool peer_authentication_required))
{ (void)options; (void)peer_authentication_required; }
WK_POLYFILL_ABSENT("Network", void, sec_protocol_options_set_verify_block, (sec_protocol_options_t options, sec_protocol_verify_t verify_block, dispatch_queue_t verify_block_queue))
{ (void)options; (void)verify_block; (void)verify_block_queue; }
WK_POLYFILL_ABSENT("Network", SecTrustRef, sec_trust_copy_ref, (sec_trust_t trust))
{ (void)trust; return NULL; }

// Metal. "No devices" is what a machine without Metal has, but the two entry points spell that
// differently and the difference matters to a CF-side caller: MTLCreateSystemDefaultDevice() returns
// an id, whose documented "no Metal device" answer is nil, while MTLCopyAllDevices() returns
// NSArray<id<MTLDevice>> * NS_RETURNS_RETAINED, whose answer is an EMPTY array. Handing back NULL
// there would fault any caller that goes straight to CFArrayGetCount/CFArrayGetValueAtIndex instead
// of sending an ObjC message.
WK_POLYFILL_ABSENT("Metal", void *, MTLCreateSystemDefaultDevice, (void))
{ return NULL; }
WK_POLYFILL_ABSENT("Metal", CFArrayRef, MTLCopyAllDevices, (void))
{ return CFArrayCreate(kCFAllocatorDefault, NULL, 0, &kCFTypeArrayCallBacks); }
