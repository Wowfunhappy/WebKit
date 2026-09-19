// Shared Cocoa transport also runs on a dedicated event loop, without pumping UI events during a synchronous load.
#include "config.h"
#include <WebCore/CocoaCurlConnection.h>
#include "SynchronousLoaderClient.h"
#include <WebCore/ResourceError.h>
#include <WebCore/SharedBuffer.h>
#include <wtf/threads/BinarySemaphore.h>
#include <wtf/MainThread.h>
#include <wtf/RefCounted.h>
#include <wtf/text/MakeString.h>
#include <Foundation/Foundation.h>
#include <cstdio>

using namespace WebCore;
struct Result {
    BinarySemaphore done;
    int error { 0 };
    int status { 0 };
    unsigned responses { 0 };
    bool http09 { false };
    bool responseBeforeData { true };
    uint64_t bytes { 0 };
    bool verifyBody { false };
    bool bodyMatches { true };
    uint64_t decodedMetric { 0 };
    String protocol;
    String mimeType;
    String encoding;
    String contentType;
    bool completedMetrics { false };
    bool nativeTrust { false };
    bool evaluatedTrust { false };
    // The answer the client gives for the server chain; absent means the platform's own.
    std::optional<bool> clientTrust;
    String tlsProtocol;
    String tlsCipher;
    tls_protocol_version_t minimumTLS { tls_protocol_version_TLSv12 };
};
class Probe final : public RefCounted<Probe>, public CocoaCurlTransferClient {
public:
    static void start(Result& result, const String& url)
    {
        Ref probe = adoptRef(*new Probe(result));
        probe->m_keepAlive = probe.ptr();
        CocoaCurlTransferOptions options(result.minimumTLS);
        options.request = ResourceRequest(URL { url });
        options.request.setTimeoutInterval(10);
        Ref scheduler = CocoaCurlScheduler::create();
        probe->m_transfer = CocoaCurlTransfer::create(scheduler, probe, WTF::move(options));
        probe->m_transfer->start();
    }
    void ref() const final { RefCounted::ref(); }
    void deref() const final { RefCounted::deref(); }
private:
    explicit Probe(Result& result) : m_result(result) { }
    void curlReceivedCookies(Vector<String>&&, const String&, const String&, CompletionHandler<void(std::optional<String>&&)>&& completion) final { completion(std::nullopt); }
    void curlReceivedResponse(CocoaCurlTransferResponse&& response, CompletionHandler<void()>&& completion) final
    {
        ++m_result.responses;
        m_result.http09 = response.response.isHTTP09();
        m_result.status = response.response.httpStatusCode();
        m_result.mimeType = response.response.mimeType().isolatedCopy();
        m_result.encoding = response.response.textEncodingName().isolatedCopy();
        m_result.contentType = response.response.httpHeaderField(HTTPHeaderName::ContentType).isolatedCopy();
        completion();
    }
    void curlReceivedInformationalResponse(ResourceResponse&&) final { }
    void curlSentData(uint64_t, uint64_t) final { }
    void curlReceivedData(const SharedBuffer& bytes, CompletionHandler<void()>&& completion) final
    {
        m_result.responseBeforeData &= m_result.responses == 1;
        if (m_result.verifyBody) {
            size_t index = m_result.bytes;
            for (auto byte : bytes.span()) {
                uint32_t value = index++ % 16384;
                value = (value ^ (value >> 16)) * 0x7feb352d;
                value = (value ^ (value >> 15)) * 0x846ca68b;
                m_result.bodyMatches &= byte == static_cast<uint8_t>(value ^ (value >> 16));
            }
        }
        m_result.bytes += bytes.size();
        completion();
    }
    void curlRequestedIdentity(CFArrayRef, CompletionHandler<void(RetainPtr<SecIdentityRef>&&, RetainPtr<CFArrayRef>&&)>&& completion) final { completion(nullptr, nullptr); }
    // The platform's own evaluation of the server chain is the answer.
    void curlRequestedServerTrust(CompletionHandler<void(bool)>&& completion) final
    {
        auto tls = m_transfer->tlsState();
        completion(m_result.clientTrust.value_or(tls && tls->accepted));
    }
    void curlCompleted(const ResourceError& error, const NetworkLoadMetrics& metrics) final
    {
        m_result.error = error.errorCode();
        m_result.decodedMetric = metrics.responseBodyDecodedSize;
        m_result.protocol = metrics.protocol.isolatedCopy();
        m_result.completedMetrics = !!metrics.responseEnd;
        if (metrics.additionalNetworkLoadMetricsForWebInspector) {
            m_result.tlsProtocol = metrics.additionalNetworkLoadMetricsForWebInspector->tlsProtocol.isolatedCopy();
            m_result.tlsCipher = metrics.additionalNetworkLoadMetricsForWebInspector->tlsCipher.isolatedCopy();
        }
        if (auto state = m_transfer->tlsState()) {
            m_result.nativeTrust = state->trust && CFGetTypeID(state->trust.get()) == SecTrustGetTypeID();
            m_result.evaluatedTrust = state->evaluated;
        }
        m_transfer->invalidateClient();
        m_transfer = nullptr;
        m_keepAlive = nullptr;
        m_result.done.signal();
    }
    Result& m_result;
    RefPtr<Probe> m_keepAlive;
    RefPtr<CocoaCurlTransfer> m_transfer;
};
// Exercises the same blocking callback queue used by legacy synchronous resource loads.
class SynchronousProbe final : public RefCounted<SynchronousProbe>, public CocoaCurlTransferClient {
public:
    static bool run()
    {
        Ref probe = adoptRef(*new SynchronousProbe);
        Ref pool = CocoaCurlConnectionPool::create();
        CocoaCurlTransferOptions options(tls_protocol_version_TLSv12);
        options.request = ResourceRequest(URL { "http://127.0.0.1:18981/probe/baseline"_s });
        options.request.setTimeoutInterval(10);
        probe->m_connection = CocoaCurlConnection::create(pool, probe, WTF::move(options), probe->m_queue.ptr());
        probe->m_connection->start();
        while (!probe->m_queue->killed()) {
            if (auto callback = probe->m_queue->waitForMessage())
                (*callback)();
        }
        probe->m_connection->invalidateClient();
        probe->m_connection = nullptr;
        bool passed = probe->m_status == 200 && probe->m_bytes == 5 && !probe->m_error;
        printf("synchronous queue bridge: status=%d bytes=%llu error=%d %s\n", probe->m_status, static_cast<unsigned long long>(probe->m_bytes), probe->m_error, passed ? "PASS" : "FAIL");
        return passed;
    }
    void ref() const final { RefCounted::ref(); }
    void deref() const final { RefCounted::deref(); }
private:
    void curlReceivedCookies(Vector<String>&&, const String&, const String&, CompletionHandler<void(std::optional<String>&&)>&& completion) final { completion(std::nullopt); }
    void curlReceivedResponse(CocoaCurlTransferResponse&& response, CompletionHandler<void()>&& completion) final
    {
        ASSERT(isMainThread());
        m_status = response.response.httpStatusCode();
        completion();
    }
    void curlReceivedData(const SharedBuffer& data, CompletionHandler<void()>&& completion) final
    {
        ASSERT(isMainThread());
        m_bytes += data.size();
        completion();
    }
    void curlSentData(uint64_t, uint64_t) final { }
    void curlReceivedInformationalResponse(ResourceResponse&&) final { }
    void curlRequestedIdentity(CFArrayRef, CompletionHandler<void(RetainPtr<SecIdentityRef>&&, RetainPtr<CFArrayRef>&&)>&& completion) final { completion(nullptr, nullptr); }
    // The platform's own evaluation of the server chain is the answer.
    void curlRequestedServerTrust(CompletionHandler<void(bool)>&& completion) final
    {
        auto tls = m_connection->tlsState();
        completion(tls && tls->accepted);
    }
    void curlCompleted(const ResourceError& error, const NetworkLoadMetrics&) final
    {
        ASSERT(isMainThread());
        m_error = error.errorCode();
        m_queue->kill();
    }
    Ref<SynchronousLoaderMessageQueue> m_queue { SynchronousLoaderMessageQueue::create() };
    RefPtr<CocoaCurlConnection> m_connection;
    int m_status { 0 };
    int m_error { 0 };
    uint64_t m_bytes { 0 };
};
int main()
{
    WTF::initializeMainThread();
    Ref worker = RunLoop::create("Cocoa curl test"_s);
    unsigned failures = !SynchronousProbe::run();
    for (const auto& url : { "http://127.0.0.1:18981/probe/baseline"_s, "http://127.0.0.1:18981/probe/chunk_short_data"_s }) {
        Result result;
        worker->dispatch([&result, url = String(url).isolatedCopy()] { Probe::start(result, url); });
        result.done.wait();
        bool truncated = StringView(url).endsWith("chunk_short_data"_s);
        bool passed = result.status == 200 && result.bytes == (truncated ? 3 : 5) && result.error == (truncated ? -1005 : 0) && result.protocol == "http/1.1"_s && result.completedMetrics;
        printf("dedicated curl loop: %s status=%d bytes=%llu error=%d %s\n", url.characters(), result.status, static_cast<unsigned long long>(result.bytes), result.error, passed ? "PASS" : "FAIL");
        failures += !passed;
    }
    for (const auto& url : { "http://[invalid/"_s, "http://127.0.0.1:99999/"_s, "http://%zz/"_s }) {
        Result result;
        worker->dispatch([&result, url = String(url).isolatedCopy()] { Probe::start(result, url); });
        result.done.wait();
        bool passed = result.error == NSURLErrorBadURL && !result.status && !result.bytes;
        printf("malformed URL: %s error=%d %s\n", url.characters(), result.error, passed ? "PASS" : "FAIL");
        failures += !passed;
    }
    {
        Result result;
        worker->dispatch([&result] { Probe::start(result, "http://127.0.0.1:18981/probe/http09_body"_s); });
        result.done.wait();
        bool passed = !result.error && result.status == 200 && result.bytes == 6 && result.decodedMetric == 6
            && result.responses == 1 && result.responseBeforeData && result.http09 && result.protocol == "http/0.9"_s;
        printf("HTTP/0.9: status=%d bytes=%llu responses=%u version=%s error=%d %s\n", result.status,
            static_cast<unsigned long long>(result.bytes), result.responses, result.protocol.utf8().data(), result.error, passed ? "PASS" : "FAIL");
        failures += !passed;
    }
    struct MimeCase { ASCIILiteral path; ASCIILiteral header; };
    for (auto& fixture : { MimeCase { "_mime_separate"_s, "application/json, text/html; charset=utf-8"_s },
                           MimeCase { "_mime_reversed"_s, "text/html; charset=utf-8, application/json"_s },
                           MimeCase { "_mime_combined"_s, "application/json, text/html; charset=utf-8"_s } }) {
        @autoreleasepool {
            String url = makeString("http://127.0.0.1:18981/probe/"_s, fixture.path);
            Result result;
            worker->dispatch([&result, url = url.isolatedCopy()] { Probe::start(result, url); });
            result.done.wait();
            NSURLResponse *native = nil;
            NSError *error = nil;
            NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:url.createNSString().get()] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10];
            NSData *data = [NSURLConnection sendSynchronousRequest:request returningResponse:&native error:&error];
            String nativeType { native.MIMEType };
            String nativeEncoding { native.textEncodingName };
            bool passed = !result.error && !error && result.status == 200 && result.bytes == data.length
                && result.mimeType == nativeType && equalIgnoringNullity(result.encoding, nativeEncoding)
                && result.contentType == fixture.header;
            printf("MIME %s: curl=%s native=%s encoding=%s nativeEncoding=%s headers=%s %s\n", fixture.path.characters(),
                result.mimeType.utf8().data(), nativeType.utf8().data(), result.encoding.utf8().data(), nativeEncoding.utf8().data(), result.contentType.utf8().data(), passed ? "PASS" : "FAIL");
            failures += !passed;
        }
    }
    for (const auto& url : { "https://127.0.0.1:19445/"_s, "https://127.0.0.1:19446/"_s }) {
        Result result;
        worker->dispatch([&result, url = String(url).isolatedCopy()] { Probe::start(result, url); });
        result.done.wait();
        bool invalid = StringView(url).contains(":19446"_s);
        bool passed = result.nativeTrust && result.evaluatedTrust && result.completedMetrics
            && (invalid ? result.error == -1202 && !result.status : !result.error && result.status == 200 && result.bytes && !result.tlsProtocol.isEmpty() && !result.tlsCipher.isEmpty());
        printf("dedicated curl TLS: %s status=%d bytes=%llu error=%d trust=%d evaluated=%d protocol=%s tls=%s cipher=%s %s\n", url.characters(), result.status, static_cast<unsigned long long>(result.bytes), result.error, result.nativeTrust, result.evaluatedTrust, result.protocol.utf8().data(), result.tlsProtocol.utf8().data(), result.tlsCipher.utf8().data(), passed ? "PASS" : "FAIL");
        failures += !passed;
    }
    // The client's answer is what the handshake follows, in both directions: a chain the platform
    // rejected loads when the client accepts it, which is how a user's decision on a certificate
    // challenge reaches the transfer, and a chain the platform accepted does not load when the
    // client refuses it.
    for (auto clientTrust : { true, false }) {
        Result result;
        result.clientTrust = clientTrust;
        String url = clientTrust ? "https://127.0.0.1:19446/"_s : "https://127.0.0.1:19445/"_s;
        worker->dispatch([&result, url = url.isolatedCopy()] { Probe::start(result, url); });
        result.done.wait();
        bool passed = result.nativeTrust && result.evaluatedTrust && result.completedMetrics
            && (clientTrust ? !result.error && result.status == 200 && result.bytes : result.error == -1202 && !result.status);
        printf("client verdict overrides the platform: accept=%d %s status=%d bytes=%llu error=%d trust=%d evaluated=%d %s\n", clientTrust, url.utf8().data(), result.status, static_cast<unsigned long long>(result.bytes), result.error, result.nativeTrust, result.evaluatedTrust, passed ? "PASS" : "FAIL");
        failures += !passed;
    }
    // The configured floor is the handshake's: a TLS 1.1-only server is refused under the TLS 1.2 floor
    // and loads under the TLS 1.0 floor a session that allows legacy TLS carries.
    for (auto minimum : { tls_protocol_version_TLSv12, tls_protocol_version_TLSv10 }) {
        Result result;
        result.minimumTLS = minimum;
        worker->dispatch([&result] { Probe::start(result, "https://127.0.0.1:19451/"_s); });
        result.done.wait();
        bool legacyAllowed = minimum == tls_protocol_version_TLSv10;
        bool passed = legacyAllowed ? !result.error && result.status == 200 && result.tlsProtocol == "TLSv1.1"_s
            : result.error == NSURLErrorSecureConnectionFailed && !result.status;
        printf("TLS floor %s against TLS 1.1: status=%d error=%d tls=%s %s\n", legacyAllowed ? "1.0" : "1.2", result.status, result.error, result.tlsProtocol.utf8().data(), passed ? "PASS" : "FAIL");
        failures += !passed;
    }
    // What the connection close means for each message framing, against a server that closes with no
    // TLS close_notify. Only a response whose framing has no other end takes the close as one.
    struct Framing { ASCIILiteral path; int status; uint64_t bytes; int error; };
    for (auto& framing : { Framing { "close-delimited"_s, 200, 5, 0 },
                           Framing { "close-delimited-error"_s, 404, 4, 0 },
                           Framing { "short-length"_s, 200, 5, -1005 },
                           Framing { "chunked-truncated"_s, 200, 3, -1005 } }) {
        Result result;
        String url = makeString("https://127.0.0.1:19449/"_s, framing.path);
        worker->dispatch([&result, url = url.isolatedCopy()] { Probe::start(result, url); });
        result.done.wait();
        bool passed = result.status == framing.status && result.bytes == framing.bytes && result.error == framing.error;
        printf("framing %s: status=%d bytes=%llu error=%d %s\n", framing.path.characters(), result.status,
            static_cast<unsigned long long>(result.bytes), result.error, passed ? "PASS" : "FAIL");
        failures += !passed;
    }
    {
        // HTTP/2 ends a body with END_STREAM, so the same close is a truncation however complete the
        // response looks: the fixture's PING barrier means the head and the body have both reached the
        // client before the connection dies, and the load still fails.
        Result result;
        worker->dispatch([&result] { Probe::start(result, "https://127.0.0.1:19450/close-delimited"_s); });
        result.done.wait();
        bool passed = result.status == 200 && result.bytes == 5 && result.error == -1005 && result.protocol == "h2"_s;
        printf("framing h2 close: status=%d bytes=%llu error=%d protocol=%s %s\n", result.status,
            static_cast<unsigned long long>(result.bytes), result.error, result.protocol.utf8().data(), passed ? "PASS" : "FAIL");
        failures += !passed;
    }
    for (auto encoding : { @"identity", @"gzip", @"deflate", @"br" }) {
        Result result;
        result.verifyBody = true;
        String url([@"http://127.0.0.1:18987/" stringByAppendingString:encoding]);
        worker->dispatch([&result, url = url.isolatedCopy()] { Probe::start(result, url); });
        result.done.wait();
        bool passed = result.status == 200 && !result.error && result.bodyMatches
            && result.bytes == 1048576 && result.decodedMetric == result.bytes;
        printf("decoded %s: status=%d bytes=%llu metric=%llu exact=%d error=%d %s\n", [encoding UTF8String], result.status,
            static_cast<unsigned long long>(result.bytes), static_cast<unsigned long long>(result.decodedMetric), result.bodyMatches, result.error, passed ? "PASS" : "FAIL");
        failures += !passed;
    }
    worker->dispatch([worker] { worker->stop(); });
    printf("FAILED=%u\n", failures);
    return failures ? 1 : 0;
}
