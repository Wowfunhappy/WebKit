// 10.9 backport: minimal Cocoa-side NetworkStorageSession.
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
#import <wtf/ProcessPrivilege.h>

namespace WebCore {

RetainPtr<NSHTTPCookieStorage> NetworkStorageSession::nsCookieStorage() const
{
    auto cf = cookieStorage();
    if (!cf)
        return [NSHTTPCookieStorage sharedHTTPCookieStorage];
    // 10.9 backport: -_cookieStorage is private; respondsToSelector to check.
    if ([[NSHTTPCookieStorage sharedHTTPCookieStorage] respondsToSelector:@selector(_cookieStorage)]
        && [NSHTTPCookieStorage sharedHTTPCookieStorage]._cookieStorage == cf.get())
        return [NSHTTPCookieStorage sharedHTTPCookieStorage];
    // 10.9 backport: -_initWithCFHTTPCookieStorage: is 10.10+. Fall back to
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

}
