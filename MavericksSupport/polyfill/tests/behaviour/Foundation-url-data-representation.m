// +[NSURL URLWithDataRepresentation:relativeToURL:] (methods/Foundation.m): a URL built out of bytes
// keeps the characters +URLWithString: rejects outright, and resolves against a base.

#import <Foundation/Foundation.h>
#import <stdio.h>
#import <stdlib.h>

// The sends below are the polyfill's whole subject; the SDK marks the selector 10.11+.
#pragma clang diagnostic ignored "-Wunguarded-availability"

static int failures;

static void check(const char *what, NSString *got, NSString *want)
{
    bool ok = want ? [got isEqualToString:want] : (got == nil);
    printf("  %-40s %-38s %s\n", what, got ? got.UTF8String : "(nil)", ok ? "ok" : "FAIL");
    if (!ok) {
        printf("  %-40s expected %s\n", "", want ? want.UTF8String : "(nil)");
        ++failures;
    }
}

static NSURL *fromBytes(NSString *string, NSURL *base)
{
    return [NSURL URLWithDataRepresentation:[string dataUsingEncoding:NSUTF8StringEncoding] relativeToURL:base];
}

int main(void)
{
    @autoreleasepool {
        // A space is what run-webkit-tests hands DumpRenderTree in a test path, and what +URLWithString: refuses.
        check("+URLWithString: on a space", [NSURL URLWithString:@"http://example.test/a b.html"].absoluteString, nil);

        NSURL *spaced = fromBytes(@"http://example.test/a b.html", nil);
        check("a space is escaped, not refused", spaced.absoluteString, @"http://example.test/a%20b.html");
        check("and reads back", spaced.path, @"/a b.html");

        NSURL *nonASCII = fromBytes(@"http://example.test/ü.html", nil);
        check("UTF-8 bytes are escaped", nonASCII.absoluteString, @"http://example.test/%C3%BC.html");
        check("and read back", nonASCII.path, @"/ü.html");

        check("a file URL keeps its path", fromBytes(@"file:///tmp/a b.html", nil).path, @"/tmp/a b.html");

        check("resolved against a base",
            fromBytes(@"b.html", [NSURL URLWithString:@"http://example.test/a/"]).absoluteString,
            @"http://example.test/a/b.html");

        NSData *noBytes = nil;
        check("no bytes", [NSURL URLWithDataRepresentation:noBytes relativeToURL:nil].absoluteString, nil);
    }
    if (failures) {
        printf("FAILED: %d\n", failures);
        return 1;
    }
    printf("PASS\n");
    return 0;
}
