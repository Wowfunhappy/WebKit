// Exercise Basic, Digest and NTLM through the actual native challenge sender.
#include "config.h"
#include "NetworkingContext.h"
#include <WebCore/AuthenticationChallenge.h>
#include <WebCore/FormData.h>
#include <WebCore/NetworkStorageSession.h>
#include <WebCore/ResourceHandle.h>
#include <WebCore/ResourceHandleClient.h>
#include <WebCore/ResourceRequest.h>
#include <WebCore/ResourceResponse.h>
#include <WebCore/ResourceError.h>
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
static void check(bool value, const char* message) { if (!value) { ++failures; printf("FAIL %s\n", message); } }
class Context final : public NetworkingContext {
public:
    static Ref<Context> create(NetworkStorageSession& storage, bool custom = false) { return adoptRef(*new Context(storage, custom)); }
    SchedulePairHashSet* scheduledRunLoopPairs() const final { return m_pairs.isEmpty() ? nullptr : &m_pairs; }
    CFStringRef mode() const { return m_pairs.isEmpty() ? kCFRunLoopDefaultMode : CFSTR("CocoaCurlResourceHandleTestMode"); }
    NetworkStorageSession* storageSession() const final { return &m_storage; }
    bool shouldClearReferrerOnHTTPSToHTTPRedirect() const final { return true; }
    bool localFileContentSniffingEnabled() const final { return false; }
    RetainPtr<CFDataRef> sourceApplicationAuditData() const final { return nullptr; }
    ResourceError blockedError(const ResourceRequest& request) const final { return ResourceError(NSURLErrorDomain, NSURLErrorCannotLoadFromNetwork, request.url(), "Blocked by the test context"_s); }
private:
    explicit Context(NetworkStorageSession& storage, bool custom) : m_storage(storage) { if (custom) m_pairs.add(SchedulePair::create(CFRunLoopGetMain(), CFSTR("CocoaCurlResourceHandleTestMode"))); }
    mutable SchedulePairHashSet m_pairs;
    NetworkStorageSession& m_storage;
};
class Probe final : public ResourceHandleClient {
public:
    void run(Context& context, ASCIILiteral url, int expectedError, unsigned redirects = 0, bool post = false)
    {
        context.storageSession()->clearCocoaCurlCredentialState();
        ResourceRequest request(URL { url });
        request.setTimeoutInterval(10);
        if (post) {
            std::array<uint8_t, 32> payload;
            for (size_t i = 0; i < payload.size(); ++i) payload[i] = i;
            request.setHTTPMethod("POST"_s);
            request.setHTTPBody(FormData::create(std::span<const uint8_t>(payload)));
            request.setHTTPHeaderField(HTTPHeaderName::Expect, "100-continue"_s);
        }
        request.setFirstPartyForCookies(request.url());
        request.setIsTopSite(true);
        auto handle = ResourceHandle::create(&context, request, this, false, true, ContentEncodingSniffingPolicy::Default, nullptr, true);
        check(!!handle, "ResourceHandle created");
        if (!handle)
            return;
        check(handle->cocoaCurlHandle() && !handle->connection(), "HTTP uses curl with no native wire connection");
        expectedMode = context.mode();
        auto deadline = adoptCF(CFRunLoopTimerCreateWithHandler(nullptr, CFAbsoluteTimeGetCurrent() + 15, 0, 0, 0, ^(CFRunLoopTimerRef) { check(false, "ResourceHandle deadline"); CFRunLoopStop(CFRunLoopGetMain()); }));
        CFRunLoopAddTimer(CFRunLoopGetMain(), deadline.get(), context.mode());
        CFRunLoopRunInMode(context.mode(), 15, false);
        CFRunLoopTimerInvalidate(deadline.get());
        check(error == expectedError, "ResourceHandle has the expected native error");
        check(!error ? status == 200 && bytes : true, "successful ResourceHandle delivered its response/body");
        check(redirectCount == redirects, "ResourceHandle followed the expected redirect count");
        check(challenges == 1, "one native credential challenge for the authentication exchange");
        printf("ResourceHandle %s status=%d bytes=%llu error=%d redirects=%u\n", url.characters(), status, static_cast<unsigned long long>(bytes), error, redirectCount);
    }
private:
    void willSendRequestAsync(ResourceHandle*, ResourceRequest&& request, ResourceResponse&&, CompletionHandler<void(ResourceRequest&&)>&& completion) final
    {
        ++redirectCount;
        completion(WTF::move(request));
    }
    void didReceiveResponseAsync(ResourceHandle*, ResourceResponse&& response, CompletionHandler<void()>&& completion) final
    {
        auto mode = adoptCF(CFRunLoopCopyCurrentMode(CFRunLoopGetCurrent()));
        check(mode && CFEqual(mode.get(), expectedMode), "ResourceHandle response arrives in the scheduled run-loop mode");
        status = response.httpStatusCode();
        completion();
    }
    void didReceiveData(ResourceHandle*, const SharedBuffer& data, int) final { bytes += data.size(); }
    void didFinishLoading(ResourceHandle*, const NetworkLoadMetrics& metrics) final
    {
        check(metrics.isComplete(), "completed ResourceHandle metrics");
        CFRunLoopStop(CFRunLoopGetCurrent());
    }
    void didFail(ResourceHandle*, const ResourceError& failure) final
    {
        error = failure.errorCode();
        CFRunLoopStop(CFRunLoopGetCurrent());
    }
    bool shouldUseCredentialStorage(ResourceHandle*) final { return false; }
    void didReceiveAuthenticationChallenge(ResourceHandle*, const AuthenticationChallenge& challenge) final
    {
        auto native = challenge.nsURLAuthenticationChallenge();
        check(!!native && !!challenge.sender(), "ResourceHandle delivers a native challenge and sender");
        ++challenges;
        NSString *method = [native protectionSpace].authenticationMethod;
        NSString *user = nil;
        if ([method isEqualToString:NSURLAuthenticationMethodHTTPDigest])
            user = @"curl-test";
        else if ([method isEqualToString:NSURLAuthenticationMethodNTLM])
            user = @"CURL\\curl-test";
        else if ([method isEqualToString:NSURLAuthenticationMethodNegotiate])
            user = @"curl-test@CURL.SWITCHOVER.TEST";
        check(!!user, "the advertised authentication scheme reaches the native challenge");
        printf("challenge method=%s failures=%ld\n", [method UTF8String], (long)[native previousFailureCount]);
        if (user && challenges == 1)
            [challenge.sender() useCredential:[NSURLCredential credentialWithUser:user password:@"correct-password" persistence:NSURLCredentialPersistenceNone] forAuthenticationChallenge:native];
        else
            [challenge.sender() cancelAuthenticationChallenge:native];
    }
#if USE(PROTECTION_SPACE_AUTH_CALLBACK)
    void canAuthenticateAgainstProtectionSpaceAsync(ResourceHandle*, const ProtectionSpace&, CompletionHandler<void(bool)>&& completion) final { completion(true); }
#endif
    CFStringRef expectedMode { kCFRunLoopDefaultMode };
    int error { 0 };
    int status { 0 };
    uint64_t bytes { 0 };
    unsigned redirectCount { 0 };
    unsigned challenges { 0 };
};
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
        Probe { }.run(context, "http://localhost:18984/digest"_s, 0);
        Probe { }.run(context, "http://localhost:18984/ntlm"_s, 0);
        Probe { }.run(context, "http://localhost:18984/ntlm?sticky"_s, 0);
        Probe { }.run(context, "http://localhost:18984/digest?body"_s, 0, 0, true);
        Probe { }.run(context, "http://localhost:18984/ntlm?body"_s, 0, 0, true);
        printf("Cocoa curl authentication: FAILED=%u\n", failures);
    }
    return failures ? 1 : 0;
}
