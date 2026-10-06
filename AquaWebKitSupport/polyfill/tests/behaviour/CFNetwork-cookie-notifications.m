#import <Foundation/Foundation.h>
#include <assert.h>
#include <dlfcn.h>
#include <stdio.h>

typedef const void* CookieStorageRef;
typedef const void* CookieRef;
extern CookieStorageRef _CFHTTPCookieStorageGetDefault(CFAllocatorRef);
@interface NSHTTPCookieStorage (NotificationsTest)
- (instancetype)_initWithCFHTTPCookieStorage:(CookieStorageRef)storage;
+ (void)_setSharedHTTPCookieStorage:(NSHTTPCookieStorage *)storage;
- (void)_setCookiesChangedHandler:(void (^)(NSArray<NSHTTPCookie *> *, NSString *))handler onQueue:(dispatch_queue_t)queue;
- (void)_setCookiesRemovedHandler:(void (^)(NSArray<NSHTTPCookie *> *, NSString *, bool))handler onQueue:(dispatch_queue_t)queue;
- (void)_setSubscribedDomainsForCookieChanges:(NSSet<NSString *> *)domains;
@end
@interface NSHTTPCookie (NotificationsTest)
- (CookieRef)_GetInternalCFHTTPCookie;
@end

static void waitForNotification(unsigned* count, unsigned expected)
{
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    while (*count < expected && [deadline timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:deadline];
    assert(*count == expected);
}

static void spinFor(NSTimeInterval interval)
{
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:interval];
    while ([deadline timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:deadline];
}

static void waitForDeliveries(NSArray* deliveries, NSUInteger expected)
{
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    while (deliveries.count < expected && [deadline timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:deadline];
    // A late duplicate of the same change would arrive from the storage observer.
    spinFor(0.3);
    if (deliveries.count != expected)
        printf("  FAIL: expected %lu deliveries, got %lu: %s\n", (unsigned long)expected, (unsigned long)deliveries.count, deliveries.description.UTF8String);
    assert(deliveries.count == expected);
}

static NSHTTPCookie* cookieNamed(NSString* name, NSString* domain, NSDate* expires)
{
    NSMutableDictionary* properties = [@{ NSHTTPCookieName: name, NSHTTPCookieValue: @"value",
        NSHTTPCookieDomain: domain, NSHTTPCookiePath: @"/" } mutableCopy];
    if (expires)
        properties[NSHTTPCookieExpires] = expires;
    NSHTTPCookie* cookie = [NSHTTPCookie cookieWithProperties:properties];
    [properties release];
    return cookie;
}

// The change handlers hear every change to the storage in a subscribed domain: a write through another
// wrapper of the jar, and a write CFNetwork makes on the jar directly, including one whose expiry removes
// a cookie. A change the handlers heard at its mutation is not heard again from the storage.
static void checkSubscriptionHearsStorageWideChanges(void)
{
    CookieStorageRef (*create)(CFAllocatorRef, CookieStorageRef) = dlsym(RTLD_DEFAULT, "CFHTTPCookieStorageCreateInMemory");
    void (*setCookie)(CookieStorageRef, CookieRef) = dlsym(RTLD_DEFAULT, "CFHTTPCookieStorageSetCookie");
    void (*setPolicy)(CookieStorageRef, CFIndex) = dlsym(RTLD_DEFAULT, "CFHTTPCookieStorageSetCookieAcceptPolicy");
    assert(create && setCookie && setPolicy);
    CookieStorageRef jar = create(NULL, NULL);
    assert(jar);
    setPolicy(jar, NSHTTPCookieAcceptPolicyAlways);
    NSHTTPCookieStorage* subscriber = [[NSHTTPCookieStorage alloc] _initWithCFHTTPCookieStorage:jar];
    NSHTTPCookieStorage* writer = [[NSHTTPCookieStorage alloc] _initWithCFHTTPCookieStorage:jar];
    NSMutableArray* changed = [NSMutableArray array];
    NSMutableArray* removed = [NSMutableArray array];
    [subscriber _setCookiesChangedHandler:^(NSArray<NSHTTPCookie *>* cookies, NSString* domain) {
        for (NSHTTPCookie* cookie in cookies)
            [changed addObject:[NSString stringWithFormat:@"%@@%@", cookie.name, domain]];
    } onQueue:dispatch_get_main_queue()];
    [subscriber _setCookiesRemovedHandler:^(NSArray<NSHTTPCookie *>* cookies, NSString* domain, bool removeAll) {
        assert(!removeAll);
        for (NSHTTPCookie* cookie in cookies)
            [removed addObject:[NSString stringWithFormat:@"%@@%@", cookie.name, domain]];
    } onQueue:dispatch_get_main_queue()];
    [subscriber _setSubscribedDomainsForCookieChanges:[NSSet setWithObject:@"observed.test"]];

    [writer setCookie:cookieNamed(@"wrapper", @"observed.test", nil)];
    waitForDeliveries(changed, 1);
    assert([changed[0] isEqual:@"wrapper@observed.test"]);

    setCookie(jar, [cookieNamed(@"direct", @".observed.test", nil) _GetInternalCFHTTPCookie]);
    waitForDeliveries(changed, 2);
    assert([changed[1] isEqual:@"direct@observed.test"]);

    setCookie(jar, [cookieNamed(@"direct", @".observed.test", [NSDate dateWithTimeIntervalSinceNow:-60]) _GetInternalCFHTTPCookie]);
    waitForDeliveries(removed, 1);
    assert([removed[0] isEqual:@"direct@observed.test"]);

    setCookie(jar, [cookieNamed(@"unrelated", @"unrelated.test", nil) _GetInternalCFHTTPCookie]);
    spinFor(0.5);
    assert(changed.count == 2 && removed.count == 1);

    [writer deleteCookie:cookieNamed(@"wrapper", @"observed.test", nil)];
    waitForDeliveries(removed, 2);
    assert([removed[1] isEqual:@"wrapper@observed.test"]);

    [subscriber _setCookiesChangedHandler:nil onQueue:nil];
    [subscriber _setCookiesRemovedHandler:nil onQueue:nil];
    setCookie(jar, [cookieNamed(@"after", @"observed.test", nil) _GetInternalCFHTTPCookie]);
    spinFor(0.5);
    assert(changed.count == 2 && removed.count == 2);
    [writer release];
    [subscriber release];
    CFRelease(jar);
    puts("PASS cookie change handlers hear storage-wide changes once");
}

int main(void)
{
    @autoreleasepool {
        NSHTTPCookieStorage* original = [[NSHTTPCookieStorage sharedHTTPCookieStorage] retain];
        CookieStorageRef (*create)(CFAllocatorRef, CookieStorageRef) = dlsym(RTLD_DEFAULT, "CFHTTPCookieStorageCreateInMemory");
        assert(create);
        CookieStorageRef jar = create(NULL, NULL);
        assert(jar);
        NSHTTPCookieStorage* store = [[NSHTTPCookieStorage alloc] _initWithCFHTTPCookieStorage:jar];
        [NSHTTPCookieStorage _setSharedHTTPCookieStorage:store];
        [NSHTTPCookieStorage _setSharedHTTPCookieStorage:store];
        assert([NSHTTPCookieStorage sharedHTTPCookieStorage] == store);
        assert(_CFHTTPCookieStorageGetDefault(kCFAllocatorDefault) == jar);
        __block unsigned notifications = 0;
        id token = [[NSNotificationCenter defaultCenter] addObserverForName:NSHTTPCookieManagerCookiesChangedNotification object:store queue:nil usingBlock:^(NSNotification* note) {
            assert(note.object == store);
            ++notifications;
        }];
        NSHTTPCookie* cookie = [NSHTTPCookie cookieWithProperties:@{
            NSHTTPCookieName:@"notification", NSHTTPCookieValue:@"value",
            NSHTTPCookieDomain:@"cookie-probe.invalid", NSHTTPCookiePath:@"/"
        }];
        [store setCookie:cookie];
        waitForNotification(&notifications, 1);
        assert(store.cookies.count == 1);
        [store deleteCookie:cookie];
        waitForNotification(&notifications, 2);
        assert(!store.cookies.count);
        [[NSNotificationCenter defaultCenter] removeObserver:token];
        [NSHTTPCookieStorage _setSharedHTTPCookieStorage:original];
        [original release];
        [store release];
        CFRelease(jar);
        puts("PASS shared cookie replacement posts native change notifications");
        checkSubscriptionHearsStorageWideChanges();
    }
    return 0;
}
