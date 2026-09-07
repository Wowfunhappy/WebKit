// Authenticate through a configured CF proxy route and the native challenge/sender contract.
#include "config.h"
#include <WebCore/CocoaCurlConnection.h>
#include <WebCore/CocoaCurlAuthentication.h>
#include <WebCore/Credential.h>
#include <WebCore/ResourceError.h>
#include <WebCore/SharedBuffer.h>
#include <wtf/MainThread.h>
#include <wtf/text/MakeString.h>
#import <Foundation/Foundation.h>
#import <CFNetwork/CFNetwork.h>
#include <cstdio>
using namespace WebCore;
static unsigned failures;
static void check(bool value, const char* message) { if (!value) { ++failures; printf("FAIL %s\n", message); } }
class Probe final : public RefCounted<Probe>, public CocoaCurlTransferClient {
public:
    static Ref<Probe> create() { return adoptRef(*new Probe); }
    void ref() const final { RefCounted::ref(); }
    void deref() const final { RefCounted::deref(); }
    void run(const String& name)
    {
        m_request = ResourceRequest(URL { makeString("http://proxy-target.invalid/"_s, name) });
        m_request.setTimeoutInterval(15);
        start();
        CFRunLoopRun();
        check(!m_error && m_status == 200 && m_bytes && m_challenges == 1, "proxy challenge completes its authenticated response");
        printf("Proxy %s status=%d bytes=%zu challenges=%u error=%d\n", name.utf8().data(), m_status, m_bytes, m_challenges, m_error);
    }
private:
    void start()
    {
        CocoaCurlTransferOptions options;
        options.request = m_request;
        options.proxySettings = (__bridge CFDictionaryRef)@{ @"HTTPEnable": @1, @"HTTPProxy": @"localhost", @"HTTPPort": @18985 };
        options.proxyCredentialHost = "localhost"_s;
        options.proxyCredentialPort = 18985;
        options.proxyAuthentication = m_authentication;
        options.proxyUser = m_user;
        options.proxyPassword = m_password;
        m_connection = CocoaCurlConnection::create(m_pool, *this, WTF::move(options));
        m_connection->start();
    }
    void curlReceivedCookies(Vector<String>&&, CompletionHandler<void(std::optional<String>&&)>&& completion) final { completion(std::nullopt); }
    void curlReceivedResponse(CocoaCurlTransferResponse&& response, CompletionHandler<void()>&& completion) final
    {
        m_status = response.response.httpStatusCode();
        if (m_status != 407) { completion(); return; }
        ++m_challenges;
        long method = cocoaCurlAuthenticationMethod(response.proxyAuthentication);
        check(method && response.proxyHost == "localhost"_s && response.proxyPort == 18985, "proxy authentication is scoped to its resolved host and port");
        auto space = cocoaCurlProtectionSpace(m_request.url(), response.proxyHost, response.proxyPort, method, response.response.httpHeaderField("Proxy-Authenticate"_s));
        auto challenge = cocoaCurlAuthenticationChallenge(space, { }, m_challenges - 1, response.response, { }, [this, method](CocoaCurlAuthenticationDisposition disposition, RetainPtr<NSURLCredential>&& credential) {
            check(disposition == CocoaCurlAuthenticationDisposition::UseCredential && credential, "the native sender returns the selected credential");
            m_authentication = method;
            m_user = String(credential.get().user);
            m_password = String(credential.get().password);
        });
        check(challenge && challenge.get().protectionSpace.isProxy && [challenge.get().protectionSpace.host isEqualToString:@"localhost"], "native proxy protection space reaches the sender");
        NSString* account = method == CURLAUTH_NEGOTIATE ? @"curl-test@CURL.SWITCHOVER.TEST" : method == CURLAUTH_NTLM ? @"CURL\\curl-test" : @"curl-test";
        [challenge.get().sender useCredential:[NSURLCredential credentialWithUser:account password:@"correct-password" persistence:NSURLCredentialPersistenceNone] forAuthenticationChallenge:challenge.get()];
        m_connection->invalidateClient();
        m_connection = nullptr;
        completion();
        if (m_challenges != 1) { m_error = NSURLErrorUserAuthenticationRequired; CFRunLoopStop(CFRunLoopGetMain()); return; }
        start();
    }
    void curlReceivedInformationalResponse(ResourceResponse&&) final { }
    void curlSentData(uint64_t, uint64_t) final { }
    void curlReceivedData(const SharedBuffer& bytes, CompletionHandler<void()>&& completion) final { m_bytes += bytes.size(); completion(); }
    void curlRequestedIdentity(CFArrayRef, CompletionHandler<void(RetainPtr<SecIdentityRef>&&, RetainPtr<CFArrayRef>&&)>&& completion) final { completion(nullptr, nullptr); }
    void curlCompleted(const ResourceError& error, const NetworkLoadMetrics&) final
    {
        m_error = error.errorCode();
        if (m_error) NSLog(@"proxy transport error: %@", error.nsError());
        m_connection->invalidateClient();
        m_connection = nullptr;
        CFRunLoopStop(CFRunLoopGetMain());
    }
    Ref<CocoaCurlConnectionPool> m_pool { CocoaCurlConnectionPool::create() };
    RefPtr<CocoaCurlConnection> m_connection;
    ResourceRequest m_request;
    String m_user, m_password;
    long m_authentication { 0 };
    int m_error { 0 }, m_status { 0 };
    unsigned m_challenges { 0 };
    size_t m_bytes { 0 };
};
int main()
{
    @autoreleasepool {
        setvbuf(stdout, nullptr, _IONBF, 0);
        WTF::initializeMainThread();
        auto before = adoptCF(CFNetworkCopySystemProxySettings());
        for (auto method : { "basic"_s, "digest"_s, "ntlm"_s }) Probe::create()->run(method);
        auto after = adoptCF(CFNetworkCopySystemProxySettings());
        check(before && after && CFEqual(before.get(), after.get()), "system proxy settings remain unchanged");
        printf("Cocoa curl proxy authentication: FAILED=%u\n", failures);
    }
    return failures ? 1 : 0;
}
