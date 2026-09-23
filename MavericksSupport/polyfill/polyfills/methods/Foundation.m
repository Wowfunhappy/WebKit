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

#import "wk_declared_types.h"
#import "wk_hosts.h"
#import "wk_cookie_storage.h"
#import "wk_url_coding.h"
#import "wk_polyfill.h"
#import "wk_samesite.h"
#import "wk_selref_scope.h"
#import <AppKit/AppKit.h>
#import <CommonCrypto/CommonDigest.h>
#import <CoreServices/CoreServices.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <dlfcn.h>
#import <pthread.h>
#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <math.h>
#import <string.h>
#import <strings.h>
#import <sys/stat.h>
#import <sys/xattr.h>
#import <mach/mach.h>
#import <Security/Security.h>
#import <objc/message.h>
#import <objc/objc-sync.h>
#import <objc/runtime.h>
#import <libkern/OSAtomic.h>
#import <pthread.h>
#import <stdatomic.h>
#import <unicode/uloc.h>
#import <unistd.h>

// CFNetwork SPI, exported on 10.9 but not declared in any public header.
typedef struct OpaqueCFHTTPCookieStorage *CFHTTPCookieStorageRef;
extern CFHTTPCookieStorageRef _CFHTTPCookieStorageGetDefault(CFAllocatorRef);
extern void CFHTTPCookieStorageSetCookieAcceptPolicy(CFHTTPCookieStorageRef, CFIndex);
extern CFIndex CFHTTPCookieStorageGetCookieAcceptPolicy(CFHTTPCookieStorageRef);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

// NSString's 10.9 address predicate rejects bracketed IPv6, although WTF::URL::host() supplies
// that URL representation. The modern predicate must recognize both bare and bracketed literals.
// The shared parser also serves native cookie domain classification.
WK_POLYFILL_REPLACE_METHODS(NSString)
- (BOOL)_web_looksLikeIPAddress
{
    return wk_hostIsIPAddress((CFStringRef)self);
}
@end

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

// ---------------------------------------------------------------------------------------------------
// Cookie reads apply SameSite policy from the native record's encoded metadata. Partitioning is
// disabled by this build; the policy dictionary supplies the request's site and navigation context.

// The modern native-cookie setter validates domain scope before invoking the 10.9 jar.
// Its native API contract shares WebCore's PSL and literal-address predicates.
static const NSHTTPCookieAcceptPolicy wk_cookieAcceptPolicyExclusivelyFromMainDocumentDomain = (NSHTTPCookieAcceptPolicy)3;

static NSHTTPCookie *wk_cookieWithUsableDomain(NSHTTPCookie *cookie, NSURL *url)
{
    NSString *domain = [cookie domain];
    if (!cookie || !domain.length)
        return cookie;

    // CFNetwork's file-cookie domain is .^filecookies^.
    NSString *host = url.isFileURL ? @"^filecookies^" : [url host];
    if (!host.length)
        return nil;

    // RFC 6265 5.3 canonicalises the domain-attribute by stripping a leading dot before anything else
    // is asked of it, and 10.9 stores one the other way round -- it ADDS the dot, so a cookie that
    // named its own host arrives here as ".myserver" against a host of "myserver". The name a cookie
    // is being held to is therefore the bare one, and the tests below are in the RFC's order.
    NSString *bare = [domain hasPrefix:@"."] ? [domain substringFromIndex:1] : domain;
    if (!bare.length)
        return nil;

    // An exact match permits cookies on a public-suffix host itself.
    if ([bare caseInsensitiveCompare:host] == NSOrderedSame)
        return cookie;

    // An address domain-matches only itself (5.1.3), which the line above already answered, so nothing
    // else a cookie names for one can be right.
    if (wk_hostIsIPAddress((CFStringRef)host))
        return nil;

    if (wk_domainIsPublicSuffix((CFStringRef)bare))
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
// domain attribute domain-matches the host (RFC 6265), asked of the jar one domain at a time.
// _saveCookies: is polyfilled further down, over 10.9's PRESENT argument-less -_saveCookies.
// RFC 6265 5.1.3: a host-only cookie covers the host it names, a domain cookie that host and every
// subdomain of it. Cookie domains are case-insensitive.
// WebCore names a host in URL form, which brackets an IPv6 literal; the jar stores the bare address.
static NSString *wk_jarHostForURLHost(NSString *host)
{
    if (host.length > 2 && [host hasPrefix:@"["] && [host hasSuffix:@"]"] && wk_hostIsIPAddress((CFStringRef)host))
        return [host substringWithRange:NSMakeRange(1, host.length - 2)];
    return host;
}

static BOOL wk_cookieDomainMatchesHost(NSString *cookieDomain, NSString *host)
{
    host = wk_jarHostForURLHost(host);
    if (!cookieDomain.length)
        return NO;
    if (!host.length)
        return [cookieDomain isEqualToString:@".^filecookies^"];

    NSString *bare = [cookieDomain hasPrefix:@"."] ? [cookieDomain substringFromIndex:1] : cookieDomain;
    if (!bare.length)
        return NO;
    if ([host caseInsensitiveCompare:bare] == NSOrderedSame)
        return YES;
    if (![cookieDomain hasPrefix:@"."])
        return NO;
    NSUInteger hostLength = host.length, bareLength = bare.length;
    if (hostLength <= bareLength)
        return NO;
    NSRange suffix = NSMakeRange(hostLength - bareLength, bareLength);
    if ([host compare:bare options:NSCaseInsensitiveSearch range:suffix] != NSOrderedSame)
        return NO;
    return [host characterAtIndex:suffix.location - 1] == '.';
}

// CFNetwork notifies a storage's observers of each change made through its handle, whichever image makes it.
// Each CF handle owns one subscription; separate NS wrappers share handlers, subscribed domains and the
// cookies last seen in those domains.
// CFNetwork's observer context retains the handle through unsubscription.
typedef void (*WKCookieStorageChangedProc)(CFHTTPCookieStorageRef, void *);
extern void CFHTTPCookieStorageAddObserver(CFHTTPCookieStorageRef, CFRunLoopRef, CFStringRef, WKCookieStorageChangedProc, void *);
extern void CFHTTPCookieStorageRemoveObserver(CFHTTPCookieStorageRef, CFRunLoopRef, CFStringRef, WKCookieStorageChangedProc, void *);
static CFHTTPCookieStorageRef wk_cfCookieStorageOf(id);

@interface NSHTTPCookieStorage (WKCookieObservationStorage)
- (instancetype)_initWithCFHTTPCookieStorage:(CFHTTPCookieStorageRef)storage;
- (NSArray<NSHTTPCookie *> *)_getCookiesForDomain:(NSString *)domain;
@end
@interface NSHTTPCookie (WKCookieObservationPartition)
- (NSString *)_storagePartition;
- (NSURL *)OriginURL;
@end

typedef struct OpaqueCFHTTPCookie *CFHTTPCookieRef;
typedef CFArrayRef (*wk_cookieCopyAll)(CFHTTPCookieStorageRef);

@interface NSHTTPCookie (WKCFHTTPCookieBridge)
+ (NSHTTPCookie *)cookieWithCFHTTPCookie:(CFHTTPCookieRef)cookie;
@end

// The cookies stored under any of |cookieDomains|, each Domain field compared as a whole string. The jar is
// read whole: 10.9's per-domain query, CFHTTPCookieStorageCopyCookiesMatching, is not safe while other
// threads use the storage. Resolved with dlsym, not declared extern: the function is in 10.9's CFNetwork but
// not in the 26.1 SDK's stub library, so a link-time reference fails to build even though the call works.
static NSMutableArray<NSHTTPCookie *> *wk_cookiesStoredInDomains(CFHTTPCookieStorageRef storage, NSSet<NSString *> *cookieDomains)
{
    static wk_cookieCopyAll copyAll;
    static bool resolved;
    if (!resolved) {
        copyAll = (wk_cookieCopyAll)dlsym(RTLD_DEFAULT, "CFHTTPCookieStorageCopyCookies");
        resolved = true;
    }
    NSMutableArray<NSHTTPCookie *> *result = [NSMutableArray array];
    if (!storage || !copyAll || !cookieDomains.count)
        return result;
    CFArrayRef stored = copyAll(storage);
    if (!stored)
        return result;
    for (CFIndex i = 0, count = CFArrayGetCount(stored); i < count; ++i) {
        NSHTTPCookie *cookie = [NSHTTPCookie cookieWithCFHTTPCookie:(CFHTTPCookieRef)CFArrayGetValueAtIndex(stored, i)];
        NSString *domain = cookie.domain.lowercaseString;
        if (domain && [cookieDomains containsObject:domain])
            [result addObject:cookie];
    }
    CFRelease(stored);
    return result;
}

// RFC 6265 5.1.3 admits exactly these Domain strings for a host: the host itself, and a dotted form of
// the host and of each of its parents. 10.9 canonicalises a stored domain to lower case.
static NSArray<NSString *> *wk_cookieDomainsMatchingHost(NSString *host)
{
    host = wk_jarHostForURLHost(host);
    NSMutableArray<NSString *> *domains = [NSMutableArray arrayWithObject:host];
    NSString *suffix = host;
    while (suffix.length) {
        NSString *dotted = [@"." stringByAppendingString:suffix];
        if (![domains containsObject:dotted])
            [domains addObject:dotted];
        NSRange dot = [suffix rangeOfString:@"."];
        if (dot.location == NSNotFound)
            break;
        suffix = [suffix substringFromIndex:dot.location + 1];
    }
    return domains;
}

typedef void (^WKCookiesChangedHandler)(NSArray<NSHTTPCookie *> *, NSString *);
typedef void (^WKCookiesRemovedHandler)(NSArray<NSHTTPCookie *> *, NSString *, bool);

@interface WKCookieChangeSubscription : NSObject {
@public
    NSSet *_domains;
    WKCookiesChangedHandler _changed;
    WKCookiesRemovedHandler _removed;
    dispatch_queue_t _changedQueue;
    dispatch_queue_t _removedQueue;
    CFHTTPCookieStorageRef _observedStorage;
    NSMutableDictionary *_visible;
}
- (void)updateObservationOfStorage:(CFHTTPCookieStorageRef)storage rebaseline:(BOOL)rebaseline;
- (void)storageChanged:(CFHTTPCookieStorageRef)storage;
- (void)storage:(CFHTTPCookieStorageRef)storage didChangeCookies:(NSArray<NSHTTPCookie *> *)cookies;
- (void)storageRemovedAllCookies;
@end

static NSArray *wk_cookieIndexKey(NSHTTPCookie *cookie)
{
    return @[cookie.name, cookie.domain.lowercaseString, cookie.path, [cookie _storagePartition] ?: @""];
}

static NSArray<NSHTTPCookie *> *wk_cookiesACandidateWouldOverlay(NSHTTPCookieStorage *, NSHTTPCookie *, NSURL *);
static NSURL *wk_cookieOriginURL(NSHTTPCookie *);

static void wk_cookieSubscriptionStorageChanged(CFHTTPCookieStorageRef storage, void *context)
{
    @autoreleasepool {
        @synchronized ((id)storage) {
            [(WKCookieChangeSubscription *)context storageChanged:storage];
        }
    }
}

@implementation WKCookieChangeSubscription
- (BOOL)isSubscribed
{
    return (_changed || _removed) && _domains.count > 0;
}
// The Domain strings the cookies of the subscribed hosts are stored under.
- (NSSet<NSString *> *)cookieDomains
{
    NSMutableSet<NSString *> *cookieDomains = [NSMutableSet set];
    for (NSString *domain in _domains)
        [cookieDomains addObjectsFromArray:wk_cookieDomainsMatchingHost(domain.lowercaseString)];
    return cookieDomains;
}
// The unexpired cookies stored under |cookieDomains|, each Domain string read by an exact match.
- (NSMutableDictionary *)storage:(CFHTTPCookieStorageRef)storage visibleCookiesInDomains:(NSSet<NSString *> *)cookieDomains
{
    NSMutableDictionary *index = [NSMutableDictionary dictionary];
    NSDate *now = [NSDate date];
    for (NSHTTPCookie *candidate in wk_cookiesStoredInDomains(storage, cookieDomains)) {
        NSDate *expires = candidate.expiresDate;
        if (!expires || [expires compare:now] == NSOrderedDescending)
            index[wk_cookieIndexKey(candidate)] = candidate;
    }
    return index;
}
- (void)updateObservationOfStorage:(CFHTTPCookieStorageRef)storage rebaseline:(BOOL)rebaseline
{
    if (![self isSubscribed]) {
        if (_observedStorage)
            CFHTTPCookieStorageRemoveObserver(_observedStorage, CFRunLoopGetMain(), kCFRunLoopCommonModes, wk_cookieSubscriptionStorageChanged, self);
        _observedStorage = NULL;
        [_visible release];
        _visible = nil;
        return;
    }
    if (_observedStorage && !rebaseline)
        return;
    [_visible release];
    _visible = [[self storage:storage visibleCookiesInDomains:[self cookieDomains]] retain];
    if (!_observedStorage) {
        _observedStorage = storage;
        CFHTTPCookieStorageAddObserver(storage, CFRunLoopGetMain(), kCFRunLoopCommonModes, wk_cookieSubscriptionStorageChanged, self);
    }
}
- (void)deliverAdded:(NSArray *)added removed:(NSArray *)removed
{
    for (NSString *domain in _domains) {
        NSMutableArray *domainAdded = [NSMutableArray array];
        NSMutableArray *domainRemoved = [NSMutableArray array];
        for (NSHTTPCookie *cookie in added) {
            if (wk_cookieDomainMatchesHost(cookie.domain, domain))
                [domainAdded addObject:cookie];
        }
        for (NSHTTPCookie *cookie in removed) {
            if (wk_cookieDomainMatchesHost(cookie.domain, domain))
                [domainRemoved addObject:cookie];
        }
        // Captured blocks and immutable batches survive handler replacement and unsubscription.
        WKCookiesRemovedHandler removedHandler = _removed;
        WKCookiesChangedHandler changedHandler = _changed;
        if (domainRemoved.count && removedHandler) {
            NSArray *batch = [[domainRemoved copy] autorelease];
            dispatch_async(_removedQueue, ^{ removedHandler(batch, domain, false); });
        }
        if (domainAdded.count && changedHandler) {
            NSArray *batch = [[domainAdded copy] autorelease];
            dispatch_async(_changedQueue, ^{ changedHandler(batch, domain); });
        }
    }
}
// Delivers what differs between the storage and the cookies last seen under |cookieDomains|, and records
// the storage as seen, so each change is delivered once whichever of its paths reads it first.
- (void)storage:(CFHTTPCookieStorageRef)storage refreshCookieDomains:(NSSet<NSString *> *)cookieDomains
{
    NSDictionary *current = [self storage:storage visibleCookiesInDomains:cookieDomains];
    NSMutableArray *added = [NSMutableArray array];
    NSMutableArray *removed = [NSMutableArray array];
    for (NSArray *key in current) {
        NSHTTPCookie *now = current[key];
        NSHTTPCookie *old = _visible[key];
        if (!old || ![now.properties isEqual:old.properties])
            [added addObject:now];
        // A visible cookie overwritten by HttpOnly leaves the script-visible cookie set.
        if (old && !old.HTTPOnly && now.HTTPOnly)
            [removed addObject:old];
        _visible[key] = now;
    }
    for (NSArray *key in _visible.allKeys) {
        if ([cookieDomains containsObject:key[1]] && !current[key]) {
            [removed addObject:_visible[key]];
            [_visible removeObjectForKey:key];
        }
    }
    [self deliverAdded:added removed:removed];
}
- (void)storageChanged:(CFHTTPCookieStorageRef)storage
{
    if (_observedStorage && [self isSubscribed])
        [self storage:storage refreshCookieDomains:[self cookieDomains]];
}
// A mutation made through this layer is delivered at the mutation, as CFNetwork's own storage delivers it
// before a response continues; each mutated cookie is read at its own URL.
- (void)storage:(CFHTTPCookieStorageRef)storage didChangeCookies:(NSArray<NSHTTPCookie *> *)cookies
{
    if (!_observedStorage || ![self isSubscribed])
        return;
    NSSet<NSString *> *subscribed = [self cookieDomains];
    NSHTTPCookieStorage *wrapper = [[NSHTTPCookieStorage alloc] _initWithCFHTTPCookieStorage:storage];
    NSMutableArray *added = [NSMutableArray array];
    NSMutableArray *removed = [NSMutableArray array];
    for (NSHTTPCookie *cookie in cookies) {
        NSString *domain = cookie.domain.lowercaseString;
        if (!domain || ![subscribed containsObject:domain])
            continue;
        NSArray *key = wk_cookieIndexKey(cookie);
        NSHTTPCookie *now = nil;
        for (NSHTTPCookie *candidate in wk_cookiesACandidateWouldOverlay(wrapper, cookie, wk_cookieOriginURL(cookie))) {
            if ([wk_cookieIndexKey(candidate) isEqualToArray:key]) {
                now = candidate;
                break;
            }
        }
        NSHTTPCookie *old = _visible[key];
        if (now) {
            if (!old || ![now.properties isEqual:old.properties])
                [added addObject:now];
            if (old && !old.HTTPOnly && now.HTTPOnly)
                [removed addObject:old];
            _visible[key] = now;
        } else if (old) {
            [removed addObject:old];
            [_visible removeObjectForKey:key];
        }
    }
    [wrapper release];
    [self deliverAdded:added removed:removed];
}
// A clear that takes the whole jar reaches the handler as the storage's own remove-all, which is how
// a subscriber learns that cookies it never held are gone.
- (void)storageRemovedAllCookies
{
    if (![self isSubscribed])
        return;
    [_visible removeAllObjects];
    WKCookiesRemovedHandler removedHandler = _removed;
    if (removedHandler)
        dispatch_async(_removedQueue, ^{ removedHandler(@[], nil, true); });
}
- (void)dealloc
{
    [_domains release];
    [_visible release];
    [_changed release];
    [_removed release];
    if (_changedQueue)
        dispatch_release(_changedQueue);
    if (_removedQueue)
        dispatch_release(_removedQueue);
    [super dealloc];
}
@end

static const void *const wk_cookieSubscriptionKey = &wk_cookieSubscriptionKey;
static WKCookieChangeSubscription *wk_cookieSubscription(CFHTTPCookieStorageRef storage)
{
    WKCookieChangeSubscription *subscription = objc_getAssociatedObject((id)storage, wk_cookieSubscriptionKey);
    if (!subscription) {
        subscription = [[[WKCookieChangeSubscription alloc] init] autorelease];
        objc_setAssociatedObject((id)storage, wk_cookieSubscriptionKey, subscription, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return subscription;
}
// The subscription a storage already has, or nil: a mutation on a storage nobody observes creates none.
static WKCookieChangeSubscription *wk_existingCookieSubscription(CFHTTPCookieStorageRef storage)
{
    return objc_getAssociatedObject((id)storage, wk_cookieSubscriptionKey);
}

// The NetworkProcess publishes the UI process's cookie jar through the shared-store SPI.
// Both the rewritten Objective-C accessor and the CF default-store shim use this override.
static NSHTTPCookieStorage *wk_sharedCookieStorageOverride;

// The CF and Objective-C default-store accessors share the process's published jar.
CFHTTPCookieStorageRef wk_sharedCookieStorage(void)
{
    @synchronized ([NSHTTPCookieStorage class]) {
        NSHTTPCookieStorage *storage = [[wk_sharedCookieStorageOverride retain] autorelease];
        return wk_cfCookieStorageOf(storage);
    }
}

static NSHTTPCookieStorage *wk_nativeSharedCookieStorage(void)
{
    id storageClass = [NSHTTPCookieStorage class];
    struct wk_original getter = wk_original_of(storageClass, @selector(sharedHTTPCookieStorage));
    return ((NSHTTPCookieStorage *(*)(id, SEL))getter.imp)(storageClass, getter.sel);
}
static void wk_registerCookieNotifications(NSHTTPCookieStorage *);

WK_POLYFILL_ADD_METHODS(NSHTTPCookieStorage)
+ (void)_setSharedHTTPCookieStorage:(NSHTTPCookieStorage *)storage
{
    @synchronized ([NSHTTPCookieStorage class]) {
        if (wk_sharedCookieStorageOverride == storage)
            return;
        [wk_sharedCookieStorageOverride release];
        wk_sharedCookieStorageOverride = [storage retain];
        NSHTTPCookieStorage *nativeShared = wk_nativeSharedCookieStorage();
        if (storage != nativeShared)
            wk_registerCookieNotifications(storage);
    }
}
- (void)_setCookiesChangedHandler:(WKCookiesChangedHandler)handler onQueue:(dispatch_queue_t)queue
{
    CFHTTPCookieStorageRef storage = wk_cfCookieStorageOf(self);
    @synchronized ((id)storage) {
        WKCookieChangeSubscription *subscription = wk_cookieSubscription(storage);
        WKCookiesChangedHandler copy = [handler copy];
        if (queue)
            dispatch_retain(queue);
        [subscription->_changed release];
        if (subscription->_changedQueue)
            dispatch_release(subscription->_changedQueue);
        subscription->_changed = copy;
        subscription->_changedQueue = queue;
        [subscription updateObservationOfStorage:storage rebaseline:NO];
    }
}
- (void)_setCookiesRemovedHandler:(WKCookiesRemovedHandler)handler onQueue:(dispatch_queue_t)queue
{
    CFHTTPCookieStorageRef storage = wk_cfCookieStorageOf(self);
    @synchronized ((id)storage) {
        WKCookieChangeSubscription *subscription = wk_cookieSubscription(storage);
        WKCookiesRemovedHandler copy = [handler copy];
        if (queue)
            dispatch_retain(queue);
        [subscription->_removed release];
        if (subscription->_removedQueue)
            dispatch_release(subscription->_removedQueue);
        subscription->_removed = copy;
        subscription->_removedQueue = queue;
        [subscription updateObservationOfStorage:storage rebaseline:NO];
    }
}
- (void)_setSubscribedDomainsForCookieChanges:(NSSet<NSString *> *)domains
{
    CFHTTPCookieStorageRef storage = wk_cfCookieStorageOf(self);
    @synchronized ((id)storage) {
        WKCookieChangeSubscription *subscription = wk_cookieSubscription(storage);
        if ([subscription->_domains isEqual:domains])
            return;
        NSSet *copy = [domains copy];
        [subscription->_domains release];
        subscription->_domains = copy;
        [subscription updateObservationOfStorage:storage rebaseline:YES];
    }
}
@end

// Notifications carry the registered NS wrapper. Its token retains the CF handle
// and unregisters before releasing that handle.
@interface WKCookieNotificationRegistration : NSObject {
@public
    CFHTTPCookieStorageRef _storage;
    NSHTTPCookieStorage *_context;
}
- (instancetype)initWithContext:(NSHTTPCookieStorage *)context;
@end

static void wk_postCookiesChangedNotification(CFHTTPCookieStorageRef storage, void *value)
{
    (void)storage;
    WKCookieNotificationRegistration *registration = value;
    [[NSNotificationCenter defaultCenter] postNotificationName:NSHTTPCookieManagerCookiesChangedNotification object:registration->_context];
}

@implementation WKCookieNotificationRegistration
- (instancetype)initWithContext:(NSHTTPCookieStorage *)context
{
    if (!(self = [super init]))
        return nil;
    _context = context;
    _storage = (CFHTTPCookieStorageRef)CFRetain(wk_cfCookieStorageOf(context));
    CFHTTPCookieStorageAddObserver(_storage, CFRunLoopGetMain(), kCFRunLoopCommonModes, wk_postCookiesChangedNotification, self);
    return self;
}
- (void)dealloc
{
    CFHTTPCookieStorageRemoveObserver(_storage, CFRunLoopGetMain(), kCFRunLoopCommonModes, wk_postCookiesChangedNotification, self);
    CFRelease(_storage);
    [super dealloc];
}
@end

static const void *const wk_cookieNotificationKey = &wk_cookieNotificationKey;
static void wk_registerCookieNotifications(NSHTTPCookieStorage *context)
{
    @synchronized (context) {
        if (context && !objc_getAssociatedObject(context, wk_cookieNotificationKey)) {
            WKCookieNotificationRegistration *registration = [[WKCookieNotificationRegistration alloc] initWithContext:context];
            objc_setAssociatedObject(context, wk_cookieNotificationKey, registration, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [registration release];
        }
    }
}

WK_POLYFILL_ADD_METHODS_ON(NSObject, "NSHTTPCookieStorageInternal")
- (void)registerForPostingNotificationsWithContext:(NSHTTPCookieStorage *)context
{
    wk_registerCookieNotifications(context);
}
@end

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
// native API constructor uses the shared limit in wk_samesite.h; HTTP Set-Cookie parsing is owned by WebCore.
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

// NSHTTPCookieExpires is kept to the nearest second, so an expiry a fraction of a second in the past
// becomes one a fraction of a second in the future and the jar keeps a cookie whose lifetime has ended.
// Truncating toward the past leaves the expiry in the second the date already names.
static NSDictionary *wk_propertiesWithWholeSecondExpiry(NSDictionary *properties)
{
    id expires = properties[NSHTTPCookieExpires];
    if (![expires isKindOfClass:[NSDate class]])
        return properties;
    NSTimeInterval seconds = [(NSDate *)expires timeIntervalSince1970];
    if (seconds == floor(seconds))
        return properties;
    NSMutableDictionary *truncated = [[properties mutableCopy] autorelease];
    truncated[NSHTTPCookieExpires] = [NSDate dateWithTimeIntervalSince1970:floor(seconds)];
    return truncated;
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
    // 10.9's NSHTTPCookie drops a property it does not know: SetInJavaScript is gone from -properties
    // before the cookie is stored, and it is what selects the cookies
    // NetworkStorageSession::deleteCookiesForHostnames(ScriptWrittenCookiesOnly::Yes) removes. It rides
    // in the blob with the other two.
    NSString *setInJavaScript = properties[@"SetInJavaScript"] ? @"1" : nil;
    if (!policy && !created && !setInJavaScript)
        return properties;

    NSMutableDictionary *translated = [[properties mutableCopy] autorelease];
    [translated removeObjectForKey:NSHTTPCookieSameSitePolicy];
    [translated removeObjectForKey:@"SetInJavaScript"];
    // 10.9's own record cannot carry a creation time a caller chose: whatever the key names, the cookie
    // comes back reporting 1, and a cookie whose creation time reads as 1 sorts ahead of every other
    // cookie of its path in the order RFC 6265 5.4 composes the Cookie header in. Dropping the key
    // leaves the constructor to stamp the record it is making, and the time the caller asked for rides
    // in the blob with the SameSite attribute, which is what -properties reports back.
    [translated removeObjectForKey:@"Created"];

    id comment = properties[NSHTTPCookieComment];
    CFStringRef encoded = wk_cookieBlobCreate((CFStringRef)policy, (CFStringRef)created, (CFStringRef)setInJavaScript,
        [comment isKindOfClass:[NSString class]] ? (CFStringRef)comment : NULL);
    if (!encoded)
        return nil;
    translated[NSHTTPCookieComment] = [(NSString *)encoded autorelease];
    return translated;
}
#pragma clang diagnostic pop

// RFC 6265bis storage integrity, which modern CFNetwork applies beneath this boundary for every caller.
static NSString *wk_bareCookieDomain(NSString *domain)
{
    return [domain hasPrefix:@"."] ? [domain substringFromIndex:1] : domain;
}

// |host| is |suffix| itself or a subdomain of it.
static BOOL wk_domainCovers(NSString *host, NSString *suffix)
{
    if (!host.length || !suffix.length)
        return NO;
    if ([host caseInsensitiveCompare:suffix] == NSOrderedSame)
        return YES;
    if (wk_hostIsIPAddress((CFStringRef)host))
        return NO;
    NSString *dotted = [@"." stringByAppendingString:suffix];
    NSRange found = [host rangeOfString:dotted options:NSCaseInsensitiveSearch | NSAnchoredSearch | NSBackwardsSearch];
    return found.location != NSNotFound;
}

// A cookie whose Path is |candidate| is covered by a record whose Path is |stored| (RFC 6265 5.1.4).
static BOOL wk_pathCovers(NSString *stored, NSString *candidate)
{
    if ([stored isEqualToString:candidate])
        return YES;
    if (!stored.length || ![candidate hasPrefix:stored])
        return NO;
    return [stored hasSuffix:@"/"] || (candidate.length > stored.length && [candidate characterAtIndex:stored.length] == '/');
}

// The records this write could overlay, including Secure records, at the candidate's own path.
static NSArray<NSHTTPCookie *> *wk_cookiesACandidateWouldOverlay(NSHTTPCookieStorage *storage, NSHTTPCookie *candidate, NSURL *url)
{
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!url.isFileURL)
        components.scheme = @"https";
    components.path = candidate.path.length ? candidate.path : @"/";
    NSURL *lookupURL = components.URL;
    return lookupURL ? [storage cookiesForURL:lookupURL] : @[];
}

// RFC 6265bis 5.5: a write from an insecure origin may neither overwrite nor shadow a Secure record, and
// a write that replaces a record keeps that record's creation time.
static NSArray<NSHTTPCookie *> *wk_cookiesWithStorageIntegrity(NSHTTPCookieStorage *storage, NSArray<NSHTTPCookie *> *cookies, NSURL *url)
{
    BOOL secureOrigin = [url.scheme caseInsensitiveCompare:@"https"] == NSOrderedSame || [url.scheme caseInsensitiveCompare:@"wss"] == NSOrderedSame;
    NSMutableArray<NSHTTPCookie *> *accepted = [NSMutableArray arrayWithCapacity:cookies.count];
    for (NSHTTPCookie *candidate in cookies) {
        if (!secureOrigin && candidate.isSecure)
            continue;
        NSHTTPCookie *replaced = nil;
        BOOL shadowsSecureRecord = NO;
        for (NSHTTPCookie *stored in wk_cookiesACandidateWouldOverlay(storage, candidate, url)) {
            if (![stored.name isEqualToString:candidate.name])
                continue;
            if (![[stored _storagePartition] ?: @"" isEqualToString:[candidate _storagePartition] ?: @""])
                continue;
            if (!secureOrigin && !candidate.isSecure && stored.isSecure
                && (wk_domainCovers(wk_bareCookieDomain(candidate.domain), wk_bareCookieDomain(stored.domain))
                    || wk_domainCovers(wk_bareCookieDomain(stored.domain), wk_bareCookieDomain(candidate.domain)))
                && wk_pathCovers(stored.path, candidate.path))
                shadowsSecureRecord = YES;
            if ([wk_cookieIndexKey(stored) isEqualToArray:wk_cookieIndexKey(candidate)])
                replaced = stored;
        }
        if (shadowsSecureRecord)
            continue;
        id created = replaced ? replaced.properties[@"Created"] : nil;
        if (!created) {
            [accepted addObject:candidate];
            continue;
        }
        NSMutableDictionary *properties = [[candidate.properties mutableCopy] autorelease];
        properties[@"Created"] = created;
        [accepted addObject:[[[NSHTTPCookie alloc] initWithProperties:properties] autorelease]];
    }
    return accepted;
}

static NSURL *wk_cookieOriginURL(NSHTTPCookie *cookie)
{
    if ([cookie.domain isEqualToString:@".^filecookies^"])
        return [NSURL fileURLWithPath:cookie.path.length ? cookie.path : @"/"];
    // 10.9's -OriginURL writes an IPv6 domain unbracketed, which leaves the URL without a host.
    if ([cookie.domain rangeOfString:@":"].location != NSNotFound && wk_hostIsIPAddress((CFStringRef)cookie.domain))
        return [NSURL URLWithString:[NSString stringWithFormat:@"http://[%@]", cookie.domain]];
    return [cookie OriginURL];
}

// Public cookie mutations preserve the stored HTTPOnly attribute.
static BOOL wk_publicCookieMayReplaceStoredCookie(NSHTTPCookieStorage *storage, NSHTTPCookie *candidate)
{
    if (candidate.isHTTPOnly)
        return YES;
    NSArray *key = wk_cookieIndexKey(candidate);
    for (NSHTTPCookie *stored in wk_cookiesACandidateWouldOverlay(storage, candidate, wk_cookieOriginURL(candidate))) {
        if (stored.isHTTPOnly && [wk_cookieIndexKey(stored) isEqualToArray:key])
            return NO;
    }
    return YES;
}

// A script may neither set an HttpOnly cookie nor overwrite a record that carries it.
static NSArray<NSHTTPCookie *> *wk_cookiesAScriptMaySet(NSHTTPCookieStorage *storage, NSArray<NSHTTPCookie *> *cookies, NSURL *url)
{
    NSMutableArray<NSHTTPCookie *> *accepted = [NSMutableArray arrayWithCapacity:cookies.count];
    for (NSHTTPCookie *candidate in cookies) {
        if (candidate.isHTTPOnly)
            continue;
        BOOL overwritesHTTPOnlyRecord = NO;
        for (NSHTTPCookie *stored in wk_cookiesACandidateWouldOverlay(storage, candidate, url)) {
            if (stored.isHTTPOnly && [wk_cookieIndexKey(stored) isEqualToArray:wk_cookieIndexKey(candidate)])
                overwritesHTTPOnlyRecord = YES;
        }
        if (!overwritesHTTPOnlyRecord)
            [accepted addObject:candidate];
    }
    return accepted;
}

WK_POLYFILL_ADD_METHODS(NSHTTPCookieStorage)
- (void)_getCookiesForURL:(NSURL *)url mainDocumentURL:(NSURL *)mainDocumentURL partition:(NSString *)partition policyProperties:(NSDictionary *)policyProperties completionHandler:(void (^)(NSArray<NSHTTPCookie *> *))completionHandler
{
    (void)partition;
    NSHTTPCookieAcceptPolicy policy = self.cookieAcceptPolicy;
    if (policy == wk_cookieAcceptPolicyExclusivelyFromMainDocumentDomain && mainDocumentURL
        && wk_hostsHaveDifferentRegistrableDomains((CFURLRef)url, (CFURLRef)mainDocumentURL))
        return completionHandler(@[]);
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
// The SPI every script-side write reaches this jar through, and the only one, so the rules that hold for
// a script rather than for a response belong here.
- (void)_setCookies:(NSArray<NSHTTPCookie *> *)cookies forURL:(NSURL *)url mainDocumentURL:(NSURL *)mainDocumentURL policyProperties:(NSDictionary *)policyProperties
{
    (void)policyProperties;
    [self setCookies:wk_cookiesAScriptMaySet(self, cookies, url) forURL:url mainDocumentURL:mainDocumentURL];
}
- (NSArray<NSHTTPCookie *> *)_getCookiesForDomain:(NSString *)domain
{
    if (!domain.length)
        return [NSMutableArray array];
    return wk_cookiesStoredInDomains(wk_cfCookieStorageOf(self), [NSSet setWithArray:wk_cookieDomainsMatchingHost(domain.lowercaseString)]);
}

@end

// A cookie whose expiry has passed is discarded at storage time rather than kept. 10.9's jar evaluates
// expiry only against a record it already holds -- handed one whose name it does not know, -setCookies:
// stores it, where it stays out of the per-URL view but remains in -cookies, so a Set-Cookie that only
// removes a cookie leaves a dead one behind for every reader of the whole jar.
static void wk_discardExpiredCookies(NSHTTPCookieStorage *storage, NSArray<NSHTTPCookie *> *cookies)
{
    NSDate *now = [NSDate date];
    for (NSHTTPCookie *cookie in cookies) {
        NSDate *expires = [cookie expiresDate];
        if (expires && [expires compare:now] != NSOrderedDescending)
            [storage deleteCookie:cookie];
    }
}

// The whole jar answers expired records too.
static BOOL wk_holdsUnexpiredCookie(NSArray<NSHTTPCookie *> *cookies)
{
    NSDate *now = [NSDate date];
    for (NSHTTPCookie *cookie in cookies) {
        NSDate *expires = [cookie expiresDate];
        if (!expires || [expires compare:now] == NSOrderedDescending)
            return YES;
    }
    return NO;
}

static BOOL wk_storageHasUnexpiredDomainCookie(NSHTTPCookieStorage *storage, NSURL *url)
{
    if (!wk_cookieStorageHasRecordsForURL(wk_cfCookieStorageOf(storage), (CFURLRef)url))
        return NO;
    NSURLComponents *secureURL = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:YES];
    secureURL.scheme = @"https";
    if (wk_holdsUnexpiredCookie([storage cookiesForURL:secureURL.URL]))
        return YES;
    // The acceptance policy counts unexpired cookies even when their Path excludes this URL.
    return wk_holdsUnexpiredCookie([storage _getCookiesForDomain:url.host]);
}

// The public setter and the policy SPI share PSL acceptance at the native jar boundary.
WK_POLYFILL_REPLACE_METHODS(NSHTTPCookieStorage)
+ (NSHTTPCookieStorage *)sharedHTTPCookieStorage
{
    @synchronized ([NSHTTPCookieStorage class]) {
        if (wk_sharedCookieStorageOverride)
            return [[wk_sharedCookieStorageOverride retain] autorelease];
    }
    return WK_ORIGINAL_METHOD(NSHTTPCookieStorage *, ());
}
- (void)setCookie:(NSHTTPCookie *)cookie
{
    NSURL *url = wk_cookieOriginURL(cookie);
    if (!wk_cookieWithUsableDomain(cookie, url) || !wk_publicCookieMayReplaceStoredCookie(self, cookie))
        return;
    NSArray<NSHTTPCookie *> *usable = wk_cookiesWithStorageIntegrity(self, @[cookie], url);
    if (!usable.count)
        return;
    cookie = usable[0];
    CFHTTPCookieStorageRef storage = wk_cfCookieStorageOf(self);
    WK_ORIGINAL_METHOD(void, (NSHTTPCookie *), cookie);
    wk_discardExpiredCookies(self, @[cookie]);
    @synchronized ((id)storage) {
        [wk_existingCookieSubscription(storage) storage:storage didChangeCookies:@[cookie]];
    }
}

- (void)deleteCookie:(NSHTTPCookie *)cookie
{
    if (!wk_publicCookieMayReplaceStoredCookie(self, cookie))
        return;
    CFHTTPCookieStorageRef storage = wk_cfCookieStorageOf(self);
    WK_ORIGINAL_METHOD(void, (NSHTTPCookie *), cookie);
    @synchronized ((id)storage) {
        [wk_existingCookieSubscription(storage) storage:storage didChangeCookies:@[cookie]];
    }
}

- (void)setCookies:(NSArray<NSHTTPCookie *> *)cookies forURL:(NSURL *)url mainDocumentURL:(NSURL *)mainDocumentURL
{
    NSHTTPCookieAcceptPolicy policy = self.cookieAcceptPolicy;
    // WebCore HTTP, document.cookie and Cookie Store API mutations share this native jar boundary.
    NSMutableArray<NSHTTPCookie *> *usable = [NSMutableArray arrayWithCapacity:cookies.count];
    for (NSHTTPCookie *cookie in cookies) {
        if (wk_cookieWithUsableDomain(cookie, url))
            [usable addObject:cookie];
    }
    // The native main-document policy consults a 2013 PSL. Apply its registrable-domain
    // boundary with the current PSL, retaining its existing-cookie exception: an unexpired stored cookie
    // whose domain domain-matches the host, whatever its path or Secure flag.
    if ((policy == NSHTTPCookieAcceptPolicyOnlyFromMainDocumentDomain || policy == wk_cookieAcceptPolicyExclusivelyFromMainDocumentDomain) && mainDocumentURL
        && wk_hostsHaveDifferentRegistrableDomains((__bridge CFURLRef)url, (__bridge CFURLRef)mainDocumentURL)
        && (policy == wk_cookieAcceptPolicyExclusivelyFromMainDocumentDomain || !wk_storageHasUnexpiredDomainCookie(self, url)))
        return;
    usable = (NSMutableArray *)wk_cookiesWithStorageIntegrity(self, usable, url);
    CFHTTPCookieStorageRef storage = wk_cfCookieStorageOf(self);
    WK_ORIGINAL_METHOD(void, (NSArray *, NSURL *, NSURL *), usable, url, mainDocumentURL);
    wk_discardExpiredCookies(self, usable);
    @synchronized ((id)storage) {
        [wk_existingCookieSubscription(storage) storage:storage didChangeCookies:usable];
    }
}
@end

// -[NSHTTPCookie _storagePartition] is the per-cookie partition key; 10.9 stores everything
// unpartitioned, so nil (the "no partition" value the callers already treat as the default) is honest.
// -[NSHTTPCookie sameSitePolicy] (10.13+) reports a cookie's stored SameSite attribute (paired with the
// NSHTTPCookieSameSiteLax/Strict constants polyfilled in c/Foundation.m), which on 10.9 is what the
// cookie carries in its Comment field (wk_samesite.h).
WK_POLYFILL_ADD_METHODS(NSHTTPCookie)
- (NSString *)sameSitePolicy { return wk_canonicalSameSitePolicy(self); }
- (NSString *)_storagePartition { return nil; }

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
    NSString *setInJavaScript = [(NSString *)wk_cookieBlobCopySetInJavaScript((CFStringRef)comment) autorelease];
    if (!sameSite && !created && !setInJavaScript)
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
    if (setInJavaScript)
        decoded[@"SetInJavaScript"] = @1;
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
    return WK_ORIGINAL_METHOD(id, (NSDictionary *), wk_propertiesWithSameSiteEncoded(wk_propertiesWithWholeSecondExpiry(wk_propertiesWithCappedExpiry(properties))));
}
- (instancetype)initWithProperties:(NSDictionary<NSHTTPCookiePropertyKey, id> *)properties
{
    return WK_ORIGINAL_METHOD(id, (NSDictionary *), wk_propertiesWithSameSiteEncoded(wk_propertiesWithWholeSecondExpiry(wk_propertiesWithCappedExpiry(properties))));
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
+ (NSURL *)fileURLWithPath:(NSString *)path isDirectory:(BOOL)isDirectory relativeToURL:(NSURL *)baseURL
{
    return [self fileURLWithFileSystemRepresentation:path.fileSystemRepresentation isDirectory:isDirectory relativeToURL:baseURL];
}
+ (NSURL *)fileURLWithPath:(NSString *)path relativeToURL:(NSURL *)baseURL
{
    // The native byte-path constructor supplies base resolution and filesystem escaping.
    BOOL isDirectory = [path hasSuffix:@"/"];
    NSURL *url = [self fileURLWithFileSystemRepresentation:path.fileSystemRepresentation isDirectory:isDirectory relativeToURL:baseURL];
    if (!isDirectory && [[NSFileManager defaultManager] fileExistsAtPath:url.path isDirectory:&isDirectory] && isDirectory)
        return [self fileURLWithFileSystemRepresentation:path.fileSystemRepresentation isDirectory:YES relativeToURL:baseURL];
    return url;
}
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
// (10.10+), the key that writes a file's LaunchServices quarantine dictionary, and implements
// NSURLIsExcludedFromBackupKey over a service WebKit's sandboxes do not grant. REPLACE it for WebKit's
// callers: the quarantine key is applied through LSSetItemAttribute/kLSItemQuarantineProperties, which is
// the mechanism the modern key is implemented over -- WKShareSheet.mm's own comment names
// LSSetItemAttribute as the call writing this key ends up making, and notes that it resets the
// quarantine flags, which is why WKShareSheet re-applies them with qtn_file_set_flags immediately
// afterwards. Every other key forwards to 10.9's implementation through WK_ORIGINAL_METHOD, so this
// cannot recurse into itself.
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
#pragma clang diagnostic pop
    // 10.9 implements NSURLIsExcludedFromBackupKey as CSBackupSetItemExcluded(), which writes the
    // attribute through a Metadata item and so needs the Spotlight server, which WebKit's sandboxes do
    // not grant. The key's modern implementation writes the attribute directly: Time Machine's
    // exclusion attribute, whose value is "com.apple.backupd" as a binary property list, the bytes
    // CSBackupSetItemExcluded writes. Clearing the key removes it.
    if ([key isEqualToString:NSURLIsExcludedFromBackupKey]) {
        if (![self isFileURL]) {
            if (error)
                *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnsupportedSchemeError userInfo:nil];
            return NO;
        }
        static const char attributeName[] = "com.apple.metadata:com_apple_backup_excludeItem";
        const char *path = [self fileSystemRepresentation];
        int result;
        int savedErrno;
        if ([value boolValue]) {
            NSData *attribute = [NSPropertyListSerialization dataWithPropertyList:@"com.apple.backupd" format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
            result = setxattr(path, attributeName, attribute.bytes, attribute.length, 0, 0);
            savedErrno = errno;
        } else {
            result = removexattr(path, attributeName, 0);
            savedErrno = errno;
            if (result && savedErrno == ENOATTR)
                result = 0;
        }
        if (result) {
            if (error) {
                NSError *underlying = [NSError errorWithDomain:NSPOSIXErrorDomain code:savedErrno userInfo:nil];
                *error = [NSError errorWithDomain:NSCocoaErrorDomain code:savedErrno == ENOENT ? NSFileNoSuchFileError : NSFileWriteUnknownError userInfo:@{ NSURLErrorKey: self, NSUnderlyingErrorKey: underlying }];
            }
            return NO;
        }
        return YES;
    }
    return WK_ORIGINAL_METHOD(BOOL, (id, NSString *, NSError **), value, key, error);
}
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
// -[NSURLResponse suggestedFilename] reads Content-Disposition as UTF-8 when its bytes form UTF-8 and as
// ISO-8859-1 otherwise, the reading ResourceResponseSoup and ResourceResponseCurl give the same header.
// A header reaches Foundation with one character per byte, and 10.9's CFURLResponseCopySuggestedFilename
// takes those characters as they stand, so a byte-per-character field that is valid UTF-8 is named from a
// response carrying its UTF-8 reading.
@interface NSURLResponse (WKSuggestedFilename)
- (CFTypeRef)_CFURLResponse;
- (void)_setMIMEType:(NSString *)MIMEType;
@end

WK_SYSTEM_FN("CFNetwork", CFStringRef, CFURLResponseCopySuggestedFilename, (CFTypeRef));

static NSString *wk_contentDispositionReadAsUTF8(NSString *field)
{
    NSUInteger length = field.length;
    NSMutableData *bytes = [NSMutableData dataWithLength:length];
    uint8_t *byte = (uint8_t *)bytes.mutableBytes;
    BOOL hasNonASCII = NO;
    for (NSUInteger i = 0; i < length; ++i) {
        unichar character = [field characterAtIndex:i];
        if (character > 0xFF)
            return nil;
        hasNonASCII |= character >= 0x80;
        byte[i] = (uint8_t)character;
    }
    if (!hasNonASCII)
        return nil;
    return [[[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding] autorelease];
}

WK_POLYFILL_REPLACE_METHODS(NSURLResponse)
- (NSString *)suggestedFilename
{
    if (![self isKindOfClass:[NSHTTPURLResponse class]])
        return WK_ORIGINAL_METHOD(NSString *, ());
    NSHTTPURLResponse *response = (NSHTTPURLResponse *)self;
    NSDictionary *headers = [response allHeaderFields];
    NSString *key = nil;
    for (NSString *candidate in headers) {
        if ([candidate isKindOfClass:[NSString class]] && [candidate caseInsensitiveCompare:@"Content-Disposition"] == NSOrderedSame) {
            key = candidate;
            break;
        }
    }
    id field = key ? [headers objectForKey:key] : nil;
    NSString *reading = [field isKindOfClass:[NSString class]] ? wk_contentDispositionReadAsUTF8(field) : nil;
    if (!reading)
        return WK_ORIGINAL_METHOD(NSString *, ());

    NSMutableDictionary *fields = [[headers mutableCopy] autorelease];
    [fields setObject:reading forKey:key];
    NSHTTPURLResponse *readResponse = [[[NSHTTPURLResponse alloc] initWithURL:[response URL] statusCode:[response statusCode] HTTPVersion:@"HTTP/1.1" headerFields:fields] autorelease];
    [readResponse _setMIMEType:[response MIMEType]];
    CFStringRef filename = WK_SYSTEM(CFURLResponseCopySuggestedFilename)([readResponse _CFURLResponse]);
    return filename ? [(NSString *)filename autorelease] : nil;
}
@end

// -[NSURLResponse MIMEType] of a file URL's response names the declared type its filename extension
// names: c/CFNetwork.c's CFURLResponseGetMIMEType, which Foundation's own call does not reach. A response
// built through the initializer, or retyped through -_setMIMEType:, keeps the MIME type it was given, and
// the mark on its CFURLResponse makes both readers keep it.
WK_POLYFILL_REPLACE_METHODS(NSURLResponse)
- (NSString *)MIMEType
{
    CFTypeRef response = [self _CFURLResponse];
    CFStringRef derived = response ? wkDerivedDeclaredMIMEType(response, (CFURLRef)[self URL]) : NULL;
    if (derived)
        return (NSString *)derived;
    return WK_ORIGINAL_METHOD(NSString *, ());
}

- (instancetype)initWithURL:(NSURL *)URL MIMEType:(NSString *)MIMEType expectedContentLength:(NSInteger)length textEncodingName:(NSString *)name
{
    self = WK_ORIGINAL_METHOD(id, (NSURL *, NSString *, NSInteger, NSString *), URL, MIMEType, length, name);
    if (self)
        wkMarkGivenMIMEType([self _CFURLResponse]);
    return self;
}

- (void)_setMIMEType:(NSString *)MIMEType
{
    wkMarkGivenMIMEType([self _CFURLResponse]);
    WK_ORIGINAL_METHOD(void, (NSString *), MIMEType);
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

// -TLSMinimumSupportedProtocolVersion is the tls_protocol_version_t spelling of the SSLProtocol
// TLSMinimumSupportedProtocol 10.9's configuration stores, so both accessors share that one value and a
// copied configuration carries it. The codepoints are the protocol's wire version numbers.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wunguarded-availability"
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
static tls_protocol_version_t wk_tlsProtocolVersionForSSLProtocol(SSLProtocol protocol)
{
    switch (protocol) {
    case kSSLProtocol3: return (tls_protocol_version_t)0x0300;
    case kTLSProtocol1: return tls_protocol_version_TLSv10;
    case kTLSProtocol11: return tls_protocol_version_TLSv11;
    case kTLSProtocol12: return tls_protocol_version_TLSv12;
    case kTLSProtocol13: return tls_protocol_version_TLSv13;
    case kDTLSProtocol1: return tls_protocol_version_DTLSv10;
    case kDTLSProtocol12: return tls_protocol_version_DTLSv12;
    default: return (tls_protocol_version_t)0;
    }
}

static SSLProtocol wk_sslProtocolForTLSProtocolVersion(tls_protocol_version_t version)
{
    switch ((uint16_t)version) {
    case 0x0300: return kSSLProtocol3;
    case tls_protocol_version_TLSv10: return kTLSProtocol1;
    case tls_protocol_version_TLSv11: return kTLSProtocol11;
    case tls_protocol_version_TLSv12: return kTLSProtocol12;
    case tls_protocol_version_TLSv13: return kTLSProtocol13;
    case tls_protocol_version_DTLSv10: return kDTLSProtocol1;
    case tls_protocol_version_DTLSv12: return kDTLSProtocol12;
    default: return kSSLProtocolUnknown;
    }
}

WK_POLYFILL_ADD_METHODS_ON(NSURLSessionConfiguration, "NSURLSessionConfiguration", "__NSCFURLSessionConfiguration")
- (tls_protocol_version_t)TLSMinimumSupportedProtocolVersion
{
    return wk_tlsProtocolVersionForSSLProtocol(self.TLSMinimumSupportedProtocol);
}
- (void)setTLSMinimumSupportedProtocolVersion:(tls_protocol_version_t)version
{
    self.TLSMinimumSupportedProtocol = wk_sslProtocolForTLSProtocolVersion(version);
}
@end
#pragma clang diagnostic pop

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

WK_POLYFILL_REPLACE_METHODS(NSHTTPCookieStorage)
// Preserve CF's exclusive main-document policy, which the native NS enum cannot represent.
// Account-wide preference writes belong only to the native default jar.
- (NSHTTPCookieAcceptPolicy)cookieAcceptPolicy
{
    return (NSHTTPCookieAcceptPolicy)CFHTTPCookieStorageGetCookieAcceptPolicy(wk_cfCookieStorageOf(self));
}

- (void)setCookieAcceptPolicy:(NSHTTPCookieAcceptPolicy)policy
{
    CFHTTPCookieStorageRef store = wk_cfCookieStorageOf(self);
    if (store == wk_cfCookieStorageOf(wk_nativeSharedCookieStorage()))
        WK_ORIGINAL_METHOD(void, (NSHTTPCookieAcceptPolicy), policy);
    if (store)
        CFHTTPCookieStorageSetCookieAcceptPolicy(store, (CFIndex)policy);
}
@end

// RFC 6265bis 5.5 sends the longer cookie-path first. Among equal paths the jar's own order stands, and
// the slot a cookie arrived in settles every tie, so the sort is stable.
struct wk_cookieSendSlot {
    NSHTTPCookie *cookie;
    CFStringRef path;
    NSUInteger arrival;
};

static int wk_compareCookieSendSlots(const void *a, const void *b)
{
    const struct wk_cookieSendSlot *first = (const struct wk_cookieSendSlot *)a;
    const struct wk_cookieSendSlot *second = (const struct wk_cookieSendSlot *)b;
    if (wk_cookiePathSortsFirst(first->path, second->path))
        return -1;
    if (wk_cookiePathSortsFirst(second->path, first->path))
        return 1;
    return first->arrival < second->arrival ? -1 : 1;
}

// Answers |cookies| itself when it already reads that way, so the common case costs one scan.
static NSArray<NSHTTPCookie *> *wk_cookiesInSendOrder(NSArray<NSHTTPCookie *> *cookies)
{
    NSUInteger count = cookies.count;
    if (count < 2)
        return cookies;
    // A URL's cookies are few; the heap is for the jar that holds more than a page ever sends.
    struct wk_cookieSendSlot inlineSlots[32];
    struct wk_cookieSendSlot *slots = count <= (sizeof(inlineSlots) / sizeof(inlineSlots[0]))
        ? inlineSlots : (struct wk_cookieSendSlot *)malloc(count * sizeof(inlineSlots[0]));
    if (!slots)
        return cookies;
    for (NSUInteger i = 0; i < count; ++i) {
        NSHTTPCookie *cookie = cookies[i];
        slots[i].cookie = cookie;
        slots[i].path = (CFStringRef)cookie.path;
        slots[i].arrival = i;
    }

    bool ordered = true;
    for (NSUInteger i = 1; i < count && ordered; ++i)
        ordered = wk_compareCookieSendSlots(&slots[i - 1], &slots[i]) < 0;
    NSArray<NSHTTPCookie *> *result = cookies;
    if (!ordered) {
        qsort(slots, count, sizeof(slots[0]), wk_compareCookieSendSlots);
        NSMutableArray<NSHTTPCookie *> *sorted = [NSMutableArray arrayWithCapacity:count];
        for (NSUInteger i = 0; i < count; ++i)
            [sorted addObject:slots[i].cookie];
        result = sorted;
    }
    if (slots != inlineSlots)
        free(slots);
    return result;
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

void wk_cookieStorageDidRemoveAllCookies(CFHTTPCookieStorageRef storage)
{
    @synchronized ((id)storage) {
        [wk_existingCookieSubscription(storage) storageRemovedAllCookies];
    }
}

// CFHTTPCookieStorageDeleteCookie (polyfills/c/CFNetwork.c) removes a cookie through here, so its
// subscribers hear of the removal as they do of -deleteCookie:.
void wk_cookieStorageDeleteCookie(CFHTTPCookieStorageRef storage, CFHTTPCookieRef cf, void (*deleteCookie)(CFHTTPCookieStorageRef, CFHTTPCookieRef))
{
    @autoreleasepool {
        NSHTTPCookie *cookie = storage && cf ? [NSHTTPCookie cookieWithCFHTTPCookie:cf] : nil;
        deleteCookie(storage, cf);
        if (!cookie)
            return;
        @synchronized ((id)storage) {
            [wk_existingCookieSubscription(storage) storage:storage didChangeCookies:@[cookie]];
        }
    }
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
    CFRelease(storage);
    return result;
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

// -[NSURLProtectionSpace authenticationMethod] and the two designated initializers, in step with the
// NSURLAuthenticationMethodHTTPBasic value in c/Foundation.m. 10.9's Foundation gives that constant
// the value of NSURLAuthenticationMethodDefault, so it names a Basic challenge a default one and
// takes the modern value back as a method it does not know. The CF space underneath carries the
// scheme the server named as a number -- Default 1, Basic 2 -- so the getter reports Basic from it,
// and an initializer handed the modern value builds a space that answers 2.
enum {
    kWKProtectionSpaceSchemeDefault = 1,
    kWKProtectionSpaceSchemeHTTPBasic = 2,
};

static WKURLProtectionSpaceRef wk_cfProtectionSpace(id space)
{
    static SEL cfSpaceSelector;
    if (!cfSpaceSelector)
        cfSpaceSelector = sel_registerName("_cfurlprtotectionspace");
    return ((WKURLProtectionSpaceRef (*)(id, SEL))objc_msgSend)(space, cfSpaceSelector);
}

// `space` with its scheme set to Basic, consuming the reference it was passed.
static id wk_protectionSpaceAsHTTPBasic(id space)
{
    WKURLProtectionSpaceRef cfSpace = space ? wk_cfProtectionSpace(space) : NULL;
    if (!cfSpace)
        return space;
    CFTypeRef basic = wk_createProtectionSpace(CFURLProtectionSpaceGetHost(cfSpace), CFURLProtectionSpaceGetPort(cfSpace),
        CFURLProtectionSpaceGetServerType(cfSpace), CFURLProtectionSpaceGetRealm(cfSpace), kWKProtectionSpaceSchemeHTTPBasic,
        NULL, NULL);
    if (!basic)
        return space;
    static SEL initWithCFSpaceSelector;
    if (!initWithCFSpaceSelector)
        initWithCFSpaceSelector = sel_registerName("_initWithCFURLProtectionSpace:");
    id result = ((id (*)(id, SEL, CFTypeRef))objc_msgSend)([NSURLProtectionSpace alloc], initWithCFSpaceSelector, basic);
    CFRelease(basic);
    if (!result)
        return space;
    [space release];
    return result;
}

WK_POLYFILL_REPLACE_METHODS(NSURLProtectionSpace)
- (NSString *)authenticationMethod
{
    WKURLProtectionSpaceRef cfSpace = wk_cfProtectionSpace(self);
    if (cfSpace && CFURLProtectionSpaceGetAuthenticationScheme(cfSpace) == kWKProtectionSpaceSchemeHTTPBasic)
        return NSURLAuthenticationMethodHTTPBasic;
    return WK_ORIGINAL_METHOD(NSString *, ());
}

- (instancetype)initWithHost:(NSString *)host port:(NSInteger)port protocol:(NSString *)protocol realm:(NSString *)realm authenticationMethod:(NSString *)authenticationMethod
{
    id space = WK_ORIGINAL_METHOD(id, (NSString *, NSInteger, NSString *, NSString *, NSString *),
        host, port, protocol, realm, authenticationMethod);
    if ([authenticationMethod isEqualToString:NSURLAuthenticationMethodHTTPBasic])
        return wk_protectionSpaceAsHTTPBasic(space);
    return space;
}

- (instancetype)initWithProxyHost:(NSString *)host port:(NSInteger)port type:(NSString *)type realm:(NSString *)realm authenticationMethod:(NSString *)authenticationMethod
{
    id space = WK_ORIGINAL_METHOD(id, (NSString *, NSInteger, NSString *, NSString *, NSString *),
        host, port, type, realm, authenticationMethod);
    if ([authenticationMethod isEqualToString:NSURLAuthenticationMethodHTTPBasic])
        return wk_protectionSpaceAsHTTPBasic(space);
    return space;
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

// -[NSURLRequest _webKitPropertyListData] / -_initWithWebKitPropertyListData: (Foundation, 15.0+): a
// request dictionary carrying Foundation properties, CFNetwork body data/file parts and protocol
// properties. WebKit's IPC coder applies its own body and protocol-property restrictions.
//
// "isHTTP" records the presence of CFNetwork's lazily created HTTP message.
// "isMutable" follows the class; the initializer answers an NSMutableURLRequest when the
// dictionary asks for one and an NSURLRequest over the same CFURLRequest otherwise.
typedef const struct _CFURLRequest *WKCFURLRequestRef;
extern CFIndex CFURLRequestGetRequestPriority(WKCFURLRequestRef);
extern CFArrayRef CFURLRequestCopyHTTPRequestBodyParts(WKCFURLRequestRef);
extern void CFURLRequestSetHTTPRequestBodyParts(struct _CFURLRequest *, CFArrayRef);

// 10.9's CFNetwork exports these two; the build SDK's CFNetwork stub does not list them.
WK_SYSTEM_FN("CFNetwork", CFDictionaryRef, _CFURLRequestGetProtocolProperties, (WKCFURLRequestRef));
WK_SYSTEM_FN("CFNetwork", const void *, _CFURLRequestGetHTTPMessage, (WKCFURLRequestRef));

extern void CFURLRequestSetRequestPriority(struct _CFURLRequest *, CFIndex);
extern void _CFURLRequestSetProtocolProperty(struct _CFURLRequest *, CFStringRef, CFTypeRef);

@interface NSURLRequest (WKCFURLRequestInitializer)
- (instancetype)_initWithCFURLRequest:(CFTypeRef)request;
@end

static WKCFURLRequestRef wk_cfURLRequest(id request)
{
    static SEL cfRequestSelector;
    if (!cfRequestSelector)
        cfRequestSelector = sel_registerName("_CFURLRequest");
    return ((WKCFURLRequestRef (*)(id, SEL))objc_msgSend)(request, cfRequestSelector);
}

WK_POLYFILL_ADD_METHODS_ON(NSURLRequest, "NSURLRequest", "NSMutableURLRequest")
- (NSDictionary *)_webKitPropertyListData
{
    WKCFURLRequestRef cfRequest = wk_cfURLRequest(self);
    if (!cfRequest)
        return nil;
    NSMutableDictionary *dictionary = [NSMutableDictionary dictionaryWithCapacity:16];
    [dictionary setObject:@([self isKindOfClass:[NSMutableURLRequest class]]) forKey:@"isMutable"];
    NSURL *url = self.URL;
    if (url)
        [dictionary setObject:url forKey:@"URL"];
    [dictionary setObject:@(self.timeoutInterval) forKey:@"timeout"];
    [dictionary setObject:@((unsigned char)self.cachePolicy) forKey:@"cachePolicy"];
    NSURL *mainDocumentURL = self.mainDocumentURL;
    if (mainDocumentURL)
        [dictionary setObject:mainDocumentURL forKey:@"mainDocumentURL"];
    [dictionary setObject:@(self.HTTPShouldHandleCookies) forKey:@"shouldHandleHTTPCookies"];
    [dictionary setObject:@(wk_requestExplicitFlags((CFTypeRef)cfRequest)) forKey:@"explicitFlags"];
    [dictionary setObject:@(self.allowsCellularAccess) forKey:@"allowCellular"];
    BOOL preventsIdleSystemSleep = ((BOOL (*)(id, SEL))objc_msgSend)(self, sel_registerName("preventsIdleSystemSleep"));
    [dictionary setObject:@(preventsIdleSystemSleep) forKey:@"preventsIdleSystemSleep"];
    [dictionary setObject:@((unsigned char)self.networkServiceType) forKey:@"networkServiceType"];
    [dictionary setObject:@((int)CFURLRequestGetRequestPriority(cfRequest)) forKey:@"requestPriority"];

    BOOL isHTTP = WK_SYSTEM(_CFURLRequestGetHTTPMessage) && WK_SYSTEM(_CFURLRequestGetHTTPMessage)(cfRequest);
    [dictionary setObject:@(isHTTP) forKey:@"isHTTP"];
    if (isHTTP) {
        NSString *method = self.HTTPMethod;
        if (method)
            [dictionary setObject:method forKey:@"httpMethod"];
        NSDictionary *fields = self.allHTTPHeaderFields;
        NSMutableDictionary *headerFields = [NSMutableDictionary dictionaryWithCapacity:fields.count];
        for (NSString *name in fields) {
            NSString *value = [fields objectForKey:name];
            if ([name isKindOfClass:[NSString class]] && [value isKindOfClass:[NSString class]])
                [headerFields setObject:@[ value ] forKey:name];
        }
        [dictionary setObject:headerFields forKey:@"headerFields"];
    }

    NSData *body = self.HTTPBody;
    if (body)
        [dictionary setObject:body forKey:@"body"];
    NSArray *bodyParts = [(NSArray *)CFURLRequestCopyHTTPRequestBodyParts(cfRequest) autorelease];
    if (bodyParts)
        [dictionary setObject:bodyParts forKey:@"bodyParts"];

    NSString *boundInterfaceIdentifier = ((NSString *(*)(id, SEL))objc_msgSend)(self, sel_registerName("boundInterfaceIdentifier"));
    if ([boundInterfaceIdentifier isKindOfClass:[NSString class]])
        [dictionary setObject:boundInterfaceIdentifier forKey:@"boundInterfaceIdentifier"];
    NSArray *fallbackEncodings = ((NSArray *(*)(id, SEL))objc_msgSend)(self, sel_registerName("contentDispositionEncodingFallbackArray"));
    if ([fallbackEncodings isKindOfClass:[NSArray class]])
        [dictionary setObject:fallbackEncodings forKey:@"contentDispositionEncodingFallbackArray"];

    NSDictionary *protocolProperties = WK_SYSTEM(_CFURLRequestGetProtocolProperties) ? (NSDictionary *)WK_SYSTEM(_CFURLRequestGetProtocolProperties)(cfRequest) : nil;
    NSString *siteForCookiesKey = @"_kCFHTTPCookiePolicyPropertySiteForCookies";
    id siteForCookies = [protocolProperties objectForKey:siteForCookiesKey];
    if (siteForCookies && ![siteForCookies isKindOfClass:[NSString class]]) {
        // CFNetwork stores NSURL, but CoreIPCNSURLRequest's dictionary schema requires NSString.
        // An empty URL/string records cross-site; an absent property records unspecified.
        NSMutableDictionary *normalized = [[protocolProperties mutableCopy] autorelease];
        NSString *address = [siteForCookies isKindOfClass:[NSURL class]] ? [siteForCookies absoluteString] : nil;
        if (address)
            [normalized setObject:address forKey:siteForCookiesKey];
        else
            [normalized removeObjectForKey:siteForCookiesKey];
        protocolProperties = normalized;
    }
    if (protocolProperties.count)
        [dictionary setObject:[[protocolProperties copy] autorelease] forKey:@"protocolProperties"];
    return dictionary;
}

- (instancetype)_initWithWebKitPropertyListData:(NSDictionary *)dictionary
{
    [self release];
    NSURL *url = wk_valueOfClass(dictionary, @"URL", [NSURL class]);
    NSNumber *timeout = wk_valueOfClass(dictionary, @"timeout", [NSNumber class]);
    NSNumber *cachePolicy = wk_valueOfClass(dictionary, @"cachePolicy", [NSNumber class]);
    NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:url
        cachePolicy:cachePolicy ? (NSURLRequestCachePolicy)[cachePolicy unsignedCharValue] : NSURLRequestUseProtocolCachePolicy
        timeoutInterval:timeout ? [timeout doubleValue] : 60];
    if (!request)
        return nil;
    struct _CFURLRequest *cfRequest = (struct _CFURLRequest *)wk_cfURLRequest(request);

    NSURL *mainDocumentURL = wk_valueOfClass(dictionary, @"mainDocumentURL", [NSURL class]);
    if (mainDocumentURL)
        request.mainDocumentURL = mainDocumentURL;
    NSNumber *value = wk_valueOfClass(dictionary, @"shouldHandleHTTPCookies", [NSNumber class]);
    if (value && [value boolValue] != request.HTTPShouldHandleCookies)
        request.HTTPShouldHandleCookies = [value boolValue];
    value = wk_valueOfClass(dictionary, @"allowCellular", [NSNumber class]);
    if (value)
        request.allowsCellularAccess = [value boolValue];
    value = wk_valueOfClass(dictionary, @"preventsIdleSystemSleep", [NSNumber class]);
    if (value)
        ((void (*)(id, SEL, BOOL))objc_msgSend)(request, sel_registerName("setPreventsIdleSystemSleep:"), [value boolValue]);
    value = wk_valueOfClass(dictionary, @"networkServiceType", [NSNumber class]);
    if (value)
        request.networkServiceType = (NSURLRequestNetworkServiceType)[value unsignedCharValue];
    value = wk_valueOfClass(dictionary, @"requestPriority", [NSNumber class]);
    // The native priority setter materializes an HTTP message, including for an unchanged default.
    if (value && cfRequest && [value intValue] != CFURLRequestGetRequestPriority(cfRequest))
        CFURLRequestSetRequestPriority(cfRequest, [value intValue]);

    NSString *method = wk_valueOfClass(dictionary, @"httpMethod", [NSString class]);
    if (method)
        request.HTTPMethod = method;
    NSDictionary *headerFields = wk_valueOfClass(dictionary, @"headerFields", [NSDictionary class]);
    for (NSString *name in headerFields) {
        if (![name isKindOfClass:[NSString class]])
            continue;
        id fieldValue = [headerFields objectForKey:name];
        if ([fieldValue isKindOfClass:[NSString class]])
            [request addValue:fieldValue forHTTPHeaderField:name];
        else if ([fieldValue isKindOfClass:[NSArray class]]) {
            for (id item in (NSArray *)fieldValue) {
                if ([item isKindOfClass:[NSString class]])
                    [request addValue:item forHTTPHeaderField:name];
            }
        }
    }

    NSData *body = wk_valueOfClass(dictionary, @"body", [NSData class]);
    if (body)
        request.HTTPBody = body;
    NSArray *bodyParts = wk_valueOfClass(dictionary, @"bodyParts", [NSArray class]);
    if (bodyParts)
        CFURLRequestSetHTTPRequestBodyParts(cfRequest, (CFArrayRef)bodyParts);

    NSString *identifier = wk_valueOfClass(dictionary, @"boundInterfaceIdentifier", [NSString class]);
    if (identifier)
        ((void (*)(id, SEL, NSString *))objc_msgSend)(request, sel_registerName("setBoundInterfaceIdentifier:"), identifier);
    NSArray *encodings = wk_valueOfClass(dictionary, @"contentDispositionEncodingFallbackArray", [NSArray class]);
    if (encodings)
        ((void (*)(id, SEL, NSArray *))objc_msgSend)(request, sel_registerName("setContentDispositionEncodingFallbackArray:"), encodings);

    NSDictionary *protocolProperties = wk_valueOfClass(dictionary, @"protocolProperties", [NSDictionary class]);
    for (id key in protocolProperties) {
        if (![key isKindOfClass:[NSString class]] || !cfRequest)
            continue;
        id property = [protocolProperties objectForKey:key];
        if ([key isEqualToString:@"_kCFHTTPCookiePolicyPropertySiteForCookies"]) {
            // Restore the native URL consumed by ResourceRequestCocoa, including an empty URL.
            if (![property isKindOfClass:[NSString class]])
                continue;
            property = [NSURL URLWithString:property];
            if (!property)
                continue;
        }
        _CFURLRequestSetProtocolProperty(cfRequest, (CFStringRef)key, (CFTypeRef)property);
    }

    NSNumber *explicitFlags = wk_valueOfClass(dictionary, @"explicitFlags", [NSNumber class]);
    if (explicitFlags)
        wk_requestSetExplicitFlags((CFTypeRef)cfRequest, [explicitFlags unsignedShortValue]);

    NSNumber *isMutable = wk_valueOfClass(dictionary, @"isMutable", [NSNumber class]);
    if (isMutable && ![isMutable boolValue]) {
        NSURLRequest *immutable = [[NSURLRequest alloc] _initWithCFURLRequest:(CFTypeRef)cfRequest];
        [request release];
        return (id)immutable;
    }
    return (id)request;
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
static const void *const wk_taskCookieTransformKey = &wk_taskCookieTransformKey;

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
// CNAME cloaking resolution, which 10.9 has no notion of: the getter reports the absence the caller
// already has to handle.
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
// Per-task cookie controls (10.13+). 10.9's CFNetwork has no per-task cookie storage, so the explicit
// storage accepts and discards -- the same thing the real API does on a system without the feature
// behind it. The visible consequence is that tracking prevention cannot swap a task onto a stateless jar.
//
// The transform is a real property, because a getter answers what the setter stored whatever the system
// underneath does with it. 10.13+ CFNetwork runs the block over the cookies a response set before storing
// them; 10.9's CFNetwork keeps that step to itself, and the block's own inputs are absent here anyway --
// -_resolvedCNAMEChain below answers nil because 10.9 resolves no CNAME chain, and with no per-task
// metrics there is no peer address either, so the cap it would decide never has a subject.
// -_setExplicitCookieStorage: has no polyfill: a 10.9 task cannot be re-pointed at a cookie jar once it
// exists (measured -- see NetworkTaskCocoa::blockCookies, which withholds cookies on the request
// instead), and nothing in this port calls it.
- (void)set_cookieTransformCallback:(id)callback
{
    objc_setAssociatedObject(self, wk_taskCookieTransformKey, callback, OBJC_ASSOCIATION_COPY_NONATOMIC);
}
- (id)_cookieTransformCallback
{
    return objc_getAssociatedObject(self, wk_taskCookieTransformKey);
}
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
// +[NSLocale matchedLanguagesFromAvailableLanguages:forPreferredLanguages:] (#68) is 10.12+.
// WTF::indexOfBestMatchingLanguageInList (Source/WTF/wtf/cocoa/LanguageCocoa.mm) sends it
// unconditionally to pick the best caption/subtitle-track language.
//
// We reproduce the 10.12+ contract faithfully: return the availableLanguages that GENUINELY match a
// preferred language (BCP-47 primary language subtag, canonicalized), in preference order, and an EMPTY
// array when none match. Callers read the emptiness as the answer: CaptionUserPreferencesMediaAF
// (matchesDefaultLanguage / sortedTrackListForMenu), AccessibilitySVGObject and WebExtension all test
// `if (![matched count]) return notFound;`, or negate the index.
//
// +[NSBundle preferredLocalizationsFromArray:forPreferences:] (10.0+) supplies the exact and dialect
// ranking, and returns entries verbatim from availableLanguages, with two 10.9 behaviours to handle:
// it falls back to the development region (the first available language) on a total no-match, and it
// matches a regional preference only against the bare language tag -- for preferred "es-MX" against
// available ["es-ES"] it answers with the fallback, where 10.12+ answers "es-ES". So its result is
// filtered down to entries whose primary subtag really is the preferred one, and every remaining
// available language sharing that subtag follows it, in availableLanguages order.
static NSString *wk_primaryLanguageSubtag(NSString *languageTag)
{
    if (!languageTag.length)
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
    // Both filters below also guarantee that every returned entry is a member of availableLanguages,
    // which WTF::indexOfBestMatchingLanguageInList relies on: it resolves languageList.find(firstObject)
    // into an index. (preferredLocalizationsFromArray: echoes the preference itself back when
    // availableLanguages is empty, and that string is not a member.)
    NSMutableArray *matched = [NSMutableArray array];
    for (NSString *preferred in preferredLanguages) {
        NSString *preferredCode = wk_primaryLanguageSubtag(preferred);
        if (!preferredCode)
            continue;
        for (NSString *candidate in [NSBundle preferredLocalizationsFromArray:availableLanguages forPreferences:@[ preferred ]]) {
            if ([preferredCode isEqualToString:wk_primaryLanguageSubtag(candidate)]
                && [availableLanguages containsObject:candidate] && ![matched containsObject:candidate])
                [matched addObject:candidate];
        }
        for (NSString *candidate in availableLanguages) {
            if ([preferredCode isEqualToString:wk_primaryLanguageSubtag(candidate)] && ![matched containsObject:candidate])
                [matched addObject:candidate];
        }
    }
    return matched;
}
@end

// ---------------------------------------------------------------------------------------------------
// +[NSLocale minimizedLanguagesFromLanguages:] (10.15+). WTF::canMinimizeLanguages
// (Source/WTF/wtf/cocoa/LanguageCocoa.mm) gates httpStyleLanguageCode (Source/WTF/wtf/cf/LanguageCF.cpp)
// on it: with it, navigator.language and Accept-Language are canonicalized locale tags; without it that
// function takes the CFBundle Script Manager round-trip its own FIXME calls "very wrong", which has no
// code for a locale the Script Manager never had and answers es-XL for es-MX and zh-TW for zh-HK.
//
// The contract is a locale one, so it holds for any caller: each tag is reduced to the coarsest form
// that still names the same locale -- its CLDR likely-subtags expansion, written as
// language[-Script][-REGION] with a script CLDR would have inferred left off -- and the list keeps its
// order with duplicates removed. That is what shrinks the fingerprinting surface of a preferred-language
// list: a long tail of spellings ("zh-Hant-HK", "zh-HK", "zh_Hant_hk") collapses onto the locale CLDR
// actually distinguishes, and a tag that already is one is returned unchanged.
//
// Extensions, variants and keywords are not part of that locale and do not survive, which is the point:
// "en-US-u-ca-japanese" and "en-US" are one language to a content negotiator.
static NSString *wk_minimizedLanguageTag(NSString *languageTag)
{
    char requested[ULOC_FULLNAME_CAPACITY];
    if (![languageTag getCString:requested maxLength:sizeof(requested) encoding:NSASCIIStringEncoding])
        return languageTag;
    for (char *p = requested; *p; ++p) {
        if (*p == '-')
            *p = '_';
    }

    // A tag that names no language names no locale: likely subtags would answer for "und", which is
    // the root's stand-in and not this caller's language.
    UErrorCode status = U_ZERO_ERROR;
    char requestedLanguage[ULOC_LANG_CAPACITY];
    uloc_getLanguage(requested, requestedLanguage, sizeof(requestedLanguage), &status);
    if (U_FAILURE(status) || !requestedLanguage[0] || !strcmp(requestedLanguage, "und"))
        return languageTag;

    status = U_ZERO_ERROR;
    char maximized[ULOC_FULLNAME_CAPACITY];
    uloc_addLikelySubtags(requested, maximized, sizeof(maximized), &status);
    if (U_FAILURE(status))
        return languageTag;

    char language[ULOC_LANG_CAPACITY] = { 0 };
    char script[ULOC_SCRIPT_CAPACITY] = { 0 };
    char region[ULOC_COUNTRY_CAPACITY] = { 0 };
    status = U_ZERO_ERROR;
    uloc_getLanguage(maximized, language, sizeof(language), &status);
    if (U_FAILURE(status) || !language[0])
        return languageTag;
    status = U_ZERO_ERROR;
    uloc_getScript(maximized, script, sizeof(script), &status);
    if (U_FAILURE(status))
        script[0] = 0;
    status = U_ZERO_ERROR;
    uloc_getCountry(maximized, region, sizeof(region), &status);
    if (U_FAILURE(status))
        region[0] = 0;

    // The script stays only when the language and region do not already imply it -- sr-Latn-RS is
    // Serbian in a script CLDR would not have guessed, sr-Cyrl-RS is the guess itself.
    bool scriptIsImplied = true;
    if (script[0]) {
        char candidate[ULOC_FULLNAME_CAPACITY];
        if (region[0])
            snprintf(candidate, sizeof(candidate), "%s_%s", language, region);
        else
            snprintf(candidate, sizeof(candidate), "%s", language);
        status = U_ZERO_ERROR;
        char candidateMaximized[ULOC_FULLNAME_CAPACITY];
        uloc_addLikelySubtags(candidate, candidateMaximized, sizeof(candidateMaximized), &status);
        char candidateScript[ULOC_SCRIPT_CAPACITY] = { 0 };
        if (U_SUCCESS(status)) {
            status = U_ZERO_ERROR;
            uloc_getScript(candidateMaximized, candidateScript, sizeof(candidateScript), &status);
            if (U_FAILURE(status))
                candidateScript[0] = 0;
        }
        scriptIsImplied = !strcmp(script, candidateScript);
    }

    NSMutableString *tag = [NSMutableString stringWithUTF8String:language];
    if (script[0] && !scriptIsImplied)
        [tag appendFormat:@"-%s", script];
    if (region[0])
        [tag appendFormat:@"-%s", region];
    return tag;
}

WK_POLYFILL_ADD_METHODS(NSLocale)
+ (NSArray<NSString *> *)minimizedLanguagesFromLanguages:(NSArray<NSString *> *)languages
{
    NSMutableArray<NSString *> *minimized = [NSMutableArray arrayWithCapacity:languages.count];
    for (NSString *language in languages) {
        if (!language.length)
            continue;
        NSString *tag = wk_minimizedLanguageTag(language);
        if (![minimized containsObject:tag])
            [minimized addObject:tag];
    }
    return minimized;
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

// The caller-set body length, or -1 when the field is absent or is not a run of digits -- a value that
// does not name a length leaves the request to the implementation this stands in for, whole. Zero is a
// length like any other: an XHR send("") declares it, and spooling that to an empty file is what puts
// "Content-Length: 0" on the wire where a zero-length stream body carries nothing at all.
static long long wk_requestContentLength(NSURLRequest *request)
{
    NSString *value = [request valueForHTTPHeaderField:@"Content-Length"];
    if (![value length])
        return -1;
    for (NSUInteger i = 0; i < value.length; i++) {
        unichar c = [value characterAtIndex:i];
        if (c < '0' || c > '9')
            return -1;
    }
    return [value longLongValue];
}

static NSURL *wk_spoolStreamBodyToFile(NSURLRequest *request, NSString **pathOut, BOOL *streamWasRead)
{
    *streamWasRead = NO;
    NSInputStream *stream = [request HTTPBodyStream];
    long long expected = wk_requestContentLength(request);
    if (!stream || expected < 0)
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
    if (!bodyStream || wk_requestContentLength(request) < 0)
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

// A session's invalidation is requested once. 10.9's -invalidateAndCancel and -finishTasksAndInvalidate
// each queue their work for every call, while __NSCFLocalSessionBridge ignores a repeated request only
// until it has finished the first; the latch carries that contract past the bridge's own. The key is a
// registered selector, so every image carrying this layer reads the same latch, and objc_sync_enter on
// the session is the lock they share.
static BOOL wk_urlSession_claimInvalidation(id session)
{
    static const void *key;
    if (!key)
        key = (const void *)sel_registerName("wk_urlSessionInvalidationRequested");
    objc_sync_enter(session);
    BOOL first = !objc_getAssociatedObject(session, key);
    if (first)
        objc_setAssociatedObject(session, key, (id)kCFBooleanTrue, OBJC_ASSOCIATION_ASSIGN);
    objc_sync_exit(session);
    return first;
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
- (void)invalidateAndCancel
{
    if (wk_urlSession_claimInvalidation(self))
        WK_ORIGINAL_METHOD(void, ());
}
- (void)finishTasksAndInvalidate
{
    if (wk_urlSession_claimInvalidation(self))
        WK_ORIGINAL_METHOD(void, ());
}
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

// NSURLFileTypeMappings (private; 10.9 has it) is what MIMETypeRegistry asks for extension <-> MIME type.
// It reads LaunchServices, which declares no HEIF type on this OS, so those types are answered from the
// declarations -[UTType ...] carries (wk_declared_types.h), as modern Foundation does.
WK_POLYFILL_REPLACE_METHODS_ON(NSObject, "NSURLFileTypeMappings")
- (NSString *)MIMETypeForExtension:(NSString *)extension
{
    const WKDeclaredType *declared = extension ? wkDeclaredTypeForFilenameExtension((__bridge CFStringRef)extension) : NULL;
    if (declared)
        return (__bridge NSString *)declared->mimeType;
    return WK_ORIGINAL_METHOD(NSString *, (NSString *), extension);
}
- (NSString *)preferredExtensionForMIMEType:(NSString *)type
{
    const WKDeclaredType *declared = type ? wkDeclaredTypeForMIMEType((__bridge CFStringRef)type) : NULL;
    if (declared)
        return (__bridge NSString *)declared->filenameExtension;
    return WK_ORIGINAL_METHOD(NSString *, (NSString *), type);
}
- (NSArray *)extensionsForMIMEType:(NSString *)type
{
    const WKDeclaredType *declared = type ? wkDeclaredTypeForMIMEType((__bridge CFStringRef)type) : NULL;
    if (declared)
        return [NSArray arrayWithObject:(__bridge NSString *)declared->filenameExtension];
    return WK_ORIGINAL_METHOD(NSArray *, (NSString *), type);
}
@end

// ---------------------------------------------------------------------------------------------------
// NSURLCache keys an entry by its request's URL and partition. Mavericks hashes only sampled characters of
// that key, so long URLs differing outside the samples share one entry and evict each other; modern
// NSURLCache keeps every distinct URL and partition apart. Each lookup, store and removal names its entry
// by a partition that digests the whole fragment-free URL and the request's own partition.
extern const CFStringRef _kCFURLCachePartitionKey;

static NSURLRequest *wk_urlCacheEntryRequest(NSURLRequest *request)
{
    NSString *spec = request.URL.absoluteString;
    if (!spec)
        return request;
    NSRange fragment = [spec rangeOfString:@"#"];
    if (fragment.location != NSNotFound)
        spec = [spec substringToIndex:fragment.location];
    NSString *partition = [NSURLProtocol propertyForKey:(__bridge NSString *)_kCFURLCachePartitionKey inRequest:request];
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    const char *url = spec.UTF8String;
    CC_SHA256_Update(&context, url, (CC_LONG)strlen(url) + 1);
    if ([partition isKindOfClass:[NSString class]]) {
        const char *name = partition.UTF8String;
        CC_SHA256_Update(&context, name, (CC_LONG)strlen(name));
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    char hex[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    for (unsigned i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i)
        snprintf(hex + i * 2, 3, "%02x", digest[i]);
    NSMutableURLRequest *entryRequest = [[request mutableCopy] autorelease];
    [NSURLProtocol setProperty:[NSString stringWithUTF8String:hex] forKey:(__bridge NSString *)_kCFURLCachePartitionKey inRequest:entryRequest];
    return entryRequest;
}

WK_POLYFILL_REPLACE_METHODS(NSURLCache)
- (NSCachedURLResponse *)cachedResponseForRequest:(NSURLRequest *)request
{
    return WK_ORIGINAL_METHOD(NSCachedURLResponse *, (NSURLRequest *), request ? wk_urlCacheEntryRequest(request) : request);
}
- (void)storeCachedResponse:(NSCachedURLResponse *)cachedResponse forRequest:(NSURLRequest *)request
{
    WK_ORIGINAL_METHOD(void, (NSCachedURLResponse *, NSURLRequest *), cachedResponse, request ? wk_urlCacheEntryRequest(request) : request);
}
- (void)removeCachedResponseForRequest:(NSURLRequest *)request
{
    WK_ORIGINAL_METHOD(void, (NSURLRequest *), request ? wk_urlCacheEntryRequest(request) : request);
}
@end
