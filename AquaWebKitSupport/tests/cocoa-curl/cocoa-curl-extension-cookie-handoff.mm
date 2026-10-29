// A WK1 download retries an adopted 401 with its original extension cookie authority.
#include "config.h"
#include <WebCore/AuthenticationChallenge.h>
#include <WebCore/CocoaCookie.h>
#include <WebCore/CocoaCurlResourceHandle.h>
#include <WebCore/NetworkingContext.h>
#include <WebCore/ResourceHandle.h>
#include <WebCore/ResourceHandleClient.h>
#include <WebCore/SecurityOrigin.h>
#include <WebCore/SecurityPolicy.h>
#include <WebKitLegacy/WebDownload.h>
#include <pal/SessionID.h>
#include <wtf/MainThread.h>
#include <wtf/ProcessPrivilege.h>
#include <Foundation/Foundation.h>
#include <cstdio>
#include <dlfcn.h>

using namespace WebCore;
static unsigned failures;
static void check(bool result, const char* message)
{
    printf("%s %s\n", result ? "PASS" : "FAIL", message);
    failures += !result;
}

@interface WebDownload (ExtensionCookieHandoff)
- (instancetype)_initWithCurlResourceHandle:(CocoaCurlResourceHandle&)handle delegate:(id)delegate;
@end

@interface CookieDestination : NSObject <NSURLDownloadDelegate> {
@public
    NSString* path;
    unsigned challenges;
    bool done;
    NSInteger error;
}
@end
@implementation CookieDestination
- (void)dealloc { [path release]; [super dealloc]; }
- (void)download:(NSURLDownload*)download decideDestinationWithSuggestedFilename:(NSString*)name { [download setDestination:path allowOverwrite:NO]; }
- (void)download:(NSURLDownload*)download didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge*)challenge
{
    ++challenges;
    check(challenges == 1, "the adopted download handles one authentication retry");
    if (challenges != 1) {
        [[challenge sender] cancelAuthenticationChallenge:challenge];
        return;
    }
    [[challenge sender] useCredential:[NSURLCredential credentialWithUser:@"cookie-test" password:@"cookie-password" persistence:NSURLCredentialPersistenceNone] forAuthenticationChallenge:challenge];
}
- (void)downloadDidFinish:(NSURLDownload*)download { done = true; CFRunLoopStop(CFRunLoopGetMain()); }
- (void)download:(NSURLDownload*)download didFailWithError:(NSError*)failure { error = failure.code; CFRunLoopStop(CFRunLoopGetMain()); }
@end

class CookieContext final : public NetworkingContext {
public:
    static Ref<CookieContext> create(NetworkStorageSession& storage) { return adoptRef(*new CookieContext(storage)); }
    NetworkStorageSession* storageSession() const final { return &m_storage; }
    bool shouldClearReferrerOnHTTPSToHTTPRedirect() const final { return true; }
    bool localFileContentSniffingEnabled() const final { return false; }
    RetainPtr<CFDataRef> sourceApplicationAuditData() const final { return nullptr; }
    ResourceError blockedError(const ResourceRequest& request) const final { return ResourceError(NSURLErrorDomain, NSURLErrorCannotLoadFromNetwork, request.url(), "Blocked cookie fixture"_s); }
private:
    explicit CookieContext(NetworkStorageSession& storage) : m_storage(storage) { }
    NetworkStorageSession& m_storage;
};

class CookieHandoff final : public ResourceHandleClient {
public:
    explicit CookieHandoff(CookieDestination* destination) : m_destination(destination) { }
    ~CookieHandoff() { [m_download cancel]; }
    unsigned challenges { 0 };
    bool adopted { false };
private:
    void willSendRequestAsync(ResourceHandle*, ResourceRequest&& request, ResourceResponse&&, CompletionHandler<void(ResourceRequest&&)>&& completion) final { completion(WTF::move(request)); }
#if USE(PROTECTION_SPACE_AUTH_CALLBACK)
    void canAuthenticateAgainstProtectionSpaceAsync(ResourceHandle*, const ProtectionSpace&, CompletionHandler<void(bool)>&& completion) final { completion(true); }
#endif
    void didReceiveAuthenticationChallenge(ResourceHandle*, const AuthenticationChallenge& challenge) final
    {
        ++challenges;
        auto native = challenge.nsURLAuthenticationChallenge();
        [[native sender] continueWithoutCredentialForAuthenticationChallenge:native];
    }
    void didReceiveResponseAsync(ResourceHandle* handle, ResourceResponse&& response, CompletionHandler<void()>&& completion) final
    {
        check(response.httpStatusCode() == 401, "the ResourceHandle offers its declined 401 for handoff");
        m_download = adoptNS([[WebDownload alloc] _initWithCurlResourceHandle:*handle->cocoaCurlHandle() delegate:m_destination.get()]);
        adopted = !!m_download;
        check(adopted, "WebDownload adopts the live WK1 response");
        completion();
        if (!adopted)
            CFRunLoopStop(CFRunLoopGetMain());
    }
    void didFail(ResourceHandle*, const ResourceError& error) final
    {
        check(false, "ResourceHandle reaches response handoff");
        printf("ResourceHandle error=%d\n", error.errorCode());
        CFRunLoopStop(CFRunLoopGetMain());
    }
    RetainPtr<CookieDestination> m_destination;
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
        URL extension { "safari-extension://cookie-handoff/page.html"_s };
        URL target { "http://127.0.0.1:18982/cookie-handoff"_s };
        Ref origin = SecurityOrigin::create(extension);
        SecurityPolicy::addOriginAccessAllowlistEntry(origin, "http"_s, "127.0.0.1"_s, false);
        [storage.nsCookieStorage() setCookieAcceptPolicy:NSHTTPCookieAcceptPolicyAlways];
        for (auto field : { "extck_handoff_read_none=1; Path=/; SameSite=None"_s, "extck_handoff_read_lax=1; Path=/; SameSite=Lax"_s, "extck_handoff_read_strict=1; Path=/; SameSite=Strict; HttpOnly"_s })
            storage.setCookie(*parseHTTPSetCookie(field, target), target, target);
        [storage.nsCookieStorage() setCookieAcceptPolicy:NSHTTPCookieAcceptPolicyOnlyFromMainDocumentDomain];
        storage.setTrackingPreventionEnabled(true);
        storage.setThirdPartyCookieBlockingMode(ThirdPartyCookieBlockingMode::All);
        NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
        Ref context = CookieContext::create(storage);
        {
            RetainPtr destination = adoptNS([CookieDestination new]);
            destination->path = [[directory stringByAppendingPathComponent:@"cookies.json"] retain];
            CookieHandoff client(destination.get());
            ResourceRequest request { URL { target } };
            request.setTimeoutInterval(10);
            request.setFirstPartyForCookies(extension);
            request.setIsSameSite(false);
            request.setIsTopSite(false);
            RefPtr handle = ResourceHandle::create(context.ptr(), request, &client, false, false, ContentEncodingSniffingPolicy::Default, origin.copyRef(), false);
            auto deadline = adoptCF(CFRunLoopTimerCreateWithHandler(nullptr, CFAbsoluteTimeGetCurrent() + 20, 0, 0, 0, ^(CFRunLoopTimerRef) {
                check(false, "cookie handoff completes before deadline");
                CFRunLoopStop(CFRunLoopGetMain());
            }));
            CFRunLoopAddTimer(CFRunLoopGetMain(), deadline.get(), kCFRunLoopDefaultMode);
            CFRunLoopRun();
            CFRunLoopTimerInvalidate(deadline.get());
            check(client.adopted && client.challenges == 1 && destination->challenges == 1 && destination->done && !destination->error,
                "the adopted WebDownload owns the successful authenticated exchange");
            NSData* data = [NSData dataWithContentsOfFile:destination->path];
            NSDictionary* response = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSDictionary* sent = response[@"cookies"];
            for (NSString* kind in @[@"none", @"lax", @"strict"]) {
                check([sent[[@"extck_handoff_read_" stringByAppendingString:kind]] isEqual:@"1"], "download retry sends the original extension cookie");
                NSString* name = [@"extck_handoff_written_" stringByAppendingString:kind];
                bool found = false;
                for (NSHTTPCookie* cookie in [storage.nsCookieStorage() cookies])
                    found |= [cookie.name isEqual:name] && [cookie.value isEqual:@"1"];
                check(found, "download response stores its extension cookie");
            }
        }
        SecurityPolicy::removeOriginAccessAllowlistEntry(origin, "http"_s, "127.0.0.1"_s, false);
        storage.deleteAllCookies([] { });
        [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
        printf("WK1 extension cookie handoff: FAILED=%u\n", failures);
    }
    return failures ? 1 : 0;
}
