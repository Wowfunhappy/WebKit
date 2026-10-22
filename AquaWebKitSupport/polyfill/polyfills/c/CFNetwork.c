// CFNetwork: entry points and constants modern WebKit references that 10.9's CFNetwork does not export,
// with native protection-space and credential coding.
#include "wk_declared_types.h"
#include "wk_polyfill.h"
#include "wk_symbols.h"
#include "wk_cookie_storage.h"
#include <dispatch/dispatch.h>
#include "wk_trust.h"
#include "wk_url_coding.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <malloc/malloc.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <objc/objc-sync.h>
#include <syslog.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char kCFNetworkSuffix[] = "/CFNetwork.framework/Versions/A/CFNetwork";

typedef struct OpaqueCFHTTPCookieStorage *CFHTTPCookieStorageRef;
typedef struct __CFURLStorageSession *CFURLStorageSessionRef;

// Mavericks accepts only policies 0 through 2. Map exclusive policy 3 to native policy 2.
// The native jar retains policy 2; the URL setter applies the exclusive policy's stricter boundary.
static const void *wk_exclusiveCookiePolicyKey(void)
{
    return (const void *)sel_registerName("wk_exclusiveCookieAcceptPolicy");
}

WK_POLYFILL_REPLACES("CFNetwork", void, CFHTTPCookieStorageSetCookieAcceptPolicy, (CFHTTPCookieStorageRef storage, CFIndex policy))
{
    objc_sync_enter((id)storage);
    WK_ORIGINAL(CFHTTPCookieStorageSetCookieAcceptPolicy)(storage, policy == 3 ? 2 : policy);
    objc_setAssociatedObject((id)storage, wk_exclusiveCookiePolicyKey(),
        policy == 3 ? (id)kCFBooleanTrue : nil, OBJC_ASSOCIATION_RETAIN);
    objc_sync_exit((id)storage);
}

WK_POLYFILL_REPLACES("CFNetwork", CFIndex, CFHTTPCookieStorageGetCookieAcceptPolicy, (CFHTTPCookieStorageRef storage))
{
    objc_sync_enter((id)storage);
    CFIndex policy = WK_ORIGINAL(CFHTTPCookieStorageGetCookieAcceptPolicy)(storage);
    if (policy == 2 && objc_getAssociatedObject((id)storage, wk_exclusiveCookiePolicyKey()))
        policy = 3;
    objc_sync_exit((id)storage);
    return policy;
}

WK_POLYFILL_REPLACES("CFNetwork", CFHTTPCookieStorageRef, _CFHTTPCookieStorageGetDefault, (CFAllocatorRef allocator))
{
    // Resolved with dlsym: the published jar lives in the WebCore-only half of the layer.
    static CFHTTPCookieStorageRef (*sharedStorage)(void);
    if (!sharedStorage)
        sharedStorage = (CFHTTPCookieStorageRef (*)(void))dlsym(RTLD_DEFAULT, "wk_sharedCookieStorage");
    CFHTTPCookieStorageRef storage = sharedStorage();
    return storage ? storage : WK_ORIGINAL(_CFHTTPCookieStorageGetDefault)(allocator);
}

WK_POLYFILL_CONST("CFNetwork", CFStringRef, kCFURLRequestContentDecoderSkipURLCheck, CFSTR("kCFURLRequestContentDecoderSkipURLCheck"));

// ---------------------------------------------------------------------------------------------------
// CFNetwork — features 10.9 lacks.
// ---------------------------------------------------------------------------------------------------

// Cookie storage archives carry the native main jar and its WebKit companion. Each native archive
// reopens its file/cookied identity or copies its in-memory records.
WK_SYSTEM_FN("CFNetwork", CFArrayRef, CFHTTPCookieStorageCreateArchive, (CFAllocatorRef, void *));
WK_SYSTEM_FN("CFNetwork", void *, CFHTTPCookieStorageCreateFromArchive, (CFAllocatorRef, CFArrayRef));

typedef CFHTTPCookieStorageRef (*wk_companion_storage)(CFHTTPCookieStorageRef);
typedef void (*wk_set_companion_storage)(CFHTTPCookieStorageRef, CFHTTPCookieStorageRef);

WK_POLYFILL_REPLACES("CFNetwork", CFArrayRef, CFHTTPCookieStorageCreateArchive, (CFAllocatorRef allocator, void *storage))
{
    CFArrayRef native = WK_ORIGINAL(CFHTTPCookieStorageCreateArchive)(allocator, storage);
    static wk_companion_storage companionStorage;
    if (!companionStorage)
        companionStorage = (wk_companion_storage)dlsym(RTLD_DEFAULT, "wk_cookieStorageCompanion");
    if (!native)
        return native;
    CFArrayRef companion = WK_ORIGINAL(CFHTTPCookieStorageCreateArchive)(allocator, companionStorage(storage));
    const void *jars[] = { native, companion };
    CFArrayRef archive = CFArrayCreate(allocator, jars, 2, &kCFTypeArrayCallBacks);
    CFRelease(companion);
    CFRelease(native);
    return archive;
}

WK_POLYFILL_REPLACES("CFNetwork", void *, CFHTTPCookieStorageCreateFromArchive, (CFAllocatorRef allocator, CFArrayRef archive))
{
    if (!archive || CFArrayGetCount(archive) != 2)
        return WK_ORIGINAL(CFHTTPCookieStorageCreateFromArchive)(allocator, archive);
    CFHTTPCookieStorageRef storage = WK_ORIGINAL(CFHTTPCookieStorageCreateFromArchive)(allocator, CFArrayGetValueAtIndex(archive, 0));
    static wk_set_companion_storage setCompanionStorage;
    if (!setCompanionStorage)
        setCompanionStorage = (wk_set_companion_storage)dlsym(RTLD_DEFAULT, "wk_cookieStorageSetCompanion");
    if (storage) {
        CFHTTPCookieStorageRef companion = WK_ORIGINAL(CFHTTPCookieStorageCreateFromArchive)(allocator, CFArrayGetValueAtIndex(archive, 1));
        setCompanionStorage(storage, companion);
        CFRelease(companion);
    }
    return storage;
}

WK_POLYFILL_ABSENT("CFNetwork", CFDataRef, CFHTTPCookieStorageCreateIdentifyingData, (CFAllocatorRef allocator, void *storage))
{
    if (!storage)
        return NULL;
    CFArrayRef archive = CFHTTPCookieStorageCreateArchive(allocator, storage);
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
    void *storage = NULL;
    if (CFGetTypeID(archive) == CFArrayGetTypeID())
        storage = CFHTTPCookieStorageCreateFromArchive(allocator, archive);
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

// A storage session carries its own URL cache (20 MB on disk, 4 MB in memory for an identified
// session); disabling it sets both capacities of that cache to zero.
typedef const struct _CFURLCache *CFURLCacheRef;
extern CFURLCacheRef _CFURLStorageSessionCopyCache(CFAllocatorRef, CFURLStorageSessionRef);
extern void CFURLCacheSetDiskCapacity(CFURLCacheRef, CFIndex);
extern void CFURLCacheSetMemoryCapacity(CFURLCacheRef, CFIndex);

WK_POLYFILL_ABSENT("CFNetwork", void, _CFURLStorageSessionDisableCache, (void *storageSession))
{
    CFURLCacheRef cache = _CFURLStorageSessionCopyCache(kCFAllocatorDefault, (CFURLStorageSessionRef)storageSession);
    CFURLCacheSetDiskCapacity(cache, 0);
    CFURLCacheSetMemoryCapacity(cache, 0);
    CFRelease(cache);
}

// ---------------------------------------------------------------------------------------------------
// Private storage sessions.
//
// A session created with _kCFURLStorageSessionIsPrivate has the same properties as the default session
// except that its storage is in-memory only. 10.9 gives one an ExternalCookieStorage instead: a jar
// registered with cookied under the session's identifier, whose every read is an XPC round trip
// (0.276 ms per CFHTTPCookieStorageCopyCookiesForURL on this host against 0.0075 ms in memory).
// CFHTTPCookieStorageCreateInMemory builds the MemoryCookieStorage the contract describes, and a private
// session carries one from creation, so the ephemeral network sessions, the testing sessions and the Web
// Process cookie cache all read and write their cookies in process.
//
// The jar rides on the session as an object association: it lives exactly as long as the session, and
// every copy hands back the one jar. The key is a selector, so it is the same address in every image:
// libpolyfill.a is force-loaded into each framework, WebCore creates the session and WebKit,
// WebKitLegacy and WebCore all copy the jar out of it. CFHTTPCookieStorageCreateInMemory and
// _kCFURLStorageSessionIsPrivate are resolved at first use -- 10.9 exports both, the 26.1 SDK's stub
// library names neither.
//
// The jar has to lock. Every HTTPCookieStorage entry point reads a CoreLockable out of its storage --
// HTTPCookieStorage::deleteAllCookies (0xd2e8e) is `impl = [this+0x10]; if ([impl+0x20]) { lock;
// ...Locked(); unlock } else ...Locked()` -- and 10.9 builds the storage behind
// CFHTTPCookieStorageCreateInMemory with MemoryCookieStorage(0) (HTTPCookieStorage::initialize,
// 0x19524), which leaves that slot NULL, so every operation on such a jar runs its *Locked body with no
// lock at all. MemoryCookieStorage::createFromArchive passes 1 instead (0xd4733) and gets the mutex, so
// the storage CFHTTPCookieStorageCreateFromArchive rebuilds from an empty one is the same
// MemoryCookieStorage with its lock in place. NetworkStorageSession::deleteAllCookies runs on a
// dispatch queue while the main thread reads the same jar, which is the access the lock serializes.
static const void *wk_privateCookieStorageKey(void)
{
    static const void *key;
    if (!key)
        key = (const void *)sel_registerName("wk_privateStorageSessionCookieJar");
    return key;
}

WK_SYSTEM_FN("CFNetwork", CFHTTPCookieStorageRef, CFHTTPCookieStorageCreateInMemory, (CFAllocatorRef, CFHTTPCookieStorageRef));
WK_SYSTEM_CONST("CFNetwork", CFStringRef, _kCFURLStorageSessionIsPrivate);

static Boolean wk_propertiesAskForPrivateSession(CFDictionaryRef properties)
{
    if (!properties)
        return false;
    CFTypeRef value = CFDictionaryGetValue(properties, WK_SYSTEM(_kCFURLStorageSessionIsPrivate));
    return value && CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue(value);
}

static CFHTTPCookieStorageRef wk_createLockedInMemoryCookieStorage(CFAllocatorRef allocator)
{
    CFHTTPCookieStorageRef empty = WK_SYSTEM(CFHTTPCookieStorageCreateInMemory)(allocator, NULL);
    CFArrayRef archive = WK_SYSTEM(CFHTTPCookieStorageCreateArchive)(allocator, empty);
    CFRelease(empty);
    CFHTTPCookieStorageRef storage = (CFHTTPCookieStorageRef)WK_SYSTEM(CFHTTPCookieStorageCreateFromArchive)(allocator, archive);
    CFRelease(archive);
    return storage;
}

WK_POLYFILL_REPLACES("CFNetwork", CFURLStorageSessionRef, _CFURLStorageSessionCreate,
    (CFAllocatorRef allocator, CFStringRef identifier, CFDictionaryRef properties))
{
    CFURLStorageSessionRef session = WK_ORIGINAL(_CFURLStorageSessionCreate)(allocator, identifier, properties);
    if (!session || !wk_propertiesAskForPrivateSession(properties))
        return session;

    CFHTTPCookieStorageRef storage = wk_createLockedInMemoryCookieStorage(allocator);
    objc_setAssociatedObject((id)session, wk_privateCookieStorageKey(), (id)storage, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CFRelease(storage);
    return session;
}

WK_POLYFILL_REPLACES("CFNetwork", CFHTTPCookieStorageRef, _CFURLStorageSessionCopyCookieStorage,
    (CFAllocatorRef allocator, CFURLStorageSessionRef session))
{
    CFHTTPCookieStorageRef storage = session
        ? (CFHTTPCookieStorageRef)objc_getAssociatedObject((id)session, wk_privateCookieStorageKey()) : NULL;
    if (storage)
        return (CFHTTPCookieStorageRef)CFRetain(storage);
    return WK_ORIGINAL(_CFURLStorageSessionCopyCookieStorage)(allocator, session);
}

// ---------------------------------------------------------------------------------------------------
// HTTP Strict Transport Security: 10.9's CFNetwork answers from the HSTS policy its own loader records.
// This build loads over curl, so the policies live in WebCore's store and that store is what the query
// asks for the application's own session. A named storage session keeps 10.9's own answer, which is
// the policy that session recorded.
// Resolved with dlsym: libpolyfill.a is force-loaded into every WebKit image, including ones that do
// not link WebCore, so a link-time reference to WebCore would make those images fail to link.
typedef bool (*wk_hsts_query)(CFURLRef);

static wk_hsts_query wk_knownHSTSHostQuery(void)
{
    static wk_hsts_query query;
    if (!query)
        query = (wk_hsts_query)dlsym(RTLD_DEFAULT, "WebCoreIsKnownHSTSHost");
    return query;
}

// A jar's enumeration includes its partitioned cookies, which the WebCore-only half of the layer keeps.
typedef CFArrayRef (*wk_copy_cookies)(CFHTTPCookieStorageRef);
WK_POLYFILL_REPLACES("CFNetwork", CFArrayRef, CFHTTPCookieStorageCopyCookies, (CFHTTPCookieStorageRef storage))
{
    static wk_copy_cookies copyCookies;
    if (!copyCookies)
        copyCookies = (wk_copy_cookies)dlsym(RTLD_DEFAULT, "wk_cookieStorageCopyCookies");
    return copyCookies(storage);
}

// NetworkStorageSession::deleteAllCookies clears a CF storage through this entry point. The storage's
// own handler reports that clear as a remove-all, which a subscriber cannot reconstruct from a diff:
// the jar it takes includes cookies no subscriber ever saw.
typedef void (*wk_removed_all)(CFHTTPCookieStorageRef);
WK_SYSTEM_FN("CFNetwork", void, CFHTTPCookieStorageSyncStorageNow, (CFHTTPCookieStorageRef));

WK_POLYFILL_REPLACES("CFNetwork", void, CFHTTPCookieStorageDeleteAllCookies, (CFHTTPCookieStorageRef storage))
{
    WK_ORIGINAL(CFHTTPCookieStorageDeleteAllCookies)(storage);
    // 10.9's external storage sends delete-all without a reply; sync is the completion barrier.
    WK_SYSTEM(CFHTTPCookieStorageSyncStorageNow)(storage);
    // Resolved with dlsym: the cookie observation lives in the WebCore-only half of the layer.
    static wk_removed_all notify;
    if (!notify)
        notify = (wk_removed_all)dlsym(RTLD_DEFAULT, "wk_cookieStorageDidRemoveAllCookies");
    notify(storage);
}

// NetworkStorageSession::deleteHTTPCookie removes one cookie through this entry point, which reaches the
// storage below -[NSHTTPCookieStorage deleteCookie:], where subscribers hear of a removal.
typedef const struct OpaqueCFHTTPCookie *CFHTTPCookieRef;
typedef void (*wk_delete_cookie)(CFHTTPCookieStorageRef, CFHTTPCookieRef);
typedef void (*wk_delete_cookie_notifying)(CFHTTPCookieStorageRef, CFHTTPCookieRef, wk_delete_cookie);

WK_POLYFILL_REPLACES("CFNetwork", void, CFHTTPCookieStorageDeleteCookie, (CFHTTPCookieStorageRef storage, CFHTTPCookieRef cookie))
{
    // Resolved with dlsym: the cookie observation lives in the WebCore-only half of the layer.
    static wk_delete_cookie_notifying notifying;
    if (!notifying)
        notifying = (wk_delete_cookie_notifying)dlsym(RTLD_DEFAULT, "wk_cookieStorageDeleteCookie");
    notifying(storage, cookie, WK_ORIGINAL(CFHTTPCookieStorageDeleteCookie));
}

WK_POLYFILL_REPLACES("CFNetwork", Boolean, _CFNetworkIsKnownHSTSHostWithSession, (CFURLRef url, CFTypeRef session))
{
    if (session)
        return WK_ORIGINAL(_CFNetworkIsKnownHSTSHostWithSession)(url, session);
    return url ? wk_knownHSTSHostQuery()(url) : false;
}

// ---------------------------------------------------------------------------------------------------
// Protection spaces and credentials as property lists: the CFNetwork side of the
// HAVE(WK_SECURE_CODING_NSURLPROTECTIONSPACE) / HAVE(WK_SECURE_CODING_NSURLCREDENTIAL) coders, whose
// Foundation methods methods/Foundation.m supplies.
//
// A protection space's trust and distinguished names have no setter in the API CFNetwork exports:
// CFURLProtectionSpaceCreate takes the other five fields, and the two arrive only through the archive
// _CFURLProtectionSpaceCreateFromArchive reads -- the dictionary _CFURLProtectionSpaceCreateArchive
// writes for a space, plus "distnames" and a "trust" entry of {"certs", "policies"}, each array written
// by SerializableArchive::add(CFStringRef, CFArrayRef). The dearchiver rebuilds the trust from those
// certificates with SecPolicyCreateSSL(false, NULL) as its policy, so the question the trust asks is
// then set from the trust it stands for: policies, custom anchors, verify date and network fetch.
typedef const struct _CFURLProtectionSpace *WKURLProtectionSpaceRef;
WK_SYSTEM_FN("CFNetwork", WKURLProtectionSpaceRef, CFURLProtectionSpaceCreate,
    (CFAllocatorRef, CFStringRef host, int port, int serverType, CFStringRef realm, int authenticationScheme));
WK_SYSTEM_FN("CFNetwork", SecTrustRef, CFURLProtectionSpaceGetServerTrust, (WKURLProtectionSpaceRef));
WK_SYSTEM_FN("CFNetwork", CFDictionaryRef, _CFURLProtectionSpaceCreateArchive, (CFAllocatorRef, WKURLProtectionSpaceRef));
WK_SYSTEM_FN("CFNetwork", WKURLProtectionSpaceRef, _CFURLProtectionSpaceCreateFromArchive, (CFAllocatorRef, CFDictionaryRef));
WK_SYSTEM_FN("CFNetwork", CFTypeID, CFURLCredentialGetTypeID, (void));

// SerializableArchive is the one dictionary it writes into.
typedef struct {
    CFMutableDictionaryRef dictionary;
} wk_serializable_archive;
typedef void (*wk_add_array_fn)(wk_serializable_archive *archive, CFStringRef key, CFArrayRef value);

static wk_add_array_fn wk_archiveAddArray(void)
{
    static wk_add_array_fn addArray;
    if (!addArray) {
        wk_image image;
        wk_find_image(kCFNetworkSuffix, &image);
        addArray = (wk_add_array_fn)wk_symbol_in_image(&image, "__ZN19SerializableArchive3addEPK10__CFStringPK9__CFArray");
    }
    return addArray;
}

CFTypeRef wk_createProtectionSpace(CFStringRef host, int port, int serverType, CFStringRef realm,
    int authenticationScheme, CFArrayRef distinguishedNames, SecTrustRef trust)
{
    WKURLProtectionSpaceRef bare = WK_SYSTEM(CFURLProtectionSpaceCreate)(kCFAllocatorDefault, host, port, serverType, realm, authenticationScheme);
    if (!bare)
        return NULL;
    if (!distinguishedNames && !trust)
        return bare;
    CFDictionaryRef bareArchive = WK_SYSTEM(_CFURLProtectionSpaceCreateArchive)(kCFAllocatorDefault, bare);
    CFRelease(bare);
    if (!bareArchive)
        return NULL;
    wk_serializable_archive archive = { CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, bareArchive) };
    CFRelease(bareArchive);

    if (distinguishedNames)
        wk_archiveAddArray()(&archive, CFSTR("distnames"), distinguishedNames);

    CFArrayRef policies = NULL;
    if (trust) {
        CFArrayRef certificates = wk_trustInputCertificates(trust);
        if (!certificates) {
            CFRelease(archive.dictionary);
            return NULL;
        }
        SecTrustCopyPolicies(trust, &policies);
        wk_serializable_archive trustArchive = {
            CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks)
        };
        wk_archiveAddArray()(&trustArchive, CFSTR("certs"), certificates);
        if (policies)
            wk_archiveAddArray()(&trustArchive, CFSTR("policies"), policies);
        CFDictionarySetValue(archive.dictionary, CFSTR("trust"), trustArchive.dictionary);
        CFRelease(trustArchive.dictionary);
    }

    WKURLProtectionSpaceRef space = WK_SYSTEM(_CFURLProtectionSpaceCreateFromArchive)(kCFAllocatorDefault, archive.dictionary);
    CFRelease(archive.dictionary);
    if (space && trust) {
        SecTrustRef attached = WK_SYSTEM(CFURLProtectionSpaceGetServerTrust)(space);
        CFArrayRef anchors = NULL;
        Boolean networkFetchAllowed = false;
        CFAbsoluteTime verifyTime = SecTrustGetVerifyTime(trust);
        if (!attached || (policies && SecTrustSetPolicies(attached, policies) != errSecSuccess)
            || (SecTrustCopyCustomAnchorCertificates(trust, &anchors) == errSecSuccess && anchors
                && SecTrustSetAnchorCertificates(attached, anchors) != errSecSuccess)
            || (SecTrustGetNetworkFetchAllowed(trust, &networkFetchAllowed) == errSecSuccess
                && SecTrustSetNetworkFetchAllowed(attached, networkFetchAllowed) != errSecSuccess)) {
            CFRelease(space);
            space = NULL;
        }
        if (space && verifyTime) {
            CFDateRef date = CFDateCreate(kCFAllocatorDefault, verifyTime);
            if (SecTrustSetVerifyDate(attached, date) != errSecSuccess) {
                CFRelease(space);
                space = NULL;
            }
            CFRelease(date);
        }
        if (anchors)
            CFRelease(anchors);
    }
    if (policies)
        CFRelease(policies);
    return space;
}

// A CFURLCredential's payload begins with the vptr of the URLCredential subclass its kind selects, holds
// the kind at +0x20 -- CFURLCredentialGetCertificateIdentity tests that word against 3 -- and, for the
// server-trust kind, the trust URLCredentialServerTrust::initialize stores at +0x40 (measured on
// 10.9.5). Each read is checked before it is believed.
enum {
    kWKCredentialKindOffset = 0x20,
    kWKCredentialServerTrustOffset = 0x40,
    kWKCredentialKindServerTrust = 1,
};

// CFRuntimeBase precedes the native credential payload on this 64-bit runtime.
static const size_t kCFPayloadOffset = 2 * sizeof(void *);

// CFURLRequest's three flag bytes at +0x58 combine property values with assignment bits. The native
// setters place cookie, network-service, cellular, idle-sleep, pipelining, cache, timeout, proxy,
// SSL and synchronous-start assignment bits six positions above Foundation's explicitFlags bits.
enum { kWKRequestFlagsOffset = 0x58, kWKRequestExplicitFlagsMask = 0x17de };
WK_SYSTEM_FN("CFNetwork", CFTypeID, CFURLRequestGetTypeID, (void));

static const uint8_t *wk_requestFlags(CFTypeRef request)
{
    if (!request || CFGetTypeID(request) != WK_SYSTEM(CFURLRequestGetTypeID)())
        wk_patch_fail("NSURLRequest dictionary", "invalid native request layout");
    return (const uint8_t *)request + kWKRequestFlagsOffset;
}

uint16_t wk_requestExplicitFlags(CFTypeRef request)
{
    const uint8_t *bytes = wk_requestFlags(request);
    uint32_t flags = bytes[0] | (uint32_t)bytes[1] << 8 | (uint32_t)bytes[2] << 16;
    return (flags >> 6) & kWKRequestExplicitFlagsMask;
}

void wk_requestSetExplicitFlags(CFTypeRef request, uint16_t explicitFlags)
{
    uint8_t *bytes = (uint8_t *)wk_requestFlags(request);
    uint32_t flags = bytes[0] | (uint32_t)bytes[1] << 8 | (uint32_t)bytes[2] << 16;
    flags = (flags & ~((uint32_t)kWKRequestExplicitFlagsMask << 6))
        | ((uint32_t)(explicitFlags & kWKRequestExplicitFlagsMask) << 6);
    bytes[0] = (uint8_t)flags;
    bytes[1] = (uint8_t)(flags >> 8);
    bytes[2] = (uint8_t)(flags >> 16);
}

// CFNetwork's CFHTTPCookieStorage wrappers pass their CFRuntimeBase payload to HTTPCookieStorage.
// someCookiesAreSetForURL traverses the native domain index and the storage's inherited base jars.
bool wk_cookieStorageHasRecordsForURL(CFTypeRef storage, CFURLRef url)
{
    static bool (*hasRecords)(const void *, CFURLRef);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        wk_image image;
        wk_find_image(kCFNetworkSuffix, &image);
        hasRecords = wk_symbol_in_image(&image, "__ZN17HTTPCookieStorage23someCookiesAreSetForURLEPK7__CFURL");
    });
    if (!storage || !url)
        return false;
    return hasRecords((const uint8_t *)storage + kCFPayloadOffset, url);
}

// The domain entry point is the indexed lookup after CFNetwork's URL host normalization.
bool wk_cookieStorageHasRecordsForDomain(CFTypeRef storage, const char *domain)
{
    static bool (*hasRecords)(const void *, const char *);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        wk_image image;
        wk_find_image(kCFNetworkSuffix, &image);
        hasRecords = wk_symbol_in_image(&image, "__ZN17HTTPCookieStorage26someCookiesAreSetForDomainEPKc");
    });
    return storage && domain && hasRecords((const uint8_t *)storage + kCFPayloadOffset, domain);
}

// CFHTTPCookieGetFlags dispatches cookieHeader at vtable offset 0x38 on the
// CFRuntime payload. CompactHTTPCookieWithData's copy constructor uses the first
// word as the allocation and memcpy byte length.
const void *wk_cookieCompactBytes(CFTypeRef cookie, size_t *length)
{
    const void *payload = (const uint8_t *)cookie + kCFPayloadOffset;
    const void *const *vtable = *(const void *const *const *)payload;
    const uint8_t *bytes = ((const uint8_t *(*)(const void *))vtable[7])(payload);
    uint32_t encodedLength;
    memcpy(&encodedLength, bytes, sizeof(encodedLength));
    *length = encodedLength;
    return bytes;
}

static const uint8_t *wk_credentialPayload(CFTypeRef credential, size_t extent)
{
    if (!credential || CFGetTypeID(credential) != WK_SYSTEM(CFURLCredentialGetTypeID)())
        return NULL;
    if (malloc_size(credential) < kCFPayloadOffset + extent)
        return NULL;
    return (const uint8_t *)credential + kCFPayloadOffset;
}

int wk_credentialKind(CFTypeRef credential)
{
    const uint8_t *payload = wk_credentialPayload(credential, kWKCredentialKindOffset + sizeof(int32_t));
    return payload ? *(const int32_t *)(payload + kWKCredentialKindOffset) : -1;
}

SecTrustRef wk_credentialServerTrust(CFTypeRef credential)
{
    if (wk_credentialKind(credential) != kWKCredentialKindServerTrust)
        return NULL;
    const uint8_t *payload = wk_credentialPayload(credential, kWKCredentialServerTrustOffset + sizeof(void *));
    SecTrustRef trust = payload ? *(SecTrustRef *)(payload + kWKCredentialServerTrustOffset) : NULL;
    if (!trust || ((uintptr_t)trust & (sizeof(void *) - 1)) || !malloc_size(trust) || CFGetTypeID(trust) != SecTrustGetTypeID())
        return NULL;
    return trust;
}

// ---------------------------------------------------------------------------------------------------
// The MIME type of a file URL's response. 10.9's loader asks LaunchServices for the type the filename
// extension names, and LaunchServices gives none of wk_declared_types.h's types a MIME type, so a response it
// derives for one of those extensions is typed from the table, as the modern loader types it. A response
// a caller builds or retypes keeps the MIME type it was given, whatever its URL.
// ---------------------------------------------------------------------------------------------------

typedef const struct _CFURLResponse *CFURLResponseRef;
extern CFURLRef CFURLResponseGetURL(CFURLResponseRef);

WK_POLYFILL_REPLACES("CFNetwork", CFStringRef, CFURLResponseGetMIMEType, (CFURLResponseRef response))
{
    CFStringRef derived = response ? wkDerivedDeclaredMIMEType(response, CFURLResponseGetURL(response)) : NULL;
    return derived ? derived : WK_ORIGINAL(CFURLResponseGetMIMEType)(response);
}

WK_POLYFILL_REPLACES("CFNetwork", void, CFURLResponseSetMIMEType, (CFURLResponseRef response, CFStringRef mimeType))
{
    wkMarkGivenMIMEType(response);
    WK_ORIGINAL(CFURLResponseSetMIMEType)(response, mimeType);
}

WK_POLYFILL_REPLACES("CFNetwork", CFURLResponseRef, CFURLResponseCreate, (CFAllocatorRef allocator, CFURLRef url,
    CFStringRef mimeType, SInt64 expectedContentLength, CFStringRef textEncodingName, int cacheStoragePolicy))
{
    CFURLResponseRef response = WK_ORIGINAL(CFURLResponseCreate)(allocator, url, mimeType, expectedContentLength, textEncodingName, cacheStoragePolicy);
    wkMarkGivenMIMEType(response);
    return response;
}
