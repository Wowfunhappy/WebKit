// Native selected SecIdentity signs real TLS 1.2 and TLS 1.3 client-certificate handshakes.
#include "config.h"
#include <WebCore/CocoaCurlConnection.h>
#include <WebCore/ResourceError.h>
#include <WebCore/SharedBuffer.h>
#include <wtf/MainThread.h>
#include <Foundation/Foundation.h>
#include <Security/Security.h>
#include <cstdio>
#include <openssl/x509.h>
#include <openssl/evp.h>
#include <openssl/rsa.h>
#include <openssl/ec.h>
#include <openssl/ecdsa.h>
extern "C" OSStatus SecCertificateCopyPublicKey(SecCertificateRef, SecKeyRef*);
using namespace WebCore;
static unsigned failures;
class IdentityProbe final : public RefCounted<IdentityProbe>, public CocoaCurlTransferClient {
public:
    static bool run(SecIdentityRef identity, CFArrayRef serverChain, unsigned port, bool supply)
    {
        Ref probe = adoptRef(*new IdentityProbe(identity, supply));
        Ref pool = CocoaCurlConnectionPool::create();
        CocoaCurlTransferOptions options;
        options.request = ResourceRequest(URL { makeString("https://127.0.0.1:"_s, port, "/client-certificate"_s) });
        options.request.setTimeoutInterval(10);
        options.acceptedCertificateChain = serverChain;
        probe->m_connection = CocoaCurlConnection::create(pool, probe, WTF::move(options));
        probe->m_connection->start();
        auto deadline = adoptCF(CFRunLoopTimerCreateWithHandler(nullptr, CFAbsoluteTimeGetCurrent() + 15, 0, 0, 0, ^(CFRunLoopTimerRef) { CFRunLoopStop(CFRunLoopGetMain()); }));
        CFRunLoopAddTimer(CFRunLoopGetMain(), deadline.get(), kCFRunLoopDefaultMode);
        CFRunLoopRun();
        CFRunLoopTimerInvalidate(deadline.get());
        bool passed = probe->m_done && probe->m_challenges == 1 && (supply ? probe->m_status == 200 && probe->m_body == "mTLS"_s && !probe->m_error : !probe->m_status && probe->m_error == (port == 19448 ? NSURLErrorClientCertificateRequired : NSURLErrorSecureConnectionFailed));
        printf("selected SecIdentity: TLS%s supply=%d challenges=%u status=%d bytes=%u error=%d %s\n", port == 19447 ? "1.2" : "1.3", supply, probe->m_challenges, probe->m_status, probe->m_body.length(), probe->m_error, passed ? "PASS" : "FAIL");
        probe->m_connection->invalidateClient();
        probe->m_connection = nullptr;
        return passed;
    }
    void ref() const final { RefCounted::ref(); }
    void deref() const final { RefCounted::deref(); }
private:
    IdentityProbe(SecIdentityRef identity, bool supply) : m_identity(identity), m_supply(supply) { }
    void curlReceivedCookies(Vector<String>&&, CompletionHandler<void(std::optional<String>&&)>&& completion) final { completion(std::nullopt); }
    void curlReceivedResponse(CocoaCurlTransferResponse&& response, CompletionHandler<void()>&& completion) final { m_status = response.response.httpStatusCode(); completion(); }
    void curlReceivedData(const SharedBuffer& data, CompletionHandler<void()>&& completion) final { m_body = makeString(m_body, String::fromUTF8(data.span())); completion(); }
    void curlSentData(uint64_t, uint64_t) final { }
    void curlReceivedInformationalResponse(ResourceResponse&&) final { }
    void curlRequestedIdentity(CFArrayRef, CompletionHandler<void(RetainPtr<SecIdentityRef>&&, RetainPtr<CFArrayRef>&&)>&& completion) final
    {
        ASSERT(isMainThread());
        ++m_challenges;
        completion(m_supply ? RetainPtr<SecIdentityRef>(m_identity) : nullptr, nullptr);
    }
    void curlCompleted(const ResourceError& error, const NetworkLoadMetrics&) final
    {
        m_error = error.errorCode();
        if (m_error) NSLog(@"TLS failure: %@", error.nsError());
        m_done = true;
        CFRunLoopStop(CFRunLoopGetMain());
    }
    RetainPtr<SecIdentityRef> m_identity;
    RefPtr<CocoaCurlConnection> m_connection;
    String m_body;
    int m_status { 0 };
    int m_error { 0 };
    unsigned m_challenges { 0 };
    bool m_supply;
    bool m_done { false };
};
int main()
{
    @autoreleasepool {
        setvbuf(stdout, nullptr, _IONBF, 0);
        WTF::initializeMainThread();
        char directory[] = "/private/tmp/curl-mtls-keychain-XXXXXX";
        RELEASE_ASSERT(mkdtemp(directory));
        NSString* path = [[NSString stringWithUTF8String:directory] stringByAppendingPathComponent:@"fixture.keychain"];
        SecKeychainRef rawKeychain = nullptr;
        OSStatus status = SecKeychainCreate(path.fileSystemRepresentation, 7, "fixture", false, nullptr, &rawKeychain);
        if (status) { printf("SecKeychainCreate failed: %d\n", status); return 1; }
        auto keychain = adoptCF(rawKeychain);
        for (NSString* fixture in @[@"identity.p12", @"ec-identity.p12"]) {
        printf("identity fixture %s\n", fixture.UTF8String);
        NSData* pkcs12 = [NSData dataWithContentsOfFile:[@"/private/tmp/curl-identity-test" stringByAppendingPathComponent:fixture]];
        NSDictionary* options = @{ (id)kSecImportExportPassphrase: @"fixture", (id)kSecImportExportKeychain: (id)keychain.get() };
        CFArrayRef rawItems = nullptr;
        status = SecPKCS12Import((CFDataRef)pkcs12, (CFDictionaryRef)options, &rawItems);
        if (status) { printf("SecPKCS12Import failed: %d\n", status); SecKeychainDelete(keychain.get()); return 1; }
        auto items = adoptCF(rawItems);
        SecIdentityRef identity = (SecIdentityRef)[(NSArray*)items.get() objectAtIndex:0][(id)kSecImportItemIdentity];
        NSData* der = [NSData dataWithContentsOfFile:@"/private/tmp/curl-identity-test/server.der"];
        auto serverCertificate = adoptCF(SecCertificateCreateWithData(nullptr, (CFDataRef)der));
        RELEASE_ASSERT(serverCertificate);
        auto chain = adoptCF(CFArrayCreateMutable(nullptr, 0, &kCFTypeArrayCallBacks));
        CFArrayAppendValue(chain.get(), serverCertificate.get());
        for (unsigned port : {19447, 19448})
            for (bool supply : {true, false}) failures += !IdentityProbe::run(identity, chain.get(), port, supply);
        }
        SecKeychainDelete(keychain.get());
        printf("Cocoa curl client certificates: FAILED=%u\n", failures);
        return failures ? 1 : 0;
    }
}
