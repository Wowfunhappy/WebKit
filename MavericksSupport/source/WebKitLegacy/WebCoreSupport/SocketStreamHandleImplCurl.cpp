/*
 * Copyright (C) 2026. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#include "SocketStreamHandleImpl.h"

// A WebSocket handshake is a TLS connection like any other, so it presents what the rest of this
// port's network layer presents: libcurl in CONNECT_ONLY mode with the ClientHello
// CocoaCurlClientHello.h defines, and the system's own trust evaluation over BoringSSL.
#include "SocketStreamHandleClient.h"
#include <WebCore/CocoaCurlProxyResolver.h>
#include <WebCore/CocoaCurlSocketGate.h>
#include <WebCore/CocoaCurlTLS.h>
#include <WebCore/DeprecatedGlobalSettings.h>
#include <WebCore/Logging.h>
#include <WebCore/SocketStreamError.h>
#include <WebCore/StorageSessionProvider.h>
#include <curl/curl.h>
#include <dispatch/dispatch.h>
#include <pal/spi/cf/CFNetworkSPI.h>
#include <sys/socket.h>
#include <unistd.h>
#include <wtf/Lock.h>
#include <wtf/MainThread.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/text/MakeString.h>

namespace WebCore {

// The connection is made on its own queue, because resolution, the proxy route and the handshake are
// blocking work. Once it stands it belongs to the main thread, where the socket's readability and
// writability drive curl_easy_recv and curl_easy_send on the run loop the client already runs on.
class SocketStreamCurlTransport : public ThreadSafeRefCounted<SocketStreamCurlTransport, WTF::DestructionThread::Main> {
public:
    struct Client {
        Function<void()> didOpen;
        Function<void(std::span<const uint8_t>)> didReceiveData;
        Function<void()> didClose;
        Function<void()> canSendMore;
        Function<void(int, String)> didFail;
    };

    static Ref<SocketStreamCurlTransport> create(const URL& url, unsigned short port, bool secure, bool acceptInsecureCertificates, Client&& client)
    {
        return adoptRef(*new SocketStreamCurlTransport(url, port, secure, acceptInsecureCertificates, WTF::move(client)));
    }

    ~SocketStreamCurlTransport();

    void start();
    void close();
    std::optional<size_t> send(std::span<const uint8_t>);

    std::shared_ptr<CocoaCurlTLSState> tlsState() const { return m_tls; }

private:
    SocketStreamCurlTransport(const URL&, unsigned short, bool secure, bool acceptInsecureCertificates, Client&&);

    void routeResolved(CFDictionaryRef, const String& error);
    void connectOnQueue();
    void connectFinished(CURLcode, curl_socket_t);
    void readAvailable();
    void resumeWriteSource();
    void suspendWriteSource();
    void fail(int code, const String& description);

    URL m_url;
    unsigned short m_port;
    bool m_secure;
    bool m_acceptInsecureCertificates;
    Client m_client; // Main thread only.

    CURL* m_curl { nullptr };
    std::shared_ptr<CocoaCurlTLSState> m_tls;
    RefPtr<CocoaCurlProxyResolver> m_resolver;
    dispatch_queue_t m_connectQueue { nullptr };
    bool m_connecting { false }; // Main thread only; true while the connect queue owns m_curl.

    curl_socket_t m_socket { CURL_SOCKET_BAD };
    dispatch_source_t m_readSource { nullptr };
    dispatch_source_t m_writeSource { nullptr };
    bool m_writeSourceActive { false };

    // Held jointly with the curl handle, because curl closes its socket when the handle is cleaned
    // up -- which happens after this object is gone.
    CocoaCurlSocketGate* m_gate { nullptr };
};

static CURLcode socketStreamInstallTLS(CURL*, void* context, void* transport)
{
    return CocoaCurlTLSState::installSynchronously(static_cast<SSL_CTX*>(context), static_cast<SocketStreamCurlTransport*>(transport)->tlsState());
}

SocketStreamCurlTransport::SocketStreamCurlTransport(const URL& url, unsigned short port, bool secure, bool acceptInsecureCertificates, Client&& client)
    : m_url(url)
    , m_port(port)
    , m_secure(secure)
    , m_acceptInsecureCertificates(acceptInsecureCertificates)
    , m_client(WTF::move(client))
{
    m_gate = cocoaCurlSocketGateCreate();
}

SocketStreamCurlTransport::~SocketStreamCurlTransport()
{
    ASSERT(!m_curl);
    if (m_connectQueue)
        dispatch_release(m_connectQueue);
    if (m_gate)
        cocoaCurlSocketGateRelease(m_gate);
}

void SocketStreamCurlTransport::start()
{
    ASSERT(isMainThread());
    m_curl = m_gate ? curl_easy_init() : nullptr;
    if (!m_curl) {
        fail(0, "Could not create the WebSocket connection"_s);
        return;
    }
    // Released where the handle is cleaned up, which is when curl closes its socket.
    cocoaCurlSocketGateRetain(m_gate);
    // curl connects to the origin and hands the connection over: it sends no request of its own, and
    // the RFC 6455 handshake is written onto the socket it returns. An RFC 6455 upgrade is HTTP/1.1,
    // so http/1.1 is the only protocol ALPN offers.
    auto endpoint = makeString(m_secure ? "https://"_s : "http://"_s,
        m_url.host().contains(':') ? "["_s : ""_s, m_url.host(), m_url.host().contains(':') ? "]"_s : ""_s,
        ":"_s, m_port, "/"_s);
    curl_easy_setopt(m_curl, CURLOPT_URL, endpoint.utf8().data());
    curl_easy_setopt(m_curl, CURLOPT_CONNECT_ONLY, 1L);
    curl_easy_setopt(m_curl, CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_1_1);
    curl_easy_setopt(m_curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(m_curl, CURLOPT_CONNECTTIMEOUT, 30L);
    curl_easy_setopt(m_curl, CURLOPT_OPENSOCKETFUNCTION, cocoaCurlSocketGateOpen);
    curl_easy_setopt(m_curl, CURLOPT_OPENSOCKETDATA, m_gate);
    curl_easy_setopt(m_curl, CURLOPT_CLOSESOCKETFUNCTION, cocoaCurlSocketGateClose);
    curl_easy_setopt(m_curl, CURLOPT_CLOSESOCKETDATA, m_gate);
    // A CONNECT tunnel carries a WebSocket through an HTTP proxy (RFC 6455 4.1), for ws:// as well.
    curl_easy_setopt(m_curl, CURLOPT_HTTPPROXYTUNNEL, 1L);
    if (m_secure) {
        m_tls = std::make_shared<CocoaCurlTLSState>();
        // The state is read on the connect queue, so its string may not share a StringImpl with the
        // main thread's.
        m_tls->url = m_url.isolatedCopy();
        m_tls->acceptAnyCertificate = m_acceptInsecureCertificates;
        // The certificate is answered for by the system trust store inside the handshake; curl's own
        // hostname check is not used because SecPolicyCreateSSL carries the name.
        curl_easy_setopt(m_curl, CURLOPT_SSL_VERIFYPEER, 1L);
        curl_easy_setopt(m_curl, CURLOPT_SSL_VERIFYHOST, 0L);
        curl_easy_setopt(m_curl, CURLOPT_CAINFO, static_cast<const char*>(nullptr));
        curl_easy_setopt(m_curl, CURLOPT_CAPATH, static_cast<const char*>(nullptr));
        curl_easy_setopt(m_curl, CURLOPT_SSLVERSION, CURL_SSLVERSION_TLSv1_2);
        curl_easy_setopt(m_curl, CURLOPT_SSL_CTX_FUNCTION, socketStreamInstallTLS);
        curl_easy_setopt(m_curl, CURLOPT_SSL_CTX_DATA, this);
    }

    // CFNetwork resolves proxies against http(s), never against a WebSocket scheme, and its answer is
    // the one that carries the exception list, the bypass rules and any PAC script.
    auto settings = adoptCF(CFNetworkCopySystemProxySettings());
    URL httpsURL { makeString(m_secure ? "https://"_s : "http://"_s, m_url.host(), ":"_s, m_port, "/"_s) };
    m_resolver = CocoaCurlProxyResolver::create(httpsURL, settings.get(), [protectedThis = Ref { *this }](RetainPtr<CFDictionaryRef>&& proxy, const String& error) {
        protectedThis->routeResolved(proxy.get(), error);
    });
    m_resolver->start();
}

void SocketStreamCurlTransport::routeResolved(CFDictionaryRef proxy, const String& error)
{
    ASSERT(isMainThread());
    m_resolver = nullptr;
    if (cocoaCurlSocketGateCancelled(m_gate))
        return;
    String proxyHost;
    int proxyPort = 0;
    if (!error.isEmpty() || !proxy || !CocoaCurlProxyResolver::apply(m_curl, proxy, proxyHost, proxyPort)
        || !CocoaCurlProxyResolver::applyCredentials(m_curl, proxy, CURLAUTH_NONE, emptyString(), emptyString())) {
        fail(0, error.isEmpty() ? "Could not resolve the proxy route for this WebSocket"_s : error);
        return;
    }

    m_connectQueue = dispatch_queue_create("com.apple.WebKit.SocketStreamConnect", DISPATCH_QUEUE_SERIAL);
    m_connecting = true;
    ref(); // Balanced in connectFinished, which the connect queue posts back to the main thread.
    dispatch_async(m_connectQueue, ^{
        connectOnQueue();
    });
}

void SocketStreamCurlTransport::connectOnQueue()
{
    auto code = curl_easy_perform(m_curl);
    curl_socket_t connected = CURL_SOCKET_BAD;
    if (code == CURLE_OK && (curl_easy_getinfo(m_curl, CURLINFO_ACTIVESOCKET, &connected) != CURLE_OK || connected == CURL_SOCKET_BAD))
        code = CURLE_COULDNT_CONNECT;
    callOnMainThread([this, code, connected] {
        connectFinished(code, connected);
        deref();
    });
}

void SocketStreamCurlTransport::connectFinished(CURLcode code, curl_socket_t connected)
{
    ASSERT(isMainThread());
    m_connecting = false;
    if (cocoaCurlSocketGateCancelled(m_gate)) {
        // close() left the handle to this: the connect queue owned it while it ran.
        if (auto* handle = std::exchange(m_curl, nullptr)) {
            curl_easy_cleanup(handle);
            cocoaCurlSocketGateRelease(m_gate);
        }
        return;
    }
    if (code != CURLE_OK) {
        fail(code, String::fromUTF8(curl_easy_strerror(code)));
        return;
    }
    m_socket = connected;
    // From here the teardown reaches the connection through the main thread, not the descriptor.
    cocoaCurlSocketGateForget(m_gate);
    m_readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, m_socket, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(m_readSource, ^{ readAvailable(); });
    // Resumed only while curl has taken less than what the client offered it.
    m_writeSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, m_socket, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(m_writeSource, ^{
        // Suspended first: what the client writes next decides whether it is armed again.
        suspendWriteSource();
        if (m_client.canSendMore)
            m_client.canSendMore();
    });
    dispatch_resume(m_readSource);
    if (m_client.didOpen)
        m_client.didOpen();
}

void SocketStreamCurlTransport::readAvailable()
{
    ASSERT(isMainThread());
    if (!m_curl)
        return;
    Ref protectedThis { *this };
    uint8_t buffer[16 * 1024];
    for (;;) {
        size_t received = 0;
        auto code = curl_easy_recv(m_curl, buffer, sizeof(buffer), &received);
        if (code == CURLE_AGAIN)
            return;
        if (code != CURLE_OK) {
            fail(code, String::fromUTF8(curl_easy_strerror(code)));
            return;
        }
        if (!received) {
            if (m_client.didClose)
                m_client.didClose();
            return;
        }
        if (m_client.didReceiveData)
            m_client.didReceiveData(std::span { buffer, received });
        if (!m_curl)
            return;
    }
}

std::optional<size_t> SocketStreamCurlTransport::send(std::span<const uint8_t> data)
{
    ASSERT(isMainThread());
    if (!m_curl || m_socket == CURL_SOCKET_BAD)
        return 0;
    size_t sent = 0;
    auto code = curl_easy_send(m_curl, data.data(), data.size(), &sent);
    if (code == CURLE_AGAIN) {
        resumeWriteSource();
        return 0;
    }
    if (code != CURLE_OK)
        return std::nullopt;
    if (sent < data.size())
        resumeWriteSource();
    return sent;
}

void SocketStreamCurlTransport::resumeWriteSource()
{
    if (m_writeSource && !m_writeSourceActive) {
        m_writeSourceActive = true;
        dispatch_resume(m_writeSource);
    }
}

void SocketStreamCurlTransport::suspendWriteSource()
{
    if (m_writeSource && m_writeSourceActive) {
        m_writeSourceActive = false;
        dispatch_suspend(m_writeSource);
    }
}

// CocoaCurlProxyResolver answers synchronously when there is no PAC script, so a failure can reach
// here from inside SocketStreamHandleImpl's constructor -- before WebSocketChannel has been given the
// handle. Failing it there runs disconnect() and platformClose() against a channel whose m_handle is
// still null, and the constructor then assigns the handle to a channel already failed and closed.
// Upstream defers its own constructor's failure through the run loop for the same reason.
void SocketStreamCurlTransport::fail(int code, const String& description)
{
    ASSERT(isMainThread());
    // Only the failure is deferred: nothing else reaches a client whose connection has failed.
    m_client.didOpen = { };
    m_client.didReceiveData = { };
    m_client.didClose = { };
    m_client.canSendMore = { };
    if (!m_client.didFail)
        return;
    // The handle behind didFail may be gone by then, and close() clears the client when it goes.
    callOnMainThread([protectedThis = Ref { *this }, code, description] {
        auto client = std::exchange(protectedThis->m_client, Client { });
        if (client.didFail)
            client.didFail(code, description);
    });
}

void SocketStreamCurlTransport::close()
{
    ASSERT(isMainThread());
    cocoaCurlSocketGateCancel(m_gate);
    m_client = Client { };
    if (m_resolver) {
        m_resolver->cancel();
        m_resolver = nullptr;
    }
    if (m_connecting)
        return; // connectFinished cleans up the handle the connect queue is using.

    auto* handle = std::exchange(m_curl, nullptr);
    auto read = std::exchange(m_readSource, nullptr);
    auto write = std::exchange(m_writeSource, nullptr);
    bool writeActive = std::exchange(m_writeSourceActive, false);
    m_socket = CURL_SOCKET_BAD;
    if (!read && !write) {
        if (handle) {
            curl_easy_cleanup(handle);
            cocoaCurlSocketGateRelease(m_gate);
        }
        return;
    }
    // The handle owns the descriptor the sources are armed on, so it closes only once both have
    // finished cancelling.
    __block int remaining = (read ? 1 : 0) + (write ? 1 : 0);
    auto* gate = m_gate;
    dispatch_block_t closeHandle = ^{
        if (!--remaining && handle) {
            curl_easy_cleanup(handle);
            cocoaCurlSocketGateRelease(gate);
        }
    };
    if (read) {
        dispatch_source_set_cancel_handler(read, closeHandle);
        dispatch_source_cancel(read);
        dispatch_release(read);
    }
    if (write) {
        // A suspended source cannot be cancelled: resume it first.
        if (!writeActive)
            dispatch_resume(write);
        dispatch_source_set_cancel_handler(write, closeHandle);
        dispatch_source_cancel(write);
        dispatch_release(write);
    }
}

// ----- SocketStreamHandleImpl -----

SocketStreamHandleImpl::SocketStreamHandleImpl(const URL& url, SocketStreamHandleClient& client, PAL::SessionID sessionID, const String& credentialPartition, SourceApplicationAuditToken&& auditData, const StorageSessionProvider* provider, bool acceptInsecureCertificates)
    : SocketStreamHandle(url, client)
    , m_shouldAcceptInsecureCertificates(acceptInsecureCertificates)
    , m_credentialPartition(credentialPartition)
    , m_auditData(WTF::move(auditData))
    , m_storageSessionProvider(provider)
{
    LOG(Network, "SocketStreamHandle %p new client %p", this, &m_client);

    ASSERT(url.protocolIs("ws"_s) || url.protocolIs("wss"_s));

    URL httpsURL { makeString("https://"_s, m_url.host()) };
    m_httpsURL = httpsURL.createCFURL();

    // Don't check for HSTS violation for ephemeral sessions since
    // HSTS state should not transfer between regular and private browsing.
    if (url.protocolIs("ws"_s)
        && !sessionID.isEphemeral()
        && _CFNetworkIsKnownHSTSHostWithSession(m_httpsURL.get(), nullptr)) {
        // Call this asynchronously because the socket stream is not fully constructed at this point.
        callOnMainThread([this, protectedThis = Ref { *this }] {
            m_client.didFailSocketStream(*this, SocketStreamError(0, m_url.string(), "WebSocket connection failed because it violates HTTP Strict Transport Security."_s));
        });
        return;
    }

    connect();
}

SocketStreamHandleImpl::~SocketStreamHandleImpl()
{
    LOG(Network, "SocketStreamHandle %p dtor", this);

    if (m_transport)
        m_transport->close();
}

void SocketStreamHandleImpl::setLegacyTLSEnabled(bool)
{
    // The ClientHello this port sends is the browser's, and it offers no protocol older than TLS 1.2.
}

void SocketStreamHandleImpl::connect()
{
    SocketStreamCurlTransport::Client transportClient;
    transportClient.didOpen = [this] { transportDidOpen(); };
    transportClient.didReceiveData = [this](std::span<const uint8_t> data) { transportDidReceiveData(data); };
    transportClient.didClose = [this] { transportDidClose(); };
    transportClient.canSendMore = [this] { sendPendingData(); };
    transportClient.didFail = [this](int code, String description) { transportDidFail(code, description); };

    m_transport = SocketStreamCurlTransport::create(m_url, port(), shouldUseSSL(), DeprecatedGlobalSettings::allowsAnySSLCertificate() || m_shouldAcceptInsecureCertificates, WTF::move(transportClient));
    m_transport->start();
}

void SocketStreamHandleImpl::transportDidOpen()
{
    RELEASE_LOG(Network, "SocketStreamHandleImpl::transportDidOpen");
    m_state = Open;
    m_client.didOpenSocketStream(*this);
}

void SocketStreamHandleImpl::transportDidReceiveData(std::span<const uint8_t> data)
{
    if (m_state != Open)
        return;
    Ref protectedThis { *this };
    m_client.didReceiveSocketStreamData(*this, data);
}

void SocketStreamHandleImpl::transportDidClose()
{
    platformClose();
}

void SocketStreamHandleImpl::transportDidFail(int code, const String& description)
{
    Ref protectedThis { *this };
    m_client.didFailSocketStream(*this, SocketStreamError(code, m_url.string(), description));
}

std::optional<size_t> SocketStreamHandleImpl::platformSendInternal(std::span<const uint8_t> data)
{
    if (!m_transport)
        return 0;
    return m_transport->send(data);
}

void SocketStreamHandleImpl::platformClose()
{
    LOG(Network, "SocketStreamHandle %p platformClose", this);

    if (auto transport = std::exchange(m_transport, nullptr))
        transport->close();
    m_client.didCloseSocketStream(*this);
}

unsigned short SocketStreamHandleImpl::port() const
{
    if (auto urlPort = m_url.port())
        return urlPort.value();
    if (shouldUseSSL())
        return 443;
    return 80;
}

} // namespace WebCore
