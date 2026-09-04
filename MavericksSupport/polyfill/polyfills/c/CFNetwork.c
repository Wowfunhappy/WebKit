// CFNetwork: entry points and constants modern WebKit references that 10.9's CFNetwork does not export,
// and a load-time patch of one CFNetwork constant in the network process.
#include "wk_cookie_storage.h"
#include "wk_polyfill.h"
#include "wk_samesite.h"
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

// Undeclared POST bodies. A POST body whose media type the sender does not know goes out with no
// Content-Type field, which is what modern CFNetwork does, what the Fetch specification asks for (a
// BufferSource body contributes no type, so FetchBody::extract sets none), and what a working
// reference browser on this host sends to a licence endpoint that rejects the alternative. 10.9's
// CFNetwork instead announces such a body as application/x-www-form-urlencoded, so a server that
// parses the body as form data receives one that is not.
//
// The field is synthesised in HTTPProtocol::_createMutableCanonicalRequest, below every request
// object: it is absent from originalRequest, from currentRequest, and from currentRequest after the
// load starts, and appears only on the wire. So there is no request for WebCore or a method
// replacement to correct, and no API expresses it either -- every body-carrying shape on 10.9
// (HTTPBody, HTTPBodyStream, uploadTaskWithRequest:fromData:, uploadTaskWithStreamedRequest: whose
// request carries no body at all, and setting then deleting the field) is stamped identically,
// CFNetwork exports no property or key that suppresses it, and the canonicaliser consults none.
//
// What it does is three instructions:
//
//     movq  _kCFHTTPHeaderContentType(%rip), %rsi           ; field name
//     movq  _kCFHTTPProtocolDefaultFormMimeType(%rip), %rdx ; value
//     callq _CFURLRequestSetHTTPHeaderFieldValue
//
// and that setter, measured here, *removes* the field when the value is NULL. Clearing the constant
// therefore makes CFNetwork's own code delete Content-Type where it would otherwise invent one. No
// value is substituted: the result is the field's absence, which is the behaviour being restored.
// A declared type is untouched, because the canonicaliser only reaches these instructions when the
// field is absent.
//
// The constant is non-external, so nothing links to it and no interposition reaches the call, which
// is direct and intra-image. It is reached through wk_symbols.h, by name and never by offset, and it
// is cleared only once the value it holds has been confirmed to be the media type described here.
//
// THE MAINTAINER APPROVED THIS PATCH EXPLICITLY, AS AN EXCEPTION TO OUR STANDARD POLICY, AND IT STANDS
// ONLY FOR THIS ONE CONSTANT IN THIS ONE PROCESS. wk_symbols.h IS NOT A GENERAL TOOL: EVERY OTHER USE
// OF IT NEEDS THE MAINTAINER'S EXPLICIT APPROVAL OF ITS OWN, AND NONE OF THEM MAY BE ADDED OR REMOVED
// WITHOUT ONE (MavericksSupport/polyfill/README.md carries the same rule).
static const char kFormMediaType[] = "application/x-www-form-urlencoded";

// The network process is the only one whose HTTP requests are all WebKit's, so it is the only one the
// media-type patch below runs in: a host application loading WebKit keeps the CFNetwork it had for the
// requests it makes itself.
static bool isWebKitNetworkProcess(void)
{
    const char *name = getprogname();
    return name && !strcmp(name, "com.apple.WebKit.Networking");
}

// The constant is a compiler-built CFString: { isa, flags, const char *bytes, length }. Reading it
// that way keeps this constructor free of CoreFoundation, which a dyld initializer cannot assume is
// initialised yet -- a CF call here answers for the state of CF, not for the state of the constant.
struct constantCFString {
    const void *isa;
    unsigned long flags;
    const char *bytes;
    unsigned long length;
};

static bool holdsTheFormMediaType(const void *value)
{
    const struct constantCFString *string = (const struct constantCFString *)value;
    return string && string->bytes && string->length == strlen(kFormMediaType)
        && !strcmp(string->bytes, kFormMediaType);
}

__attribute__((constructor)) static void clearDefaultFormMediaType(void)
{
    static const wk_pointer_patch patch = {
        .what = "CFNetwork undeclared-post-body patch",
        .imagePathSuffix = kCFNetworkSuffix,
        .symbol = "_kCFHTTPProtocolDefaultFormMimeType",
        .isInScope = isWebKitNetworkProcess,
        .describes = holdsTheFormMediaType,
        .replacement = NULL,
    };
    wk_patch_pointer(&patch);
}

// ---------------------------------------------------------------------------------------------------
// The accept policy the process's own cookie jar starts with.
//
// 10.9 hands the process's default cookie storage over set to kCFHTTPCookieStorageAcceptPolicyNever,
// where CFNetwork's documented default -- the value every caller of these APIs is written against -- is
// Always. (A storage created for a session of its own is a different case and is left alone: it starts
// at OnlyFromMainDocumentDomain, and WebCore::createPrivateStorageSession sets the policy its creator
// chose on it immediately.) A normal NSURLSession load never notices the default jar's value, because
// 10.9 stamps the session configuration's own policy onto each request and reads the storage's only as
// a fallback; WebKit does notice, because NetworkSessionCocoa marks the storage authoritative over the
// configuration (-_overrideSessionCookieAcceptPolicy) and then only READS the policy, and because
// WebKitLegacy's DOM cookie writes go straight to this jar. Left as 10.9 hands it over, no response and
// no script can store a cookie.
//
// The policy belongs to the handle rather than to the store, so the correction is made on each handle
// on this jar as it is handed over, once, before anybody has had it to choose a policy on: a policy set
// afterwards -- Safari's Privacy radio through WebCookieManagerMac, WKHTTPCookieStore's
// setCookiePolicy: -- is the answer from then on.
static const char kCookieAcceptPolicyKey[] = "wk cookie accept policy defaulted";

enum { kWKCookieAcceptPolicyAlways = 0, kWKCookieAcceptPolicyNever = 1 };

WK_SYSTEM_FN("CFNetwork", CFIndex, CFHTTPCookieStorageGetCookieAcceptPolicy, (CFTypeRef));
WK_SYSTEM_FN("CFNetwork", void, CFHTTPCookieStorageSetCookieAcceptPolicy, (CFTypeRef, CFIndex));

void wk_giveTheProcessCookieJarItsDefaultAcceptPolicy(CFTypeRef storage)
{
    if (!storage || objc_getAssociatedObject((id)storage, kCookieAcceptPolicyKey))
        return;
    objc_setAssociatedObject((id)storage, kCookieAcceptPolicyKey, (id)kCFBooleanTrue, OBJC_ASSOCIATION_ASSIGN);
    if (WK_SYSTEM(CFHTTPCookieStorageGetCookieAcceptPolicy)(storage) == kWKCookieAcceptPolicyNever)
        WK_SYSTEM(CFHTTPCookieStorageSetCookieAcceptPolicy)(storage, kWKCookieAcceptPolicyAlways);
}

// The C half of the two ways WebKit reaches this jar: NetworkStorageSession reads the default storage
// straight through this entry point (its ObjC twin is +[NSHTTPCookieStorage sharedHTTPCookieStorage],
// replaced in methods/Foundation.m). The replacement covers WebKit's images only -- the archive is
// static and hidden -- so a host application's own default storage is untouched.
WK_POLYFILL_REPLACES("CFNetwork", CFTypeRef, _CFHTTPCookieStorageGetDefault, (CFAllocatorRef allocator))
{
    CFTypeRef storage = WK_ORIGINAL(_CFHTTPCookieStorageGetDefault)(allocator);
    wk_giveTheProcessCookieJarItsDefaultAcceptPolicy(storage);
    return storage;
}

// ---------------------------------------------------------------------------------------------------
// An HttpOnly cookie is not the public API's to replace or to delete.
//
// Later CFNetwork ignores a public-API set or delete whose cookie is not itself HttpOnly when the store
// holds an HttpOnly cookie of the same name, domain and path -- the rule WKHTTPCookieStore's
// setCookie:/deleteCookie: are written against, and the one upstream's WKHTTPCookieStore.HttpOnly
// asserts. 10.9 lets either through. The two entry points a caller reaches are the CF pair below and
// -[NSHTTPCookieStorage setCookie:]/-deleteCookie: (methods/Foundation.m), which cover the CF pair
// through Foundation's own call rather than through this archive; both ask the rule here.
// NetworkStorageSession takes the CF route whenever a session has a cookie storage of its own and the
// ObjC route otherwise, so a rule on either alone would be a rule for one kind of data store.
//
// A response's cookies do not come through here: CFNetwork stores those from the protocol layer, where
// the restriction does not apply.
WK_SYSTEM_FN("CFNetwork", CFArrayRef, CFHTTPCookieStorageCopyCookies, (CFTypeRef));
WK_SYSTEM_FN("CFNetwork", CFStringRef, CFHTTPCookieCopyName, (CFTypeRef));
WK_SYSTEM_FN("CFNetwork", CFStringRef, CFHTTPCookieCopyDomain, (CFTypeRef));
WK_SYSTEM_FN("CFNetwork", CFStringRef, CFHTTPCookieCopyPath, (CFTypeRef));
WK_SYSTEM_FN("CFNetwork", Boolean, CFHTTPCookieIsHTTPOnly, (CFTypeRef));
WK_SYSTEM_FN("CFNetwork", Boolean, CFHTTPCookieIsSecure, (CFTypeRef));
WK_SYSTEM_FN("CFNetwork", CFStringRef, CFHTTPCookieCopyValue, (CFTypeRef));

static bool wk_stringsMatch(CFStringRef a, CFStringRef b, CFStringCompareFlags flags)
{
    if (!a || !b)
        return a == b;
    return CFStringCompare(a, b, flags) == kCFCompareEqualTo;
}

// Whether a caller that is not the protocol layer may set or delete |cookie| in |storage|: it may,
// unless the store holds an HttpOnly cookie of the same name, domain and path and this cookie is not
// itself HttpOnly. Asking again for the same operation is safe: a delete that was refused leaves the
// stored cookie in place and is refused identically, and one that went through leaves no match, which
// is the answer for a cookie the store does not hold. -[NSHTTPCookieStorage deleteCookie:] reaches
// CFHTTPCookieStorageDeleteCookie twice, the second time on the base storage.
bool wk_publicCallerMayChangeCookie(CFTypeRef storage, CFStringRef name, CFStringRef domain, CFStringRef path, bool cookieIsHTTPOnly)
{
    if (cookieIsHTTPOnly || !storage || !name)
        return true;

    CFArrayRef cookies = WK_SYSTEM(CFHTTPCookieStorageCopyCookies)(storage);
    CFIndex count = cookies ? CFArrayGetCount(cookies) : 0;
    bool mayChange = true;
    for (CFIndex i = 0; i < count && mayChange; ++i) {
        CFTypeRef stored = CFArrayGetValueAtIndex(cookies, i);
        if (!WK_SYSTEM(CFHTTPCookieIsHTTPOnly)(stored))
            continue;
        CFStringRef storedName = WK_SYSTEM(CFHTTPCookieCopyName)(stored);
        CFStringRef storedDomain = WK_SYSTEM(CFHTTPCookieCopyDomain)(stored);
        CFStringRef storedPath = WK_SYSTEM(CFHTTPCookieCopyPath)(stored);
        if (wk_stringsMatch(storedName, name, 0)
            && wk_stringsMatch(storedDomain, domain, kCFCompareCaseInsensitive)
            && wk_stringsMatch(storedPath, path, 0))
            mayChange = false;
        if (storedName)
            CFRelease(storedName);
        if (storedDomain)
            CFRelease(storedDomain);
        if (storedPath)
            CFRelease(storedPath);
    }
    if (cookies)
        CFRelease(cookies);
    return mayChange;
}

static bool wk_publicCallerMayChangeCFCookie(CFTypeRef storage, CFTypeRef cookie)
{
    if (!cookie)
        return true;
    CFStringRef name = WK_SYSTEM(CFHTTPCookieCopyName)(cookie);
    CFStringRef domain = WK_SYSTEM(CFHTTPCookieCopyDomain)(cookie);
    CFStringRef path = WK_SYSTEM(CFHTTPCookieCopyPath)(cookie);
    bool mayChange = wk_publicCallerMayChangeCookie(storage, name, domain, path,
        WK_SYSTEM(CFHTTPCookieIsHTTPOnly)(cookie));
    if (name)
        CFRelease(name);
    if (domain)
        CFRelease(domain);
    if (path)
        CFRelease(path);
    return mayChange;
}

WK_POLYFILL_REPLACES("CFNetwork", void, CFHTTPCookieStorageSetCookie, (CFTypeRef storage, CFTypeRef cookie))
{
    if (wk_publicCallerMayChangeCFCookie(storage, cookie))
        WK_ORIGINAL(CFHTTPCookieStorageSetCookie)(storage, cookie);
}

WK_POLYFILL_REPLACES("CFNetwork", void, CFHTTPCookieStorageDeleteCookie, (CFTypeRef storage, CFTypeRef cookie))
{
    if (wk_publicCallerMayChangeCFCookie(storage, cookie))
        WK_ORIGINAL(CFHTTPCookieStorageDeleteCookie)(storage, cookie);
}

// ---------------------------------------------------------------------------------------------------
// SameSite, where 10.9 decides cookies.
//
// CFNetwork-673.3 has never heard of the attribute -- it contains no occurrence of the name in its
// strings or its symbols -- and it composes the Cookie header of a request and parses the Set-Cookie of
// a response entirely below the Objective-C layer, so neither can be reached from there. What can be
// reached is the two virtual calls those paths make. HTTPProtocol::addCookies calls the connection
// session's copyCookiesForRequestUsingAllAppropriateStorageSemantics, which selects the storage, merges
// any additional cookies the request carries, and then asks the storage for the cookies of a URL through
// XCookieStorage::copyRequestHeaderFieldsForURL before composing the header from them.
// HTTPProtocol::updateCookieStoreDuringHeaderRead calls the storage's setCookiesWithResponseHeaderFields
// with the response's raw header fields, which is the last point at which the attribute is still there
// to read.
//
// So the outer replacement reads the request's cookie-policy context and leaves it where the inner one
// can see it, the inner one subtracts the cookies that context withholds, and CFNetwork's own code does
// the selecting, the merging and the composing. The storing replacement puts the attribute into the
// Comment field of the header it is given and hands it on, so CFNetwork applies the accept policy,
// parses and stores exactly once, with the cookie's Created assigned exactly once.
//
// The two sides are scoped differently because what they can see differs. Reading scopes itself to a
// request: a request carries the cookie-policy properties only because ResourceRequestCocoa's
// doUpdatePlatformRequest put them there, and the key naming them appears nowhere in 10.9's CFNetwork
// or Foundation, so nothing but WebKit can put one on a request. A request made by a host application
// around WebKit therefore has no context stashed for it and reaches the implementation this stands in
// for with nothing subtracted. That is a per-request boundary, and it is what covers a WebKitLegacy
// load, which is composed by this same CFNetwork code inside the application's own process.
//
// Storing has no such boundary to draw. HTTPProtocol::updateCookieStoreDuringHeaderRead holds the
// request, but neither it nor performHeaderRead nor updateForHeader occupies a vtable slot anywhere in
// this image, and the storage this replacement is handed names no requester. So it marks every response
// the process receives, and marks only a restriction: an attribute reading "None", or a value the
// modern constants do not name, restricts nothing, and its field is left exactly as the server sent it.
// A cookie the host application's own response set is withheld from nothing -- the read side subtracts
// only from a request WebKit stamped -- and carries the encoded comment, which this layer's readers
// decode and a reader outside it reads as it stands.
// ---------------------------------------------------------------------------------------------------

typedef const struct OpaqueCFHTTPCookie *WKHTTPCookieRef;
typedef const struct _CFURLRequest *WKCFURLRequestRef;
WK_SYSTEM_FN("CFNetwork", CFStringRef, CFHTTPCookieCopyComment, (WKHTTPCookieRef));
WK_SYSTEM_FN("CFNetwork", CFTypeRef, _CFURLRequestCopyProtocolPropertyForKey, (WKCFURLRequestRef, CFStringRef));
WK_SYSTEM_FN("CFNetwork", CFStringRef, CFURLRequestCopyHTTPRequestMethod, (WKCFURLRequestRef));
WK_SYSTEM_FN("CFNetwork", CFURLRef, CFURLRequestGetURL, (WKCFURLRequestRef));

// A CF object's payload -- the C++ object CFObject::Allocate answers with, and the `this` a CFNetwork
// C++ method takes -- begins one CF header into the object.
static const size_t kCFPayloadOffset = 2 * sizeof(void *);
typedef CFTypeID (*wk_type_id_fn)(void);
static wk_type_id_fn wk_CFHTTPCookieStorageGetTypeID;

static const char kSameSiteHooks[] = "CFNetwork SameSite cookie hooks";

// The context one composition runs under. The inner replacement is handed a storage and a URL and no
// request, so the outer one leaves this where it can read it.
struct wk_cookie_context {
    bool known;
    bool isSameSite;
    bool isTopLevelNavigation;
    bool isSafeMethod;
};
static __thread struct wk_cookie_context wk_cookieContext;

static bool wk_booleanValue(CFTypeRef value)
{
    if (!value)
        return false;
    if (CFGetTypeID(value) == CFBooleanGetTypeID())
        return CFBooleanGetValue((CFBooleanRef)value);
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        int number = 0;
        return CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &number) && number;
    }
    return false;
}

static struct wk_cookie_context wk_contextOfRequest(WKCFURLRequestRef request)
{
    struct wk_cookie_context context = { false, false, false, false };
    if (!request)
        return context;

    CFTypeRef site = WK_SYSTEM(_CFURLRequestCopyProtocolPropertyForKey)(request, CFSTR("_kCFHTTPCookiePolicyPropertySiteForCookies"));
    if (site) {
        if (CFGetTypeID(site) == CFURLGetTypeID()) {
            context.known = true;
            // Derived again here rather than read off the stamp: CFNetwork carries these properties
            // across an internal redirect verbatim while the URL changes host, so the stamp answers for
            // the hop that made it.
            context.isSameSite = wk_sameSiteURLsAreSameSite((CFURLRef)site, WK_SYSTEM(CFURLRequestGetURL)(request));
        }
        CFRelease(site);
    }
    if (!context.known)
        return context;

    CFTypeRef topLevel = WK_SYSTEM(_CFURLRequestCopyProtocolPropertyForKey)(request, CFSTR("_kCFHTTPCookiePolicyPropertyIsTopLevelNavigation"));
    context.isTopLevelNavigation = wk_booleanValue(topLevel);
    if (topLevel)
        CFRelease(topLevel);

    CFStringRef method = WK_SYSTEM(CFURLRequestCopyHTTPRequestMethod)(request);
    context.isSafeMethod = wk_sameSiteMethodIsSafe(method);
    if (method)
        CFRelease(method);
    return context;
}

// One replacement serves every cookie-storage class, so a storage's vptr is what it finds the
// implementation it stands in for by.
struct wk_storage_hook {
    const void *vtable;
    void *copyCookiesForURL;
    void *setCookiesWithResponseHeaderFields;
    // Where the class keeps the CFHTTPCookieStorage its store method hands the work to, or 0 for a
    // class that does the work itself and reaches no HTTPCookieStorage.
    long cookieStorageField;
};
static struct wk_storage_hook wk_storageHooks[3];
static long wk_storageHookCount;

static const struct wk_storage_hook *wk_hookForStorage(const void *storage)
{
    const void *vtable = *(const void *const *)storage;
    for (long i = 0; i < wk_storageHookCount; ++i) {
        if (wk_storageHooks[i].vtable == vtable)
            return &wk_storageHooks[i];
    }
    wk_patch_fail(kSameSiteHooks, "a cookie storage reached a replacement installed on another class");
}

typedef CFArrayRef (*wk_copy_cookies_for_url_fn)(const void *storage, CFURLRef url, unsigned char secure);
typedef void (*wk_set_cookies_fn)(const void *storage, CFURLRef url, CFDictionaryRef headerFields,
                                  CFURLRef mainDocumentURL, int acceptPolicy);
typedef CFDictionaryRef (*wk_copy_cookies_for_request_fn)(const void *session, WKCFURLRequestRef request);

static wk_copy_cookies_for_request_fn wk_originalCopyCookiesForRequest;

static CFDictionaryRef wk_copyCookiesForRequest(const void *session, WKCFURLRequestRef request)
{
    struct wk_cookie_context enclosing = wk_cookieContext;
    wk_cookieContext = wk_contextOfRequest(request);
    CFDictionaryRef fields = wk_originalCopyCookiesForRequest(session, request);
    // Put back rather than cleared, on the one way out there is: a context left behind on this thread
    // would let a Strict cookie ride the next read made on it.
    wk_cookieContext = enclosing;
    return fields;
}

// RFC 6265bis 5.5's send order, applied where CFNetwork composes a request's Cookie header. A stable
// pass, so cookies of equal path length keep the order the storage gave; |cookies| is consumed.
static CFArrayRef wk_cookiesInSendOrderCreate(CFArrayRef cookies)
{
    CFIndex count = CFArrayGetCount(cookies);
    bool ordered = true;
    for (CFIndex i = 1; i < count && ordered; ++i) {
        CFStringRef path = WK_SYSTEM(CFHTTPCookieCopyPath)(CFArrayGetValueAtIndex(cookies, i));
        CFStringRef before = WK_SYSTEM(CFHTTPCookieCopyPath)(CFArrayGetValueAtIndex(cookies, i - 1));
        ordered = !wk_cookiePathSortsFirst(path, before);
        if (path)
            CFRelease(path);
        if (before)
            CFRelease(before);
    }
    if (ordered)
        return cookies;

    CFMutableArrayRef sorted = CFArrayCreateMutable(NULL, count, &kCFTypeArrayCallBacks);
    if (!sorted)
        wk_patch_fail(kSameSiteHooks, "a read's cookies did not fit in memory to be ordered");
    // Insertion by the rule: each cookie goes after every one whose path is not shorter, which keeps
    // equal-length paths in the order they arrived however many of them there are.
    for (CFIndex i = 0; i < count; ++i) {
        const void *cookie = CFArrayGetValueAtIndex(cookies, i);
        CFStringRef path = WK_SYSTEM(CFHTTPCookieCopyPath)(cookie);
        CFIndex at = CFArrayGetCount(sorted);
        while (at > 0) {
            CFStringRef seated = WK_SYSTEM(CFHTTPCookieCopyPath)(CFArrayGetValueAtIndex(sorted, at - 1));
            bool goesBefore = wk_cookiePathSortsFirst(path, seated);
            if (seated)
                CFRelease(seated);
            if (!goesBefore)
                break;
            --at;
        }
        if (path)
            CFRelease(path);
        CFArrayInsertValueAtIndex(sorted, at, cookie);
    }
    CFRelease(cookies);
    return sorted;
}

static CFArrayRef wk_copyCookiesForURL(const void *storage, CFURLRef url, unsigned char secure)
{
    wk_copy_cookies_for_url_fn original = (wk_copy_cookies_for_url_fn)wk_hookForStorage(storage)->copyCookiesForURL;
    CFArrayRef cookies = original(storage, url, secure);
    if (!cookies)
        return cookies;

    // This slot is what CFNetwork composes a request's Cookie header through, so the path rule holds for
    // every caller of it. The SameSite rule is a property of the read: a same-site one lets every cookie
    // ride whatever its policy says (wk_sameSiteAllows), so only a cross-site read pays the per-cookie
    // comment scan.
    bool applySameSite = wk_cookieContext.known && !wk_cookieContext.isSameSite;
    CFStringRef requestPath = wk_requestPathCreate(url);

    CFIndex count = CFArrayGetCount(cookies);
    CFMutableArrayRef allowed = NULL;
    for (CFIndex i = 0; i < count; ++i) {
        const void *cookie = CFArrayGetValueAtIndex(cookies, i);
        CFStringRef cookiePath = WK_SYSTEM(CFHTTPCookieCopyPath)((CFTypeRef)cookie);
        bool rides = wk_cookiePathMatchesRequestPath(cookiePath, requestPath);
        if (cookiePath)
            CFRelease(cookiePath);
        if (rides && applySameSite) {
            CFStringRef comment = WK_SYSTEM(CFHTTPCookieCopyComment)((WKHTTPCookieRef)cookie);
            rides = wk_sameSiteAllows(wk_sameSitePolicyOfComment(comment), wk_cookieContext.isSameSite,
                                      wk_cookieContext.isTopLevelNavigation, wk_cookieContext.isSafeMethod);
            if (comment)
                CFRelease(comment);
        }
        if (rides) {
            if (allowed)
                CFArrayAppendValue(allowed, cookie);
            continue;
        }
        if (!allowed) {
            allowed = CFArrayCreateMutable(NULL, count, &kCFTypeArrayCallBacks);
            if (!allowed)
                wk_patch_fail(kSameSiteHooks, "a read's surviving cookies did not fit in memory");
            for (CFIndex kept = 0; kept < i; ++kept)
                CFArrayAppendValue(allowed, CFArrayGetValueAtIndex(cookies, kept));
        }
    }
    CFRelease(requestPath);
    if (allowed) {
        CFRelease(cookies);
        cookies = allowed;
    }
    return wk_cookiesInSendOrderCreate(cookies);
}

// The field name a response carries Set-Cookie under, in whatever case it arrived in.
static CFStringRef wk_setCookieFieldName(CFDictionaryRef fields)
{
    // The canonical spelling first: one hash probe answers nearly every response (most carry no
    // Set-Cookie at all, and CFNetwork canonicalizes the ones that do), and only an uncanonical
    // spelling pays the key-vector scan below.
    if (CFDictionaryGetValue(fields, CFSTR("Set-Cookie")))
        return CFSTR("Set-Cookie");
    CFIndex count = CFDictionaryGetCount(fields);
    if (count <= 0)
        return NULL;
    const void **keys = (const void **)malloc(sizeof(void *) * (size_t)count);
    if (!keys)
        return NULL;
    CFDictionaryGetKeysAndValues(fields, keys, NULL);
    CFStringRef name = NULL;
    for (CFIndex i = 0; i < count && !name; ++i) {
        if (CFGetTypeID(keys[i]) == CFStringGetTypeID()
            && CFStringCompare((CFStringRef)keys[i], CFSTR("Set-Cookie"), kCFCompareCaseInsensitive) == kCFCompareEqualTo)
            name = (CFStringRef)keys[i];
    }
    free(keys);
    return name;
}

// NSHTTPCookieAcceptPolicyOnlyFromMainDocumentDomain, as the accept policy reaches the slots below.
enum { kOnlyFromMainDocumentDomain = 2 };

// HTTPCookieStorage::someCookiesAreSetForURL, the question itself rather than one shaped like it: it
// takes the URL's host, lowercases it and asks someCookiesAreSetForDomain, where the read slot above
// would also have matched the path (lookupAndCopyCookies is a strlen bound and a strncmp). It takes the
// C++ storage, which begins one CF header into the CFHTTPCookieStorage the class holds.
typedef unsigned char (*wk_some_cookies_are_set_fn)(const void *storage, CFURLRef url);
static wk_some_cookies_are_set_fn wk_someCookiesAreSetForURL;

static bool wk_storageHoldsCookiesForURL(const void *storage, CFURLRef url)
{
    long field = wk_hookForStorage(storage)->cookieStorageField;
    if (!field)
        return true;
    CFTypeRef cookieStorage = *(CFTypeRef *)((const char *)storage + field);
    if (!cookieStorage || !wk_CFHTTPCookieStorageGetTypeID
        || CFGetTypeID(cookieStorage) != wk_CFHTTPCookieStorageGetTypeID())
        wk_patch_fail(kSameSiteHooks, "a cookie storage class does not hold a cookie storage where this reads one");
    return wk_someCookiesAreSetForURL((const char *)cookieStorage + kCFPayloadOffset, url);
}

static void wk_setCookiesWithResponseHeaderFields(const void *storage, CFURLRef url, CFDictionaryRef headerFields,
                                                  CFURLRef mainDocumentURL, int acceptPolicy)
{
    wk_set_cookies_fn original = (wk_set_cookies_fn)wk_hookForStorage(storage)->setCookiesWithResponseHeaderFields;
    if (!original)
        wk_patch_fail(kSameSiteHooks, "a cookie storage class this only reads through was stored to");

    // NSHTTPCookieAcceptPolicyOnlyFromMainDocumentDomain, the policy Safari's "Block cookies: from third
    // parties and advertisers" sets, holds a response's cookies to the main document's own domain:
    // HTTPCookieStorage::setCookiesWithResponseHeaderFields takes them when the storage already holds
    // cookies for the URL, when there is no main document, or when isURLInMainDocumentDomain says the
    // two hosts share more than a top-level domain. That last answer comes from a 2013 table of
    // top-level domains, so a third party under any label registered since is read as the main
    // document's own domain. Only the hosts 10.9's table cannot know about are answered here
    // (wk_hostsShareOnlyATopLevelDomain), and only where 10.9 would have taken the cookies, so this
    // subtracts from what is stored and never adds.
    if (acceptPolicy == kOnlyFromMainDocumentDomain && mainDocumentURL
        && wk_hostsShareOnlyATopLevelDomain(url, mainDocumentURL)
        && !wk_storageHoldsCookiesForURL(storage, url))
        return;

    CFStringRef name = headerFields ? wk_setCookieFieldName(headerFields) : NULL;
    CFTypeRef header = name ? CFDictionaryGetValue(headerFields, name) : NULL;
    if (!header || CFGetTypeID(header) != CFStringGetTypeID()) {
        original(storage, url, headerFields, mainDocumentURL, acceptPolicy);
        return;
    }

    // Everything the field is held to, in one pass (wk_storableSetCookieFieldCreate, c/wk_samesite.c):
    // the control-character rule, the cookies that may not be set at all, the lifetime ceiling and the
    // SameSite attribute. A field whose every cookie was refused is not passed on.
    bool setsNothing = false;
    CFStringRef storable = wk_storableSetCookieFieldCreate((CFStringRef)header, url, &setsNothing);
    if (setsNothing)
        return;
    if (!storable) {
        original(storage, url, headerFields, mainDocumentURL, acceptPolicy);
        return;
    }

    CFMutableDictionaryRef replaced = CFDictionaryCreateMutableCopy(NULL, 0, headerFields);
    if (!replaced)
        wk_patch_fail(kSameSiteHooks, "the response header fields carrying the attribute could not be copied");
    CFDictionarySetValue(replaced, name, storable);
    original(storage, url, replaced, mainDocumentURL, acceptPolicy);
    CFRelease(replaced);
    CFRelease(storable);
}

// ---------------------------------------------------------------------------------------------------
// Cookie change reporting. HTTPCookieStorage::setCookie, ::deleteCookie and ::deleteAllCookies take the
// storage's mutex and call the backend's setCookieInternalLocked(CompactCookieHeader const*),
// deleteCookieInternalLocked and deleteAllCookiesLocked, and every write a process makes to a jar --
// a response's Set-Cookie fields, -setCookies:forURL:mainDocumentURL:, -setCookie:, -deleteCookie:,
// CFHTTPCookieStorageDeleteAllCookies -- ends in one of those three. A file-backed storage also takes
// in what another process wrote to its file, in bulk, when syncStorageWithCompletionLocked merges the
// file and replays its journal; that boundary is reported from below. Neither mutation slot answers
// what a subscriber is told: the set slot answers that the write was accepted, which a store over an
// identical cookie is too, and the delete slot answers whether a cookie was there to remove only on
// DiskCookieStorage and MemoryCookieStorage -- ExternalCookieStorage, the backend the process's own jar
// is built on, and NSCFPrivateCookieStorage both return a hardcoded 1. wk_backendStoredCookieCreate
// asks the storage itself, before either slot, for the cookie it holds under this one's identity. That
// read costs External a synchronous cookied round trip, since its set and delete both invalidate the
// per-domain cache, so it is made only when a subscriber is there to be told and the answer is used.
// The cookie is rebuilt from the header and handed to WKPolyfillCookieWatcher
// (methods/Foundation.m) through the runtime: the framework whose copy of this claimed the slots is not
// necessarily the one carrying the watcher. NSCFPrivateCookieStorage::setCookieInternalLocked builds a
// cookie and sends it to a delegate from inside this same slot, so an Objective-C call made here is one
// the storage's own mutex is already held across.
static const char kCookieChangeHooks[] = "CFNetwork cookie change hooks";

struct wk_backend_hook {
    const void *vtable;
    void *setCookieInternalLocked;
    void *deleteCookieInternalLocked;
    void *deleteAllCookiesLocked;
    // The cookies the storage holds for one domain, which is the answer the delete slots withhold.
    void *copyDomainCookieArrayLocked;
    // Set only for the backends whose sync merges a file another process may have written.
    void *visitCookiesLocked;
    void *syncStorageWithCompletionLocked;
};
static struct wk_backend_hook wk_backendHooks[5];
static long wk_backendHookCount;

static const struct wk_backend_hook *wk_backendHookFor(const void *backend)
{
    const void *vtable = *(const void *const *)backend;
    for (long i = 0; i < wk_backendHookCount; ++i) {
        if (wk_backendHooks[i].vtable == vtable)
            return &wk_backendHooks[i];
    }
    return NULL;
}

typedef unsigned char (*wk_compact_cookie_fn)(const void *backend, const void *header);
typedef void (*wk_delete_all_cookies_fn)(const void *backend);
typedef void (*wk_visit_cookies_fn)(const void *backend, void (^visitor)(const void *header));
typedef void (*wk_sync_storage_fn)(const void *backend, unsigned char flags, void (^completion)(void));
typedef const void *(*wk_cf_class_fn)(void);
typedef void *(*wk_cf_object_allocate_fn)(unsigned long size, const void *cfClass, CFAllocatorRef allocator);
typedef void (*wk_compact_cookie_ctor_fn)(void *payload, const void *header);
typedef CFAbsoluteTime (*wk_cookie_time_fn)(CFTypeRef cookie);

static wk_cf_class_fn wk_HTTPCookieClass;
static wk_cf_object_allocate_fn wk_CFObjectAllocate;
static wk_compact_cookie_ctor_fn wk_constructCompactHTTPCookieWithData;
static wk_cookie_time_fn wk_CFHTTPCookieGetCreationTime;
static wk_cookie_time_fn wk_CFHTTPCookieGetExpirationTime;

// The cookie a stored header describes, built the way NSCFPrivateCookieStorage::setCookieInternalLocked
// builds the one it hands its delegate: CFObject::Allocate(0x18, HTTPCookie::Class(), allocator), the
// CompactHTTPCookieWithData constructor over the payload, and the CF object the payload sits inside.
static CFTypeRef wk_copyCookieFromCompactHeader(const void *header)
{
    void *payload = wk_CFObjectAllocate(0x18, wk_HTTPCookieClass(), kCFAllocatorDefault);
    if (!payload)
        return NULL;
    wk_constructCompactHTTPCookieWithData(payload, header);
    return (CFTypeRef)((const uint8_t *)payload - kCFPayloadOffset);
}

// CFHTTPCookieStorageSetCookie hands HTTPCookieStorage::setCookie the storage's payload, and setCookie
// dispatches to the backend two words into that payload.
const void *wk_cookieStorageBackend(CFTypeRef storage)
{
    if (!wk_CFHTTPCookieStorageGetTypeID)
        wk_patch_fail(kCookieChangeHooks, "a cookie storage was reached before the cookie hooks were installed");
    if (!storage || CFGetTypeID(storage) != wk_CFHTTPCookieStorageGetTypeID())
        wk_patch_fail(kCookieChangeHooks, "a cookie change watcher was asked for something that is not a cookie storage");
    const uint8_t *wrapper = (const uint8_t *)storage + kCFPayloadOffset;
    const void *backend = *(const void *const *)(wrapper + 2 * sizeof(void *));
    if (!backend || !wk_backendHookFor(backend))
        wk_patch_fail(kCookieChangeHooks, "a cookie storage's backend is not one of the classes this patches");
    return backend;
}

static void wk_reportCookieChange(const void *backend, CFTypeRef cookie, enum wk_cookie_change change)
{
    static SEL report;
    static Class watcherClass;
    if (!watcherClass) {
        Class found = objc_getClass("WKPolyfillCookieWatcher");
        if (!found)
            return;
        report = sel_registerName("reportCookie:ofStorage:change:");
        watcherClass = found;
    }
    ((void (*)(id, SEL, CFTypeRef, const void *, int))objc_msgSend)((id)watcherClass, report, cookie, backend, (int)change);
}

// The two sides of a merge, which the watcher tells apart per subscribed host.
static void wk_reportCookieMerge(const void *backend, CFArrayRef before, CFArrayRef after)
{
    static SEL report;
    static Class watcherClass;
    if (!watcherClass) {
        Class found = objc_getClass("WKPolyfillCookieWatcher");
        if (!found)
            return;
        report = sel_registerName("reportMergeOfStorage:before:after:");
        watcherClass = found;
    }
    ((void (*)(id, SEL, const void *, CFArrayRef, CFArrayRef))objc_msgSend)((id)watcherClass, report, backend, before, after);
}

static void wk_reportCompactCookie(const void *backend, const void *header, enum wk_cookie_change change)
{
    CFTypeRef cookie = wk_copyCookieFromCompactHeader(header);
    if (!cookie)
        return;
    wk_reportCookieChange(backend, cookie, change);
    CFRelease(cookie);
}

static const struct wk_backend_hook *wk_backendHookOrFail(const void *backend)
{
    const struct wk_backend_hook *hook = wk_backendHookFor(backend);
    if (!hook)
        wk_patch_fail(kCookieChangeHooks, "a cookie storage backend reached a replacement installed on another class");
    return hook;
}

// A cookie already expired when it is stored: the write deletes rather than sets, which is how a
// script and a server both delete one -- CookieStore::deleteCookie writes the cookie with an expiry a
// day old, and "Max-Age=0" dates a cookie to its own creation. A cookie carrying no expiry at all
// reports 0 here and is a session cookie, not an expired one. This is the test
// CookieStore::cookiesAdded makes of the same pair.
static bool wk_cookieExpiredWhenStored(CFTypeRef cookie)
{
    CFAbsoluteTime expires = wk_CFHTTPCookieGetExpirationTime(cookie);
    return expires && expires <= wk_CFHTTPCookieGetCreationTime(cookie);
}

// A CompactCookieHeader is a size-prefixed record of offsets to its NUL-terminated strings. The guards
// are the ones MemoryCookies::setCookie applies to the same fields.
enum { kCompactSizeField = 0x00, kCompactDomainField = 0x10, kCompactNameField = 0x14, kCompactPathField = 0x18 };

static const char *wk_compactField(const void *header, uint32_t field)
{
    uint32_t size = *(const uint32_t *)((const char *)header + kCompactSizeField) + 1;
    if (size < field + 4)
        return NULL;
    uint32_t offset = *(const uint32_t *)((const char *)header + field);
    if (!offset || offset >= size)
        return NULL;
    return (const char *)header + offset;
}

// copyDomainCookieArrayLocked answers the storage's bucket for one domain -- the key is the domain bytes
// the header itself carries, leading dot and all, so a header's own domain needs no normalising. It
// answers a CompactCookieArray's payload, whose CF object begins 0x10 bytes before it, and an empty one
// rather than NULL for a domain it holds nothing for. It takes no lock of its own on any of the four
// implementing classes, so it is callable from inside a slot the storage's mutex is already held across.
typedef const void *(*wk_copy_domain_cookies_fn)(const void *backend, const unsigned char *domain, unsigned char keepSecure);
typedef void (*wk_visit_compact_array_fn)(const void *array, void (^visitor)(const void *header));
static wk_visit_compact_array_fn wk_CompactCookieArrayVisitCookies;

// The cookie the storage already holds under this one's identity -- name, domain and path, which is what
// RFC 6265 5.3 replaces a cookie by and what the delete slots match on -- or NULL for none. The caller
// owns the result. A stored cookie always carries a non-empty name, domain and path: 10.9's parser
// refuses "Set-Cookie: bare" and "Set-Cookie: =novalue" outright and rewrites an empty path to the
// default one, so a zero offset in any of those three fields is a record this does not understand.
static CFTypeRef wk_backendStoredCookieCreate(const struct wk_backend_hook *hook, const void *backend, const void *header)
{
    const char *domain = wk_compactField(header, kCompactDomainField);
    const char *name = wk_compactField(header, kCompactNameField);
    const char *path = wk_compactField(header, kCompactPathField);
    if (!domain || !name || !path)
        wk_patch_fail(kCookieChangeHooks, "a cookie being stored carries no name, domain or path to match on");

    const void *array = ((wk_copy_domain_cookies_fn)hook->copyDomainCookieArrayLocked)(backend,
        (const unsigned char *)domain, 1);
    if (!array)
        wk_patch_fail(kCookieChangeHooks, "a cookie storage answered no array for a domain it was asked about");

    __block CFTypeRef held = NULL;
    wk_CompactCookieArrayVisitCookies(array, ^(const void *stored) {
        if (held)
            return;
        const char *storedName = wk_compactField(stored, kCompactNameField);
        const char *storedPath = wk_compactField(stored, kCompactPathField);
        if (!storedName || !storedPath)
            wk_patch_fail(kCookieChangeHooks, "a cookie the storage holds carries no name or path");
        if (!strcmp(storedName, name) && !strcmp(storedPath, path))
            held = wk_copyCookieFromCompactHeader(stored);
    });
    CFRelease((CFTypeRef)((const char *)array - 0x10));
    return held;
}

// Whether two strings either side of a cookie field differ, a missing one differing from a present one.
static bool wk_cookieStringsDiffer(CFStringRef one, CFStringRef other)
{
    if (!one || !other)
        return one != other;
    return !CFEqual(one, other);
}

// What a subscriber is told a change is: the cookie's value or any attribute it carries, the comment
// among them -- this port keeps SameSite there (wk_sameSiteCommentCreate). Not the record itself: its
// creation time is rewritten on every store, so no two records of one cookie are equal.
static bool wk_storedCookieDiffers(CFTypeRef stored, CFTypeRef cookie)
{
    if (WK_SYSTEM(CFHTTPCookieIsSecure)(stored) != WK_SYSTEM(CFHTTPCookieIsSecure)(cookie)
        || WK_SYSTEM(CFHTTPCookieIsHTTPOnly)(stored) != WK_SYSTEM(CFHTTPCookieIsHTTPOnly)(cookie)
        || wk_CFHTTPCookieGetExpirationTime(stored) != wk_CFHTTPCookieGetExpirationTime(cookie))
        return true;
    CFStringRef storedValue = WK_SYSTEM(CFHTTPCookieCopyValue)(stored);
    CFStringRef value = WK_SYSTEM(CFHTTPCookieCopyValue)(cookie);
    bool differs = wk_cookieStringsDiffer(storedValue, value);
    if (storedValue)
        CFRelease(storedValue);
    if (value)
        CFRelease(value);
    if (differs)
        return true;
    CFStringRef storedComment = WK_SYSTEM(CFHTTPCookieCopyComment)((WKHTTPCookieRef)stored);
    CFStringRef comment = WK_SYSTEM(CFHTTPCookieCopyComment)((WKHTTPCookieRef)cookie);
    differs = wk_cookieStringsDiffer(storedComment, comment);
    if (storedComment)
        CFRelease(storedComment);
    if (comment)
        CFRelease(comment);
    return differs;
}

// Whether anyone is subscribed to changes for this cookie's domain on this storage. Asking the storage
// what it already holds costs ExternalCookieStorage a synchronous cookied round trip -- its set and
// delete both invalidate the per-domain cache first -- so it is asked only when a subscriber is there
// to be told, which is the only time the answer is used.
static bool wk_backendIsWatchedForCookie(const void *backend, const void *header)
{
    static SEL wants;
    static Class watcherClass;
    if (!watcherClass) {
        Class found = objc_getClass("WKPolyfillCookieWatcher");
        if (!found)
            return false;
        wants = sel_registerName("wantsReportsForStorage:domain:");
        watcherClass = found;
    }
    const char *domain = wk_compactField(header, kCompactDomainField);
    if (!domain)
        return false;
    return ((BOOL (*)(id, SEL, const void *, const char *))objc_msgSend)((id)watcherClass, wants, backend, domain);
}

static unsigned char wk_setCookieInternalLocked(const void *backend, const void *header)
{
    const struct wk_backend_hook *hook = wk_backendHookOrFail(backend);
    CFTypeRef cookie = wk_copyCookieFromCompactHeader(header);

    bool watched = cookie && wk_backendIsWatchedForCookie(backend, header);

    if (cookie && wk_cookieExpiredWhenStored(cookie)) {
        // A cookie that arrives already expired names one to remove and keeps nothing. 10.9 takes it in
        // and goes on sending it until the clock passes that instant, so the storage's own delete is
        // what takes it out; the delete matches on name, domain and path, so it reaches the stored
        // cookie whatever value this one carries. Whether there was one to remove is asked of the
        // storage rather than of the delete's answer, which two of the four backends hardcode --
        // writing an expired cookie over nothing changes nothing, and raises no change event.
        CFTypeRef stored = watched ? wk_backendStoredCookieCreate(hook, backend, header) : NULL;
        unsigned char answered = ((wk_compact_cookie_fn)hook->deleteCookieInternalLocked)(backend, header);
        if (stored) {
            wk_reportCookieChange(backend, cookie, WK_COOKIE_DELETED);
            CFRelease(stored);
        }
        CFRelease(cookie);
        // HTTPCookieStorage::setCookie notifies its own observers on this answer, so it stays the
        // delete slot's own word.
        return answered;
    }

    CFTypeRef stored = watched ? wk_backendStoredCookieCreate(hook, backend, header) : NULL;
    unsigned char changed = ((wk_compact_cookie_fn)hook->setCookieInternalLocked)(backend, header);
    // The slot answers that the write was accepted, not that the jar differs -- storing a cookie over
    // an identical one answers 1 on every backend. A subscriber is told about a change, so a store that
    // left the jar as it was is not one.
    if (changed && cookie && (!watched || !stored || wk_storedCookieDiffers(stored, cookie)))
        wk_reportCookieChange(backend, cookie, WK_COOKIE_SET);
    if (stored)
        CFRelease(stored);
    if (cookie)
        CFRelease(cookie);
    return changed;
}

static unsigned char wk_deleteCookieInternalLocked(const void *backend, const void *header)
{
    const struct wk_backend_hook *hook = wk_backendHookOrFail(backend);
    // Asked of the storage, not of the slot's answer: ExternalCookieStorage and NSCFPrivateCookieStorage
    // return a hardcoded 1. HTTPCookieStorage::deleteCookie reaches this slot twice for one delete, and
    // the second finds nothing left to remove, so the same question also keeps that to one report.
    CFTypeRef stored = wk_backendIsWatchedForCookie(backend, header)
        ? wk_backendStoredCookieCreate(hook, backend, header) : NULL;
    unsigned char answered = ((wk_compact_cookie_fn)hook->deleteCookieInternalLocked)(backend, header);
    if (stored) {
        wk_reportCompactCookie(backend, header, WK_COOKIE_DELETED);
        CFRelease(stored);
    }
    return answered;
}

// The cookies a storage holds, as the records it holds them as. visitCookiesLocked is the storage's own
// enumerator and reaches no cookie server.
static CFArrayRef wk_copyCookiesOfBackend(const struct wk_backend_hook *hook, const void *backend)
{
    CFMutableArrayRef cookies = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    if (!cookies)
        wk_patch_fail(kCookieChangeHooks, "a cookie storage's contents did not fit in memory");
    ((wk_visit_cookies_fn)hook->visitCookiesLocked)(backend, ^(const void *header) {
        CFTypeRef cookie = wk_copyCookieFromCompactHeader(header);
        if (!cookie)
            wk_patch_fail(kCookieChangeHooks, "a cookie the storage holds could not be read");
        CFArrayAppendValue(cookies, cookie);
        CFRelease(cookie);
    });
    return cookies;
}

// A file-backed storage syncs by merging the file and replaying its journal, which is how a cookie
// another process wrote to that file arrives. The merge names nothing it brought in, so the cookies the
// storage holds on either side of it do: this runs under the storage's own mutex, where no other writer
// can interleave, and the merge is a disk sync rather than a per-write step.
static void wk_syncStorageWithCompletionLocked(const void *backend, unsigned char flags, void (^completion)(void))
{
    const struct wk_backend_hook *hook = wk_backendHookOrFail(backend);
    wk_sync_storage_fn original = (wk_sync_storage_fn)hook->syncStorageWithCompletionLocked;
    if (!original)
        wk_patch_fail(kCookieChangeHooks, "a cookie storage class this does not merge for was synced");

    CFArrayRef before = wk_copyCookiesOfBackend(hook, backend);
    original(backend, flags, completion);
    CFArrayRef after = wk_copyCookiesOfBackend(hook, backend);
    wk_reportCookieMerge(backend, before, after);
    CFRelease(before);
    CFRelease(after);
}

static void wk_deleteAllCookiesLocked(const void *backend)
{
    wk_delete_all_cookies_fn original = (wk_delete_all_cookies_fn)wk_backendHookOrFail(backend)->deleteAllCookiesLocked;
    original(backend);
    wk_reportCookieChange(backend, NULL, WK_COOKIE_ALL_DELETED);
}

// The vptr an instance carries: the vtable symbol addresses the offset-to-top and typeinfo words ahead
// of the function pointers.
static const void *wk_vptrOfVTable(const wk_image *image, const char *vtableSymbol)
{
    void *vtable = wk_symbol_in_image(image, vtableSymbol);
    if (!vtable)
        wk_patch_fail(kSameSiteHooks, "CFNetwork's symbol table does not name a cookie storage vtable this patches");
    return (const void *)((const uint8_t *)vtable + 2 * sizeof(void *));
}

__attribute__((constructor)) static void wk_installSameSiteCookieHooks(void)
{
    // Each cookie storage class a request's cookies are read from and a response's are stored to. The
    // in-memory one is the storage an ephemeral session gets -- private browsing, and the session the
    // layout-test harness runs on -- and it stores a response's cookies through its own method like the
    // other two.
    //
    // CFXCookieStorage and MemXCookieStorage hand a response's fields to the CFHTTPCookieStorage they
    // hold -- at +0x18 and +0x20 -- which is where HTTPCookieStorage::setCookiesWithResponseHeaderFields
    // applies the cookie accept policy. NSXCookieStorage reaches no HTTPCookieStorage at all: it parses
    // the fields itself and hands the cookies to Foundation, so 10.9 applies no accept policy on its
    // store path and neither does the replacement.
    struct wk_storage_class {
        const char *vtable;
        const char *copyCookiesForURL;
        const char *setCookiesWithResponseHeaderFields;
        long cookieStorageField;
    };
    static const struct wk_storage_class classes[] = {
        { "__ZTV16CFXCookieStorage", "__ZNK16CFXCookieStorage17copyCookiesForURLEPK7__CFURLh",
          "__ZNK16CFXCookieStorage34setCookiesWithResponseHeaderFieldsEPK7__CFURLPK14__CFDictionaryS2_i", 0x18 },
        { "__ZTV16NSXCookieStorage", "__ZNK16NSXCookieStorage17copyCookiesForURLEPK7__CFURLh",
          "__ZNK16NSXCookieStorage34setCookiesWithResponseHeaderFieldsEPK7__CFURLPK14__CFDictionaryS2_i", 0 },
        { "__ZTV17MemXCookieStorage", "__ZNK17MemXCookieStorage17copyCookiesForURLEPK7__CFURLh",
          "__ZNK17MemXCookieStorage34setCookiesWithResponseHeaderFieldsEPK7__CFURLPK14__CFDictionaryS2_i", 0x20 },
    };
    const long classCount = (long)(sizeof(classes) / sizeof(classes[0]));

    // A process with no CFNetwork mapped makes no HTTP request through it, so there is nothing here to
    // decide. WebCore, WebKit and WebKit2 each link it, so a process that does load it has at least one
    // framework whose copy of this runs with it present.
    wk_image image;
    if (!wk_find_image(kCFNetworkSuffix, &image))
        return;

    // Resolved and published before anything is patched, so the first call to reach a replacement finds
    // the implementation it stands in for already recorded.
    static const char kOuterVTable[] = "__ZTV24ClassicConnectionSession";
    static const char kOuterFunction[] = "__ZNK24ClassicConnectionSession56copyCookiesForRequestUsingAllAppropriateStorageSemanticsEPK13_CFURLRequest";

    wk_originalCopyCookiesForRequest = (wk_copy_cookies_for_request_fn)wk_symbol_in_image(&image, kOuterFunction);
    if (!wk_originalCopyCookiesForRequest)
        wk_patch_fail(kSameSiteHooks, "CFNetwork's symbol table does not name the cookie composer this stands in for");
    wk_someCookiesAreSetForURL = (wk_some_cookies_are_set_fn)wk_symbol_in_image(&image,
        "__ZN17HTTPCookieStorage23someCookiesAreSetForURLEPK7__CFURL");
    if (!wk_someCookiesAreSetForURL)
        wk_patch_fail(kSameSiteHooks, "CFNetwork's symbol table does not name the storage question the accept policy asks");
    for (long i = 0; i < classCount; ++i) {
        wk_storageHooks[i].vtable = wk_vptrOfVTable(&image, classes[i].vtable);
        wk_storageHooks[i].copyCookiesForURL = wk_symbol_in_image(&image, classes[i].copyCookiesForURL);
        wk_storageHooks[i].setCookiesWithResponseHeaderFields = classes[i].setCookiesWithResponseHeaderFields
            ? wk_symbol_in_image(&image, classes[i].setCookiesWithResponseHeaderFields) : NULL;
        wk_storageHooks[i].cookieStorageField = classes[i].cookieStorageField;
        if (!wk_storageHooks[i].copyCookiesForURL
            || (classes[i].setCookiesWithResponseHeaderFields && !wk_storageHooks[i].setCookiesWithResponseHeaderFields))
            wk_patch_fail(kSameSiteHooks, "CFNetwork's symbol table does not name a cookie storage method this stands in for");
    }
    wk_storageHookCount = classCount;

    long claimed = 0, alreadyDone = 0;
    bool thisFrameworkWrote = false;
    wk_vtable_patch patch;
    patch.what = kSameSiteHooks;
    patch.imagePathSuffix = kCFNetworkSuffix;
    patch.isInScope = NULL;

    patch.vtableSymbol = kOuterVTable;
    patch.originalSymbol = kOuterFunction;
    patch.replacement = (const void *)wk_copyCookiesForRequest;
    wk_patch_vtable_slot(&patch, &thisFrameworkWrote);
    if (thisFrameworkWrote)
        ++claimed;
    else
        ++alreadyDone;

    for (long i = 0; i < classCount; ++i) {
        patch.vtableSymbol = classes[i].vtable;
        patch.originalSymbol = classes[i].copyCookiesForURL;
        patch.replacement = (const void *)wk_copyCookiesForURL;
        wk_patch_vtable_slot(&patch, &thisFrameworkWrote);
        if (thisFrameworkWrote)
            ++claimed;
        else
            ++alreadyDone;

        if (!classes[i].setCookiesWithResponseHeaderFields)
            continue;
        patch.originalSymbol = classes[i].setCookiesWithResponseHeaderFields;
        patch.replacement = (const void *)wk_setCookiesWithResponseHeaderFields;
        wk_patch_vtable_slot(&patch, &thisFrameworkWrote);
        if (thisFrameworkWrote)
            ++claimed;
        else
            ++alreadyDone;
    }

    // The backends a storage's writes reach. The set is every vtable holding the mutation slots, which
    // is not the same as every class defining them: XMLCookieStorage and BinaryCookieStorage are the two
    // concrete file-backed jars and both inherit DiskCookieStorage's implementations, while
    // DiskCookieStorage itself has no complete-object constructor and is never a live vptr.
    struct wk_backend_class {
        const char *vtable;
        const char *setCookieInternalLocked;
        const char *deleteCookieInternalLocked;
        const char *deleteAllCookiesLocked;
        const char *copyDomainCookieArrayLocked;
        // Only the file-backed pair merges on sync; the rest hold no file to merge.
        const char *visitCookiesLocked;
        const char *syncStorageWithCompletionLocked;
    };
    static const char kDiskCopyDomain[] = "__ZN17DiskCookieStorage27copyDomainCookieArrayLockedEPKhh";
    static const char kDiskSet[] = "__ZN17DiskCookieStorage23setCookieInternalLockedEPK19CompactCookieHeader";
    static const char kDiskDelete[] = "__ZN17DiskCookieStorage26deleteCookieInternalLockedEPK19CompactCookieHeader";
    static const char kDiskDeleteAll[] = "__ZN17DiskCookieStorage22deleteAllCookiesLockedEv";
    static const char kDiskVisit[] = "__ZN17DiskCookieStorage18visitCookiesLockedEU13block_pointerFvPK19CompactCookieHeaderE";
    static const char kDiskSync[] = "__ZN17DiskCookieStorage31syncStorageWithCompletionLockedEhU13block_pointerFvvE";
    static const struct wk_backend_class backends[] = {
        { "__ZTV21ExternalCookieStorage",
          "__ZN21ExternalCookieStorage23setCookieInternalLockedEPK19CompactCookieHeader",
          "__ZN21ExternalCookieStorage26deleteCookieInternalLockedEPK19CompactCookieHeader",
          "__ZN21ExternalCookieStorage22deleteAllCookiesLockedEv",
          "__ZN21ExternalCookieStorage27copyDomainCookieArrayLockedEPKhh", NULL, NULL },
        { "__ZTV19MemoryCookieStorage",
          "__ZN19MemoryCookieStorage23setCookieInternalLockedEPK19CompactCookieHeader",
          "__ZN19MemoryCookieStorage26deleteCookieInternalLockedEPK19CompactCookieHeader",
          "__ZN19MemoryCookieStorage22deleteAllCookiesLockedEv",
          "__ZN19MemoryCookieStorage27copyDomainCookieArrayLockedEPKhh", NULL, NULL },
        { "__ZTV24NSCFPrivateCookieStorage",
          "__ZN24NSCFPrivateCookieStorage23setCookieInternalLockedEPK19CompactCookieHeader",
          "__ZN24NSCFPrivateCookieStorage26deleteCookieInternalLockedEPK19CompactCookieHeader",
          "__ZN24NSCFPrivateCookieStorage22deleteAllCookiesLockedEv",
          "__ZN24NSCFPrivateCookieStorage27copyDomainCookieArrayLockedEPKhh", NULL, NULL },
        { "__ZTV16XMLCookieStorage", kDiskSet, kDiskDelete, kDiskDeleteAll, kDiskCopyDomain, kDiskVisit, kDiskSync },
        { "__ZTV19BinaryCookieStorage", kDiskSet, kDiskDelete, kDiskDeleteAll, kDiskCopyDomain, kDiskVisit, kDiskSync },
    };
    const long backendCount = (long)(sizeof(backends) / sizeof(backends[0]));

    wk_HTTPCookieClass = (wk_cf_class_fn)wk_symbol_in_image(&image, "__ZN10HTTPCookie5ClassEv");
    wk_CFObjectAllocate = (wk_cf_object_allocate_fn)wk_symbol_in_image(&image, "__ZN8CFObject8AllocateEmRK7CFClassPK13__CFAllocator");
    wk_constructCompactHTTPCookieWithData = (wk_compact_cookie_ctor_fn)wk_symbol_in_image(&image, "__ZN25CompactHTTPCookieWithDataC1EPK19CompactCookieHeader");
    wk_CFHTTPCookieStorageGetTypeID = (wk_type_id_fn)wk_symbol_in_image(&image, "_CFHTTPCookieStorageGetTypeID");
    wk_CompactCookieArrayVisitCookies = (wk_visit_compact_array_fn)wk_symbol_in_image(&image,
        "__ZNK18CompactCookieArray12visitCookiesEU13block_pointerFvPK19CompactCookieHeaderE");
    if (!wk_CompactCookieArrayVisitCookies)
        wk_patch_fail(kCookieChangeHooks, "CFNetwork's symbol table does not name the cookie array this reads a domain's cookies from");
    wk_CFHTTPCookieGetCreationTime = (wk_cookie_time_fn)wk_symbol_in_image(&image, "_CFHTTPCookieGetCreationTime");
    wk_CFHTTPCookieGetExpirationTime = (wk_cookie_time_fn)wk_symbol_in_image(&image, "_CFHTTPCookieGetExpirationTime");
    if (!wk_CFHTTPCookieGetCreationTime || !wk_CFHTTPCookieGetExpirationTime)
        wk_patch_fail(kCookieChangeHooks, "CFNetwork's symbol table does not name the cookie times a stored cookie is judged by");
    if (!wk_HTTPCookieClass || !wk_CFObjectAllocate || !wk_constructCompactHTTPCookieWithData || !wk_CFHTTPCookieStorageGetTypeID)
        wk_patch_fail(kCookieChangeHooks, "CFNetwork's symbol table does not name the cookie constructor this rebuilds a stored cookie with");
    for (long i = 0; i < backendCount; ++i) {
        wk_backendHooks[i].vtable = wk_vptrOfVTable(&image, backends[i].vtable);
        wk_backendHooks[i].setCookieInternalLocked = wk_symbol_in_image(&image, backends[i].setCookieInternalLocked);
        wk_backendHooks[i].deleteCookieInternalLocked = wk_symbol_in_image(&image, backends[i].deleteCookieInternalLocked);
        wk_backendHooks[i].deleteAllCookiesLocked = wk_symbol_in_image(&image, backends[i].deleteAllCookiesLocked);
        wk_backendHooks[i].copyDomainCookieArrayLocked = wk_symbol_in_image(&image, backends[i].copyDomainCookieArrayLocked);
        if (!wk_backendHooks[i].setCookieInternalLocked || !wk_backendHooks[i].deleteCookieInternalLocked
            || !wk_backendHooks[i].deleteAllCookiesLocked || !wk_backendHooks[i].copyDomainCookieArrayLocked)
            wk_patch_fail(kCookieChangeHooks, "CFNetwork's symbol table does not name a cookie storage mutation slot this stands in for");
        if (!backends[i].syncStorageWithCompletionLocked)
            continue;
        wk_backendHooks[i].visitCookiesLocked = wk_symbol_in_image(&image, backends[i].visitCookiesLocked);
        wk_backendHooks[i].syncStorageWithCompletionLocked = wk_symbol_in_image(&image, backends[i].syncStorageWithCompletionLocked);
        if (!wk_backendHooks[i].visitCookiesLocked || !wk_backendHooks[i].syncStorageWithCompletionLocked)
            wk_patch_fail(kCookieChangeHooks, "CFNetwork's symbol table does not name the cookie storage merge this reports");
    }
    wk_backendHookCount = backendCount;

    patch.what = kCookieChangeHooks;
    for (long i = 0; i < backendCount; ++i) {
        patch.vtableSymbol = backends[i].vtable;
        patch.originalSymbol = backends[i].setCookieInternalLocked;
        patch.replacement = (const void *)wk_setCookieInternalLocked;
        wk_patch_vtable_slot(&patch, &thisFrameworkWrote);
        if (thisFrameworkWrote)
            ++claimed;
        else
            ++alreadyDone;

        patch.originalSymbol = backends[i].deleteCookieInternalLocked;
        patch.replacement = (const void *)wk_deleteCookieInternalLocked;
        wk_patch_vtable_slot(&patch, &thisFrameworkWrote);
        if (thisFrameworkWrote)
            ++claimed;
        else
            ++alreadyDone;

        patch.originalSymbol = backends[i].deleteAllCookiesLocked;
        patch.replacement = (const void *)wk_deleteAllCookiesLocked;
        wk_patch_vtable_slot(&patch, &thisFrameworkWrote);
        if (thisFrameworkWrote)
            ++claimed;
        else
            ++alreadyDone;

        if (!backends[i].syncStorageWithCompletionLocked)
            continue;
        patch.originalSymbol = backends[i].syncStorageWithCompletionLocked;
        patch.replacement = (const void *)wk_syncStorageWithCompletionLocked;
        wk_patch_vtable_slot(&patch, &thisFrameworkWrote);
        if (thisFrameworkWrote)
            ++claimed;
        else
            ++alreadyDone;
    }

    // These replacements pass a request context between them through storage private to the framework
    // they were installed from, so one framework has to have claimed all of them. dyld runs initializers
    // serially, so the first to reach this does; a split set is a broken assumption, not a race to
    // accommodate.
    if (claimed && alreadyDone)
        wk_patch_fail(kSameSiteHooks, "one framework did not claim the whole set, so the replacements would "
                                      "not share the request context they pass between them");
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
