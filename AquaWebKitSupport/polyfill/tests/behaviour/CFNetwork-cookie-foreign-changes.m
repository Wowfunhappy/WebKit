#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdio.h>

@interface NSHTTPCookieStorage (ForeignChangesTest)
- (void)_setCookiesChangedHandler:(void (^)(NSArray<NSHTTPCookie *> *, NSString *))handler onQueue:(dispatch_queue_t)queue;
- (void)_setCookiesRemovedHandler:(void (^)(NSArray<NSHTTPCookie *> *, NSString *, bool))handler onQueue:(dispatch_queue_t)queue;
- (void)_setSubscribedDomainsForCookieChanges:(NSSet<NSString *> *)domains;
@end

// Runs a separate, unpolyfilled process that changes the shared jar.
static void runForeignProcess(NSString *script)
{
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/usr/bin/python";
    task.arguments = @[ @"-c", [@"from Foundation import *\nimport time\ns = NSHTTPCookieStorage.sharedHTTPCookieStorage()\n" stringByAppendingString:script] ];
    [task launch];
    [task waitUntilExit];
    assert(task.terminationStatus == 0);
    [task release];
}

static BOOL waitFor(NSArray *deliveries, NSString *expected, NSTimeInterval limit)
{
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:limit];
    while (![deliveries containsObject:expected] && [deadline timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    return [deliveries containsObject:expected];
}

// The change handlers of the shared jar hear a change another process makes to it: 10.9 tells only the
// process that made the change, and the subscription hears the jar's directory change.
int main(void)
{
    @autoreleasepool {
        NSHTTPCookieStorage *shared = [NSHTTPCookieStorage sharedHTTPCookieStorage];
        NSMutableArray *changed = [NSMutableArray array];
        NSMutableArray *removed = [NSMutableArray array];
        [shared _setCookiesChangedHandler:^(NSArray<NSHTTPCookie *> *cookies, NSString *domain) {
            for (NSHTTPCookie *cookie in cookies)
                [changed addObject:[NSString stringWithFormat:@"%@=%@@%@", cookie.name, cookie.value, domain]];
        } onQueue:dispatch_get_main_queue()];
        [shared _setCookiesRemovedHandler:^(NSArray<NSHTTPCookie *> *cookies, NSString *domain, bool removeAll) {
            for (NSHTTPCookie *cookie in cookies)
                [removed addObject:[NSString stringWithFormat:@"%@@%@", cookie.name, domain]];
        } onQueue:dispatch_get_main_queue()];
        [shared _setSubscribedDomainsForCookieChanges:[NSSet setWithObject:@"foreign-change.test"]];
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];

        NSString *value = [NSString stringWithFormat:@"v%ld", (long)[NSDate date].timeIntervalSince1970];
        runForeignProcess([NSString stringWithFormat:@"s.setCookie_(NSHTTPCookie.cookieWithProperties_({'Name': 'foreign', 'Value': '%@', 'Domain': 'foreign-change.test', 'Path': '/', 'Expires': NSDate.dateWithTimeIntervalSinceNow_(3600)}))\nNSRunLoop.currentRunLoop().runUntilDate_(NSDate.dateWithTimeIntervalSinceNow_(2))\n", value]);
        NSString *expectedChange = [NSString stringWithFormat:@"foreign=%@@foreign-change.test", value];
        if (!waitFor(changed, expectedChange, 15)) {
            printf("  FAIL: no change delivered for %s; got %s\n", expectedChange.UTF8String, changed.description.UTF8String);
            return 1;
        }

        runForeignProcess(@"for c in (s.cookies() or []):\n    if c.domain() == 'foreign-change.test': s.deleteCookie_(c)\nNSRunLoop.currentRunLoop().runUntilDate_(NSDate.dateWithTimeIntervalSinceNow_(2))\n");
        if (!waitFor(removed, @"foreign@foreign-change.test", 15)) {
            printf("  FAIL: no removal delivered; got %s\n", removed.description.UTF8String);
            return 1;
        }
        [shared _setCookiesChangedHandler:nil onQueue:nil];
        [shared _setCookiesRemovedHandler:nil onQueue:nil];
        puts("PASS another process's change to the shared jar reaches the change handlers");
    }
    return 0;
}
