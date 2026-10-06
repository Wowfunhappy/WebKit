// Relative file URL construction through the native 10.9 filesystem-path API.
#import <Foundation/Foundation.h>
#include <stdio.h>

#pragma clang diagnostic ignored "-Wunguarded-availability"

static unsigned failures;

static void check(const char *name, BOOL matches)
{
    printf("%s %s\n", matches ? "PASS" : "FAIL", name);
    failures += !matches;
}

int main(void)
{
    @autoreleasepool {
        NSURL *base = [NSURL fileURLWithPath:@"/tmp/base/index.html"];
        NSURL *relative = [NSURL fileURLWithPath:@"resources/hello.txt" relativeToURL:base];
        check("relative path against a file", [relative.path isEqualToString:@"/tmp/base/resources/hello.txt"]);
        check("base URL retained", [relative.baseURL isEqual:base]);
        check("relative URL remains relative", [relative.relativeString isEqualToString:@"resources/hello.txt"]);

        NSURL *directoryBase = [NSURL fileURLWithPath:@"/tmp/base" isDirectory:YES];
        NSURL *fromDirectory = [NSURL fileURLWithPath:@"hello.txt" relativeToURL:directoryBase];
        check("relative path against a directory", [fromDirectory.path isEqualToString:@"/tmp/base/hello.txt"]);

        NSURL *absolute = [NSURL fileURLWithPath:@"/tmp/elsewhere.txt" relativeToURL:base];
        check("absolute path ignores base", [absolute.path isEqualToString:@"/tmp/elsewhere.txt"]);
        check("absolute path has no base", !absolute.baseURL);

        NSURL *escaped = [NSURL fileURLWithPath:@"a b#%.txt" relativeToURL:base];
        check("filesystem characters escaped", [escaped.absoluteString isEqualToString:@"file:///tmp/base/a%20b%23%25.txt"]);
        check("filesystem characters round trip", [escaped.path isEqualToString:@"/tmp/base/a b#%.txt"]);

        NSURL *unicode = [NSURL fileURLWithPath:@"caf\u00e9.txt" relativeToURL:base];
        check("Unicode matches native absolute constructor", [unicode.absoluteURL isEqual:[NSURL fileURLWithPath:@"/tmp/base/caf\u00e9.txt"]]);
        check("no base matches native constructor", [[NSURL fileURLWithPath:@"relative.txt" relativeToURL:nil] isEqual:[NSURL fileURLWithPath:@"relative.txt"]]);

        NSURL *systemBase = [NSURL fileURLWithPath:@"/System/Library/index.html"];
        check("existing directory inferred", CFURLHasDirectoryPath((CFURLRef)[NSURL fileURLWithPath:@"Frameworks" relativeToURL:systemBase]));
        check("existing file inferred", !CFURLHasDirectoryPath((CFURLRef)[NSURL fileURLWithPath:@"/System/Library/Frameworks/Foundation.framework/Foundation" relativeToURL:base]));
        check("trailing slash marks a directory", CFURLHasDirectoryPath((CFURLRef)[NSURL fileURLWithPath:@"uncreated/" relativeToURL:base]));
        check("explicit directory hint", CFURLHasDirectoryPath((CFURLRef)[NSURL fileURLWithPath:@"uncreated" isDirectory:YES relativeToURL:base]));
        check("explicit file hint avoids directory inference", !CFURLHasDirectoryPath((CFURLRef)[NSURL fileURLWithPath:@"Frameworks" isDirectory:NO relativeToURL:systemBase]));
    }
    return failures ? 1 : 0;
}
