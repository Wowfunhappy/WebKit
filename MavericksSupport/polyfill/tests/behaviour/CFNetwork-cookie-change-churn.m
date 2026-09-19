// Cookie-change subscription under mutation churn on 10.9's cookied-backed jar: a subscriber to changes in a set
// of domains, and writes that store cookies and discard expired ones in those domains. Each mode runs in a child
// process, so a fault inside the jar reports as the child's signal. Modes:
//   main    every write on the main thread, with the storage observer's run-loop callbacks pumped between writes
//   reader  the same, and a second thread reading the jar's cookies for those URLs throughout
//   large   a few domains each holding hundreds of multi-kilobyte cookies, expired ones mixed into every write
//   deleters the main-thread writes, and a global dispatch queue deleting cookies in those domains throughout, as
//           NetworkStorageSession::deleteCookie does
//   deleters-unsubscribed  the same writes and deletes with no change subscription
#import <Foundation/Foundation.h>
#include <crt_externs.h>
#include <mach-o/dyld.h>
#include <mach/mach_time.h>
#include <float.h>
#include <dlfcn.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>

@interface NSHTTPCookieStorage (WKChurnSubscription)
- (instancetype)_initWithCFHTTPCookieStorage:(CFTypeRef)storage;
- (void)_setCookiesChangedHandler:(void (^)(NSArray<NSHTTPCookie *> *, NSString *))handler onQueue:(dispatch_queue_t)queue;
- (void)_setCookiesRemovedHandler:(void (^)(NSArray<NSHTTPCookie *> *, NSString *, bool))handler onQueue:(dispatch_queue_t)queue;
- (void)_setSubscribedDomainsForCookieChanges:(NSSet<NSString *> *)domains;
@end

static const int wk_domainCount = 12;
static NSString *wk_host(int i) { return [NSString stringWithFormat:@"site%d.churn.test", i]; }
static NSURL *wk_url(int i) { return [NSURL URLWithString:[NSString stringWithFormat:@"http://%@/", wk_host(i)]]; }

static NSHTTPCookie *wk_cookie(int domain, NSString *name, NSString *value, NSDate *expires)
{
    NSMutableDictionary *properties = [@{ NSHTTPCookieName: name, NSHTTPCookieValue: value, NSHTTPCookieDomain: wk_host(domain), NSHTTPCookiePath: @"/" } mutableCopy];
    if (expires)
        properties[NSHTTPCookieExpires] = expires;
    NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:properties];
    [properties release];
    return cookie;
}

static void wk_forgetChurnCookies(NSHTTPCookieStorage *jar)
{
    for (NSHTTPCookie *cookie in [[[jar cookies] copy] autorelease]) {
        if ([cookie.domain hasSuffix:@"churn.test"])
            [jar deleteCookie:cookie];
    }
}

static int wk_runChurn(BOOL withReader, int rounds)
{
    @autoreleasepool {
        NSHTTPCookieStorage *jar = [NSHTTPCookieStorage sharedHTTPCookieStorage];
        jar.cookieAcceptPolicy = NSHTTPCookieAcceptPolicyAlways;
        wk_forgetChurnCookies(jar);
        NSMutableSet *domains = [NSMutableSet set];
        for (int i = 0; i < wk_domainCount; ++i)
            [domains addObject:wk_host(i)];
        __block long delivered = 0;
        dispatch_queue_t queue = dispatch_queue_create("churn.handlers", DISPATCH_QUEUE_SERIAL);
        [jar _setCookiesChangedHandler:^(NSArray<NSHTTPCookie *> *cookies, NSString *domain) { delivered += cookies.count; } onQueue:queue];
        [jar _setCookiesRemovedHandler:^(NSArray<NSHTTPCookie *> *cookies, NSString *domain, bool all) { delivered += cookies.count; } onQueue:queue];
        [jar _setSubscribedDomainsForCookieChanges:domains];

        __block BOOL stop = NO;
        if (withReader) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                while (!stop) {
                    @autoreleasepool {
                        for (int i = 0; i < wk_domainCount && !stop; ++i)
                            (void)[jar cookiesForURL:wk_url(i)];
                    }
                }
            });
        }
        NSDate *past = [NSDate dateWithTimeIntervalSince1970:0];
        NSString *longValue = [@"" stringByPaddingToLength:120 withString:@"v" startingAtIndex:0];
        for (int round = 0; round < rounds; ++round) {
            @autoreleasepool {
                int d = round % wk_domainCount;
                NSMutableArray *batch = [NSMutableArray array];
                for (int i = 0; i < 20; ++i) {
                    [batch addObject:wk_cookie(d, [NSString stringWithFormat:@"live%d_%d", round % 30, i], [longValue stringByAppendingFormat:@"%d", round], nil)];
                    [batch addObject:wk_cookie(d, [NSString stringWithFormat:@"live%d_%d", (round + 11) % 30, i], @"", past)];
                    [batch addObject:wk_cookie(d, [NSString stringWithFormat:@"gone%d", i], @"x", past)];
                }
                [jar setCookies:batch forURL:wk_url(d) mainDocumentURL:wk_url(d)];
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
            }
        }
        stop = YES;
        [jar _setSubscribedDomainsForCookieChanges:[NSSet set]];
        wk_forgetChurnCookies(jar);
        printf("  %s: %d rounds, %ld changes delivered\n", withReader ? "reader" : "main", rounds, delivered);
        return 0;
    }
}

static int wk_runLargeJar(int rounds)
{
    @autoreleasepool {
        NSHTTPCookieStorage *jar = [NSHTTPCookieStorage sharedHTTPCookieStorage];
        jar.cookieAcceptPolicy = NSHTTPCookieAcceptPolicyAlways;
        wk_forgetChurnCookies(jar);
        const int domains = 3;
        NSMutableSet *subscribed = [NSMutableSet set];
        for (int i = 0; i < domains; ++i)
            [subscribed addObject:wk_host(i)];
        __block long delivered = 0;
        dispatch_queue_t queue = dispatch_queue_create("churn.large.handlers", DISPATCH_QUEUE_SERIAL);
        [jar _setCookiesChangedHandler:^(NSArray<NSHTTPCookie *> *cookies, NSString *domain) { delivered += cookies.count; } onQueue:queue];
        [jar _setCookiesRemovedHandler:^(NSArray<NSHTTPCookie *> *cookies, NSString *domain, bool all) { delivered += cookies.count; } onQueue:queue];
        [jar _setSubscribedDomainsForCookieChanges:subscribed];
        NSDate *past = [NSDate dateWithTimeIntervalSince1970:0];
        NSDate *future = [NSDate dateWithTimeIntervalSinceNow:3600];
        NSString *bigValue = [@"" stringByPaddingToLength:3500 withString:@"b" startingAtIndex:0];
        for (int round = 0; round < rounds; ++round) {
            @autoreleasepool {
                int d = round % domains;
                NSMutableArray *batch = [NSMutableArray array];
                for (int i = 0; i < 40; ++i) {
                    int slot = (round * 7 + i) % 300;
                    [batch addObject:wk_cookie(d, [NSString stringWithFormat:@"big%d", slot], [bigValue stringByAppendingFormat:@"%d", round], future)];
                    [batch addObject:wk_cookie(d, [NSString stringWithFormat:@"big%d", (slot + 150) % 300], @"", past)];
                }
                [jar setCookies:batch forURL:wk_url(d) mainDocumentURL:wk_url(d)];
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
            }
        }
        [jar _setSubscribedDomainsForCookieChanges:[NSSet set]];
        wk_forgetChurnCookies(jar);
        printf("  large: %d rounds, %ld changes delivered\n", rounds, delivered);
        return 0;
    }
}

static int wk_runDeleters(int rounds, BOOL subscribed)
{
    @autoreleasepool {
        NSHTTPCookieStorage *jar = [NSHTTPCookieStorage sharedHTTPCookieStorage];
        jar.cookieAcceptPolicy = NSHTTPCookieAcceptPolicyAlways;
        wk_forgetChurnCookies(jar);
        NSMutableSet *domains = [NSMutableSet set];
        for (int i = 0; i < wk_domainCount; ++i)
            [domains addObject:wk_host(i)];
        __block long delivered = 0;
        dispatch_queue_t queue = dispatch_queue_create("churn.deleters.handlers", DISPATCH_QUEUE_SERIAL);
        [jar _setCookiesChangedHandler:^(NSArray<NSHTTPCookie *> *cookies, NSString *domain) { delivered += cookies.count; } onQueue:queue];
        [jar _setCookiesRemovedHandler:^(NSArray<NSHTTPCookie *> *cookies, NSString *domain, bool all) { delivered += cookies.count; } onQueue:queue];
        if (subscribed)
            [jar _setSubscribedDomainsForCookieChanges:domains];
        __block BOOL stop = NO;
        dispatch_group_t deleters = dispatch_group_create();
        for (int worker = 0; worker < 3; ++worker) {
            dispatch_group_async(deleters, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                int n = 0;
                while (!stop) {
                    @autoreleasepool {
                        int d = (n + worker * 5) % wk_domainCount;
                        for (NSHTTPCookie *cookie in [jar cookiesForURL:wk_url(d)]) {
                            if (stop)
                                break;
                            if ((++n % 3) == 0)
                                [jar deleteCookie:cookie];
                        }
                    }
                }
            });
        }
        NSDate *past = [NSDate dateWithTimeIntervalSince1970:0];
        NSString *longValue = [@"" stringByPaddingToLength:400 withString:@"d" startingAtIndex:0];
        for (int round = 0; round < rounds; ++round) {
            @autoreleasepool {
                int d = round % wk_domainCount;
                NSMutableArray *batch = [NSMutableArray array];
                for (int i = 0; i < 20; ++i) {
                    [batch addObject:wk_cookie(d, [NSString stringWithFormat:@"del%d_%d", round % 25, i], [longValue stringByAppendingFormat:@"%d", round], nil)];
                    [batch addObject:wk_cookie(d, [NSString stringWithFormat:@"del%d_%d", (round + 9) % 25, i], @"", past)];
                }
                [jar setCookies:batch forURL:wk_url(d) mainDocumentURL:wk_url(d)];
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
            }
        }
        stop = YES;
        dispatch_group_wait(deleters, DISPATCH_TIME_FOREVER);
        [jar _setSubscribedDomainsForCookieChanges:[NSSet set]];
        wk_forgetChurnCookies(jar);
        printf("  %s: %d rounds, %ld changes delivered\n", subscribed ? "deleters" : "deleters-unsubscribed", rounds, delivered);
        return 0;
    }
}

static double wk_elapsedMilliseconds(uint64_t start, uint64_t end)
{
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    return (double)(end - start) * timebase.numer / timebase.denom / 1e6;
}

static int wk_measureWriteCost(void)
{
    const int sizes[] = { 150, 1000, 3000, 10000 };
    for (unsigned sizeIndex = 0; sizeIndex < sizeof(sizes) / sizeof(sizes[0]); ++sizeIndex) {
        @autoreleasepool {
            int size = sizes[sizeIndex];
            CFTypeRef (*createStorage)(CFAllocatorRef, CFTypeRef) = dlsym(RTLD_DEFAULT, "CFHTTPCookieStorageCreateInMemory");
            if (!createStorage) {
                fprintf(stderr, "CFHTTPCookieStorageCreateInMemory is unavailable\n");
                return 1;
            }
            CFTypeRef storage = createStorage(NULL, NULL);
            NSHTTPCookieStorage *jar = [[NSHTTPCookieStorage alloc] _initWithCFHTTPCookieStorage:storage];
            CFRelease(storage);
            jar.cookieAcceptPolicy = NSHTTPCookieAcceptPolicyAlways;
            NSDate *future = [NSDate dateWithTimeIntervalSinceNow:3600];
            for (int i = 0; i < size; ++i) {
                NSString *domain = [NSString stringWithFormat:@"site%d.write-cost.test", i / 5];
                NSHTTPCookie *stored = [NSHTTPCookie cookieWithProperties:@{ NSHTTPCookieName: [NSString stringWithFormat:@"cost%d", i], NSHTTPCookieValue: @"0123456789abcdef", NSHTTPCookieDomain: domain, NSHTTPCookiePath: @"/", NSHTTPCookieExpires: future }];
                [jar setCookie:stored];
            }
            dispatch_queue_t queue = dispatch_queue_create("churn.cost.handlers", DISPATCH_QUEUE_SERIAL);
            [jar _setCookiesChangedHandler:^(NSArray<NSHTTPCookie *> *cookies, NSString *domain) { (void)cookies; (void)domain; } onQueue:queue];
            [jar _setSubscribedDomainsForCookieChanges:[NSSet setWithObject:@"site0.write-cost.test"]];
            double best = DBL_MAX;
            double total = 0;
            const int writes = 50;
            for (int write = 0; write < writes; ++write) {
                NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:@{ NSHTTPCookieName: @"cost0", NSHTTPCookieValue: [NSString stringWithFormat:@"value%d", write], NSHTTPCookieDomain: @"site0.write-cost.test", NSHTTPCookiePath: @"/", NSHTTPCookieExpires: future }];
                uint64_t start = mach_absolute_time();
                [jar setCookie:cookie];
                double elapsed = wk_elapsedMilliseconds(start, mach_absolute_time());
                best = MIN(best, elapsed);
                total += elapsed;
            }
            printf("  cost: requested=%d stored=%lu best=%.3f ms mean=%.3f ms per write\n", size, (unsigned long)jar.cookies.count, best, total / writes);
            [jar _setSubscribedDomainsForCookieChanges:[NSSet set]];
            dispatch_release(queue);
            [jar release];
        }
    }
    return 0;
}

static int wk_spawnMode(const char *mode, const char *rounds)
{
    char executable[PATH_MAX];
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size))
        return -1;
    char *arguments[] = { executable, (char *)mode, (char *)rounds, NULL };
    pid_t child = 0;
    if (posix_spawn(&child, executable, NULL, NULL, arguments, *_NSGetEnviron()))
        return -1;
    int status = 0;
    if (waitpid(child, &status, 0) != child)
        return -1;
    if (WIFSIGNALED(status)) {
        printf("  FAIL: %s mode died with signal %d (%s)\n", mode, WTERMSIG(status), strsignal(WTERMSIG(status)));
        return 1;
    }
    return WIFEXITED(status) && !WEXITSTATUS(status) ? 0 : 1;
}

int main(int argc, char **argv)
{
    if (argc > 2 && !strcmp(argv[1], "main"))
        return wk_runChurn(NO, atoi(argv[2]));
    if (argc > 2 && !strcmp(argv[1], "reader"))
        return wk_runChurn(YES, atoi(argv[2]));
    if (argc > 2 && !strcmp(argv[1], "large"))
        return wk_runLargeJar(atoi(argv[2]));
    if (argc > 2 && !strcmp(argv[1], "deleters"))
        return wk_runDeleters(atoi(argv[2]), YES);
    if (argc > 2 && !strcmp(argv[1], "deleters-unsubscribed"))
        return wk_runDeleters(atoi(argv[2]), NO);
    if (argc > 1 && !strcmp(argv[1], "cost"))
        return wk_measureWriteCost();
    const char *rounds = argc > 1 ? argv[1] : "20";
    const char *only = argc > 2 ? argv[2] : NULL;
    printf("Cookie-change subscription under mutation churn (%s rounds per mode):\n", rounds);
    int failures = 0;
    const char *modes[] = { "main", "reader", "large", "deleters", "deleters-unsubscribed", "cost" };
    for (unsigned m = 0; m < sizeof(modes) / sizeof(modes[0]); ++m) {
        const char *mode = modes[m];
        // Write-cost measurement is an opt-in benchmark; the default exercises mutation modes.
        if (only ? !strcmp(only, mode) : strcmp(mode, "cost"))
            failures += wk_spawnMode(mode, rounds);
    }
    printf(failures ? "  %d FAILED\n" : "  ok\n", failures);
    return failures ? 1 : 0;
}
