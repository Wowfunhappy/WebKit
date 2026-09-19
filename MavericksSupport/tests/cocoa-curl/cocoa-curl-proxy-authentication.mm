// Authenticate through a configured CF proxy route and the native challenge/sender contract, and check that a
// WebKitLegacy load through an authenticating proxy follows ResourceHandle's proxy rule.
#include "config.h"
#include "NetworkingContext.h"
#include <WebCore/AuthenticationChallenge.h>
#include <WebCore/CocoaCurlConnection.h>
#include <WebCore/SecurityOrigin.h>
#include <WebCore/NetworkStorageSession.h>
#include <WebCore/ResourceHandle.h>
#include <WebCore/ResourceHandleClient.h>
#include <pal/SessionID.h>
#include <wtf/ProcessPrivilege.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/mach.h>
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

// WebKitLegacy loads take the system's proxy settings. For the WebKitLegacy case, WebCore's own binding of
// CFNetworkCopySystemProxySettings is pointed at settings that name the proxy fixture, in this process only.
static bool routeThroughFixture;
static CFDictionaryRef (*systemProxySettings)();
static CFDictionaryRef fixtureSystemProxySettings()
{
    if (!routeThroughFixture)
        return systemProxySettings();
    return (CFDictionaryRef)CFBridgingRetain(@{ @"HTTPEnable": @1, @"HTTPProxy": @"localhost", @"HTTPPort": @18985 });
}
static bool rebindInImage(const mach_header_64* header, intptr_t slide, const char* symbolName, void* replacement)
{
    const segment_command_64* linkedit = nullptr;
    const symtab_command* symtab = nullptr;
    const dysymtab_command* dysymtab = nullptr;
    auto* command = reinterpret_cast<const load_command*>(header + 1);
    for (uint32_t i = 0; i < header->ncmds; ++i, command = reinterpret_cast<const load_command*>(reinterpret_cast<const char*>(command) + command->cmdsize)) {
        if (command->cmd == LC_SEGMENT_64 && !strcmp(reinterpret_cast<const segment_command_64*>(command)->segname, SEG_LINKEDIT))
            linkedit = reinterpret_cast<const segment_command_64*>(command);
        else if (command->cmd == LC_SYMTAB)
            symtab = reinterpret_cast<const symtab_command*>(command);
        else if (command->cmd == LC_DYSYMTAB)
            dysymtab = reinterpret_cast<const dysymtab_command*>(command);
    }
    if (!linkedit || !symtab || !dysymtab)
        return false;
    uintptr_t linkeditBase = slide + linkedit->vmaddr - linkedit->fileoff;
    auto* symbols = reinterpret_cast<const nlist_64*>(linkeditBase + symtab->symoff);
    auto* strings = reinterpret_cast<const char*>(linkeditBase + symtab->stroff);
    auto* indirect = reinterpret_cast<const uint32_t*>(linkeditBase + dysymtab->indirectsymoff);
    bool rebound = false;
    command = reinterpret_cast<const load_command*>(header + 1);
    for (uint32_t i = 0; i < header->ncmds; ++i, command = reinterpret_cast<const load_command*>(reinterpret_cast<const char*>(command) + command->cmdsize)) {
        if (command->cmd != LC_SEGMENT_64)
            continue;
        auto* segment = reinterpret_cast<const segment_command_64*>(command);
        auto* sections = reinterpret_cast<const section_64*>(segment + 1);
        for (uint32_t j = 0; j < segment->nsects; ++j) {
            uint32_t type = sections[j].flags & SECTION_TYPE;
            if (type != S_LAZY_SYMBOL_POINTERS && type != S_NON_LAZY_SYMBOL_POINTERS)
                continue;
            auto* pointers = reinterpret_cast<void**>(slide + sections[j].addr);
            for (uint64_t k = 0; k < sections[j].size / sizeof(void*); ++k) {
                uint32_t symbolIndex = indirect[sections[j].reserved1 + k];
                if (symbolIndex & (INDIRECT_SYMBOL_ABS | INDIRECT_SYMBOL_LOCAL))
                    continue;
                if (strcmp(strings + symbols[symbolIndex].n_un.n_strx, symbolName))
                    continue;
                vm_protect(mach_task_self(), reinterpret_cast<vm_address_t>(pointers), sections[j].size, false, VM_PROT_READ | VM_PROT_WRITE);
                pointers[k] = replacement;
                rebound = true;
            }
        }
    }
    return rebound;
}
static bool routeWebCoreProxySettingsThroughFixture()
{
    systemProxySettings = CFNetworkCopySystemProxySettings;
    for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
        if (strstr(_dyld_get_image_name(i), "/WebCore.framework/"))
            return rebindInImage(reinterpret_cast<const mach_header_64*>(_dyld_get_image_header(i)), _dyld_get_image_vmaddr_slide(i), "_CFNetworkCopySystemProxySettings", reinterpret_cast<void*>(fixtureSystemProxySettings));
    }
    return false;
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

// ResourceHandle::didReceiveAuthenticationChallenge continues a proxy challenge without a credential, so the
// client sees no challenge and receives the 407 as the load's response.
class LegacyProxyProbe final : public ResourceHandleClient {
public:
    void run(Context& context)
    {
        ResourceRequest request(URL { "http://proxy-target.invalid/basic"_s });
        request.setTimeoutInterval(15);
        auto handle = ResourceHandle::create(&context, request, this, false, true, ContentEncodingSniffingPolicy::Default, nullptr, true);
        check(!!handle, "ResourceHandle created");
        if (!handle)
            return;
        CFRunLoopRun();
        check(!m_error && m_status == 407 && !m_challenges, "a WebKitLegacy proxy challenge delivers the 407 to the client");
        printf("WebKitLegacy proxy status=%d challenges=%u error=%d\n", m_status, m_challenges, m_error);
    }
private:
    void willSendRequestAsync(ResourceHandle*, ResourceRequest&& request, ResourceResponse&&, CompletionHandler<void(ResourceRequest&&)>&& completion) final { completion(WTF::move(request)); }
    void didReceiveResponseAsync(ResourceHandle*, ResourceResponse&& response, CompletionHandler<void()>&& completion) final
    {
        m_status = response.httpStatusCode();
        completion();
    }
    void didReceiveData(ResourceHandle*, const SharedBuffer&, int) final { }
    void didFinishLoading(ResourceHandle*, const NetworkLoadMetrics&) final { CFRunLoopStop(CFRunLoopGetMain()); }
    void didFail(ResourceHandle*, const ResourceError& error) final
    {
        m_error = error.errorCode();
        CFRunLoopStop(CFRunLoopGetMain());
    }
    void didReceiveAuthenticationChallenge(ResourceHandle*, const AuthenticationChallenge& challenge) final
    {
        ++m_challenges;
        [challenge.sender() cancelAuthenticationChallenge:challenge.nsURLAuthenticationChallenge()];
    }
#if USE(PROTECTION_SPACE_AUTH_CALLBACK)
    void canAuthenticateAgainstProtectionSpaceAsync(ResourceHandle*, const ProtectionSpace&, CompletionHandler<void(bool)>&& completion) final { completion(true); }
#endif
    int m_status { 0 };
    int m_error { 0 };
    unsigned m_challenges { 0 };
};
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
        CocoaCurlTransferOptions options(tls_protocol_version_TLSv12);
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
    void curlReceivedCookies(Vector<String>&&, const String&, const String&, CompletionHandler<void(std::optional<String>&&)>&& completion) final { completion(std::nullopt); }
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
    // The platform's own evaluation of the server chain is the answer.
    void curlRequestedServerTrust(CompletionHandler<void(bool)>&& completion) final
    {
        auto tls = m_connection->tlsState();
        completion(tls && tls->accepted);
    }
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
        {
            setProcessPrivileges({ ProcessPrivilege::CanAccessRawCookies, ProcessPrivilege::CanAccessCredentials });
            NetworkStorageSession::permitProcessToUseCookieAPI(true);
            auto createStorage = reinterpret_cast<CFHTTPCookieStorageRef (*)(CFAllocatorRef, CFDictionaryRef)>(dlsym(RTLD_DEFAULT, "CFHTTPCookieStorageCreateInMemory"));
            RELEASE_ASSERT(createStorage);
            NetworkStorageSession storage(PAL::SessionID::generateEphemeralSessionID(), nullptr, adoptCF(createStorage(kCFAllocatorDefault, nullptr)), NetworkStorageSession::IsInMemoryCookieStore::Yes);
            Ref context = Context::create(storage);
            check(routeWebCoreProxySettingsThroughFixture(), "WebCore's proxy settings binding reaches the fixture");
            routeThroughFixture = true;
            LegacyProxyProbe { }.run(context);
            routeThroughFixture = false;
        }
        auto after = adoptCF(CFNetworkCopySystemProxySettings());
        check(before && after && CFEqual(before.get(), after.get()), "system proxy settings remain unchanged");
        printf("Cocoa curl proxy authentication: FAILED=%u\n", failures);
    }
    return failures ? 1 : 0;
}
