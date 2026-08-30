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

    CFStringRef described = NULL;
    if (disposition == WK_SAMESITE_HEADER_REFUSED)
        described = (CFStringRef)CFRetain(CFSTR("REFUSED"));
    else
        described = parseAndDescribe(disposition == WK_SAMESITE_HEADER_REWRITTEN ? rewritten : field, url);

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
    check(wk_sameSiteCopyServerComment(NULL) == NULL, "no comment stays no comment");
    check(wk_sameSiteCommentCreate(NULL, NULL) == NULL, "nothing to carry encodes to nothing");

    // A field this layer cannot carry is refused rather than trimmed to fit.
    {
        CFMutableStringRef huge = CFStringCreateMutable(NULL, 0);
        for (int i = 0; i < 300; ++i)
            CFStringAppend(huge, CFSTR("S"));
        check(wk_sameSiteCommentCreate(huge, NULL) == NULL, "an attribute past the cap is refused");
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

    // The parse cap: past it the field is refused, so the cap is not the way around the attribute.
    {
        CFMutableStringRef many = CFStringCreateMutable(NULL, 0);
        CFStringAppend(many, CFSTR("a=1; Path=/"));
        for (int i = 0; i < 65; ++i)
            CFStringAppend(many, CFSTR("; SameSite=Lax"));
        char *text = utf8(many);
        checkRewrite("past the parse cap", text, "REFUSED");
        free(text);
        CFRelease(many);
    }

    // The refusal path of the constructors this layer replaces: a cookie whose attribute does not fit
    // the field that carries it is refused, and refusing it leaves a live process behind.
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
            NSDictionary *refused = @{ NSHTTPCookieName: @"c", NSHTTPCookieValue: @"v",
                                       NSHTTPCookiePath: @"/", NSHTTPCookieDomain: @"z.test",
                                       @"SameSite": (NSString *)huge };
            id built = ((id (*)(id, SEL, id))objc_msgSend)([NSHTTPCookie alloc], initWithProperties, refused);
            check(!built, "an attribute past the cap refuses the cookie rather than building it");
            check(!((id (*)(id, SEL, id))objc_msgSend)([NSHTTPCookie class], cookieWithProperties, refused),
                  "and refuses it through the class method too");
            NSDictionary *accepted = @{ NSHTTPCookieName: @"c", NSHTTPCookieValue: @"v",
                                        NSHTTPCookiePath: @"/", NSHTTPCookieDomain: @"z.test",
                                        @"SameSite": @"Strict" };
            id cookie = [((id (*)(id, SEL, id))objc_msgSend)([NSHTTPCookie alloc], initWithProperties, accepted) autorelease];
            check(cookie != nil, "an attribute that fits builds the cookie");
            check(cookie && [((NSString *(*)(id, SEL))objc_msgSend)(cookie, sel_getUid("wk_sameSitePolicy"))
                             isEqualToString:@"strict"], "and the cookie reports it");
            CFRelease(huge);
        }
    }

    printf(failures ? "  %d FAILED\n" : "  ok\n", failures);
    return failures ? 1 : 0;
}
