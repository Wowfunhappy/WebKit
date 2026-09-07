// HTTP cookie syntax and mutation contracts belong to WebCore; the native jar preserves Safari UI interoperability.
#include "config.h"
#include <WebCore/CocoaCookie.h>
#include <WebCore/Cookie.h>
#include <WebCore/CocoaCurlConnection.h>
#include <WebCore/CookieStorageObserver.h>
#include <WebCore/NetworkStorageSession.h>
#include <WebCore/SameSiteInfo.h>
#include <pal/SessionID.h>
#include <pal/spi/cf/CFNetworkSPI.h>
#include <wtf/Function.h>
#include <wtf/HashSet.h>
#include <wtf/MainThread.h>
#include <wtf/ProcessPrivilege.h>
#include <wtf/WallTime.h>
#include <wtf/text/MakeString.h>
#include <Foundation/Foundation.h>
#include <cmath>
#include <cstdio>
#include <dlfcn.h>

using namespace WebCore;
static unsigned failures;
static unsigned checks;
static void check(bool result, const char* message)
{
    ++checks;
    if (!result) {
        ++failures;
        printf("FAIL %s\n", message);
    }
}

static void parserTests()
{
    URL secure { "https://www.web-platform.test/a/b/index.html"_s };
    auto parse = [&](ASCIILiteral field) { return parseHTTPSetCookie(field, secure); };
    struct Case { ASCIILiteral field; ASCIILiteral name; ASCIILiteral value; ASCIILiteral path; Cookie::SameSitePolicy sameSite; };
    const Case cases[] = {
        { "a=1"_s, "a"_s, "1"_s, "/a/b"_s, Cookie::SameSitePolicy::Lax },
        { "a=1; Path=/; SameSite=Strict"_s, "a"_s, "1"_s, "/"_s, Cookie::SameSitePolicy::Strict },
        { "a=1; Extension=bar, invented=2"_s, "a"_s, "1"_s, "/a/b"_s, Cookie::SameSitePolicy::Lax },
        { "a=1, b=2"_s, "a"_s, "1, b=2"_s, "/a/b"_s, Cookie::SameSitePolicy::Lax },
        { "a=\"x,y\"; Path=/"_s, "a"_s, "\"x,y\""_s, "/"_s, Cookie::SameSitePolicy::Lax },
        { "a=\"x;y\"; Path=/"_s, "a"_s, "\"x"_s, "/"_s, Cookie::SameSitePolicy::Lax },
        { "\ta\t=\t1\t; \tpath\t=\t/zzz"_s, "a"_s, "1"_s, "/zzz"_s, Cookie::SameSitePolicy::Lax },
        { "a=1; Path=/qux; Path=/"_s, "a"_s, "1"_s, "/"_s, Cookie::SameSitePolicy::Lax },
        { "a=1; Path=/; Path=/qux"_s, "a"_s, "1"_s, "/qux"_s, Cookie::SameSitePolicy::Lax },
        { "a=1; Path=/dog; Path="_s, "a"_s, "1"_s, "/a/b"_s, Cookie::SameSitePolicy::Lax },
        { "a=1; SameSite=Lax; SameSite=Strict"_s, "a"_s, "1"_s, "/a/b"_s, Cookie::SameSitePolicy::Strict },
        { "a=1; SameSite=Unknown"_s, "a"_s, "1"_s, "/a/b"_s, Cookie::SameSitePolicy::Lax },
        { "a=1; SameSite=None; Secure"_s, "a"_s, "1"_s, "/a/b"_s, Cookie::SameSitePolicy::None },
        { "a="_s, "a"_s, ""_s, "/a/b"_s, Cookie::SameSitePolicy::Lax },
        { "=value"_s, ""_s, "value"_s, "/a/b"_s, Cookie::SameSitePolicy::Lax },
        { "value"_s, ""_s, "value"_s, "/a/b"_s, Cookie::SameSitePolicy::Lax },
    };
    for (auto& entry : cases) {
        auto cookie = parse(entry.field);
        check(cookie && cookie->name == entry.name && cookie->value == entry.value && cookie->path == entry.path && cookie->sameSite == entry.sameSite, entry.field.characters());
    }
    for (unsigned character = 0; character <= 0x7f; ++character) {
        if (character == '\t' || character >= 0x20 && character != 0x7f)
            continue;
        auto cookie = parseHTTPSetCookie(makeString("a=1; Extension="_s, static_cast<char16_t>(character)), secure);
        check(!cookie, "CTL in an attribute rejects the entire field");
    }
    for (auto field : { ""_s, "="_s, "a=1; SameSite=None"_s, "__Secure-a=1"_s, "__SeCuRe-a=1"_s, "__Host-a=1; Secure; Path=/x"_s, "__Host-a=1; Secure; Path=/; Domain=web-platform.test"_s, "__Http-a=1; Secure"_s, "__Host-Http-a=1; Secure; Path=/"_s })
        check(!parse(field), field.characters());
    check(parse("__Secure-a=1; Secure"_s).has_value(), "secure prefix accepted with Secure");
    check(parse("__Host-a=1; Secure; Path=/"_s).has_value(), "host prefix accepted with root path and no Domain");
    check(parse("__Http-a=1; Secure; HttpOnly"_s).has_value(), "HTTP prefix accepted with Secure and HttpOnly");
    check(!parseHTTPSetCookie("a=1; Secure"_s, URL { "http://web-platform.test/"_s }), "insecure origin cannot set Secure");
    struct DomainCase { ASCIILiteral url; ASCIILiteral field; bool accepted; };
    const DomainCase domains[] = {
        { "http://myserver/x"_s, "a=1"_s, true },
        { "http://myserver/x"_s, "a=1; Domain=myserver"_s, true },
        { "http://myserver/x"_s, "a=1; Domain=.myserver"_s, true },
        { "http://www.example.com/x"_s, "a=1; Domain=example.com"_s, true },
        { "http://www.example.com/x"_s, "a=1; Domain=com"_s, false },
        { "http://www.evil.app/x"_s, "a=1; Domain=app"_s, false },
        { "http://a.web-platform.test/x"_s, "a=1; Domain=test"_s, false },
        { "http://127.0.0.1/x"_s, "a=1"_s, true },
        { "http://127.0.0.1/x"_s, "a=1; Domain=0.0.1"_s, false },
        { "http://www.example.com/x"_s, "a=1; Domain=attacker.com"_s, false },
        { "http://www.example.com/x"_s, "a=1; Domain=attacker.com; Domain=example.com"_s, true },
    };
    for (auto& entry : domains)
        check(parseHTTPSetCookie(entry.field, URL { entry.url }).has_value() == entry.accepted, entry.field.characters());
    auto capped = parse("a=1; Max-Age=99999999999999999999999999999"_s);
    auto nearly = [](double actual, double expected) { return std::abs(actual - expected) < 1000; };
    check(capped && capped->expires && nearly(*capped->expires - capped->created, 400.0 * 24 * 60 * 60 * 1000), "oversized Max-Age saturates at 400 days");
    auto dated = parse("a=1; Expires=Wed, 01 Jan 2094 00:00:00 GMT"_s);
    check(dated && dated->expires && nearly(*dated->expires - dated->created, 400.0 * 24 * 60 * 60 * 1000), "long Expires date is capped");
    auto zero = parse("a=1; Max-Age=0; Expires=Wed, 01 Jan 2094 00:00:00 GMT"_s);
    check(zero && zero->expires && *zero->expires <= zero->created, "Max-Age zero overrides Expires");
    auto repeated = parse("a=1; Max-Age=0; Max-Age=60"_s);
    check(repeated && repeated->expires && nearly(*repeated->expires - repeated->created, 60000), "last valid Max-Age wins");
    auto invalid = parse("a=1; Max-Age=+60"_s);
    check(invalid && invalid->session, "invalid Max-Age does not create an expiry");
    auto longPath = makeString("a=1; Path=/"_s, String::fromUTF8(std::string(1023, 'x')));
    auto boundedAttribute = parseHTTPSetCookie(longPath, secure);
    check(boundedAttribute && boundedAttribute->path.length() == 1024, "1024-byte attribute is accepted");
    auto overflow = makeString("a="_s, String::fromUTF8(std::string(4095, 'x')));
    check(parseHTTPSetCookie(overflow, secure).has_value(), "4096 name/value octets accepted");
    check(!parseHTTPSetCookie(makeString(overflow, 'x'), secure), "4097 name/value octets rejected");
}

// The change listeners the DOM's cookie observers subscribe through. Deliveries arrive on the main
// queue and never carry an HttpOnly cookie.
class ChangeObserver final : public RefCounted<ChangeObserver>, public CookieChangeObserver {
public:
    static Ref<ChangeObserver> create() { return adoptRef(*new ChangeObserver); }
    void ref() const final { RefCounted::ref(); }
    void deref() const final { RefCounted::deref(); }
    Vector<Cookie> added;
    Vector<Cookie> deleted;
    unsigned allDeleted { 0 };
private:
    void cookiesAdded(const String&, const Vector<Cookie>& cookies) final { added.appendVector(cookies); }
    void cookiesDeleted(const String&, const Vector<Cookie>& cookies) final { deleted.appendVector(cookies); }
    void allCookiesDeleted() final { ++allDeleted; }
};

static bool pump(Function<bool()>&& ready, unsigned slices = 100)
{
    for (unsigned i = 0; i < slices && !ready(); ++i)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
    return ready();
}

static void mutationTests()
{
    auto createStorage = reinterpret_cast<CFHTTPCookieStorageRef (*)(CFAllocatorRef, CFDictionaryRef)>(dlsym(RTLD_DEFAULT, "CFHTTPCookieStorageCreateInMemory"));
    RELEASE_ASSERT(createStorage);
    NetworkStorageSession session(PAL::SessionID::generateEphemeralSessionID(), nullptr, adoptCF(createStorage(kCFAllocatorDefault, nullptr)), NetworkStorageSession::IsInMemoryCookieStore::Yes);
    check(&session.cocoaCurlConnectionPool(true) != &session.cocoaCurlConnectionPool(false), "legacy credential policies own separate connection and TLS pools");
    check(&session.cocoaCurlConnectionPool(false) == &session.cocoaCurlConnectionPool(false), "credential-free legacy loads reuse their own pool");
    Ref authenticatedPool { session.cocoaCurlConnectionPool(true) };
    Ref credentiallessPool { session.cocoaCurlConnectionPool(false) };
    session.clearCocoaCurlCredentialState();
    check(&session.cocoaCurlConnectionPool(true) != authenticatedPool.ptr() && &session.cocoaCurlConnectionPool(false) != credentiallessPool.ptr(), "credential clearing retires both connection/TLS pools");
    auto storage = session.nsCookieStorage();
    URL url { "https://cookies.test/"_s };
    CookieStorageObserver observer(storage.get());
    unsigned classic = 0;
    observer.startObserving([&] { ++classic; });
    Ref changes = ChangeObserver::create();
    HashSet<String> subscribed;
    subscribed.add(url.host().toString());
    check(session.startListeningForCookieChangeNotifications(changes.get(), url, url, FrameIdentifier::generate(), PageIdentifier::generate(), ShouldRelaxThirdPartyCookieBlocking::No, IsKnownCrossSiteTracker::No), "a first-party listener subscribes to its host");
    auto cookie = *parseHTTPSetCookie("a=1; Path=/; SameSite=Strict; HttpOnly"_s, url);
    session.setCookie(cookie);
    check(pump([&] { return classic == 1; }), "a stored cookie reports one mutation");
    auto stored = session.getAllCookies();
    check(stored.size() == 1 && stored[0].httpOnly && stored[0].sameSite == Cookie::SameSitePolicy::Strict, "the native jar retains HttpOnly and SameSite");
    check(changes->added.isEmpty(), "an HttpOnly cookie is withheld from a change listener");
    observer.cookiesDidChange();
    check(classic == 2, "a native notification calls the listener again");
    session.setCookiesFromDOM(url, { true, true, false }, url, std::nullopt, std::nullopt, ApplyTrackingPrevention::No, RequiresScriptTrackingPrivacy::No, "a=script; Path=/"_s, ShouldRelaxThirdPartyCookieBlocking::No, IsKnownCrossSiteTracker::No);
    check(session.getAllCookies().size() == 1 && session.getAllCookies()[0].value == "1"_s, "DOM cannot overwrite HttpOnly");
    auto responseCookie = *parseHTTPSetCookie("a=server; Path=/; SameSite=Lax"_s, url);
    session.setCookie(responseCookie, url, url);
    check(session.getAllCookies().size() == 1 && session.getAllCookies()[0].value == "server"_s, "server can replace its HttpOnly cookie");
    check(pump([&] { return changes->added.size() == 1; }) && changes->added[0].value == "server"_s && changes->added[0].sameSite == Cookie::SameSitePolicy::Lax, "a cookie a listener may see arrives with its SameSite");
    bool deleted = false;
    session.deleteCookie(responseCookie, [&] { deleted = true; });
    check(deleted && session.getAllCookies().isEmpty(), "delete completes through the native jar");
    check(pump([&] { return changes->deleted.size() == 1; }) && changes->deleted[0].name == "a"_s, "deletion reports the removed cookie");
    session.setCookie(responseCookie);
    auto expired = *parseHTTPSetCookie("a=gone; Path=/; Max-Age=0"_s, url);
    session.setCookie(expired);
    check(session.getAllCookies().isEmpty() && pump([&] { return changes->deleted.size() == 2; }), "an expired Set-Cookie is a deletion");
    session.setCookies({ responseCookie, *parseHTTPSetCookie("b=2; Path=/"_s, url) }, url, url);
    session.deleteAllCookies([&] { deleted = true; });
    check(session.getAllCookies().isEmpty() && pump([&] { return changes->allDeleted == 1; }), "remove-all reports one all-cookies deletion");
    session.stopListeningForCookieChangeNotifications(changes.get(), subscribed);
    observer.stopObserving();
    auto secureCookie = *parseHTTPSetCookie("secure=original; Path=/login; Secure; SameSite=None"_s, url);
    secureCookie.created -= 60000;
    session.setCookie(secureCookie, url, url);
    auto storedSecure = session.getAllCookies();
    check(storedSecure.size() == 1 && storedSecure[0].sameSite == Cookie::SameSitePolicy::None, "SameSite=None survives the native jar");
    URL insecure { "http://cookies.test/login"_s };
    session.setCookie(*parseHTTPSetCookie("secure=attacker; Path=/login/deeper"_s, insecure), insecure, insecure);
    check(session.getAllCookies().size() == 1, "HTTP cannot overlay a Secure cookie at a deeper path");
    session.setCookie(*parseHTTPSetCookie("secure=expired; Path=/login; Max-Age=0"_s, insecure), insecure, insecure);
    check(session.getAllCookies().size() == 1 && session.getAllCookies()[0].value == "original"_s, "HTTP cannot expire a Secure cookie");
    session.setCookie(*parseHTTPSetCookie("secure=parent; Path=/"_s, insecure), insecure, insecure);
    check(session.getAllCookies().size() == 2, "Secure overlay path comparison permits a parent path");
    session.setCookie(*parseHTTPSetCookie("secure=replacement; Path=/login; Secure; SameSite=None"_s, url), url, url);
    bool creationPreserved = false;
    for (auto& record : session.getAllCookies()) {
        if (record.path == "/login"_s)
            creationPreserved = record.created == storedSecure[0].created && record.value == "replacement"_s;
    }
    check(creationPreserved, "HTTP replacement preserves creation time");
    session.deleteAllCookies([] { });
    unsigned selfUnregisteringCalls = 0;
    observer.startObserving([&] { ++selfUnregisteringCalls; observer.stopObserving(); });
    session.setCookie(responseCookie);
    session.setCookie(*parseHTTPSetCookie("b=2; Path=/"_s, url));
    check(pump([&] { return selfUnregisteringCalls == 1; }), "a classic listener can unregister during its callback");
    Ref later = ChangeObserver::create();
    session.startListeningForCookieChangeNotifications(later.get(), url, url, FrameIdentifier::generate(), PageIdentifier::generate(), ShouldRelaxThirdPartyCookieBlocking::No, IsKnownCrossSiteTracker::No);
    session.setCookie(*parseHTTPSetCookie("c=3; Path=/"_s, url));
    check(pump([&] { return later->added.size() == 1; }) && later->added[0].name == "c"_s, "a subscribed listener receives its host's cookie");
    session.stopListeningForCookieChangeNotifications(later.get(), subscribed);
    session.setCookie(*parseHTTPSetCookie("d=4; Path=/"_s, url));
    check(!pump([&] { return later->added.size() > 1; }, 10), "an unsubscribed listener receives nothing further");
    session.deleteAllCookies([] { });
    session.setCookie(*parseHTTPSetCookie("guard=1; Path=/; HttpOnly"_s, url));
    session.setCookiesFromDOM(url, { true, true, false }, url, std::nullopt, std::nullopt, ApplyTrackingPrevention::No, RequiresScriptTrackingPrivacy::No, "guard=; Path=/; Max-Age=0"_s, ShouldRelaxThirdPartyCookieBlocking::No, IsKnownCrossSiteTracker::No);
    check(session.getAllCookies().size() == 1, "a script cannot expire an HttpOnly cookie");
    session.deleteAllCookies([] { });
    session.setCookie(*parseHTTPSetCookie("guard=1; Path=/; Secure"_s, url), url, url);
    URL insecureOrigin { "http://cookies.test/"_s };
    session.setCookiesFromDOM(insecureOrigin, { true, true, false }, insecureOrigin, std::nullopt, std::nullopt, ApplyTrackingPrevention::No, RequiresScriptTrackingPrivacy::No, "guard=; Path=/; Max-Age=0"_s, ShouldRelaxThirdPartyCookieBlocking::No, IsKnownCrossSiteTracker::No);
    check(session.getAllCookies().size() == 1, "a script on an insecure origin cannot expire a Secure cookie");
    session.deleteAllCookies([] { });
    URL tenant { "https://one.pages.dev/"_s };
    URL anotherTenant { "https://two.pages.dev/"_s };
    auto tenantCookie = *parseHTTPSetCookie("tenant=one; Path=/; SameSite=None; Secure"_s, tenant);
    [storage setCookieAcceptPolicy:NSHTTPCookieAcceptPolicyOnlyFromMainDocumentDomain];
    session.setCookie(tenantCookie, tenant, anotherTenant);
    check(session.getAllCookies().isEmpty(), "HTTP cannot establish cookies from another private-suffix tenant under first-party-only acceptance");
    session.setCookie(tenantCookie, tenant, tenant);
    check(session.getAllCookies().size() == 1, "HTTP can establish first-party cookies under native acceptance policy");
    auto replacement = tenantCookie;
    replacement.value = "updated"_s;
    session.setCookie(replacement, tenant, anotherTenant);
    check(session.getAllCookies().size() == 1 && session.getAllCookies()[0].value == "updated"_s, "native existing-cookie exception survives the transport change");
    [storage setCookieAcceptPolicy:NSHTTPCookieAcceptPolicyNever];
    replacement.value = "blocked"_s;
    session.setCookie(replacement, tenant, tenant);
    check(session.getAllCookies().size() == 1 && session.getAllCookies()[0].value == "updated"_s, "HTTP obeys native never-accept policy");
    [storage setCookieAcceptPolicy:NSHTTPCookieAcceptPolicyAlways];
    session.deleteAllCookies([] { });
    check(!parseHTTPSetCookie("invalid=1; Domain=pages.dev"_s, tenant), "WebCore parser rejects a modern private public suffix");
}

int main()
{
    @autoreleasepool {
        setvbuf(stdout, nullptr, _IONBF, 0);
        WTF::initializeMainThread();
        setProcessPrivileges({ ProcessPrivilege::CanAccessRawCookies });
        NetworkStorageSession::permitProcessToUseCookieAPI(true);
        parserTests();
        mutationTests();
        printf("WebCore cookies: %u checks, FAILED=%u\n", checks, failures);
    }
    return failures ? 1 : 0;
}
