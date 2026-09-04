// Foundation: Objective-C methods on Foundation classes (NSURL, NSURLSession and its CFNetwork-backed
// cluster classes, cookies, archiving, ...) that macOS 10.9 does not have (or gets wrong), implemented
// with the APIs 10.9 does have.
//
// To add one: write the method under its real name inside a WK_POLYFILL_ADD_METHODS(Class) block (or
// WK_POLYFILL_REPLACE_METHODS for a method 10.9 has); see wk_selref_scope.h. WebKit's call sites keep
// saying `[obj <name>]` and get the polyfill.
//
// VALUES: prefer a SEMANTIC 10.9 equivalent (a real API that still exists and adapts) over a frozen
// literal. A polyfill's contract is the system API's modern behavior, so it is correct at every caller.

#import "wk_cookie_storage.h"
#import "wk_url_coding.h"
#import "wk_polyfill.h"
#import "wk_samesite.h"
#import "wk_selref_scope.h"
#import <AppKit/AppKit.h>
#import <CoreServices/CoreServices.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <dlfcn.h>
#import <pthread.h>
#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <math.h>
#import <string.h>
#import <sys/stat.h>
#import <mach/mach.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <libkern/OSAtomic.h>
#import <pthread.h>
#import <stdatomic.h>
#import <unistd.h>

// CFNetwork SPI, exported on 10.9 but not declared in any public header.
typedef struct OpaqueCFHTTPCookieStorage *CFHTTPCookieStorageRef;
extern CFHTTPCookieStorageRef _CFHTTPCookieStorageGetDefault(CFAllocatorRef);
extern void CFHTTPCookieStorageSetCookieAcceptPolicy(CFHTTPCookieStorageRef, CFIndex);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

// ---------------------------------------------------------------------------------------------------
// -[NSError underlyingErrors] (10.14+) is the array-valued successor to the single NSUnderlyingErrorKey
// that 10.9's NSError already carries, so return that one error when the userInfo has it and an empty
// array otherwise — the same shape callers iterate, carrying the real underlying error 10.9 records.
WK_POLYFILL_ADD_METHODS(NSError)
- (NSArray<NSError *> *)underlyingErrors
{
    NSError *underlying = [[self userInfo] objectForKey:NSUnderlyingErrorKey];
    return [underlying isKindOfClass:[NSError class]] ? @[underlying] : @[];
}
@end

// ---------------------------------------------------------------------------------------------------
// -[NSProcessInfo isLowPowerModeEnabled] (10.12+). Low Power Mode is a battery-saver state 10.9 has no
// concept of, so the honest answer on this OS is not-enabled. NSProcessInfoPowerStateDidChangeNotification
// (c/Foundation.m) is the paired notification; nothing on 10.9 posts it, so an observer of it simply never
// fires.
WK_POLYFILL_ADD_METHODS(NSProcessInfo)
- (BOOL)isLowPowerModeEnabled { return NO; }
@end

// -[NSHTTPCookieStorageInternal registerForPostingNotificationsWithContext:] (10.10+) makes a cookie
// storage that is not the shared one post NSHTTPCookieManagerCookiesChangedNotification when its
// cookies change. CookieStorageObserver::registerInternalsForNotifications asks it of every session but
// the default, and 10.9 posts that notification only for the shared storage, so the notification
// CookieStorageObserver waits on never arrives. 10.9's per-storage change signal is
// CFHTTPCookieStorageAddObserver, delivered on the run loop it is given, which is what posts it here;
// that observer names no cookies, and neither does the notification.
typedef void (*WKCookieStoragePostProc)(CFHTTPCookieStorageRef store, void *context);
extern void CFHTTPCookieStorageAddObserver(CFHTTPCookieStorageRef store, CFRunLoopRef runLoop, CFStringRef mode, WKCookieStoragePostProc callback, void *context);

static void wk_postCookiesChangedNotification(CFHTTPCookieStorageRef store, void *context)
{
    (void)store;
    [[NSNotificationCenter defaultCenter] postNotificationName:NSHTTPCookieManagerCookiesChangedNotification
                                                        object:(NSHTTPCookieStorage *)context];
}

// One registration per store: CookieStorageObserver asks for this once per observer and never takes it
// back, and a store reached through a second NSHTTPCookieStorage wrapper is the same store, so the flag
// rides on the store rather than on the wrapper. The observer's context is owned for as long as the
// registration it belongs to, which the store outlives.
static const void *const wk_cookiePostingRegisteredKey = &wk_cookiePostingRegisteredKey;

WK_POLYFILL_ADD_METHODS_ON(NSObject, "NSHTTPCookieStorageInternal")
- (void)registerForPostingNotificationsWithContext:(id)context
{
    CFHTTPCookieStorageRef store = ((CFHTTPCookieStorageRef (*)(id, SEL))objc_msgSend)(context, sel_registerName("_cookieStorage"));
    if (!store || objc_getAssociatedObject((id)store, wk_cookiePostingRegisteredKey))
        return;
    objc_setAssociatedObject((id)store, wk_cookiePostingRegisteredKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CFHTTPCookieStorageAddObserver(store, CFRunLoopGetMain(), kCFRunLoopCommonModes,
        wk_postCookiesChangedNotification, [context retain]);
}
@end

// ---------------------------------------------------------------------------------------------------
// Private NSHTTPCookieStorage / NSHTTPCookie cookie SPI (10.10+) that WebCore's NetworkStorageSession
// (Source/WebCore/platform/network/cocoa/NetworkStorageSessionCocoa.mm) uses for the modern
// partition-/SameSite-aware cookie jar. None of these selectors exist on 10.9, so the NetworkProcess
// aborted with an "unrecognized selector" NSInvalidArgumentException the moment a page read or wrote a
// cookie or subscribed to cookie changes. 10.9 has no cookie partitioning, and on this build cookie
// partitioning is off in every sense (NetworkStorageSession::m_isOptInCookiePartitioningEnabled is
// false and CFN_COOKIE_ACCEPTS_POLICY_PARTITION is undefined, so the _getCookiesForPartition: path is
// compiled out), which means the partition argument carries no information here. policyProperties does
// carry information -- NetworkStorageSessionCocoa's policyProperties() fills in
// _kCFHTTPCookiePolicyPropertySiteForCookies and _kCFHTTPCookiePolicyPropertyIsTopLevelNavigation on
// every read and write -- but it is the SameSite context, and 10.9's parser discards a cookie's SameSite
// attribute while reading Set-Cookie, so no cookie in this jar carries the attribute that context would
// be matched against. Each modern selector therefore reduces to the classic 10.9 public API.

// RFC 6265 5.3: a cookie is kept only when its Domain attribute names neither a public suffix nor a
// domain the request host fails to domain-match. 10.9's parser applies neither rule, so
// `document.cookie = "x=1; domain=.com"` from any .com page is stored against `.com` and sent to
// every other .com site. _CFHostIsDomainTopLevel is the public-suffix oracle WebCore's own
// PublicSuffixStore asks on Cocoa, and 10.9 exports it; it answers on Unicode labels, so a name in
// its A-label form is decoded first, as PublicSuffixStoreCocoa's decodeHostName does.
extern Boolean _CFHostIsDomainTopLevel(CFStringRef domain);

static NSString *wk_decodedHostName(NSString *name)
{
    if ([name rangeOfString:@"xn--" options:NSCaseInsensitiveSearch].location == NSNotFound)
        return name;

    typedef int32_t (*IDNToUnicodeFn)(const UniChar*, int32_t, UniChar*, int32_t, int32_t, void*, int32_t*);
    static IDNToUnicodeFn idnToUnicode;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        idnToUnicode = (IDNToUnicodeFn)dlsym(RTLD_DEFAULT, "uidna_IDNToUnicode");
    });
    if (!idnToUnicode)
        return name;

    NSUInteger length = name.length;
    UniChar source[256];
    UniChar decoded[256];
    if (length >= sizeof(source) / sizeof(source[0]))
        return name;
    [name getCharacters:source range:NSMakeRange(0, length)];

    int32_t status = 0;
    int32_t decodedLength = idnToUnicode(source, (int32_t)length, decoded,
        (int32_t)(sizeof(decoded) / sizeof(decoded[0])), 0, NULL, &status);
    if (status > 0 || decodedLength <= 0)
        return name;
    return [NSString stringWithCharacters:decoded length:(NSUInteger)decodedLength];
}

// A host that is an IP literal domain-matches only itself (RFC 6265 5.1.3), and no address is a
// public suffix, so both tests below are skipped for one.
static BOOL wk_hostIsIPLiteral(NSString *host)
{
    if ([host rangeOfString:@":"].location != NSNotFound)
        return YES;
    NSCharacterSet *nonAddress = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789."] invertedSet];
    return host.length && [host rangeOfCharacterFromSet:nonAddress].location == NSNotFound;
}

// RFC 6265bis 5.5: a set-cookie-string carrying a CTL other than HTAB -- %x00-08, %x0A-1F or %x7F --
// is ignored, its attributes included. 10.9's parser keeps one.
static BOOL wk_stringHasControlCharacter(NSString *text)
{
    NSUInteger length = text.length;
    for (NSUInteger i = 0; i < length; ++i) {
        unichar c = [text characterAtIndex:i];
        if (c == '\t')
            continue;
        if (c <= 0x1f || c == 0x7f)
            return YES;
    }
    return NO;
}

static NSHTTPCookie *wk_cookieWithUsableDomain(NSHTTPCookie *cookie, NSURL *url)
{
    NSString *domain = [cookie domain];
    if (!cookie || !domain.length)
        return cookie;

    NSString *host = [url host];
    if (!host.length)
        return nil;

    // RFC 6265 5.3 canonicalises the domain-attribute by stripping a leading dot before anything else
    // is asked of it, and 10.9 stores one the other way round -- it ADDS the dot, so a cookie that
    // named its own host arrives here as ".myserver" against a host of "myserver". The name a cookie
    // is being held to is therefore the bare one, and the tests below are in the RFC's order.
    NSString *bare = [domain hasPrefix:@"."] ? [domain substringFromIndex:1] : domain;
    if (!bare.length)
        return nil;

    // A cookie whose domain-attribute is its own host is a host-only cookie, which 5.3 keeps rather
    // than refuses however the public-suffix rule would answer for that name.
    if ([bare caseInsensitiveCompare:host] == NSOrderedSame)
        return cookie;

    // An address domain-matches only itself (5.1.3), which the line above already answered, so nothing
    // else a cookie names for one can be right.
    if (wk_hostIsIPLiteral(host))
        return nil;

    if (_CFHostIsDomainTopLevel((__bridge CFStringRef)wk_decodedHostName(bare)))
        return nil;

    if (![[host lowercaseString] hasSuffix:[[@"." stringByAppendingString:bare] lowercaseString]])
        return nil;

    return cookie;
}

// -[NSHTTPCookieStorage _getCookiesForURL:…completionHandler:] is the async-shaped successor to
// -cookiesForURL:; it invokes the handler synchronously (the caller RELEASE_ASSERTs this). With a nil
// partition, -cookiesForURL: is the whole answer.
// _setCookies:forURL:mainDocumentURL:policyProperties: is -setCookies:forURL:mainDocumentURL: plus a
// policy dictionary 10.9 cannot honour. _getCookiesForDomain: returns every unpartitioned cookie whose
// domain attribute domain-matches the host (RFC 6265). _saveCookies: is polyfilled further down, over 10.9's
// PRESENT argument-less -_saveCookies.
// _setCookiesChangedHandler:onQueue:/_setCookiesRemovedHandler:onQueue:/
// _setSubscribedDomainsForCookieChanges: are the HAVE(COOKIE_CHANGE_LISTENER_API) hooks
// NetworkStorageSession::registerCookieChangeListenersIfNecessary installs. WebKit names a set of hosts
// and is handed the cookies added to, or removed from, one of them; that is what keeps the WebProcess's
// WebCookieCache -- the answer document.cookie reads -- and the CookieStore API's change events in step
// with the cookies a network response stores. The cookies are named by the storage backend's own
// mutation slots, which c/CFNetwork.c replaces; they report here through +reportCookie:ofStorage:change:
// with the cookie each write stored or deleted, from under the storage's mutex, so nothing below reads
// the storage back.
//
// The watcher belongs to the storage backend rather than to the NSHTTPCookieStorage it is reached
// through, because NetworkStorageSession::nsCookieStorage() allocates a fresh wrapper on every call for
// any session but the default one: the handlers and the subscribed hosts arrive on separate objects
// over one store, and the backend is what the slots know a store by.
typedef void (^WKCookiesChangedHandler)(NSArray<NSHTTPCookie *> *addedCookies, NSString *domainForChangedCookie);
typedef void (^WKCookiesRemovedHandler)(NSArray<NSHTTPCookie *> *removedCookies, NSString *domainForRemovedCookies, BOOL removeAllCookies);

// Foundation's own wrapper over a CFHTTPCookie, which retains it.
@interface NSHTTPCookie (WKPolyfillCFHTTPCookie)
+ (NSHTTPCookie *)cookieWithCFHTTPCookie:(CFTypeRef)cookie;
@end

// RFC 6265 5.1.3: a host-only cookie covers the host it names, a domain cookie that host and every
// subdomain of it. Cookie domains are case-insensitive.
static BOOL wk_cookieDomainMatchesHost(NSString *cookieDomain, NSString *host)
{
    if (!cookieDomain.length || !host.length)
        return NO;

    NSString *bare = [cookieDomain hasPrefix:@"."] ? [cookieDomain substringFromIndex:1] : cookieDomain;
    if (!bare.length)
        return NO;
    if ([host caseInsensitiveCompare:bare] == NSOrderedSame)
        return YES;
    NSUInteger hostLength = host.length, bareLength = bare.length;
    if (hostLength <= bareLength)
        return NO;
    NSRange suffix = NSMakeRange(hostLength - bareLength, bareLength);
    if ([host compare:bare options:NSCaseInsensitiveSearch range:suffix] != NSOrderedSame)
        return NO;
    return [host characterAtIndex:suffix.location - 1] == '.';
}

// Name, domain and path are a stored cookie's identity (RFC 6265 5.3): a second Set-Cookie carrying all
// three replaces the first rather than joining it.
static NSString *wk_cookieIdentity(NSHTTPCookie *cookie)
{
    return [NSString stringWithFormat:@"%@\n%@\n%@", [cookie name], [cookie domain], [cookie path]];
}

static BOOL wk_cookieMatchesStoredCookie(NSHTTPCookie *cookie, NSHTTPCookie *other)
{
    if (![[cookie value] isEqualToString:[other value]])
        return NO;

    NSDate *expiry = [cookie expiresDate];
    NSDate *otherExpiry = [other expiresDate];
    if ((expiry || otherExpiry) && ![expiry isEqualToDate:otherExpiry])
        return NO;

    return [cookie isSecure] == [other isSecure] && [cookie isHTTPOnly] == [other isHTTPOnly];
}

// The cookies of |cookies| that |host| is subscribed to, by identity.
static NSDictionary<NSString *, NSHTTPCookie *> *wk_cookiesForHost(NSArray<NSHTTPCookie *> *cookies, NSString *host)
{
    NSMutableDictionary<NSString *, NSHTTPCookie *> *matching = [NSMutableDictionary dictionary];
    for (NSHTTPCookie *cookie in cookies) {
        if (wk_cookieDomainMatchesHost([cookie domain], host))
            [matching setObject:cookie forKey:wk_cookieIdentity(cookie)];
    }
    return matching;
}

@interface WKPolyfillCookieWatcher : NSObject {
@private
    const void *_backend;
    WKCookiesChangedHandler _changedHandler;
    dispatch_queue_t _changedQueue;
    WKCookiesRemovedHandler _removedHandler;
    dispatch_queue_t _removedQueue;
    NSSet<NSString *> *_hosts;
}
+ (void)reportCookie:(CFTypeRef)cookie ofStorage:(const void *)backend change:(int)change;
+ (BOOL)wantsReportsForStorage:(const void *)backend domain:(const char *)domain;
+ (void)reportMergeOfStorage:(const void *)backend before:(CFArrayRef)before after:(CFArrayRef)after;
- (instancetype)initWithBackend:(const void *)backend;
- (void)reportCookie:(CFTypeRef)cookie change:(int)change;
- (void)reportMergeBefore:(NSArray<NSHTTPCookie *> *)before after:(NSArray<NSHTTPCookie *> *)after;
- (void)setChangedHandler:(WKCookiesChangedHandler)handler queue:(dispatch_queue_t)queue;
- (void)setRemovedHandler:(WKCookiesRemovedHandler)handler queue:(dispatch_queue_t)queue;
- (void)setSubscribedHosts:(NSSet<NSString *> *)hosts;
@end

static pthread_mutex_t wk_cookieWatcherLock = PTHREAD_MUTEX_INITIALIZER;
static NSMutableDictionary<NSValue *, WKPolyfillCookieWatcher *> *wk_cookieWatchers;

// The caller holds wk_cookieWatcherLock.
static WKPolyfillCookieWatcher *wk_cookieWatcherForStorage(NSHTTPCookieStorage *storage, BOOL create)
{
    CFHTTPCookieStorageRef store = ((CFHTTPCookieStorageRef (*)(id, SEL))objc_msgSend)(storage, sel_registerName("_cookieStorage"));
    if (!store)
        return nil;

    const void *backend = wk_cookieStorageBackend(store);
    NSValue *key = [NSValue valueWithPointer:backend];
    WKPolyfillCookieWatcher *watcher = [wk_cookieWatchers objectForKey:key];
    if (watcher || !create)
        return watcher;

    watcher = [[[WKPolyfillCookieWatcher alloc] initWithBackend:backend] autorelease];
    if (!wk_cookieWatchers)
        wk_cookieWatchers = [[NSMutableDictionary alloc] init];
    [wk_cookieWatchers setObject:watcher forKey:key];
    return watcher;
}

// A CFHTTPCookie is not the same object as an NSHTTPCookie -- the two are not bridged -- so the records
// the storage was read for arrive as the wrapper Foundation makes of each.
static NSArray<NSHTTPCookie *> *wk_cookiesFromCFCookies(CFArrayRef cfCookies)
{
    CFIndex count = cfCookies ? CFArrayGetCount(cfCookies) : 0;
    NSMutableArray<NSHTTPCookie *> *cookies = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
    for (CFIndex i = 0; i < count; ++i)
        [cookies addObject:[NSHTTPCookie cookieWithCFHTTPCookie:CFArrayGetValueAtIndex(cfCookies, i)]];
    return cookies;
}

@implementation WKPolyfillCookieWatcher

- (instancetype)initWithBackend:(const void *)backend
{
    self = [super init];
    if (!self)
        return nil;
    _backend = backend;
    return self;
}

- (void)dealloc
{
    [_changedHandler release];
    [_changedQueue release];
    [_removedHandler release];
    [_removedQueue release];
    [_hosts release];
    [super dealloc];
}

// The caller holds wk_cookieWatcherLock. A watcher with neither handler nor host retires.
- (void)retireIfIdle
{
    if (_changedHandler || _removedHandler || [_hosts count])
        return;
    [[self retain] autorelease];
    [wk_cookieWatchers removeObjectForKey:[NSValue valueWithPointer:_backend]];
}

- (void)setChangedHandler:(WKCookiesChangedHandler)handler queue:(dispatch_queue_t)queue
{
    WKCookiesChangedHandler copied = handler ? [handler copy] : nil;
    [_changedHandler release];
    _changedHandler = copied;
    [queue retain];
    [_changedQueue release];
    _changedQueue = queue;
    [self retireIfIdle];
}

- (void)setRemovedHandler:(WKCookiesRemovedHandler)handler queue:(dispatch_queue_t)queue
{
    WKCookiesRemovedHandler copied = handler ? [handler copy] : nil;
    [_removedHandler release];
    _removedHandler = copied;
    [queue retain];
    [_removedQueue release];
    _removedQueue = queue;
    [self retireIfIdle];
}

- (void)setSubscribedHosts:(NSSet<NSString *> *)hosts
{
    NSSet<NSString *> *copied = [hosts copy];
    [_hosts release];
    _hosts = copied;
    [self retireIfIdle];
}

// Whether a report for this domain would reach anyone. c/CFNetwork.c asks this before it asks the
// storage what it already holds, which is the expensive half of deciding whether a write changed
// anything: ExternalCookieStorage invalidates its per-domain cache on every write, so that question
// costs a synchronous cookied round trip.
+ (BOOL)wantsReportsForStorage:(const void *)backend domain:(const char *)domain
{
    if (!domain)
        return NO;
    @autoreleasepool {
        pthread_mutex_lock(&wk_cookieWatcherLock);
        WKPolyfillCookieWatcher *watcher = [[[wk_cookieWatchers objectForKey:[NSValue valueWithPointer:backend]] retain] autorelease];
        pthread_mutex_unlock(&wk_cookieWatcherLock);
        if (!watcher)
            return NO;

        pthread_mutex_lock(&wk_cookieWatcherLock);
        BOOL anyHandler = watcher->_changedHandler || watcher->_removedHandler;
        NSSet<NSString *> *hosts = [watcher->_hosts retain];
        pthread_mutex_unlock(&wk_cookieWatcherLock);

        BOOL wanted = NO;
        if (anyHandler) {
            NSString *text = [NSString stringWithUTF8String:domain];
            for (NSString *host in hosts) {
                if (text && wk_cookieDomainMatchesHost(text, host)) {
                    wanted = YES;
                    break;
                }
            }
        }
        [hosts release];
        return wanted;
    }
}

+ (void)reportCookie:(CFTypeRef)cookie ofStorage:(const void *)backend change:(int)change
{
    @autoreleasepool {
        pthread_mutex_lock(&wk_cookieWatcherLock);
        WKPolyfillCookieWatcher *watcher = [[[wk_cookieWatchers objectForKey:[NSValue valueWithPointer:backend]] retain] autorelease];
        pthread_mutex_unlock(&wk_cookieWatcherLock);
        [watcher reportCookie:cookie change:change];
    }
}

// A file-backed storage's sync takes in whatever another process wrote to its file, in bulk. The two
// sides of that merge name the cookies it moved, which is what a subscriber is owed.
+ (void)reportMergeOfStorage:(const void *)backend before:(CFArrayRef)before after:(CFArrayRef)after
{
    @autoreleasepool {
        pthread_mutex_lock(&wk_cookieWatcherLock);
        WKPolyfillCookieWatcher *watcher = [[[wk_cookieWatchers objectForKey:[NSValue valueWithPointer:backend]] retain] autorelease];
        pthread_mutex_unlock(&wk_cookieWatcherLock);
        if (!watcher)
            return;
        [watcher reportMergeBefore:wk_cookiesFromCFCookies(before) after:wk_cookiesFromCFCookies(after)];
    }
}

- (void)reportMergeBefore:(NSArray<NSHTTPCookie *> *)before after:(NSArray<NSHTTPCookie *> *)after
{
    pthread_mutex_lock(&wk_cookieWatcherLock);
    WKCookiesChangedHandler changedHandler = [_changedHandler retain];
    dispatch_queue_t changedQueue = [_changedQueue retain];
    WKCookiesRemovedHandler removedHandler = [_removedHandler retain];
    dispatch_queue_t removedQueue = [_removedQueue retain];
    NSSet<NSString *> *hosts = [_hosts retain];
    pthread_mutex_unlock(&wk_cookieWatcherLock);

    for (NSString *host in hosts) {
        NSDictionary<NSString *, NSHTTPCookie *> *was = wk_cookiesForHost(before, host);
        NSDictionary<NSString *, NSHTTPCookie *> *now = wk_cookiesForHost(after, host);

        NSMutableArray<NSHTTPCookie *> *added = [NSMutableArray array];
        NSMutableArray<NSHTTPCookie *> *removed = [NSMutableArray array];
        for (NSString *identity in now) {
            NSHTTPCookie *cookie = [now objectForKey:identity];
            NSHTTPCookie *stored = [was objectForKey:identity];
            // A cookie whose value or attributes changed is a set, not a pair of edits: the merge
            // replaces it under the same identity.
            if (!stored || !wk_cookieMatchesStoredCookie(cookie, stored))
                [added addObject:cookie];
        }
        for (NSString *identity in was) {
            if (![now objectForKey:identity])
                [removed addObject:[was objectForKey:identity]];
        }

        if ([added count] && changedHandler)
            dispatch_async(changedQueue, ^{ changedHandler(added, host); });
        if ([removed count] && removedHandler)
            dispatch_async(removedQueue, ^{ removedHandler(removed, host, NO); });
    }

    [changedHandler release];
    [changedQueue release];
    [removedHandler release];
    [removedQueue release];
    [hosts release];
}

// A cookie is delivered under every subscribed host its domain covers, which is the host WebKit
// registered its observers by.
- (void)reportCookie:(CFTypeRef)cfCookie change:(int)change
{
    pthread_mutex_lock(&wk_cookieWatcherLock);
    WKCookiesChangedHandler changedHandler = [_changedHandler retain];
    dispatch_queue_t changedQueue = [_changedQueue retain];
    WKCookiesRemovedHandler removedHandler = [_removedHandler retain];
    dispatch_queue_t removedQueue = [_removedQueue retain];
    NSSet<NSString *> *hosts = [_hosts retain];
    pthread_mutex_unlock(&wk_cookieWatcherLock);

    if (change == WK_COOKIE_ALL_DELETED) {
        if (removedHandler)
            dispatch_async(removedQueue, ^{ removedHandler(@[], @"", YES); });
    } else if (cfCookie) {
        NSHTTPCookie *cookie = [NSHTTPCookie cookieWithCFHTTPCookie:cfCookie];
        NSArray<NSHTTPCookie *> *cookies = @[cookie];
        NSString *domain = [cookie domain];
        for (NSString *host in hosts) {
            if (!wk_cookieDomainMatchesHost(domain, host))
                continue;
            if (change == WK_COOKIE_SET) {
                if (changedHandler)
                    dispatch_async(changedQueue, ^{ changedHandler(cookies, host); });
            } else if (removedHandler) {
                dispatch_async(removedQueue, ^{ removedHandler(cookies, host, NO); });
            }
        }
    }

    [changedHandler release];
    [changedQueue release];
    [removedHandler release];
    [removedQueue release];
    [hosts release];
}
@end
// ---------------------------------------------------------------------------------------------------
// -comment is REPLACED below, so a reader of the encoded form has to reach the implementation that body
// stands in for. @selector(comment) here is a selref of this library, rewritten to the body's private
// selector like any other.
static NSString *wk_rawCookieComment(NSHTTPCookie *cookie)
{
    struct wk_original original = wk_original_of(cookie, @selector(comment));
    return ((NSString *(*)(id, SEL))original.imp)(cookie, original.sel);
}

// NSHTTPCookieSameSitePolicy and NSHTTPCookieSameSiteLax/Strict are 10.13+/10.15+ in the SDK and absent
// on the 10.9 runtime; c/Foundation.m supplies all three.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"

// The value -sameSitePolicy answers with, which is the constant CookieCocoa's coreSameSitePolicy
// compares against. A cookie keeps the attribute's text as the server wrote it; this is the platform's
// own spelling of it, and nil for a value the modern constants do not name, which coreSameSitePolicy
// reads as unspecified either way.
static NSString *wk_canonicalSameSitePolicy(NSHTTPCookie *cookie)
{
    switch (wk_sameSitePolicyOfComment((CFStringRef)wk_rawCookieComment(cookie))) {
    case WK_SAME_SITE_LAX:
        return NSHTTPCookieSameSiteLax;
    case WK_SAME_SITE_STRICT:
        return NSHTTPCookieSameSiteStrict;
    case WK_SAME_SITE_NONE:
        break;
    }
    return nil;
}

// A property dictionary carries the attribute under NSHTTPCookieSameSitePolicy, which is the literal
// "SameSite" CookieCocoa's createNSHTTPCookie writes and NetworkStorageSessionCocoa's
// setAllCookiesToSameSiteStrict writes through the constant. It is lifted out and encoded into the
// Comment the record does carry, so the caller's own Created still reaches the constructor.
// -properties reports Created as the NSNumber of seconds the record holds, and 10.9's constructors
// answer that spelling with the value 1 rather than with the number or with a fresh timestamp
// (measured; an NSDate is ignored and a fresh one assigned, which is also what an absent key gets).
// A cookie whose creation time reads as 1 sorts ahead of every other cookie of its path, which is the
// order RFC 6265 5.4 composes the Cookie header in. Dropping the key leaves the constructor to stamp
// the record it is making, which is the answer it gives for every spelling it does understand.
// The creation time a caller asks for, as the blob carries it: a decimal string of the CFAbsoluteTime
// the "Created" key names, which is the number -properties reports for a cookie 10.9 stamped itself.
static NSString *wk_createdFieldOfProperties(NSDictionary *properties)
{
    id created = [properties objectForKey:@"Created"];
    if ([created isKindOfClass:[NSNumber class]] || [created isKindOfClass:[NSString class]])
        return [NSString stringWithFormat:@"%.17g", [created doubleValue]];
    return nil;
}

// A cookie's lifetime has a ceiling of 400 days from the moment it is created -- the limit RFC 6265bis
// 4.1.2.1 sets and modern CFNetwork enforces, on a cookie a script sets and on one a response sends
// alike. 10.9 keeps whatever the cookie names, so a page can plant one that outlives the machine. The
// number and the text come from wk_samesite.h, which is where the Set-Cookie field pass takes them from.
//
// A property dictionary can spell the lifetime two ways, and NSHTTPCookieMaximumAge ("Max-Age") decides
// over NSHTTPCookieExpires when it carries both (measured), so it is the one held to the ceiling.
static NSDictionary *wk_propertiesWithCappedExpiry(NSDictionary *properties)
{
    // The key by its value rather than by NSHTTPCookieMaximumAge: 10.9 exports that constant from
    // Foundation and the build SDK's stub library places it in CFNetwork, so a reference to it does not
    // bind here (measured: "Symbol not found: _NSHTTPCookieMaximumAge, expected in CFNetwork").
    id maximumAge = properties[@"Max-Age"];
    if ([maximumAge isKindOfClass:[NSString class]] || [maximumAge isKindOfClass:[NSNumber class]]) {
        if ([maximumAge doubleValue] <= WK_MAXIMUM_COOKIE_LIFETIME_SECONDS)
            return properties;
        NSMutableDictionary *capped = [[properties mutableCopy] autorelease];
        capped[@"Max-Age"] = [NSString stringWithFormat:@"%d", (int)WK_MAXIMUM_COOKIE_LIFETIME_SECONDS];
        return capped;
    }

    id expires = properties[NSHTTPCookieExpires];
    if (![expires isKindOfClass:[NSDate class]])
        return properties;
    NSDate *ceiling = [NSDate dateWithTimeIntervalSinceNow:WK_MAXIMUM_COOKIE_LIFETIME_SECONDS];
    if ([(NSDate *)expires compare:ceiling] != NSOrderedDescending)
        return properties;
    NSMutableDictionary *capped = [[properties mutableCopy] autorelease];
    capped[NSHTTPCookieExpires] = ceiling;
    return capped;
}

static NSDictionary *wk_propertiesWithSameSiteEncoded(NSDictionary *properties)
{
    id policy = properties[NSHTTPCookieSameSitePolicy];
    if (![policy isKindOfClass:[NSString class]])
        policy = nil;
    else if (wk_sameSitePolicyOfValue((CFStringRef)policy) == WK_SAME_SITE_NONE) {
        // A value that restricts nothing is a cookie with no attribute, which is what the key's
        // absence already says.
        policy = nil;
    }
    NSString *created = wk_createdFieldOfProperties(properties);
    if (!policy && !created)
        return properties;

    NSMutableDictionary *translated = [[properties mutableCopy] autorelease];
    [translated removeObjectForKey:NSHTTPCookieSameSitePolicy];
    // 10.9's own record cannot carry a creation time a caller chose: whatever the key names, the cookie
    // comes back reporting 1, and a cookie whose creation time reads as 1 sorts ahead of every other
    // cookie of its path in the order RFC 6265 5.4 composes the Cookie header in. Dropping the key
    // leaves the constructor to stamp the record it is making, and the time the caller asked for rides
    // in the blob with the SameSite attribute, which is what -properties reports back.
    [translated removeObjectForKey:@"Created"];

    id comment = properties[NSHTTPCookieComment];
    CFStringRef encoded = wk_cookieBlobCreate((CFStringRef)policy, (CFStringRef)created,
        [comment isKindOfClass:[NSString class]] ? (CFStringRef)comment : NULL);
    // Text with no encoding -- a lone surrogate, which a script can put in a comment -- leaves the
    // cookie as the caller wrote it, carrying what 10.9 carries for every cookie.
    if (encoded)
        translated[NSHTTPCookieComment] = [(NSString *)encoded autorelease];
    return translated;
}
#pragma clang diagnostic pop

WK_POLYFILL_ADD_METHODS(NSHTTPCookieStorage)
- (void)_getCookiesForURL:(NSURL *)url mainDocumentURL:(NSURL *)mainDocumentURL partition:(NSString *)partition policyProperties:(NSDictionary *)policyProperties completionHandler:(void (^)(NSArray<NSHTTPCookie *> *))completionHandler
{
    (void)mainDocumentURL; (void)partition;
    NSArray<NSHTTPCookie *> *cookies = [self cookiesForURL:url];

    // policyProperties carries this read's SameSite context. 10.13+ CFNetwork withholds a Strict or Lax
    // cookie from a cross-site read here; the same rule is applied from what the cookie carries. Which
    // site this read is for is derived from SiteForCookies against the URL being read rather than read
    // off the presence of the stamp, because a stamp travels unchanged across a redirect that changes
    // host.
    id siteForCookies = policyProperties[@"_kCFHTTPCookiePolicyPropertySiteForCookies"];
    if ([siteForCookies isKindOfClass:[NSURL class]] && cookies.count
        && !wk_sameSiteURLsAreSameSite((CFURLRef)siteForCookies, (CFURLRef)url)) {
        // A same-site read lets every cookie ride whatever its policy says (wk_sameSiteAllows), so
        // only a cross-site read pays the per-cookie comment scan.
        bool isTopLevelNavigation = [policyProperties[@"_kCFHTTPCookiePolicyPropertyIsTopLevelNavigation"] boolValue];
        NSMutableArray<NSHTTPCookie *> *allowed = [NSMutableArray arrayWithCapacity:cookies.count];
        for (NSHTTPCookie *cookie in cookies) {
            // A read carries no HTTP method, so a navigation is the only safe-method case there is.
            if (wk_sameSiteAllows(wk_sameSitePolicyOfComment((CFStringRef)wk_rawCookieComment(cookie)),
                                  false, isTopLevelNavigation, isTopLevelNavigation))
                [allowed addObject:cookie];
        }
        cookies = allowed;
    }
    completionHandler(cookies);
}
- (void)_setCookies:(NSArray<NSHTTPCookie *> *)cookies forURL:(NSURL *)url mainDocumentURL:(NSURL *)mainDocumentURL policyProperties:(NSDictionary *)policyProperties
{
    (void)policyProperties;
    // Every script-written cookie reaches the store through here, whether it was parsed from a
    // Set-Cookie string or built by the Cookie Store API, so the domain rules apply here too.
    NSMutableArray<NSHTTPCookie *> *usable = [NSMutableArray arrayWithCapacity:cookies.count];
    for (NSHTTPCookie *cookie in cookies) {
        if (wk_cookieWithUsableDomain(cookie, url))
            [usable addObject:cookie];
    }
    // -setCookies:forURL:mainDocumentURL: holds these to the main document's domain under
    // NSHTTPCookieAcceptPolicyOnlyFromMainDocumentDomain, and answers "same domain" from a 2013 table of
    // top-level domains, so a third party under a label registered since is read as the main document's
    // own. Two hosts sharing only one label share only a top-level domain whatever that table holds.
    if (self.cookieAcceptPolicy == NSHTTPCookieAcceptPolicyOnlyFromMainDocumentDomain && mainDocumentURL
        && wk_hostsShareOnlyATopLevelDomain((__bridge CFURLRef)url, (__bridge CFURLRef)mainDocumentURL)
        && ![[self cookiesForURL:url] count])
        return;
    [self setCookies:usable forURL:url mainDocumentURL:mainDocumentURL];
}
- (NSArray<NSHTTPCookie *> *)_getCookiesForDomain:(NSString *)domain
{
    NSMutableArray<NSHTTPCookie *> *result = [NSMutableArray array];
    for (NSHTTPCookie *cookie in [self cookies]) {
        if (wk_cookieDomainMatchesHost([cookie domain], domain))
            [result addObject:cookie];
    }
    return result;
}
- (void)_setCookiesChangedHandler:(void (^)(NSArray<NSHTTPCookie *> *, NSString *))handler onQueue:(dispatch_queue_t)queue
{
    pthread_mutex_lock(&wk_cookieWatcherLock);
    [wk_cookieWatcherForStorage(self, handler != nil) setChangedHandler:handler queue:queue];
    pthread_mutex_unlock(&wk_cookieWatcherLock);
}
- (void)_setCookiesRemovedHandler:(void (^)(NSArray<NSHTTPCookie *> *, NSString *, BOOL))handler onQueue:(dispatch_queue_t)queue
{
    pthread_mutex_lock(&wk_cookieWatcherLock);
    [wk_cookieWatcherForStorage(self, handler != nil) setRemovedHandler:handler queue:queue];
    pthread_mutex_unlock(&wk_cookieWatcherLock);
}
- (void)_setSubscribedDomainsForCookieChanges:(NSSet<NSString *> *)domains
{
    pthread_mutex_lock(&wk_cookieWatcherLock);
    [wk_cookieWatcherForStorage(self, [domains count] > 0) setSubscribedHosts:domains ?: [NSSet set]];
    pthread_mutex_unlock(&wk_cookieWatcherLock);
}
@end

// -[NSHTTPCookie _storagePartition] is the per-cookie partition key; 10.9 stores everything
// unpartitioned, so nil (the "no partition" value the callers already treat as the default) is honest.
// +[NSHTTPCookie _cookieForSetCookieString:forURL:partition:] parses a single Set-Cookie header field
// into a cookie — -cookiesWithResponseHeaderFields:forURL: is 10.9's parser for exactly that.
// -[NSHTTPCookie sameSitePolicy] (10.13+) reports a cookie's stored SameSite attribute (paired with the
// NSHTTPCookieSameSiteLax/Strict constants polyfilled in c/Foundation.m), which on 10.9 is what the
// cookie carries in its Comment field (wk_samesite.h).
WK_POLYFILL_ADD_METHODS(NSHTTPCookie)
- (NSString *)sameSitePolicy { return wk_canonicalSameSitePolicy(self); }
- (NSString *)_storagePartition { return nil; }
+ (NSHTTPCookie *)_cookieForSetCookieString:(NSString *)setCookieString forURL:(NSURL *)url partition:(NSString *)partition
{
    (void)partition;
    if (!setCookieString.length || !url)
        return nil;
    // RFC 6265bis 5.5: a set-cookie-string carrying a CTL other than HTAB is ignored entirely. The parse
    // below drops the character and keeps the cookie, so the string is judged before it.
    if (wk_stringHasControlCharacter(setCookieString))
        return nil;
    // A script's cookie carries the attribute in the same syntax and loses it the same way. This send is
    // a selref of this library, so it reaches the body below, which is where the attribute goes into the
    // Comment field.
    NSHTTPCookie *cookie = [[NSHTTPCookie cookiesWithResponseHeaderFields:@{ @"Set-Cookie": setCookieString } forURL:url] firstObject];
    return wk_cookieWithUsableDomain(cookie, url);
}
@end

// The Comment a cookie carries the attribute in is the server's field, so no reader is ever handed the
// encoded form: -comment and -properties give back the comment the server sent, and -description prints
// that one. The attribute reaches a caller under its own modern name instead.
WK_POLYFILL_REPLACE_METHODS(NSHTTPCookie)
- (NSString *)comment
{
    NSString *comment = WK_ORIGINAL_METHOD(NSString *, ());
    return [(NSString *)wk_sameSiteCopyServerComment((CFStringRef)comment) autorelease];
}
- (NSDictionary<NSHTTPCookiePropertyKey, id> *)properties
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
    NSDictionary *properties = WK_ORIGINAL_METHOD(NSDictionary *, ());
    id comment = properties[NSHTTPCookieComment];
    if (![comment isKindOfClass:[NSString class]])
        return properties;
    NSString *sameSite = [(NSString *)wk_sameSiteCopyValue((CFStringRef)comment) autorelease];
    NSString *created = [(NSString *)wk_cookieBlobCopyCreated((CFStringRef)comment) autorelease];
    if (!sameSite && !created)
        return properties;

    NSMutableDictionary *decoded = [[properties mutableCopy] autorelease];
    NSString *server = [(NSString *)wk_sameSiteCopyServerComment((CFStringRef)comment) autorelease];
    if (server)
        decoded[NSHTTPCookieComment] = server;
    else
        [decoded removeObjectForKey:NSHTTPCookieComment];
    if (sameSite)
        decoded[NSHTTPCookieSameSitePolicy] = sameSite;
    if (created)
        decoded[@"Created"] = @([created doubleValue]);
    return decoded;
#pragma clang diagnostic pop
}
- (NSString *)description
{
    NSString *description = WK_ORIGINAL_METHOD(NSString *, ());
    NSString *raw = wk_rawCookieComment(self);
    NSString *sameSite = [(NSString *)wk_sameSiteCopyValue((CFStringRef)raw) autorelease];
    if (!sameSite)
        return description;
    NSString *server = [(NSString *)wk_sameSiteCopyServerComment((CFStringRef)raw) autorelease];
    return [description stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@" comment:\"%@\"", raw]
                                                  withString:server ? [NSString stringWithFormat:@" comment:\"%@\"", server] : @""];
}
+ (NSHTTPCookie *)cookieWithProperties:(NSDictionary<NSHTTPCookiePropertyKey, id> *)properties
{
    return WK_ORIGINAL_METHOD(id, (NSDictionary *), wk_propertiesWithSameSiteEncoded(wk_propertiesWithCappedExpiry(properties)));
}
- (instancetype)initWithProperties:(NSDictionary<NSHTTPCookiePropertyKey, id> *)properties
{
    return WK_ORIGINAL_METHOD(id, (NSDictionary *), wk_propertiesWithSameSiteEncoded(wk_propertiesWithCappedExpiry(properties)));
}
// Used directly by WebKit as well as by the cookie jar (SOAuthorizationSession), so the attribute is
// put into the Comment field here too, before the parser this stands in for sees the header.
+ (NSArray<NSHTTPCookie *> *)cookiesWithResponseHeaderFields:(NSDictionary<NSString *, NSString *> *)headerFields forURL:(NSURL *)url
{
    NSString *name = nil;
    for (NSString *field in headerFields) {
        if ([field caseInsensitiveCompare:@"Set-Cookie"] == NSOrderedSame) {
            name = field;
            break;
        }
    }
    id header = name ? headerFields[name] : nil;
    if (![header isKindOfClass:[NSString class]] || !url)
        return WK_ORIGINAL_METHOD(NSArray *, (NSDictionary *, NSURL *), headerFields, url);

    // Everything a Set-Cookie field is held to, in the one pass the storage's own hook uses
    // (wk_storableSetCookieFieldCreate, c/wk_samesite.c): the control-character rule, the cookies that
    // may not be set at all, the lifetime ceiling and the SameSite attribute.
    bool setsNothing = false;
    NSString *storable = (NSString *)wk_storableSetCookieFieldCreate((CFStringRef)header, (CFURLRef)url, &setsNothing);
    if (setsNothing)
        return @[];
    if (!storable)
        return WK_ORIGINAL_METHOD(NSArray *, (NSDictionary *, NSURL *), headerFields, url);

    NSMutableDictionary *replaced = [[headerFields mutableCopy] autorelease];
    replaced[name] = [storable autorelease];
    return WK_ORIGINAL_METHOD(NSArray *, (NSDictionary *, NSURL *), replaced, url);
}
@end

// ---------------------------------------------------------------------------------------------------
// -[NSURLConnection _timingData] is a newer CFNetwork/Foundation SPI absent on 10.9 (verified: 10.9's
// NSURLConnection does not respond to it). WebCore's synchronous WebKitLegacy loader reads it in two
// upstream places — copyTimingData() in NetworkLoadMetrics.mm (didReceiveResponse:) and
// connectionDidFinishLoading: — to populate NetworkLoadMetrics (Resource Timing / Inspector network
// timings). Unguarded it throws an unrecognized-selector NSInvalidArgumentException → std::terminate,
// which aborts the whole app; this is what crashes Messages on launch as it loads its iMessage
// transcript over WK1. 10.9's NSURLConnection collects no such timing dictionary, so nil is the honest
// answer: every _kCFNTimingData* key then resolves to nil and the metrics stay empty (best-effort, the
// same result the classic 10.9 loader gave). Polyfilling it keeps both WebCore call sites byte-identical
// to upstream.
WK_POLYFILL_ADD_METHODS(NSURLConnection)
- (NSDictionary *)_timingData { return nil; }
@end

// ---------------------------------------------------------------------------------------------------
// NSURL -_lp_simplifiedDisplayString (LinkPresentation, 10.15+). LinkPresentation is absent on 10.9, so
// createDragImageForLink (DragImageCocoa) would send an unrecognized selector to NSURL. Return the host
// (nearest 10.9 meaning of a "simplified" display URL), falling back to the absolute string.
//
// +URLByResolvingAliasFileAtURL:options:error: (10.10+). A Finder alias file has been a bookmark file
// since 10.6, so resolve it with the bookmark API 10.9 has; the NSURLBookmarkResolutionOptions bits are
// the same ones the modern method takes. Per the modern contract, a URL that is not an alias file
// (NSURLIsAliasFileKey, which also covers symlinks) comes back unchanged, and symlinks — which carry no
// bookmark data — resolve to their destination.
WK_POLYFILL_ADD_METHODS(NSURL)
- (NSString *)_lp_simplifiedDisplayString
{
    NSString *host = [self host];
    return host.length ? host : [self absoluteString];
}
+ (instancetype)URLByResolvingAliasFileAtURL:(NSURL *)url options:(NSURLBookmarkResolutionOptions)options error:(NSError **)error
{
    NSNumber *isAlias = nil;
    [url getResourceValue:&isAlias forKey:NSURLIsAliasFileKey error:NULL];
    if (![isAlias boolValue])
        return (id)url;
    NSError *bookmarkError = nil;
    NSData *bookmarkData = [NSURL bookmarkDataWithContentsOfURL:url error:&bookmarkError];
    if (!bookmarkData) {
        NSNumber *isSymlink = nil;
        if ([url getResourceValue:&isSymlink forKey:NSURLIsSymbolicLinkKey error:NULL] && [isSymlink boolValue])
            return (id)[url URLByResolvingSymlinksInPath];
        if (error)
            *error = bookmarkError;
        return nil;
    }
    BOOL stale = NO;
    return (id)[NSURL URLByResolvingBookmarkData:bookmarkData options:options relativeToURL:nil bookmarkDataIsStale:&stale error:error];
}
@end

WK_POLYFILL_REPLACE_METHODS(NSURL)
// -getResourceValue:forKey:error: exists on 10.9 but does not know the modern NSURLContentTypeKey
// (11.0+, answered with a UTType). REPLACE it for WebKit's callers: that one key is answered from the
// classic NSURLTypeIdentifierKey wrapped in the UTType polyfill class; every other key forwards to
// 10.9's implementation through WK_ORIGINAL_METHOD, so this cannot recurse into itself.
- (BOOL)getResourceValue:(id *)value forKey:(NSURLResourceKey)key error:(NSError **)error
{
// NSURLContentTypeKey and UTType are 11.0+ in the SDK and absent on the 10.9 runtime; c/Foundation.m
// supplies the key and classes/UniformTypeIdentifiers.m supplies the class and +typeWithIdentifier:.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
    if ([key isEqualToString:NSURLContentTypeKey]) {
        NSString *typeIdentifier = nil;
        if (!WK_ORIGINAL_METHOD(BOOL, (id *, NSString *, NSError **), (id *)&typeIdentifier, NSURLTypeIdentifierKey, error))
            return NO;
        if (value)
            *value = typeIdentifier ? [UTType typeWithIdentifier:typeIdentifier] : nil;
        return YES;
    }
#pragma clang diagnostic pop
    return WK_ORIGINAL_METHOD(BOOL, (id *, NSString *, NSError **), value, key, error);
}
// -setResourceValue:forKey:error: exists on 10.9 but does not know NSURLQuarantinePropertiesKey
// (10.10+), the key that writes a file's LaunchServices quarantine dictionary. REPLACE it for WebKit's
// callers: that one key is applied through LSSetItemAttribute/kLSItemQuarantineProperties, which is the
// mechanism the modern key is implemented over -- WKShareSheet.mm's own comment names LSSetItemAttribute
// as the call writing this key ends up making, and notes that it resets the quarantine flags, which is
// why WKShareSheet re-applies them with qtn_file_set_flags immediately afterwards. Every other key
// forwards to 10.9's implementation through WK_ORIGINAL_METHOD, so this cannot recurse into itself.
//
// Letting the unknown key fall through to 10.9 would not be a smaller divergence, it would be a silent
// one: WKShareSheet treats a failed quarantine write as "do not share this file", so an unrouted key
// turns every file share into a no-op.
- (BOOL)setResourceValue:(id)value forKey:(NSURLResourceKey)key error:(NSError **)error
{
// The key is 10.10+ in the SDK and absent on the 10.9 runtime; c/Foundation.m supplies it.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"
    if ([key isEqualToString:NSURLQuarantinePropertiesKey]) {
        if (![self isFileURL]) {
            if (error)
                *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnsupportedSchemeError userInfo:nil];
            return NO;
        }
        // CFURLGetFSRef is the only 10.9 spelling that reaches LSSetItemAttribute, and it resolves the
        // file rather than parsing a path string. It fails when the file does not exist yet, which is
        // the same case the modern key reports as a write error.
        FSRef ref;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if (!CFURLGetFSRef((CFURLRef)self, &ref)) {
            if (error)
                *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileNoSuchFileError userInfo:nil];
            return NO;
        }
        // A nil value CLEARS the quarantine, which LSSetItemAttribute spells as a NULL attribute value.
        OSStatus status = LSSetItemAttribute(&ref, kLSRolesAll, kLSItemQuarantineProperties, (CFTypeRef)value);
#pragma clang diagnostic pop
        if (status != noErr) {
            if (error)
                *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
            return NO;
        }
        return YES;
    }
    return WK_ORIGINAL_METHOD(BOOL, (id, NSString *, NSError **), value, key, error);
}
#pragma clang diagnostic pop
// -[NSURL initWithString:] and +[NSURL URLWithString:] throw NSInvalidArgumentException on a nil string
// on 10.9 (modern Foundation returns nil). REPLACE both for WebKit's callers with the modern contract:
// nil in -> nil out; any non-nil string forwards to 10.9's real implementation through
// WK_ORIGINAL_METHOD (so this cannot recurse into itself). The init consumes its already-alloc'd
// receiver on the nil path to keep the alloc/init ownership contract (this file is MRR).
// +URLWithString: is not an init-family selector, so it just returns nil/the autoreleased URL.
- (instancetype)initWithString:(NSString *)string
{
    if (!string) {
        [self release];
        return nil;
    }
    // The same modern-vs-10.9 contract gap, one case over: modern -initWithString:@"" returns a non-nil
    // URL whose relativeString is empty, and does so for an NSURL SUBCLASS too. 10.9 returns nil for the
    // empty string on a subclass, though it answers correctly for NSURL itself -- measured on this host:
    //   [[NSURL alloc]         initWithString:@""] -> object
    //   [[NSURLSubclass alloc] initWithString:@""] -> nil
    //   [[NSURLSubclass alloc] initWithString:@"" relativeToURL:[NSURL URLWithString:@""]]
    //                                              -> object, relativeString "", subclass preserved
    // so the relative form is 10.9's way to spell what the modern initializer means, and it is applied
    // only where 10.9 would otherwise hand back nil. Decided BEFORE calling the real initializer, never
    // after: a failed init has already released the receiver, so a second init on it is a use-after-free.
    if (![string length] && ![self isMemberOfClass:[NSURL class]]) {
        // -initWithString:relativeToURL: and +URLWithString: on NSURL itself are ordinary sends: the
        // former is not polyfilled at all, and the latter names an explicit class rather than a
        // receiver whose chain could carry an override, so neither can re-enter this body.
        typedef id (*WKURLInitRelativeFn)(id, SEL, NSString *, NSURL *);
        WKURLInitRelativeFn originalRelative = (WKURLInitRelativeFn)objc_msgSend;
        typedef id (*WKURLWithStringFn)(id, SEL, NSString *);
        WKURLWithStringFn urlWithString = (WKURLWithStringFn)objc_msgSend;
        static SEL urlWithStringSelector, initRelativeSelector;
        if (!urlWithStringSelector) {
            urlWithStringSelector = sel_registerName("URLWithString:");
            initRelativeSelector = sel_registerName("initWithString:relativeToURL:");
        }
        NSURL *emptyBase = urlWithString([NSURL class], urlWithStringSelector, @"");
        return originalRelative(self, initRelativeSelector, string, emptyBase);
    }
    return WK_ORIGINAL_METHOD(id, (NSString *), string);
}
+ (instancetype)URLWithString:(NSString *)string
{
    if (!string)
        return nil;
    return WK_ORIGINAL_METHOD(id, (NSString *), string);
}
@end

// ---------------------------------------------------------------------------------------------------
// -[NSAttributedString _htmlDocumentFragmentString:documentAttributes:subresources:] (returns interchange
// HTML fragment markup + collects WebArchive subresources) is ABSENT on 10.9 (verified on-host:
// instancesRespondToSelector == NO; the older -_documentFromRange:document:documentAttributes:subresources:
// exists but yields a WebKit1 DOMDocumentFragment, not a string). WebContentReaderCocoa's
// createFragmentInternal(NSAttributedString*) needs the STRING form when pasting RTF / attributed-string
// content from a native app (TextEdit, Mail, Notes) that puts NO html on the pasteboard; without it rich
// paste is silently stripped to plain text. Reimplement from the PUBLIC exporter
// -dataFromRange:documentAttributes:error: (present on 10.9): NSHTMLTextDocumentType output honors the
// caller's NSExcludedElementsDocumentAttribute, which already excludes doctype/html/head/body/style/xml, so
// the result is fragment markup rather than a full document. Subresources (embedded images) are not
// collected by the public path — return an empty array; inline text formatting (bold/italic/color/underline/
// lists/links) is preserved, which is the overwhelming majority of native-app rich paste.
WK_POLYFILL_ADD_METHODS(NSAttributedString)
- (NSString *)_htmlDocumentFragmentString:(NSRange)range documentAttributes:(NSDictionary *)dict subresources:(NSArray **)subresources
{
    if (subresources)
        *subresources = @[];
    NSMutableDictionary *docAttributes = [NSMutableDictionary dictionary];
    [docAttributes setObject:NSHTMLTextDocumentType forKey:NSDocumentTypeDocumentAttribute];
    // Carry over only the public exclusion list; drop the private WebResourceHandler/OutputBaseURL/
    // InterchangeNewline/CoalesceTabSpans keys the public exporter does not understand.
    id excluded = [dict objectForKey:NSExcludedElementsDocumentAttribute];
    if (excluded)
        [docAttributes setObject:excluded forKey:NSExcludedElementsDocumentAttribute];
    NSData *data = [self dataFromRange:range documentAttributes:docAttributes error:NULL];
    if (!data)
        return @"";
    return [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
}
@end

// ---------------------------------------------------------------------------------------------------
// -[NSString containsString:] (10.10+) via the classic -rangeOfString:.
WK_POLYFILL_ADD_METHODS(NSString)
- (BOOL)containsString:(NSString *)str { return [self rangeOfString:str].location != NSNotFound; }
@end

// ---------------------------------------------------------------------------------------------------
// +[NSURLSession _disableAppSSO] (10.13) is a side-effect-only SPI with no 10.9 equivalent -- 10.9 has
// no App-SSO -- so it is a faithful no-op.

WK_POLYFILL_ADD_METHODS(NSURLSession)
+ (void)_disableAppSSO { }
@end

// ---------------------------------------------------------------------------------------------------
// -[NSString stringByApplyingTransform:reverse:] (10.11+) via CFStringTransform (10.4+), which accepts
// the same ICU transform IDs (e.g. @"Hans-Hant"). Returns the transformed string, or nil if the
// transform fails — matching the modern method's contract. (Verified CFStringTransform(@"Hans-Hant")
// works on 10.9.)
WK_POLYFILL_ADD_METHODS(NSString)
- (NSString *)stringByApplyingTransform:(NSStringTransform)transform reverse:(BOOL)reverse
{
    NSMutableString *result = [[self mutableCopy] autorelease];
    CFRange range = CFRangeMake(0, result.length);
    if (CFStringTransform((CFMutableStringRef)result, &range, (CFStringRef)transform, reverse))
        return result;
    return nil;
}
@end

// ---------------------------------------------------------------------------------------------------
// -[NSRunLoop performBlock:] (10.13+) via CFRunLoopPerformBlock (10.6+): enqueue the block to run on the
// next iteration of this run loop in the common modes, then wake the loop so it fires promptly. This is
// exactly what the modern method does, and (like it) is safe to call from another thread — WebKit uses it
// from async completion handlers (spell-check results, XPC teardown) to hop back onto a run loop.
WK_POLYFILL_ADD_METHODS(NSRunLoop)
- (void)performBlock:(void (^)(void))block
{
    CFRunLoopRef runLoop = [self getCFRunLoop];
    CFRunLoopPerformBlock(runLoop, kCFRunLoopCommonModes, block);
    CFRunLoopWakeUp(runLoop);
}
@end

// ---------------------------------------------------------------------------------------------------
// -[NSOperationQueue underlyingQueue] (10.10+): the main operation queue is backed by the main dispatch
// queue on 10.9; any other queue has no underlying dispatch queue (nil) — the honest 10.9 answer.
WK_POLYFILL_ADD_METHODS(NSOperationQueue)
- (dispatch_queue_t)underlyingQueue
{
    return self == [NSOperationQueue mainQueue] ? dispatch_get_main_queue() : nil;
}
@end

// ---------------------------------------------------------------------------------------------------
// -[NSHTTPCookieStorage _saveCookies:] (block variant, ~10.13+): 10.9 has the argument-less -_saveCookies,
// which hands the cookies to nsurlstoraged for the on-disk write. Call it, then run the completion (the
// caller's block redispatches to the main run loop itself).
@interface NSHTTPCookieStorage (WKPolyfill10_9SPI)
- (void)_saveCookies;   // 10.9 argument-less private SPI (do not polyfill it: this body calls it)
@end
WK_POLYFILL_ADD_METHODS(NSHTTPCookieStorage)
- (void)_saveCookies:(dispatch_block_t)completionHandler
{
    [self _saveCookies];
    if (completionHandler)
        completionHandler();
}
@end

// ---------------------------------------------------------------------------------------------------
// Secure-coding archiver convenience API (10.11+/10.13+) built on the classic secure-coding primitives
// present since 10.8. EVERY polyfill enforces requiresSecureCoding:YES (or honors the caller's BOOL) — never
// a secure->insecure downgrade. The modern convenience methods return nil + *error on a malformed archive
// rather than raising; the classic primitives RAISE (NSInvalidUnarchiveOperationException etc.). The
// @try/@catch here is therefore REQUIRED to implement the modern non-throwing contract faithfully — it
// converts the classic exception into the nil+error the caller expects (it is not a blanket swallow: the
// callers explicitly branch on nil/error). -[NSKeyedUnarchiver initForReadingWithData:] and
// -[NSKeyedArchiver initForWritingWithMutableData:] are deprecated (hence the -Wdeprecated push above).
static id wk_unarchivedObjectOfClasses(NSSet *classes, NSData *data, NSError **error)
{
    if (error)
        *error = nil;
    NSKeyedUnarchiver *unarchiver = nil;
    id object = nil;
    @try {
        // Modern +unarchivedObjectOfClasses:fromData:error: is NON-throwing (nil + *error). Both the classic
        // initForReadingWithData: (RAISES "incomprehensible archive" on malformed/truncated input) and
        // decodeObjectOfClasses: (raises on a class/format violation) are inside the @try, or an untrusted
        // IPC/on-disk decode would crash instead of failing cleanly.
        unarchiver = [[NSKeyedUnarchiver alloc] initForReadingWithData:data];
        [unarchiver setRequiresSecureCoding:YES];   // secure + class-restricted, matching the modern convenience
        object = [unarchiver decodeObjectOfClasses:classes forKey:NSKeyedArchiveRootObjectKey];
    } @catch (NSException *exception) {
        object = nil;
        if (error)
// NSCoderReadCorruptError is an NSError-code enumerator, so it is a compile-time integer with no
// runtime symbol behind it; there is nothing for 10.9 to be missing.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSCoderReadCorruptError userInfo:@{ NSLocalizedDescriptionKey: [exception reason] ?: @"decode failed" }];
#pragma clang diagnostic pop
    } @finally {
        [unarchiver finishDecoding];   // send-to-nil no-op if the init raised (unarchiver stays nil)
        [unarchiver release];
    }
    return object;
}

WK_POLYFILL_ADD_METHODS(NSKeyedUnarchiver)
- (instancetype)initForReadingFromData:(NSData *)data error:(NSError **)error
{
    if (error)
        *error = nil;
    @try {
        self = [self initForReadingWithData:data];
        [self setRequiresSecureCoding:YES];   // initForReadingFromData:error: defaults to secure — never downgrade
    } @catch (NSException *exception) {
        // Modern initForReadingFromData:error: is NON-throwing (returns nil + *error). The classic
        // initForReadingWithData: RAISES "incomprehensible archive" on malformed/truncated input, so it must
        // be inside the @try or an untrusted-IPC/.webarchive decode would crash instead of failing cleanly.
        // (self was consumed by the throwing initializer; releasing a half-initialized archiver is unsafe, so
        // return nil directly — the rare-error-path leak of the alloc'd shell is preferable to a crash.)
        if (error)
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSCoderReadCorruptError userInfo:@{ NSLocalizedDescriptionKey: [exception reason] ?: @"incomprehensible archive" }];
        return nil;
    }
    return self;
}
- (void)setDecodingFailurePolicy:(NSDecodingFailurePolicy)policy
{
    // 10.9's sole decoding-failure behavior is NSDecodingFailurePolicyRaiseException — exactly what every
    // WebKit caller requests; the decode polyfills @catch that raise. Nothing to configure.
    (void)policy;
}
+ (id)unarchivedObjectOfClasses:(NSSet<Class> *)classes fromData:(NSData *)data error:(NSError **)error
{
    return wk_unarchivedObjectOfClasses(classes, data, error);
}
+ (id)unarchivedObjectOfClass:(Class)cls fromData:(NSData *)data error:(NSError **)error
{
    return wk_unarchivedObjectOfClasses(cls ? [NSSet setWithObject:cls] : nil, data, error);
}
@end

static char kWKKeyedArchiverDataKey;
WK_POLYFILL_ADD_METHODS(NSKeyedArchiver)
// -initRequiringSecureCoding: / -encodedData (10.13+): the classic pairing is an explicit mutable
// data buffer plus finishEncoding. The buffer rides along as an associated object so encodedData can
// answer it; encodedData finishes encoding on first read, exactly the modern property's contract.
- (instancetype)initRequiringSecureCoding:(BOOL)requireSecure
{
    NSMutableData *data = [NSMutableData data];
    self = [self initForWritingWithMutableData:data];
    if (self) {
        [self setRequiresSecureCoding:requireSecure];   // honor the caller's flag; never silently downgrade
        objc_setAssociatedObject(self, &kWKKeyedArchiverDataKey, data, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return self;
}
- (NSData *)encodedData
{
    // -finishEncoding unconditionally: measured on this host, 10.9's is idempotent (three consecutive
    // calls all succeed and leave the archive intact), so there is nothing to guard against and a
    // caller that finished the archive itself is not penalised.
    [self finishEncoding];
    // nil for an archiver built through some other initializer: only the paired init above records a
    // buffer, and that pairing is the modern API's own (initRequiringSecureCoding: -> encodedData).
    // Copied because the modern property vends immutable NSData; handing back the live NSMutableData
    // would let a caller mutate the archive it just asked for.
    NSMutableData *backing = objc_getAssociatedObject(self, &kWKKeyedArchiverDataKey);
    return backing ? [[backing copy] autorelease] : nil;
}
+ (NSData *)archivedDataWithRootObject:(id)root requiringSecureCoding:(BOOL)requireSecure error:(NSError **)error
{
    if (error)
        *error = nil;
    NSMutableData *data = [NSMutableData data];
    NSKeyedArchiver *archiver = [[NSKeyedArchiver alloc] initForWritingWithMutableData:data];
    [archiver setRequiresSecureCoding:requireSecure];   // honor the caller's flag; never silently downgrade
    NSData *result = nil;
    @try {
        [archiver encodeObject:root forKey:NSKeyedArchiveRootObjectKey];
        [archiver finishEncoding];
        result = data;
    } @catch (NSException *exception) {
        result = nil;
        if (error)
            // An NSError-code enumerator: a compile-time integer with no runtime symbol.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSCoderInvalidValueError userInfo:@{ NSLocalizedDescriptionKey: [exception reason] ?: @"archive failed" }];
#pragma clang diagnostic pop
    }
    [archiver release];
    return result;
}
@end
// +unarchiveTopLevelObjectWithData:error: (10.11+) is the NON-SECURE, NON-throwing top-level decode:
// any NSCoding graph, no class list, nil + *error instead of a raise. 10.9 has only the raising
// +unarchiveObjectWithData:, so the raise is converted here into the modern contract, exactly as the
// secure siblings above do. Kept distinct from unarchivedObjectOfClasses:fromData:error: because the
// contracts differ: this one does NOT require secure coding and does not restrict the class set, which
// is what a caller decoding an arbitrary embedder-supplied object needs.
WK_POLYFILL_ADD_METHODS(NSKeyedUnarchiver)
+ (id)unarchiveTopLevelObjectWithData:(NSData *)data error:(NSError **)error
{
    if (error)
        *error = nil;
    if (!data) {
        if (error)
            // An NSError-code enumerator: a compile-time integer with no runtime symbol.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSCoderValueNotFoundError userInfo:nil];
#pragma clang diagnostic pop
        return nil;
    }
    typedef id (*WKUnarchiveFn)(id, SEL, NSData *);
    WKUnarchiveFn original = (WKUnarchiveFn)objc_msgSend;
    @try {
        return original(self, sel_registerName("unarchiveObjectWithData:"), data);
    } @catch (NSException *exception) {
        if (error)
            // An NSError-code enumerator: a compile-time integer with no runtime symbol.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSCoderReadCorruptError userInfo:@{ NSLocalizedDescriptionKey: [exception reason] ?: @"unarchive failed" }];
#pragma clang diagnostic pop
        return nil;
    }
}
@end

// ---------------------------------------------------------------------------------------------------
// -[NSHTTPURLResponse valueForHTTPHeaderField:] (10.13+): 10.9 lacks it, but -allHeaderFields is present;
// look the field up there case-insensitively (HTTP header names are case-insensitive), matching the modern
// method's contract.
WK_POLYFILL_ADD_METHODS(NSHTTPURLResponse)
- (NSString *)valueForHTTPHeaderField:(NSString *)field
{
    NSDictionary *headers = [self allHeaderFields];
    NSString *direct = [headers objectForKey:field];
    if (direct)
        return direct;
    for (NSString *key in headers)
        if ([key isKindOfClass:[NSString class]] && [key caseInsensitiveCompare:field] == NSOrderedSame)
            return [headers objectForKey:key];
    return nil;
}
@end

// ---------------------------------------------------------------------------------------------------
// -[NSLocale languageCode]/scriptCode/countryCode (10.12+) via the classic component keys (10.4+).
// (Do not polyfill "objectForKey:": these bodies call it.)
WK_POLYFILL_ADD_METHODS(NSLocale)
- (NSString *)languageCode { return [self objectForKey:NSLocaleLanguageCode]; }
- (NSString *)scriptCode   { return [self objectForKey:NSLocaleScriptCode]; }
- (NSString *)countryCode  { return [self objectForKey:NSLocaleCountryCode]; }
@end

// ---------------------------------------------------------------------------------------------------
// +[NSURLProtocol _protocolClassForRequest:skipAppSSO:] (10.10+ SPI). WebCoreNSURLExtras sends it
// unconditionally to decide whether a request is claimed by a registered NSURLProtocol before it takes
// the App SSO path; on 10.9 the selector does not exist and the send throws. App SSO (the Kerberos/AAA
// extension point the flag names) does not exist on 10.9 at all, so no protocol class can be the App SSO
// one: Nil is the whole answer, and WebCoreNSURLExtras falls back to the standard URL-loading path.
//
// Named directly: NSURLProtocol is a class this build's SDK and the 10.9 runtime agree on (both home
// _OBJC_CLASS_$_NSURLProtocol in Foundation — checked in MacOSX26.1.sdk's Foundation.tbd and in
// 10.9.5's Foundation export table), so there is no moved-framework classref to avoid.
WK_POLYFILL_ADD_METHODS(NSURLProtocol)
+ (Class)_protocolClassForRequest:(NSURLRequest *)request skipAppSSO:(BOOL)skipAppSSO
{
    (void)request;
    (void)skipAppSSO;
    return Nil;
}
@end

// ---------------------------------------------------------------------------------------------------
// -[NSURLSessionDownloadTask cancelByProducingResumeData:] — 10.9's implementation ABORTS the process
// when the download cannot produce resume information (github #94: cancelling any such download killed
// the NetworkProcess, and with it Safari).
//
// What 10.9 does, read off CFNetwork 673.3: -[__NSCFLocalDownloadTask _private_fileCompletion] asks
// -createResumeInformation: for the resume dictionary and stuffs the result into the cancellation
// error's userInfo under NSURLSessionDownloadTaskResumeData — with no nil check.
// createResumeInformation: returns nil whenever resuming is impossible, and for a plain HTTP download
// that is the ordinary case: it requires an http/https GET whose response carries an ETag or a
// Last-Modified (a validator, without which no server can be asked to continue), or, for a non-HTTP
// response, a task that was itself created from resume data (_originalResumeInfo). nil then reaches
// -[NSMutableDictionary setObject:forKey:] -> NSInvalidArgumentException -> abort(). Later OS versions
// fixed this by reporting no resume data; this restores that behaviour by not entering the broken path:
// when 10.9 cannot produce resume information, cancel plainly and report no resume data, which is
// exactly what the API's callers already handle (WebKit's Download::platformCancelNetworkLoad passes an
// empty span on). When it CAN, 10.9's own implementation runs, so resuming a download still works.
//
// The gate replicates createResumeInformation:'s preconditions rather than calling it, because calling
// it is not side-effect-free on the path that succeeds (it captures the partial file and sets
// skipUnlink, which the real cancel would then redo). Note allHeaderFields is a CASE-INSENSITIVE
// dictionary on 10.9 (verified: a server's "ETag:" is listed as "Etag" and both spellings look it up),
// so these lookups see the same headers CFNetwork's own do.
static BOOL wk_downloadTaskCanProduceResumeInformation(id task)
{
    NSURLRequest *request = [task currentRequest];
    NSString *scheme = [[request URL] scheme];
    BOOL isHTTPFamily = [scheme caseInsensitiveCompare:@"http"] == NSOrderedSame || [scheme caseInsensitiveCompare:@"https"] == NSOrderedSame;
    if (!isHTTPFamily)
        return NO;
    // A nil HTTPMethod compares equal here, matching CFNetwork's own nil-receiver comparison.
    NSString *method = [request HTTPMethod];
    if (method && [method caseInsensitiveCompare:@"GET"] != NSOrderedSame)
        return NO;

    id response = [task response];
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSDictionary *headers = [(NSHTTPURLResponse *)response allHeaderFields];
        return [headers objectForKey:@"Etag"] != nil || [headers objectForKey:@"Last-Modified"] != nil;
    }

    // Non-HTTP response: 10.9 can only re-emit the resume information the task was created from.
    Ivar originalResumeInfo = class_getInstanceVariable(object_getClass(task), "_originalResumeInfo");
    return originalResumeInfo && object_getIvar(task, originalResumeInfo) != nil;
}

// Both concrete download-task classes 10.9 vends (a local session and a background/URL session), each
// of which implements the real selector itself — hence REPLACE, so the body wins over the aliased
// real method. The public NSURLSessionDownloadTask does NOT implement it on 10.9 and is not in the
// concrete classes' superclass chain (__NSCFLocalDownloadTask : __NSCFLocalSessionTask :
// __NSCFURLSessionTask : NSObject), so installing it there would reach no instance.
WK_POLYFILL_REPLACE_METHODS_ON(NSObject, "__NSCFLocalDownloadTask", "__NSCFURLSessionDownloadTask")
- (void)cancelByProducingResumeData:(void (^)(NSData *resumeData))completionHandler
{
    if (wk_downloadTaskCanProduceResumeInformation(self)) {
        WK_ORIGINAL_METHOD(void, (void (^)(NSData *)), completionHandler);
        return;
    }

    static SEL cancelSelector;
    if (!cancelSelector)
        cancelSelector = sel_registerName("cancel");
    void (*cancel)(id, SEL) = (void (*)(id, SEL))objc_msgSend;
    cancel(self, cancelSelector);
    if (completionHandler)
        completionHandler(nil);
}
@end

// ---------------------------------------------------------------------------------------------------
// NSURLSession SPI that arrived after 10.9, on NSURLSessionConfiguration, NSMutableURLRequest and
// NSHTTPCookieStorage; the session tasks' own is in the NSURLSessionTask block further down.
//
// Every selector below was probed on this 10.9 host and is absent. They configure behaviour 10.9 has no
// notion of -- App SSO, tracker blocking and enhanced privacy mode, the privacy proxy, W3C timing data,
// source-application attribution, per-task metrics, CNAME cloaking resolution -- so the honest 10.9
// answer to each is "nothing happens", which is exactly what these do: the setters accept and discard,
// and the getters report the absence (nil, NO, 0) that the caller already has to handle. That is correct
// for any caller, not just for WebKit's, which is why it belongs here and not at the call sites.
//
// Not a no-op stub: +[NSURLSession _strictTrustEvaluate:queue:completionHandler:] is implemented for real
// further down this file, because "nothing happens" is not a safe answer for a trust evaluation.

// NSURLSessionConfiguration. Installed on the public class WebKit compiles against and on the concrete
// class 10.9 vends.
WK_POLYFILL_ADD_METHODS_ON(NSObject, "NSURLSessionConfiguration", "__NSCFURLSessionConfiguration")
- (void)set_shouldSkipPreferredClientCertificateLookup:(BOOL)value { (void)value; }
- (void)set_connectionCacheNumPriorityLevels:(NSUInteger)value { (void)value; }
- (void)set_connectionCacheMinimumFastLanePriority:(NSUInteger)value { (void)value; }
- (void)set_connectionCacheNumFastLanes:(NSUInteger)value { (void)value; }
- (void)set_preventsAppSSO:(BOOL)value { (void)value; }
- (void)set_suppressedAutoAddedHTTPHeaders:(id)value { (void)value; }
- (void)set_sourceApplicationAuditTokenData:(id)value { (void)value; }
- (void)set_sourceApplicationBundleIdentifier:(id)value { (void)value; }
- (void)set_sourceApplicationSecondaryIdentifier:(id)value { (void)value; }
- (void)set_preventsSystemHTTPProxyAuthentication:(BOOL)value { (void)value; }
- (void)set_requiresSecureHTTPSProxyConnection:(BOOL)value { (void)value; }
- (void)set_timingDataOptions:(NSUInteger)value { (void)value; }
- (void)set_skipsStackTraceCapture:(BOOL)value { (void)value; }
- (id)_sourceApplicationSecondaryIdentifier { return nil; }
- (BOOL)_allowsHSTSWithUntrustedRootCertificate { return NO; }
- (void)set_allowsHSTSWithUntrustedRootCertificate:(BOOL)value { (void)value; }
// The two storage handles the session configuration can be given. 10.9's configuration has no slot for
// either (probed absent on both the public and the concrete class), and the stub storages themselves keep
// nothing, so accepting and discarding is consistent: no HSTS state and no known alternative services.
- (void)set_hstsStorage:(id)value { (void)value; }
- (id)_hstsStorage { return nil; }
- (void)set_alternativeServicesStorage:(id)value { (void)value; }
- (id)_alternativeServicesStorage { return nil; }
@end

// NSMutableURLRequest.
WK_POLYFILL_ADD_METHODS(NSMutableURLRequest)
- (void)_setUseEnhancedPrivacyMode:(BOOL)value { (void)value; }
- (void)_setBlockTrackers:(BOOL)value { (void)value; }
- (void)_setNeedsNetworkTrackingPrevention:(BOOL)value { (void)value; }
- (BOOL)_needsNetworkTrackingPrevention { return NO; }
- (void)_setPrivacyProxyFailClosedForUnreachableNonMainHosts:(BOOL)value { (void)value; }
- (void)_setProhibitPrivacyProxy:(BOOL)value { (void)value; }
- (void)_setPrivacyProxyStrictFailClosed:(BOOL)value { (void)value; }
- (void)_setPrivacyProxyFailClosedForUnreachableHosts:(BOOL)value { (void)value; }
- (void)_setPrivacyProxyFailClosed:(BOOL)value { (void)value; }
- (void)_setWebSearchContent:(BOOL)value { (void)value; }
- (void)_setAllowPrivateAccessTokensForThirdParty:(BOOL)value { (void)value; }
@end
// The read side of the privacy-proxy flag. NSURLRequest as well as NSMutableURLRequest: the getter is
// read off immutable requests too. NO is the honest answer -- there is no Private Relay on 10.9 to have
// failed closed.
WK_POLYFILL_ADD_METHODS_ON(NSURLRequest, "NSURLRequest", "NSMutableURLRequest")
- (BOOL)_privacyProxyFailClosedForUnreachableNonMainHosts { return NO; }
@end

// NSHTTPCookieStorage.

// -[NSHTTPCookieStorage _overrideSessionCookieAcceptPolicy] (10.10+) marks a cookie storage as
// authoritative over NSURLSessionConfiguration's own policy for every session built on it. 10.9's
// CFNetwork implements that behaviour already -- URLRequest::getCookieStorageAcceptPolicy tests the
// request's "policy explicitly set" flag and otherwise falls back to
// CFHTTPCookieStorageGetCookieAcceptPolicy on the request's storage -- but its session path stamps the
// configuration's policy onto every request first, so the fallback is never reached and the storage's
// policy is ignored. A policy set on the request itself pre-empts that stamp, so the flag is recorded
// here and applied to the request by the task creators further down.
//
// The flag rides on the CFHTTPCookieStorageRef rather than on the NSHTTPCookieStorage that carries it,
// for the same reason the cookie-change watcher above does: NetworkStorageSession::nsCookieStorage()
// wraps the same CF storage in a fresh NSHTTPCookieStorage on every call for a non-default session, so
// the wrapper is not an identity. A CF storage is a real Objective-C object, so it holds the flag as an
// associated object, which the runtime drops when the storage is deallocated.
static const void *const wk_cookieAcceptPolicyOverrideKey = &wk_cookieAcceptPolicyOverrideKey;

static CFHTTPCookieStorageRef wk_cfCookieStorageOf(id storage)
{
    if (!storage)
        return NULL;
    static SEL cookieStorageSelector;
    if (!cookieStorageSelector)
        cookieStorageSelector = sel_registerName("_cookieStorage");
    return ((CFHTTPCookieStorageRef (*)(id, SEL))objc_msgSend)(storage, cookieStorageSelector);
}

static void wk_setCookieStorageOverridesSessionCookieAcceptPolicy(id storage, BOOL overrides)
{
    CFHTTPCookieStorageRef store = wk_cfCookieStorageOf(storage);
    if (!store)
        return;
    objc_setAssociatedObject((id)store, wk_cookieAcceptPolicyOverrideKey, overrides ? @YES : nil,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL wk_cookieStorageOverridesSessionCookieAcceptPolicy(id storage)
{
    CFHTTPCookieStorageRef store = wk_cfCookieStorageOf(storage);
    return store && objc_getAssociatedObject((id)store, wk_cookieAcceptPolicyOverrideKey) != nil;
}

WK_POLYFILL_ADD_METHODS(NSHTTPCookieStorage)
- (void)set_overrideSessionCookieAcceptPolicy:(BOOL)overrides
{
    wk_setCookieStorageOverridesSessionCookieAcceptPolicy(self, overrides);
}
- (BOOL)_overrideSessionCookieAcceptPolicy
{
    return wk_cookieStorageOverridesSessionCookieAcceptPolicy(self);
}
@end

// The accept policy the process's own cookie jar starts with: 10.9 hands its handle over set to
// NSHTTPCookieAcceptPolicyNever, and c/CFNetwork.c's wk_giveTheProcessCookieJarItsDefaultAcceptPolicy
// gives it the one CFNetwork documents, once, before anybody has had it to choose a policy on. This is
// the ObjC half of the two ways WebKit reaches that jar; the C half replaces
// _CFHTTPCookieStorageGetDefault.
WK_POLYFILL_REPLACE_METHODS(NSHTTPCookieStorage)
+ (NSHTTPCookieStorage *)sharedHTTPCookieStorage
{
    NSHTTPCookieStorage *storage = WK_ORIGINAL_METHOD(NSHTTPCookieStorage *, ());
    wk_giveTheProcessCookieJarItsDefaultAcceptPolicy(wk_cfCookieStorageOf(storage));
    return storage;
}
// -setCookieAcceptPolicy: leaves the CF storage as it was, while the getter -- and every other reader --
// takes the policy from the CF storage, so on 10.9 the setter has no effect anybody can observe. The
// rest of the class covers the CF storage directly (-setCookie: and -deleteCookie: call
// CFHTTPCookieStorageSetCookie and CFHTTPCookieStorageDeleteCookie), so writing through is the shape of
// the class.
//
// What 10.9's own implementation does instead is stamp com.apple.WebFoundation's NSHTTPAcceptCookies --
// a setting every CFNetwork client in the user's account reads -- and it does that for ANY receiver,
// including a private in-memory jar (measured: setting Never on a jar from -_initWithIdentifier:private:
// leaves NSHTTPAcceptCookies=never behind). A policy chosen for one storage is not an account-wide
// choice, so the original runs only for the storage that IS the process's own jar.
- (void)setCookieAcceptPolicy:(NSHTTPCookieAcceptPolicy)policy
{
    CFHTTPCookieStorageRef store = wk_cfCookieStorageOf(self);
    if (store == _CFHTTPCookieStorageGetDefault(kCFAllocatorDefault))
        WK_ORIGINAL_METHOD(void, (NSHTTPCookieAcceptPolicy), policy);
    if (store)
        CFHTTPCookieStorageSetCookieAcceptPolicy(store, (CFIndex)policy);
}
@end

// The cookies of |cookies| in the order RFC 6265bis 5.5 sends them, which is a stable sort by path
// length: a cookie 10.9 ordered by name among equal-length paths keeps that place, because the creation
// time the RFC breaks those ties by is whole seconds here. Answers |cookies| itself when it already
// reads that way, which is the common case and costs one scan and no allocation.
static NSArray<NSHTTPCookie *> *wk_cookiesInSendOrder(NSArray<NSHTTPCookie *> *cookies)
{
    NSUInteger count = cookies.count;
    bool ordered = true;
    for (NSUInteger i = 1; i < count && ordered; ++i)
        ordered = !wk_cookiePathSortsFirst((CFStringRef)cookies[i].path, (CFStringRef)cookies[i - 1].path);
    if (ordered)
        return cookies;

    NSMutableArray<NSNumber *> *slots = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; ++i)
        [slots addObject:@(i)];
    // The slot decides every tie, so the sort is stable however the sort itself is implemented.
    [slots sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        NSUInteger first = a.unsignedIntegerValue, second = b.unsignedIntegerValue;
        if (wk_cookiePathSortsFirst((CFStringRef)cookies[first].path, (CFStringRef)cookies[second].path))
            return NSOrderedAscending;
        if (wk_cookiePathSortsFirst((CFStringRef)cookies[second].path, (CFStringRef)cookies[first].path))
            return NSOrderedDescending;
        return first < second ? NSOrderedAscending : NSOrderedDescending;
    }];
    NSMutableArray<NSHTTPCookie *> *sorted = [NSMutableArray arrayWithCapacity:count];
    for (NSNumber *slot in slots)
        [sorted addObject:cookies[slot.unsignedIntegerValue]];
    return sorted;
}

// RFC 6265 5.1.4 holds a cookie to a request-path on a path-segment boundary; 10.9 tests only that the
// cookie-path is a prefix (HTTPCookieStorage::lookupAndCopyCookies is a strlen bound and a strncmp), so
// a cookie whose Path is /cook is answered here for /cookies/anything. This is the read every other
// answer is built from -- _getCookiesForURL: above, NetworkStorageSession::getCookies, and through it
// WKHTTPCookieStore and the extension cookies API.
WK_POLYFILL_REPLACE_METHODS(NSHTTPCookieStorage)
- (NSArray<NSHTTPCookie *> *)cookiesForURL:(NSURL *)url
{
    NSArray<NSHTTPCookie *> *cookies = WK_ORIGINAL_METHOD(NSArray *, (NSURL *), url);
    CFStringRef requestPath = wk_requestPathCreate((CFURLRef)url);
    NSMutableArray<NSHTTPCookie *> *onPath = nil;
    for (NSUInteger i = 0; i < cookies.count; ++i) {
        NSHTTPCookie *cookie = cookies[i];
        if (wk_cookiePathMatchesRequestPath((CFStringRef)cookie.path, requestPath)) {
            [onPath addObject:cookie];
            continue;
        }
        if (!onPath) {
            onPath = [NSMutableArray arrayWithCapacity:cookies.count];
            for (NSUInteger kept = 0; kept < i; ++kept)
                [onPath addObject:cookies[kept]];
        }
    }
    CFRelease(requestPath);
    return wk_cookiesInSendOrder(onPath ?: cookies);
}
@end

// An HttpOnly cookie the store holds is not a public caller's to replace or to delete; the rule, and
// why both this pair and the CF pair carry it, is with wk_publicCallerMayChangeCookie in c/CFNetwork.c.
// These two reach CFNetwork through Foundation's own call, which this archive does not rebind.
WK_POLYFILL_REPLACE_METHODS(NSHTTPCookieStorage)
- (void)setCookie:(NSHTTPCookie *)cookie
{
    if (wk_publicCallerMayChangeCookie(wk_cfCookieStorageOf(self), (CFStringRef)[cookie name],
        (CFStringRef)[cookie domain], (CFStringRef)[cookie path], [cookie isHTTPOnly]))
        WK_ORIGINAL_METHOD(void, (NSHTTPCookie *), cookie);
}
- (void)deleteCookie:(NSHTTPCookie *)cookie
{
    if (wk_publicCallerMayChangeCookie(wk_cfCookieStorageOf(self), (CFStringRef)[cookie name],
        (CFStringRef)[cookie domain], (CFStringRef)[cookie path], [cookie isHTTPOnly]))
        WK_ORIGINAL_METHOD(void, (NSHTTPCookie *), cookie);
}
@end

// -[NSURLRequest HTTPShouldHandleCookies] is public, documented, scheme-agnostic Foundation API, and it
// is how a caller withholds cookies from one request. 10.9 keeps the flag only for an http(s) URL:
// set it on a ws://, wss:// or blob: request and it reads back NO however it was set (measured), so on
// those schemes a caller can neither withhold cookies nor learn that it failed to. For a scheme the
// platform does not keep the flag for, the value is kept in the request's own property store, which
// survives -mutableCopy; the platform's own answer is used unchanged for the schemes it does keep.
static NSString * const wkShouldHandleCookiesKey = @"WKShouldHandleCookies";

// Runs on every request and every redirect in both processes (ResourceRequestCocoa's
// doUpdateResourceRequest reads the flag back each time), so it compares the scheme in place rather
// than allocating a lowercased copy of it.
static BOOL wk_urlKeepsCookieFlagNatively(NSURL *url)
{
    NSString *scheme = [url scheme];
    return [scheme caseInsensitiveCompare:@"http"] == NSOrderedSame
        || [scheme caseInsensitiveCompare:@"https"] == NSOrderedSame;
}

WK_POLYFILL_REPLACE_METHODS(NSURLRequest)
- (BOOL)HTTPShouldHandleCookies
{
    if (wk_urlKeepsCookieFlagNatively([self URL]))
        return WK_ORIGINAL_METHOD(BOOL, ());
    id stored = [NSURLProtocol propertyForKey:wkShouldHandleCookiesKey inRequest:self];
    return stored ? [stored boolValue] : YES;
}
@end

WK_POLYFILL_REPLACE_METHODS(NSMutableURLRequest)
- (void)setHTTPShouldHandleCookies:(BOOL)shouldHandle
{
    WK_ORIGINAL_METHOD(void, (BOOL), shouldHandle);
    if (!wk_urlKeepsCookieFlagNatively([self URL]))
        [NSURLProtocol setProperty:(shouldHandle ? @YES : @NO) forKey:wkShouldHandleCookiesKey inRequest:self];
}
@end


// The request side of the flag above. Read at TASK CREATION, so a policy the embedder changes while the
// session is alive takes effect on the next task -- which is the whole point of the storage being
// authoritative, and is why nothing here is cached on the session.
typedef struct _CFURLRequest *WKCFMutableURLRequestRef;
extern void CFURLRequestSetHTTPCookieStorageAcceptPolicy(WKCFMutableURLRequestRef request, int32_t policy);

static NSURLRequest *wk_requestCarryingStorageCookieAcceptPolicy(id session, NSURLRequest *request)
{
    if (!request || !session)
        return request;
    static SEL configurationSelector;
    if (!configurationSelector)
        configurationSelector = sel_registerName("configuration");
    id configuration = ((id (*)(id, SEL))objc_msgSend)(session, configurationSelector);
    id storage = [configuration HTTPCookieStorage];
    if (!wk_cookieStorageOverridesSessionCookieAcceptPolicy(storage))
        return request;

    NSMutableURLRequest *stamped = [[request mutableCopy] autorelease];
    static SEL cfRequestSelector;
    if (!cfRequestSelector)
        cfRequestSelector = sel_registerName("_CFURLRequest");
    WKCFMutableURLRequestRef cfRequest = (WKCFMutableURLRequestRef)((void *(*)(id, SEL))objc_msgSend)(stamped, cfRequestSelector);
    if (!cfRequest)
        return request;
    CFURLRequestSetHTTPCookieStorageAcceptPolicy(cfRequest, (int32_t)[storage cookieAcceptPolicy]);
    return stamped;
}

// ---------------------------------------------------------------------------------------------------
// +[NSURLSession _strictTrustEvaluate:queue:completionHandler:] (10.10+).
//
// Evaluates a server-trust challenge off the calling thread and reports the result as an OSStatus, so a
// client can decide the challenge itself instead of leaving it to CFNetwork's default handling. 10.9 has
// everything that needs: the challenge carries the SecTrustRef, and SecTrustEvaluate is the same
// evaluation the system performs. So this runs it, rather than answering "cannot evaluate", which for a
// trust decision would be the one wrong answer to give.
//
// `queue:` is the COMPLETION queue, the same convention as SecTrustEvaluateAsyncWithError -- it is not
// where the evaluation runs. That distinction is the whole point of the SPI: callers pass the queue they
// are already on (NetworkSessionCocoa passes the network process's main queue from a delegate callback
// that runs there), so evaluating on it would block the caller for the duration. On 10.9 that duration is
// ~250ms per chain and never cached, so doing it on the caller's queue would serialise every certificate
// check in the process onto one thread -- the defect this SPI is used to avoid.
//
// So the evaluation runs on a private pool and only the completion hops to the caller's queue. The pool is
// bounded because 10.9's Security framework does evaluate chains in parallel, but throughput saturates at
// the core count and degrades past it: 28 evaluations took 7.34s at width 1, 2.41s at 4 (this host's core
// count), 2.63s at 8 and 3.03s at 12. An unbounded queue would also let one page's connections spawn a
// thread each.
//
// noErr means trusted, which is how the caller reads it. kSecTrustResultProceed is an explicit user/admin
// trust decision and kSecTrustResultUnspecified is "valid chain, no explicit decision"; every other
// result (recoverable failure, fatal failure, deny, invalid setup) is not trusted, and errSecNotTrusted
// is what the modern SPI reports for those.
//
// RESULT CACHE. The real _strictTrustEvaluate on 10.10+ is backed by trustd, which answers a repeat
// evaluation of the same certificate from its result cache; that is why modern CFNetwork can afford to
// re-ask the trust question on every connection. 10.9 has no trustd, so without a cache this polyfill
// runs a full CDSA evaluation -- RSA chain verification, keychain issuer lookups, a CRL/ocspd round
// trip, all behind Security's one global CSSM mutex -- once PER CONNECTION. Measured on this host
// (arstechnica.com, one load): 95 of 107 SecTrustEvaluate calls in the network process came from this
// function, ~2 per distinct host, because a page opens several connections to each host and every ad and
// analytics origin (doubleclick, google-analytics, facebook, amazon-adsystem, ...) recurs on nearly
// every page. Under CPU contention those evaluations both starve for cores and convoy on the CSSM mutex,
// which is the same lock CFNetwork's socket thread needs to move bytes -- so page loads stall. Caching
// the result here, exactly as trustd does underneath the real SPI, collapses the per-connection
// redundancy within a page and, because the cache persists, makes the ubiquitous third-party origins a
// hit on every page after the first -- which is the steady-state a trustd-backed browser runs in.
//
// This caches this function's OWN evaluations; it does not interpose SecTrustEvaluate. The key is the
// whole readable question -- leaf certificate DER, every policy's properties (which bind the hostname),
// the custom anchors, the network-fetch flag and the verify date -- all of them evaluation-free reads on
// 10.9. Identical question, identical answer, up to the freshness the TTL bounds. Only a clean verdict
// (Proceed/Unspecified) is stored: a failure re-evaluates at full price every time, so a revoked or
// expired chain is never served from memory, and a good chain that just goes bad is caught on its next
// connection rather than the next page. The TTL (10 minutes) is far tighter than 10.9's real revocation
// freshness, whose CRL cache under /var/db/crls persists for days. On a hit the SecTrustRef is left
// unevaluated; the sole caller (NetworkSessionCocoa) reads only the reported OSStatus, and any later
// consumer that wants the built chain triggers Security's own evaluation lazily at full price.
enum { WK_TRUST_CACHE_SLOTS = 512 };
static const CFAbsoluteTime kWKTrustCacheTTL = 600.0;

struct wk_trust_cache_slot {
    uint8_t key[CC_SHA256_DIGEST_LENGTH];
    CFAbsoluteTime expires;
    bool used;
};
static struct wk_trust_cache_slot wk_trust_cache[WK_TRUST_CACHE_SLOTS];
static pthread_mutex_t wk_trust_cache_lock = PTHREAD_MUTEX_INITIALIZER;

static int wk_trust_policy_key_compare(const void *a, const void *b)
{
    return (int)CFStringCompare(*(CFStringRef *)a, *(CFStringRef *)b, 0);
}

// Fold one CoreFoundation value into the digest by its CONTENT, never by CFCopyDescription: on 10.9
// -[CFString description] is "<CFString 0x7fa1... [0x...]>{contents = ...}", i.e. it embeds the object's
// pointer address, which differs for every freshly-allocated instance -- so a policy's value strings,
// which SecPolicyCopyProperties mints anew per connection, would hash differently each time even though
// the string is identical. (That defect made the cache never hit.) A per-type tag keeps values of
// different types from colliding. An unhandled type returns false, which makes the whole key fail and
// the trust evaluate uncached -- the safe direction.
static bool wk_trust_hash_cf(CC_SHA256_CTX *ctx, CFTypeRef value)
{
    if (!value)
        return false;
    CFTypeID type = CFGetTypeID(value);
    if (type == CFStringGetTypeID()) {
        CFDataRef utf8 = CFStringCreateExternalRepresentation(NULL, (CFStringRef)value, kCFStringEncodingUTF8, '?');
        if (!utf8)
            return false;
        char tag = 'S';
        CFIndex len = CFDataGetLength(utf8);
        CC_SHA256_Update(ctx, &tag, 1);
        CC_SHA256_Update(ctx, &len, sizeof(len));
        CC_SHA256_Update(ctx, CFDataGetBytePtr(utf8), (CC_LONG)len);
        CFRelease(utf8);
        return true;
    }
    if (type == CFBooleanGetTypeID()) {
        char tag = 'B';
        uint8_t v = CFBooleanGetValue((CFBooleanRef)value) ? 1 : 0;
        CC_SHA256_Update(ctx, &tag, 1);
        CC_SHA256_Update(ctx, &v, 1);
        return true;
    }
    if (type == CFNumberGetTypeID()) {
        char tag = 'N';
        double v = 0;
        CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &v);
        CC_SHA256_Update(ctx, &tag, 1);
        CC_SHA256_Update(ctx, &v, sizeof(v));
        return true;
    }
    if (type == CFDataGetTypeID()) {
        char tag = 'D';
        CFIndex len = CFDataGetLength((CFDataRef)value);
        CC_SHA256_Update(ctx, &tag, 1);
        CC_SHA256_Update(ctx, &len, sizeof(len));
        CC_SHA256_Update(ctx, CFDataGetBytePtr((CFDataRef)value), (CC_LONG)len);
        return true;
    }
    return false;
}

// Fold a policy's properties (name/oid/hostname/client flags) into the digest, key order normalised so
// the hash is stable regardless of dictionary iteration order.
static bool wk_trust_hash_policy(CC_SHA256_CTX *ctx, SecPolicyRef policy)
{
    CFDictionaryRef properties = SecPolicyCopyProperties(policy);
    if (!properties)
        return false;
    bool ok = true;
    CFIndex count = CFDictionaryGetCount(properties);
    CC_SHA256_Update(ctx, &count, sizeof(count));
    if (count) {
        const void **keys = (const void **)calloc((size_t)count, sizeof(*keys));
        if (keys) {
            CFDictionaryGetKeysAndValues(properties, keys, NULL);
            qsort(keys, (size_t)count, sizeof(*keys), wk_trust_policy_key_compare);
            for (CFIndex i = 0; ok && i < count; ++i)
                ok = wk_trust_hash_cf(ctx, keys[i])
                    && wk_trust_hash_cf(ctx, CFDictionaryGetValue(properties, keys[i]));
            free(keys);
        } else
            ok = false;
    }
    CFRelease(properties);
    return ok;
}

// Assemble the readable trust question into a SHA-256 key. Returns false (evaluate uncached) if any
// component cannot be read -- the failure mode is always "evaluate for real".
static bool wk_trust_cache_key(SecTrustRef trust, uint8_t out[CC_SHA256_DIGEST_LENGTH])
{
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);

    SecCertificateRef leaf = SecTrustGetCertificateAtIndex(trust, 0);
    if (!leaf)
        return false;
    CFDataRef leafDER = SecCertificateCopyData(leaf);
    if (!leafDER)
        return false;
    CFIndex leafLen = CFDataGetLength(leafDER);
    CC_SHA256_Update(&ctx, &leafLen, sizeof(leafLen));
    CC_SHA256_Update(&ctx, CFDataGetBytePtr(leafDER), (CC_LONG)leafLen);
    CFRelease(leafDER);

    CFArrayRef policies = NULL;
    if (SecTrustCopyPolicies(trust, &policies) != errSecSuccess || !policies)
        return false;
    bool ok = true;
    CFIndex policyCount = CFArrayGetCount(policies);
    CC_SHA256_Update(&ctx, &policyCount, sizeof(policyCount));
    for (CFIndex i = 0; ok && i < policyCount; ++i)
        ok = wk_trust_hash_policy(&ctx, (SecPolicyRef)CFArrayGetValueAtIndex(policies, i));
    CFRelease(policies);
    if (!ok)
        return false;

    CFArrayRef anchors = NULL;
    if (SecTrustCopyCustomAnchorCertificates(trust, &anchors) != errSecSuccess)
        return false;
    CFIndex anchorCount = anchors ? CFArrayGetCount(anchors) : -1; // NULL (system anchors) != empty array
    CC_SHA256_Update(&ctx, &anchorCount, sizeof(anchorCount));
    for (CFIndex i = 0; ok && anchors && i < anchorCount; ++i) {
        CFDataRef anchorDER = SecCertificateCopyData((SecCertificateRef)CFArrayGetValueAtIndex(anchors, i));
        if (anchorDER) {
            CFIndex len = CFDataGetLength(anchorDER);
            CC_SHA256_Update(&ctx, &len, sizeof(len));
            CC_SHA256_Update(&ctx, CFDataGetBytePtr(anchorDER), (CC_LONG)len);
            CFRelease(anchorDER);
        } else
            ok = false;
    }
    if (anchors)
        CFRelease(anchors);
    if (!ok)
        return false;

    Boolean fetchAllowed = false;
    if (SecTrustGetNetworkFetchAllowed(trust, &fetchAllowed) != errSecSuccess)
        return false;
    CC_SHA256_Update(&ctx, &fetchAllowed, sizeof(fetchAllowed));
    CFAbsoluteTime verifyTime = SecTrustGetVerifyTime(trust); // 0 when unset, i.e. "now"
    CC_SHA256_Update(&ctx, &verifyTime, sizeof(verifyTime));

    CC_SHA256_Final(out, &ctx);
    return true;
}

static bool wk_trust_cache_lookup(const uint8_t key[CC_SHA256_DIGEST_LENGTH])
{
    unsigned slot = ((unsigned)key[0] | ((unsigned)key[1] << 8)) % WK_TRUST_CACHE_SLOTS;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    pthread_mutex_lock(&wk_trust_cache_lock);
    struct wk_trust_cache_slot *entry = &wk_trust_cache[slot];
    bool hit = entry->used && entry->expires > now && !memcmp(entry->key, key, CC_SHA256_DIGEST_LENGTH);
    pthread_mutex_unlock(&wk_trust_cache_lock);
    return hit;
}

static void wk_trust_cache_store(const uint8_t key[CC_SHA256_DIGEST_LENGTH])
{
    unsigned slot = ((unsigned)key[0] | ((unsigned)key[1] << 8)) % WK_TRUST_CACHE_SLOTS;
    pthread_mutex_lock(&wk_trust_cache_lock);
    struct wk_trust_cache_slot *entry = &wk_trust_cache[slot];
    memcpy(entry->key, key, CC_SHA256_DIGEST_LENGTH);
    entry->expires = CFAbsoluteTimeGetCurrent() + kWKTrustCacheTTL;
    entry->used = true;
    pthread_mutex_unlock(&wk_trust_cache_lock);
}

static dispatch_queue_t wk_trustEvaluationQueue(void)
{
    static dispatch_queue_t *queues;
    static unsigned queueCount;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        long cores = sysconf(_SC_NPROCESSORS_ONLN);
        if (cores < 2)
            cores = 2;
        else if (cores > 8)
            cores = 8;
        queueCount = (unsigned)cores;
        queues = (dispatch_queue_t *)calloc(queueCount, sizeof(*queues));
        for (unsigned i = 0; i < queueCount; ++i)
            queues[i] = dispatch_queue_create("com.apple.WebKit.polyfill.trust-evaluation", DISPATCH_QUEUE_SERIAL);
    });
    // Callers are not promised to be on one thread, so the rotation counter is atomic.
    static _Atomic(unsigned) next;
    return queues[atomic_fetch_add(&next, 1u) % queueCount];
}

WK_POLYFILL_ADD_METHODS(NSURLSession)
+ (void)_strictTrustEvaluate:(NSURLAuthenticationChallenge *)challenge queue:(dispatch_queue_t)queue completionHandler:(void (^)(NSURLAuthenticationChallenge *, OSStatus))completionHandler
{
    // challenge is captured by the blocks, which retain it; the SecTrustRef is owned by the challenge, so
    // it is retained across the hops explicitly.
    SecTrustRef trust = [[challenge protectionSpace] serverTrust];
    if (trust)
        CFRetain(trust);
    dispatch_queue_t completionQueue = queue ?: dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    dispatch_retain(completionQueue);

    // Build the cache key on the caller's queue: it is only evaluation-free reads plus a hash, orders of
    // magnitude cheaper than the evaluation this can avoid, so it does not meaningfully load that queue.
    // A hit answers without ever touching the bounded evaluation pool -- which matters most under load,
    // when that pool is saturated and a cache hit must not have to wait behind real evaluations for a slot.
    struct { uint8_t bytes[CC_SHA256_DIGEST_LENGTH]; bool valid; } cacheKey;
    cacheKey.valid = trust && wk_trust_cache_key(trust, cacheKey.bytes);
    if (cacheKey.valid && wk_trust_cache_lookup(cacheKey.bytes)) {
        dispatch_async(completionQueue, ^{
            completionHandler(challenge, noErr);
            if (trust)
                CFRelease(trust);
            dispatch_release(completionQueue);
        });
        return;
    }

    dispatch_async(wk_trustEvaluationQueue(), ^{
        OSStatus status = errSecNotTrusted;
        SecTrustResultType trustResult = kSecTrustResultInvalid;
        if (trust && SecTrustEvaluate(trust, &trustResult) == errSecSuccess
            && (trustResult == kSecTrustResultProceed || trustResult == kSecTrustResultUnspecified)) {
            status = noErr;
            if (cacheKey.valid)
                wk_trust_cache_store(cacheKey.bytes); // only clean verdicts are remembered
        }
        dispatch_async(completionQueue, ^{
            completionHandler(challenge, status);
            if (trust)
                CFRelease(trust);
            dispatch_release(completionQueue);
        });
    });
}
@end

// ---------------------------------------------------------------------------------------------------
// -[NSHTTPCookieStorage _initWithIdentifier:private:] (10.13+).
//
// Arities read off the disassembly rather than guessed: _CFURLStorageSessionCreate uses rdi/rsi/rdx
// (three), each Copy*Storage uses rdi/rsi (two). Shared by the cookie and credential initializers below.
// The properties dictionary a storage session is created with. CFNetwork keys privacy off the literal
// _kCFURLStorageSessionIsPrivate value, so build the dictionary the API actually reads -- the same key
// upstream WebCore uses in NetworkStorageSessionCocoa. Resolved through the soft-link path because the
// SDK stub is not a reliable guide to what 10.9's CFNetwork exports.
static CFStringRef wk_storageSessionIsPrivateKey(void)
{
    static CFStringRef key;
    static bool resolved;
    if (!resolved) {
        CFStringRef *slot = (CFStringRef *)dlsym(RTLD_DEFAULT, "_kCFURLStorageSessionIsPrivate");
        key = slot ? *slot : NULL;
        resolved = true;
    }
    return key;
}

// Returns NULL ONLY as "could not build the contract"; callers must treat that as a hard failure, never
// as "create the session without the key". Passing NULL properties selects CFNetwork's PERSISTENT branch,
// so a private:YES request that fell back to NULL would silently get an on-disk, app-identifier-keyed jar
// -- the exact defect this key was added to fix.
static CFDictionaryRef wk_storageSessionProperties(BOOL isPrivate, bool *outFailed)
{
    *outFailed = false;
    CFStringRef key = wk_storageSessionIsPrivateKey();
    if (!key) {
        *outFailed = true;
        return NULL;
    }
    const void *keys[] = { key };
    const void *values[] = { isPrivate ? kCFBooleanTrue : kCFBooleanFalse };
    CFDictionaryRef properties = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!properties)
        *outFailed = true;
    return properties;
}

// -removeCookiesSinceDate: (10.10+) takes every cookie created at or after |date|.
// NetworkStorageSession::deleteAllCookiesModifiedSince asks whether the selector exists and returns
// having done nothing when it does not. A cookie's creation time rides in its properties under
// "Created", as a CFAbsoluteTime.
WK_POLYFILL_ADD_METHODS(NSHTTPCookieStorage)
- (void)removeCookiesSinceDate:(NSDate *)date
{
    NSTimeInterval since = [date timeIntervalSinceReferenceDate];
    for (NSHTTPCookie *cookie in [[[self cookies] copy] autorelease]) {
        if ([[[cookie properties] objectForKey:@"Created"] doubleValue] < since)
            continue;
        [self deleteCookie:cookie];
    }
}
@end

// A null CF storage is how upstream spells "this session uses the process's shared jar" --
// NetworkStorageSession::nsCookieStorage() maps it to +sharedHTTPCookieStorage itself, and modern
// CFNetwork answers this initializer with the default store. 10.9 instead logs "Cannot get default
// cookie store - using a memory store for this process" and substitutes a fresh, EMPTY in-memory store,
// so a caller that deleted cookies from the shared jar and then flushed through the result was flushing
// a store its deletions never touched.
WK_POLYFILL_REPLACE_METHODS(NSHTTPCookieStorage)
- (id)_initWithCFHTTPCookieStorage:(CFHTTPCookieStorageRef)storage
{
    if (storage)
        return WK_ORIGINAL_METHOD(id, (CFHTTPCookieStorageRef), storage);
    [self release];
    return (id)[[NSHTTPCookieStorage sharedHTTPCookieStorage] retain];
}
@end

typedef struct OpaqueCFURLStorageSession *CFURLStorageSessionRef;
typedef struct OpaqueCFURLCredentialStorage *CFURLCredentialStorageRef;
extern CFURLStorageSessionRef _CFURLStorageSessionCreate(CFAllocatorRef, CFStringRef, CFDictionaryRef);
extern CFURLCredentialStorageRef _CFURLStorageSessionCopyCredentialStorage(CFAllocatorRef, CFURLStorageSessionRef);
extern CFHTTPCookieStorageRef _CFURLStorageSessionCopyCookieStorage(CFAllocatorRef, CFURLStorageSessionRef);

// Both parameters mean something and both are honoured, the same way the credential-storage twin below
// honours them -- the identifier names a CFNetwork STORAGE SESSION (not a file), and private selects
// whether that session is backed by the process's persistent state. 10.9 exports the whole pair:
// _CFURLStorageSessionCreate makes a session of its own and _CFURLStorageSessionCopyCookieStorage takes
// that session's cookie storage (both probed present), which is the identical mapping upstream WebKit
// uses for identified sessions in NetworkStorageSessionCocoa. -[NSHTTPCookieStorage
// _initWithCFHTTPCookieStorage:] then wraps the result in the ObjC class.
//
// Doing it this way is what makes the identifier MEAN the same thing here as everywhere else: a component
// that names a store through _CFURLStorageSessionCreate and one that names it through this initializer
// land on the same jar. Ignoring the arguments would be correct only for the private:YES caller WebKit
// happens to have, and inventing a per-identifier file path would create a second, private naming scheme
// that agrees with nothing else in the system.
//
// NetworkTaskCocoa::statelessCookieStorage is the private:YES caller that matters: it needs a storage
// whose cookies are never sent with a redirected request. Without this it fell back to the SHARED storage
// and set NSHTTPCookieAcceptPolicyNever on it -- turning cookie acceptance off process-wide.

WK_POLYFILL_ADD_METHODS(NSHTTPCookieStorage)
- (id)_initWithIdentifier:(NSString *)identifier private:(BOOL)isPrivate
{
    static SEL initWithCFStorageSelector;
    if (!initWithCFStorageSelector)
        initWithCFStorageSelector = sel_registerName("_initWithCFHTTPCookieStorage:");

    // The session properties must carry the REAL key, not merely be non-NULL: CFNetwork's
    // StorageSession::copyCookieStorage tests GetValue(props, _kCFURLStorageSessionIsPrivate) ==
    // kCFBooleanTrue and takes the PERSISTENT branch otherwise, so an empty dictionary yields an
    // on-disk, app-identifier-keyed jar that outlives the process -- the opposite of private, measured
    // surviving across two runs.
    bool propertiesFailed = false;
    CFDictionaryRef privateProperties = wk_storageSessionProperties(isPrivate, &propertiesFailed);
    if (propertiesFailed) {
        // No key means the privacy contract cannot be expressed. Creating the session anyway would hand a
        // private:YES caller a persistent jar and a private:NO caller no guarantee at all, so fail here.
        [self release];
        return nil;
    }
    CFURLStorageSessionRef session = _CFURLStorageSessionCreate(kCFAllocatorDefault, (CFStringRef)identifier, privateProperties);
    if (privateProperties)
        CFRelease(privateProperties);

    CFHTTPCookieStorageRef storage = session ? _CFURLStorageSessionCopyCookieStorage(kCFAllocatorDefault, session) : NULL;
    if (session)
        CFRelease(session);

    // No in-memory substitution: for private:NO that would be a jar that silently never persists, which is
    // a fake value. A failed session is an initializer failure, reported the way the twin below reports it.
    if (!storage) {
        [self release];
        return nil;
    }

    id result = ((id (*)(id, SEL, CFHTTPCookieStorageRef))objc_msgSend)(self, initWithCFStorageSelector, storage);
    // A handle this layer just constructed: nobody has had it to choose a policy on, so it starts where
    // CFNetwork's default is rather than where 10.9 leaves it.
    wk_giveTheProcessCookieJarItsDefaultAcceptPolicy(storage);
    CFRelease(storage);
    return result;
}

// +[NSHTTPCookieStorage _setSharedHTTPCookieStorage:] (10.10+): point the process at a cookie jar of its
// own. 10.9 has no way to replace the process's cookie store, and -- measured on this host -- it does not
// need one, because the storage WebKit passes here is already a HANDLE ON THAT STORE:
//
//   NetworkProcess::setSharedHTTPCookieStorage installs cookieStorageFromIdentifyingData(...), and the
//   identifying data 10.9 produces is an archive naming "com.apple.CFNetwork.defaultStorageSession".
//   Restoring it yields a different CFHTTPCookieStorageRef POINTER but the same store: same cookie count
//   (2148 == 2148), and a cookie set through the restored handle is immediately visible through
//   +sharedHTTPCookieStorage. Two handles, one jar.
//
// So accepting and discarding leaves every consumer -- WebKit's cookie API and the NSURLSession that
// performs the loads -- on that one jar. The rejected alternative was to keep an override that
// +sharedHTTPCookieStorage returned: because the selref rewrite only reaches WebKit-marked images, that
// would have redirected WebKit's reads while CFNetwork's own internal default went untouched, i.e. an
// illusion of a swap that is correct only for callers the rewrite happens to cover. No override is kept
// and +sharedHTTPCookieStorage is left alone, so there is exactly one jar and no way for the two to drift.
+ (void)_setSharedHTTPCookieStorage:(id)storage
{
    (void)storage;
}
@end

// -[NSURLCredentialStorage _initWithIdentifier:private:] (10.13+), the same contract one layer over:
// credentials that belong to this data store alone and are not the process-wide set. Built the same way,
// from primitives 10.9 exports: _CFURLStorageSessionCreate makes a storage session of its own,
// _CFURLStorageSessionCopyCredentialStorage takes that session's credential storage, and
// -[NSURLCredentialStorage _initWithCFURLCredentialStorage:] (probed present) wraps it.
//
// NOT CFURLCredentialStorageCreate, which looks like the obvious call and is the wrong one: read off the
// disassembly it fetches _CFURLStorageSessionGetDefault and copies THAT session's storage, i.e. it hands
// back the shared credentials — the opposite of private. Arities also read off the disassembly rather
// than guessed: _CFURLStorageSessionCreate uses rdi/rsi/rdx (three), the copy uses rdi/rsi (two).

WK_POLYFILL_ADD_METHODS(NSURLCredentialStorage)
- (id)_initWithIdentifier:(NSString *)identifier private:(BOOL)isPrivate
{
    static SEL initWithCFStorageSelector;
    if (!initWithCFStorageSelector)
        initWithCFStorageSelector = sel_registerName("_initWithCFURLCredentialStorage:");

    // private:YES has to mean the caller does not see the process's persistent credentials, and 10.9 can
    // express that: measured on this host, a session created with a non-NULL properties dictionary yields
    // a credential storage reporting ZERO protection spaces, while the same call with NULL properties
    // reports the keychain-backed set the shared storage shows. So the flag selects the properties
    // argument -- it is not decoration, and ignoring it would have made this correct only for the
    // private:NO caller WebKit happens to be.
    // Same real key as the cookie twin above. The credential path happens to read any non-NULL dict as
    // private (it tests == kCFBooleanFalse for persistent), but spelling the contract out is what makes
    // both correct for the same reason instead of by opposite accident.
    bool propertiesFailed = false;
    CFDictionaryRef privateProperties = wk_storageSessionProperties(isPrivate, &propertiesFailed);
    if (propertiesFailed) {
        [self release];
        return nil;
    }
    CFURLStorageSessionRef session = _CFURLStorageSessionCreate(kCFAllocatorDefault, (CFStringRef)identifier, privateProperties);
    if (privateProperties)
        CFRelease(privateProperties);
    CFURLCredentialStorageRef storage = session ? _CFURLStorageSessionCopyCredentialStorage(kCFAllocatorDefault, session) : NULL;
    if (session)
        CFRelease(session);
    if (!storage) {
        // -_initWithCFURLCredentialStorage: TRAPS on NULL (measured: SIGTRAP, exit 133), so a failure to
        // build the storage has to come back as nil -- the ordinary "this initializer failed" answer --
        // rather than as a dead NetworkProcess.
        [self release];
        return nil;
    }
    id result = ((id (*)(id, SEL, CFURLCredentialStorageRef))objc_msgSend)(self, initWithCFStorageSelector, storage);
    CFRelease(storage);
    return result;
}
@end


// ---------------------------------------------------------------------------------------------------
// -[NSURLProtectionSpace _webKitPropertyListData] / -_initWithWebKitPropertyListData: and the
// NSURLCredential pair (Foundation, 15.4+): a protection space or credential as the dictionary WebKit's
// CoreIPCNSURLProtectionSpace / CoreIPCNSURLCredential read and write, field by field, with a
// SecTrustRef travelling as itself. The keys and values are the ones those coders name -- "host",
// "port", "type", "realm", "scheme", "trust", "distnames"; "persistence", "type", "user", "password",
// "trust" -- with "type" and "scheme" as CFNetwork numbers its server types and authentication
// schemes, "persistence" as kCFURLCredentialPersistence*, and a credential's "type" as its
// kURLCredential* kind.
//
// Built from what 10.9 exports: the CF space behind an NSURLProtectionSpace (-_cfurlprtotectionspace,
// sic) and its getters, wk_createProtectionSpace and -_initWithCFURLProtectionSpace: for the way
// back; the public NSURLCredential constructors and getters, with the kind and the server trust read
// by wk_credentialKind / wk_credentialServerTrust. A client-certificate credential crosses as its
// kind alone, the way the coder writes it, and 10.9 can make no credential of that kind without an
// identity (measured: CFURLCredentialCreateWithIdentityAndCertificateArray answers NULL), so the
// initializer answers nil for one.
typedef const struct _CFURLProtectionSpace *WKURLProtectionSpaceRef;
extern CFStringRef CFURLProtectionSpaceGetHost(WKURLProtectionSpaceRef);
extern int CFURLProtectionSpaceGetPort(WKURLProtectionSpaceRef);
extern int CFURLProtectionSpaceGetServerType(WKURLProtectionSpaceRef);
extern CFStringRef CFURLProtectionSpaceGetRealm(WKURLProtectionSpaceRef);
extern int CFURLProtectionSpaceGetAuthenticationScheme(WKURLProtectionSpaceRef);

enum {
    kWKCredentialKindInternetPassword = 0,
    kWKCredentialKindServerTrust = 1,
};

static id wk_valueOfClass(NSDictionary *dictionary, NSString *key, Class cls)
{
    id value = [dictionary objectForKey:key];
    return [value isKindOfClass:cls] ? value : nil;
}

WK_POLYFILL_ADD_METHODS(NSURLProtectionSpace)
- (NSDictionary *)_webKitPropertyListData
{
    static SEL cfSpaceSelector;
    if (!cfSpaceSelector)
        cfSpaceSelector = sel_registerName("_cfurlprtotectionspace");
    WKURLProtectionSpaceRef space = ((WKURLProtectionSpaceRef (*)(id, SEL))objc_msgSend)(self, cfSpaceSelector);
    if (!space)
        return nil;
    NSMutableDictionary *dictionary = [NSMutableDictionary dictionaryWithCapacity:7];
    CFStringRef host = CFURLProtectionSpaceGetHost(space);
    if (host)
        [dictionary setObject:(NSString *)host forKey:@"host"];
    [dictionary setObject:[NSNumber numberWithInt:CFURLProtectionSpaceGetPort(space)] forKey:@"port"];
    [dictionary setObject:[NSNumber numberWithInt:CFURLProtectionSpaceGetServerType(space)] forKey:@"type"];
    CFStringRef realm = CFURLProtectionSpaceGetRealm(space);
    if (realm)
        [dictionary setObject:(NSString *)realm forKey:@"realm"];
    [dictionary setObject:[NSNumber numberWithInt:CFURLProtectionSpaceGetAuthenticationScheme(space)] forKey:@"scheme"];
    SecTrustRef trust = self.serverTrust;
    if (trust)
        [dictionary setObject:(id)trust forKey:@"trust"];
    NSArray *distinguishedNames = self.distinguishedNames;
    if (distinguishedNames)
        [dictionary setObject:distinguishedNames forKey:@"distnames"];
    return dictionary;
}

- (instancetype)_initWithWebKitPropertyListData:(NSDictionary *)dictionary
{
    static SEL initWithCFSpaceSelector;
    if (!initWithCFSpaceSelector)
        initWithCFSpaceSelector = sel_registerName("_initWithCFURLProtectionSpace:");
    NSString *host = wk_valueOfClass(dictionary, @"host", [NSString class]);
    NSNumber *port = wk_valueOfClass(dictionary, @"port", [NSNumber class]);
    NSNumber *type = wk_valueOfClass(dictionary, @"type", [NSNumber class]);
    NSString *realm = wk_valueOfClass(dictionary, @"realm", [NSString class]);
    NSNumber *scheme = wk_valueOfClass(dictionary, @"scheme", [NSNumber class]);
    id trust = [dictionary objectForKey:@"trust"];
    if (trust && CFGetTypeID((CFTypeRef)trust) != SecTrustGetTypeID())
        trust = nil;
    NSArray *distinguishedNames = wk_valueOfClass(dictionary, @"distnames", [NSArray class]);
    CFTypeRef space = port && type && scheme
        ? wk_createProtectionSpace((CFStringRef)host, [port intValue], [type intValue], (CFStringRef)realm, [scheme intValue],
            (CFArrayRef)distinguishedNames, (SecTrustRef)trust)
        : NULL;
    if (!space) {
        [self release];
        return nil;
    }
    id result = ((id (*)(id, SEL, CFTypeRef))objc_msgSend)(self, initWithCFSpaceSelector, space);
    CFRelease(space);
    return result;
}
@end

WK_POLYFILL_ADD_METHODS(NSURLCredential)
- (NSDictionary *)_webKitPropertyListData
{
    static SEL cfCredentialSelector;
    if (!cfCredentialSelector)
        cfCredentialSelector = sel_registerName("_cfurlcredential");
    CFTypeRef credential = ((CFTypeRef (*)(id, SEL))objc_msgSend)(self, cfCredentialSelector);
    int kind = wk_credentialKind(credential);
    if (kind < 0)
        return nil;
    // NSURLCredentialPersistence is kCFURLCredentialPersistence less one.
    NSMutableDictionary *dictionary = [NSMutableDictionary dictionaryWithCapacity:5];
    [dictionary setObject:[NSNumber numberWithInt:(int)self.persistence + 1] forKey:@"persistence"];
    [dictionary setObject:[NSNumber numberWithInt:kind] forKey:@"type"];
    if (kind == kWKCredentialKindInternetPassword) {
        NSString *user = self.user;
        if (user)
            [dictionary setObject:user forKey:@"user"];
        NSString *password = self.hasPassword ? self.password : nil;
        if (password)
            [dictionary setObject:password forKey:@"password"];
    } else if (kind == kWKCredentialKindServerTrust) {
        SecTrustRef trust = wk_credentialServerTrust(credential);
        if (!trust)
            return nil;
        [dictionary setObject:(id)trust forKey:@"trust"];
    }
    return dictionary;
}

- (instancetype)_initWithWebKitPropertyListData:(NSDictionary *)dictionary
{
    NSNumber *persistence = wk_valueOfClass(dictionary, @"persistence", [NSNumber class]);
    NSNumber *type = wk_valueOfClass(dictionary, @"type", [NSNumber class]);
    if (!type || !persistence) {
        [self release];
        return nil;
    }
    NSURLCredentialPersistence nsPersistence = (NSURLCredentialPersistence)([persistence intValue] - 1);
    switch ([type intValue]) {
    case kWKCredentialKindInternetPassword:
        return [self initWithUser:wk_valueOfClass(dictionary, @"user", [NSString class])
            password:wk_valueOfClass(dictionary, @"password", [NSString class]) persistence:nsPersistence];
    case kWKCredentialKindServerTrust: {
        id trust = [dictionary objectForKey:@"trust"];
        if (trust && CFGetTypeID((CFTypeRef)trust) == SecTrustGetTypeID())
            return [self initWithTrust:(SecTrustRef)trust];
        break;
    }
    default:
        break;
    }
    [self release];
    return nil;
}
@end


// ---------------------------------------------------------------------------------------------------
// -[NSURLSessionTask _pathToDownloadTaskFile] / -set_pathToDownloadTaskFile: (github #11 / resume).
//
// This is the property with which CFNetwork streams a download STRAIGHT INTO the file the client
// nominated, instead of into a private temp file it only reveals at completion. WebKit sets it in
// NetworkDataTaskCocoa::setPendingDownloadLocation and Download::resume; 10.9's NSURLSession has no
// such property, so the bytes went to /var/folders/.../CFNetworkDownload_XXXXXX.tmp and only arrived
// at the destination once the download finished.
//
// That is not cosmetic on this port, because Safari 7 requires the partial file to exist WHILE the
// download runs. It nominates <name>.download/<name> inside a bundle directory it creates itself
// (its persisted DownloadEntryPath, e.g. ~/Downloads/bigfile.bin.download/bigfile.bin), and
// -[DownloadProgressEntry resume] takes [[self downloadFile] path], requires -fileExistsAtPath: on
// it, and hands that same path to -[WebDownload _initWithResumeInformation:delegate:path:] so
// CFNetwork can append the rest. With the bytes in CFNetwork's temp file the bundle held nothing but
// Info.plist, so resume was never even offered and "Show in Finder" reported the file had moved.
//
// 10.9 has the pieces to do exactly what the property does, and CFNetwork's own NSURLSession resume
// path (-[__NSCFLocalDownloadTask initWithSession:resumeData:ident:bridge:]) uses them: a download
// task holds its output in a _downloadFile, and __NSCFLocalDownloadFile can be built around a file
// that already exists. -initWithExistingFile:expectedSize: open()s it O_WRONLY|O_APPEND (0x9, mode
// 0666) and does NOT pass O_CREAT, so the file must be created first; expectedSize is only logged.
// -[__NSCFLocalDownloadFile dealloc] unlink()s its path unless skipUnlink is set, which is what keeps
// a temp file invisible and would otherwise delete the client's file, so the replacement sets it.

static NSString *wk_downloadTaskFilePathKey = @"wk_pathToDownloadTaskFile";

// Marks the download files whose path belongs to a CLIENT rather than to CFNetwork, so that replacing one
// never unlinks the file the client is downloading into.
static const void *wk_downloadFileIsClientOwnedKey = &wk_downloadFileIsClientOwnedKey;

// Take a download file out of CFNetwork's ownership: its -dealloc unlinks its own path, which is what keeps
// a temp file invisible and would otherwise DELETE the file the client asked us to write. Measured: without
// this, a resumed download completed at full size and then vanished, unlinked from
// -[__NSCFLocalDownloadFile dealloc] as the last reference went away.
static void wk_claimDownloadFileForClient(id file)
{
    static SEL setSkipUnlinkSelector;
    if (!setSkipUnlinkSelector)
        setSkipUnlinkSelector = sel_registerName("setSkipUnlink:");
    void (*setSkipUnlink)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))objc_msgSend;
    setSkipUnlink(file, setSkipUnlinkSelector, YES);
    objc_setAssociatedObject(file, wk_downloadFileIsClientOwnedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Build a __NSCFLocalDownloadFile that appends to a file the client owns.
//
// -initWithExistingFile:expectedSize: is open(path, 0x9 = O_WRONLY|O_APPEND, 0666) with no O_CREAT, so the
// file has to exist first; it close()s that descriptor again immediately (the writing channel is opened
// lazily by -ioChannel) and stores errno into _error whether or not the open succeeded, so errno is cleared
// beforehand to keep a stale value from reading as a failed destination. expectedSize is only logged.
//
// A destination that cannot be opened is REPORTED, not swallowed, and by CFNetwork's own mechanism: the
// object comes back with _path unset, -ioChannel then makes no channel ("Not creating a write channel
// because we don't have a path already set up"), and -writeBytes:completionQueue:completion: invokes its
// completion with _error, which -[__NSCFLocalDownloadTask checkWrite] turns into -_private_posixError:. So
// binding this object makes the download fail with the real errno instead of quietly diverting the bytes to
// a temp file the client never hears about -- which is what the real property does too.
static id wk_localDownloadFileForPath(NSString *path)
{
    // -initWithExistingFile: cannot create, and the client's directory may not hold the file yet. A failure
    // here needs no handling of its own: the init below opens the same path with the same flags, so it
    // records that errno itself.
    int fd = open([path fileSystemRepresentation], O_WRONLY | O_CREAT | O_APPEND, 0666);
    if (fd >= 0)
        close(fd);

    errno = 0;
    static SEL initWithExistingFileSelector;
    if (!initWithExistingFileSelector)
        initWithExistingFileSelector = sel_registerName("initWithExistingFile:expectedSize:");
    id (*initWithExistingFile)(id, SEL, NSString *, long long) = (id (*)(id, SEL, NSString *, long long))objc_msgSend;
    id file = initWithExistingFile([objc_getClass("__NSCFLocalDownloadFile") alloc], initWithExistingFileSelector, path, 0);

    wk_claimDownloadFileForClient(file);
    return file;
}

// Close a download file's dispatch_io channel and WAIT for the close to complete, so that everything
// CFNetwork wrote through it is on disk and can be read back.
//
// -finishOnQueue:completion: is dispatch_io_close(channel, 0) followed by dispatch_io_barrier, and a barrier
// block runs only once the operations submitted before it have completed -- so the completion firing IS the
// ordering guarantee, and there is nothing left to race. The queue passed in is a concurrent global queue,
// so this cannot deadlock against it.
static void wk_finishDownloadFile(id file)
{
    static SEL finishOnQueueSelector;
    if (!finishOnQueueSelector)
        finishOnQueueSelector = sel_registerName("finishOnQueue:completion:");
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    void (*finishOnQueue)(id, SEL, dispatch_queue_t, void (^)(void)) = (void (*)(id, SEL, dispatch_queue_t, void (^)(void)))objc_msgSend;
    finishOnQueue(file, finishOnQueueSelector, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        dispatch_semaphore_signal(finished);
    });
    dispatch_semaphore_wait(finished, DISPATCH_TIME_FOREVER);
    dispatch_release(finished);
}

// Append everything in `fromPath` to `toPath`. Returns 0, or the errno that stopped it -- every failure has
// one, which is why this reads and writes itself instead of going through -[NSData dataWithContentsOfFile:].
static int wk_appendFileContents(NSString *fromPath, NSString *toPath)
{
    int source = open([fromPath fileSystemRepresentation], O_RDONLY);
    if (source < 0)
        return errno;
    int destination = open([toPath fileSystemRepresentation], O_WRONLY | O_APPEND);
    if (destination < 0) {
        int failure = errno;
        close(source);
        return failure;
    }

    int failure = 0;
    uint8_t buffer[65536];
    for (;;) {
        ssize_t got = read(source, buffer, sizeof(buffer));
        if (!got)
            break;
        if (got < 0) {
            failure = errno;
            break;
        }
        const uint8_t *remaining = buffer;
        size_t left = (size_t)got;
        while (left) {
            ssize_t wrote = write(destination, remaining, left);
            if (wrote <= 0) {
                failure = errno ? errno : EIO;
                break;
            }
            remaining += wrote;
            left -= (size_t)wrote;
        }
        if (failure)
            break;
    }
    close(source);
    close(destination);
    return failure;
}

// Point a download task's output at `path`.
//
// The earliest a client can reach a download task is after its initializer has run, and by then CFNetwork
// has already replayed into its temp file whatever response body arrived while the destination was being
// decided (measured: one 32 KB chunk). Those bytes belong at the START of the client's file.
static void wk_bindDownloadTaskToFile(id task, NSString *path)
{
    if (![path length])
        return; // Setting the property to nil means "no destination override", so there is nothing to bind.

    // Only a download task keeps an output file. A data task that has not been converted yet has none, and
    // the path is re-applied from -URLSession:dataTask:didBecomeDownloadTask: once it has one. The ivar is
    // the discriminator because it exists on exactly the class that owns a download file
    // (__NSCFLocalDownloadTask, which also vends -downloadFile/-setDownloadFile:).
    if (!class_getInstanceVariable(object_getClass(task), "_downloadFile"))
        return;

    static SEL downloadFileSelector, setDownloadFileSelector, pathSelector, setPathSelector, setErrorSelector;
    static SEL originalResumeInfoSelector, initialResumeSizeSelector;
    if (!downloadFileSelector) {
        downloadFileSelector = sel_registerName("downloadFile");
        setDownloadFileSelector = sel_registerName("setDownloadFile:");
        pathSelector = sel_registerName("path");
        setPathSelector = sel_registerName("setPath:");
        setErrorSelector = sel_registerName("setError:");
        originalResumeInfoSelector = sel_registerName("originalResumeInfo");
        initialResumeSizeSelector = sel_registerName("initialResumeSize");
    }
    id (*getObject)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    void (*setObject)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
    id previous = getObject(task, downloadFileSelector);
    if (!previous)
        return; // -setupForNewDownload has not made one yet; it will, and the path is re-applied then.
    // Retained for the whole function: -path hands back the _path ivar itself, with no retain or
    // autorelease (measured), and the branches below reassign that ivar (-setPath:) or release the object
    // holding it (-setDownloadFile:) while still needing the old path to unlink it.
    NSString *previousPath = [getObject(previous, pathSelector) retain];

    // stat() rather than -attributesOfItemAtPath:, which reported a non-empty destination on a path that
    // did not exist yet and sent this down the copy path (observed: link() never called, the file created
    // with O_CREAT by the fallback, and one chunk lost).
    struct stat previousInfo, destinationInfo;
    bool previousExists = [previousPath length] && !stat([previousPath fileSystemRepresentation], &previousInfo);
    bool destinationExists = !stat([path fileSystemRepresentation], &destinationInfo);

    // ALREADY writing into the client's file, so there is nothing to REBIND -- and rebinding would destroy
    // the download, because everything below treats the previous file as CFNetwork's disposable temp file.
    // Download::resume arrives here: -[__NSCFLocalDownloadTask createResumeInformation:] records
    // [[self downloadFile] path] as NSURLSessionResumeInfoLocalPath, which with this property in place IS
    // the client's path, and -initWithSession:resumeData:ident:bridge: hands that path straight back to
    // -initWithExistingFile:expectedSize:. Compared by identity rather than by string, since what must not
    // happen is unlinking the file that holds the partial download.
    //
    // The file still has to be CLAIMED, though: CFNetwork built it, so it would unlink the client's file
    // when it goes away (measured: the resumed download completed at the full size and then vanished).
    if (previousExists && destinationExists && previousInfo.st_dev == destinationInfo.st_dev
        && previousInfo.st_ino == destinationInfo.st_ino) {
        wk_claimDownloadFileForClient(previous);
        [previousPath release];
        return;
    }

    // Fresh download or resumed one? Ask the TASK, which knows: -initWithSession:resumeData:ident:bridge:
    // fills in _initialResumeSize and -setOriginalResumeInfo: before any client can set this property.
    // Inferring it from the destination's size instead would splice an existing file's contents in front of
    // a fresh download that happened to be pointed at a non-empty path.
    bool resuming = getObject(task, originalResumeInfoSelector)
        || ((long long (*)(id, SEL))objc_msgSend)(task, initialResumeSizeSelector) > 0;

    if (!resuming) {
        // A fresh download starts from an empty destination, whatever happened to be sitting there.
        unlink([path fileSystemRepresentation]);
        destinationExists = false;

        // Now the destination can simply become a second NAME for the file CFNetwork is already writing,
        // which is better than copying the replayed chunk across: that copy went through the temp file's
        // dispatch_io channel and is not necessarily on disk when we look, so reading it raced the flush and
        // silently dropped the chunk (measured: identical downloads landed either byte-exact or exactly
        // 32,768 bytes short, the short ones starting at absolute offset 32768, 6 of 10 bad). With a hard
        // link both names refer to the one growing file: the prefix is already there and CFNetwork keeps
        // writing through the channel it owns.
        if (previousExists && !link([previousPath fileSystemRepresentation], [path fileSystemRepresentation])) {
            // Exactly ONE name must survive, or the download would keep a second full-size link alive in
            // /var/folders for good: -createResumeInformation: sets skipUnlink, so after a stop CFNetwork
            // never unlinks its own name again, and deleting the download in the Finder would free nothing.
            // Hand the file over to the client's name instead -- the descriptor already open keeps writing to
            // the same inode, a channel not opened yet opens the client's path, and [downloadFile path] then
            // reports the client's file, which is what the resume information and -fileURL must name.
            setObject(previous, setPathSelector, path);
            wk_claimDownloadFileForClient(previous);
            unlink([previousPath fileSystemRepresentation]);
            [previousPath release];
            return;
        }
        // link() fails with EXDEV when the client's directory is on another volume, which Safari's "Save
        // downloaded files to" setting allows and which then applies to EVERY download there. Fall through
        // and bind a separate file object instead.
    }

    // Binding a replacement means reading the previous file back, so close its channel FIRST and wait for
    // the close: after that, every byte CFNetwork wrote through it is on disk (see wk_finishDownloadFile),
    // so the carry below is ordered after those writes rather than racing them.
    if (previousExists)
        wk_finishDownloadFile(previous);

    id replacement = wk_localDownloadFileForPath(path);

    // Carry over whatever the previous file holds. CFNetwork opens the replacement O_APPEND, which is right
    // in both directions: for a fresh download the replayed chunk lands at offset 0, and for a resume onto a
    // file that is not the one named in the resume data, anything already received lands after the bytes the
    // destination already holds.
    int carryFailure = previousExists ? wk_appendFileContents(previousPath, path) : 0;
    if (carryFailure) {
        // The destination is now missing bytes it must never be missing, so the download has to FAIL rather
        // than run to completion and be reported finished with a hole in it. Put the file into the same
        // state CFNetwork produces for a destination it cannot open -- no path, _error set: -ioChannel makes
        // no channel without a path, -writeBytes:completionQueue:completion: then completes with _error, and
        // -[__NSCFLocalDownloadTask writeAndResume]'s completion turns any non-zero into -posixError: ->
        // cancel_with_error:. The temp file is deliberately left where it is, since it holds the only copy
        // of the bytes that did not make it across.
        setObject(replacement, setPathSelector, nil);
        ((void (*)(id, SEL, int))objc_msgSend)(replacement, setErrorSelector, carryFailure);
    } else if (previousExists && !objc_getAssociatedObject(previous, wk_downloadFileIsClientOwnedKey)) {
        // Remove the temp file now that its contents are safely across: its channel is closed, and -dealloc
        // would unlink it anyway, but the object outlives this call whenever something else still retains
        // it. Never for a file this polyfill bound -- that path belongs to a client. Done before the swap,
        // because the swap releases `previous` and previousPath is its string.
        unlink([previousPath fileSystemRepresentation]);
    }

    // -setDownloadFile: is objc_setProperty, i.e. it retains the new file and releases the one it replaces,
    // so the ivar's reference is handed over correctly without touching it by hand. Then drop the +1 from
    // +alloc, leaving the task as the only owner.
    setObject(task, setDownloadFileSelector, replacement);
    [replacement release];
    [previousPath release];
}

// ---------------------------------------------------------------------------------------------------
// NSURLSessionTask SPI absent on 10.9. NSURLSessionTask is a MOVED-FRAMEWORK class (CFNetwork on the
// 26.1 SDK, Foundation at 10.9 runtime), so the block names it by string. On 10.9 the concrete task
// instances do NOT subclass the public NSURLSessionTask class — their hierarchy is
// __NSCFLocalDataTask : __NSCFLocalSessionTask : __NSCFURLSessionTask : NSObject (CFNetwork) — so the
// methods are installed on __NSCFURLSessionTask, the root of the concrete hierarchy, to reach real
// instances (installing only on NSURLSessionTask leaves them unrecognized -> NetworkProcess crash in the
// NetworkDataTaskCocoa constructor). NSURLSessionTask is named too, for the abstract class itself and for
// any OS variant whose concrete tasks do inherit from it.
static const void *const wk_taskPriorityKey = &wk_taskPriorityKey;
static const void *wk_taskIsPreconnectKey = &wk_taskIsPreconnectKey;

WK_POLYFILL_ADD_METHODS_ON(NSObject, "NSURLSessionTask", "__NSCFURLSessionTask")
// -priority/-setPriority: (10.10+). 10.9's URL loading has no per-task scheduling priority, so the value
// can't affect scheduling; store it in an associated object so the property round-trips for its only
// reader (the Web Inspector task metrics), defaulting to NSURLSessionTaskPriorityDefault (0.5).
- (float)priority
{
    NSNumber *v = objc_getAssociatedObject(self, wk_taskPriorityKey);
    return v ? [v floatValue] : 0.5f;
}
- (void)setPriority:(float)priority
{
    objc_setAssociatedObject(self, wk_taskPriorityKey, @(priority), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
// Per-task metrics and CNAME cloaking resolution, which 10.9 has no notion of: the getters report the
// absence the caller already has to handle.
- (id)_incompleteTaskMetrics { return nil; }
- (id)_resolvedCNAMEChain { return nil; }
// -_adoptEffectiveConfiguration: exists to hand ONE task a configuration that
// differs from its session's; 10.9 decides everything the sole caller changes -- credential storage --
// per CONNECTION SESSION and nowhere else, so no per-task state exists for this to write.
// StoredCredentialsPolicy::DoNotUse tasks therefore get a session without credential storage instead
// (NetworkSessionCocoa::sessionWrapperForTask), which is where 10.9 does honour it, and by the time
// this is called the task is already on that session and there is nothing left for it to do.
- (void)_adoptEffectiveConfiguration:(id)configuration { (void)configuration; }
// -_preconnect records what it is told and nothing more. With
// ENABLE(SERVER_PRECONNECT) off for this port (PlatformEnableCocoa.h) WebKit never creates a preconnect
// task, so there is no transfer to suppress here; the getter exists because NetworkSessionCocoa reads it
// outside any SERVER_PRECONNECT guard, and NO is the true answer on a system that has no preconnect.
- (void)set_preconnect:(BOOL)preconnect
{
    objc_setAssociatedObject(self, wk_taskIsPreconnectKey, preconnect ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (BOOL)_preconnect
{
    return objc_getAssociatedObject(self, wk_taskIsPreconnectKey) != nil;
}
// Bytes as they arrived on the wire. 10.9 counts only the decoded body, which is the same number for a
// response that is not content-encoded and the closest true value for one that is -- far closer than the
// zero an "absent" answer would report into the transfer-size accounting.
- (int64_t)_countOfBytesReceivedEncoded
{
    static SEL countSelector;
    if (!countSelector)
        countSelector = sel_registerName("countOfBytesReceived");
    return ((int64_t (*)(id, SEL))objc_msgSend)(self, countSelector);
}
// Per-task cookie controls (10.13+). 10.9's CFNetwork has no per-task cookie storage and no
// cookie-transform hook, so each of these accepts and discards -- the same thing the real API does on a
// system without the feature behind it. The visible consequence is that tracking prevention cannot swap
// a task onto a stateless jar.
// -_setExplicitCookieStorage: has no polyfill: a 10.9 task cannot be re-pointed at a cookie jar once it
// exists (measured -- see NetworkTaskCocoa::blockCookies, which withholds cookies on the request
// instead), and nothing in this port calls it.
- (void)set_cookieTransformCallback:(id)callback { (void)callback; }
- (id)_cookieTransformCallback { return nil; }
- (void)set_siteForCookies:(id)site { (void)site; }
- (void)set_isTopLevelNavigation:(BOOL)value { (void)value; }
// -_pathToDownloadTaskFile is declared on NSURLSessionTask (CFNetworkSPI.h) and WebKit sets it through
// that type; installed on the shared root of the concrete classes, a data task can carry the path before
// it becomes a download task and a download task can bind it.
- (NSString *)_pathToDownloadTaskFile
{
    return objc_getAssociatedObject(self, (const void *)&wk_downloadTaskFilePathKey);
}
- (void)set_pathToDownloadTaskFile:(NSString *)path
{
    objc_setAssociatedObject(self, (const void *)&wk_downloadTaskFilePathKey, path, OBJC_ASSOCIATION_COPY_NONATOMIC);

    // A data task has no output file to bind; wk_bindDownloadTaskToFile returns without doing anything,
    // and the path is re-applied to the download task it becomes (see the comment on that call in
    // NetworkSessionCocoa's -URLSession:dataTask:didBecomeDownloadTask:).
    wk_bindDownloadTaskToFile(self, path);
}
@end

// ---------------------------------------------------------------------------------------------------
// +[NSLocale matchedLanguagesFromAvailableLanguages:forPreferredLanguages:] (#68) is
// 10.12+. WTF::indexOfBestMatchingLanguageInList (Source/WTF/wtf/cocoa/LanguageCocoa.mm) calls it
// UNCONDITIONALLY to pick the best caption/subtitle-track language, so on 10.9 the absent selector throws
// (unrecognized selector -> SIGILL) the instant any media element's caption menu is built
// (CaptionUserPreferencesMediaAF::sortedTrackListForMenu).
//
// We reproduce the 10.12+ contract faithfully: return the availableLanguages that GENUINELY match a
// preferred language (BCP-47 primary language subtag, canonicalized), in preference order, and an EMPTY
// array when none match. The empty-on-no-match behaviour is load-bearing: callers such as
// CaptionUserPreferencesMediaAF (matchesDefaultLanguage / sortedTrackListForMenu),
// AccessibilitySVGObject and WebExtension test `if (![matched count]) return notFound;` (or negate the
// index) and would otherwise treat a non-matching language as a match. +[NSBundle
// preferredLocalizationsFromArray:forPreferences:] (10.0+) does the same BCP-47 best-match and returns
// entries verbatim from availableLanguages, BUT it falls back to the development region (the first
// available language) when nothing matches, so its result must be filtered down to real language matches.
static NSString *wk_primaryLanguageSubtag(NSString *languageTag)
{
    if (![languageTag isKindOfClass:[NSString class]] || !languageTag.length)
        return nil;
    // Canonicalize (e.g. iw->he, EN-us->en-US) then take the primary subtag before the first "-"/"_".
    NSString *canonical = [NSLocale canonicalLanguageIdentifierFromString:languageTag];
    if (!canonical.length)
        canonical = languageTag;
    NSRange sep = [canonical rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"-_"]];
    NSString *code = (sep.location == NSNotFound) ? canonical : [canonical substringToIndex:sep.location];
    return code.lowercaseString;
}
WK_POLYFILL_ADD_METHODS(NSLocale)
+ (NSArray<NSString *> *)matchedLanguagesFromAvailableLanguages:(NSArray<NSString *> *)availableLanguages forPreferredLanguages:(NSArray<NSString *> *)preferredLanguages
{
    NSArray *ordered = [NSBundle preferredLocalizationsFromArray:availableLanguages forPreferences:preferredLanguages];
    if (!ordered.count)
        return @[];
    NSMutableSet *preferredCodes = [NSMutableSet set];
    for (NSString *preferred in preferredLanguages) {
        NSString *code = wk_primaryLanguageSubtag(preferred);
        if (code)
            [preferredCodes addObject:code];
    }
    // Keep only entries that are (a) genuine members of availableLanguages and (b) whose primary language
    // subtag is actually among the preferred languages. (a) drops the value preferredLocalizationsFromArray:
    // echoes back when availableLanguages is empty (it returns the preferred string itself, which is NOT a
    // member); (b) drops the development-region fallback it adds on a non-empty total no-match. Together they
    // reproduce +matchedLanguagesFromAvailableLanguages:'s empty-on-no-match result and guarantee every
    // returned entry is a member of availableLanguages (WTF::indexOfBestMatchingLanguageInList relies on
    // languageList.find(firstObject) resolving).
    NSMutableArray *matched = [NSMutableArray array];
    for (NSString *available in ordered) {
        NSString *code = wk_primaryLanguageSubtag(available);
        if (code && [preferredCodes containsObject:code] && [availableLanguages containsObject:available])
            [matched addObject:available];
    }
    return matched;
}
@end

// -[NSProgress fileOperationKind]/-fileURL and their setters (10.13+) are thin wrappers over
// userInfo keys 10.9 already defines, so implement them that way. NSProgress itself ships in 10.9;
// only these convenience accessors postdate it. WKDownloadProgress sets both when publishing a
// download's progress to the Finder.
//
// fileURL/setFileURL: are generic names -- WebKit sends them to other classes too. That is handled:
// a class that implements the real method has its own implementation aliased under the private
// selector when its image loads, so only NSProgress reaches this polyfill.
WK_POLYFILL_ADD_METHODS(NSProgress)
- (void)setFileOperationKind:(NSProgressFileOperationKind)kind { [self setUserInfoObject:kind forKey:NSProgressFileOperationKindKey]; }
- (NSProgressFileOperationKind)fileOperationKind { return [[self userInfo] objectForKey:NSProgressFileOperationKindKey]; }
- (void)setFileURL:(NSURL *)url { [self setUserInfoObject:url forKey:NSProgressFileURLKey]; }
- (NSURL *)fileURL { return [[self userInfo] objectForKey:NSProgressFileURLKey]; }
@end

// -[NSKeyedUnarchiver _enableStrictSecureDecodingMode] (10.13+) opts an unarchiver into rejecting the
// looser decodes that older secure coding tolerated. 10.9 has no such mode to enable, so doing nothing
// IS this OS's behaviour -- the decode simply runs under the secure-coding rules 10.9 does implement.
WK_POLYFILL_ADD_METHODS(NSKeyedUnarchiver)
- (void)_enableStrictSecureDecodingMode { }
@end

// ---------------------------------------------------------------------------------------------------
// -[NSURLSession dataTaskWithRequest:] / -uploadTaskWithStreamedRequest: with a STREAM body.
//
// 10.9 CFNetwork sends every NSInputStream-bodied task with Transfer-Encoding: chunked and DISCARDS an
// explicitly-set Content-Length. Measured on the wire against a local server:
//   dataTaskWithRequest:        + stream + "Content-Length: N"  ->  Chunked, no Content-Length
//   uploadTaskWithStreamedRequest: + "Content-Length: N"        ->  Chunked, no Content-Length
//   uploadTaskWithRequest:fromFile:                             ->  Content-Length: N
// Modern CFNetwork honours the header; many endpoints reject a length-less chunked upload, which is
// every <input type=file> upload. The contract being restored is therefore the modern one -- "a request
// whose caller set Content-Length on a stream body goes out with that Content-Length" -- and it is stated
// entirely in NSURLRequest terms, so it is correct for any caller, not only WebKit's. Upstream already
// sets that header on stream bodies (ResourceRequestCocoa: "For streams, provide a Content-Length to
// avoid using chunked encoding"), which is what makes the length known here without any WebCore type.
//
// Spool exactly Content-Length bytes, then hand the file to the one 10.9 body form that carries a length
// and also replays safely across redirects and auth retries. A request WITHOUT a stream body or a
// caller-set length is handed to the real selector untouched. Once the stream has been read there is no
// way back to it, so a short or unreadable stream or a write failure becomes a FAILED LOAD -- a real,
// cancelled task whose error the delegate sees -- never a truncated body and never nil (see below).
@interface WKPolyfillScopeUploadSpoolOwner : NSObject {
@public
    NSString *m_path;
}
@end
@implementation WKPolyfillScopeUploadSpoolOwner
- (void)dealloc
{
    if (m_path)
        [[NSFileManager defaultManager] removeItemAtPath:m_path error:NULL];
    [m_path release];
    [super dealloc];
}
@end

// Draining the caller's stream and then "falling back" to the real selector would hand CFNetwork a
// closed, already-read stream -- a silently truncated body dressed up as a safety net. So *streamWasRead
// separates the two failures: everything up to the spool file existing leaves the stream untouched and
// the request is still the caller's to hand on, and only once the stream has been opened does a failure
// have to become a failed load.
static NSURL *wk_spoolStreamBodyToFile(NSURLRequest *request, NSString **pathOut, BOOL *streamWasRead)
{
    *streamWasRead = NO;
    NSInputStream *stream = [request HTTPBodyStream];
    NSString *lengthHeader = [request valueForHTTPHeaderField:@"Content-Length"];
    if (!stream || ![lengthHeader length])
        return nil;
    long long expected = [lengthHeader longLongValue];
    if (expected <= 0)
        return nil;

    // mkstemp, not pid+pointer: NSURLRequest addresses are recycled, so a name derived from one can
    // collide with a spool an in-flight upload is still streaming from -- truncating that body and, when
    // the first owner deallocs, unlinking the second task's file.
    NSString *templatePath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wk-upload-XXXXXX"];
    char nameTemplate[PATH_MAX];
    if (![templatePath getFileSystemRepresentation:nameTemplate maxLength:sizeof(nameTemplate)])
        return nil;
    int fd = mkstemp(nameTemplate);
    if (fd < 0)
        return nil;
    NSString *path = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:nameTemplate length:strlen(nameTemplate)];

    *streamWasRead = YES;
    [stream open];
    long long written = 0;
    uint8_t buffer[64 * 1024];
    bool ok = true;
    while (written < expected) {
        NSInteger wanted = (NSInteger)MIN((long long)sizeof(buffer), expected - written);
        NSInteger got = [stream read:buffer maxLength:wanted];
        if (got <= 0) {
            ok = false;
            break;
        }
        // write(2) + errno rather than -[NSFileHandle writeData:] and an exception handler: this file
        // already reports IO this way (see wk_appendFileContents), and a short write is a value to check,
        // not a condition to catch.
        ssize_t offset = 0;
        while (offset < got) {
            ssize_t n = write(fd, buffer + offset, (size_t)(got - offset));
            if (n <= 0) {
                if (n < 0 && errno == EINTR)
                    continue;
                ok = false;
                break;
            }
            offset += n;
        }
        if (!ok)
            break;
        written += got;
    }
    [stream close];
    close(fd);

    // Only a byte-exact spool may be substituted: anything else would ship a different body.
    if (!ok || written != expected) {
        unlink(nameTemplate);
        return nil;
    }
    *pathOut = path;
    return [NSURL fileURLWithPath:path];
}

static const void *wkUploadSpoolOwnerKey = &wkUploadSpoolOwnerKey;

// The upload task standing in for a stream-bodied `request`, or nil when the request is to be handed to
// the implementation the body stands in for, untouched, with its stream unread. *spoolFailed reports a
// stream that was consumed with no task to carry it.
static id wk_urlSession_spooledUploadTask(id self, NSURLRequest *request, BOOL *spoolFailed)
{
    *spoolFailed = NO;
    // Nothing to substitute (no stream body, or no caller-set length).
    NSInputStream *bodyStream = [request HTTPBodyStream];
    NSString *lengthHeader = [request valueForHTTPHeaderField:@"Content-Length"];
    if (!bodyStream || ![lengthHeader length] || [lengthHeader longLongValue] <= 0)
        return nil;

    NSString *path = nil;
    BOOL streamWasRead = NO;
    NSURL *fileURL = wk_spoolStreamBodyToFile(request, &path, &streamWasRead);
    if (!fileURL) {
        // A spool that got no further than a temporary file leaves the stream where it found it, so the
        // request is still the caller's, whole, and goes to the implementation this stands in for.
        *spoolFailed = streamWasRead;
        return nil;
    }

    NSMutableURLRequest *uploadRequest = [[request mutableCopy] autorelease];
    [uploadRequest setHTTPBodyStream:nil];
    // Let CFNetwork recompute the length from the file it is about to send.
    [uploadRequest setValue:nil forHTTPHeaderField:@"Content-Length"];

    id task = ((id (*)(id, SEL, id, id))objc_msgSend)(self, sel_registerName("uploadTaskWithRequest:fromFile:"), uploadRequest, fileURL);
    if (!task) {
        // The stream is gone, so this cannot fall back to it either.
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
        *spoolFailed = YES;
        return nil;
    }
    // The spool outlives this call and must die with the task that reads it.
    WKPolyfillScopeUploadSpoolOwner *owner = [[WKPolyfillScopeUploadSpoolOwner alloc] init];
    owner->m_path = [path retain];
    objc_setAssociatedObject(task, wkUploadSpoolOwnerKey, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [owner release];
    return task;
}

// Reading the stream consumed it, so once that has happened there is no way back to the unsubstituted
// request: handing the drained stream to the real selector would upload a truncated body. A failed
// spool therefore has to become a FAILED LOAD, and it has to fail the way any other load fails -- a
// real task carried through the delegate with an error -- so the caller's bookkeeping still works.
// Returning nil instead is not available: NetworkDataTaskCocoa assigns the result unconditionally and
// then keys dataTaskMap on [m_task taskIdentifier], which is 0 for nil and is also the identifier of
// the first real task in a session; the entry is never removed (the destructor requires m_task), so the
// load hangs with no error and the next identifier-0 task in that session trips a RELEASE_ASSERT.
// -cancel is the ordinary way to make a created task end in an error its delegate sees; nothing is
// sent because the task has not been resumed.
static id wk_urlSession_taskFailedBySpool(id task, BOOL spoolFailed)
{
    if (spoolFailed && task)
        ((void (*)(id, SEL))objc_msgSend)(task, sel_registerName("cancel"));
    return task;
}

// The request a URL-taking creator stands for: -[NSURLSession dataTaskWithURL:] builds it from the
// session configuration's cache policy and timeout, so building it from NSURLRequest's own defaults
// would quietly hand every caller a 60-second timeout and the protocol cache policy.
static NSURLRequest *wk_urlSession_requestForURL(id session, NSURL *url)
{
    static SEL configurationSelector;
    if (!configurationSelector)
        configurationSelector = sel_registerName("configuration");
    id configuration = ((id (*)(id, SEL))objc_msgSend)(session, configurationSelector);
    if (!configuration)
        return [NSURLRequest requestWithURL:url];
    return [NSURLRequest requestWithURL:url
                            cachePolicy:[configuration requestCachePolicy]
                        timeoutInterval:[configuration timeoutIntervalForRequest]];
}

// Installed on the public class AND on the concrete one: NSURLSession is a class cluster whose
// __NSCFURLSession is NOT a subclass of NSURLSession (measured: __NSCFURLSession -> NSObject), so a
// method installed only on the public class reaches no instance.
//
// Every request-taking task creator is covered, so the authoritative-storage cookie policy above reaches
// a task however it was made rather than only the way WebKit happens to make one. The URL-taking forms
// are defined as their request-taking sibling over -requestWithURL:, so they build that request, stamp
// it and hand it on. -downloadTaskWithResumeData: takes no request and cannot be stamped: a task resumed
// from data answers to the session configuration's policy, which is the one gap in this coverage.
WK_POLYFILL_REPLACE_METHODS_ON(NSURLSession, "NSURLSession", "__NSCFURLSession")
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
{
    request = wk_requestCarryingStorageCookieAcceptPolicy(self, request);
    BOOL spoolFailed = NO;
    id task = wk_urlSession_spooledUploadTask(self, request, &spoolFailed);
    if (task)
        return task;
    return wk_urlSession_taskFailedBySpool(WK_ORIGINAL_METHOD(id, (NSURLRequest *), request), spoolFailed);
}
- (NSURLSessionUploadTask *)uploadTaskWithStreamedRequest:(NSURLRequest *)request
{
    request = wk_requestCarryingStorageCookieAcceptPolicy(self, request);
    BOOL spoolFailed = NO;
    id task = wk_urlSession_spooledUploadTask(self, request, &spoolFailed);
    if (task)
        return task;
    return wk_urlSession_taskFailedBySpool(WK_ORIGINAL_METHOD(id, (NSURLRequest *), request), spoolFailed);
}
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler
{
    return WK_ORIGINAL_METHOD(id, (NSURLRequest *, id), wk_requestCarryingStorageCookieAcceptPolicy(self, request), completionHandler);
}
- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURL *, NSURLResponse *, NSError *))completionHandler
{
    return WK_ORIGINAL_METHOD(id, (NSURLRequest *, id), wk_requestCarryingStorageCookieAcceptPolicy(self, request), completionHandler);
}
- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request
{
    return WK_ORIGINAL_METHOD(id, (NSURLRequest *), wk_requestCarryingStorageCookieAcceptPolicy(self, request));
}
- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData
{
    return WK_ORIGINAL_METHOD(id, (NSURLRequest *, id), wk_requestCarryingStorageCookieAcceptPolicy(self, request), bodyData);
}
- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromFile:(NSURL *)fileURL
{
    return WK_ORIGINAL_METHOD(id, (NSURLRequest *, id), wk_requestCarryingStorageCookieAcceptPolicy(self, request), fileURL);
}
// A URL-taking creator forwards to the PUBLIC request-taking selector through a runtime-built selector,
// which the selref rewrite does not touch, so it reaches the platform method directly and cannot
// re-enter the request-taking body above; that body is what prepares a request for the session.
- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url
{
    static SEL dataTaskSelector;
    if (!dataTaskSelector)
        dataTaskSelector = sel_registerName("dataTaskWithRequest:");
    return ((id (*)(id, SEL, id))objc_msgSend)(self, dataTaskSelector,
        wk_requestCarryingStorageCookieAcceptPolicy(self, wk_urlSession_requestForURL(self, url)));
}
- (NSURLSessionDownloadTask *)downloadTaskWithURL:(NSURL *)url
{
    static SEL downloadTaskSelector;
    if (!downloadTaskSelector)
        downloadTaskSelector = sel_registerName("downloadTaskWithRequest:");
    return ((id (*)(id, SEL, id))objc_msgSend)(self, downloadTaskSelector,
        wk_requestCarryingStorageCookieAcceptPolicy(self, wk_urlSession_requestForURL(self, url)));
}
@end

// ---------------------------------------------------------------------------------------------------
// -[NSURLRequest _schemeWasUpgradedDueToDynamicHSTS] (10.11+ CFNetwork SPI) reports that CFNetwork's
// dynamic-HSTS store rewrote this request's http:// to https://. 10.9's CFNetwork has no HSTS store and
// never upgrades a scheme, so no request on this OS was ever HSTS-upgraded. Lets
// WebCoreURLResponse.mm's synthesizeRedirectResponseIfNecessary call it unguarded (upstream's other
// call sites carry their own respondsToSelector: guard, which now answers through this body too).
WK_POLYFILL_ADD_METHODS(NSURLRequest)
- (BOOL)_schemeWasUpgradedDueToDynamicHSTS { return NO; }
@end

#pragma clang diagnostic pop

// ---------------------------------------------------------------------------------------------------
// +[NSURL URLWithDataRepresentation:relativeToURL:] (10.11+) builds a URL out of the bytes as written,
// rather than out of a string. CFURLCreateWithBytes is that same construction one layer down, and 10.9
// has it: it parses the bytes in the given encoding against the base URL.
WK_POLYFILL_ADD_METHODS(NSURL)
+ (NSURL *)URLWithDataRepresentation:(NSData *)data relativeToURL:(NSURL *)baseURL
{
    if (!data)
        return nil;
    return CFBridgingRelease(CFURLCreateWithBytes(kCFAllocatorDefault, (const UInt8 *)data.bytes,
        (CFIndex)data.length, kCFStringEncodingUTF8, (__bridge CFURLRef)baseURL));
}
@end
