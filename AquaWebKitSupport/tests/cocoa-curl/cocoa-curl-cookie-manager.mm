// Exercise Safari 7's cookie-change C client against an isolated WK2 cookie store.
#import <Cocoa/Cocoa.h>
#import <WebKit/WKWebsiteDataStore.h>
#import <WebKit/WKHTTPCookieStore.h>
#import <WebKit/WKCookieManager.h>
#include <cstdio>
static unsigned failures;
static void check(bool value, const char* name) { if (!value) { ++failures; printf("FAIL %s\n", name); } }
@interface CookieProbe : NSObject <WKHTTPCookieStoreObserver> {
@public
    WKWebsiteDataStore* dataStore;
    WKHTTPCookieStore* store;
    WKCookieManagerRef manager;
    unsigned phase;
    unsigned firstCalls;
    unsigned replacementCalls;
    bool changed;
    bool operationComplete;
    bool finishing;
    bool finished;
    bool hasModernObserver;
}
- (void)beginPhase;
- (void)maybeFinish;
- (void)deadline;
@end
static void firstChanged(WKCookieManagerRef manager, const void* context)
{
    CookieProbe* probe = (CookieProbe*)context;
    check(manager == probe->manager, "legacy callback receives its own cookie manager");
    ++probe->firstCalls;
    if (!probe->phase) {
        probe->changed = true;
        [probe maybeFinish];
    }
}
static void replacementChanged(WKCookieManagerRef manager, const void* context)
{
    CookieProbe* probe = (CookieProbe*)context;
    check(manager == probe->manager, "replacement callback receives its own cookie manager");
    ++probe->replacementCalls;
    if (probe->phase == 3)
        WKCookieManagerSetClient(manager, nullptr);
}
@implementation CookieProbe
- (void)cookiesDidChangeInCookieStore:(WKHTTPCookieStore*)value
{
    check(value == store, "modern observer supplies an independent mutation barrier");
    changed = true;
    [self maybeFinish];
}
- (void)maybeFinish
{
    if (!changed || !operationComplete || finishing)
        return;
    finishing = true;
    [store getAllCookies:^(NSArray<NSHTTPCookie*>* cookies) {
        const unsigned expectedFirst[] = { 1, 1, 1, 1, 1, 2 };
        const unsigned expectedReplacement[] = { 0, 0, 1, 2, 2, 2 };
        check(firstCalls == expectedFirst[phase], "legacy start/stop and original client count");
        check(replacementCalls == expectedReplacement[phase], "replacement and self-unregistration count");
        if (phase == 5)
            check(!cookies.count, "legacy Remove All Website Data cookie operation empties the private jar");
        printf("cookie manager phase=%u first=%u replacement=%u stored=%lu\n", phase, firstCalls, replacementCalls, (unsigned long)cookies.count);
        if (++phase == 6) {
            WKCookieManagerStopObservingCookieChanges(manager);
            WKCookieManagerSetClient(manager, nullptr);
            [store removeObserver:self];
            finished = true;
            CFRunLoopStop(CFRunLoopGetMain());
        } else
            [self beginPhase];
    }];
}
- (void)beginPhase
{
    changed = false;
    operationComplete = false;
    finishing = false;
    // Stack clients deliberately expire before notification; SetClient must copy them.
    if (!phase || phase == 5) {
        WKCookieManagerClientV0 client = { { 0, self }, firstChanged };
        WKCookieManagerSetClient(manager, &client.base);
        WKCookieManagerStartObservingCookieChanges(manager);
    } else if (phase == 1) {
        [store addObserver:self];
        hasModernObserver = true;
        WKCookieManagerStopObservingCookieChanges(manager);
    }
    else if (phase == 2) {
        WKCookieManagerClientV0 client = { { 0, self }, replacementChanged };
        WKCookieManagerStartObservingCookieChanges(manager);
        WKCookieManagerSetClient(manager, &client.base);
    }
    if (phase == 5) {
        WKCookieManagerDeleteAllCookies(manager);
        operationComplete = true;
        [self maybeFinish];
        return;
    }
    NSHTTPCookie* cookie = [NSHTTPCookie cookieWithProperties:@{ NSHTTPCookieName: @"legacy-observer", NSHTTPCookieValue: [NSString stringWithFormat:@"%u", phase], NSHTTPCookieDomain: @"cookie-manager.test", NSHTTPCookiePath: @"/" }];
    [store setCookie:cookie completionHandler:^{ operationComplete = true; [self maybeFinish]; }];
}
- (void)deadline
{
    check(false, "cookie manager mutation/notification deadline");
    WKCookieManagerStopObservingCookieChanges(manager);
    WKCookieManagerSetClient(manager, nullptr);
    if (hasModernObserver)
        [store removeObserver:self];
    CFRunLoopStop(CFRunLoopGetMain());
}
@end
int main()
{
    @autoreleasepool {
        setvbuf(stdout, nullptr, _IONBF, 0);
        [NSApplication sharedApplication];
        CookieProbe* probe = [CookieProbe new];
        probe->dataStore = [[WKWebsiteDataStore nonPersistentDataStore] retain];
        probe->store = [probe->dataStore.httpCookieStore retain];
        probe->manager = (__bridge WKCookieManagerRef)probe->store;
        // The first change has only the legacy observer, proving Start enables the backend.
        NSTimer* timer = [NSTimer scheduledTimerWithTimeInterval:30 target:probe selector:@selector(deadline) userInfo:nil repeats:NO];
        [probe beginPhase];
        CFRunLoopRun();
        [timer invalidate];
        check(probe->finished, "all cookie manager phases completed");
        [probe->store release];
        [probe->dataStore release];
        [probe release];
        printf("Cocoa curl Safari cookie manager: FAILED=%u\n", failures);
    }
    return failures ? 1 : 0;
}
