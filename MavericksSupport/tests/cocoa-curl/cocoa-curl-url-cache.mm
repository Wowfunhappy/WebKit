// WebKitLegacy ResourceHandle cache policy, revalidation and replacement over NSURLCache.
// Server hit counts distinguish cached responses from network loads; private sessions
// must retain independent entries.
#include "config.h"
#include "NetworkingContext.h"
#include <WebCore/CocoaCurlTransfer.h>
#include <WebCore/NetworkStorageSession.h>
#include <WebCore/ResourceError.h>
#include <WebCore/ResourceHandle.h>
#include <WebCore/ResourceHandleClient.h>
#include <WebCore/ResourceRequest.h>
#include <WebCore/ResourceResponse.h>
#include <WebCore/SecurityOrigin.h>
#include <WebCore/SharedBuffer.h>
#include <pal/SessionID.h>
#include <wtf/MainThread.h>
#include <wtf/ProcessPrivilege.h>
#include <Foundation/Foundation.h>
#include <dlfcn.h>
#include <cstdio>
using namespace WebCore;
static unsigned failures;
static void check(bool value, const char* message)
{
    if (!value) {
        ++failures;
        printf("FAIL %s\n", message);
    }
}
class Context final : public NetworkingContext {
public:
    static Ref<Context> create(NetworkStorageSession& storage) { return adoptRef(*new Context(storage)); }
    NetworkStorageSession* storageSession() const final { return &m_storage; }
    bool shouldClearReferrerOnHTTPSToHTTPRedirect() const final { return true; }
    bool localFileContentSniffingEnabled() const final { return false; }
    RetainPtr<CFDataRef> sourceApplicationAuditData() const final { return nullptr; }
    ResourceError blockedError(const ResourceRequest& request) const final { return ResourceError(NSURLErrorDomain, NSURLErrorCannotLoadFromNetwork, request.url(), "Blocked by the test context"_s); }
private:
    explicit Context(NetworkStorageSession& storage) : m_storage(storage) { }
    NetworkStorageSession& m_storage;
};
struct Load {
    int error { 0 };
    int status { 0 };
    String body;
    String revalidated;
    String responseURL;
    String nativeResponseURL;
    unsigned willCache { 0 };
    unsigned redirects { 0 };
};
class Probe final : public ResourceHandleClient {
public:
    Load run(Context& context, const String& path, ResourceRequestCachePolicy policy, const String& varyValue = { }, const String& cacheControl = { }, const String& validator = { })
    {
        ResourceRequest request(URL { makeString("http://127.0.0.1:18981"_s, path) });
        request.setTimeoutInterval(10);
        request.setCachePolicy(policy);
        if (!varyValue.isNull())
            request.setHTTPHeaderField("X-Cache-Test"_s, varyValue);
        if (!cacheControl.isNull())
            request.setHTTPHeaderField("Cache-Control"_s, cacheControl);
        if (!validator.isNull())
            request.setHTTPHeaderField("If-None-Match"_s, validator);
        // WebKitLegacy delegates can return a mutable copy of every native request.
        auto delegateRequest = adoptNS([request.nsURLRequest(HTTPBodyUpdatePolicy::UpdateHTTPBody) mutableCopy]);
        request.updateFromDelegatePreservingOldProperties(ResourceRequest(delegateRequest.get()));
        auto handle = ResourceHandle::create(&context, request, this, false, true, ContentEncodingSniffingPolicy::Default, nullptr, true);
        check(!!handle, "ResourceHandle created");
        if (!handle)
            return m_load;
        auto deadline = adoptCF(CFRunLoopTimerCreateWithHandler(nullptr, CFAbsoluteTimeGetCurrent() + 15, 0, 0, 0, ^(CFRunLoopTimerRef) {
            check(false, "ResourceHandle deadline");
            CFRunLoopStop(CFRunLoopGetMain());
        }));
        CFRunLoopAddTimer(CFRunLoopGetMain(), deadline.get(), kCFRunLoopDefaultMode);
        CFRunLoopRun();
        CFRunLoopTimerInvalidate(deadline.get());
        return m_load;
    }
private:
    void willSendRequestAsync(ResourceHandle*, ResourceRequest&& request, ResourceResponse&&, CompletionHandler<void(ResourceRequest&&)>&& completion) final
    {
        ++m_load.redirects;
        completion(WTF::move(request));
    }
    void didReceiveResponseAsync(ResourceHandle*, ResourceResponse&& response, CompletionHandler<void()>&& completion) final
    {
        m_load.status = response.httpStatusCode();
        m_load.responseURL = response.url().string();
        m_load.nativeResponseURL = String([[response.nsURLResponse() URL] absoluteString]);
        m_load.revalidated = response.httpHeaderField("X-Revalidated"_s);
        completion();
    }
    void didReceiveData(ResourceHandle*, const SharedBuffer& data, int) final { m_body.append(data.span()); }
    void willCacheResponseAsync(ResourceHandle*, NSCachedURLResponse *response, CompletionHandler<void(NSCachedURLResponse *)>&& completion) final
    {
        ++m_load.willCache;
        completion(response);
    }
    void didFinishLoading(ResourceHandle*, const NetworkLoadMetrics&) final
    {
        m_load.body = String(m_body.span());
        CFRunLoopStop(CFRunLoopGetCurrent());
    }
    void didFail(ResourceHandle*, const ResourceError& failure) final
    {
        m_load.error = failure.errorCode();
        CFRunLoopStop(CFRunLoopGetCurrent());
    }
#if USE(PROTECTION_SPACE_AUTH_CALLBACK)
    void canAuthenticateAgainstProtectionSpaceAsync(ResourceHandle*, const ProtectionSpace&, CompletionHandler<void(bool)>&& completion) final { completion(true); }
#endif
    Load m_load;
    Vector<uint8_t> m_body;
};
static unsigned hits(const String& name)
{
    NSString *url = [NSString stringWithFormat:@"http://127.0.0.1:18981/cache/hits/%@", name.createNSString().get()];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10];
    NSData *data = [NSURLConnection sendSynchronousRequest:request returningResponse:nil error:nil];
    return [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] intValue];
}
static void expect(ASCIILiteral label, bool passed)
{
    check(passed, label.characters());
    printf("%s %s\n", label.characters(), passed ? "PASS" : "FAIL");
}
// Disk-backed NSURLCache processes individual removals on its maintenance run loop.
static bool waitForRemoval(NetworkStorageSession& storage, const ResourceRequest& request)
{
    __block bool removed = false;
    auto deadline = CFAbsoluteTimeGetCurrent() + 15;
    auto timer = adoptCF(CFRunLoopTimerCreateWithHandler(nullptr, CFAbsoluteTimeGetCurrent(), 0.1, 0, 0, ^(CFRunLoopTimerRef) {
        removed = !lookUpCocoaCurlCachedResponse(&storage, request).entry;
        if (removed || CFAbsoluteTimeGetCurrent() >= deadline)
            CFRunLoopStop(CFRunLoopGetCurrent());
    }));
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer.get(), kCFRunLoopDefaultMode);
    CFRunLoopRun();
    CFRunLoopTimerInvalidate(timer.get());
    return removed;
}

int main()
{
    @autoreleasepool {
        WTF::initializeMainThread();
        setProcessPrivileges({ ProcessPrivilege::CanAccessRawCookies, ProcessPrivilege::CanAccessCredentials });
        NetworkStorageSession::permitProcessToUseCookieAPI(true);
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
        RetainPtr cache = adoptNS([[NSURLCache alloc] initWithMemoryCapacity:512 * 1024 diskCapacity:1024 * 1024 diskPath:directory]);
        [NSURLCache setSharedURLCache:cache.get()];
        auto createStorage = reinterpret_cast<CFHTTPCookieStorageRef (*)(CFAllocatorRef, CFDictionaryRef)>(dlsym(RTLD_DEFAULT, "CFHTTPCookieStorageCreateInMemory"));
        RELEASE_ASSERT(createStorage);
        // Unique paths per run: the fixture's hit counts outlive a single run.
        String run = String([[NSUUID UUID] UUIDString]);
        auto path = [&](ASCIILiteral name) { return makeString("/cache/"_s, name, '/', run); };
        auto name = [&](ASCIILiteral name) { return makeString(name, '/', run); };
        NetworkStorageSession storage(PAL::SessionID::defaultSessionID(), nullptr, adoptCF(createStorage(kCFAllocatorDefault, nullptr)), NetworkStorageSession::IsInMemoryCookieStore::Yes);
        Ref context = Context::create(storage);

        auto miss = Probe { }.run(context, path("fresh"_s), ResourceRequestCachePolicy::ReturnCacheDataDontLoad);
        expect("cache-only miss fails with NSURLErrorResourceUnavailable"_s, miss.error == NSURLErrorResourceUnavailable && !hits(name("fresh"_s)));
        auto onlyIfCached = Probe { }.run(context, path("fresh"_s), ResourceRequestCachePolicy::UseProtocolCachePolicy, { }, "only-if-cached"_s);
        expect("only-if-cached does not send a cache miss to the network"_s, onlyIfCached.error == NSURLErrorResourceUnavailable && !hits(name("fresh"_s)));

        auto stored = Probe { }.run(context, path("fresh"_s), ResourceRequestCachePolicy::UseProtocolCachePolicy);
        expect("a cacheable response is offered to willCacheResponse"_s, !stored.error && stored.status == 200 && stored.body == "CACHED"_s && stored.willCache == 1);
        auto fresh = Probe { }.run(context, path("fresh"_s), ResourceRequestCachePolicy::UseProtocolCachePolicy);
        expect("a fresh entry answers without the network"_s, fresh.status == 200 && fresh.body == "CACHED"_s && !fresh.willCache && hits(name("fresh"_s)) == 1);
        auto cacheOnly = Probe { }.run(context, path("fresh"_s), ResourceRequestCachePolicy::ReturnCacheDataDontLoad);
        expect("a cache-only load answers from a stored entry"_s, cacheOnly.status == 200 && cacheOnly.body == "CACHED"_s && hits(name("fresh"_s)) == 1);
        auto reload = Probe { }.run(context, path("fresh"_s), ResourceRequestCachePolicy::ReloadIgnoringCacheData);
        expect("a reload reaches the network and stores its response"_s, reload.status == 200 && reload.willCache == 1 && hits(name("fresh"_s)) == 2);

        auto directivesPath = makeString(path("fresh"_s), "-directives"_s);
        auto directivesName = makeString(name("fresh"_s), "-directives"_s);
        Probe { }.run(context, directivesPath, ResourceRequestCachePolicy::UseProtocolCachePolicy);
        auto noCache = Probe { }.run(context, directivesPath, ResourceRequestCachePolicy::UseProtocolCachePolicy, { }, "no-cache"_s);
        expect("request no-cache reloads a fresh response"_s, noCache.body == "CACHED"_s && noCache.willCache == 1 && hits(directivesName) == 2);
        auto maxAgeZero = Probe { }.run(context, directivesPath, ResourceRequestCachePolicy::UseProtocolCachePolicy, { }, "max-age=0"_s);
        expect("request max-age zero reloads a fresh response"_s, maxAgeZero.body == "CACHED"_s && maxAgeZero.willCache == 1 && hits(directivesName) == 3);
        auto maxAge = Probe { }.run(context, directivesPath, ResourceRequestCachePolicy::UseProtocolCachePolicy, { }, "max-age=100"_s);
        expect("request nonzero max-age reuses a fresh response"_s, maxAge.body == "CACHED"_s && !maxAge.willCache && hits(directivesName) == 3);

        struct FreshnessCase {
            ASCIILiteral description;
            unsigned age;
            ASCIILiteral directives;
            CocoaCurlCacheAnswer answer;
        };
        unsigned freshnessIndex = 0;
        for (auto test : {
                 FreshnessCase { "request min-fresh within remaining lifetime permits reuse"_s, 100, "min-fresh=800"_s, CocoaCurlCacheAnswer::UseCached },
                 FreshnessCase { "max-stale does not override fresh response max-age validation"_s, 100, "max-age=50, max-stale=500"_s, CocoaCurlCacheAnswer::Revalidate },
                 FreshnessCase { "max-stale does not override fresh response min-fresh validation"_s, 100, "min-fresh=1000, max-stale=500"_s, CocoaCurlCacheAnswer::Revalidate },
                 FreshnessCase { "expired responses follow max-stale after the fresh-only constraints"_s, 1200, "max-age=50, min-fresh=1000, max-stale=500"_s, CocoaCurlCacheAnswer::UseCached },
                 FreshnessCase { "max-stale does not override request no-store"_s, 1200, "no-store, max-stale=500"_s, CocoaCurlCacheAnswer::Revalidate } }) {
            ResourceRequest request(URL { makeString("http://127.0.0.1:18981/cache/freshness/"_s, run, '/', freshnessIndex++) });
            ResourceResponse response(URL { request.url() }, "text/plain"_s, 0, "UTF-8"_s);
            response.setHTTPStatusCode(200);
            response.setHTTPHeaderField(HTTPHeaderName::CacheControl, "max-age=1000"_s);
            response.setHTTPHeaderField(HTTPHeaderName::Age, String::number(test.age));
            response.setHTTPHeaderField(HTTPHeaderName::ETag, "\"freshness\""_s);
            auto entry = createCocoaCurlCachedResponse(&storage, request, response, { }, WallTime::now());
            storeCocoaCurlCachedResponse(&storage, entry.get(), request);
            request.setHTTPHeaderField(HTTPHeaderName::CacheControl, String(test.directives));
            expect(test.description, lookUpCocoaCurlCachedResponse(&storage, request).answer == test.answer);
        }

        auto maxStalePath = makeString(path("stale"_s), "-max-stale"_s);
        auto maxStaleName = makeString(name("stale"_s), "-max-stale"_s);
        Probe { }.run(context, maxStalePath, ResourceRequestCachePolicy::UseProtocolCachePolicy);
        auto maxStale = Probe { }.run(context, maxStalePath, ResourceRequestCachePolicy::UseProtocolCachePolicy, { }, "max-stale=100"_s);
        expect("request max-stale admits a recently expired response"_s, maxStale.body == "CACHED"_s && maxStale.revalidated.isEmpty() && hits(maxStaleName) == 1);
        auto maxStaleZero = Probe { }.run(context, maxStalePath, ResourceRequestCachePolicy::UseProtocolCachePolicy, { }, "max-stale=0"_s);
        expect("request max-stale zero validates an expired response"_s, maxStaleZero.body == "CACHED"_s && maxStaleZero.revalidated == "yes"_s && hits(maxStaleName) == 2);

        auto fetchNoStorePath = makeString(path("fresh"_s), "-fetch-no-store"_s);
        auto fetchNoStoreName = makeString(name("fresh"_s), "-fetch-no-store"_s);
        auto fetchNoStore = Probe { }.run(context, fetchNoStorePath, ResourceRequestCachePolicy::DoNotUseAnyCache);
        auto fetchNoStoreOnly = Probe { }.run(context, fetchNoStorePath, ResourceRequestCachePolicy::ReturnCacheDataDontLoad);
        expect("fetch no-store survives delegate copying and prevents storage"_s,
            !fetchNoStore.error && fetchNoStore.body == "CACHED"_s && !fetchNoStore.willCache
            && fetchNoStoreOnly.error == NSURLErrorResourceUnavailable && hits(fetchNoStoreName) == 1);
        Probe { }.run(context, fetchNoStorePath, ResourceRequestCachePolicy::UseProtocolCachePolicy);
        auto bypassStored = Probe { }.run(context, fetchNoStorePath, ResourceRequestCachePolicy::DoNotUseAnyCache);
        auto retainedStored = Probe { }.run(context, fetchNoStorePath, ResourceRequestCachePolicy::ReturnCacheDataDontLoad);
        expect("fetch no-store bypasses an existing entry and retains it"_s,
            !bypassStored.error && bypassStored.body == "CACHED"_s && !bypassStored.willCache
            && retainedStored.body == "CACHED"_s && hits(fetchNoStoreName) == 3);

        auto requestNoStorePath = makeString(path("fresh"_s), "-request-no-store"_s);
        auto requestNoStore = Probe { }.run(context, requestNoStorePath, ResourceRequestCachePolicy::UseProtocolCachePolicy, { }, "no-store"_s);
        auto requestNoStoreOnly = Probe { }.run(context, requestNoStorePath, ResourceRequestCachePolicy::ReturnCacheDataDontLoad);
        expect("request no-store prevents response storage"_s, requestNoStore.body == "CACHED"_s && !requestNoStore.willCache && requestNoStoreOnly.error == NSURLErrorResourceUnavailable);

        Probe { }.run(context, path("stale"_s), ResourceRequestCachePolicy::UseProtocolCachePolicy);
        auto revalidated = Probe { }.run(context, path("stale"_s), ResourceRequestCachePolicy::UseProtocolCachePolicy);
        expect("a stale entry is revalidated and a 304 delivers the stored body with the updated fields"_s,
            revalidated.status == 200 && revalidated.body == "CACHED"_s && revalidated.revalidated == "yes"_s && !revalidated.willCache && hits(name("stale"_s)) == 2);
        auto elseLoad = Probe { }.run(context, path("stale"_s), ResourceRequestCachePolicy::ReturnCacheDataElseLoad);
        expect("return-cache-else-load answers from a stale entry"_s, elseLoad.status == 200 && elseLoad.body == "CACHED"_s && hits(name("stale"_s)) == 2);

        Probe { }.run(context, path("refresh"_s), ResourceRequestCachePolicy::UseProtocolCachePolicy);
        auto refreshed = Probe { }.run(context, path("refresh"_s), ResourceRequestCachePolicy::UseProtocolCachePolicy);
        auto refreshedAgain = Probe { }.run(context, path("refresh"_s), ResourceRequestCachePolicy::UseProtocolCachePolicy);
        expect("304 metadata persists for the next cache lookup"_s, refreshed.status == 200 && refreshed.revalidated == "yes"_s
            && refreshedAgain.body == "CACHED"_s && refreshedAgain.revalidated == "yes"_s && hits(name("refresh"_s)) == 2);

        auto conditionalPath = makeString(path("refresh"_s), "-conditional"_s);
        Probe { }.run(context, conditionalPath, ResourceRequestCachePolicy::UseProtocolCachePolicy);
        auto conditional = Probe { }.run(context, conditionalPath, ResourceRequestCachePolicy::ReloadIgnoringCacheData, { }, { }, "\"v1\""_s);
        auto afterConditional = Probe { }.run(context, conditionalPath, ResourceRequestCachePolicy::UseProtocolCachePolicy);
        expect("caller validation retains 304 and refreshes the stored entry"_s, conditional.status == 304 && conditional.body.isEmpty()
            && afterConditional.status == 200 && afterConditional.body == "CACHED"_s && afterConditional.revalidated == "yes"_s
            && hits(makeString(name("refresh"_s), "-conditional"_s)) == 2);

        Probe { }.run(context, path("replacement"_s), ResourceRequestCachePolicy::UseProtocolCachePolicy);
        auto replacement = Probe { }.run(context, path("replacement"_s), ResourceRequestCachePolicy::ReloadIgnoringCacheData, "no-store"_s);
        NSURLRequest *replacementRequest = [NSURLRequest requestWithURL:[NSURL URLWithString:makeString("http://127.0.0.1:18981"_s, path("replacement"_s)).createNSString().get()]];
        bool removed = waitForRemoval(storage, ResourceRequest(replacementRequest));
        auto replacedOnly = Probe { }.run(context, path("replacement"_s), ResourceRequestCachePolicy::ReturnCacheDataDontLoad);
        expect("a no-store replacement removes the stored response"_s, replacement.body == "REPLACED"_s && !replacement.willCache
            && removed && replacedOnly.error == NSURLErrorResourceUnavailable);

        Probe { }.run(context, path("status307"_s), ResourceRequestCachePolicy::UseProtocolCachePolicy);
        auto status307 = Probe { }.run(context, path("status307"_s), ResourceRequestCachePolicy::UseProtocolCachePolicy);
        expect("an explicit freshness lifetime makes status 307 cacheable"_s, status307.status == 307 && status307.body == "CACHED"_s && hits(name("status307"_s)) == 1);

        auto redirected = Probe { }.run(context, path("redirect"_s), ResourceRequestCachePolicy::UseProtocolCachePolicy);
        auto redirectedAgain = Probe { }.run(context, path("redirect"_s), ResourceRequestCachePolicy::UseProtocolCachePolicy);
        expect("cached redirects retain delegate policy and reuse their target"_s, redirected.body == "CACHED"_s && redirected.redirects == 1
            && redirectedAgain.body == "CACHED"_s && redirectedAgain.redirects == 1 && hits(name("redirect"_s)) == 1
            && hits(makeString(name("fresh"_s), "-target"_s)) == 1);

        auto staleRedirect = Probe { }.run(context, path("redirect-stale"_s), ResourceRequestCachePolicy::UseProtocolCachePolicy);
        auto staleRedirectAgain = Probe { }.run(context, path("redirect-stale"_s), ResourceRequestCachePolicy::UseProtocolCachePolicy);
        expect("a cached redirect revalidates its stale target"_s, staleRedirect.body == "CACHED"_s && staleRedirect.redirects == 1
            && staleRedirectAgain.body == "CACHED"_s && staleRedirectAgain.redirects == 1 && staleRedirectAgain.revalidated == "yes"_s
            && hits(name("redirect-stale"_s)) == 1 && hits(makeString(name("stale"_s), "-target"_s)) == 2);

        auto fragmentPath = makeString(path("fresh"_s), "-fragment"_s);
        Probe { }.run(context, makeString(fragmentPath, "#first"_s), ResourceRequestCachePolicy::UseProtocolCachePolicy);
        auto fragment = Probe { }.run(context, makeString(fragmentPath, "#second"_s), ResourceRequestCachePolicy::ReturnCacheDataDontLoad);
        expect("fragments share the HTTP cache entry"_s, fragment.status == 200 && fragment.body == "CACHED"_s && hits(makeString(name("fresh"_s), "-fragment"_s)) == 1);
        auto fragmentURL = makeString("http://127.0.0.1:18981"_s, fragmentPath, "#second"_s);
        expect("a cached response carries the current request fragment"_s, fragment.responseURL == fragmentURL && fragment.nativeResponseURL == fragmentURL);
        auto staleFragmentPath = makeString(path("stale"_s), "-fragment"_s);
        Probe { }.run(context, makeString(staleFragmentPath, "#first"_s), ResourceRequestCachePolicy::UseProtocolCachePolicy);
        auto staleFragment = Probe { }.run(context, makeString(staleFragmentPath, "#second"_s), ResourceRequestCachePolicy::UseProtocolCachePolicy);
        auto staleFragmentURL = makeString("http://127.0.0.1:18981"_s, staleFragmentPath, "#second"_s);
        expect("a revalidated response carries the current request fragment"_s, staleFragment.revalidated == "yes"_s
            && staleFragment.body == "CACHED"_s && staleFragment.responseURL == staleFragmentURL && staleFragment.nativeResponseURL == staleFragmentURL);


        Probe { }.run(context, path("vary"_s), ResourceRequestCachePolicy::UseProtocolCachePolicy, "a"_s);
        Probe { }.run(context, path("vary"_s), ResourceRequestCachePolicy::UseProtocolCachePolicy, "a"_s);
        expect("a Vary field with the same request value answers from the cache"_s, hits(name("vary"_s)) == 1);
        auto varyingCacheOnly = Probe { }.run(context, path("vary"_s), ResourceRequestCachePolicy::ReturnCacheDataDontLoad, "b"_s);
        expect("cache-only policy preserves Vary matching"_s, varyingCacheOnly.error == NSURLErrorResourceUnavailable && hits(name("vary"_s)) == 1);
        Probe { }.run(context, path("vary"_s), ResourceRequestCachePolicy::UseProtocolCachePolicy, "b"_s);
        expect("a Vary field with another request value reaches the network"_s, hits(name("vary"_s)) == 2);

        auto absentVaryPath = makeString(path("vary"_s), "-absent"_s);
        auto absentVaryName = makeString(name("vary"_s), "-absent"_s);
        Probe { }.run(context, absentVaryPath, ResourceRequestCachePolicy::UseProtocolCachePolicy);
        auto absentVary = Probe { }.run(context, absentVaryPath, ResourceRequestCachePolicy::UseProtocolCachePolicy);
        expect("an absent Vary request field matches another absent field"_s, !absentVary.error && !absentVary.willCache && hits(absentVaryName) == 1);
        auto emptyVary = Probe { }.run(context, absentVaryPath, ResourceRequestCachePolicy::UseProtocolCachePolicy, emptyString());
        auto emptyVaryAgain = Probe { }.run(context, absentVaryPath, ResourceRequestCachePolicy::UseProtocolCachePolicy, emptyString());
        expect("an empty Vary request field is distinct from an absent field and reusable"_s,
            !emptyVary.error && emptyVary.willCache == 1 && !emptyVaryAgain.willCache && hits(absentVaryName) == 2);

        auto noStore = Probe { }.run(context, path("nostore"_s), ResourceRequestCachePolicy::UseProtocolCachePolicy);
        auto noStoreOnly = Probe { }.run(context, path("nostore"_s), ResourceRequestCachePolicy::ReturnCacheDataDontLoad);
        expect("a no-store response is not stored"_s, noStore.status == 200 && !noStore.willCache && noStoreOnly.error == NSURLErrorResourceUnavailable);

        auto large = Probe { }.run(context, path("large"_s), ResourceRequestCachePolicy::UseProtocolCachePolicy);
        auto largeOnly = Probe { }.run(context, path("large"_s), ResourceRequestCachePolicy::ReturnCacheDataDontLoad);
        expect("a body over a twentieth of the cache's capacity is not stored"_s, large.status == 200 && !large.willCache && largeOnly.error == NSURLErrorResourceUnavailable);

        auto privateSession = createPrivateStorageSession(run.createCFString().get());
        RELEASE_ASSERT(privateSession);
        NetworkStorageSession ephemeral(PAL::SessionID::generateEphemeralSessionID(), WTF::move(privateSession), nullptr);
        Ref ephemeralContext = Context::create(ephemeral);
        auto ephemeralLoad = Probe { }.run(ephemeralContext, path("fresh"_s), ResourceRequestCachePolicy::UseProtocolCachePolicy);
        auto ephemeralOnly = Probe { }.run(ephemeralContext, path("fresh"_s), ResourceRequestCachePolicy::ReturnCacheDataDontLoad);
        expect("an ephemeral session reads and writes only its own cache"_s, ephemeralLoad.status == 200 && ephemeralLoad.willCache == 1 && hits(name("fresh"_s)) == 3 && ephemeralOnly.status == 200 && ephemeralOnly.body == "CACHED"_s);
        auto privatePath = makeString(path("fresh"_s), "-private"_s);
        auto privateStored = Probe { }.run(ephemeralContext, privatePath, ResourceRequestCachePolicy::UseProtocolCachePolicy);
        auto sharedOnly = Probe { }.run(context, privatePath, ResourceRequestCachePolicy::ReturnCacheDataDontLoad);
        auto secondSession = createPrivateStorageSession(makeString(run, "-second"_s).createCFString().get());
        RELEASE_ASSERT(secondSession);
        NetworkStorageSession secondEphemeral(PAL::SessionID::generateEphemeralSessionID(), WTF::move(secondSession), nullptr);
        Ref secondContext = Context::create(secondEphemeral);
        auto secondOnly = Probe { }.run(secondContext, privatePath, ResourceRequestCachePolicy::ReturnCacheDataDontLoad);
        expect("a private cache entry is absent from shared and other private sessions"_s, privateStored.status == 200 && privateStored.willCache == 1 && sharedOnly.error == NSURLErrorResourceUnavailable && secondOnly.error == NSURLErrorResourceUnavailable);

        // Distinct native CFString cache keys with the same sampled hash on Mavericks.
        Vector<ResourceRequest> collisionRequests;
        for (auto identifier : { "167297174343"_s, "561372903984"_s }) {
            ResourceRequest request(URL { makeString("http://127.0.0.1:8000/cache/disk-cache/resources/generate-response.cgi?body=test%20body&uniqueId="_s,
                identifier, "&Content-Type=text/plain&Cache-control=max-age%3D0"_s) });
            ResourceResponse response(URL { request.url() }, "text/plain"_s, 1, "UTF-8"_s);
            response.setHTTPStatusCode(200);
            response.setHTTPHeaderField(HTTPHeaderName::CacheControl, "max-age=3600"_s);
            std::array<uint8_t, 1> body { static_cast<uint8_t>(collisionRequests.size()) };
            auto entry = createCocoaCurlCachedResponse(&storage, request, response, body, WallTime::now());
            storeCocoaCurlCachedResponse(&storage, entry.get(), request);
            collisionRequests.append(WTF::move(request));
        }
        for (size_t i = 0; i < collisionRequests.size(); ++i) {
            auto cached = lookUpCocoaCurlCachedResponse(&storage, collisionRequests[i]);
            expect("colliding long native URL keys retain distinct bodies and URLs"_s,
                cached.answer == CocoaCurlCacheAnswer::UseCached && cached.entry
                && cached.entry.get().data.length == 1
                && static_cast<const uint8_t *>(cached.entry.get().data.bytes)[0] == i
                && cocoaCurlCachedResponse(cached.entry.get(), collisionRequests[i]).url() == collisionRequests[i].url());
        }
        for (size_t i = 0; i < collisionRequests.size(); ++i) {
            NSCachedURLResponse *plain = cachedResponseForRequest(nullptr, collisionRequests[i].nsURLRequest(HTTPBodyUpdatePolicy::DoNotUpdateHTTPBody));
            expect("WebCore's plain NSURLCache lookup finds each entry the transport stored"_s,
                plain && plain.data.length == 1 && static_cast<const uint8_t *>(plain.data.bytes)[0] == i);
        }
        removeCocoaCurlCachedResponse(&storage, collisionRequests[0]);
        expect("removing one colliding URL leaves the other entry intact"_s,
            waitForRemoval(storage, collisionRequests[0])
            && lookUpCocoaCurlCachedResponse(&storage, collisionRequests[1]).answer == CocoaCurlCacheAnswer::UseCached);

        ResourceRequest wholeRequest(URL { makeString("http://127.0.0.1:18981/cache/range/"_s, run) });
        wholeRequest.setFirstPartyForCookies(URL { "https://cache-invalidation.example/"_s });
        auto rangeRequest = wholeRequest;
        rangeRequest.setHTTPHeaderField(HTTPHeaderName::Range, "bytes=0-2"_s);
        ResourceResponse partialResponse(URL { wholeRequest.url() }, "text/plain"_s, 3, "UTF-8"_s);
        partialResponse.setHTTPStatusCode(206);
        partialResponse.setHTTPHeaderField(HTTPHeaderName::CacheControl, "max-age=3600"_s);
        partialResponse.setHTTPHeaderField(HTTPHeaderName::ContentRange, "bytes 0-2/6"_s);
        std::array<uint8_t, 3> rangeBody { 'a', 'b', 'c' };
        check(cocoaCurlCacheMayStore(&storage, rangeRequest, partialResponse), "single byte-range response is cacheable");
        ResourceResponse notModified(URL { wholeRequest.url() }, "text/plain"_s, 0, "UTF-8"_s);
        notModified.setHTTPStatusCode(304);
        notModified.setHTTPHeaderField(HTTPHeaderName::CacheControl, "max-age=3600"_s);
        check(!cocoaCurlCacheMayStore(&storage, wholeRequest, notModified), "304 response is never stored");
        ResourceResponse forbidden(URL { wholeRequest.url() }, "text/plain"_s, 3, "UTF-8"_s);
        forbidden.setHTTPStatusCode(403);
        check(!cocoaCurlCacheMayStore(&storage, wholeRequest, forbidden), "403 without expiration headers or public is not stored");
        forbidden.setHTTPHeaderField(HTTPHeaderName::CacheControl, "public"_s);
        check(cocoaCurlCacheMayStore(&storage, wholeRequest, forbidden), "403 marked public is stored");
        forbidden.setHTTPHeaderField(HTTPHeaderName::CacheControl, "max-age=3600"_s);
        check(cocoaCurlCacheMayStore(&storage, wholeRequest, forbidden), "403 with max-age is stored");
        auto rangeEntry = createCocoaCurlCachedResponse(&storage, rangeRequest, partialResponse, rangeBody, WallTime::now());
        storeCocoaCurlCachedResponse(&storage, rangeEntry.get(), rangeRequest);
        auto sameRange = lookUpCocoaCurlCachedResponse(&storage, rangeRequest);
        auto otherRangeRequest = wholeRequest;
        otherRangeRequest.setHTTPHeaderField(HTTPHeaderName::Range, "bytes=3-5"_s);
        expect("partial response is reusable only for the exact requested range"_s,
            sameRange.answer == CocoaCurlCacheAnswer::UseCached && sameRange.entry
            && cocoaCurlCachedResponse(sameRange.entry.get(), rangeRequest).httpStatusCode() == 206
            && sameRange.entry.get().data.length == rangeBody.size()
            && lookUpCocoaCurlCachedResponse(&storage, wholeRequest).answer == CocoaCurlCacheAnswer::Load
            && lookUpCocoaCurlCachedResponse(&storage, otherRangeRequest).answer == CocoaCurlCacheAnswer::Load);

        RetainPtr nativeUnsafeRequest = adoptNS([wholeRequest.nsURLRequest(HTTPBodyUpdatePolicy::DoNotUpdateHTTPBody) mutableCopy]);
        [nativeUnsafeRequest setHTTPMethod:@"POST"];
        [nativeUnsafeRequest setHTTPBody:[NSData dataWithBytes:rangeBody.data() length:rangeBody.size()]];
        ResourceRequest unsafeRequest { nativeUnsafeRequest.get() };
        unsafeRequest.setFirstPartyForCookies(wholeRequest.firstPartyForCookies());
        unsafeRequest.setShouldBlockThirdPartyStorage(wholeRequest.shouldBlockThirdPartyStorage());
        unsafeRequest.setCachePolicy(ResourceRequestCachePolicy::DoNotUseAnyCache);
        ResourceResponse unsafeResponse(URL { wholeRequest.url() }, "text/plain"_s, 0, "UTF-8"_s);
        unsafeResponse.setHTTPStatusCode(500);
        invalidateCocoaCurlCacheAfterResponse(&storage, unsafeRequest, unsafeResponse);
        expect("a failed unsafe request retains the stored response"_s,
            lookUpCocoaCurlCachedResponse(&storage, rangeRequest).answer == CocoaCurlCacheAnswer::UseCached);
        unsafeResponse.setHTTPStatusCode(204);
        invalidateCocoaCurlCacheAfterResponse(&storage, unsafeRequest, unsafeResponse);
        expect("a successful no-store unsafe request invalidates the stored range"_s, waitForRemoval(storage, rangeRequest));

        struct MetadataCase { ASCIILiteral version; ASCIILiteral statusText; int status; };
        for (auto metadata : { MetadataCase { "HTTP/2.0"_s, ""_s, 410 },
                 MetadataCase { "HTTP/1.1"_s, "Custom Reason"_s, 410 },
                 MetadataCase { "HTTP/0.9"_s, "OK"_s, 200 } }) {
            ResourceRequest request(URL { makeString("http://127.0.0.1:18981/cache/metadata/"_s, run, '/', metadata.version) });
            ResourceResponse response(URL { request.url() }, "text/plain"_s, 0, "UTF-8"_s);
            response.setHTTPStatusCode(metadata.status);
            response.setHTTPStatusText(String(metadata.statusText));
            response.setHTTPVersion(String(metadata.version));
            response.setHTTPHeaderField(HTTPHeaderName::CacheControl, "max-age=3600"_s);
            auto entry = createCocoaCurlCachedResponse(&storage, request, response, { }, WallTime::now());
            storeCocoaCurlCachedResponse(&storage, entry.get(), request);
            auto cached = lookUpCocoaCurlCachedResponse(&storage, request);
            check(cached.answer == CocoaCurlCacheAnswer::UseCached && cached.entry, "native cache admits response metadata case");
            if (cached.entry) {
                auto restored = cocoaCurlCachedResponse(cached.entry.get(), request);
                expect("native cache preserves HTTP status text and version"_s, restored.httpStatusText() == response.httpStatusText() && restored.httpVersion() == response.httpVersion());
                ResourceResponse notModified(URL { request.url() }, "text/plain"_s, 0, "UTF-8"_s);
                notModified.setHTTPStatusCode(304);
                notModified.setHTTPHeaderField(HTTPHeaderName::CacheControl, "max-age=7200"_s);
                auto validated = cocoaCurlRevalidatedResponse(cached.entry.get(), notModified);
                expect("304 preserves cached HTTP status text and version"_s, validated.httpStatusCode() == metadata.status && validated.httpStatusText() == response.httpStatusText() && validated.httpVersion() == response.httpVersion());
            }
        }

        [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
        printf("Cocoa curl URL cache: FAILED=%u\n", failures);
    }
    return failures ? 1 : 0;
}
