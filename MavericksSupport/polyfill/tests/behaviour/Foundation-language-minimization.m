// +[NSLocale minimizedLanguagesFromLanguages:] (methods/Foundation.m), which WTF::canMinimizeLanguages
// tests for and httpStyleLanguageCode's modern branch consumes.
//
// The bodies live in Foundation.o and wk_selref_scope.o installs them under the layer's private
// selector, which is how a program of our own can drive them.
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <stdio.h>

static int failures;

static void check(int ok, const char *what)
{
    printf("  %-60s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok)
        failures++;
}

static NSArray *minimized(NSArray *languages)
{
    return ((NSArray *(*)(id, SEL, NSArray *))objc_msgSend)([NSLocale class], sel_getUid("wk_minimizedLanguagesFromLanguages:"), languages);
}

static void expect(const char *input, const char *want)
{
    NSArray *result = minimized(@[ @(input) ]);
    NSString *got = result.count == 1 ? result[0] : nil;
    char what[160];
    snprintf(what, sizeof(what), "%s -> %s", input, want);
    check([got isEqualToString:@(want)], what);
    if (![got isEqualToString:@(want)])
        printf("      got %s\n", got.UTF8String ?: "(nothing)");
}

int main(void)
{
    @autoreleasepool {
        // The premise: 10.9 has no implementation of its own for this to shadow.
        check(![NSLocale respondsToSelector:sel_getUid("minimizedLanguagesFromLanguages:")],
              "10.9 does not implement minimizedLanguagesFromLanguages:");

        // A tag that already names a language and a region is returned unchanged.
        expect("en-US", "en-US");
        expect("en-GB", "en-GB");
        expect("fr-CA", "fr-CA");
        expect("pt-BR", "pt-BR");
        expect("pt-PT", "pt-PT");
        expect("es-MX", "es-MX");
        expect("es-419", "es-419");
        expect("zh-TW", "zh-TW");
        expect("zh-HK", "zh-HK");

        // A bare language gains the region CLDR says it implies.
        expect("en", "en-US");
        expect("es", "es-ES");
        expect("fr", "fr-FR");
        expect("hi", "hi-IN");
        expect("ja", "ja-JP");
        expect("ru", "ru-RU");
        expect("pt", "pt-BR");

        // A script subtag is what the region it implies is read from, and does not survive.
        expect("zh-Hans", "zh-CN");
        expect("zh-Hant", "zh-TW");
        expect("zh-Hant-HK", "zh-HK");

        // A script CLDR would not have inferred is information, and stays.
        expect("sr-Latn-RS", "sr-Latn-RS");
        expect("sr-Cyrl-RS", "sr-RS");
        expect("sr", "sr-RS");
        expect("uz-Cyrl", "uz-Cyrl-UZ");

        // Extensions and variants are not part of the pair.
        expect("en-US-u-ca-japanese", "en-US");
        expect("en-Latn-US", "en-US");

        // Case and separator spellings reach the same pair.
        expect("ZH-hant-hk", "zh-HK");
        expect("zh_Hant_HK", "zh-HK");

        // A tag that names no language is passed through rather than guessed at.
        expect("x-klingon", "x-klingon");
        expect("und", "und");

        // The list keeps its order, and tags that minimize onto one pair collapse to one entry.
        NSArray *list = minimized(@[ @"zh-Hant-HK", @"zh-HK", @"en", @"en-US", @"fr-CA" ]);
        check([list isEqualToArray:@[ @"zh-HK", @"en-US", @"fr-CA" ]], "duplicates collapse, order kept");
        if (![list isEqualToArray:@[ @"zh-HK", @"en-US", @"fr-CA" ]])
            printf("      got %s\n", [[list componentsJoinedByString:@","] UTF8String]);

        check([minimized(@[]) isEqualToArray:@[]], "an empty list minimizes to an empty list");

        if (failures) {
            printf("Foundation-language-minimization: %d check(s) failed\n", failures);
            return 1;
        }
        printf("Foundation-language-minimization: all checks passed\n");
    }
    return 0;
}
