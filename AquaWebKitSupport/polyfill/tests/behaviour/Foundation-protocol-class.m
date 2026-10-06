// +[NSURLProtocol _protocolClassForRequest:skipAppSSO:] answers the protocol class that handles a request:
// the system's own for its schemes, a registered class for its scheme, and nil for a scheme nothing
// handles. The class it answers canonicalizes the request.
#import <Foundation/Foundation.h>
#include <stdio.h>

@interface NSURLProtocol (ProtocolClassTest)
+ (Class)_protocolClassForRequest:(NSURLRequest *)request skipAppSSO:(BOOL)skipAppSSO;
@end

@interface ProtocolClassTestProtocol : NSURLProtocol
@end

@implementation ProtocolClassTestProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request
{
    return [request.URL.scheme isEqualToString:@"protocol-class-test"];
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request
{
    return request;
}
@end

static int failures;

static Class classFor(NSString *string, BOOL skipAppSSO)
{
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:string]];
    return [NSURLProtocol _protocolClassForRequest:request skipAppSSO:skipAppSSO];
}

static void expectClass(NSString *string, NSString *expected)
{
    for (int skip = 0; skip < 2; ++skip) {
        Class actual = classFor(string, skip);
        NSString *name = actual ? NSStringFromClass(actual) : @"nil";
        if ([name isEqualToString:expected])
            continue;
        printf("  FAIL: %s (skipAppSSO %d): expected %s, got %s\n", [string UTF8String], skip, [expected UTF8String], [name UTF8String]);
        ++failures;
    }
}

static void expectCanonical(NSString *string, NSString *expected)
{
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:string]];
    Class protocolClass = [NSURLProtocol _protocolClassForRequest:request skipAppSSO:YES];
    NSString *actual = [[[protocolClass canonicalRequestForRequest:request] URL] absoluteString];
    if ([actual isEqualToString:expected])
        return;
    printf("  FAIL: canonical %s: expected %s, got %s\n", [string UTF8String], [expected UTF8String], actual ? [actual UTF8String] : "nil");
    ++failures;
}

int main(void)
{
    @autoreleasepool {
        [NSURLProtocol registerClass:[ProtocolClassTestProtocol class]];
        expectClass(@"http://bloomberg.com", @"NSCFURLProtocol");
        expectClass(@"https://example.com/", @"NSCFURLProtocol");
        expectClass(@"about:blank", @"NSAboutURLProtocol");
        expectClass(@"protocol-class-test://host/", @"ProtocolClassTestProtocol");
        expectClass(@"unhandled-scheme://host/", @"nil");
        expectCanonical(@"http://bloomberg.com", @"http://bloomberg.com/");
        expectCanonical(@"https://Example.COM", @"https://example.com/");
    }
    if (failures)
        return 1;
    printf("  protocol class: ok\n");
    return 0;
}
