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
@interface NativeDeliveryProbe : NSObject <NSURLConnectionDataDelegate> {
@public
    NSUInteger bytes;
    NSUInteger responses;
    NSInteger errorCode;
    BOOL finished;
}
@end
@implementation NativeDeliveryProbe
- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response { ++responses; }
- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data { bytes += data.length; }
- (void)connectionDidFinishLoading:(NSURLConnection *)connection { finished = YES; CFRunLoopStop(CFRunLoopGetCurrent()); }
- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error { errorCode = error.code; finished = YES; CFRunLoopStop(CFRunLoopGetCurrent()); }
@end

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
        mimeType = response.mimeType();
        ++responseCount;
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
public:
    unsigned responseCount { 0 };
    String mimeType;
    uint64_t deliveredBytes() const { return bytes; }
    int deliveredError() const { return error; }
};

class PausedResponses final : public ResourceHandleClient {
public:
    void run(Context& context)
    {
        // Fill the scheduler's six per-host connections with unacknowledged response policies.
        Vector<RefPtr<ResourceHandle>> handles;
        ResourceRequest request(URL { "http://127.0.0.1:18981/probe/baseline"_s });
        request.setFirstPartyForCookies(request.url());
        request.setTimeoutInterval(10);
        request.setCachePolicy(ResourceRequestCachePolicy::DoNotUseAnyCache);
        for (unsigned i = 0; i < 6; ++i)
            handles.append(ResourceHandle::create(&context, request, this, false, false, ContentEncodingSniffingPolicy::Default, nullptr, true));
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 15, false);
        check(m_pending.size() == handles.size(), "all per-host connections await asynchronous response policy");
        ResourceError error;
        ResourceResponse response;
        Vector<uint8_t> bytes;
        if (m_pending.size() == handles.size()) {
            ResourceHandle::loadResourceSynchronously(&context, request, StoredCredentialsPolicy::DoNotUse, nullptr, error, response, bytes);
            check(error.isNull() && response.httpStatusCode() == 200 && String(bytes.span()) == "HELLO"_s,
                "synchronous load completes while asynchronous response policies remain paused");
            printf("saturated synchronous ResourceHandle pending=%zu status=%d bytes=%zu error=%d\n",
                m_pending.size(), response.httpStatusCode(), bytes.size(), error.errorCode());
        }
        for (auto& completion : m_pending)
            completion();
        m_pending.clear();
        for (auto& handle : handles) {
            if (handle)
                handle->cancel();
        }
    }
private:
    void didReceiveResponseAsync(ResourceHandle*, ResourceResponse&&, CompletionHandler<void()>&& completion) final
    {
        m_pending.append(WTF::move(completion));
        if (m_pending.size() == 6)
            CFRunLoopStop(CFRunLoopGetCurrent());
    }
    void didFail(ResourceHandle*, const ResourceError&) final
    {
        check(false, "asynchronous saturation load succeeds");
        CFRunLoopStop(CFRunLoopGetCurrent());
    }
    void willSendRequestAsync(ResourceHandle*, ResourceRequest&& request, ResourceResponse&&, CompletionHandler<void(ResourceRequest&&)>&& completion) final { completion(WTF::move(request)); }
    void canAuthenticateAgainstProtectionSpaceAsync(ResourceHandle*, const ProtectionSpace&, CompletionHandler<void(bool)>&& completion) final { completion(true); }
    bool shouldUseCredentialStorage(ResourceHandle*) final { return false; }
    Vector<CompletionHandler<void()>> m_pending;
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
        PausedResponses { }.run(context);
        for (auto url : { "http://127.0.0.1:18981/probe/_mime_separate"_s,
                          "http://127.0.0.1:18981/probe/_mime_reversed"_s,
                          "http://127.0.0.1:18981/probe/_mime_combined"_s,
                          "http://127.0.0.1:18981/probe/_mime_empty_last"_s }) {
            Probe probe;
            probe.run(context, url, 0);
            NSURLResponse *native = nil;
            NSError *error = nil;
            NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:String(url).createNSString().get()] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10];
            NSData *data = [NSURLConnection sendSynchronousRequest:request returningResponse:&native error:&error];
            bool matches = !error && data.length == probe.deliveredBytes() && probe.mimeType == String(native.MIMEType);
            check(matches, "ResourceHandle uses the native effective MIME type after body sniffing");
            printf("MIME ResourceHandle %s curl=%s native=%s %s\n", url.characters(), probe.mimeType.utf8().data(), native.MIMEType.UTF8String, matches ? "PASS" : "FAIL");
        }
        Probe { }.run(context, "http://127.0.0.1:18981/probe/baseline"_s, 0);
        Probe { }.run(context, "http://127.0.0.1:18981/probe/chunk_short_data"_s, NSURLErrorNetworkConnectionLost);
        Probe { }.run(context, "http://127.0.0.1:18981/probe/redirect_limit_20"_s, 0, 20);
        Probe { }.run(context, "http://127.0.0.1:18981/probe/redirect_limit_21"_s, NSURLErrorHTTPTooManyRedirects, 20);
        Probe { }.run(context, "http://127.0.0.1:18982/basic"_s, 0);
        Probe { }.run(context, "https://127.0.0.1:19446/"_s, NSURLErrorServerCertificateUntrusted);
        // A body the connection close delimits reaches this client whole; one a declared length says is
        // longer than what arrived does not.
        Probe { }.run(context, "https://127.0.0.1:19449/close-delimited"_s, 0);
        Probe { }.run(context, "https://127.0.0.1:19449/short-length"_s, NSURLErrorNetworkConnectionLost);
        {
            // multipart/x-mixed-replace carries no length and no chunked coding of its own: the parts
            // end where the connection does, and each one reaches this client as a response of its own.
            Probe multipart;
            multipart.run(context, "https://127.0.0.1:19449/multipart"_s, 0);
            // The stream's own response, then one per part.
            check(multipart.responseCount == 3, "each multipart part arrives as its own response");
            check(multipart.deliveredBytes() == 11, "every multipart part body is delivered");
            printf("ResourceHandle multipart responses=%u bytes=%llu error=%d\n", multipart.responseCount,
                static_cast<unsigned long long>(multipart.deliveredBytes()), multipart.deliveredError());
        }
        Ref customContext = Context::create(storage, true);
        Probe { }.run(customContext, "http://127.0.0.1:18981/probe/baseline"_s, 0);
        Probe customMultipart;
        customMultipart.run(customContext, "https://127.0.0.1:19449/multipart"_s, 0);
        check(customMultipart.responseCount == 3 && customMultipart.deliveredBytes() == 11,
            "multipart policy and body callbacks honor the custom run-loop mode");
        for (auto url : { "http://127.0.0.1:18981/probe/baseline"_s, "http://127.0.0.1:18981/probe/chunk_short_data"_s }) {
            ResourceRequest request(URL { url });
            request.setTimeoutInterval(10);
            ResourceError error;
            ResourceResponse response;
            Vector<uint8_t> bytes;
            ResourceHandle::loadResourceSynchronously(context.ptr(), request, StoredCredentialsPolicy::DoNotUse, nullptr, error, response, bytes);
            bool truncated = StringView(url).endsWith("chunk_short_data"_s);
            check(error.errorCode() == (truncated ? NSURLErrorNetworkConnectionLost : 0), "synchronous ResourceHandle preserves framing failure");
            auto native = adoptNS([[NativeDeliveryProbe alloc] init]);
            NSURLRequest *nativeRequest = [NSURLRequest requestWithURL:[NSURL URLWithString:String(url).createNSString().get()] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10];
            auto connection = adoptNS([[NSURLConnection alloc] initWithRequest:nativeRequest delegate:native.get() startImmediately:NO]);
            [connection scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
            [connection start];
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 15, false);
            [connection cancel];
            check(native->finished && bytes.size() == native->bytes && !!error.errorCode() == !!native->errorCode,
                "synchronous ResourceHandle matches native delivered bytes and success/failure");
            printf("native framing %s responses=%lu bytes=%lu error=%ld\n", url.characters(), (unsigned long)native->responses, (unsigned long)native->bytes, (long)native->errorCode);
            printf("synchronous ResourceHandle %s error=%d bytes=%zu\n", url.characters(), error.errorCode(), bytes.size());
        }
        printf("Cocoa curl ResourceHandle: FAILED=%u\n", failures);
    }
    return failures ? 1 : 0;
}
