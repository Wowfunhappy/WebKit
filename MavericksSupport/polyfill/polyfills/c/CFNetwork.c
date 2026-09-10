// CFNetwork: entry points and constants modern WebKit references that 10.9's CFNetwork does not export,
// with native protection-space and credential coding.
#include "wk_polyfill.h"
#include "wk_symbols.h"
#include "wk_trust.h"
#include "wk_url_coding.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <malloc/malloc.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <syslog.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char kCFNetworkSuffix[] = "/CFNetwork.framework/Versions/A/CFNetwork";

WK_POLYFILL_CONST("CFNetwork", CFStringRef, kCFURLRequestContentDecoderSkipURLCheck, CFSTR("kCFURLRequestContentDecoderSkipURLCheck"));

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
// HTTP Strict Transport Security: 10.9's CFNetwork answers from the HSTS policy its own loader records.
// This build loads over curl, so the policies live in WebCore's store and that store is what the query
// asks for the application's own session. A named storage session keeps 10.9's own answer, which is
// the policy that session recorded.
// Resolved with dlsym: libpolyfill.a is force-loaded into every WebKit image, including ones that do
// not link WebCore, so a link-time reference to WebCore would make those images fail to link.
static const char kKnownHSTSHost[] = "CFNetwork HSTS host query";

typedef bool (*wk_hsts_query)(CFURLRef);

static wk_hsts_query wk_knownHSTSHostQuery(void)
{
    static wk_hsts_query query;
    if (!query) {
        query = (wk_hsts_query)dlsym(RTLD_DEFAULT, "WebCoreIsKnownHSTSHost");
        if (!query)
            wk_patch_fail(kKnownHSTSHost, "WebCore is not loaded in this process");
    }
    return query;
}

// NetworkStorageSession::deleteAllCookies clears a CF storage through this entry point. The storage's
// own handler reports that clear as a remove-all, which a subscriber cannot reconstruct from a diff:
// the jar it takes includes cookies no subscriber ever saw.
typedef struct OpaqueCFHTTPCookieStorage* CFHTTPCookieStorageRef;
typedef void (*wk_removed_all)(CFHTTPCookieStorageRef);

WK_POLYFILL_REPLACES("CFNetwork", void, CFHTTPCookieStorageDeleteAllCookies, (CFHTTPCookieStorageRef storage))
{
    WK_ORIGINAL(CFHTTPCookieStorageDeleteAllCookies)(storage);
    // Resolved with dlsym: the cookie observation lives in the WebCore-only half of the layer.
    static wk_removed_all notify;
    if (!notify)
        notify = (wk_removed_all)dlsym(RTLD_DEFAULT, "wk_cookieStorageDidRemoveAllCookies");
    if (notify)
        notify(storage);
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
static const char kProtectionSpaceCoding[] = "CFNetwork protection-space property list";

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
        if (!wk_find_image(kCFNetworkSuffix, &image))
            wk_patch_fail(kProtectionSpaceCoding, "CFNetwork is not loaded in this process");
        addArray = (wk_add_array_fn)wk_symbol_in_image(&image, "__ZN19SerializableArchive3addEPK10__CFStringPK9__CFArray");
        if (!addArray)
            wk_patch_fail(kProtectionSpaceCoding, "CFNetwork's symbol table does not name the archive writer this calls");
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
