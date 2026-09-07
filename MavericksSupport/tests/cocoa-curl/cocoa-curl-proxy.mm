// Resolve real CF proxy dictionaries, including PAC URL execution, without changing system settings.
#include "config.h"
#include <WebCore/CocoaCurlProxyResolver.h>
#include <wtf/MainThread.h>
#import <Foundation/Foundation.h>
#import <CFNetwork/CFNetwork.h>
#include <cstdio>
using namespace WebCore;
static unsigned failures;
static void resolve(NSString* address, NSDictionary* settings, CFStringRef expectedType, NSString* expectedHost = nil, int expectedPort = 0)
{
    bool done = false;
    Ref resolver = CocoaCurlProxyResolver::create(URL { String(address) }, (__bridge CFDictionaryRef)settings, [&](RetainPtr<CFDictionaryRef>&& route, const String& error) {
        auto dictionary = (__bridge NSDictionary*)route.get();
        bool passed = error.isEmpty() && [dictionary[(id)kCFProxyTypeKey] isEqual:(id)expectedType]
            && (!expectedHost || [dictionary[(id)kCFProxyHostNameKey] isEqual:expectedHost])
            && (!expectedPort || [dictionary[(id)kCFProxyPortNumberKey] intValue] == expectedPort);
        printf("Proxy %s route=%s host=%s port=%d error=%s %s\n", address.UTF8String, [dictionary[(id)kCFProxyTypeKey] UTF8String], [dictionary[(id)kCFProxyHostNameKey] UTF8String], [dictionary[(id)kCFProxyPortNumberKey] intValue], error.utf8().data(), passed ? "PASS" : "FAIL");
        failures += !passed;
        done = true;
        CFRunLoopStop(CFRunLoopGetMain());
    });
    auto deadline = adoptCF(CFRunLoopTimerCreateWithHandler(nullptr, CFAbsoluteTimeGetCurrent() + 15, 0, 0, 0, ^(CFRunLoopTimerRef) { ++failures; puts("FAIL PAC deadline"); CFRunLoopStop(CFRunLoopGetMain()); }));
    CFRunLoopAddTimer(CFRunLoopGetMain(), deadline.get(), kCFRunLoopDefaultMode);
    resolver->start();
    if (!done) CFRunLoopRun();
    CFRunLoopTimerInvalidate(deadline.get());
    resolver->cancel();
}
int main()
{
    @autoreleasepool {
        setvbuf(stdout, nullptr, _IONBF, 0);
        WTF::initializeMainThread();
        auto systemBefore = adoptCF(CFNetworkCopySystemProxySettings());
        NSDictionary* configured = @{ @"HTTPEnable": @1, @"HTTPProxy": @"127.0.0.1", @"HTTPPort": @18985, @"HTTPSEnable": @1, @"HTTPSProxy": @"127.0.0.1", @"HTTPSPort": @18985, @"ExceptionsList": @[@"*.test", @"169.254/16"], @"ExcludeSimpleHostnames": @1 };
        resolve(@"http://proxy-target.invalid/", configured, kCFProxyTypeHTTP, @"127.0.0.1", 18985);
        resolve(@"https://proxy-target.invalid/", configured, kCFProxyTypeHTTPS, @"127.0.0.1", 18985);
        resolve(@"https://subdomain.test/", configured, kCFProxyTypeNone);
        resolve(@"http://169.254.10.20/", configured, kCFProxyTypeNone);
        resolve(@"http://printer/", configured, kCFProxyTypeNone);
        char directory[] = "/private/tmp/curl-proxy-PAC-XXXXXX";
        RELEASE_ASSERT(mkdtemp(directory));
        NSString* file = [[NSString stringWithUTF8String:directory] stringByAppendingPathComponent:@"proxy.pac"];
        NSString* script = @"function FindProxyForURL(url, host) { if (host == 'direct.test') return 'DIRECT'; return 'PROXY 127.0.0.1:18985'; }";
        RELEASE_ASSERT([script writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil]);
        NSDictionary* pac = @{ @"ProxyAutoConfigEnable": @1, @"ProxyAutoConfigURLString": [NSURL fileURLWithPath:file].absoluteString };
        // CF classifies an HTTP CONNECT route as HTTPS for an HTTPS target.
        resolve(@"https://proxy-target.invalid/", pac, kCFProxyTypeHTTPS, @"127.0.0.1", 18985);
        resolve(@"https://direct.test/", pac, kCFProxyTypeNone);
        [[NSFileManager defaultManager] removeItemAtPath:[NSString stringWithUTF8String:directory] error:nil];
        auto systemAfter = adoptCF(CFNetworkCopySystemProxySettings());
        bool unchanged = systemBefore && systemAfter && CFEqual(systemBefore.get(), systemAfter.get());
        failures += !unchanged;
        printf("System proxy settings unchanged: %s\nCocoa curl proxy routing: FAILED=%u\n", unchanged ? "PASS" : "FAIL", failures);
    }
    return failures ? 1 : 0;
}
