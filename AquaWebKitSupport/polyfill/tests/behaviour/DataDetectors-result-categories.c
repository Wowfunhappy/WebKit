#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdbool.h>
#include <stdio.h>

extern int DDResultGetCategory(CFTypeRef);
extern CFStringRef const DDBinderParsecSourceKey;

static int failures;

static void check(Boolean condition, const char *name)
{
    printf("  %s: %s\n", name, condition ? "ok" : "FAIL");
    failures += !condition;
}

int main(void)
{
    void *framework = dlopen("/System/Library/PrivateFrameworks/DataDetectorsCore.framework/DataDetectorsCore", RTLD_LAZY);
    if (!framework)
        return 1;

    CFStringRef const *parsecKey = dlsym(framework, "DDBinderParsecSourceKey");
    check(parsecKey && CFEqual(*parsecKey, CFSTR("Parsec")), "soft-linked Parsec key");
    check(CFEqual(DDBinderParsecSourceKey, CFSTR("Parsec")), "linked Parsec key");

    int (*category)(CFTypeRef) = dlsym(framework, "DDResultGetCategory");
    CFTypeRef (*createScanner)(int, CFIndex, CFErrorRef *) = dlsym(framework, "DDScannerCreate");
    CFTypeRef (*createQuery)(CFAllocatorRef, CFStringRef, CFRange) = dlsym(framework, "DDScanQueryCreateFromString");
    Boolean (*scanQuery)(CFTypeRef, CFTypeRef) = dlsym(framework, "DDScannerScanQuery");
    CFArrayRef (*copyResults)(CFTypeRef, CFIndex) = dlsym(framework, "DDScannerCopyResultsWithOptions");
    CFRange (*resultRange)(CFTypeRef) = dlsym(framework, "DDResultGetRange");
    if (!category || !createScanner || !createQuery || !scanQuery || !copyResults || !resultRange)
        return 1;

    check(category(NULL) == 0 && DDResultGetCategory(NULL) == 0, "null result preserves Unknown");

    struct {
        CFStringRef text;
        int category;
        const char *name;
    } cases[] = {
        { CFSTR("$79.99"), 6, "money" },
        { CFSTR("$20.00"), 6, "money with trailing zeroes" },
        { CFSTR("January 12, 2025"), 4, "calendar event" },
        { CFSTR("https://apple.com"), 1, "URL" },
        { CFSTR("800-555-1212"), 2, "phone number" },
    };

    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i) {
        CFIndex length = CFStringGetLength(cases[i].text);
        CFTypeRef scanner = createScanner(0, 0, NULL);
        CFTypeRef query = createQuery(kCFAllocatorDefault, cases[i].text, CFRangeMake(0, length));
        if (!scanner || !query || !scanQuery(scanner, query))
            return 1;
        CFArrayRef results = copyResults(scanner, 1);
        Boolean matched = false;
        for (CFIndex j = 0; results && j < CFArrayGetCount(results); ++j) {
            CFTypeRef result = CFArrayGetValueAtIndex(results, j);
            CFRange range = resultRange(result);
            if (!range.location && range.length == length
                && category(result) == cases[i].category
                && DDResultGetCategory(result) == cases[i].category)
                matched = true;
        }
        check(matched, cases[i].name);
        if (results)
            CFRelease(results);
        CFRelease(query);
        CFRelease(scanner);
    }
    dlclose(framework);
    return !!failures;
}
