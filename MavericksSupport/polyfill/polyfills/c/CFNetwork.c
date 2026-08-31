// CFNetwork: entry points and constants modern WebKit references that 10.9's CFNetwork does not export,
// and a load-time patch of one CFNetwork constant in the network process.
#include "wk_polyfill.h"
#include "wk_samesite.h"
#include "wk_symbols.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
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

static CFArrayRef wk_copyCookiesForURL(const void *storage, CFURLRef url, unsigned char secure)
{
    wk_copy_cookies_for_url_fn original = (wk_copy_cookies_for_url_fn)wk_hookForStorage(storage)->copyCookiesForURL;
    CFArrayRef cookies = original(storage, url, secure);
    // Every other caller of this -- CFNetwork's own accept-policy path among them -- gets exactly what
    // it would have got. A same-site read lets every cookie ride whatever its policy says
    // (wk_sameSiteAllows), so only a cross-site read pays the per-cookie comment scan.
    if (!cookies || !wk_cookieContext.known || wk_cookieContext.isSameSite)
        return cookies;

    CFIndex count = CFArrayGetCount(cookies);
    CFMutableArrayRef allowed = NULL;
    for (CFIndex i = 0; i < count; ++i) {
        const void *cookie = CFArrayGetValueAtIndex(cookies, i);
        CFStringRef comment = WK_SYSTEM(CFHTTPCookieCopyComment)((WKHTTPCookieRef)cookie);
        bool rides = wk_sameSiteAllows(wk_sameSitePolicyOfComment(comment), wk_cookieContext.isSameSite,
                                       wk_cookieContext.isTopLevelNavigation, wk_cookieContext.isSafeMethod);
        if (comment)
            CFRelease(comment);
        if (rides) {
            if (allowed)
                CFArrayAppendValue(allowed, cookie);
            continue;
        }
        if (!allowed) {
            allowed = CFArrayCreateMutable(NULL, count, &kCFTypeArrayCallBacks);
            if (!allowed)
                return cookies;
            for (CFIndex kept = 0; kept < i; ++kept)
                CFArrayAppendValue(allowed, CFArrayGetValueAtIndex(cookies, kept));
        }
    }
    if (!allowed)
        return cookies;
    CFRelease(cookies);
    return allowed;
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

static void wk_setCookiesWithResponseHeaderFields(const void *storage, CFURLRef url, CFDictionaryRef headerFields,
                                                  CFURLRef mainDocumentURL, int acceptPolicy)
{
    wk_set_cookies_fn original = (wk_set_cookies_fn)wk_hookForStorage(storage)->setCookiesWithResponseHeaderFields;
    if (!original)
        wk_patch_fail(kSameSiteHooks, "a cookie storage class this only reads through was stored to");

    CFStringRef name = headerFields ? wk_setCookieFieldName(headerFields) : NULL;
    CFTypeRef header = name ? CFDictionaryGetValue(headerFields, name) : NULL;
    if (!header || CFGetTypeID(header) != CFStringGetTypeID()) {
        original(storage, url, headerFields, mainDocumentURL, acceptPolicy);
        return;
    }

    CFStringRef rewritten = NULL;
    wk_samesite_header_disposition disposition = wk_sameSiteRewriteSetCookieHeader((CFStringRef)header, url, &rewritten);
    if (disposition == WK_SAMESITE_HEADER_UNCHANGED) {
        original(storage, url, headerFields, mainDocumentURL, acceptPolicy);
        return;
    }
    CFMutableDictionaryRef replaced = CFDictionaryCreateMutableCopy(NULL, 0, headerFields);
    if (!replaced)
        wk_patch_fail(kSameSiteHooks, "the response header fields carrying the attribute could not be copied");
    CFDictionarySetValue(replaced, name, rewritten);
    original(storage, url, replaced, mainDocumentURL, acceptPolicy);
    CFRelease(replaced);
    CFRelease(rewritten);
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
    // A cookie storage class the request's cookies are read from. Only the two the response-storing path
    // reaches carry a storing symbol; the third is the in-memory storage that path never writes to.
    struct wk_storage_class {
        const char *vtable;
        const char *copyCookiesForURL;
        const char *setCookiesWithResponseHeaderFields;
    };
    static const struct wk_storage_class classes[] = {
        { "__ZTV16CFXCookieStorage", "__ZNK16CFXCookieStorage17copyCookiesForURLEPK7__CFURLh",
          "__ZNK16CFXCookieStorage34setCookiesWithResponseHeaderFieldsEPK7__CFURLPK14__CFDictionaryS2_i" },
        { "__ZTV16NSXCookieStorage", "__ZNK16NSXCookieStorage17copyCookiesForURLEPK7__CFURLh",
          "__ZNK16NSXCookieStorage34setCookiesWithResponseHeaderFieldsEPK7__CFURLPK14__CFDictionaryS2_i" },
        { "__ZTV17MemXCookieStorage", "__ZNK17MemXCookieStorage17copyCookiesForURLEPK7__CFURLh", NULL },
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
    for (long i = 0; i < classCount; ++i) {
        wk_storageHooks[i].vtable = wk_vptrOfVTable(&image, classes[i].vtable);
        wk_storageHooks[i].copyCookiesForURL = wk_symbol_in_image(&image, classes[i].copyCookiesForURL);
        wk_storageHooks[i].setCookiesWithResponseHeaderFields = classes[i].setCookiesWithResponseHeaderFields
            ? wk_symbol_in_image(&image, classes[i].setCookiesWithResponseHeaderFields) : NULL;
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

    // These replacements pass a request context between them through storage private to the framework
    // they were installed from, so one framework has to have claimed all of them. dyld runs initializers
    // serially, so the first to reach this does; a split set is a broken assumption, not a race to
    // accommodate.
    if (claimed && alreadyDone)
        wk_patch_fail(kSameSiteHooks, "one framework did not claim the whole set, so the replacements would "
                                      "not share the request context they pass between them");
}
