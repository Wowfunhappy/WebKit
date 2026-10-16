// -[NSUserDefaults volatileDomainForName:] (methods/Foundation.m) answers a dictionary for every domain,
// empty when the domain holds nothing. WTF::overrideUserPreferredLanguages reads NSArgumentDomain,
// adds AppleLanguages to a mutable copy and writes it back; this program, launched with no arguments,
// is in the position of an XPC service doing that.
//
// The body lives in Foundation.o and wk_selref_scope.o installs it under the layer's private selector.
// This image carries the WebKit marker, so its own sends of the public selector are rewritten to it;
// sel_getUid strings are not, and reach 10.9's implementation the way a host app's sends do.
#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <stdio.h>

static int failures;

static void check(int ok, const char *what)
{
    printf("  %-72s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok)
        failures++;
}

static NSDictionary *domainVia(const char *selectorName, NSString *name)
{
    return ((NSDictionary *(*)(id, SEL, NSString *))objc_msgSend)([NSUserDefaults standardUserDefaults], sel_getUid(selectorName), name);
}

static NSString *firstPreferredLanguage(void)
{
    CFArrayRef languages = CFLocaleCopyPreferredLanguages();
    NSString *first = CFArrayGetCount(languages) ? [[(NSString *)CFArrayGetValueAtIndex(languages, 0) retain] autorelease] : nil;
    CFRelease(languages);
    return first;
}

// WTF::overrideUserPreferredLanguages, as written in Source/WTF/wtf/cocoa/LanguageCocoa.mm.
static void overrideLanguages(NSArray *languages)
{
    NSDictionary *existingArguments = [[NSUserDefaults standardUserDefaults] volatileDomainForName:NSArgumentDomain];
    NSMutableDictionary *newArguments = [[existingArguments mutableCopy] autorelease];
    [newArguments setValue:languages forKey:@"AppleLanguages"];
    [[NSUserDefaults standardUserDefaults] setVolatileDomain:newArguments forName:NSArgumentDomain];
}

int main(void)
{
    @autoreleasepool {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

        // The premise: 10.9 lists the argument domain but answers nil for it while it is empty.
        check([[defaults volatileDomainNames] containsObject:NSArgumentDomain], "10.9 lists NSArgumentDomain among the volatile domains");
        check(!domainVia("volatileDomainForName:", NSArgumentDomain), "10.9 answers nil for an empty NSArgumentDomain");

        NSDictionary *arguments = domainVia("wk_volatileDomainForName:", NSArgumentDomain);
        check([arguments isKindOfClass:[NSDictionary class]] && !arguments.count, "an empty NSArgumentDomain is an empty dictionary");
        check([[defaults volatileDomainForName:NSArgumentDomain] isKindOfClass:[NSDictionary class]], "a marked image's own send reaches the polyfill");

        NSDictionary *unknown = domainVia("wk_volatileDomainForName:", @"WKBehaviourNoSuchDomain");
        check([unknown isKindOfClass:[NSDictionary class]] && !unknown.count, "a domain never set is an empty dictionary");

        [defaults setVolatileDomain:@{ @"Key": @"Value" } forName:@"WKBehaviourDomain"];
        check([domainVia("wk_volatileDomainForName:", @"WKBehaviourDomain") isEqualToDictionary:@{ @"Key": @"Value" }], "a populated domain is answered as stored");

        // The read-modify-write lands, and what the system reads afterwards is the override.
        overrideLanguages(@[ @"fr-FR" ]);
        check([[defaults objectForKey:@"AppleLanguages"] isEqual:@[ @"fr-FR" ]], "AppleLanguages reads the override");
        check([firstPreferredLanguage() isEqualToString:@"fr-FR"], "CFLocaleCopyPreferredLanguages leads with the override");

        // A second writer keeps what the first one put there.
        NSMutableDictionary *more = [[[defaults volatileDomainForName:NSArgumentDomain] mutableCopy] autorelease];
        [more setValue:@NO forKey:@"NSTextViewAllowsDowngradeToLayoutManager"];
        [defaults setVolatileDomain:more forName:NSArgumentDomain];
        check([[defaults objectForKey:@"AppleLanguages"] isEqual:@[ @"fr-FR" ]] && [defaults objectForKey:@"NSTextViewAllowsDowngradeToLayoutManager"],
              "a later argument-domain writer preserves AppleLanguages");

        overrideLanguages(@[ @"de-DE" ]);
        check([firstPreferredLanguage() isEqualToString:@"de-DE"], "a second override replaces the first");

        if (failures) {
            printf("Foundation-volatile-domain: %d check(s) failed\n", failures);
            return 1;
        }
        printf("Foundation-volatile-domain: all checks passed\n");
    }
    return 0;
}
