/*
 * Copyright (C) 2026 Wowfunhappy. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */

#pragma once

// A page's WebSocket, as upstream's curl port's WebSocketTask carries one (NetworkProcess/curl/WebSocketTaskCurl):
// an RFC 6455 client on a CocoaCurlSocketStream, which takes the route the proxy settings and the system give the
// URL, and the browser's ClientHello. The handshake follows redirects, answers HTTP authentication (Basic, Digest,
// NTLM and Negotiate) with the credentials the AuthenticationManager supplies, sends and stores cookies as the
// session's network tasks do, and puts an untrusted server certificate and a request for a client certificate to the
// user as a load does. Everything runs on
// the main thread, where NetworkSocketChannel receives the task's events.

#include "WebPageProxyIdentifier.h"
#include <WebCore/CocoaCurlProxyConfiguration.h>
#include <WebCore/Credential.h>
#include <WebCore/FrameIdentifier.h>
#include <WebCore/PageIdentifier.h>
#include <WebCore/ResourceRequest.h>
#include <WebCore/ResourceResponse.h>
#include <WebCore/SecurityOriginData.h>
#include <wtf/CompletionHandler.h>
#include <wtf/Deque.h>
#include <wtf/RetainPtr.h>
#include <wtf/RunLoop.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/ThreadSafeWeakPtr.h>
#include <wtf/WeakPtr.h>

OBJC_CLASS WKWebSocketConnectionAuthentication;

namespace WebCore {
class AuthenticationChallenge;
class CocoaCurlSocketStream;
struct ClientOrigin;
enum class IsInitiatedByDedicatedWorker : bool;
enum class StoredCredentialsPolicy : uint8_t;
}

namespace WebKit {
class WebSocketTask;
}

namespace WebKit {

class NetworkSessionCocoa;
class NetworkSocketChannel;
enum class AuthenticationChallengeDisposition : uint8_t;
struct SessionSet;

class WebSocketTask : public ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr<WebSocketTask> {
    WTF_MAKE_TZONE_ALLOCATED(WebSocketTask);
public:
    typedef uint64_t TaskIdentifier;

    static Ref<WebSocketTask> create(NetworkSocketChannel&, WebPageProxyIdentifier, std::optional<WebCore::FrameIdentifier>, std::optional<WebCore::PageIdentifier>, WeakPtr<SessionSet>&&, const WebCore::ResourceRequest&, const String& protocol, const WebCore::ClientOrigin&, WebCore::StoredCredentialsPolicy, WebCore::IsInitiatedByDedicatedWorker);
    ~WebSocketTask();

    void sendString(std::span<const uint8_t>, CompletionHandler<void()>&&);
    void sendData(std::span<const uint8_t>, CompletionHandler<void()>&&);
    void close(int32_t code, const String& reason);

    void cancel();
    void resume();

    TaskIdentifier identifier() const { return m_identifier; }
    NetworkSessionCocoa* networkSession();
    SessionSet* sessionSet() { return m_sessionSet.get(); }

private:
    WebSocketTask(NetworkSocketChannel&, WebPageProxyIdentifier, std::optional<WebCore::FrameIdentifier>, std::optional<WebCore::PageIdentifier>, WeakPtr<SessionSet>&&, const WebCore::ResourceRequest&, const String& protocol, const WebCore::ClientOrigin&, WebCore::StoredCredentialsPolicy, WebCore::IsInitiatedByDedicatedWorker);

    enum class State : uint8_t { Connecting, Handshaking, Open, Closing, Closed };

    // A frame, or a handshake request, on its way to the socket; its completion runs once the stream has taken its last
    // byte, which is when WebKit takes it out of the page's bufferedAmount.
    struct Outgoing {
        Vector<uint8_t> data;
        CompletionHandler<void()> completion;
    };

    // One challenge of a 401: its scheme as CFNetwork names it, its own text, and its realm.
    struct OfferedChallenge {
        String scheme;
        String challenge;
        String realm;
    };

    void startConnection();
    void streamDidOpen(std::optional<String>&& forwardingProxyAuthorization);
    void decideServerTrust(RetainPtr<SecTrustRef>&&, CompletionHandler<void(bool)>&&);
    void requestClientIdentity(RetainPtr<CFArrayRef>&& authorities, CompletionHandler<void(RetainPtr<SecIdentityRef>&&, RetainPtr<CFArrayRef>&&)>&&);
    void receive(std::span<const uint8_t>);
    void handleEndOfConnection();
    void flushOutput();
    void write(Outgoing&&);
    void sendFrame(uint8_t opcode, std::span<const uint8_t> payload, CompletionHandler<void()>&& = { });
    void sendCloseFrame(uint16_t code, std::span<const uint8_t> reason);

    void sendHandshake();
    bool completeHandshake(std::span<const uint8_t> header);
    bool parseStatusLine(std::span<const uint8_t> header, int& statusCode, size_t& lineLength);
    bool followRedirect();
    bool authenticate();
    bool holdConnectionAfterRefusal();
    void resetConnection();
    void continueWithHandshakeRequest(WebCore::ResourceRequest&&, int status);
    bool handshakeFailed(int status);

    std::optional<WebCore::Credential> proposedCredential(size_t challengeIndex);
    RetainPtr<NSURLProtectionSpace> protectionSpace(size_t challengeIndex);
    void presentChallenge(size_t challengeIndex);
    void continueWithCredential(std::optional<WebCore::Credential>&&, size_t challengeIndex);
    void askAuthenticationManager(WebCore::AuthenticationChallenge&&, CompletionHandler<void(AuthenticationChallengeDisposition, const WebCore::Credential&)>&&);

    void parseFrames();
    void handleFrame(uint8_t opcode, bool fin, std::span<const uint8_t> payload);

    void armHandshakeDeadline(Seconds remaining);
    Seconds disarmHandshakeDeadline();
    void handshakeTimedOut();

    String cookieHeader() const;
    void storeCookies(const Vector<String>& setCookieFields);
    bool updateCookieBlocking(const WebCore::ResourceRequest&);

    void failProtocol(const String& reason);
    void fail(const String& reason);
    void deliverClose(unsigned short code, const String& reason);
    void teardownTransport();
    void closeTransport();

    WeakPtr<NetworkSocketChannel> m_channel;
    TaskIdentifier m_identifier;
    Markable<WebPageProxyIdentifier> m_webPageProxyID;
    std::optional<WebCore::FrameIdentifier> m_frameID;
    std::optional<WebCore::PageIdentifier> m_pageID;
    WeakPtr<SessionSet> m_sessionSet;
    String m_partition;
    WebCore::StoredCredentialsPolicy m_storedCredentialsPolicy;
    WebCore::SecurityOriginData m_topOrigin;
    WebCore::IsInitiatedByDedicatedWorker m_isInitiatedByDedicatedWorker;
    // The proxy.onRequest answers for the handshake (LegacyExtensionNetwork::interceptWebSocket).
    Vector<WebCore::CocoaCurlProxyFilterResult> m_proxyFilterResults;
    bool m_cookiesBlocked { false };

    // The hop being made now, and the protocols the page asked for, as Sec-WebSocket-Protocol lists them.
    WebCore::ResourceRequest m_request;
    String m_protocol;
    unsigned m_redirectCount { 0 };

    RefPtr<WebCore::CocoaCurlSocketStream> m_stream;
    bool m_transportOpen { false };
    std::optional<String> m_forwardingProxyAuthorization;

    State m_state { State::Connecting };
    String m_acceptKey;
    WebCore::ResourceResponse m_response;
    RunLoop::Timer m_handshakeTimer;
    std::optional<MonotonicTime> m_handshakeDeadline;
    Seconds m_handshakeTimeLeft;

    Vector<uint8_t> m_inBuffer;
    Deque<Outgoing> m_outQueue;
    Vector<Outgoing> m_heldSends;
    size_t m_outOffset { 0 };
    bool m_sentClose { false };
    Vector<uint8_t> m_messageBuffer;
    int m_messageOpcode { -1 };
    bool m_didConnect { false };
    bool m_didClose { false };

    unsigned m_authenticationFailureCount { 0 };
    std::optional<WebCore::Credential> m_lastCredential;
    Vector<OfferedChallenge> m_offeredChallenges;
    String m_offeredRealm;
    RetainPtr<WKWebSocketConnectionAuthentication> m_connectionAuthentication;
    size_t m_discardedBodyBytes { 0 };
    bool m_awaitingCredential { false };
};

} // namespace WebKit
