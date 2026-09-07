// ResourceHandle response policy transfers its actual connection/buffer/error to native WebDownload.
#include "config.h"
#include <wtf/Assertions.h>
#include <WebCore/NetworkingContext.h>
#include <WebCore/CocoaCurlResourceHandle.h>
#include <WebCore/ResourceHandle.h>
#include <WebCore/ResourceHandleClient.h>
#include <WebCore/SharedBuffer.h>
#include <WebCore/SecurityOrigin.h>
#include <WebKitLegacy/WebDownload.h>
#include <wtf/MainThread.h>
#include <wtf/ProcessPrivilege.h>
#include <pal/SessionID.h>
#include <Foundation/Foundation.h>
#include <dlfcn.h>
#include <cstdio>
using namespace WebCore;
static unsigned failures;
static void check(bool result, const char* name) { if (!result) { ++failures; printf("FAIL %s\n", name); } }
@interface WebDownload (CurlHandoffTest)
- (instancetype)_initWithCurlResourceHandle:(CocoaCurlResourceHandle&)handle delegate:(id)delegate;
@end
@interface Destination : NSObject <NSURLDownloadDelegate> {
@public
    NSString* path;
    NSInteger error;
    bool done;
    unsigned responses;
}
@end
@implementation Destination
- (void)download:(NSURLDownload*)download didReceiveResponse:(NSURLResponse*)response { ++responses; }
- (void)download:(NSURLDownload*)download decideDestinationWithSuggestedFilename:(NSString*)name { [download setDestination:path allowOverwrite:NO]; }
- (void)downloadDidFinish:(NSURLDownload*)download { done = true; CFRunLoopStop(CFRunLoopGetMain()); }
- (void)download:(NSURLDownload*)download didFailWithError:(NSError*)failure { error = failure.code; done = true; CFRunLoopStop(CFRunLoopGetMain()); }
@end
class Context final : public NetworkingContext {
public:
    static Ref<Context> create(NetworkStorageSession& storage) { return adoptRef(*new Context(storage)); }
    NetworkStorageSession* storageSession() const final { return &m_storage; }
    bool shouldClearReferrerOnHTTPSToHTTPRedirect() const final { return true; }
    bool localFileContentSniffingEnabled() const final { return false; }
    RetainPtr<CFDataRef> sourceApplicationAuditData() const final { return nullptr; }
    ResourceError blockedError(const ResourceRequest& request) const final { return ResourceError(NSURLErrorDomain, NSURLErrorCannotLoadFromNetwork, request.url(), "Blocked test request"_s); }
private:
    explicit Context(NetworkStorageSession& storage) : m_storage(storage) { }
    NetworkStorageSession& m_storage;
};
class Handoff final : public ResourceHandleClient {
public:
    Handoff(Destination* destination) : m_destination(destination) { }
    ~Handoff() { [m_download cancel]; }
private:
    void willSendRequestAsync(ResourceHandle*, ResourceRequest&& request, ResourceResponse&&, CompletionHandler<void(ResourceRequest&&)>&& completion) final { completion(WTF::move(request)); }
#if USE(PROTECTION_SPACE_AUTH_CALLBACK)
    void canAuthenticateAgainstProtectionSpaceAsync(ResourceHandle*, const ProtectionSpace&, CompletionHandler<void(bool)>&& completion) final { completion(true); }
#endif
    void didReceiveResponseAsync(ResourceHandle* handle, ResourceResponse&&, CompletionHandler<void()>&& completion) final
    {
        check(!!handle->cocoaCurlHandle(), "ResourceHandle owns the curl transfer");
        m_download = adoptNS([[WebDownload alloc] _initWithCurlResourceHandle:*handle->cocoaCurlHandle() delegate:m_destination.get()]);
        check(!!m_download, "native download adopted the response policy state");
        [m_download setDeletesFileUponFailure:NO];
        completion();
        if (!m_download) CFRunLoopStop(CFRunLoopGetMain());
    }
    void didReceiveData(ResourceHandle*, const SharedBuffer&, int) final { check(false, "adopted data must reach the download owner"); }
    void didFinishLoading(ResourceHandle*, const NetworkLoadMetrics&) final { check(false, "adopted completion must reach the download owner"); CFRunLoopStop(CFRunLoopGetMain()); }
    void didFail(ResourceHandle*, const ResourceError& error) final { check(false, "adopted failure must reach the download owner"); printf("old loader error %d\n", error.errorCode()); CFRunLoopStop(CFRunLoopGetMain()); }
    RetainPtr<Destination> m_destination;
    RetainPtr<WebDownload> m_download;
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
        NetworkStorageSession storage(PAL::SessionID::generateEphemeralSessionID(), nullptr, adoptCF(createStorage(nullptr, nullptr)), NetworkStorageSession::IsInMemoryCookieStore::Yes);
        Ref context = Context::create(storage);
        for (auto endpoint : { "http://127.0.0.1:18981/probe/baseline", "http://127.0.0.1:18981/probe/_download_404_body", "http://127.0.0.1:18981/probe/chunk_short_data", "http://127.0.0.1:18982/file" }) {
            char directory[] = "/private/tmp/curl-handoff-XXXXXX";
            RELEASE_ASSERT(mkdtemp(directory));
            RetainPtr destination = adoptNS([Destination new]);
            destination->path = [[[NSString stringWithUTF8String:directory] stringByAppendingPathComponent:@"download.bin"] retain];
            Handoff client(destination.get());
            ResourceRequest request(URL { String::fromUTF8([[NSString stringWithFormat:@"%s?handoff=%@", endpoint, [NSUUID UUID].UUIDString] UTF8String]) });
            request.setTimeoutInterval(10);
            request.setFirstPartyForCookies(request.url());
            request.setIsTopSite(true);
            RefPtr handle = ResourceHandle::create(context.ptr(), request, &client, false, true, ContentEncodingSniffingPolicy::Default, nullptr, true);
            auto deadline = adoptCF(CFRunLoopTimerCreateWithHandler(nullptr, CFAbsoluteTimeGetCurrent() + 15, 0, 0, 0, ^(CFRunLoopTimerRef) { check(false, "handoff deadline"); CFRunLoopStop(CFRunLoopGetMain()); }));
            CFRunLoopAddTimer(CFRunLoopGetMain(), deadline.get(), kCFRunLoopDefaultMode);
            CFRunLoopRun();
            CFRunLoopTimerInvalidate(deadline.get());
            NSData* data = [NSData dataWithContentsOfFile:destination->path];
            bool partial = strstr(endpoint, "chunk_short_data");
            bool large = strstr(endpoint, "18982");
            check(destination->done && destination->responses == 1, "download gets one response and one terminal event");
            check(destination->error == (partial ? NSURLErrorNetworkConnectionLost : 0), "handoff preserves terminal result, and an adopted 404 is saved");
            bool matches = data.length == (large ? 2097152 : partial ? 3 : 5);
            const auto* bytes = static_cast<const uint8_t*>(data.bytes);
            for (size_t i = 0; matches && i < data.length; ++i) matches = bytes[i] == (large ? (i & 255) : "HELLO"[i]);
            check(matches, "handoff preserves exact buffered and streamed bytes");
            printf("handoff %s bytes=%lu error=%ld\n", endpoint, (unsigned long)data.length, (long)destination->error);
        }
        printf("Cocoa curl ResourceHandle/WebDownload handoff: FAILED=%u\n", failures);
    }
    return failures ? 1 : 0;
}
