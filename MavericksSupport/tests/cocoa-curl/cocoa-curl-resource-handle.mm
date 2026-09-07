// Actual legacy ResourceHandle calls, including synchronous loads and native authentication senders.
#include "config.h"
#include "NetworkingContext.h"
#include <WebCore/AuthenticationChallenge.h>
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
    void run(Context& context, ASCIILiteral url, int expectedError, unsigned redirects = 0)
    {
        ResourceRequest request(URL { url });
        request.setTimeoutInterval(10);
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
        if ([[native protectionSpace].authenticationMethod isEqualToString:NSURLAuthenticationMethodHTTPBasic])
            [challenge.sender() useCredential:[NSURLCredential credentialWithUser:@"curl-test" password:@"correct-password" persistence:NSURLCredentialPersistenceNone] forAuthenticationChallenge:native];
        else
            [challenge.sender() continueWithoutCredentialForAuthenticationChallenge:native];
    }
#if USE(PROTECTION_SPACE_AUTH_CALLBACK)
    void canAuthenticateAgainstProtectionSpaceAsync(ResourceHandle*, const ProtectionSpace&, CompletionHandler<void(bool)>&& completion) final { completion(true); }
#endif
    CFStringRef expectedMode { kCFRunLoopDefaultMode };
    int error { 0 };
    int status { 0 };
    uint64_t bytes { 0 };
    unsigned redirectCount { 0 };
};
int main()
{
    @autoreleasepool {
        WTF::initializeMainThread();
        setProcessPrivileges({ ProcessPrivilege::CanAccessRawCookies, ProcessPrivilege::CanAccessCredentials });
        NetworkStorageSession::permitProcessToUseCookieAPI(true);
        auto createStorage = reinterpret_cast<CFHTTPCookieStorageRef (*)(CFAllocatorRef, CFDictionaryRef)>(dlsym(RTLD_DEFAULT, "CFHTTPCookieStorageCreateInMemory"));
        RELEASE_ASSERT(createStorage);
        NetworkStorageSession storage(PAL::SessionID::generateEphemeralSessionID(), nullptr, adoptCF(createStorage(kCFAllocatorDefault, nullptr)), NetworkStorageSession::IsInMemoryCookieStore::Yes);
        Ref context = Context::create(storage);
        Probe { }.run(context, "http://127.0.0.1:18981/probe/baseline"_s, 0);
        Probe { }.run(context, "http://127.0.0.1:18981/probe/chunk_short_data"_s, NSURLErrorNetworkConnectionLost);
        Probe { }.run(context, "http://127.0.0.1:18981/probe/redirect_limit_20"_s, 0, 20);
        Probe { }.run(context, "http://127.0.0.1:18981/probe/redirect_limit_21"_s, NSURLErrorHTTPTooManyRedirects, 20);
        Probe { }.run(context, "http://127.0.0.1:18982/basic"_s, 0);
        Probe { }.run(context, "https://127.0.0.1:19446/"_s, NSURLErrorServerCertificateUntrusted);
        Ref customContext = Context::create(storage, true);
        Probe { }.run(customContext, "http://127.0.0.1:18981/probe/baseline"_s, 0);
        for (auto url : { "http://127.0.0.1:18981/probe/baseline"_s, "http://127.0.0.1:18981/probe/chunk_short_data"_s }) {
            ResourceRequest request(URL { url });
            request.setTimeoutInterval(10);
            ResourceError error;
            ResourceResponse response;
            Vector<uint8_t> bytes;
            ResourceHandle::loadResourceSynchronously(context.ptr(), request, StoredCredentialsPolicy::DoNotUse, nullptr, error, response, bytes);
            bool truncated = StringView(url).endsWith("chunk_short_data"_s);
            check(error.errorCode() == (truncated ? NSURLErrorNetworkConnectionLost : 0), "synchronous ResourceHandle preserves framing failure");
            check(bytes.size() == (truncated ? 3 : 5), "synchronous ResourceHandle retains the actually delivered bytes");
            printf("synchronous ResourceHandle %s error=%d bytes=%zu\n", url.characters(), error.errorCode(), bytes.size());
        }
        printf("Cocoa curl ResourceHandle: FAILED=%u\n", failures);
    }
    return failures ? 1 : 0;
}
