// -[NSURLRequest attribution] / -[NSMutableURLRequest setAttribution:] (methods/Foundation.m). A request
// reports NSURLRequestAttributionDeveloper until one is set; a set value reads back, survives -copy,
// -mutableCopy, a CFURLRequest copy and a secure keyed archive, and setting the default again restores
// a request indistinguishable from an untouched one. The property-list coder carries it as the
// dictionary's "attribution" entry, for mutable and immutable requests alike.
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdio.h>

// NSURLRequestAttribution is a 12.0+ enum in the SDK; its values are compile-time constants.
#pragma clang diagnostic ignored "-Wunguarded-availability-new"

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-72s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok)
        failures++;
}

static NSUInteger attribution(NSURLRequest *request)
{
    return ((NSUInteger (*)(id, SEL))objc_msgSend)(request, sel_getUid("wk_attribution"));
}

static void setAttribution(NSMutableURLRequest *request, NSUInteger value)
{
    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(request, sel_getUid("wk_setAttribution:"), value);
}

static NSDictionary *propertyList(id object)
{
    return ((NSDictionary *(*)(id, SEL))objc_msgSend)(object, sel_getUid("wk__webKitPropertyListData"));
}

static NSURLRequest *fromPropertyList(NSDictionary *dictionary)
{
    return ((id (*)(id, SEL, NSDictionary *))objc_msgSend)([NSURLRequest alloc], sel_getUid("wk__initWithWebKitPropertyListData:"), dictionary);
}

typedef const struct _CFURLRequest *CFURLRequestRef;
extern CFURLRequestRef CFURLRequestCreateMutableCopy(CFAllocatorRef, CFURLRequestRef);

static NSURLRequest *secureArchiveRoundTrip(NSURLRequest *request)
{
    NSMutableData *data = [NSMutableData data];
    NSKeyedArchiver *archiver = [[NSKeyedArchiver alloc] initForWritingWithMutableData:data];
    archiver.requiresSecureCoding = YES;
    [archiver encodeObject:request forKey:@"root"];
    [archiver finishEncoding];
    [archiver release];
    NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingWithData:data];
    unarchiver.requiresSecureCoding = YES;
    NSURLRequest *back = [unarchiver decodeObjectOfClass:[NSURLRequest class] forKey:@"root"];
    [unarchiver release];
    return back;
}

int main(void)
{
    @autoreleasepool {
        NSURL *url = [NSURL URLWithString:@"https://attribution.example/path"];
        SEL getter = sel_getUid("wk_attribution");
        SEL setter = sel_getUid("wk_setAttribution:");
        check([NSURLRequest instancesRespondToSelector:getter] && [NSMutableURLRequest instancesRespondToSelector:getter], "both request classes answer the getter");
        check([NSMutableURLRequest instancesRespondToSelector:setter] && ![NSURLRequest instancesRespondToSelector:setter], "only the mutable class takes the setter");

        NSURLRequest *immutable = [NSURLRequest requestWithURL:url];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        NSMutableURLRequest *allocated = [[[NSMutableURLRequest alloc] init] autorelease];
        check(attribution(immutable) == NSURLRequestAttributionDeveloper, "an immutable request defaults to developer");
        check(attribution(request) == NSURLRequestAttributionDeveloper, "a mutable request defaults to developer");
        check(attribution(allocated) == NSURLRequestAttributionDeveloper, "an -init request defaults to developer");

        setAttribution(request, NSURLRequestAttributionUser);
        check(attribution(request) == NSURLRequestAttributionUser, "a set value reads back");

        NSURLRequest *copied = [[request copy] autorelease];
        NSMutableURLRequest *mutableCopied = [[request mutableCopy] autorelease];
        check(attribution(copied) == NSURLRequestAttributionUser, "-copy keeps the value");
        check(attribution(mutableCopied) == NSURLRequestAttributionUser, "-mutableCopy keeps the value");
        NSURLRequest *immutableCopy = [[[[NSURLRequest alloc] initWithURL:url] autorelease] copy];
        check(attribution([immutableCopy autorelease]) == NSURLRequestAttributionDeveloper, "-copy of an untouched immutable request is developer");
        NSMutableURLRequest *fromImmutable = [[mutableCopied copy] autorelease];
        check(attribution([[fromImmutable mutableCopy] autorelease]) == NSURLRequestAttributionUser, "a copy of a copy keeps the value");

        setAttribution(mutableCopied, NSURLRequestAttributionDeveloper);
        check(attribution(mutableCopied) == NSURLRequestAttributionDeveloper, "a copy is set independently of its original");
        check(attribution(request) == NSURLRequestAttributionUser, "and the original keeps its own value");

        CFURLRequestRef nativeCopy = CFURLRequestCreateMutableCopy(kCFAllocatorDefault,
            ((CFURLRequestRef (*)(id, SEL))objc_msgSend)(request, sel_getUid("_CFURLRequest")));
        NSURLRequest *wrapped = ((id (*)(id, SEL, CFURLRequestRef))objc_msgSend)([NSURLRequest alloc], sel_getUid("_initWithCFURLRequest:"), nativeCopy);
        check(attribution(wrapped) == NSURLRequestAttributionUser, "a CFURLRequest copy keeps the value");
        [wrapped release];
        CFRelease(nativeCopy);

        check([NSURLRequest supportsSecureCoding], "NSURLRequest supports secure coding");
        check(attribution(secureArchiveRoundTrip(request)) == NSURLRequestAttributionUser, "a secure archive keeps the value");
        check(attribution(secureArchiveRoundTrip(immutable)) == NSURLRequestAttributionDeveloper, "a secure archive keeps the default");

        NSMutableURLRequest *untouched = [NSMutableURLRequest requestWithURL:url];
        NSMutableURLRequest *reset = [NSMutableURLRequest requestWithURL:url];
        setAttribution(reset, NSURLRequestAttributionUser);
        setAttribution(reset, NSURLRequestAttributionDeveloper);
        check(attribution(reset) == NSURLRequestAttributionDeveloper, "setting developer again reads back developer");
        check([reset isEqual:untouched] && [propertyList(reset) isEqual:propertyList(untouched)], "and leaves the request identical to an untouched one");
        setAttribution(untouched, NSURLRequestAttributionDeveloper);
        check([propertyList(untouched) isEqual:propertyList([NSMutableURLRequest requestWithURL:url])], "setting the default on an untouched request changes nothing");

        NSDictionary *dictionary = propertyList(request);
        check([dictionary[@"attribution"] isEqual:@(NSURLRequestAttributionUser)], "the property list carries the value as \"attribution\"");
        check(!dictionary[@"protocolProperties"], "and not among the protocol properties");
        check(![dictionary[@"isHTTP"] boolValue], "setting it does not materialize HTTP metadata");
        check([propertyList(immutable)[@"attribution"] isEqual:@(NSURLRequestAttributionDeveloper)], "an untouched request writes developer");
        NSURLRequest *back = [fromPropertyList(dictionary) autorelease];
        check(attribution(back) == NSURLRequestAttributionUser, "a request built from the property list reads the value back");
        check([propertyList(back) isEqual:dictionary], "the round trip is stable");
        NSMutableDictionary *immutableAsked = [[dictionary mutableCopy] autorelease];
        immutableAsked[@"isMutable"] = @NO;
        NSURLRequest *immutableBack = [fromPropertyList(immutableAsked) autorelease];
        check(![immutableBack isKindOfClass:[NSMutableURLRequest class]] && attribution(immutableBack) == NSURLRequestAttributionUser,
            "an immutable request built from the property list reads the value back");
        NSMutableDictionary *withoutEntry = [[dictionary mutableCopy] autorelease];
        [withoutEntry removeObjectForKey:@"attribution"];
        check(attribution([fromPropertyList(withoutEntry) autorelease]) == NSURLRequestAttributionDeveloper, "a property list without the entry gives developer");
    }
    printf("Foundation-url-request-attribution: %s\n", failures ? "FAIL" : "ok");
    return failures ? 1 : 0;
}
