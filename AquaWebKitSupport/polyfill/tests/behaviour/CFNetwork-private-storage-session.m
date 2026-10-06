// A private storage session's cookie jar: in-memory only, one jar per session, named sessions untouched,
// and the same jar seen from a second image carrying its own copy of the layer -- which is how the
// shipped frameworks are built, and how WebCore creating a session and WebKit copying its jar meet.
// Built twice by build-polyfill.sh: -DWK_PROBE_SECOND_IMAGE makes the dylib, plain makes the program.
#import <Foundation/Foundation.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

typedef struct __CFURLStorageSession *CFURLStorageSessionRef;
typedef struct OpaqueCFHTTPCookieStorage *CFHTTPCookieStorageRef;

extern CFURLStorageSessionRef _CFURLStorageSessionCreate(CFAllocatorRef, CFStringRef, CFDictionaryRef);
extern CFHTTPCookieStorageRef _CFURLStorageSessionCopyCookieStorage(CFAllocatorRef, CFURLStorageSessionRef);

#if defined(WK_PROBE_SECOND_IMAGE)
__attribute__((visibility("default")))
CFHTTPCookieStorageRef wkProbeCopyCookieJar(CFURLStorageSessionRef session)
{
    return _CFURLStorageSessionCopyCookieStorage(kCFAllocatorDefault, session);
}
#else

static int failures;

static void check(bool condition, const char *what)
{
    if (condition)
        return;
    printf("  FAIL: %s\n", what);
    ++failures;
}

static void *cfnetwork(const char *name)
{
    static void *image;
    if (!image)
        image = dlopen("/System/Library/Frameworks/CFNetwork.framework/CFNetwork", RTLD_LAZY);
    void *symbol = image ? dlsym(image, name) : NULL;
    if (!symbol) {
        printf("  FAIL: CFNetwork does not export %s\n", name);
        exit(1);
    }
    return symbol;
}

@interface NSHTTPCookieStorage (PrivateStorageSessionTest)
- (instancetype)_initWithCFHTTPCookieStorage:(CFHTTPCookieStorageRef)storage;
@end

// Every HTTPCookieStorage entry point locks only if its storage carries a CoreLockable --
// HTTPCookieStorage::deleteAllCookies (CFNetwork 0xd2e8e) is `impl = [this+0x10]; if ([impl+0x20])
// { lock; ...Locked(); unlock } else ...Locked()`. CFHTTPCookieStorageCreateInMemory builds its storage
// with MemoryCookieStorage(0) (0x19524), leaving that slot NULL; the archive constructor passes 1
// (0xd4733) and allocates the mutex. NetworkStorageSession::deleteAllCookies runs on a dispatch queue
// while the main thread reads the same jar, so a private session's jar has to be the locking one.
static void *cookieStorageLock(CFHTTPCookieStorageRef jar)
{
    if (!jar)
        return NULL;
    void *impl = ((void **)jar)[4];
    return impl ? ((void **)impl)[4] : NULL;
}

// The access NetworkStorageSession::deleteAllCookies makes: readers and writers on the jar while a
// dispatch queue deletes everything out from under them.
static void hammerConcurrently(CFHTTPCookieStorageRef jar, void (*deleteAllCookies)(CFHTTPCookieStorageRef))
{
    __block volatile int stop = 0;
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    dispatch_group_t group = dispatch_group_create();
    for (int thread = 0; thread < 3; thread++) {
        dispatch_group_async(group, queue, ^{
            NSHTTPCookieStorage *storage = [[NSHTTPCookieStorage alloc] _initWithCFHTTPCookieStorage:jar];
            while (!stop) { @autoreleasepool {
                for (int i = 0; i < 24; i++) {
                    [storage setCookie:[NSHTTPCookie cookieWithProperties:@{
                        NSHTTPCookieName: [NSString stringWithFormat:@"c%d", i], NSHTTPCookieValue: @"1",
                        NSHTTPCookieDomain: [NSString stringWithFormat:@"h%d.invalid", i & 7], NSHTTPCookiePath: @"/" }]];
                }
                (void)[storage cookiesForURL:[NSURL URLWithString:@"http://h1.invalid/"]];
                (void)[[storage cookies] count];
            } }
        });
    }
    dispatch_group_async(group, queue, ^{ while (!stop) { deleteAllCookies(jar); usleep(200); } });
    usleep(2500000);
    stop = 1;
    dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 10ull * NSEC_PER_SEC));
    dispatch_release(group);
}

// 10.9 names the implementation behind a jar in its description: "Memory Cookies" for the
// MemoryCookieStorage the private-session contract calls for, "ExternalCookieStorage" for the
// cookied-hosted jar it hands out otherwise.
static bool jarIsInMemory(CFHTTPCookieStorageRef jar)
{
    CFStringRef description = jar ? CFCopyDescription(jar) : NULL;
    if (!description)
        return false;
    bool inMemory = CFStringFind(description, CFSTR("Memory Cookies"), 0).location != kCFNotFound;
    CFRelease(description);
    return inMemory;
}

static CFURLStorageSessionRef createSession(const char *name, bool isPrivate)
{
    CFStringRef identifier = (CFStringRef)[NSString stringWithFormat:@"%s-%d", name, getpid()];
    if (!isPrivate)
        return _CFURLStorageSessionCreate(kCFAllocatorDefault, identifier, NULL);

    CFStringRef key = *(CFStringRef *)cfnetwork("_kCFURLStorageSessionIsPrivate");
    const void *keys[] = { key };
    const void *values[] = { kCFBooleanTrue };
    CFDictionaryRef properties = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFURLStorageSessionRef session = _CFURLStorageSessionCreate(kCFAllocatorDefault, identifier, properties);
    CFRelease(properties);
    return session;
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        // Line-buffered: a failing assertion has to reach the log even when a later one crashes.
        setvbuf(stdout, NULL, _IOLBF, 0);
        printf("CFNetwork private storage session\n");

        CFURLStorageSessionRef privateSession = createSession("WebKitPrivateStorageSessionTest", true);
        check(privateSession != NULL, "a private storage session is created");
        if (!privateSession)
            return 1;

        CFHTTPCookieStorageRef jar = _CFURLStorageSessionCopyCookieStorage(kCFAllocatorDefault, privateSession);
        check(jar != NULL, "a private session has a cookie jar");
        check(jarIsInMemory(jar), "a private session's jar is in-memory storage");

        CFHTTPCookieStorageRef again = _CFURLStorageSessionCopyCookieStorage(kCFAllocatorDefault, privateSession);
        check(again == jar, "every copy of one private session's jar is the same jar");

        CFURLStorageSessionRef otherSession = createSession("WebKitPrivateStorageSessionTestOther", true);
        CFHTTPCookieStorageRef otherJar = _CFURLStorageSessionCopyCookieStorage(kCFAllocatorDefault, otherSession);
        check(otherJar && otherJar != jar, "each private session has a jar of its own");

        CFURLStorageSessionRef namedSession = createSession("WebKitNamedStorageSessionTest", false);
        CFHTTPCookieStorageRef namedJar = namedSession
            ? _CFURLStorageSessionCopyCookieStorage(kCFAllocatorDefault, namedSession) : NULL;
        check(namedJar != NULL, "a named session has a cookie jar");
        check(!jarIsInMemory(namedJar), "a named session keeps 10.9's own jar");

        // The reads and writes NetworkStorageSession makes of this jar.
        NSHTTPCookieStorage *storage = [[NSHTTPCookieStorage alloc] _initWithCFHTTPCookieStorage:jar];
        NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:@{
            NSHTTPCookieName: @"probe", NSHTTPCookieValue: @"1",
            NSHTTPCookieDomain: @"private-session.invalid", NSHTTPCookiePath: @"/" }];
        [storage setCookie:cookie];
        check([[storage cookies] count] == 1, "a cookie written to a private session's jar is stored");
        check([[storage cookiesForURL:[NSURL URLWithString:@"http://private-session.invalid/x"]] count] == 1,
            "a cookie written to a private session's jar is read back by URL");

        NSHTTPCookieStorage *otherStorage = [[NSHTTPCookieStorage alloc] _initWithCFHTTPCookieStorage:otherJar];
        check(![[otherStorage cookies] count], "one private session's cookies stay out of another's");
        for (NSHTTPCookie *shared in [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookies])
            check(![[shared name] isEqualToString:@"probe"], "a private session's cookies stay out of the shared jar");

        CFHTTPCookieStorageRef (*createInMemory)(CFAllocatorRef, CFHTTPCookieStorageRef) = cfnetwork("CFHTTPCookieStorageCreateInMemory");
        CFHTTPCookieStorageRef unlocked = createInMemory(kCFAllocatorDefault, NULL);
        check(!cookieStorageLock(unlocked), "CFHTTPCookieStorageCreateInMemory builds an unlocked jar");
        check(cookieStorageLock(jar) != NULL, "a private session's jar locks");
        CFRelease(unlocked);

        void (*deleteAllCookies)(CFHTTPCookieStorageRef) = cfnetwork("CFHTTPCookieStorageDeleteAllCookies");
        hammerConcurrently(jar, deleteAllCookies);
        check(true, "a private session's jar survives concurrent deletes and reads");

        void (*setPolicy)(CFHTTPCookieStorageRef, CFIndex) = cfnetwork("CFHTTPCookieStorageSetCookieAcceptPolicy");
        CFIndex (*policy)(CFHTTPCookieStorageRef) = cfnetwork("CFHTTPCookieStorageGetCookieAcceptPolicy");
        setPolicy(jar, NSHTTPCookieAcceptPolicyNever);
        check(policy(jar) == NSHTTPCookieAcceptPolicyNever, "a private session's jar carries a cookie accept policy");

        // A second image with its own copy of the layer, the way each shipped framework force-loads one.
        if (argc > 1) {
            void *image = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
            check(image != NULL, "the second image loads");
            CFHTTPCookieStorageRef (*copyFromSecondImage)(CFURLStorageSessionRef) = image
                ? (CFHTTPCookieStorageRef (*)(CFURLStorageSessionRef))dlsym(image, "wkProbeCopyCookieJar") : NULL;
            check(copyFromSecondImage != NULL, "the second image exports its probe");
            if (copyFromSecondImage) {
                CFHTTPCookieStorageRef fromSecondImage = copyFromSecondImage(privateSession);
                check(fromSecondImage == jar, "a second image copies the same jar out of the session");
                if (fromSecondImage)
                    CFRelease(fromSecondImage);
            }
        }

        CFRelease(jar);
        CFRelease(again);
        if (otherJar)
            CFRelease(otherJar);
        if (namedJar)
            CFRelease(namedJar);
        CFRelease(privateSession);
        CFRelease(otherSession);
        if (namedSession)
            CFRelease(namedSession);

        printf(failures ? "  %d FAILED\n" : "  ok\n", failures);
        return failures ? 1 : 0;
    }
}
#endif // WK_PROBE_SECOND_IMAGE
