/*
 * Copyright (C) 2026 Wowfunhappy. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#pragma once

// The connection a WebSocket travels on: libcurl in CONNECT_ONLY mode, through the route the process's proxy
// settings and the system give the URL (CocoaCurlRouteResolver, its servers tried in turn), with the ClientHello
// CocoaCurlClientHello.h defines for wss. WebKit 1's socket streams and the network process's WebSocket tasks both
// stand on it.
//
// The connection is made on its own queue, because resolution, the proxy route and the handshake are blocking work.
// Once it stands it belongs to the main thread, where the socket's readability and writability drive curl_easy_recv
// and curl_easy_send, and where the client is called.

#include "CocoaCurlProxyConfiguration.h"
#include <Security/Security.h>
#include <curl/curl.h>
#include <dispatch/dispatch.h>
#include <memory>
#include <wtf/CompletionHandler.h>
#include <wtf/Function.h>
#include <wtf/RetainPtr.h>
#include <wtf/Seconds.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/URL.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

struct CocoaCurlSocketGate;
struct ssl_st;
enum ssl_verify_result_t : int;

namespace WebCore {

struct CocoaCurlTLSState;
class LegacyWebSocketHandshake;
class ResourceResponse;

class WEBCORE_EXPORT CocoaCurlSocketStream final : public ThreadSafeRefCounted<CocoaCurlSocketStream, WTF::DestructionThread::Main> {
public:
    enum class ServerTrust : uint8_t {
        // The system's trust store decides inside the handshake, unless the stream accepts any certificate.
        Native,
        // The handshake takes any certificate, and the client decides about it before the stream opens.
        Client,
    };

    struct Options {
        // The origin, by an http:, https:, ws: or wss: URL; the route is resolved for its http: or https: form.
        URL url;
        uint16_t port { 0 };
        bool secure { false };
        // A plain connection through an HTTP proxy is a CONNECT tunnel; otherwise the stream connects to the proxy,
        // and the client writes its requests to it in absolute form.
        bool tunnelsPlainConnections { true };
        // The floor CocoaCurlTransferOptions documents.
        tls_protocol_version_t minimumTLSProtocol { tls_protocol_version_TLSv12 };
        ServerTrust serverTrust { ServerTrust::Native };
        bool acceptsAnyCertificate { false };
        // CocoaCurlTLSState::presentsPreferredIdentity.
        bool presentsPreferredIdentity { false };
        RetainPtr<CFDictionaryRef> configuredProxySettings;
        Vector<CocoaCurlProxyFilterResult> proxyFilterResults;
        // How long a connection may take, less the time the client takes to answer the questions put to it while
        // it is made; infinity sets no limit.
        Seconds connectTimeout { 30_s };
    };

    // An HTTP proxy that forwards the client's requests, which the client addresses in absolute form, and the
    // Proxy-Authorization field it is to send that proxy.
    struct ForwardingProxy {
        String authorization;
    };

    struct Client {
        Function<void(std::optional<ForwardingProxy>&&)> didOpen;
        Function<void(std::span<const uint8_t>)> didReceiveData;
        Function<void()> didClose;
        Function<void()> canSendMore;
        Function<void(int code, const String& description)> didFail;
        // ServerTrust::Client, for a secure stream: the certificate chain the server presented, as a trust object
        // for the URL's host. The handshake waits for the handler, and fails when it is called with false.
        Function<void(RetainPtr<SecTrustRef>&&, CompletionHandler<void(bool)>&&)> decideServerTrust;
        // ServerTrust::Client, for a server that asks for a certificate: the certificate authorities it names. The
        // handler takes the identity and the certificate chain to present, or none; the handshake waits for it.
        Function<void(RetainPtr<CFArrayRef>&& authorities, CompletionHandler<void(RetainPtr<SecIdentityRef>&&, RetainPtr<CFArrayRef>&&)>&&)> requestIdentity;
    };

    static Ref<CocoaCurlSocketStream> create(Options&&, Client&&);
    ~CocoaCurlSocketStream();

    void setWebSocketHandshake(RefPtr<LegacyWebSocketHandshake>&&);
    void didValidateWebSocketHandshake(const ResourceResponse&, bool connected);
    void start();
    void close();
    // The bytes curl took, which may be fewer than offered (canSendMore follows once the socket drains), or null
    // when the connection failed.
    std::optional<size_t> send(std::span<const uint8_t>);

    // The address the connection reached: the proxy's, through one.
    const String& remoteAddress() const { return m_remoteAddress; }

private:
    CocoaCurlSocketStream(Options&&, Client&&);

    static CURLcode installTLS(CURL*, void* context, void* stream);
    struct ClientAnswer;
    bool waitForAnswer(Function<void(CocoaCurlSocketStream&, std::shared_ptr<ClientAnswer>&&)>&& ask);
    void answer(bool accepted);
    void answerIdentity(RetainPtr<SecIdentityRef>&&, RetainPtr<CFArrayRef>&& chain);
    static enum ssl_verify_result_t verifyPeer(struct ssl_st*, uint8_t* alert);
    void routeResolved(Expected<CocoaCurlProxyRoute, String>&&);
    bool applyNextServer();
    void connect();
    void connectOnQueue();
    void connectFinished(CURLcode, curl_socket_t);
    void open();
    void readAvailable();
    void receiveWebSocketHandshake(std::span<const uint8_t>);
    void flushWebSocketHandshake();
    void resumeWebSocketRead();
    void resumeWriteSource();
    void suspendWriteSource();
    void fail(int code, const String& description);

    RefPtr<LegacyWebSocketHandshake> m_webSocketHandshake;
    bool m_webSocketRequestSent { false };
    bool m_webSocketReadSuspended { false };
    bool m_webSocketResponseReceived { false };
    Vector<uint8_t> m_webSocketOutput;
    size_t m_webSocketOutputOffset { 0 };
    Vector<uint8_t> m_webSocketInput;

    Options m_options;
    Client m_client; // Main thread only.

    CURL* m_curl { nullptr };
    std::shared_ptr<CocoaCurlTLSState> m_tls;
    // ServerTrust::Client: the question to the client the connect queue is waiting on. Main thread only.
    std::shared_ptr<ClientAnswer> m_pendingAnswer;
    RefPtr<CocoaCurlRouteResolver> m_routeResolver;
    // The servers of the route not yet tried, the one being tried, and what reaching it takes.
    CocoaCurlProxyRoute m_proxyRoute;
    std::optional<CocoaCurlProxyServer> m_proxyServer;
    curl_slist* m_proxyHeaders { nullptr };
    // The connect limit set on the handle for the server being tried, in milliseconds; 0 for none.
    long m_connectTimeoutMilliseconds { 0 };
    std::shared_ptr<CocoaCurlTLSState> m_proxyTLS;
    bool m_forwardedByProxy { false };
    String m_remoteAddress;
    dispatch_queue_t m_connectQueue { nullptr };
    bool m_connecting { false }; // Main thread only; true while the connect queue owns m_curl.

    curl_socket_t m_socket { CURL_SOCKET_BAD };
    dispatch_source_t m_readSource { nullptr };
    dispatch_source_t m_writeSource { nullptr };
    bool m_writeSourceActive { false };

    // Held jointly with the curl handle, because curl closes its socket when the handle is cleaned up -- which
    // happens after this object is gone.
    CocoaCurlSocketGate* m_gate { nullptr };
};

} // namespace WebCore
