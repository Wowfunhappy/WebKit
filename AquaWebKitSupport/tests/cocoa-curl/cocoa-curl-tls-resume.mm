// TLS session resumption over the legacy ResourceHandle. A resumed connection reports the certificate
// its session authenticated and records HSTS as the original did. Its trust is evaluated only for a load
// that includes certificate info -- the main resource -- and before that load sees its response; any
// other load gets it unevaluated. A session whose certificate was accepted only through an exception is
// never resumed, so the next load that has no exception meets the certificate again. Every load asks
// the fixture to close its connection, so the partition holds no connection between loads and each one
// opens its own, offering whatever session the partition's cache kept.
// Expects the root-signed fixture on 19445 and the self-signed one on 19446 (cocoa-curl-tls-fixtures.py).
#include "config.h"
#include "NetworkingContext.h"
#include <WebCore/AuthenticationChallenge.h>
#include <WebCore/HTTPStrictTransportSecurityStore.h>
#include <WebCore/NetworkStorageSession.h>
#include <WebCore/ResourceError.h>
#include <WebCore/ResourceHandle.h>
#include <WebCore/ResourceHandleClient.h>
#include <WebCore/ResourceRequest.h>
#include <WebCore/ResourceResponse.h>
#include <WebCore/SharedBuffer.h>
#include <pal/SessionID.h>
#include <wtf/MainThread.h>
#include <wtf/ProcessPrivilege.h>
#include <Foundation/Foundation.h>
#include <dlfcn.h>
#include <cstdio>

@interface NSURLRequest (CocoaCurlTLSResumeFixture)
+ (void)setAllowsAnyHTTPSCertificate:(BOOL)allow forHost:(NSString *)host;
@end

using namespace WebCore;
static unsigned failures;
static void check(bool value, const char* message) { if (!value) { ++failures; printf("FAIL %s\n", message); } }

class Context final : public NetworkingContext {
public:
    static Ref<Context> create(NetworkStorageSession& storage) { return adoptRef(*new Context(storage)); }
    bool shouldClearReferrerOnHTTPSToHTTPRedirect() const final { return true; }
    bool localFileContentSniffingEnabled() const final { return false; }
    RetainPtr<CFDataRef> sourceApplicationAuditData() const final { return nullptr; }
    SchedulePairHashSet* scheduledRunLoopPairs() const final { return nullptr; }
    NetworkStorageSession* storageSession() const final { return &m_storage; }
    ResourceError blockedError(const ResourceRequest& request) const final { return ResourceError(NSURLErrorDomain, NSURLErrorCannotLoadFromNetwork, request.url(), "Blocked by the test context"_s); }
private:
    explicit Context(NetworkStorageSession& storage) : m_storage(storage) { }
    NetworkStorageSession& m_storage;
};

enum class TrustAnswer : bool { Cancel, UseCredential };

class Load final : public ResourceHandleClient {
public:
    Load(Context& context, ASCIILiteral url, TrustAnswer answer, bool mainResource = false, ASCIILiteral firstParty = "https://127.0.0.1/"_s)
        : m_answer(answer)
    {
        ResourceRequest request(URL { url });
        if (mainResource)
            request.setRequester(ResourceRequestRequester::Main);
        request.setTimeoutInterval(10);
        request.setFirstPartyForCookies(URL { firstParty });
        request.setCachePolicy(ResourceRequestCachePolicy::DoNotUseAnyCache);
        auto handle = ResourceHandle::create(&context, request, this, false, false, ContentEncodingSniffingPolicy::Default, nullptr, true);
        check(!!handle, "ResourceHandle created");
        if (handle)
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 15, false);
        check(m_done, "load finished before its deadline");
        printf("%s status=%d reused=%s trustChallenges=%u error=%d trust=%s result=%d\n", url.characters(), status,
            reused.utf8().data(), trustChallenges, error, trust ? "yes" : "no", static_cast<int>(trustResult));
    }
    int status { 0 };
    int error { 0 };
    unsigned trustChallenges { 0 };
    String reused;
    RetainPtr<SecTrustRef> trust;
    // Read as the response arrives with SecTrustGetTrustResult, which reports and never evaluates.
    SecTrustResultType trustResult { kSecTrustResultInvalid };
private:
    void didReceiveResponseAsync(ResourceHandle*, ResourceResponse&& response, CompletionHandler<void()>&& completion) final
    {
        status = response.httpStatusCode();
        reused = response.httpHeaderField("X-TLS-Session-Reused"_s);
        if (auto& info = response.certificateInfo())
            trust = info->trust();
        if (trust && SecTrustGetTrustResult(trust.get(), &trustResult) != errSecSuccess)
            trustResult = kSecTrustResultOtherError;
        completion();
    }
    void didReceiveData(ResourceHandle*, const SharedBuffer&, int) final { }
    void didFinishLoading(ResourceHandle*, const NetworkLoadMetrics&) final { finish(); }
    void didFail(ResourceHandle*, const ResourceError& failure) final
    {
        error = failure.errorCode();
        finish();
    }
    void willSendRequestAsync(ResourceHandle*, ResourceRequest&& request, ResourceResponse&&, CompletionHandler<void(ResourceRequest&&)>&& completion) final { completion(WTF::move(request)); }
    bool shouldUseCredentialStorage(ResourceHandle*) final { return false; }
    void canAuthenticateAgainstProtectionSpaceAsync(ResourceHandle*, const ProtectionSpace&, CompletionHandler<void(bool)>&& completion) final { completion(true); }
    void didReceiveAuthenticationChallenge(ResourceHandle*, const AuthenticationChallenge& challenge) final
    {
        NSURLAuthenticationChallenge *native = challenge.nsURLAuthenticationChallenge();
        if (![native.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
            [challenge.sender() continueWithoutCredentialForAuthenticationChallenge:native];
            return;
        }
        ++trustChallenges;
        if (m_answer == TrustAnswer::UseCredential)
            [challenge.sender() useCredential:[NSURLCredential credentialForTrust:native.protectionSpace.serverTrust] forAuthenticationChallenge:native];
        else
            [challenge.sender() continueWithoutCredentialForAuthenticationChallenge:native];
    }
    void finish()
    {
        m_done = true;
        CFRunLoopStop(CFRunLoopGetCurrent());
    }
    TrustAnswer m_answer;
    bool m_done { false };
};

// 10.9's SecTrustGetCertificateCount evaluates the trust; SecTrustGetCertificateAtIndex reads the leaf without evaluating.
static RetainPtr<CFDataRef> leafData(SecTrustRef trust)
{
    auto leaf = trust ? SecTrustGetCertificateAtIndex(trust, 0) : nullptr;
    return leaf ? adoptCF(SecCertificateCopyData(leaf)) : nullptr;
}

static bool succeeded(SecTrustResultType result) { return result == kSecTrustResultProceed || result == kSecTrustResultUnspecified; }

int main()
{
    @autoreleasepool {
        setvbuf(stdout, nullptr, _IONBF, 0);
        WTF::initializeMainThread();
        setProcessPrivileges({ ProcessPrivilege::CanAccessRawCookies, ProcessPrivilege::CanAccessCredentials });
        NetworkStorageSession::permitProcessToUseCookieAPI(true);
        auto createStorage = reinterpret_cast<CFHTTPCookieStorageRef (*)(CFAllocatorRef, CFDictionaryRef)>(dlsym(RTLD_DEFAULT, "CFHTTPCookieStorageCreateInMemory"));
        RELEASE_ASSERT(createStorage);
        NetworkStorageSession storage(PAL::SessionID::generateEphemeralSessionID(), nullptr, adoptCF(createStorage(kCFAllocatorDefault, nullptr)), NetworkStorageSession::IsInMemoryCookieStore::Yes);
        Ref context = Context::create(storage);

        // A platform-trusted chain: later connections resume the first one's session. Their responses
        // carry that certificate, evaluated for the main resource and unevaluated for anything else, and
        // still count as authenticated for HSTS.
        Load trustedFull(context, "https://localhost:19445/full?close"_s, TrustAnswer::Cancel);
        check(trustedFull.status == 200 && trustedFull.reused == "0"_s, "trusted chain: first connection completes a full handshake");
        check(succeeded(trustedFull.trustResult), "trusted chain: full handshake reports its evaluated trust");
        Load trustedResumed(context, "https://localhost:19445/resumed?close&hsts"_s, TrustAnswer::Cancel);
        check(trustedResumed.status == 200 && trustedResumed.reused == "1"_s, "trusted chain: second connection resumes the session");
        check(!trustedResumed.trustChallenges, "trusted chain: resumed connection raises no challenge");
        check(!!trustedResumed.trust && trustedResumed.trustResult == kSecTrustResultInvalid, "trusted chain: a resumed load without certificate info gets an unevaluated trust");
        check(storage.httpStrictTransportSecurityStore().shouldUpgrade(URL { "http://localhost/"_s }), "trusted chain: resumed connection records HSTS");
        Load trustedMain(context, "https://localhost:19445/main?close"_s, TrustAnswer::Cancel, true);
        check(trustedMain.status == 200 && trustedMain.reused == "1"_s, "trusted chain: main resource resumes the session");
        check(succeeded(trustedMain.trustResult), "trusted chain: resumed main resource gets an evaluated trust");
        auto fullLeaf = leafData(trustedFull.trust.get());
        auto resumedLeaf = leafData(trustedResumed.trust.get());
        auto mainLeaf = leafData(trustedMain.trust.get());
        check(fullLeaf && resumedLeaf && CFEqual(fullLeaf.get(), resumedLeaf.get()), "trusted chain: resumed response carries the session's certificate");
        check(fullLeaf && mainLeaf && CFEqual(fullLeaf.get(), mainLeaf.get()), "trusted chain: resumed main resource carries the session's certificate");

        // Each partition keeps sessions of its own, and the pool keeps four partitions' caches, giving up
        // the least recently active idle partition's first.
        Load firstPartition(context, "https://localhost:19445/partition?close"_s, TrustAnswer::Cancel, false, "https://first.test/"_s);
        check(firstPartition.status == 200 && firstPartition.reused == "0"_s, "partitions: a new partition starts with no session");
        for (auto firstParty : { "https://second.test/"_s, "https://third.test/"_s, "https://fourth.test/"_s, "https://fifth.test/"_s }) {
            Load next(context, "https://localhost:19445/partition?close"_s, TrustAnswer::Cancel, false, firstParty);
            check(next.status == 200 && next.reused == "0"_s, "partitions: another partition's session is not offered");
        }
        Load recent(context, "https://localhost:19445/partition?close"_s, TrustAnswer::Cancel, false, "https://fifth.test/"_s);
        check(recent.reused == "1"_s, "partitions: the most recent partition keeps its session");
        Load evicted(context, "https://localhost:19445/partition?close"_s, TrustAnswer::Cancel, false, "https://first.test/"_s);
        check(evicted.reused == "0"_s, "partitions: the least recently active partition's cache is given up past four");

        // +[NSURLRequest setAllowsAnyHTTPSCertificate:forHost:] accepts the self-signed certificate in
        // the handshake; once it is withdrawn, the next connection meets that certificate again.
        [NSURLRequest setAllowsAnyHTTPSCertificate:YES forHost:@"127.0.0.1"];
        Load allowed(context, "https://127.0.0.1:19446/allowed?close"_s, TrustAnswer::Cancel);
        check(allowed.status == 200 && !allowed.trustChallenges, "allowsAnyHTTPSCertificate: load accepted without a challenge");
        [NSURLRequest setAllowsAnyHTTPSCertificate:NO forHost:@"127.0.0.1"];
        Load afterAllowed(context, "https://127.0.0.1:19446/after-allowed?close"_s, TrustAnswer::Cancel);
        check(afterAllowed.trustChallenges == 1, "allowsAnyHTTPSCertificate: the next load is challenged again");
        check(afterAllowed.error == NSURLErrorServerCertificateUntrusted && !afterAllowed.status, "allowsAnyHTTPSCertificate: the next load fails once the challenge is refused");

        // A load whose challenge the client accepts restarts with that certificate accepted; a fresh
        // load to the same server is challenged in its turn.
        Load accepted(context, "https://127.0.0.1:19446/accepted?close"_s, TrustAnswer::UseCredential);
        check(accepted.status == 200 && accepted.trustChallenges == 1, "accepted challenge: load completes after one challenge");
        Load afterAccepted(context, "https://127.0.0.1:19446/after-accepted?close"_s, TrustAnswer::UseCredential);
        check(afterAccepted.status == 200 && afterAccepted.trustChallenges == 1, "accepted challenge: a fresh load is challenged again");
        check(afterAccepted.reused == "0"_s, "accepted challenge: the excepted session is not resumed");

        printf("cocoa-curl-tls-resume: %s\n", failures ? "FAILED" : "passed");
        return failures ? 1 : 0;
    }
}
