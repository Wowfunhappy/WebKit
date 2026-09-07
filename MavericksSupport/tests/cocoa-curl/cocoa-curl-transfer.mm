// Shared Cocoa transport also runs on a dedicated event loop, without pumping UI events during a synchronous load.
#include "config.h"
#include <WebCore/CocoaCurlConnection.h>
#include "SynchronousLoaderClient.h"
#include <WebCore/ResourceError.h>
#include <WebCore/SharedBuffer.h>
#include <wtf/threads/BinarySemaphore.h>
#include <wtf/MainThread.h>
#include <wtf/RefCounted.h>
#include <Foundation/Foundation.h>
#include <cstdio>

using namespace WebCore;
struct Result {
    BinarySemaphore done;
    int error { 0 };
    int status { 0 };
    uint64_t bytes { 0 };
    bool verifyBody { false };
    bool bodyMatches { true };
    uint64_t decodedMetric { 0 };
    String protocol;
    bool completedMetrics { false };
    bool nativeTrust { false };
    bool evaluatedTrust { false };
    String tlsProtocol;
    String tlsCipher;
};
class Probe final : public RefCounted<Probe>, public CocoaCurlTransferClient {
public:
    static void start(Result& result, const String& url)
    {
        Ref probe = adoptRef(*new Probe(result));
        probe->m_keepAlive = probe.ptr();
        CocoaCurlTransferOptions options;
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
    void curlReceivedCookies(Vector<String>&&, CompletionHandler<void(std::optional<String>&&)>&& completion) final { completion(std::nullopt); }
    void curlReceivedResponse(CocoaCurlTransferResponse&& response, CompletionHandler<void()>&& completion) final
    {
        m_result.status = response.response.httpStatusCode();
        completion();
    }
    void curlReceivedInformationalResponse(ResourceResponse&&) final { }
    void curlSentData(uint64_t, uint64_t) final { }
    void curlReceivedData(const SharedBuffer& bytes, CompletionHandler<void()>&& completion) final
    {
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
        CocoaCurlTransferOptions options;
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
    void curlReceivedCookies(Vector<String>&&, CompletionHandler<void(std::optional<String>&&)>&& completion) final { completion(std::nullopt); }
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
