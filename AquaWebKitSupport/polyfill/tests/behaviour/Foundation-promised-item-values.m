// Promised-item resource values answer as the plain resource-value API for items that are not promises.
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
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
        [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *file = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"hello.txt"]];
        [@"hello world\n" writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:nil];

        id typeIdentifier = nil;
        id plainTypeIdentifier = nil;
        [file getResourceValue:&plainTypeIdentifier forKey:NSURLTypeIdentifierKey error:nil];
        check("single value succeeds", [file getPromisedItemResourceValue:&typeIdentifier forKey:NSURLTypeIdentifierKey error:nil]);
        check("single value matches the plain value", plainTypeIdentifier && [typeIdentifier isEqual:plainTypeIdentifier]);

        NSArray *keys = @[ NSURLLocalizedNameKey, NSURLHasHiddenExtensionKey, NSURLFileSizeKey ];
        NSDictionary *values = [file promisedItemResourceValuesForKeys:keys error:nil];
        NSDictionary *plainValues = [file resourceValuesForKeys:keys error:nil];
        check("dictionary matches the plain dictionary", values && [values isEqual:plainValues]);

        NSURL *contentTypeValue = nil;
        [file getPromisedItemResourceValue:&contentTypeValue forKey:NSURLContentTypeKey error:nil];
        check("modern keys answer through the resource-value polyfill", [[(id)contentTypeValue identifier] isEqual:plainTypeIdentifier]);

        NSURL *missing = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"missing.txt"]];
        NSError *error = nil;
        id missingName = nil;
        BOOL plainResult = [missing getResourceValue:&missingName forKey:NSURLLocalizedNameKey error:nil];
        check("missing item fails like the plain value", [missing getPromisedItemResourceValue:&missingName forKey:NSURLLocalizedNameKey error:&error] == plainResult);
        error = nil;
        check("missing item dictionary is nil with an error", ![missing promisedItemResourceValuesForKeys:keys error:&error] && error);

        [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
    }
    return failures ? 1 : 0;
}
