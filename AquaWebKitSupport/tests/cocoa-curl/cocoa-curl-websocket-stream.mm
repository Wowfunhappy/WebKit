// CocoaCurlSocketStream, the connection page WebSockets and WebKit 1's socket streams travel on, with the questions
// a page WebSocket's task answers inside the TLS handshake. The time the client takes to answer does not count
// against the connect limit: a server certificate or a client identity answered after more than that limit still
// opens the stream. A proxy server's failoverTimeout still bounds the attempt through it.
// Expects the fixtures of run.sh: the self-signed server on 19446, and the client-certificate servers on 19447
// (TLS 1.2) and 19448 (TLS 1.3), with the identities in /private/tmp/curl-identity-test.
#include "config.h"
#include <WebCore/CocoaCurlProxyConfiguration.h>
#include <WebCore/CocoaCurlSocketStream.h>
#include <wtf/BlockPtr.h>
#include <wtf/MainThread.h>
#include <wtf/MonotonicTime.h>
#include <wtf/text/MakeString.h>
#include <Foundation/Foundation.h>
#include <Security/Security.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <cstdio>

using namespace WebCore;

static unsigned failures;

struct Result {
    bool opened { false };
    bool failed { false };
    String failure;
    String received;
    unsigned trustQuestions { 0 };
    unsigned identityQuestions { 0 };
    Seconds elapsed;
};

struct Case {
    const char* name;
    uint16_t port;
    Seconds connectTimeout;
    Seconds trustDelay;
    bool acceptTrust { true };
    Seconds identityDelay;
    SecIdentityRef identity { nullptr };
    Vector<CocoaCurlProxyFilterResult> proxyFilterResults;
};

static void after(Seconds delay, Function<void()>&& work)
{
    auto block = makeBlockPtr([work = WTF::move(work)]() mutable { work(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(delay.nanoseconds())), dispatch_get_main_queue(), block.get());
}

static Result run(const Case& test)
{
    Result result;
    bool done = false;
    auto start = MonotonicTime::now();
    CocoaCurlSocketStream::Options options;
    options.url = URL { makeString("wss://127.0.0.1:"_s, test.port, "/websocket"_s) };
    options.port = test.port;
    options.secure = true;
    options.tunnelsPlainConnections = false;
    options.minimumTLSProtocol = tls_protocol_version_TLSv12;
    options.serverTrust = CocoaCurlSocketStream::ServerTrust::Client;
    // No system proxy: the route is a direct connection, which a test's filter results act on.
    options.configuredProxySettings = (__bridge CFDictionaryRef)@{ @"HTTPEnable": @0, @"HTTPSEnable": @0, @"SOCKSEnable": @0 };
    options.proxyFilterResults = test.proxyFilterResults;
    options.connectTimeout = test.connectTimeout;

    RefPtr<CocoaCurlSocketStream> stream;
    CocoaCurlSocketStream::Client client;
    client.didOpen = [&](std::optional<CocoaCurlSocketStream::ForwardingProxy>&&) {
        result.opened = true;
        static constexpr auto request = "GET /websocket HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"_span;
        stream->send(byteCast<uint8_t>(request));
    };
    client.didReceiveData = [&](std::span<const uint8_t> data) {
        result.received = makeString(result.received, String { byteCast<Latin1Character>(data) });
        if (result.received.contains("mTLS"_s)) {
            done = true;
            CFRunLoopStop(CFRunLoopGetMain());
        }
    };
    client.didClose = [&] {
        done = true;
        CFRunLoopStop(CFRunLoopGetMain());
    };
    client.didFail = [&](int, const String& description) {
        result.failed = true;
        result.failure = description;
        done = true;
        CFRunLoopStop(CFRunLoopGetMain());
    };
    client.decideServerTrust = [&](RetainPtr<SecTrustRef>&&, CompletionHandler<void(bool)>&& completion) {
        ++result.trustQuestions;
        after(test.trustDelay, [completion = WTF::move(completion), accept = test.acceptTrust]() mutable { completion(accept); });
    };
    client.requestIdentity = [&](RetainPtr<CFArrayRef>&&, CompletionHandler<void(RetainPtr<SecIdentityRef>&&, RetainPtr<CFArrayRef>&&)>&& completion) {
        ++result.identityQuestions;
        after(test.identityDelay, [completion = WTF::move(completion), identity = retainPtr(test.identity)]() mutable { completion(WTF::move(identity), nullptr); });
    };
    stream = CocoaCurlSocketStream::create(WTF::move(options), WTF::move(client));
    stream->start();
    auto deadline = MonotonicTime::now() + 30_s;
    while (!done && MonotonicTime::now() < deadline)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.5, false);
    result.elapsed = MonotonicTime::now() - start;
    stream->close();
    return result;
}

static void check(bool passed, const char* name, const Result& result)
{
    printf("%s: opened=%d trust=%u identity=%u received=%d failure=[%s] elapsed=%.1fs %s\n", name, result.opened, result.trustQuestions,
        result.identityQuestions, result.received.contains("mTLS"_s), result.failure.utf8().data(), result.elapsed.seconds(), passed ? "PASS" : "FAIL");
    failures += !passed;
}

// A proxy that takes the connection and never answers it.
static int silentProxy(uint16_t& port)
{
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in address { };
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    socklen_t length = sizeof(address);
    if (bind(listener, reinterpret_cast<sockaddr*>(&address), sizeof(address)) || listen(listener, 8)
        || getsockname(listener, reinterpret_cast<sockaddr*>(&address), &length))
        return -1;
    port = ntohs(address.sin_port);
    return listener;
}

int main()
{
    @autoreleasepool {
        setvbuf(stdout, nullptr, _IONBF, 0);
        WTF::initializeMainThread();

        Result trusted = run({ "server certificate accepted after the connect limit", 19446, 2_s, 4_s });
        check(trusted.opened && trusted.received.contains("mTLS"_s) && trusted.trustQuestions == 1 && trusted.elapsed > 4_s,
            "server certificate accepted 4 s into a 2 s connect limit: opens", trusted);

        Result rejected = run({ "server certificate rejected", 19446, 2_s, 0_s, false });
        check(!rejected.opened && rejected.failed && rejected.failure.contains("certificate"_s) && rejected.trustQuestions == 1,
            "server certificate rejected: fails", rejected);

        char directory[] = "/private/tmp/curl-websocket-keychain-XXXXXX";
        RELEASE_ASSERT(mkdtemp(directory));
        NSString *path = [[NSString stringWithUTF8String:directory] stringByAppendingPathComponent:@"fixture.keychain"];
        SecKeychainRef rawKeychain = nullptr;
        if (SecKeychainCreate(path.fileSystemRepresentation, 7, "fixture", false, nullptr, &rawKeychain)) {
            printf("SecKeychainCreate failed\n");
            return 1;
        }
        auto keychain = adoptCF(rawKeychain);
        NSData *pkcs12 = [NSData dataWithContentsOfFile:@"/private/tmp/curl-identity-test/identity.p12"];
        CFArrayRef rawItems = nullptr;
        OSStatus status = SecPKCS12Import((__bridge CFDataRef)pkcs12, (__bridge CFDictionaryRef)@{ (id)kSecImportExportPassphrase: @"fixture", (id)kSecImportExportKeychain: (__bridge id)keychain.get() }, &rawItems);
        if (status) {
            printf("SecPKCS12Import failed: %d\n", status);
            SecKeychainDelete(keychain.get());
            return 1;
        }
        auto items = adoptCF(rawItems);
        auto identity = (__bridge SecIdentityRef)[(__bridge NSArray *)items.get() objectAtIndex:0][(id)kSecImportItemIdentity];

        for (uint16_t port : { 19447, 19448 }) {
            Result supplied = run({ "client identity", port, 2_s, 0_s, true, 4_s, identity });
            check(supplied.opened && supplied.received.contains("mTLS"_s) && supplied.identityQuestions == 1 && supplied.elapsed > 4_s,
                port == 19447 ? "TLS 1.2 client identity answered 4 s into a 2 s connect limit: opens" : "TLS 1.3 client identity answered 4 s into a 2 s connect limit: opens", supplied);
            Result none = run({ "no client identity", port, 2_s, 0_s, true, 0_s, nullptr });
            // TLS 1.3 lets the server refuse the missing certificate after the client's Finished, which the client reads
            // as the end of the connection once the stream stands.
            check(none.identityQuestions == 1 && !none.received.contains("mTLS"_s),
                port == 19447 ? "TLS 1.2 without a client identity: refused" : "TLS 1.3 without a client identity: refused", none);
        }
        SecKeychainDelete(keychain.get());

        uint16_t proxyPort = 0;
        int listener = silentProxy(proxyPort);
        RELEASE_ASSERT(listener >= 0);
        CocoaCurlProxyServer silent;
        silent.type = CocoaCurlProxyServer::Type::HTTP;
        silent.host = "127.0.0.1"_s;
        silent.port = proxyPort;
        silent.failoverTimeout = 1_s;
        CocoaCurlProxyFilterResult route;
        route.entries.append(silent);
        route.entries.append(CocoaCurlProxyServer { });
        Result failover = run({ "failover", 19446, 2_s, 3_s, true, 0_s, nullptr, { route } });
        check(failover.opened && failover.received.contains("mTLS"_s) && failover.elapsed > 4_s && failover.elapsed < 10_s,
            "silent proxy with a 1 s failoverTimeout, then direct with a certificate answered 3 s into a 2 s limit: opens", failover);
        close(listener);

        printf("Cocoa curl WebSocket stream: FAILED=%u\n", failures);
        return failures ? 1 : 0;
    }
}
