// HTTP cookie syntax and mutation contracts belong to WebCore; the native jar preserves Safari UI interoperability.
#include "config.h"
#include <WebCore/CocoaCookie.h>
#include <WebCore/Cookie.h>
#include <WebCore/CookieJar.h>
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
#include "../../polyfill/mechanism/wk_polyfill.h"
#define WK_POLYFILL_UNIT CookieTests
#include "../../polyfill/mechanism/wk_selref_scope.h"

WK_SYSTEM_FN("CFNetwork", CFArrayRef, CFHTTPCookieStorageCopyCookies, (CFHTTPCookieStorageRef));

@interface NSHTTPCookieStorage (CookieTestSharedStorage)
+ (void)_setSharedHTTPCookieStorage:(NSHTTPCookieStorage *)storage;
@end

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
        { "a=1"_s, "a"_s, "1"_s, "/a/b"_s, Cookie::SameSitePolicy::None },
        { "a=1; Path=/; SameSite=Strict"_s, "a"_s, "1"_s, "/"_s, Cookie::SameSitePolicy::Strict },
        { "a=1; Extension=bar, invented=2"_s, "a"_s, "1"_s, "/a/b"_s, Cookie::SameSitePolicy::None },
        { "a=1, b=2"_s, "a"_s, "1, b=2"_s, "/a/b"_s, Cookie::SameSitePolicy::None },
        { "a=\"x,y\"; Path=/"_s, "a"_s, "\"x,y\""_s, "/"_s, Cookie::SameSitePolicy::None },
        { "a=\"x;y\"; Path=/"_s, "a"_s, "\"x;y\""_s, "/"_s, Cookie::SameSitePolicy::None },
        { "\ta\t=\t1\t; \tpath\t=\t/zzz"_s, "a"_s, "1"_s, "/zzz"_s, Cookie::SameSitePolicy::None },
        { "a=1; Path=/qux; Path=/"_s, "a"_s, "1"_s, "/"_s, Cookie::SameSitePolicy::None },
        { "a=1; Path=/; Path=/qux"_s, "a"_s, "1"_s, "/qux"_s, Cookie::SameSitePolicy::None },
        { "a=1; Path=/dog; Path="_s, "a"_s, "1"_s, "/a/b"_s, Cookie::SameSitePolicy::None },
        { "a=1; SameSite=Lax; SameSite=Strict"_s, "a"_s, "1"_s, "/a/b"_s, Cookie::SameSitePolicy::Strict },
        { "a=1; SameSite=Unknown"_s, "a"_s, "1"_s, "/a/b"_s, Cookie::SameSitePolicy::None },
        { "a=1; SameSite=None; Secure"_s, "a"_s, "1"_s, "/a/b"_s, Cookie::SameSitePolicy::None },
        { "a="_s, "a"_s, ""_s, "/a/b"_s, Cookie::SameSitePolicy::None },
        { "=value"_s, ""_s, "value"_s, "/a/b"_s, Cookie::SameSitePolicy::None },
        { "value"_s, ""_s, "value"_s, "/a/b"_s, Cookie::SameSitePolicy::None },
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
    auto partitioned = parseHTTPSetCookie("chips=1; Secure; SameSite=None; Partitioned"_s, secure, "https://top.test"_s);
    check(partitioned && partitioned->partitionKey == "https://top.test"_s, "Partitioned cookie receives its top-level site key");
    check(!parseHTTPSetCookie("chips=1; SameSite=None; Partitioned"_s, secure, "https://top.test"_s), "Partitioned cookie requires Secure");
    auto disabledPartitioning = parseHTTPSetCookie("chips=1; Secure; Partitioned"_s, secure);
    check(disabledPartitioning && disabledPartitioning->partitionKey.isEmpty(), "disabled CHIPS ignores Partitioned and keeps an unpartitioned cookie");
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
    // HTTP fields carry octets as Latin-1. An unquoted value ends at a C1 control octet; the others are kept.
    for (unsigned character : { 0x80, 0x98, 0x9f }) {
        auto cookie = parseHTTPSetCookie(makeString("octets=ab"_s, static_cast<char16_t>(character), "value; Path=/"_s), secure);
        check(cookie && cookie->value == "ab"_s && cookie->path == "/"_s, "unquoted value ends at a C1 control octet");
    }
    for (unsigned character : { 0xa0, 0xe9, 0xef, 0xff }) {
        auto value = makeString(static_cast<char16_t>(character), "value"_s);
        auto cookie = parseHTTPSetCookie(makeString("octets="_s, value, "; Path=/"_s), secure);
        check(cookie && cookie->value == value, "unquoted non-ASCII cookie value is preserved");
        if (cookie) {
            auto native = cookie->createNSHTTPCookie();
            check(native && Cookie(native.get()).value == value, "native cookie round trip preserves non-ASCII value");
        }
    }
    auto bomBytes = makeString(static_cast<char16_t>(0xef), static_cast<char16_t>(0xbb), static_cast<char16_t>(0xbf), "value"_s);
    auto bomCookie = parseHTTPSetCookie(makeString("octets="_s, bomBytes, "; Path=/"_s), secure);
    check(bomCookie && bomCookie->value == bomBytes, "UTF-8 signature octets retain the upstream cookie encoding");
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
    session.setOptInCookiePartitioningEnabled(true);
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
    session.setCookie(*parseHTTPSetCookie("tenant=; Path=/; Secure; Max-Age=0"_s, tenant), tenant, tenant);
    check(session.getAllCookies().size() == 1 && session.getAllCookies()[0].value == "updated"_s, "an expired HTTP write obeys native never-accept policy");
    [storage setCookieAcceptPolicy:NSHTTPCookieAcceptPolicyAlways];
    session.deleteAllCookies([] { });
    check(!parseHTTPSetCookie("invalid=1; Domain=pages.dev"_s, tenant), "WebCore parser rejects a modern private public suffix");

    URL topA { "https://top-a.test/"_s };
    URL topB { "https://top-b.test/"_s };
    URL embedded { "https://embedded.test/resource"_s };
    auto unpartitioned = *parseHTTPSetCookie("shared=unpartitioned; Path=/; Secure; SameSite=None"_s, embedded);
    auto partitionA = *parseHTTPSetCookie("shared=partition-a; Path=/; Secure; SameSite=None; Partitioned"_s, embedded, cookiePartitionForTopLevelURL(topA));
    auto partitionB = *parseHTTPSetCookie("shared=partition-b; Path=/; Secure; SameSite=None; Partitioned"_s, embedded, cookiePartitionForTopLevelURL(topB));
    auto sameValueInAnotherPartition = partitionA;
    sameValueInAnotherPartition.partitionKey = partitionB.partitionKey;
    check(!(partitionA == sameValueInAnotherPartition), "cookie identity includes its CHIPS partition");
    CFHTTPCookieStorageSetCookieAcceptPolicy(session.cookieStorage().get(), CFHTTPCookieStorageAcceptPolicyOnlyFromMainDocumentDomain);
    session.setCookie(partitionA, embedded, topA);
    check(session.getAllCookies().size() == 1, "main-document acceptance admits a cross-site partitioned record in an empty jar");
    session.deleteCookie(partitionA, [] { });
    CFHTTPCookieStorageSetCookieAcceptPolicy(session.cookieStorage().get(), CFHTTPCookieStorageAcceptPolicyAlways);
    session.setCookie(unpartitioned, embedded, topA);
    session.setCookie(partitionA, embedded, topA);
    session.setCookie(partitionB, embedded, topB);
    [storage setCookieAcceptPolicy:NSHTTPCookieAcceptPolicyNever];
    session.setCookie(*parseHTTPSetCookie("shared=; Path=/; Secure; SameSite=None; Partitioned; Max-Age=0"_s, embedded, cookiePartitionForTopLevelURL(topA)), embedded, topA);
    check(session.getAllCookies().size() == 3, "an expired partitioned HTTP write obeys native never-accept policy");
    [storage setCookieAcceptPolicy:NSHTTPCookieAcceptPolicyAlways];
    auto chips = session.getAllCookies();
    unsigned partitionedCount = 0;
    for (auto& storedCookie : chips)
        partitionedCount += !storedCookie.partitionKey.isEmpty();
    check(chips.size() == 3 && partitionedCount == 2, "unpartitioned and same-key cookies coexist across CHIPS partitions");
    auto nativeCookies = adoptCF(WK_SYSTEM(CFHTTPCookieStorageCopyCookies)(session.cookieStorage().get()));
    auto nativeGetter = wk_original_of(storage.get(), @selector(cookies));
    NSArray *nativeNSCookies = ((NSArray *(*)(id, SEL))nativeGetter.imp)(storage.get(), nativeGetter.sel);
    check(CFArrayGetCount(nativeCookies.get()) == 1 && nativeNSCookies.count == 1, "native CF and NS enumeration of the main jar contain only the unpartitioned cookie");
    auto managedCookies = adoptCF(CFHTTPCookieStorageCopyCookies(session.cookieStorage().get()));
    check(CFArrayGetCount(managedCookies.get()) == 3 && [storage cookies].count == 3, "WebKit CF and NS management enumeration includes both logical partitions");
    NSArray *logicalCookies = [storage cookies];
    NSString *nativeHeader = [NSHTTPCookie requestHeaderFieldsWithCookies:logicalCookies][@"Cookie"];
    check([nativeHeader containsString:@"shared=partition-a"] && [nativeHeader containsString:@"shared=partition-b"] && ![nativeHeader containsString:@"WKPartition-"], "native Foundation header serialization sees logical cookie names");
    NSData *encodedCookies = [NSKeyedArchiver archivedDataWithRootObject:logicalCookies];
    NSArray *decodedCookies = [NSKeyedUnarchiver unarchiveObjectWithData:encodedCookies];
    unsigned decodedPartitions = 0;
    for (NSHTTPCookie *cookie in decodedCookies)
        decodedPartitions += !Cookie(cookie).partitionKey.isEmpty();
    check(decodedCookies.count == 3 && decodedPartitions == 2, "native keyed archives preserve logical names and partition metadata");
    auto expiryUpdate = partitionA;
    expiryUpdate.session = false;
    expiryUpdate.expires = WallTime::now().secondsSinceEpoch().milliseconds() + 3600000;
    session.setCookie(expiryUpdate, embedded, topA);
    session.getAllCookies();
    expiryUpdate.expires = *expiryUpdate.expires + 3600000;
    session.setCookie(expiryUpdate, embedded, topA);
    bool expiryUpdated = false;
    for (auto& cookie : session.getAllCookies()) {
        if (cookie.partitionKey == partitionA.partitionKey)
            expiryUpdated = cookie.expires && std::abs(*cookie.expires - *expiryUpdate.expires) < 1000;
    }
    check(expiryUpdated, "a same-value expiry-only overwrite invalidates the logical projection immediately");
    auto headerFor = [&](const URL& top) {
        return session.cookieRequestHeaderFieldValue(top, { false, false, false }, embedded, std::nullopt, std::nullopt, IncludeSecureCookies::Yes, ApplyTrackingPrevention::Yes, ShouldRelaxThirdPartyCookieBlocking::No, IsKnownCrossSiteTracker::No).first;
    };
    auto sameSiteUpdate = expiryUpdate;
    sameSiteUpdate.sameSite = Cookie::SameSitePolicy::Strict;
    session.setCookie(sameSiteUpdate, embedded, topA);
    check(!headerFor(topA).contains("shared=partition-a"_s), "a same-value SameSite-only overwrite invalidates the decoded policy immediately");
    session.setCookie(expiryUpdate, embedded, topA);
    auto headerA = headerFor(topA);
    auto headerB = headerFor(topB);
    check(headerA.contains("shared=unpartitioned"_s) && headerA.contains("shared=partition-a"_s) && !headerA.contains("shared=partition-b"_s), "top-level site A reads only its partition and unpartitioned cookies");
    check(headerB.contains("shared=unpartitioned"_s) && !headerB.contains("shared=partition-a"_s) && headerB.contains("shared=partition-b"_s), "top-level site B reads only its partition and unpartitioned cookies");
    session.setTrackingPreventionEnabled(true);
    session.setThirdPartyCookieBlockingMode(ThirdPartyCookieBlockingMode::AllExceptPartitioned);
    headerA = headerFor(topA);
    check(!headerA.contains("shared=unpartitioned"_s) && headerA.contains("shared=partition-a"_s) && !headerA.contains("shared=partition-b"_s), "third-party blocking sends only the matching partition");
    CFHTTPCookieStorageSetCookieAcceptPolicy(session.cookieStorage().get(), static_cast<CFHTTPCookieStorageAcceptPolicy>(3));
    auto rejected = partitionA;
    rejected.value = "exclusive-policy-write"_s;
    session.setCookie(rejected, embedded, topA);
    check(headerFor(topA).isEmpty(), "exclusive main-document policy withholds cross-site partitioned reads");
    [storage setCookieAcceptPolicy:NSHTTPCookieAcceptPolicyAlways];
    check(headerFor(topA).contains("shared=partition-a"_s), "exclusive main-document policy also rejects cross-site partitioned writes");
    session.deleteCookie(partitionA, [] { });
    chips = session.getAllCookies();
    check(chips.size() == 2 && !headerFor(topA).contains("shared=partition-a"_s) && headerFor(topB).contains("shared=partition-b"_s), "deleting one partition leaves the others intact");

    session.deleteAllCookies([] { });
    auto createArchive = reinterpret_cast<CFArrayRef (*)(CFAllocatorRef, void *)>(dlsym(RTLD_DEFAULT, "CFHTTPCookieStorageCreateArchive"));
    auto createFromArchive = reinterpret_cast<void* (*)(CFAllocatorRef, CFArrayRef)>(dlsym(RTLD_DEFAULT, "CFHTTPCookieStorageCreateFromArchive"));
    RELEASE_ASSERT(createArchive && createFromArchive);
    NetworkStorageSession archiveSource(PAL::SessionID::generateEphemeralSessionID(), nullptr, adoptCF(createStorage(kCFAllocatorDefault, nullptr)), NetworkStorageSession::IsInMemoryCookieStore::Yes);
    archiveSource.setOptInCookiePartitioningEnabled(true);
    URL archiveURL { "https://embedded.test/scope/resource"_s };
    auto archiveUnpartitioned = *parseHTTPSetCookie("archive=unpartitioned; Path=/scope; Max-Age=3600; Secure; SameSite=None"_s, archiveURL);
    auto archivePartitionA = *parseHTTPSetCookie("archive=partition-a; Path=/scope; Max-Age=3600; Secure; SameSite=None; Partitioned"_s, archiveURL, cookiePartitionForTopLevelURL(topA));
    auto archivePartitionB = *parseHTTPSetCookie("archive=partition-b; Path=/scope; Max-Age=3600; Secure; SameSite=None; Partitioned"_s, archiveURL, cookiePartitionForTopLevelURL(topB));
    archiveSource.setCookie(archiveUnpartitioned);
    archiveSource.setCookie(archivePartitionA, archiveURL, topA);
    archiveSource.setCookie(archivePartitionB, archiveURL, topB);
    check(archiveSource.getAllCookies().size() == 3, "archive source contains unpartitioned and same-key partitioned cookies");
    auto archive = adoptCF(createArchive(kCFAllocatorDefault, archiveSource.cookieStorage().get()));
    check(CFArrayGetCount(archive.get()) == 2, "the storage archive includes the companion archive");
    auto rawArchiveSource = adoptCF(WK_SYSTEM(CFHTTPCookieStorageCopyCookies)(archiveSource.cookieStorage().get()));
    check(CFArrayGetCount(rawArchiveSource.get()) == 1, "archiving leaves partitioned records outside the main jar");
    auto restoredStorage = adoptCF(static_cast<CFHTTPCookieStorageRef>(createFromArchive(kCFAllocatorDefault, archive.get())));
    NetworkStorageSession restored(PAL::SessionID::generateEphemeralSessionID(), nullptr, WTF::move(restoredStorage), NetworkStorageSession::IsInMemoryCookieStore::Yes);
    restored.setOptInCookiePartitioningEnabled(true);
    auto restoredCookies = restored.getAllCookies();
    unsigned restoredPartitionedCount = 0;
    bool restoredFields = restoredCookies.size() == 3;
    for (auto& cookie : restoredCookies) {
        restoredPartitionedCount += !cookie.partitionKey.isEmpty();
        restoredFields &= cookie.name == "archive"_s && cookie.domain == "embedded.test"_s && cookie.path == "/scope"_s;
        const Cookie* sourceCookie = cookie.value == "unpartitioned"_s ? &archiveUnpartitioned
            : cookie.value == "partition-a"_s ? &archivePartitionA
            : cookie.value == "partition-b"_s ? &archivePartitionB : nullptr;
        restoredFields &= sourceCookie && cookie.expires && sourceCookie->expires && std::abs(*cookie.expires - *sourceCookie->expires) < 1000;
    }
    check(restoredFields && restoredPartitionedCount == 2, "archive restoration preserves logical CHIPS identity, scope, expiry and coexistence");
    auto restoredHeader = [&](const URL& top) {
        return restored.cookieRequestHeaderFieldValue(top, { false, false, false }, archiveURL, std::nullopt, std::nullopt, IncludeSecureCookies::Yes, ApplyTrackingPrevention::Yes, ShouldRelaxThirdPartyCookieBlocking::No, IsKnownCrossSiteTracker::No).first;
    };
    check(restoredHeader(topA).contains("archive=unpartitioned"_s) && restoredHeader(topA).contains("archive=partition-a"_s) && !restoredHeader(topA).contains("archive=partition-b"_s), "restored jar selects partition A");
    check(restoredHeader(topB).contains("archive=unpartitioned"_s) && !restoredHeader(topB).contains("archive=partition-a"_s) && restoredHeader(topB).contains("archive=partition-b"_s), "restored jar selects partition B");
    restored.deleteCookie(archivePartitionA, [] { });
    check(restored.getAllCookies().size() == 2 && !restoredHeader(topA).contains("archive=partition-a"_s) && restoredHeader(topB).contains("archive=partition-b"_s), "partition-specific deletion survives archive restoration");
    check(archiveSource.getAllCookies().size() == 3, "restored in-memory companions are independent of the source jar");
    Vector<String> hosts { "embedded.test"_s };
    bool removedHosts = false;
    restored.deleteCookiesForHostnames(hosts.span(), IncludeHttpOnlyCookies::Yes, ScriptWrittenCookiesOnly::No, [&] { removedHosts = true; });
    check(pump([&] { return removedHosts; }) && restored.getAllCookies().isEmpty(), "hostname deletion covers the main jar and companion");
    archiveSource.deleteAllCookiesModifiedSince(WallTime::fromRawSeconds(0), [] { });
    check(archiveSource.getAllCookies().isEmpty(), "since-date deletion covers both jars");

    Ref partitionChanges = ChangeObserver::create();
    check(session.startListeningForCookieChangeNotifications(partitionChanges.get(), embedded, embedded, FrameIdentifier::generate(), PageIdentifier::generate(), ShouldRelaxThirdPartyCookieBlocking::No, IsKnownCrossSiteTracker::No), "partitioned cookie observer subscribes");
    unsigned partitionNotifications = 0;
    observer.startObserving([&] { ++partitionNotifications; });
    session.setCookie(partitionA, embedded, topA);
    check(pump([&] { return partitionChanges->added.size() == 1 && partitionNotifications > 0; }) && partitionChanges->added[0].partitionKey == partitionA.partitionKey, "companion mutations reach both cookie notification paths");
    auto overwrittenPartition = partitionA;
    overwrittenPartition.value = "server-overwrite"_s;
    session.setCookie(overwrittenPartition, embedded, topA);
    check(pump([&] { return partitionChanges->added.size() == 2; }) && partitionChanges->added.last().value == "server-overwrite"_s, "partitioned HTTP overwrite reaches the change listener");
    session.setCookie(*parseHTTPSetCookie("shared=; Path=/; Secure; SameSite=None; Partitioned; Max-Age=0"_s, embedded, partitionA.partitionKey), embedded, topA);
    check(pump([&] { return partitionChanges->deleted.size() == 1; }) && session.getAllCookies().isEmpty(), "partitioned HTTP deletion reaches the change listener");
    session.setCookie(partitionB, embedded, topB);
    session.deleteAllCookies([] { });
    check(session.getAllCookies().isEmpty() && pump([&] { return partitionChanges->allDeleted == 1; }), "remove-all clears the companion and notifies listeners");
    HashSet<String> partitionHosts { "embedded.test"_s };
    session.stopListeningForCookieChangeNotifications(partitionChanges.get(), partitionHosts);
    observer.stopObserving();

    RetainPtr savedSharedStorage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    [NSHTTPCookieStorage _setSharedHTTPCookieStorage:storage.get()];
    {
        NetworkStorageSession sharedSession(PAL::SessionID::defaultSessionID());
        check(!sharedSession.cookieStorage(), "the default-session management path has a null CF storage");
        sharedSession.setCookie(partitionA, embedded, topA);
        auto sharedCookies = sharedSession.getAllCookies();
        check(sharedCookies.size() == 1 && sharedCookies[0].partitionKey == partitionA.partitionKey, "null CF storage enumeration includes its shared companion");
        bool sharedDeleted = false;
        sharedSession.deleteAllCookies([&] { sharedDeleted = true; });
        check(pump([&] { return sharedDeleted; }) && sharedSession.getAllCookies().isEmpty(), "null CF storage remove-all clears its shared companion");
    }
    [NSHTTPCookieStorage _setSharedHTTPCookieStorage:savedSharedStorage.get()];

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
