// Native cookie metadata, PSL acceptance, and CF observer-driven notification SPIs.
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

@interface NSString (AddressPredicateTest)
- (BOOL)_web_looksLikeIPAddress;
@end

static void check(bool condition, const char *what)
{
    if (condition)
        return;
    printf("  FAIL: %s\n", what);
    ++failures;
}

@interface NSHTTPCookieStorage (CookieObservationTest)
- (instancetype)_initWithCFHTTPCookieStorage:(CFHTTPCookieStorageRef)storage;
- (void)_setCookiesChangedHandler:(void (^)(NSArray *, NSString *))handler onQueue:(dispatch_queue_t)queue;
- (void)_setCookiesRemovedHandler:(void (^)(NSArray *, NSString *, bool))handler onQueue:(dispatch_queue_t)queue;
- (void)_setSubscribedDomainsForCookieChanges:(NSSet *)domains;
@end
@interface NSObject (CookieInternalObservationTest)
- (void)registerForPostingNotificationsWithContext:(NSHTTPCookieStorage *)context;
@end

static void checkCookieObservers(void)
{
    CFHTTPCookieStorageRef jar = ((CFHTTPCookieStorageRef (*)(CFAllocatorRef, CFDictionaryRef))
        cfnetwork("CFHTTPCookieStorageCreateInMemory"))(NULL, NULL);
    NSHTTPCookieStorage *store = [[NSHTTPCookieStorage alloc] _initWithCFHTTPCookieStorage:jar];
    NSHTTPCookieStorage *otherWrapper = [[NSHTTPCookieStorage alloc] _initWithCFHTTPCookieStorage:jar];
    __block unsigned notifications = 0;
    id token = [[NSNotificationCenter defaultCenter] addObserverForName:NSHTTPCookieManagerCookiesChangedNotification
        object:store queue:nil usingBlock:^(NSNotification *notification) {
            check(notification.object == store, "Internal notification identifies the registered NS wrapper");
            ++notifications;
        }];
    id internal = object_getIvar(store, class_getInstanceVariable([NSHTTPCookieStorage class], "_internal"));
    [internal registerForPostingNotificationsWithContext:store];
    [internal registerForPostingNotificationsWithContext:store];
    __block unsigned stage = 0;
    NSHTTPCookie *(^cookie)(NSString *, BOOL) = ^NSHTTPCookie *(NSString *value, BOOL httpOnly) {
        NSMutableDictionary *properties = [@{ NSHTTPCookieName: @"observed", NSHTTPCookieValue: value,
            NSHTTPCookieDomain: @"observer.test", NSHTTPCookiePath: @"/" } mutableCopy];
        if (httpOnly)
            properties[@"HttpOnly"] = @YES;
        NSHTTPCookie *result = [NSHTTPCookie cookieWithProperties:properties];
        [properties release];
        return result;
    };
    [store _setCookiesChangedHandler:^(NSArray *cookies, NSString *domain) {
        check([domain isEqual:@"observer.test"] && cookies.count == 1, "change batch is filtered to the subscribed domain");
        NSHTTPCookie *changed = cookies[0];
        if (changed.HTTPOnly)
            return;
        if (stage == 0) {
            check([changed.value isEqual:@"one"], "native setCookie emits the added cookie");
            stage = 1;
            [store setCookie:cookie(@"two", NO)];
        } else if (stage == 1) {
            check([changed.value isEqual:@"two"], "same-key replacement emits the new value");
            stage = 2;
            [store setCookie:cookie(@"hidden", YES)];
        } else
            check(false, "no duplicate visible change callback");
    } onQueue:dispatch_get_main_queue()];
    [otherWrapper _setCookiesRemovedHandler:^(NSArray *cookies, NSString *domain, bool removeAll) {
        check(!removeAll && [domain isEqual:@"observer.test"] && cookies.count == 1, "removal batch identifies its subscribed domain");
        NSHTTPCookie *removed = cookies[0];
        if (stage == 2) {
            check(!removed.HTTPOnly && [removed.value isEqual:@"two"], "HttpOnly replacement removes the visible predecessor");
            stage = 3;
            [store deleteCookie:cookie(@"hidden", YES)];
        } else if (stage == 3) {
            check(removed.HTTPOnly, "native deleteCookie emits the stored deleted cookie");
            stage = 4;
            CFRunLoopStop(CFRunLoopGetMain());
        } else
            check(false, "no duplicate removal callback");
    } onQueue:dispatch_get_main_queue()];
    [otherWrapper _setSubscribedDomainsForCookieChanges:[NSSet setWithObject:@"observer.test"]];
    [store setCookie:[NSHTTPCookie cookieWithProperties:@{ NSHTTPCookieName: @"unrelated", NSHTTPCookieValue: @"ignored",
        NSHTTPCookieDomain: @"unrelated.test", NSHTTPCookiePath: @"/" }]];
    [store setCookie:cookie(@"one", NO)];
    // One bounded event-loop run; callbacks drive the mutation sequence and stop it on completion.
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 10, false);
    printf("    [observer stage=%u notifications=%u]\n", stage, notifications);
    check(stage == 4, "native storage observer completed add, replace, HttpOnly overwrite, and delete");
    check(notifications > 0, "Internal SPI posts native mutation notifications");
    [store _setCookiesChangedHandler:nil onQueue:nil];
    [otherWrapper _setCookiesRemovedHandler:nil onQueue:nil];
    [store _setSubscribedDomainsForCookieChanges:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:token];
    [otherWrapper release];
    [store release];
    CFRelease(jar);
}

static void checkPublicSetterPolicy(void)
{
    CFHTTPCookieStorageRef jar = ((CFHTTPCookieStorageRef (*)(CFAllocatorRef, CFDictionaryRef))
        cfnetwork("CFHTTPCookieStorageCreateInMemory"))(NULL, NULL);
    NSHTTPCookieStorage *store = [[NSHTTPCookieStorage alloc] _initWithCFHTTPCookieStorage:jar];
    store.cookieAcceptPolicy = NSHTTPCookieAcceptPolicyAlways;
    NSURL *url = [NSURL URLWithString:@"https://project.pages.dev/"];
    for (NSString *domain in @[@".pages.dev", @".project.pages.dev"]) {
        [store setCookies:@[[NSHTTPCookie cookieWithProperties:@{ NSHTTPCookieName: @"psl", NSHTTPCookieValue: @"1",
            NSHTTPCookieDomain: domain, NSHTTPCookiePath: @"/" }]] forURL:url mainDocumentURL:url];
    }
    check(store.cookies.count == 1 && [[store.cookies[0] domain] isEqual:@".project.pages.dev"],
        "public setter rejects a modern private suffix and accepts its tenant domain");
    [store release];
    CFRelease(jar);
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
    CFStringRef blob = wk_cookieBlobCreate(policy, NULL, NULL, original);
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

static void checkPolicy(const char *sameSite, wk_same_site_policy expected, const char *what)
{
    CFStringRef policy = str(sameSite);
    CFStringRef blob = wk_cookieBlobCreate(policy, NULL, NULL, NULL);
    check(blob && wk_sameSitePolicyOfComment(blob) == expected, what);
    if (blob)
        CFRelease(blob);
    CFRelease(policy);
}

// Whether a response's cookies are held to the main document's domain under
// NSHTTPCookieAcceptPolicyOnlyFromMainDocumentDomain, where 10.9's own table would take them.
static void checkOnlyATopLevelDomain(const char *url, const char *mainDocumentURL, bool expected, const char *what)
{
    CFStringRef urlText = str(url), mainText = str(mainDocumentURL);
    CFURLRef a = CFURLCreateWithString(NULL, urlText, NULL);
    CFURLRef b = CFURLCreateWithString(NULL, mainText, NULL);
    check(wk_hostsHaveDifferentRegistrableDomains(a, b) == expected, what);
    if (a)
        CFRelease(a);
    if (b)
        CFRelease(b);
    CFRelease(urlText);
    CFRelease(mainText);
}

// The registrable domain of a host, which decides what is same-site.
static void checkRegistrableDomain(const char *host, const char *expected, const char *what)
{
    CFStringRef hostText = str(host);
    CFStringRef domain = wk_copyRegistrableDomain(hostText);
    char *actual = domain ? utf8(domain) : NULL;
    if (!actual || strcmp(actual, expected)) {
        printf("  FAIL: %s\n        host %s -> %s, expected %s\n", what, host, actual ? actual : "(null)", expected);
        ++failures;
    }
    free(actual);
    if (domain)
        CFRelease(domain);
    CFRelease(hostText);
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
// A cookie this file wrote, and only that: sharedHTTPCookieStorage is the account's own jar.
static void forgetCookiesOfDomain(NSHTTPCookieStorage *storage, NSString *domain)
{
    for (NSHTTPCookie *held in [[storage.cookies copy] autorelease]) {
        if ([held.domain rangeOfString:domain].location != NSNotFound)
            [storage deleteCookie:held];
    }
}
int main(void)
{
    printf("Native cookie metadata and read policy:\n");
    for (NSString *address in @[@"127.0.0.1", @"::1", @"[::1]", @"[2001:db8::1]"]) {
        check(wk_hostIsIPAddress((CFStringRef)address), "native-cookie address parser recognizes IP literals");
        check([address _web_looksLikeIPAddress], "Cocoa URL address predicate recognizes IP literals");
    }
    for (NSString *name in @[@"policy.test", @"1.2.3", @"999.1.1.1", @"[not-an-address]", @"[127.0.0.1]", @"a:b"]) {
        check(!wk_hostIsIPAddress((CFStringRef)name), "native-cookie address parser rejects non-addresses");
        check(![name _web_looksLikeIPAddress], "Cocoa URL address predicate rejects non-addresses");
    }


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
    // RFC 6265 5.1.4: a cookie-path matches on a path-segment boundary. 10.9 tests only the prefix, so
    // -[NSHTTPCookieStorage cookiesForURL:] answers a Path=/cook cookie for /cookies/x without the
    // replacement in methods/Foundation.m.
    {
        struct { const char *cookiePath; const char *readPath; bool served; } cases[] = {
            { "/cook",              "/cookies/x.html",    false },
            { "/cookies",           "/cookies/x.html",    true  },
            { "/cookies/",          "/cookies/x.html",    true  },
            { "/cookies/x.html",    "/cookies/x.html",    true  },
            { "/cookies/resources", "/cookies/x.html",    false },
            { "/",                  "/cookies/x.html",    true  },
        };
        NSHTTPCookieStorage *storage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
        for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i) {
            forgetCookiesOfDomain(storage, @"path.test");
            NSString *cookiePath = [NSString stringWithUTF8String:cases[i].cookiePath];
            NSURL *readURL = [NSURL URLWithString:[NSString stringWithFormat:@"http://path.test%s", cases[i].readPath]];
            NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:@{
                NSHTTPCookieName: @"p", NSHTTPCookieValue: @"1",
                NSHTTPCookieDomain: @"path.test", NSHTTPCookiePath: cookiePath }];
            [storage setCookie:cookie];
            bool served = [storage cookiesForURL:readURL].count == 1;
            char label[160];
            snprintf(label, sizeof(label), "Path=%s %s served at %s", cases[i].cookiePath,
                     cases[i].served ? "is" : "is not", cases[i].readPath);
            check(served == cases[i].served, label);
            forgetCookiesOfDomain(storage, @"path.test");
        }
    }

    // RFC 6265bis 5.5 sends the longer cookie-path first. 10.9 answers host-only cookies ahead of the
    // ones carrying a Domain attribute and orders by path length only inside each group.
    {
        NSHTTPCookieStorage *storage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
        forgetCookiesOfDomain(storage, @"order.test");
        // The shape of ordering.sub.html's first case: two host-only cookies and two with a Domain.
        struct { const char *name; const char *path; bool withDomain; } written[] = {
            { "testB", "/cookies",             false },
            { "testC", "/",                    false },
            { "testE", "/",                    true  },
            { "testF", "/cookies/attributes",  true  },
        };
        for (size_t i = 0; i < sizeof(written) / sizeof(written[0]); ++i) {
            NSMutableDictionary *properties = [@{
                NSHTTPCookieName: [NSString stringWithUTF8String:written[i].name],
                NSHTTPCookieValue: @"1",
                NSHTTPCookiePath: [NSString stringWithUTF8String:written[i].path] } mutableCopy];
            properties[NSHTTPCookieDomain] = written[i].withDomain ? @".order.test" : @"order.test";
            [storage setCookie:[NSHTTPCookie cookieWithProperties:properties]];
        }
        NSArray<NSHTTPCookie *> *answered = [storage cookiesForURL:[NSURL URLWithString:@"http://order.test/cookies/attributes/x.html"]];
        NSMutableArray *names = [NSMutableArray array];
        bool descending = true;
        for (NSUInteger i = 0; i < answered.count; ++i) {
            [names addObject:answered[i].name];
            if (i && answered[i].path.length > answered[i - 1].path.length)
                descending = false;
        }
        NSString *got = [names componentsJoinedByString:@","];
        // The two /-path cookies tie, and the order among them is the one 10.9 gave: the RFC breaks that
        // tie by creation time, which this platform records only to the second.
        check(descending && answered.count == 4 && [names[0] isEqualToString:@"testF"] && [names[1] isEqualToString:@"testB"],
              [[NSString stringWithFormat:@"longer cookie-paths are sent first (got %@)", got] UTF8String]);
        forgetCookiesOfDomain(storage, @"order.test");
    }

    check(wk_sameSiteCopyServerComment(NULL) == NULL, "no comment stays no comment");
    check(wk_cookieBlobCreate(NULL, NULL, NULL, NULL) == NULL, "nothing to carry encodes to nothing");

    // The creation time a caller of +[NSHTTPCookie cookieWithProperties:] asked for rides in the same
    // blob, because 10.9's record cannot carry it (any "Created" a caller passes comes back as 1).
    {
        CFStringRef withEverything = wk_cookieBlobCreate(CFSTR("Strict"), CFSTR("100000"), NULL, CFSTR("a server comment"));
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

        CFStringRef timeOnly = wk_cookieBlobCreate(NULL, CFSTR("810100830.5"), NULL, NULL);
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
        check(wk_cookieBlobCreate(NULL, NULL, NULL, plain) != NULL, "and encodes to itself");
    }

    // Whether a script wrote the cookie rides in the same blob, for the same reason: 10.9's record
    // drops the property.
    {
        CFStringRef marked = wk_cookieBlobCreate(CFSTR("Lax"), CFSTR("100001"), CFSTR("TRUE"), CFSTR("a server comment"));
        CFStringRef mark = marked ? wk_cookieBlobCopySetInJavaScript(marked) : NULL;
        CFStringRef alongsideTime = marked ? wk_cookieBlobCopyCreated(marked) : NULL;
        CFStringRef alongsidePolicy = marked ? wk_sameSiteCopyValue(marked) : NULL;
        CFStringRef alongsideComment = marked ? wk_sameSiteCopyServerComment(marked) : NULL;
        check(mark && CFEqual(mark, CFSTR("TRUE")), "a script-written mark reads back");
        check(alongsideTime && CFEqual(alongsideTime, CFSTR("100001")), "beside the creation time");
        check(alongsidePolicy && CFEqual(alongsidePolicy, CFSTR("Lax")), "the attribute");
        check(alongsideComment && CFEqual(alongsideComment, CFSTR("a server comment")), "and the server's own comment");
        if (mark)
            CFRelease(mark);
        if (alongsideTime)
            CFRelease(alongsideTime);
        if (alongsidePolicy)
            CFRelease(alongsidePolicy);
        if (alongsideComment)
            CFRelease(alongsideComment);
        if (marked)
            CFRelease(marked);

        CFStringRef markOnly = wk_cookieBlobCreate(NULL, NULL, CFSTR("TRUE"), NULL);
        CFStringRef markOnlyBack = markOnly ? wk_cookieBlobCopySetInJavaScript(markOnly) : NULL;
        check(markOnlyBack && CFEqual(markOnlyBack, CFSTR("TRUE")), "a mark alone reads back");
        check(markOnly && wk_cookieBlobCopyCreated(markOnly) == NULL, "and carries no creation time");
        check(markOnly && wk_sameSitePolicyOfComment(markOnly) == WK_SAME_SITE_NONE, "so it restricts nothing");
        if (markOnlyBack)
            CFRelease(markOnlyBack);
        if (markOnly)
            CFRelease(markOnly);

        CFStringRef unmarked = wk_cookieBlobCreate(CFSTR("Lax"), CFSTR("100002"), NULL, NULL);
        check(unmarked && wk_cookieBlobCopySetInJavaScript(unmarked) == NULL, "a blob without the field reads back no mark");
        check(wk_cookieBlobCopySetInJavaScript(CFSTR("a comment the server sent")) == NULL,
            "and neither does a comment that is not one of ours");
        if (unmarked)
            CFRelease(unmarked);
    }

    // A field as long as the record carries: 10.9 stores a comment of thousands of characters and hands
    // it back whole (measured), so the encoding has no length of its own to stop at.
    {
        CFMutableStringRef huge = CFStringCreateMutable(NULL, 0);
        for (int i = 0; i < 3000; ++i)
            CFStringAppend(huge, CFSTR("S"));
        CFStringRef blob = wk_cookieBlobCreate(CFSTR("Lax"), NULL, NULL, huge);
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
    checkPolicy("whatever", WK_SAME_SITE_LAX, "an unrecognised value takes the default enforcement");
    checkPolicy("", WK_SAME_SITE_LAX, "an empty value takes the default enforcement");
    checkPolicy("Unsupported", WK_SAME_SITE_LAX, "the value WPT writes takes the default enforcement");

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
    checkSameSite("https://www1.web-platform.test:9443/a", "https://web-platform.test:9443/b", true,
        "a subdomain of a host under a label 10.9's table predates is same-site with it");

    // 10.9's table holds com, org, net, xyz, io and co.uk, and not test, app or dev.
    checkRegistrableDomain("www1.web-platform.test", "web-platform.test", "a newer label is a public suffix");
    checkRegistrableDomain("www.example.com", "example.com", "a label the table holds still answers");
    checkRegistrableDomain("a.b.example.co.uk", "example.co.uk", "a two-label public suffix still answers");
    checkRegistrableDomain("web-platform.test", "web-platform.test", "a two-label host is its own domain");
    checkRegistrableDomain("localhost", "localhost", "localhost is its own domain");
    checkRegistrableDomain("127.0.0.1", "127.0.0.1", "an address is its own domain");
    check(wk_domainIsPublicSuffix(CFSTR("pages.dev")), "modern private public suffix");
    check(wk_domainIsPublicSuffix(CFSTR("foo.ck")), "PSL wildcard suffix");
    check(!wk_domainIsPublicSuffix(CFSTR("www.ck")), "PSL exception");
    check(wk_domainIsPublicSuffix(CFSTR("公司.cn")), "Unicode PSL entry");
    check(wk_domainIsPublicSuffix(CFSTR("xn--55qx5d.cn")), "ACE PSL entry");
    checkRegistrableDomain("a.project.pages.dev", "project.pages.dev", "modern private registrable domain");
    checkRegistrableDomain("a.www.ck", "www.ck", "PSL exception registrable domain");
    checkSameSite("https://one.pages.dev/a", "https://two.pages.dev/b", false, "private-suffix tenants are separate sites");

    checkOnlyATopLevelDomain("https://not-web-platform.test/a", "https://web-platform.test/b", true,
        "two hosts sharing only a label the table predates");
    checkOnlyATopLevelDomain("https://one.pages.dev/a", "https://two.pages.dev/b", true, "different private-suffix tenants");
    checkOnlyATopLevelDomain("https://evil.app/a", "https://victim.app/b", true, "the same under .app");
    checkOnlyATopLevelDomain("https://evil.com/a", "https://victim.com/b", true, "the same under .com");
    checkOnlyATopLevelDomain("https://www1.web-platform.test/a", "https://web-platform.test/b", false,
        "a subdomain shares more than a top-level domain");
    checkOnlyATopLevelDomain("https://a.example.co.uk/x", "https://b.example.co.uk/y", false,
        "two hosts under one registrable domain");
    checkOnlyATopLevelDomain("https://web-platform.test/a", "https://web-platform.test/b", false,
        "one host with itself");

    // A cookie's name and value are byte sequences, not ASCII. The constructors this layer replaces
    // rebuild the property dictionary, so they are the place a non-ASCII name or value could be lost.
    {
        SEL cookieWithProperties = sel_getUid("wk_cookieWithProperties:");
        struct { NSString *name; NSString *value; const char *what; } cases[] = {
            { @"ascii", @"ok", "an ASCII cookie survives the constructor" },
            { @"latin", @"h\u00e9llo", "a Latin-1 value survives the constructor" },
            { @"\U0001F36A", @"\U0001F535", "a name and value outside the BMP survive the constructor" },
        };
        for (unsigned i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i) {
            NSDictionary *properties = @{ NSHTTPCookieName: cases[i].name, NSHTTPCookieValue: cases[i].value,
                                          NSHTTPCookieDomain: @"encoding.test", NSHTTPCookiePath: @"/",
                                          NSHTTPCookieVersion: @"1" };
            NSHTTPCookie *built = ((id (*)(id, SEL, id))objc_msgSend)([NSHTTPCookie class],
                cookieWithProperties, properties);
            bool kept = built && [[built name] isEqualToString:cases[i].name]
                && [[built value] isEqualToString:cases[i].value];
            check(kept, cases[i].what);
            if (!kept)
                printf("        built=%s name=[%s] value=[%s]\n", built ? "yes" : "no",
                       built ? [[built name] UTF8String] : "-", built ? [[built value] UTF8String] : "-");
        }
    }

    // The seam the Cookie Store API's set reaches in the network process, over a non-ASCII name and
    // value: a cookie's name and value are byte sequences and must survive it whole.
    {
        SEL setCookies = sel_getUid("wk__setCookies:forURL:mainDocumentURL:policyProperties:");
        CFTypeRef jar = ((CFTypeRef (*)(CFAllocatorRef, CFDictionaryRef))
            cfnetwork("CFHTTPCookieStorageCreateInMemory"))(NULL, NULL);
        NSHTTPCookieStorage *store = ((id (*)(id, SEL, CFTypeRef))objc_msgSend)([NSHTTPCookieStorage alloc],
            sel_getUid("_initWithCFHTTPCookieStorage:"), jar);
        NSURL *url = [NSURL URLWithString:@"http://encoding.test/x"];
        NSMutableArray *cookies = [NSMutableArray array];
        for (NSArray *pair in @[ @[@"ascii", @"ok"], @[@"latin", @"h\u00e9llo"], @[@"\U0001F36A", @"\U0001F535"] ]) {
            [cookies addObject:[NSHTTPCookie cookieWithProperties:@{
                NSHTTPCookieName: pair[0], NSHTTPCookieValue: pair[1],
                NSHTTPCookieDomain: @"encoding.test", NSHTTPCookiePath: @"/", NSHTTPCookieVersion: @"1" }]];
        }
        if (![store respondsToSelector:setCookies]) {
            printf("  FAIL: the layer's -_setCookies:forURL:mainDocumentURL:policyProperties: is not installed\n");
            ++failures;
        } else {
            ((void (*)(id, SEL, id, id, id, id))objc_msgSend)(store, setCookies, cookies, url, url, nil);
            check([[store cookiesForURL:url] count] == 3, "a non-ASCII name and value survive the set seam");
            for (NSHTTPCookie *k in [store cookiesForURL:url])
                printf("    [stored %s=%s]\n", [[k name] UTF8String], [[k value] UTF8String]);
        }
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
            check(built && [((NSString *(*)(id, SEL))objc_msgSend)(built, sel_getUid("wk_sameSitePolicy")) isEqualToString:@"lax"],
                  "an unrecognized SameSite value takes default enforcement");
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

            // All NSString code units survive metadata encoding, including an unpaired surrogate.
            unichar loneSurrogate = 0xD800;
            NSString *unencodable = [NSString stringWithCharacters:&loneSurrogate length:1];
            NSDictionary *restrictedText = @{ NSHTTPCookieName: @"c", NSHTTPCookieValue: @"v",
                NSHTTPCookiePath: @"/", NSHTTPCookieDomain: @"z.test",
                NSHTTPCookieComment: unencodable, @"SameSite": @"Strict" };
            id kept = [((id (*)(id, SEL, id))objc_msgSend)([NSHTTPCookie alloc], initWithProperties, restrictedText) autorelease];
            check(kept != nil, "a cookie with a UTF-16 comment is created");
            check([((NSString *(*)(id, SEL))objc_msgSend)(kept, sel_getUid("wk_comment")) isEqualToString:unencodable],
                "the original UTF-16 comment is preserved");
            check([((NSString *(*)(id, SEL))objc_msgSend)(kept, sel_getUid("wk_sameSitePolicy")) isEqualToString:@"strict"],
                "the SameSite restriction survives every comment value");
            CFStringRef blob = wk_cookieBlobCreate(CFSTR("Lax"), NULL, NULL, (CFStringRef)unencodable);
            CFStringRef decoded = wk_sameSiteCopyServerComment(blob);
            check(decoded && CFEqual(decoded, (CFStringRef)unencodable), "UTF-16 metadata round-trips");
            if (decoded)
                CFRelease(decoded);
            if (blob)
                CFRelease(blob);
            CFRelease(huge);
        }
    }

    checkPublicSetterPolicy();
    checkCookieObservers();

    printf(failures ? "  %d FAILED\n" : "  ok\n", failures);
    return failures ? 1 : 0;
}
