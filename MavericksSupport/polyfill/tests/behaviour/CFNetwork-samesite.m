// The SameSite encoding, the rule and the Set-Cookie rewrite (polyfills/c/wk_samesite.c), against 10.9's
// own cookie parser.
#include "../../polyfills/c/wk_samesite.h"
#include "../../polyfills/c/wk_hosts.h"

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// CFNetwork's own cookie parser and accessors, resolved the way the polyfill resolves them: they are
// exported on 10.9 and absent from the build SDK's stub library.
typedef const struct OpaqueCFHTTPCookie *CookieRef;
typedef struct OpaqueCFHTTPCookieStorage *CFHTTPCookieStorageRef;
typedef CFArrayRef (*ParseFn)(CFAllocatorRef, CFDictionaryRef, CFURLRef);
typedef CFStringRef (*CopyFn)(CookieRef);

static void *cfnetwork(const char *name)
{
    static void *image;
    if (!image)
        image = dlopen("/System/Library/Frameworks/CFNetwork.framework/CFNetwork", RTLD_LAZY);
    void *function = image ? dlsym(image, name) : NULL;
    if (!function) {
        printf("  FAIL: CFNetwork does not export %s\n", name);
        exit(1);
    }
    return function;
}

static int failures;

static void check(bool condition, const char *what)
{
    if (condition)
        return;
    printf("  FAIL: %s\n", what);
    ++failures;
}

static CFStringRef str(const char *text)
{
    return CFStringCreateWithCString(NULL, text, kCFStringEncodingUTF8);
}

static char *utf8(CFStringRef string)
{
    if (!string)
        return NULL;
    CFIndex capacity = CFStringGetMaximumSizeForEncoding(CFStringGetLength(string), kCFStringEncodingUTF8) + 1;
    char *bytes = (char *)malloc((size_t)capacity);
    CFStringGetCString(string, bytes, capacity, kCFStringEncodingUTF8);
    return bytes;
}

static void checkRoundTrip(const char *sameSite, const char *comment)
{
    CFStringRef policy = str(sameSite);
    CFStringRef original = comment ? str(comment) : NULL;
    CFStringRef blob = wk_sameSiteCommentCreate(policy, original);
    check(blob != NULL, "the pair encodes");
    if (blob) {
        CFStringRef readPolicy = wk_sameSiteCopyValue(blob);
        CFStringRef readComment = wk_sameSiteCopyServerComment(blob);
        check(readPolicy && CFEqual(readPolicy, policy), "the attribute reads back");
        check(original ? (readComment && CFEqual(readComment, original)) : !readComment,
              "the server's comment reads back");
        if (readPolicy)
            CFRelease(readPolicy);
        if (readComment)
            CFRelease(readComment);
        CFRelease(blob);
    }
    CFRelease(policy);
    if (original)
        CFRelease(original);
}

// The cookies 10.9's parser makes of |header|, printed as "name=value|comment" per cookie.
static CFStringRef parseAndDescribe(CFStringRef header, CFURLRef url)
{
    const void *key = (const void *)CFSTR("Set-Cookie");
    const void *value = (const void *)header;
    CFDictionaryRef fields = CFDictionaryCreate(NULL, &key, &value, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFArrayRef cookies = ((ParseFn)cfnetwork("CFHTTPCookieCreateWithResponseHeaderFields"))(NULL, fields, url);
    CFRelease(fields);
    CFMutableStringRef description = CFStringCreateMutable(NULL, 0);
    for (CFIndex i = 0; cookies && i < CFArrayGetCount(cookies); ++i) {
        CookieRef cookie = (CookieRef)CFArrayGetValueAtIndex(cookies, i);
        CFStringRef name = ((CopyFn)cfnetwork("CFHTTPCookieCopyName"))(cookie);
        CFStringRef text = ((CopyFn)cfnetwork("CFHTTPCookieCopyValue"))(cookie);
        CFStringRef comment = ((CopyFn)cfnetwork("CFHTTPCookieCopyComment"))(cookie);
        CFStringAppendFormat(description, NULL, CFSTR("[%@=%@|%@]"), name, text, comment ? comment : CFSTR("-"));
        if (name)
            CFRelease(name);
        if (text)
            CFRelease(text);
        if (comment)
            CFRelease(comment);
    }
    if (cookies)
        CFRelease(cookies);
    return description;
}

// Rewrites |header| and answers what the parser then makes of it, so a case is stated in terms of the
// cookies that reach the jar rather than the bytes in between.
static void checkRewrite(const char *label, const char *header, const char *expected)
{
    CFURLRef url = CFURLCreateWithString(NULL, CFSTR("http://a.test/x"), NULL);
    CFStringRef field = str(header);
    CFStringRef rewritten = NULL;
    wk_samesite_header_disposition disposition = wk_sameSiteRewriteSetCookieHeader(field, url, &rewritten);

    CFStringRef described = parseAndDescribe(disposition == WK_SAMESITE_HEADER_REWRITTEN ? rewritten : field, url);

    char *actual = utf8(described);
    if (strcmp(actual, expected)) {
        printf("  FAIL: %s\n        header   %s\n        expected %s\n        actual   %s\n",
               label, header, expected, actual);
        ++failures;
    }
    free(actual);
    CFRelease(described);
    if (rewritten)
        CFRelease(rewritten);
    CFRelease(field);
    CFRelease(url);
}


// RFC 6265bis 5.5 at the HTTP seam: the set-cookie-strings of a folded field that carry no CTL other
// than HTAB, folded back into one field. |expected| is NULL when every cookie in the field carries one.
static void checkControlSplit(const char *label, const char *header, const char *expected)
{
    CFStringRef field = str(header);
    CFStringRef kept = wk_copyFieldWithoutControlCookies(field);
    char *actual = kept ? utf8(kept) : NULL;
    bool same = expected ? (actual && !strcmp(actual, expected)) : !actual;
    if (!same) {
        printf("  FAIL: %s\n        header   %s\n        expected %s\n        actual   %s\n",
               label, header, expected ? expected : "(the whole field ignored)",
               actual ? actual : "(the whole field ignored)");
        ++failures;
    }
    free(actual);
    if (kept)
        CFRelease(kept);
    CFRelease(field);
}


// The division this layer makes must be the one 10.9's parser makes, so a field is never handed on
// carrying more or fewer cookies than the server sent.
static void checkRangeCountMatchesParser(const char *header)
{
    CFURLRef url = CFURLCreateWithString(NULL, CFSTR("http://a.test/x"), NULL);
    CFStringRef field = str(header);
    CFIndex ours = 0;
    CFRange *ranges = wk_copySetCookieRanges(field, &ours);
    const void *key = (const void *)CFSTR("Set-Cookie");
    const void *value = (const void *)field;
    CFDictionaryRef fields = CFDictionaryCreate(NULL, &key, &value, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFArrayRef parsed = ((ParseFn)cfnetwork("CFHTTPCookieCreateWithResponseHeaderFields"))(NULL, fields, url);
    CFRelease(fields);
    CFIndex theirs = parsed ? CFArrayGetCount(parsed) : 0;
    if (ours != theirs) {
        printf("  FAIL: the field divides into %ld cookies here and %ld in the parser\n        header %s\n",
               (long)ours, (long)theirs, header);
        ++failures;
    }
    free(ranges);
    if (parsed)
        CFRelease(parsed);
    CFRelease(field);
    CFRelease(url);
}

static void checkPolicy(const char *sameSite, wk_same_site_policy expected, const char *what)
{
    CFStringRef policy = str(sameSite);
    CFStringRef blob = wk_sameSiteCommentCreate(policy, NULL);
    check(blob && wk_sameSitePolicyOfComment(blob) == expected, what);
    if (blob)
        CFRelease(blob);
    CFRelease(policy);
}

static void checkSameSite(const char *site, const char *url, bool expected, const char *what)
{
    CFStringRef siteText = str(site), urlText = str(url);
    CFURLRef a = CFURLCreateWithString(NULL, siteText, NULL);
    CFURLRef b = CFURLCreateWithString(NULL, urlText, NULL);
    check(wk_sameSiteURLsAreSameSite(a, b) == expected, what);
    if (a)
        CFRelease(a);
    if (b)
        CFRelease(b);
    CFRelease(siteText);
    CFRelease(urlText);
}


// ---------------------------------------------------------------------------------------------------
// The bulk-merge report (polyfills/c/CFNetwork.c). A file-backed cookie storage takes in whatever
// another process wrote to its file when it syncs, naming none of it; the hook snapshots the storage
// either side of that merge and the watcher reports the difference. Driven here with two storages over
// one file: the second writes, the first syncs, and the handlers say what moved.
typedef CFHTTPCookieStorageRef (*CreateFromFileFn)(CFAllocatorRef, CFURLRef, CFDictionaryRef);
typedef void (*SyncNowFn)(CFHTTPCookieStorageRef);
typedef void (*StorageSetCookieFn)(CFHTTPCookieStorageRef, CookieRef);
typedef void (*StorageDeleteCookieFn)(CFHTTPCookieStorageRef, CookieRef);

// -_initWithCFHTTPCookieStorage: is 10.9's own, so the public selector reaches it; the three handler
// methods below are ones this layer adds, and an added method answers only the private selector the
// layer registers it under ("wk_" and the real name), which is what a send made at runtime must name.
static NSHTTPCookieStorage *wrapStorage(CFHTTPCookieStorageRef store)
{
    return [((id (*)(id, SEL, CFHTTPCookieStorageRef))objc_msgSend)([NSHTTPCookieStorage alloc],
        sel_getUid("_initWithCFHTTPCookieStorage:"), store) autorelease];
}

static NSHTTPCookie *cookieNamed(NSString *name, NSString *value)
{
    return [NSHTTPCookie cookieWithProperties:@{ NSHTTPCookieName: name, NSHTTPCookieValue: value,
        NSHTTPCookieDomain: @"merge.test", NSHTTPCookiePath: @"/" }];
}

// The reports the watcher has delivered, drained by spinning the run loop the handlers are queued on.
static NSMutableArray *gAdded, *gRemoved;

static void drain(void)
{
    for (int i = 0; i < 40; ++i)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, true);
}

static NSString *describe(NSArray *cookies)
{
    NSMutableArray *parts = [NSMutableArray array];
    for (NSHTTPCookie *c in [cookies sortedArrayUsingComparator:^NSComparisonResult(NSHTTPCookie *a, NSHTTPCookie *b) {
            return [[a name] compare:[b name]]; }])
        [parts addObject:[NSString stringWithFormat:@"%@=%@", [c name], [c value]]];
    return [parts componentsJoinedByString:@","];
}

static void checkMerge(const char *label, NSString *gotAdded, const char *wantAdded,
                       NSString *gotRemoved, const char *wantRemoved)
{
    if (strcmp([gotAdded UTF8String], wantAdded) || strcmp([gotRemoved UTF8String], wantRemoved)) {
        printf("  FAIL: %s\n        added   expected [%s] got [%s]\n        removed expected [%s] got [%s]\n",
               label, wantAdded, [gotAdded UTF8String], wantRemoved, [gotRemoved UTF8String]);
        ++failures;
    }
}

static void checkBulkMergeReport(void)
{
    CreateFromFileFn createFromFile = (CreateFromFileFn)cfnetwork("CFHTTPCookieStorageCreateFromFile");
    SyncNowFn syncNow = (SyncNowFn)cfnetwork("CFHTTPCookieStorageSyncStorageNow");

    NSString *path = [NSString stringWithFormat:@"/tmp/wk-merge-%d.cookies", (int)getpid()];
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)[path UTF8String],
                                                           (CFIndex)strlen([path UTF8String]), false);

    CFHTTPCookieStorageRef observed = createFromFile(NULL, url, NULL);
    CFHTTPCookieStorageRef writer = createFromFile(NULL, url, NULL);
    if (!observed || !writer) {
        printf("  FAIL: a file-backed cookie storage could not be made\n");
        ++failures;
        CFRelease(url);
        return;
    }

    gAdded = [NSMutableArray array];
    gRemoved = [NSMutableArray array];
    NSHTTPCookieStorage *watched = wrapStorage(observed);
    NSHTTPCookieStorage *writing = wrapStorage(writer);

    ((void (*)(id, SEL, id, dispatch_queue_t))objc_msgSend)(watched, sel_getUid("wk__setCookiesChangedHandler:onQueue:"),
        ^(NSArray *cookies, NSString *host) { (void)host; [gAdded addObjectsFromArray:cookies]; }, dispatch_get_main_queue());
    ((void (*)(id, SEL, id, dispatch_queue_t))objc_msgSend)(watched, sel_getUid("wk__setCookiesRemovedHandler:onQueue:"),
        ^(NSArray *cookies, NSString *host, BOOL all) { (void)host; (void)all; [gRemoved addObjectsFromArray:cookies]; }, dispatch_get_main_queue());
    ((void (*)(id, SEL, id))objc_msgSend)(watched, sel_getUid("wk__setSubscribedDomainsForCookieChanges:"),
        [NSSet setWithObject:@"merge.test"]);

    // (1) a cookie another writer added arrives as an addition
    [writing setCookie:cookieNamed(@"a", @"1")];
    [writing setCookie:cookieNamed(@"b", @"2")];
    syncNow(writer);
    syncNow(observed);
    drain();
    checkMerge("a merge that adds cookies names them", describe(gAdded), "a=1,b=2", describe(gRemoved), "");

    // (2) a value change under the same identity is a set, not a pair of edits
    [gAdded removeAllObjects]; [gRemoved removeAllObjects];
    [writing setCookie:cookieNamed(@"a", @"changed")];
    syncNow(writer);
    syncNow(observed);
    drain();
    checkMerge("a merge that changes a value names it once", describe(gAdded), "a=changed", describe(gRemoved), "");

    // (3) a cookie another writer removed arrives as a removal
    [gAdded removeAllObjects]; [gRemoved removeAllObjects];
    [writing deleteCookie:cookieNamed(@"b", @"2")];
    syncNow(writer);
    syncNow(observed);
    drain();
    checkMerge("a merge that removes a cookie names it", describe(gAdded), "", describe(gRemoved), "b=2");

    ((void (*)(id, SEL, id))objc_msgSend)(watched, sel_getUid("wk__setSubscribedDomainsForCookieChanges:"), nil);
    CFRelease(observed);
    CFRelease(writer);
    CFRelease(url);
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

int main(void)
{
    printf("SameSite encoding, rule and Set-Cookie rewrite:\n");

    // The encoding carries the attribute and the server's comment, whatever either contains.
    checkRoundTrip("Strict", NULL);
    checkRoundTrip("Lax", "a plain comment");
    checkRoundTrip("None", "punctuation ; and , and = and % and \"quotes\"");
    checkRoundTrip("Strict", "wk:1 ss=Lax");
    checkRoundTrip("", "");
    checkRoundTrip("Strict", "\xc3\xa9\xc3\xa8 non-ASCII");

    // A comment of a server's own is handed back as itself, however it begins.
    CFStringRef foreign = str("wk:9 not one of ours");
    CFStringRef asComment = wk_sameSiteCopyServerComment(foreign);
    check(asComment && CFEqual(asComment, foreign), "a foreign comment beginning wk: is not misread");
    check(wk_sameSiteCopyValue(foreign) == NULL, "and carries no attribute");
    check(wk_sameSitePolicyOfComment(foreign) == WK_SAME_SITE_NONE, "and no policy");
    if (asComment)
        CFRelease(asComment);
    CFRelease(foreign);
    // What a cookie must be to be stored at all: a Secure cookie needs a secure origin, and a name
    // prefix is a promise the cookie has to keep. The prefixes match case-sensitively, as CFNetwork's do.
    {
        CFURLRef secure = CFURLCreateWithString(NULL, CFSTR("https://example.com/x/"), NULL);
        CFURLRef plain = CFURLCreateWithString(NULL, CFSTR("http://example.com/x/"), NULL);
        check(wk_cookieMayBeSet(CFSTR("a"), false, CFSTR("/"), false, plain),
              "an ordinary cookie is set from a non-secure origin");
        check(!wk_cookieMayBeSet(CFSTR("a"), true, CFSTR("/"), false, plain),
              "a Secure cookie is not");
        check(wk_cookieMayBeSet(CFSTR("__Secure-a"), true, CFSTR("/"), false, secure),
              "a __Secure- cookie that is Secure and from a secure origin is set");
        check(!wk_cookieMayBeSet(CFSTR("__Secure-a"), false, CFSTR("/"), false, secure),
              "one without the attribute is not");
        check(wk_cookieMayBeSet(CFSTR("__SeCuRe-a"), false, CFSTR("/"), false, secure),
              "and the prefix is matched case-sensitively, as CFNetwork matches it");
        check(wk_cookieMayBeSet(CFSTR("__Host-a"), true, CFSTR("/"), false, secure),
              "a __Host- cookie with a root path and no Domain is set");
        check(!wk_cookieMayBeSet(CFSTR("__Host-a"), true, CFSTR("/x"), false, secure),
              "one with another path is not");
        check(!wk_cookieMayBeSet(CFSTR("__Host-a"), true, CFSTR("/"), true, secure),
              "and neither is one that carried a Domain attribute");

        bool setsNothing = true;
        CFStringRef kept = wk_cookieFieldWithoutRefusedCookiesCreate(
            CFSTR("good=1; Path=/, __Host-bad=2; Secure; Path=/; Domain=example.com"), secure, &setsNothing);
        check(kept && !setsNothing && CFStringFind(kept, CFSTR("good=1"), 0).location != kCFNotFound
              && CFStringFind(kept, CFSTR("__Host-bad"), 0).location == kCFNotFound,
              "a field keeps the cookies that may be set and drops the one that may not");
        CFStringRef none = wk_cookieFieldWithoutRefusedCookiesCreate(
            CFSTR("__Host-bad=2; Secure; Path=/x"), secure, &setsNothing);
        check(none && setsNothing, "a field whose every cookie is refused sets nothing");

        // The Domain attribute is read off the string: a cookie set with Domain= an IPv4 literal comes
        // back from the parser with the host and no leading dot, exactly like a host-only cookie.
        CFURLRef literal = CFURLCreateWithString(NULL, CFSTR("https://127.0.0.1/"), NULL);
        CFStringRef refusedByDomain = wk_cookieFieldWithoutRefusedCookiesCreate(
            CFSTR("__Host-a=1; Secure; Path=/; Domain=127.0.0.1"), literal, &setsNothing);
        check(refusedByDomain && setsNothing, "a __Host- cookie with Domain= an address literal is refused");
        CFStringRef keptWithoutDomain = wk_cookieFieldWithoutRefusedCookiesCreate(
            CFSTR("__Host-a=1; Secure; Path=/"), literal, &setsNothing);
        check(!keptWithoutDomain, "and the same cookie without the attribute is kept");
        CFStringRef emptyDomain = wk_cookieFieldWithoutRefusedCookiesCreate(
            CFSTR("__Host-a=1; Secure; Path=/; Domain="), literal, &setsNothing);
        check(!emptyDomain, "an empty Domain= is no attribute at all");
        if (refusedByDomain)
            CFRelease(refusedByDomain);
        if (keptWithoutDomain)
            CFRelease(keptWithoutDomain);
        if (emptyDomain)
            CFRelease(emptyDomain);
        CFRelease(literal);
        if (kept)
            CFRelease(kept);
        if (none)
            CFRelease(none);
        CFRelease(secure);
        CFRelease(plain);
    }

    // The 400-day ceiling, expressed by appending Max-Age to the cookies that exceed it.
    {
        CFURLRef url = CFURLCreateWithString(NULL, CFSTR("https://example.com/"), NULL);
        CFStringRef longOne = wk_cookieLifetimeCappedHeaderCreate(
            CFSTR("a=1; max-age=99999999999999999999999999999; path=/"), url);
        check(longOne && CFStringFind(longOne, CFSTR("max-age=34560000"), 0).location != kCFNotFound
              && CFStringFind(longOne, CFSTR("99999"), 0).location == kCFNotFound,
              "a cookie past the ceiling has its Max-Age replaced");
        CFStringRef byDate = wk_cookieLifetimeCappedHeaderCreate(
            CFSTR("a=1; expires=Wed, 01 Jan 2094 00:00:00 GMT; path=/"), url);
        check(byDate && CFStringHasSuffix(byDate, CFSTR("; Max-Age=34560000")),
              "a cookie dated past the ceiling takes a Max-Age that decides its lifetime");
        if (byDate)
            CFRelease(byDate);
        check(wk_cookieLifetimeCappedHeaderCreate(CFSTR("a=1; max-age=60; path=/"), url) == NULL,
              "a short-lived cookie is left alone");
        check(wk_cookieLifetimeCappedHeaderCreate(CFSTR("a=1; path=/"), url) == NULL,
              "a session cookie has no lifetime to cap");
        // A quoted value carries its own semicolons and its own "max-age": the scan must not anchor
        // inside it, and no byte of the value may be rewritten.
        CFStringRef quoted = wk_cookieLifetimeCappedHeaderCreate(
            CFSTR("a=\"; max-age=1\"; expires=Wed, 01 Jan 2094 00:00:00 GMT"), url);
        check(quoted && CFStringFind(quoted, CFSTR("a=\"; max-age=1\""), 0).location != kCFNotFound,
              "a quoted cookie value survives the cap byte for byte");
        check(quoted && CFStringHasSuffix(quoted, CFSTR("; Max-Age=34560000")),
              "and the cookie is capped by an appended Max-Age");
        if (quoted)
            CFRelease(quoted);

        CFStringRef pair = wk_cookieLifetimeCappedHeaderCreate(
            CFSTR("a=1; max-age=60, b=2; max-age=99999999999"), url);
        check(pair && CFStringFind(pair, CFSTR("a=1; max-age=60"), 0).location != kCFNotFound
              && CFStringFind(pair, CFSTR("b=2; max-age=34560000"), 0).location != kCFNotFound,
              "one cookie of a folded field is capped and the other is left alone");
        if (longOne)
            CFRelease(longOne);
        if (pair)
            CFRelease(pair);
        if (url)
            CFRelease(url);
    }

    check(wk_sameSiteCopyServerComment(NULL) == NULL, "no comment stays no comment");
    check(wk_sameSiteCommentCreate(NULL, NULL) == NULL, "nothing to carry encodes to nothing");

    // The creation time a caller of +[NSHTTPCookie cookieWithProperties:] asked for rides in the same
    // blob, because 10.9's record cannot carry it (any "Created" a caller passes comes back as 1).
    {
        CFStringRef withEverything = wk_cookieBlobCreate(CFSTR("Strict"), CFSTR("100000"), CFSTR("a server comment"));
        CFStringRef created = withEverything ? wk_cookieBlobCopyCreated(withEverything) : NULL;
        CFStringRef policy = withEverything ? wk_sameSiteCopyValue(withEverything) : NULL;
        CFStringRef comment = withEverything ? wk_sameSiteCopyServerComment(withEverything) : NULL;
        check(created && CFEqual(created, CFSTR("100000")), "a creation time reads back");
        check(policy && CFEqual(policy, CFSTR("Strict")), "alongside the attribute");
        check(comment && CFEqual(comment, CFSTR("a server comment")), "and the server's own comment");
        if (created)
            CFRelease(created);
        if (policy)
            CFRelease(policy);
        if (comment)
            CFRelease(comment);
        if (withEverything)
            CFRelease(withEverything);

        CFStringRef timeOnly = wk_cookieBlobCreate(NULL, CFSTR("810100830.5"), NULL);
        CFStringRef readBack = timeOnly ? wk_cookieBlobCopyCreated(timeOnly) : NULL;
        check(readBack && CFEqual(readBack, CFSTR("810100830.5")), "a creation time alone reads back");
        check(timeOnly && wk_sameSiteCopyValue(timeOnly) == NULL, "and carries no attribute");
        check(timeOnly && wk_sameSitePolicyOfComment(timeOnly) == WK_SAME_SITE_NONE, "so it restricts nothing");
        if (readBack)
            CFRelease(readBack);
        if (timeOnly)
            CFRelease(timeOnly);

        CFStringRef plain = CFSTR("a comment the server sent");
        check(wk_cookieBlobCopyCreated(plain) == NULL, "a comment that is not one of ours carries no time");
        check(wk_cookieBlobCreate(NULL, NULL, plain) != NULL, "and encodes to itself");
    }

    // A field as long as the record carries: 10.9 stores a comment of thousands of characters and hands
    // it back whole (measured), so the encoding has no length of its own to stop at.
    {
        CFMutableStringRef huge = CFStringCreateMutable(NULL, 0);
        for (int i = 0; i < 3000; ++i)
            CFStringAppend(huge, CFSTR("S"));
        CFStringRef blob = wk_sameSiteCommentCreate(CFSTR("Lax"), huge);
        CFStringRef carried = blob ? wk_sameSiteCopyServerComment(blob) : NULL;
        check(carried && CFEqual(carried, huge), "a comment of 3000 characters is carried whole");
        check(blob && wk_sameSitePolicyOfComment(blob) == WK_SAME_SITE_LAX, "alongside the attribute");
        if (carried)
            CFRelease(carried);
        if (blob)
            CFRelease(blob);
        CFRelease(huge);
    }

    // Read the way CookieCocoa's coreSameSitePolicy reads it.
    checkPolicy("Strict", WK_SAME_SITE_STRICT, "Strict reads as Strict");
    checkPolicy("strict", WK_SAME_SITE_STRICT, "strict reads as Strict");
    checkPolicy("LAX", WK_SAME_SITE_LAX, "LAX reads as Lax");
    checkPolicy("None", WK_SAME_SITE_NONE, "None reads as unspecified");
    checkPolicy("whatever", WK_SAME_SITE_NONE, "an unrecognised value reads as unspecified");
    checkPolicy("", WK_SAME_SITE_NONE, "an empty value reads as unspecified");

    // RFC 6265bis 5.5.
    check(wk_sameSiteAllows(WK_SAME_SITE_STRICT, true, false, false), "Strict rides a same-site request");
    check(!wk_sameSiteAllows(WK_SAME_SITE_STRICT, false, true, true), "Strict rides no cross-site request");
    check(wk_sameSiteAllows(WK_SAME_SITE_LAX, false, true, true), "Lax rides a cross-site safe navigation");
    check(!wk_sameSiteAllows(WK_SAME_SITE_LAX, false, true, false), "Lax rides no cross-site POST navigation");
    check(!wk_sameSiteAllows(WK_SAME_SITE_LAX, false, false, true), "Lax rides no cross-site subresource");
    check(wk_sameSiteAllows(WK_SAME_SITE_NONE, false, false, false), "an unrestricted cookie rides anything");

    // The same-site comparison, made again at each hop.
    checkSameSite("http://localhost:9/a", "http://localhost:9/b", true, "one host is same-site with itself");
    checkSameSite("http://localhost:9/a", "http://127.0.0.1:9/b", false, "localhost and 127.0.0.1 are two sites");
    checkSameSite("http://www.example.com/a", "http://api.example.com/b", true, "one registrable domain");
    checkSameSite("http://example.com/a", "http://example.org/b", false, "two registrable domains");
    checkSameSite("", "http://example.com/b", false, "an empty site is same-site with nothing");

    // The rewrite, stated as the cookies that reach the jar.
    checkRewrite("no attribute", "a=1; Path=/", "[a=1|-]");
    checkRewrite("one cookie", "a=1; Path=/; SameSite=Strict", "[a=1|wk:1 ss=Strict]");
    checkRewrite("attribute and comment", "a=1; Path=/; Comment=mine; SameSite=Lax", "[a=1|wk:2 c=mine ss=Lax]");
    checkRewrite("comment after attribute", "a=1; Path=/; SameSite=Lax; Comment=mine", "[a=1|wk:2 c=mine ss=Lax]");
    checkRewrite("repeated attribute", "a=1; Path=/; SameSite=Lax; SameSite=Strict", "[a=1|wk:1 ss=Strict]");
    checkRewrite("two cookies, one marked", "p=1; Path=/, q=2; Path=/; SameSite=Strict",
                 "[p=1|-][q=2|wk:1 ss=Strict]");
    checkRewrite("two cookies, both marked", "p=1; Path=/; SameSite=Lax, q=2; Path=/; SameSite=Strict",
                 "[p=1|wk:1 ss=Lax][q=2|wk:1 ss=Strict]");
    checkRewrite("a comment left alone", "p=1; Path=/; Comment=keep, q=2; Path=/; SameSite=Strict",
                 "[p=1|keep][q=2|wk:1 ss=Strict]");
    // A value carrying the literal text of the attribute keeps every byte of it.
    checkRewrite("the text inside a value", "trap=\"x SameSite=Lax y\"; Path=/, q=2; Path=/; SameSite=Strict",
                 "[trap=\"x SameSite=Lax y\"|-][q=2|wk:1 ss=Strict]");
    checkRewrite("the text inside a value, past a semicolon",
                 "trap=\"x; SameSite=Lax y\"; Path=/, q=2; Path=/; SameSite=Strict",
                 "[trap=\"x; SameSite=Lax y\"|-][q=2|wk:1 ss=Strict]");

    // A value that restricts nothing is left for 10.9 to drop, so the cookie is stored exactly as it
    // would have been without this layer.
    checkRewrite("none", "a=1; Path=/; SameSite=None", "[a=1|-]");
    checkRewrite("a value the constants do not name", "a=1; Path=/; SameSite=Sometimes", "[a=1|-]");
    checkRewrite("none alongside a comment", "a=1; Path=/; Comment=mine; SameSite=None", "[a=1|mine]");
    checkRewrite("none and a restriction in one field",
                 "p=1; Path=/; SameSite=None, q=2; Path=/; SameSite=Lax", "[p=1|-][q=2|wk:1 ss=Lax]");
    // The grammar allows space around an attribute's value.
    checkRewrite("spaces around the value", "a=1; Path=/; SameSite = Lax ", "[a=1|wk:1 ss=Lax]");

    // A comma inside an Expires date and a comma inside a value are not fold boundaries, so a cookie
    // that shares a field with one carrying a control character keeps every byte the server sent it.
    checkControlSplit("a date's comma is not a boundary",
                      "a=1; Expires=Wed, 09 Jun 2027 10:18:14 GMT, b=2\x01",
                      "a=1; Expires=Wed, 09 Jun 2027 10:18:14 GMT");
    checkControlSplit("a comma with no name= after it divides nothing",
                      "a=1,2, b=3\x01", "a=1,2");
    checkControlSplit("the cookie carrying it is the only one dropped",
                      "good=1, bad=2\x01, alsogood=3", "good=1, alsogood=3");
    checkControlSplit("a field whose every cookie carries one", "bad=1\x01, worse=2\x02", NULL);
    checkRangeCountMatchesParser("a=1");
    checkRangeCountMatchesParser("a=1, b=2");
    checkRangeCountMatchesParser("a=1,2, b=3");
    checkRangeCountMatchesParser("a=1; Expires=Wed, 09 Jun 2027 10:18:14 GMT");
    checkRangeCountMatchesParser("a=1; Expires=Wed, 09 Jun 2027 10:18:14 GMT, b=2");
    checkRangeCountMatchesParser("a=\"x,y\"; Path=/");
    checkRangeCountMatchesParser("a=\"x,y\"; Path=/, b=2");
    checkRangeCountMatchesParser("a=1; Path=/; SameSite=Lax, b=2; SameSite=Strict");

    checkControlSplit("a quoted comma is not a boundary",
                      "a=\"x,y\"; Path=/, b=2\x01", "a=\"x,y\"; Path=/");
    checkRewrite("a quoted semicolon begins no attribute",
                 "a=\"x; SameSite=Strict\"; Path=/", "[a=\"x; SameSite=Strict\"|-]");

    // A field carrying as many attributes as a busy response: every one of them is carried, and the
    // cost is one parse for the round that attributes them all rather than one parse each.
    {
        CFMutableStringRef many = CFStringCreateMutable(NULL, 0);
        CFMutableStringRef expected = CFStringCreateMutable(NULL, 0);
        for (int i = 0; i < 100; ++i) {
            CFStringAppendFormat(many, NULL, CFSTR("%sc%d=v%d; Path=/; SameSite=Lax"), i ? ", " : "", i, i);
            CFStringAppendFormat(expected, NULL, CFSTR("[c%d=v%d|wk:1 ss=Lax]"), i, i);
        }
        char *text = utf8(many);
        char *want = utf8(expected);
        checkRewrite("a hundred cookies, each restricted", text, want);
        free(text);
        free(want);
        CFRelease(many);
        CFRelease(expected);
    }

    // A comment far longer than any field this layer writes for itself: the record carries it, so the
    // rewrite carries it too rather than dropping the cookie that has it.
    {
        CFMutableStringRef longComment = CFStringCreateMutable(NULL, 0);
        for (int i = 0; i < 500; ++i)
            CFStringAppend(longComment, CFSTR("c"));
        CFMutableStringRef header = CFStringCreateMutable(NULL, 0);
        CFStringAppendFormat(header, NULL, CFSTR("a=1; Path=/; Comment=%@; SameSite=Strict"), longComment);
        CFMutableStringRef expected = CFStringCreateMutable(NULL, 0);
        CFStringAppendFormat(expected, NULL, CFSTR("[a=1|wk:2 c=%@ ss=Strict]"), longComment);
        char *text = utf8(header);
        char *want = utf8(expected);
        checkRewrite("a long comment alongside the attribute", text, want);
        free(text);
        free(want);
        CFRelease(longComment);
        CFRelease(header);
        CFRelease(expected);
    }

    // The constructors this layer replaces: a property dictionary's attribute travels into the Comment
    // the record has, and a value that restricts nothing leaves the cookie as the caller wrote it.
    {
        SEL initWithProperties = sel_getUid("wk_initWithProperties:");
        SEL cookieWithProperties = sel_getUid("wk_cookieWithProperties:");
        if (![NSHTTPCookie instancesRespondToSelector:initWithProperties]) {
            printf("  FAIL: the layer's -initWithProperties: is not installed on NSHTTPCookie\n");
            ++failures;
        } else {
            CFMutableStringRef huge = CFStringCreateMutable(NULL, 0);
            for (int i = 0; i < 300; ++i)
                CFStringAppend(huge, CFSTR("S"));
            NSDictionary *unrestricted = @{ NSHTTPCookieName: @"c", NSHTTPCookieValue: @"v",
                                            NSHTTPCookiePath: @"/", NSHTTPCookieDomain: @"z.test",
                                            @"SameSite": (NSString *)huge };
            id built = [((id (*)(id, SEL, id))objc_msgSend)([NSHTTPCookie alloc], initWithProperties, unrestricted) autorelease];
            check(built != nil, "a value the constants do not name still builds the cookie");
            check(built && !((NSString *(*)(id, SEL))objc_msgSend)(built, sel_getUid("wk_sameSitePolicy")),
                  "and the cookie reports no policy");
            check(((id (*)(id, SEL, id))objc_msgSend)([NSHTTPCookie class], cookieWithProperties, unrestricted) != nil,
                  "and the class method builds it too");
            NSDictionary *restricted = @{ NSHTTPCookieName: @"c", NSHTTPCookieValue: @"v",
                                          NSHTTPCookiePath: @"/", NSHTTPCookieDomain: @"z.test",
                                          NSHTTPCookieComment: (NSString *)huge,
                                          @"SameSite": @"Strict" };
            id cookie = [((id (*)(id, SEL, id))objc_msgSend)([NSHTTPCookie alloc], initWithProperties, restricted) autorelease];
            check(cookie != nil, "a restriction alongside a long comment builds the cookie");
            check(cookie && [((NSString *(*)(id, SEL))objc_msgSend)(cookie, sel_getUid("wk_sameSitePolicy"))
                             isEqualToString:@"strict"], "and the cookie reports it");
            check(cookie && [((NSString *(*)(id, SEL))objc_msgSend)(cookie, sel_getUid("wk_comment"))
                             isEqualToString:(NSString *)huge], "and hands back the comment it was given");

            // Text with no UTF-8 of its own, which a script can put in a comment: the cookie built from
            // it is the one those properties make without a restriction at all -- 10.9 stores a lone
            // surrogate as the empty comment (measured) -- rather than a process that ended.
            unichar loneSurrogate = 0xD800;
            NSString *unencodable = [NSString stringWithCharacters:&loneSurrogate length:1];
            NSDictionary *restrictedText = @{ NSHTTPCookieName: @"c", NSHTTPCookieValue: @"v",
                                              NSHTTPCookiePath: @"/", NSHTTPCookieDomain: @"z.test",
                                              NSHTTPCookieComment: unencodable, @"SameSite": @"Strict" };
            NSDictionary *plainText = @{ NSHTTPCookieName: @"c", NSHTTPCookieValue: @"v",
                                         NSHTTPCookiePath: @"/", NSHTTPCookieDomain: @"z.test",
                                         NSHTTPCookieComment: unencodable };
            id kept = [((id (*)(id, SEL, id))objc_msgSend)([NSHTTPCookie alloc], initWithProperties, restrictedText) autorelease];
            id plain = [((id (*)(id, SEL, id))objc_msgSend)([NSHTTPCookie alloc], initWithProperties, plainText) autorelease];
            check(kept != nil, "a comment with no encoding still builds the cookie");
            NSString *keptComment = ((NSString *(*)(id, SEL))objc_msgSend)(kept, sel_getUid("wk_comment"));
            NSString *plainComment = ((NSString *(*)(id, SEL))objc_msgSend)(plain, sel_getUid("wk_comment"));
            check(kept && plain && (keptComment ? [keptComment isEqualToString:plainComment] : !plainComment),
                  "and is the cookie those properties make with no restriction at all");
            check(kept && !((NSString *(*)(id, SEL))objc_msgSend)(kept, sel_getUid("wk_sameSitePolicy")),
                  "and reports no policy rather than ending the process");
            check(wk_sameSiteCommentCreate(CFSTR("Lax"), (CFStringRef)unencodable) == NULL,
                  "and the encoding answers that it cannot carry it");
            CFRelease(huge);
        }
    }

    checkBulkMergeReport();

    printf(failures ? "  %d FAILED\n" : "  ok\n", failures);
    return failures ? 1 : 0;
}
