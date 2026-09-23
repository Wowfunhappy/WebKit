#import "config.h"
#import <AppKit/AppKit.h>
#import <WebKit/WKNavigationDelegate.h>
#import <WebKit/WKPreferencesPrivate.h>
#import <WebKit/WKProcessPoolPrivate.h>
#import <WebKit/WKWebView.h>
#import <WebKit/WKWebViewPrivate.h>
#import <WebKit/WKWebViewConfiguration.h>
#import <WebKit/WKWebsiteDataStorePrivate.h>
#import <WebKit/_WKFeature.h>
#import <WebKit/_WKProcessPoolConfiguration.h>
#include <errno.h>
#include <signal.h>

static bool waitUntil(bool (^condition)())
{
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20];
    while (!condition() && deadline.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    return condition();
}

@interface Navigation : NSObject <WKNavigationDelegate>
@property BOOL finished;
@property BOOL terminated;
@end
@implementation Navigation
- (void)webView:(WKWebView *)view didFinishNavigation:(WKNavigation *)navigation { self.finished = YES; }
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)view { self.terminated = YES; }
- (void)webView:(WKWebView *)view didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error { NSLog(@"navigation error: %@", error); }
@end

static bool setFeature(WKPreferences *preferences, NSString *key, BOOL value)
{
    for (_WKFeature *feature in [WKPreferences _features]) {
        if ([feature.key isEqualToString:key]) {
            [preferences _setEnabled:value forFeature:feature];
            return true;
        }
    }
    return false;
}

static id evaluate(WKWebView *view, NSString *script)
{
    __block bool finished = false;
    __block id result = nil;
    [view evaluateJavaScript:script completionHandler:^(id value, NSError *error) {
        result = [value retain];
        if (error)
            NSLog(@"script error: %@", error);
        finished = true;
    }];
    if (!waitUntil(^bool { return finished; }))
        NSLog(@"script timed out: %@", script);
    return [result autorelease];
}

static NSString *probeLibrary;
static bool expectsNativeBundle;

static bool sendVerb(WKWebView *view, NSString *verb, unsigned port)
{
    unsigned operation = [verb isEqual:@"AddOriginAccessAllowListEntry"] ? 0 : [verb isEqual:@"RemoveOriginAccessAllowListEntry"] ? 1 : 2;
    NSString *expression = [NSString stringWithFormat:@"expression -- (int)((int (*)(int, unsigned, int))dlsym((void*)dlopen(\"%@\", 2), \"WKOriginAccessProbe\"))(%u, %u, %u)", probeLibrary, operation, port, expectsNativeBundle];
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/usr/bin/lldb";
    task.arguments = @[ @"-p", [NSString stringWithFormat:@"%d", view._webProcessIdentifier], @"-o", @"thread select 1", @"-o", expression, @"-o", @"process detach", @"-o", @"quit" ];
    NSPipe *output = [NSPipe pipe];
    task.standardOutput = output;
    task.standardError = output;
    [task launch];
    NSData *data = [output.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    NSString *text = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    bool success = !task.terminationStatus && [text rangeOfString:@"= 0"].location != NSNotFound;
    if (!success)
        NSLog(@"debugger probe failed: %@", text);
    [task release];
    return success;
}

static bool checkFetch(WKWebView *view, unsigned port, bool allowed)
{
    NSString *script = [NSString stringWithFormat:@"window.fetchResult='PENDING';fetch('http://localhost:%u/target?'+Math.random()).then(r=>r.text()).then(t=>fetchResult=t).catch(e=>fetchResult='BLOCKED');'STARTED'", port];
    id startResult = evaluate(view, script);
    if (![startResult isEqual:@"STARTED"]) {
        NSLog(@"fetch did not start (allowed=%d): %@", allowed, startResult);
        return false;
    }
    __block id result = nil;
    if (!waitUntil(^bool {
        result = evaluate(view, @"window.fetchResult");
        return result && ![result isEqual:@"PENDING"];
    })) {
        NSLog(@"fetch did not complete (allowed=%d): %@", allowed, result);
        return false;
    }
    NSString *expected = allowed ? @"CROSS_ORIGIN_OK" : @"BLOCKED";
    if (![result isEqual:expected])
        NSLog(@"fetch expected %@, got %@", expected, result);
    return [result isEqual:expected];
}

int main(int argc, char **argv)
{
    setvbuf(stdout, nullptr, _IOLBF, 0);
    @autoreleasepool {
        if (argc != 4)
            return 2;
        [NSApplication sharedApplication];
        unsigned port = (unsigned)strtoul(argv[1], nullptr, 10);
        NSString *bundlePath = [NSString stringWithUTF8String:argv[2]];
        NSString *mode = [NSString stringWithUTF8String:argv[3]];
        probeLibrary = [bundlePath stringByAppendingPathComponent:@"Contents/MacOS/OriginAccess"];
        BOOL nativeAuthority = [mode isEqual:@"bundle"];
        expectsNativeBundle = nativeAuthority;
        BOOL testAuthority = [mode isEqual:@"test"];
        WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
        if (nativeAuthority) {
            _WKProcessPoolConfiguration *poolConfiguration = [[_WKProcessPoolConfiguration alloc] init];
            poolConfiguration.injectedBundleURL = [NSURL fileURLWithPath:bundlePath];
            configuration.processPool = [[[WKProcessPool alloc] _initWithConfiguration:poolConfiguration] autorelease];
            [poolConfiguration release];
        }
        if (!setFeature(configuration.preferences, @"AllowTestOnlyOriginAccessAllowListIPC", testAuthority))
            return 3;
        WKWebView *view = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 640, 480) configuration:configuration];
        Navigation *navigation = [[Navigation alloc] init];
        view.navigationDelegate = navigation;
        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%u/page", port]];
        [view loadRequest:[NSURLRequest requestWithURL:url]];
        if (!waitUntil(^bool { return navigation.finished || navigation.terminated; }) || navigation.terminated)
            return 4;
        if (!nativeAuthority && !testAuthority) {
            if (!sendVerb(view, mode, port) || !waitUntil(^bool { return navigation.terminated; }))
                return 5;
            printf("PASS denied %s without native or test authority\n", mode.UTF8String);
            return 0;
        }
        for (unsigned cycle = 0; cycle < 3; ++cycle) {
            if (cycle == 1) {
                if (!setFeature(configuration.preferences, @"WebSocketEnabled", NO))
                    return 6;
                if (![evaluate(view, @"'PREFERENCE_UPDATED'") isEqual:@"PREFERENCE_UPDATED"])
                    return 7;
            }
            if (cycle == 2) {
                pid_t oldNetworkPID = configuration.websiteDataStore._networkProcessIdentifier;
                [configuration.websiteDataStore _terminateNetworkProcess];
                // Termination is asynchronous. Reload only after the original process exits,
                // so a late disconnect cannot invalidate the freshly loaded test document.
                if (!waitUntil(^bool { return kill(oldNetworkPID, 0) == -1 && errno == ESRCH; }))
                    return 8;
                navigation.finished = NO;
                [view reload];
                if (!waitUntil(^bool { return navigation.finished || navigation.terminated; }) || navigation.terminated)
                    return 8;
                pid_t newNetworkPID = configuration.websiteDataStore._networkProcessIdentifier;
                if (newNetworkPID <= 0 || newNetworkPID == oldNetworkPID)
                    return 8;
                printf("Network process reconnected: %d -> %d\n", oldNetworkPID, newNetworkPID);
            }
            if (!checkFetch(view, port, false)
                || !sendVerb(view, @"AddOriginAccessAllowListEntry", port) || !checkFetch(view, port, true)
                || !sendVerb(view, @"RemoveOriginAccessAllowListEntry", port) || !checkFetch(view, port, false)
                || !sendVerb(view, @"AddOriginAccessAllowListEntry", port) || !checkFetch(view, port, true)
                || !sendVerb(view, @"ResetOriginAccessAllowLists", port) || !checkFetch(view, port, false)
                || navigation.terminated)
                return 9;
            printf("PASS %s add/remove/reset cycle %u%s\n", mode.UTF8String, cycle,
                cycle == 1 ? " after preference update" : cycle == 2 ? " after network reconnect" : "");
        }
        [view release];
        [navigation release];
        [configuration release];
    }
    return 0;
}
