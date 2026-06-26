// MAVERICKS_BACKPORT: minimal Cocoa-side NetworkStorageSession.
// The full upstream implementation depends on cookie/sameSite APIs not present in
// the 10.9 SDK. We provide a working subset that uses NSHTTPCookieStorage directly
// — enough for sites that check `document.cookie` (e.g., iCloud "iCloud requires
// cookies" message, github auxiliary endpoints).

#import "config.h"
#import "NetworkStorageSession.h"

#import "Cookie.h"
#import "ClientOrigin.h"
#import "CookieRequestHeaderFieldProxy.h"
#import "CookieStorageObserver.h"
#import "HTTPCookieAcceptPolicyCocoa.h"
#import <pal/spi/cf/CFNetworkSPI.h>
#import <wtf/BlockObjCExceptions.h>
#import <wtf/CallbackAggregator.h>
#import <wtf/ProcessPrivilege.h>

namespace WebCore {

RetainPtr<NSHTTPCookieStorage> NetworkStorageSession::nsCookieStorage() const
{
    auto cf = cookieStorage();
    if (!cf)
        return [NSHTTPCookieStorage sharedHTTPCookieStorage];
    // MAVERICKS_BACKPORT: -_cookieStorage is private; respondsToSelector to check.
    if ([[NSHTTPCookieStorage sharedHTTPCookieStorage] respondsToSelector:@selector(_cookieStorage)]
        && [NSHTTPCookieStorage sharedHTTPCookieStorage]._cookieStorage == cf.get())
        return [NSHTTPCookieStorage sharedHTTPCookieStorage];
    // MAVERICKS_BACKPORT: -_initWithCFHTTPCookieStorage: is 10.10+. Fall back to
    // sharedHTTPCookieStorage when not available — cookies will share globally
    // across sessions, but at least JS document.cookie reads/writes work.
    if ([NSHTTPCookieStorage instancesRespondToSelector:@selector(_initWithCFHTTPCookieStorage:)])
        return adoptNS([[NSHTTPCookieStorage alloc] _initWithCFHTTPCookieStorage:cf.get()]);
    return [NSHTTPCookieStorage sharedHTTPCookieStorage];
}

CookieStorageObserver& NetworkStorageSession::cookieStorageObserver() const
{
    if (!m_cookieStorageObserver)
        m_cookieStorageObserver = makeUnique<CookieStorageObserver>(nsCookieStorage().get());
    return *m_cookieStorageObserver;
}

// Helper: build NSHTTPCookie properties dict from WebCore::Cookie struct.
static RetainPtr<NSDictionary> cookiePropertiesFromCookieStruct(const Cookie& cookie)
{
    RetainPtr properties = adoptNS([[NSMutableDictionary alloc] init]);
    if (!cookie.name.isEmpty())
        [properties setObject:cookie.name.createNSString().get() forKey:NSHTTPCookieName];
    [properties setObject:cookie.value.createNSString().get() forKey:NSHTTPCookieValue];
    if (!cookie.domain.isEmpty())
        [properties setObject:cookie.domain.createNSString().get() forKey:NSHTTPCookieDomain];
    if (!cookie.path.isEmpty())
        [properties setObject:cookie.path.createNSString().get() forKey:NSHTTPCookiePath];
    if (cookie.secure)
        [properties setObject:@"YES" forKey:NSHTTPCookieSecure];
    return properties;
}

void NetworkStorageSession::setCookie(const Cookie& cookie, const URL&, const URL&)
{
    RetainPtr storage = nsCookieStorage();
    if (!storage)
        return;
    RetainPtr ns = adoptNS([[NSHTTPCookie alloc] initWithProperties:cookiePropertiesFromCookieStruct(cookie).get()]);
    if (ns)
        [storage setCookie:ns.get()];
}

void NetworkStorageSession::setCookie(const Cookie& cookie)
{
    setCookie(cookie, URL { }, URL { });
}

void NetworkStorageSession::setCookies(const Vector<Cookie>& cookies, const URL& url, const URL& mainDocumentURL)
{
    for (auto& c : cookies)
        setCookie(c, url, mainDocumentURL);
}

void NetworkStorageSession::deleteCookie(const URL& /*firstParty*/, const URL& url, const String& cookieName, CompletionHandler<void()>&& completionHandler) const
{
    RetainPtr storage = nsCookieStorage();
    if (storage) {
        RetainPtr nsURL = url.createNSURL();
        NSArray *cookies = [storage cookiesForURL:nsURL.get()];
        for (NSHTTPCookie *c in cookies) {
            if ([[c name] isEqualToString:cookieName.createNSString().get()])
                [storage deleteCookie:c];
        }
    }
    completionHandler();
}

void NetworkStorageSession::deleteCookie(const Cookie& cookie, CompletionHandler<void()>&& completionHandler)
{
    RetainPtr storage = nsCookieStorage();
    if (storage) {
        RetainPtr ns = adoptNS([[NSHTTPCookie alloc] initWithProperties:cookiePropertiesFromCookieStruct(cookie).get()]);
        if (ns)
            [storage deleteCookie:ns.get()];
    }
    completionHandler();
}

void NetworkStorageSession::deleteCookies(const ClientOrigin&, CompletionHandler<void()>&& completionHandler)
{
    completionHandler();
}

void NetworkStorageSession::deleteCookiesForHostnames(const Vector<String>& hostnames, IncludeHttpOnlyCookies includeHttpOnly, ScriptWrittenCookiesOnly, CompletionHandler<void()>&& completionHandler)
{
    RetainPtr storage = nsCookieStorage();
    if (storage) {
        for (auto& hostname : hostnames) {
            NSArray *cookies = [storage cookies];
            for (NSHTTPCookie *c in cookies) {
                if (includeHttpOnly == IncludeHttpOnlyCookies::No && [c isHTTPOnly])
                    continue;
                if ([[c domain] rangeOfString:hostname.createNSString().get()].location != NSNotFound)
                    [storage deleteCookie:c];
            }
        }
    }
    completionHandler();
}

// MAVERICKS_BACKPORT: these cookie-management methods were unimplemented in this minimal Cocoa file
// (only the Curl/Soup backends had them), so they fell back to libpolyfill no-op stubs — leaving
// Safari's "Clear History" unable to clear cookies and cookie-management/getAll APIs empty. Implement
// them directly against the shared NSHTTPCookieStorage (nsCookieStorage()), mirroring the existing
// methods above.
Vector<Cookie> NetworkStorageSession::getAllCookies()
{
    Vector<Cookie> result;
    RetainPtr storage = nsCookieStorage();
    if (!storage)
        return result;
    for (NSHTTPCookie *c in [storage cookies]) {
        Cookie cookie;
        cookie.name = String([c name]);
        cookie.value = String([c value]);
        cookie.domain = String([c domain]);
        cookie.path = String([c path]);
        cookie.secure = [c isSecure];
        cookie.httpOnly = [c isHTTPOnly];
        cookie.session = [c isSessionOnly];
        result.append(std::move(cookie));
    }
    return result;
}

void NetworkStorageSession::getHostnamesWithCookies(HashSet<String>& hostnames)
{
    RetainPtr storage = nsCookieStorage();
    if (!storage)
        return;
    for (NSHTTPCookie *c in [storage cookies]) {
        String domain([c domain]);
        if (!domain.isEmpty())
            hostnames.add(domain);
    }
}

void NetworkStorageSession::deleteAllCookies(CompletionHandler<void()>&& completionHandler)
{
    if (RetainPtr storage = nsCookieStorage()) {
        // Copy first: -deleteCookie: mutates the live -cookies array we would be enumerating.
        RetainPtr<NSArray> all = adoptNS([[storage cookies] copy]);
        for (NSHTTPCookie *c in all.get())
            [storage deleteCookie:c];
    }
    completionHandler();
}

void NetworkStorageSession::deleteAllCookiesModifiedSince(WallTime, CompletionHandler<void()>&& completionHandler)
{
    // MAVERICKS_BACKPORT: NSHTTPCookie exposes no per-cookie modification date and -removeCookiesSinceDate:
    // is 10.10+. Approximate by clearing all cookies — a privacy-safe over-delete for time-ranged
    // "Clear History"; the common case ("all history") wants exactly this.
    deleteAllCookies(std::move(completionHandler));
}

void NetworkStorageSession::hasCookies(const RegistrableDomain& domain, CompletionHandler<void(bool)>&& completionHandler) const
{
    bool found = false;
    if (RetainPtr storage = nsCookieStorage()) {
        auto target = domain.string();
        for (NSHTTPCookie *c in [storage cookies]) {
            String host([c domain]);
            if (host.startsWith('.'))
                host = host.substring(1);
            if (host == target || (host.length() > target.length() && host.endsWith(target) && host[host.length() - target.length() - 1] == '.')) {
                found = true;
                break;
            }
        }
    }
    completionHandler(found);
}

bool NetworkStorageSession::getRawCookies(const URL&, const SameSiteInfo&, const URL& url, std::optional<FrameIdentifier>, std::optional<PageIdentifier>, ApplyTrackingPrevention, ShouldRelaxThirdPartyCookieBlocking, Vector<Cookie>& outCookies) const
{
    RetainPtr storage = nsCookieStorage();
    if (!storage)
        return false;
    RetainPtr nsURL = url.createNSURL();
    NSArray<NSHTTPCookie*> *nsCookies = [storage cookiesForURL:nsURL.get()];
    for (NSHTTPCookie *c in nsCookies) {
        if (![[c name] length])
            continue;
        Cookie cookie;
        cookie.name = String([c name]);
        cookie.value = String([c value]);
        cookie.domain = String([c domain]);
        cookie.path = String([c path]);
        cookie.secure = [c isSecure];
        cookie.httpOnly = [c isHTTPOnly];
        cookie.session = [c isSessionOnly];
        outCookies.append(WTF::move(cookie));
    }
    return true;
}

Vector<Cookie> NetworkStorageSession::domCookiesForHost(const URL& url)
{
    RetainPtr storage = nsCookieStorage();
    if (!storage)
        return { };
    RetainPtr nsURL = url.createNSURL();
    NSArray<NSHTTPCookie*> *nsCookies = [storage cookiesForURL:nsURL.get()];
    Vector<Cookie> result;
    for (NSHTTPCookie *c in nsCookies) {
        if ([c isHTTPOnly])
            continue;
        if (![[c name] length])
            continue;
        Cookie cookie;
        cookie.name = String([c name]);
        cookie.value = String([c value]);
        cookie.domain = String([c domain]);
        cookie.path = String([c path]);
        cookie.secure = [c isSecure];
        cookie.httpOnly = [c isHTTPOnly];
        cookie.session = [c isSessionOnly];
        result.append(WTF::move(cookie));
    }
    return result;
}

#if HAVE(COOKIE_CHANGE_LISTENER_API)
bool NetworkStorageSession::startListeningForCookieChangeNotifications(CookieChangeObserver&, const URL&, const URL&, FrameIdentifier, PageIdentifier, ShouldRelaxThirdPartyCookieBlocking, IsKnownCrossSiteTracker)
{
    return false;
}

void NetworkStorageSession::stopListeningForCookieChangeNotifications(CookieChangeObserver&, const HashSet<String>&)
{
}

void NetworkStorageSession::unregisterCookieChangeListenersIfNecessary()
{
    if (!m_didRegisterCookieListeners)
        return;

    [nsCookieStorage() _setCookiesChangedHandler:nil onQueue:nil];
    [nsCookieStorage() _setCookiesRemovedHandler:nil onQueue:nil];

    [nsCookieStorage() _setSubscribedDomainsForCookieChanges:nil];
    m_didRegisterCookieListeners = false;
}
#endif

// Helper: filter NSHTTPCookies by includeSecureCookies and HTTPOnly, build "k1=v1; k2=v2"
// header-style string. Returns {string, hadSecureCookie}.
static std::pair<String, bool> formatCookies(NSArray<NSHTTPCookie*>* cookies, bool includeSecure, bool excludeHTTPOnly)
{
    StringBuilder builder;
    bool sawSecure = false;
    bool first = true;
    for (NSHTTPCookie *cookie in cookies) {
        if (excludeHTTPOnly && [cookie isHTTPOnly])
            continue;
        if ([cookie isSecure]) {
            if (!includeSecure)
                continue;
            sawSecure = true;
        }
        if (![[cookie name] length])
            continue;
        if (!first)
            builder.append("; "_s);
        first = false;
        builder.append(String([cookie name]));
        builder.append('=');
        builder.append(String([cookie value]));
    }
    return { builder.toString(), sawSecure };
}

std::pair<String, bool> NetworkStorageSession::cookiesForDOM(const URL&, const SameSiteInfo&, const URL& url, std::optional<FrameIdentifier>, std::optional<PageIdentifier>, IncludeSecureCookies includeSecureCookies, ApplyTrackingPrevention, ShouldRelaxThirdPartyCookieBlocking, IsKnownCrossSiteTracker) const
{
    RetainPtr storage = nsCookieStorage();
    if (!storage)
        return { String(), false };
    RetainPtr nsURL = url.createNSURL();
    NSArray<NSHTTPCookie*> *cookies = [storage cookiesForURL:nsURL.get()];
    return formatCookies(cookies, includeSecureCookies == IncludeSecureCookies::Yes, /*excludeHTTPOnly=*/true);
}

std::pair<String, bool> NetworkStorageSession::cookieRequestHeaderFieldValue(const URL&, const SameSiteInfo&, const URL& url, std::optional<FrameIdentifier>, std::optional<PageIdentifier>, IncludeSecureCookies includeSecureCookies, ApplyTrackingPrevention, ShouldRelaxThirdPartyCookieBlocking, IsKnownCrossSiteTracker) const
{
    RetainPtr storage = nsCookieStorage();
    if (!storage)
        return { String(), false };
    RetainPtr nsURL = url.createNSURL();
    NSArray<NSHTTPCookie*> *cookies = [storage cookiesForURL:nsURL.get()];
    // HTTP request: include HTTPOnly cookies.
    return formatCookies(cookies, includeSecureCookies == IncludeSecureCookies::Yes, /*excludeHTTPOnly=*/false);
}

std::pair<String, bool> NetworkStorageSession::cookieRequestHeaderFieldValue(const CookieRequestHeaderFieldProxy& proxy) const
{
    return cookieRequestHeaderFieldValue(proxy.firstParty, proxy.sameSiteInfo, proxy.url, proxy.frameID, proxy.pageID, proxy.includeSecureCookies, ApplyTrackingPrevention::Yes, ShouldRelaxThirdPartyCookieBlocking::No, IsKnownCrossSiteTracker::No);
}

void NetworkStorageSession::setCookiesFromDOM(const URL&, const SameSiteInfo&, const URL& url, std::optional<FrameIdentifier>, std::optional<PageIdentifier>, ApplyTrackingPrevention, RequiresScriptTrackingPrivacy, const String& cookieString, ShouldRelaxThirdPartyCookieBlocking, IsKnownCrossSiteTracker) const
{
    if (cookieString.isEmpty())
        return;
    RetainPtr storage = nsCookieStorage();
    if (!storage)
        return;
    RetainPtr nsURL = url.createNSURL();
    // Parse the cookieString as a Set-Cookie header. NSHTTPCookie does the heavy lifting.
    NSDictionary *headerFields = @{ @"Set-Cookie": cookieString.createNSString().get() };
    NSArray<NSHTTPCookie*> *cookies = [NSHTTPCookie cookiesWithResponseHeaderFields:headerFields forURL:nsURL.get()];
    for (NSHTTPCookie *cookie in cookies) {
        // DOM-set cookies must not be HTTPOnly.
        if ([cookie isHTTPOnly])
            continue;
        if (![[cookie name] length])
            continue;
        [storage setCookie:cookie];
    }
}

// MAVERICKS_BACKPORT: restored upstream Cocoa definitions (dropped during backport); referenced by WK2 NetworkProcess.
// getCookies / cookieAcceptPolicy are restored verbatim from upstream (83b24ce), along with their self-contained
// static helpers nsCookiesToCookieVector and httpCookieAcceptPolicy. setAllCookiesToSameSiteStrict and setCookieFromDOM
// keep upstream's logic but route cookie writes/deletes through this file's public-API nsCookieStorage() path
// instead of upstream's deleteHTTPCookie/setHTTPCookiesForURL, which rely on 10.10+ CFNetwork SPI absent on 10.9.
static Vector<Cookie> nsCookiesToCookieVector(NSArray<NSHTTPCookie *> *nsCookies, NOESCAPE const Function<bool(NSHTTPCookie *)>& filter = { })
{
    Vector<Cookie> cookies;
    cookies.reserveInitialCapacity(nsCookies.count);
    for (NSHTTPCookie *nsCookie in nsCookies) {
        @autoreleasepool {
            if (!filter || filter(nsCookie))
                cookies.append(nsCookie);
        }
    }
    if (filter)
        cookies.shrinkToFit();
    return cookies;
}

Vector<Cookie> NetworkStorageSession::getCookies(const URL& url)
{
    ASSERT(hasProcessPrivilege(ProcessPrivilege::CanAccessRawCookies));
    return nsCookiesToCookieVector(retainPtr([nsCookieStorage() cookiesForURL:url.createNSURL().get()]).get());
}

static NSHTTPCookieAcceptPolicy httpCookieAcceptPolicy(CFHTTPCookieStorageRef cookieStorage)
{
    ASSERT(hasProcessPrivilege(ProcessPrivilege::CanAccessRawCookies));

    if (!cookieStorage)
        return [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookieAcceptPolicy];

    return static_cast<NSHTTPCookieAcceptPolicy>(CFHTTPCookieStorageGetCookieAcceptPolicy(cookieStorage));
}

HTTPCookieAcceptPolicy NetworkStorageSession::cookieAcceptPolicy() const
{
    BEGIN_BLOCK_OBJC_EXCEPTIONS
    auto policy = httpCookieAcceptPolicy(cookieStorage().get());
    return toHTTPCookieAcceptPolicy(policy);
    END_BLOCK_OBJC_EXCEPTIONS

    return HTTPCookieAcceptPolicy::Never;
}

// MAVERICKS_BACKPORT: -[NSHTTPCookie sameSitePolicy]/NSHTTPCookieSameSitePolicy/NSHTTPCookieSameSiteStrict are 10.13+.
// Guard with respondsToSelector so we still iterate cleanly on 10.9 (where SameSite has no effect) and only
// rewrite cookies when the API is actually present.
void NetworkStorageSession::setAllCookiesToSameSiteStrict(const RegistrableDomain& domain, CompletionHandler<void()>&& completionHandler)
{
    ASSERT(hasProcessPrivilege(ProcessPrivilege::CanAccessRawCookies));

    RetainPtr storage = nsCookieStorage();
    if (!storage)
        return completionHandler();

    if (![NSHTTPCookie instancesRespondToSelector:@selector(sameSitePolicy)])
        return completionHandler();

    RetainPtr<NSMutableArray<NSHTTPCookie *>> oldCookiesToDelete = adoptNS([[NSMutableArray alloc] init]);
    RetainPtr<NSMutableArray<NSHTTPCookie *>> newCookiesToAdd = adoptNS([[NSMutableArray alloc] init]);

    for (NSHTTPCookie *nsCookie in [storage cookies]) {
        if (RegistrableDomain::uncheckedCreateFromHost(nsCookie.domain) == domain && nsCookie.sameSitePolicy != NSHTTPCookieSameSiteStrict) {
            [oldCookiesToDelete addObject:nsCookie];
            RetainPtr<NSMutableDictionary<NSHTTPCookiePropertyKey, id>> mutableProperties = adoptNS([[nsCookie properties] mutableCopy]);
            mutableProperties.get()[NSHTTPCookieSameSitePolicy] = NSHTTPCookieSameSiteStrict;
            RetainPtr strictCookie = adoptNS([[NSHTTPCookie alloc] initWithProperties:mutableProperties.get()]);
            if (strictCookie)
                [newCookiesToAdd addObject:strictCookie.get()];
        }
    }

    auto aggregator = CallbackAggregator::create([completionHandler = WTF::move(completionHandler), newCookiesToAdd = WTF::move(newCookiesToAdd), storage = RetainPtr { storage }] () mutable {
        BEGIN_BLOCK_OBJC_EXCEPTIONS
        for (NSHTTPCookie *newCookie in newCookiesToAdd.get())
            [storage setCookie:newCookie];
        END_BLOCK_OBJC_EXCEPTIONS
        completionHandler();
    });

    BEGIN_BLOCK_OBJC_EXCEPTIONS
    for (NSHTTPCookie *oldCookie in oldCookiesToDelete.get()) {
        [storage deleteCookie:oldCookie];
        UNUSED_PARAM(aggregator);
    }
    END_BLOCK_OBJC_EXCEPTIONS
}

// Restored upstream static helper adjustScriptWrittenCookie (and the capExpiryOfPersistentCookie it calls, whose
// static declaration in NetworkStorageSession.h was left undefined by the backport). Both use only public NSHTTPCookie
// API and are 10.9-safe.
RetainPtr<NSHTTPCookie> NetworkStorageSession::capExpiryOfPersistentCookie(NSHTTPCookie *cookie, Seconds cap)
{
    if ([cookie isSessionOnly])
        return cookie;

    if (!cookie.expiresDate || cookie.expiresDate.timeIntervalSinceNow > cap.seconds()) {
        auto properties = adoptNS([[cookie properties] mutableCopy]);
        auto date = adoptNS([[NSDate alloc] initWithTimeIntervalSinceNow:cap.seconds()]);
        [properties setObject:date.get() forKey:NSHTTPCookieExpires];
        return adoptNS([[NSHTTPCookie alloc] initWithProperties:properties.get()]);
    }
    return cookie;
}

static RetainPtr<NSHTTPCookie> adjustScriptWrittenCookie(NSHTTPCookie *initialCookie, std::optional<Seconds> cappedLifetime)
{
    if (!initialCookie)
        return nil;

    RetainPtr cookie = initialCookie;

    // <rdar://problem/5632883> On 10.5, NSHTTPCookieStorage would store an empty cookie,
    // which would be sent as "Cookie: =". We have a workaround in setCookies() to prevent
    // that, but we also need to avoid sending cookies that were previously stored, and
    // there's no harm to doing this check because such a cookie is never valid.
    if (![[cookie name] length])
        return nil;

    if ([cookie isHTTPOnly])
        return nil;

    // Cap lifetime of persistent, client-side cookies.
    if (cappedLifetime)
        return NetworkStorageSession::capExpiryOfPersistentCookie(cookie.get(), *cappedLifetime);

    return cookie;
}

bool NetworkStorageSession::setCookieFromDOM(const URL& firstParty, const SameSiteInfo& sameSiteInfo, const URL& url, std::optional<FrameIdentifier> frameID, std::optional<PageIdentifier> pageID, ApplyTrackingPrevention applyTrackingPrevention, RequiresScriptTrackingPrivacy requiresScriptTrackingPrivacy, const Cookie& cookie, ShouldRelaxThirdPartyCookieBlocking shouldRelaxThirdPartyCookieBlocking, IsKnownCrossSiteTracker isKnownCrossSiteTracker) const
{
    ASSERT(hasProcessPrivilege(ProcessPrivilege::CanAccessRawCookies));

    BEGIN_BLOCK_OBJC_EXCEPTIONS

    auto thirdPartyCookieBlockingDecision = thirdPartyCookieBlockingDecisionForRequest(firstParty, url, frameID, pageID, shouldRelaxThirdPartyCookieBlocking, isKnownCrossSiteTracker);
    if (applyTrackingPrevention == ApplyTrackingPrevention::Yes && shouldBlockCookies(thirdPartyCookieBlockingDecision))
        return false;

    auto expiryCap = clientSideCookieCap(RegistrableDomain { firstParty }, requiresScriptTrackingPrivacy, pageID);
    RetainPtr nshttpCookie = adjustScriptWrittenCookie(cookie.createNSHTTPCookie().get(), expiryCap);
    if (!nshttpCookie)
        return false;

    RetainPtr storage = nsCookieStorage();
    if (!storage)
        return false;
    [storage setCookie:nshttpCookie.get()];
    return true;

    END_BLOCK_OBJC_EXCEPTIONS
    return false;
}

std::optional<Vector<Cookie>> NetworkStorageSession::cookiesForDOMAsVector(const URL& firstParty, const SameSiteInfo& sameSiteInfo, const URL& url, std::optional<FrameIdentifier> frameID, std::optional<PageIdentifier> pageID, IncludeSecureCookies includeSecureCookies, ApplyTrackingPrevention applyTrackingPrevention, ShouldRelaxThirdPartyCookieBlocking relaxBlocking, IsKnownCrossSiteTracker tracker, CookieStoreGetOptions&&) const
{
    RetainPtr storage = nsCookieStorage();
    if (!storage)
        return Vector<Cookie>{};
    RetainPtr nsURL = url.createNSURL();
    NSArray<NSHTTPCookie*> *nsCookies = [storage cookiesForURL:nsURL.get()];
    Vector<Cookie> result;
    for (NSHTTPCookie *c in nsCookies) {
        if ([c isHTTPOnly])
            continue;
        if (includeSecureCookies == IncludeSecureCookies::No && [c isSecure])
            continue;
        if (![[c name] length])
            continue;
        Cookie cookie;
        cookie.name = String([c name]);
        cookie.value = String([c value]);
        cookie.domain = String([c domain]);
        cookie.path = String([c path]);
        cookie.secure = [c isSecure];
        cookie.httpOnly = [c isHTTPOnly];
        cookie.session = [c isSessionOnly];
        result.append(WTF::move(cookie));
    }
    return result;
}

NetworkStorageSession::~NetworkStorageSession()
{
#if HAVE(COOKIE_CHANGE_LISTENER_API)
    unregisterCookieChangeListenersIfNecessary();
#endif
    clearCookiesVersionChangeCallbacks();
}

RetainPtr<CFURLStorageSessionRef> createPrivateStorageSession(CFStringRef identifier, std::optional<HTTPCookieAcceptPolicy> cookieAcceptPolicy, NetworkStorageSession::ShouldDisableCFURLCache shouldDisableCFURLCache)
{
    const void* sessionPropertyKeys[] = { _kCFURLStorageSessionIsPrivate };
    const void* sessionPropertyValues[] = { kCFBooleanTrue };
    auto sessionProperties = adoptCF(CFDictionaryCreate(kCFAllocatorDefault, sessionPropertyKeys, sessionPropertyValues, sizeof(sessionPropertyKeys) / sizeof(*sessionPropertyKeys), &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
    auto storageSession = adoptCF(_CFURLStorageSessionCreate(kCFAllocatorDefault, identifier, sessionProperties.get()));

    if (!storageSession)
        return nullptr;

    if (shouldDisableCFURLCache == NetworkStorageSession::ShouldDisableCFURLCache::Yes)
        _CFURLStorageSessionDisableCache(storageSession.get());

    // The private storage session should have the same properties as the default storage session,
    // with the exception that it should be in-memory only storage.

    // FIXME 9199649: If any of the storages do not exist, do no use the storage session.
    // This could occur if there is an issue figuring out where to place a storage on disk (e.g. the
    // sandbox does not allow CFNetwork access).

    if (shouldDisableCFURLCache == NetworkStorageSession::ShouldDisableCFURLCache::No) {
        auto cache = adoptCF(_CFURLStorageSessionCopyCache(kCFAllocatorDefault, storageSession.get()));
        if (!cache)
            return nullptr;

        CFURLCacheSetMemoryCapacity(cache.get(), [[NSURLCache sharedURLCache] memoryCapacity]);
    }

    auto cookieStorage = adoptCF(_CFURLStorageSessionCopyCookieStorage(kCFAllocatorDefault, storageSession.get()));
    if (!cookieStorage)
        return nullptr;

    NSHTTPCookieAcceptPolicy nsCookieAcceptPolicy;
    if (cookieAcceptPolicy)
        nsCookieAcceptPolicy = toNSHTTPCookieAcceptPolicy(*cookieAcceptPolicy);
    else
        nsCookieAcceptPolicy = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookieAcceptPolicy];

    // FIXME: Use _CFHTTPCookieStorageGetDefault when USE(CFNETWORK) is defined in WebKit for consistency.
    CFHTTPCookieStorageSetCookieAcceptPolicy(cookieStorage.get(), nsCookieAcceptPolicy);

    return storageSession;
}

}
