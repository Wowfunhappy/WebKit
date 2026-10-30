/*
 * Copyright (C) 2026 Wowfunhappy. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#include "config.h"
#include "CocoaCurlSocketStream.h"

#include "CocoaCurlClientHello.h"
#include "CocoaCurlSocketGate.h"
#include "CocoaCurlTLS.h"
#include "CocoaCurlTransfer.h"
#include <openssl/ssl.h>
#include <wtf/MainThread.h>
#include <wtf/MonotonicTime.h>
#include <wtf/text/MakeString.h>

#include "LegacyLoadInterceptor.h"
#include "ResourceRequest.h"
#include "HTTPParsers.h"
#include "ResourceResponse.h"
#include <wtf/text/StringBuilder.h>
#include <wtf/text/StringToIntegerConversion.h>

namespace WebCore {

Ref<CocoaCurlSocketStream> CocoaCurlSocketStream::create(Options&& options, Client&& client)
{
    return adoptRef(*new CocoaCurlSocketStream(WTF::move(options), WTF::move(client)));
}

CocoaCurlSocketStream::CocoaCurlSocketStream(Options&& options, Client&& client)
    : m_options(WTF::move(options))
    , m_client(WTF::move(client))
{
    m_gate = cocoaCurlSocketGateCreate();
}

// The connect queue waits on the semaphore while the main thread puts a question to the client.
struct CocoaCurlSocketStream::ClientAnswer {
    ClientAnswer()
        : semaphore(dispatch_semaphore_create(0))
    {
    }
    ~ClientAnswer() { dispatch_release(semaphore); }
    dispatch_semaphore_t semaphore;
    bool answered { false };
    bool accepted { false };
};

CocoaCurlSocketStream::~CocoaCurlSocketStream()
{
    ASSERT(!m_curl);
    if (m_tls) {
        m_tls->requestIdentity = nullptr;
        m_tls->requestSignature = nullptr;
    }
    curl_slist_free_all(m_proxyHeaders);
    if (m_connectQueue)
        dispatch_release(m_connectQueue);
    if (m_gate)
        cocoaCurlSocketGateRelease(m_gate);
}

static int peerTrustStreamIndex()
{
    static int index = SSL_CTX_get_ex_new_index(0, nullptr, nullptr, nullptr, nullptr);
    return index;
}

// A trust object for the chain the peer presented, under the SSL policy for the host. The connection's SSL object is
// alive only inside the handshake, so the chain is taken there.
static RetainPtr<SecTrustRef> copyTrustForPeer(SSL* ssl, const String& host)
{
    STACK_OF(X509)* chain = SSL_get_peer_full_cert_chain(ssl);
    if (!chain || !sk_X509_num(chain))
        return nullptr;
    auto certificates = adoptCF(CFArrayCreateMutable(nullptr, 0, &kCFTypeArrayCallBacks));
    for (size_t i = 0; i < sk_X509_num(chain); ++i) {
        unsigned char* der = nullptr;
        int length = i2d_X509(sk_X509_value(chain, i), &der);
        RetainPtr<SecCertificateRef> certificate;
        if (length > 0 && der) {
            auto data = adoptCF(CFDataCreate(nullptr, der, length));
            certificate = data ? adoptCF(SecCertificateCreateWithData(nullptr, data.get())) : nullptr;
        }
        OPENSSL_free(der);
        if (!certificate)
            return nullptr;
        CFArrayAppendValue(certificates.get(), certificate.get());
    }
    auto policy = adoptCF(SecPolicyCreateSSL(true, host.createCFString().get()));
    SecTrustRef trust = nullptr;
    if (SecTrustCreateWithCertificates(certificates.get(), policy.get(), &trust) != errSecSuccess) {
        if (trust)
            CFRelease(trust);
        return nullptr;
    }
    return adoptCF(trust);
}

// On the connect queue, inside the handshake, which goes on once the client has answered on the main thread.
bool CocoaCurlSocketStream::waitForAnswer(Function<void(CocoaCurlSocketStream&, std::shared_ptr<ClientAnswer>&&)>&& ask)
{
    auto answer = std::make_shared<ClientAnswer>();
    callOnMainThread([protectedThis = Ref { *this }, answer, ask = WTF::move(ask)]() mutable {
        protectedThis->m_pendingAnswer = answer;
        if (cocoaCurlSocketGateCancelled(protectedThis->m_gate))
            return protectedThis->answer(false);
        ask(protectedThis.get(), WTF::move(answer));
    });
    auto asked = MonotonicTime::now();
    dispatch_semaphore_wait(answer->semaphore, DISPATCH_TIME_FOREVER);
    // The time the client takes to answer is not the connection's. curl measures the connect limit from the start
    // of the attempt and reads it afresh at each check, so the limit grows by the wait.
    if (m_connectTimeoutMilliseconds) {
        m_connectTimeoutMilliseconds += (MonotonicTime::now() - asked).millisecondsAs<long>();
        curl_easy_setopt(m_curl, CURLOPT_CONNECTTIMEOUT_MS, m_connectTimeoutMilliseconds);
    }
    return answer->accepted;
}

// The connect queue reads what the answer set once the semaphore lets it go on.
void CocoaCurlSocketStream::answer(bool accepted)
{
    ASSERT(isMainThread());
    auto answer = std::exchange(m_pendingAnswer, nullptr);
    if (!answer || std::exchange(answer->answered, true))
        return;
    answer->accepted = accepted;
    dispatch_semaphore_signal(answer->semaphore);
}

// ServerTrust::Client: the chain the server presented, as a trust object for the URL's host, is put to the client.
ssl_verify_result_t CocoaCurlSocketStream::verifyPeer(SSL* ssl, uint8_t* alert)
{
    auto* stream = static_cast<CocoaCurlSocketStream*>(SSL_CTX_get_ex_data(SSL_get_SSL_CTX(ssl), peerTrustStreamIndex()));
    RetainPtr trust = stream ? copyTrustForPeer(ssl, stream->m_options.url.host().toString()) : nullptr;
    bool accepted = trust && stream->waitForAnswer([trust = WTF::move(trust)](CocoaCurlSocketStream& stream, std::shared_ptr<ClientAnswer>&& answer) mutable {
        if (!stream.m_client.decideServerTrust)
            return stream.answer(false);
        stream.m_client.decideServerTrust(WTF::move(trust), [protectedStream = Ref { stream }, answer = WTF::move(answer)](bool accepted) {
            if (protectedStream->m_pendingAnswer == answer)
                protectedStream->answer(accepted);
        });
    });
    if (accepted)
        return ssl_verify_ok;
    *alert = SSL_AD_BAD_CERTIFICATE;
    return ssl_verify_invalid;
}

CURLcode CocoaCurlSocketStream::installTLS(CURL* easy, void* context, void* data)
{
    auto& stream = *static_cast<CocoaCurlSocketStream*>(data);
    auto* ssl = static_cast<SSL_CTX*>(context);
    if (stream.m_proxyTLS && CocoaCurlRouteResolver::isProxyHandshake(easy))
        return CocoaCurlTLSState::installSynchronously(ssl, stream.m_proxyTLS);
    if (stream.m_options.serverTrust == ServerTrust::Native)
        return CocoaCurlTLSState::installSynchronously(ssl, stream.m_tls);
    if (auto code = CocoaCurlTLSState::installWithClientIdentity(ssl, stream.m_tls); code != CURLE_OK)
        return code;
    if (peerTrustStreamIndex() < 0 || !SSL_CTX_set_ex_data(ssl, peerTrustStreamIndex(), &stream))
        return CURLE_OUT_OF_MEMORY;
    SSL_CTX_set_custom_verify(ssl, SSL_VERIFY_PEER, verifyPeer);
    return CURLE_OK;
}

void CocoaCurlSocketStream::start()
{
    ASSERT(isMainThread());
    m_curl = m_gate ? curl_easy_init() : nullptr;
    if (!m_curl) {
        fail(0, "Could not create the WebSocket connection"_s);
        return;
    }
    // Released where the handle is cleaned up, which is when curl closes its socket.
    cocoaCurlSocketGateRetain(m_gate);
    // curl connects to the origin and hands the connection over: it sends no request of its own, and the client's
    // bytes are written onto the socket it returns. An RFC 6455 upgrade is HTTP/1.1, so http/1.1 is the only
    // protocol ALPN offers.
    auto host = m_options.url.host();
    bool bracketed = host.contains(':');
    auto endpoint = makeString(m_options.secure ? "https://"_s : "http://"_s, bracketed ? "["_s : ""_s, host, bracketed ? "]"_s : ""_s, ':', m_options.port, '/');
    curl_easy_setopt(m_curl, CURLOPT_URL, endpoint.utf8().data());
    curl_easy_setopt(m_curl, CURLOPT_CONNECT_ONLY, 1L);
    curl_easy_setopt(m_curl, CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_1_1);
    curl_easy_setopt(m_curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(m_curl, CURLOPT_OPENSOCKETFUNCTION, cocoaCurlSocketGateOpen);
    curl_easy_setopt(m_curl, CURLOPT_OPENSOCKETDATA, m_gate);
    curl_easy_setopt(m_curl, CURLOPT_CLOSESOCKETFUNCTION, cocoaCurlSocketGateClose);
    curl_easy_setopt(m_curl, CURLOPT_CLOSESOCKETDATA, m_gate);
    if (m_options.secure) {
        m_tls = std::make_shared<CocoaCurlTLSState>();
        // The state is read on the connect queue, so its string may not share a StringImpl with the main thread's.
        m_tls->url = m_options.url.isolatedCopy();
        m_tls->acceptAnyCertificate = m_options.acceptsAnyCertificate;
        m_tls->presentsPreferredIdentity = m_options.presentsPreferredIdentity;
        // The connect queue is this stream's own, and the handshake on it waits for the lookup.
        m_tls->requestPreferredIdentity = [tls = m_tls.get()] {
            if (auto preferred = CocoaCurlTLSState::preferredIdentity(tls->url)) {
                tls->identity = WTF::move(preferred->identity);
                tls->clientCertificates = WTF::move(preferred->certificates);
                tls->identityAnswered = true;
            }
            tls->preferredIdentityResolved = true;
            return true;
        };
        if (m_options.serverTrust == ServerTrust::Client) {
            // Both run on the connect queue inside the handshake, which waits for their answers. The stream outlives
            // the connect (connect() holds a reference until connectFinished).
            m_tls->requestIdentity = [this](SSL* ssl) {
                waitForAnswer([authorities = CocoaCurlTLSState::certificateAuthorities(ssl)](CocoaCurlSocketStream& stream, std::shared_ptr<ClientAnswer>&& answer) mutable {
                    if (!stream.m_client.requestIdentity)
                        return stream.answerIdentity(nullptr, nullptr);
                    stream.m_client.requestIdentity(WTF::move(authorities), [protectedStream = Ref { stream }, answer = WTF::move(answer)](RetainPtr<SecIdentityRef>&& identity, RetainPtr<CFArrayRef>&& chain) mutable {
                        if (protectedStream->m_pendingAnswer == answer)
                            protectedStream->answerIdentity(WTF::move(identity), WTF::move(chain));
                    });
                });
                // A stream closed while the question was out has no identity: identityAnswered is set either way.
                m_tls->identityAnswered = true;
                return true;
            };
            m_tls->requestSignature = [tls = m_tls.get()](SecKeyAlgorithm algorithm, RetainPtr<CFDataRef>&& data) {
                CFErrorRef error = nullptr;
                tls->signature = adoptCF(SecKeyCreateSignature(tls->privateKey.get(), algorithm, data.get(), &error));
                tls->signingError = adoptCF(error);
                tls->signingComplete = true;
                return true;
            };
        }
        // The certificate is answered for by the system trust store, inside the handshake or by the client; curl's
        // own hostname check is not used because SecPolicyCreateSSL carries the name.
        curl_easy_setopt(m_curl, CURLOPT_SSL_VERIFYPEER, 1L);
        curl_easy_setopt(m_curl, CURLOPT_SSL_VERIFYHOST, 0L);
        curl_easy_setopt(m_curl, CURLOPT_CAINFO, static_cast<const char*>(nullptr));
        curl_easy_setopt(m_curl, CURLOPT_CAPATH, static_cast<const char*>(nullptr));
        curl_easy_setopt(m_curl, CURLOPT_SSLVERSION, cocoaCurlMinimumTLSVersion(m_options.minimumTLSProtocol));
    }
    // An HTTPS proxy's handshake reaches the same function as the origin's.
    curl_easy_setopt(m_curl, CURLOPT_SSL_CTX_FUNCTION, installTLS);
    curl_easy_setopt(m_curl, CURLOPT_SSL_CTX_DATA, this);

    // CFNetwork resolves proxies against http(s), never against a WebSocket scheme, and its answer is the one that
    // carries the exception list, the bypass rules and any PAC script.
    URL routeURL { makeString(m_options.secure ? "https://"_s : "http://"_s, bracketed ? "["_s : ""_s, host, bracketed ? "]"_s : ""_s, ':', m_options.port, '/') };
    m_routeResolver = CocoaCurlRouteResolver::create(routeURL, m_options.configuredProxySettings.get(), m_options.proxyFilterResults, [protectedThis = Ref { *this }](Expected<CocoaCurlProxyRoute, String>&& route) {
        protectedThis->routeResolved(WTF::move(route));
    });
    m_routeResolver->start();
}

void CocoaCurlSocketStream::answerIdentity(RetainPtr<SecIdentityRef>&& identity, RetainPtr<CFArrayRef>&& chain)
{
    ASSERT(isMainThread());
    m_tls->identity = WTF::move(identity);
    m_tls->clientCertificates = (__bridge NSArray *)chain.get();
    answer(true);
}

void CocoaCurlSocketStream::routeResolved(Expected<CocoaCurlProxyRoute, String>&& route)
{
    ASSERT(isMainThread());
    m_routeResolver = nullptr;
    if (cocoaCurlSocketGateCancelled(m_gate))
        return;
    if (!route) {
        fail(0, route.error());
        return;
    }
    m_proxyRoute = WTF::move(*route);
    if (!applyNextServer()) {
        fail(0, "Could not resolve the proxy route for this WebSocket"_s);
        return;
    }
    connect();
}

// The route's next server, each tried when the connection to the one before it fails, as a load's are
// (CocoaCurlTransfer::failOverProxy).
bool CocoaCurlSocketStream::applyNextServer()
{
    CocoaCurlProxyServer server;
    if (!m_proxyRoute.isEmpty()) {
        server = m_proxyRoute.first();
        m_proxyRoute.removeAt(0);
    }
    if (m_proxyRoute.isEmpty())
        server.failoverTimeout = { };
    m_proxyServer = server;
    m_proxyTLS = nullptr;
    if (server.type == CocoaCurlProxyServer::Type::HTTPS) {
        // Read on the connect queue, so its URL shares no StringImpl with the main thread's.
        m_proxyTLS = std::make_shared<CocoaCurlTLSState>();
        m_proxyTLS->url = CocoaCurlRouteResolver::tlsURL(server).isolatedCopy();
    }
    bool isHTTPProxy = server.type == CocoaCurlProxyServer::Type::HTTP || server.type == CocoaCurlProxyServer::Type::HTTPS;
    m_forwardedByProxy = isHTTPProxy && !m_options.secure && !m_options.tunnelsPlainConnections;
    auto timeout = server.failoverTimeout ? server.failoverTimeout : m_options.connectTimeout;
    m_connectTimeoutMilliseconds = timeout.isInfinity() ? 0 : std::max<long>(1, static_cast<long>(timeout.milliseconds()));
    return CocoaCurlRouteResolver::apply(m_curl, server, m_proxyHeaders)
        && curl_easy_setopt(m_curl, CURLOPT_HTTPPROXYTUNNEL, m_forwardedByProxy ? 0L : 1L) == CURLE_OK
        && curl_easy_setopt(m_curl, CURLOPT_PROXY_SSLVERSION, CURL_SSLVERSION_TLSv1_2) == CURLE_OK
        && curl_easy_setopt(m_curl, CURLOPT_CONNECTTIMEOUT_MS, m_connectTimeoutMilliseconds ? m_connectTimeoutMilliseconds : std::numeric_limits<long>::max()) == CURLE_OK
        && CocoaCurlRouteResolver::applyCredentials(m_curl, server.username, server.password);
}

void CocoaCurlSocketStream::connect()
{
    if (!m_connectQueue)
        m_connectQueue = dispatch_queue_create("com.apple.WebKit.SocketStreamConnect", DISPATCH_QUEUE_SERIAL);
    m_connecting = true;
    ref(); // Balanced in connectFinished, which the connect queue posts back to the main thread.
    dispatch_async(m_connectQueue, ^{
        connectOnQueue();
    });
}

void CocoaCurlSocketStream::connectOnQueue()
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

void CocoaCurlSocketStream::connectFinished(CURLcode code, curl_socket_t connected)
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
        // A proxy that could not be reached, before it answered the CONNECT, gives way to the route's next server.
        long connectCode = 0;
        curl_easy_getinfo(m_curl, CURLINFO_HTTP_CONNECTCODE, &connectCode);
        bool proxyFailed = m_proxyServer && m_proxyServer->type != CocoaCurlProxyServer::Type::Direct && !connectCode
            && (code == CURLE_COULDNT_CONNECT || code == CURLE_COULDNT_RESOLVE_PROXY || code == CURLE_OPERATION_TIMEDOUT || code == CURLE_PROXY);
        if (proxyFailed && !m_proxyRoute.isEmpty()) {
            if (applyNextServer())
                return connect();
        } else if (proxyFailed && code != CURLE_PROXY)
            CocoaCurlProxyConfiguration::reportError(true, "net::ERR_PROXY_CONNECTION_FAILED"_s, emptyString());
        bool rejected = code == CURLE_PEER_FAILED_VERIFICATION && m_options.serverTrust == ServerTrust::Client;
        fail(code, rejected ? "The certificate for this server is invalid"_s : String::fromUTF8(curl_easy_strerror(code)));
        return;
    }
    // The Proxy-Authorization field went with the CONNECT; a forwarding proxy's goes with the client's requests.
    curl_easy_setopt(m_curl, CURLOPT_PROXYHEADER, nullptr);
    curl_slist_free_all(std::exchange(m_proxyHeaders, nullptr));
    m_socket = connected;
    char* address = nullptr;
    if (curl_easy_getinfo(m_curl, CURLINFO_PRIMARY_IP, &address) == CURLE_OK && address)
        m_remoteAddress = String::fromLatin1(address);
    // From here the teardown reaches the connection through the main thread, not the descriptor.
    cocoaCurlSocketGateForget(m_gate);
    open();
}

void CocoaCurlSocketStream::open()
{
    m_readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, m_socket, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(m_readSource, ^{ readAvailable(); });
    // Resumed only while curl has taken less than what the client offered it.
    m_writeSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, m_socket, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(m_writeSource, ^{
        // Suspended first: what the client writes next decides whether it is armed again.
        suspendWriteSource();
        if (!m_webSocketOutput.isEmpty())
            flushWebSocketHandshake();
        else if (m_client.canSendMore)
            m_client.canSendMore();
    });
    dispatch_resume(m_readSource);
    std::optional<ForwardingProxy> forwardingProxy;
    if (m_forwardedByProxy)
        forwardingProxy = ForwardingProxy { m_proxyServer->authorizationHeader };
    if (m_client.didOpen)
        m_client.didOpen(WTF::move(forwardingProxy));
}

void CocoaCurlSocketStream::readAvailable()
{
    ASSERT(isMainThread());
    if (!m_curl)
        return;
    Ref protectedThis { *this };
    uint8_t buffer[16 * 1024];
    for (;;) {
        size_t received = 0;
        auto code = curl_easy_recv(m_curl, buffer, sizeof(buffer), &received);
        // A readable socket can still hold less than one TLS record, and one record can hold several frames, so the
        // loop ends on the transport saying so rather than on the socket.
        if (code == CURLE_AGAIN)
            return;
        if (code != CURLE_OK) {
            fail(code, String::fromUTF8(curl_easy_strerror(code)));
            return;
        }
        if (!received) {
            if (RefPtr handshake = std::exchange(m_webSocketHandshake, nullptr))
                handshake->didComplete("net::ERR_CONNECTION_CLOSED"_s);
            if (m_client.didClose)
                m_client.didClose();
            return;
        }
        if (m_webSocketHandshake && !m_webSocketResponseReceived && m_webSocketHandshake->observesResponseHeaders())
            receiveWebSocketHandshake(std::span { buffer, received });
        else if (m_client.didReceiveData)
            m_client.didReceiveData(std::span { buffer, received });
        if (!m_curl || m_webSocketReadSuspended)
            return;
    }
}

std::optional<size_t> CocoaCurlSocketStream::send(std::span<const uint8_t> data)
{
    ASSERT(isMainThread());
    if (!m_curl || !m_readSource)
        return 0;
    if (m_webSocketHandshake && !std::exchange(m_webSocketRequestSent, true) && m_webSocketHandshake->observesRequestHeaders()) {
        auto lines = String { byteCast<Latin1Character>(data) }.split('\n');
        ResourceRequest request { URL { m_options.url } };
        for (size_t i = 1; i < lines.size(); ++i) {
            auto& line = lines[i];
            auto colon = line.find(':');
            if (colon != notFound)
                request.setHTTPHeaderField(line.left(colon), line.substring(colon + 1).trim(isASCIIWhitespace<char16_t>));
        }
        m_webSocketHandshake->willSendHeaders(WTF::move(request), [this, protectedThis = Ref { *this }, requestLine = lines[0]](ResourceRequest&& request) {
            if (!m_webSocketHandshake || !m_client.didReceiveData)
                return;
            if (request.isNull()) {
                fail(CURLE_ABORTED_BY_CALLBACK, "WebSocket connection was blocked by an extension"_s);
                return;
            }
            StringBuilder message;
            message.append(requestLine, '\n');
            for (auto& field : request.httpHeaderFields())
                message.append(field.key, ": "_s, field.value, "\r\n"_s);
            message.append("\r\n"_s);
            auto bytes = message.toString().latin1();
            m_webSocketOutput = Vector<uint8_t> { byteCast<uint8_t>(bytes.span()) };
            flushWebSocketHandshake();
        });
        return data.size();
    }
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

void CocoaCurlSocketStream::setWebSocketHandshake(RefPtr<LegacyWebSocketHandshake>&& handshake)
{
    m_webSocketHandshake = WTF::move(handshake);
}

void CocoaCurlSocketStream::didValidateWebSocketHandshake(const ResourceResponse& response, bool connected)
{
    if (RefPtr handshake = std::exchange(m_webSocketHandshake, nullptr))
        handshake->didValidateResponse(response, connected);
}

void CocoaCurlSocketStream::flushWebSocketHandshake()
{
    while (!m_webSocketOutput.isEmpty()) {
        auto sent = send(m_webSocketOutput.span().subspan(m_webSocketOutputOffset));
        if (!sent) {
            fail(CURLE_SEND_ERROR, "WebSocket handshake write failed"_s);
            return;
        }
        if (!*sent)
            return;
        m_webSocketOutputOffset += *sent;
        if (m_webSocketOutputOffset == m_webSocketOutput.size()) {
            m_webSocketOutput.clear();
            m_webSocketOutputOffset = 0;
        }
    }
}

void CocoaCurlSocketStream::resumeWebSocketRead()
{
    if (std::exchange(m_webSocketReadSuspended, false) && m_readSource)
        dispatch_resume(m_readSource);
}

void CocoaCurlSocketStream::receiveWebSocketHandshake(std::span<const uint8_t> data)
{
    m_webSocketInput.append(data);
    auto text = String { byteCast<Latin1Character>(m_webSocketInput.span()) };
    auto headerEnd = text.find("\r\n\r\n"_s);
    if (headerEnd == notFound)
        return;
    auto statusLine = text.left(text.find("\r\n"_s));
    auto firstSpace = statusLine.find(' ');
    auto secondSpace = firstSpace == notFound ? notFound : statusLine.find(' ', firstSpace + 1);
    ResourceResponse response;
    response.setURL(URL { m_options.url });
    if (firstSpace != notFound)
        response.setHTTPVersion(statusLine.left(firstSpace));
    if (secondSpace != notFound) {
        response.setHTTPStatusCode(parseInteger<int>(statusLine.substring(firstSpace + 1, secondSpace - firstSpace - 1)).value_or(0));
        response.setHTTPStatusText(statusLine.substring(secondSpace + 1));
    }
    Vector<String> cookies;
    auto fields = m_webSocketInput.span().subspan(text.find('\n') + 1, headerEnd + 3 - text.find('\n'));
    for (; !fields.empty(); fields = fields.subspan(1)) {
        String failure;
        StringView name;
        String value;
        auto consumed = parseHTTPHeader(fields, failure, name, value);
        if (!consumed) {
            fail(CURLE_WEIRD_SERVER_REPLY, failure);
            return;
        }
        fields = fields.subspan(consumed);
        if (name.isEmpty())
            break;
        if (equalLettersIgnoringASCIICase(name, "set-cookie"_s))
            cookies.append(value);
        else {
            auto key = name.toString();
            auto existing = response.httpHeaderField(key);
            response.setHTTPHeaderField(key, existing.isEmpty() ? value : makeString(existing, ", "_s, value));
        }
    }
    m_webSocketReadSuspended = true;
    dispatch_suspend(m_readSource);
    m_webSocketHandshake->didReceiveResponse(ResourceResponse { response }, Vector<String> { cookies },
        [this, protectedThis = Ref { *this }, response, cookies, original = std::exchange(m_webSocketInput, { }), headerEnd, statusLine](ResourceResponse&& approved, Vector<String>&& approvedCookies) {
            if (!m_webSocketHandshake || !m_client.didReceiveData)
                return;
            if (approved.isNull()) {
                fail(CURLE_ABORTED_BY_CALLBACK, "WebSocket connection was blocked by an extension"_s);
                return;
            }
            Vector<uint8_t> rewritten;
            auto header = original.span().first(headerEnd + 4);
            if (response.httpHeaderFields() != approved.httpHeaderFields() || cookies != approvedCookies) {
                StringBuilder message;
                message.append(statusLine, "\r\n"_s);
                for (auto& field : approved.httpHeaderFields()) {
                    if (!equalLettersIgnoringASCIICase(field.key, "set-cookie"_s))
                        message.append(field.key, ": "_s, field.value, "\r\n"_s);
                }
                for (auto& cookie : approvedCookies)
                    message.append("Set-Cookie: "_s, cookie, "\r\n"_s);
                message.append("\r\n"_s);
                auto bytes = message.toString().latin1();
                rewritten = Vector<uint8_t> { byteCast<uint8_t>(bytes.span()) };
                header = rewritten.span();
            }
            m_webSocketResponseReceived = true;
            m_client.didReceiveData(header);
            resumeWebSocketRead();
            if (m_client.didReceiveData && original.size() > headerEnd + 4)
                m_client.didReceiveData(original.span().subspan(headerEnd + 4));
        });
}

void CocoaCurlSocketStream::resumeWriteSource()
{
    if (m_writeSource && !m_writeSourceActive) {
        m_writeSourceActive = true;
        dispatch_resume(m_writeSource);
    }
}

void CocoaCurlSocketStream::suspendWriteSource()
{
    if (m_writeSource && m_writeSourceActive) {
        m_writeSourceActive = false;
        dispatch_suspend(m_writeSource);
    }
}

// A route the resolver answers synchronously can fail inside the client's own setup, before the client has handed
// the stream to whatever reports its failure, so the failure reaches the client on a later turn of the run loop.
void CocoaCurlSocketStream::fail(int code, const String& description)
{
    ASSERT(isMainThread());
    if (RefPtr handshake = std::exchange(m_webSocketHandshake, nullptr))
        handshake->didComplete("net::ERR_FAILED"_s);
    // Only the failure is delivered: nothing else reaches a client whose connection has failed.
    m_client.didOpen = { };
    m_client.didReceiveData = { };
    m_client.didClose = { };
    m_client.canSendMore = { };
    m_client.decideServerTrust = { };
    m_client.requestIdentity = { };
    if (!m_client.didFail)
        return;
    // The client behind didFail may be gone by then, and close() clears the client when it goes.
    callOnMainThread([protectedThis = Ref { *this }, code, description = description.isolatedCopy()] {
        auto client = std::exchange(protectedThis->m_client, Client { });
        if (client.didFail)
            client.didFail(code, description);
    });
}

void CocoaCurlSocketStream::close()
{
    ASSERT(isMainThread());
    if (RefPtr handshake = std::exchange(m_webSocketHandshake, nullptr))
        handshake->didComplete("net::ERR_ABORTED"_s);
    m_webSocketInput.clear();
    m_webSocketOutput.clear();
    resumeWebSocketRead();
    cocoaCurlSocketGateCancel(m_gate);
    m_client = Client { };
    // The connect queue stops waiting, and the handshake fails on the descriptor the gate shut.
    answer(false);
    if (RefPtr routeResolver = std::exchange(m_routeResolver, nullptr))
        routeResolver->cancel();
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
    // The handle owns the descriptor the sources are armed on, so it closes only once both have finished cancelling.
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

} // namespace WebCore
