#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <stdio.h>

#if defined(HOST_CALLER)

void hostSetSubscript(NSMutableDictionary *dictionary, id<NSCopying> key, id value)
{
    dictionary[key] = value;
}

#else

extern void hostSetSubscript(NSMutableDictionary *, id<NSCopying>, id);

static int failures;
static void check(BOOL ok, const char *what)
{
    printf("  %-60s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok)
        ++failures;
}

static void checkDictionary(NSMutableDictionary *dictionary, const char *factory)
{
    printf("%s: %s\n", factory, object_getClassName(dictionary));
    dictionary[@"a"] = @1;
    dictionary[@"a"] = @2;
    dictionary[@"keep"] = [NSNull null];
    check([dictionary[@"a"] isEqual:@2], "WebKit subscript inserts and replaces a non-nil value");

    @try {
        dictionary[@"a"] = nil;
        check(!dictionary[@"a"] && dictionary.count == 1, "WebKit nil subscript removes only its key");
        dictionary[@"absent"] = nil;
        check(dictionary.count == 1, "WebKit nil subscript for an absent key leaves contents intact");
    } @catch (NSException *exception) {
        printf("  unexpected exception: %s\n", exception.reason.UTF8String);
        check(NO, "WebKit nil subscript accepts nil");
    }
    check(dictionary[@"keep"] == [NSNull null], "NSNull remains a stored value");

    hostSetSubscript(dictionary, @"a", @3);
    check([dictionary[@"a"] isEqual:@3], "host subscript stores a non-nil value");
    BOOL raised = NO;
    @try {
        hostSetSubscript(dictionary, @"a", nil);
    } @catch (NSException *exception) {
        raised = [exception.name isEqualToString:NSInvalidArgumentException];
    }
    check(raised && [dictionary[@"a"] isEqual:@3], "host nil subscript raises and preserves the value");

    raised = NO;
    @try {
        [dictionary setObject:nil forKey:@"a"];
    } @catch (NSException *exception) {
        raised = [exception.name isEqualToString:NSInvalidArgumentException];
    }
    check(raised && [dictionary[@"a"] isEqual:@3], "setObject:forKey: retains its non-nil precondition");

    id key = nil;
    raised = NO;
    @try {
        dictionary[key] = @4;
    } @catch (NSException *exception) {
        raised = [exception.name isEqualToString:NSInvalidArgumentException];
    }
    check(raised, "WebKit subscript retains its non-nil key precondition");
}

int main(void)
{
    @autoreleasepool {
        checkDictionary([NSMutableDictionary dictionary], "NSMutableDictionary dictionary");
        checkDictionary([[@{ @"a": @0 } mutableCopy] autorelease], "immutable dictionary mutableCopy");
        CFMutableDictionaryRef dictionary = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        checkDictionary((NSMutableDictionary *)dictionary, "CFDictionaryCreateMutable");
        CFRelease(dictionary);
    }
    return failures ? 1 : 0;
}

#endif
