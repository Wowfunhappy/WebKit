/*
 * Copyright (C) 2009-2023 Apple Inc. All rights reserved.
 * Copyright (C) 2009 Google Inc. All rights reserved.
 * Copyright (C) 2026 Wowfunhappy. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are
 * met:
 *
 *     * Redistributions of source code must retain the above copyright
 * notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above
 * copyright notice, this list of conditions and the following disclaimer
 * in the documentation and/or other materials provided with the
 * distribution.
 *     * Neither the name of Google Inc. nor the names of its
 * contributors may be used to endorse or promote products derived from
 * this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
#include "SocketStreamHandleImpl.h"

// A WebSocket handshake is a TLS connection like any other, so it presents what the rest of this
// port's network layer presents: CocoaCurlSocketStream, libcurl in CONNECT_ONLY mode with the ClientHello
// CocoaCurlClientHello.h defines, and the system's own trust evaluation over BoringSSL.
#include "SocketStreamHandleClient.h"
#include <WebCore/CocoaCurlSocketStream.h>
#include <WebCore/DeprecatedGlobalSettings.h>
#include "WebSocketChannel.h"
#include <WebCore/Document.h>
#include <WebCore/LegacyLoadInterceptor.h>
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

    // Safari 7 extensions' webRequest decides the handshake first, for the document of the WebSocketChannel,
    // this handle's only client. A blocked handshake fails as the HSTS check above fails one.
    if (auto* interceptor = LegacyLoadInterceptor::singleton()) {
        Ref document = *static_cast<WebSocketChannel&>(m_client).document();
        auto continueHandshake = [this, protectedThis = Ref { *this }](bool proceed, Vector<CocoaCurlProxyFilterResult>&& proxyFilterResults) {
            if (state() == Closed)
                return;
            if (proceed)
                return connect(WTF::move(proxyFilterResults));
            callOnMainThread([this, protectedThis] {
                if (state() != Closed)
                    m_client.didFailSocketStream(*this, SocketStreamError(0, m_url.string(), "WebSocket connection was blocked by an extension"_s));
            });
        };
        if (interceptor->interceptWebSocket(document, url, WTF::move(continueHandshake)))
            return;
    }

    connect({ });
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

// A WebSocket is carried through a CONNECT tunnel by an HTTP proxy (RFC 6455 4.1), for ws:// as well.
void SocketStreamHandleImpl::connect(Vector<CocoaCurlProxyFilterResult>&& proxyFilterResults)
{
    CocoaCurlSocketStream::Client transportClient;
    transportClient.didOpen = [this](std::optional<CocoaCurlSocketStream::ForwardingProxy>&&) { transportDidOpen(); };
    transportClient.didReceiveData = [this](std::span<const uint8_t> data) { transportDidReceiveData(data); };
    transportClient.didClose = [this] { transportDidClose(); };
    transportClient.canSendMore = [this] { sendPendingData(); };
    transportClient.didFail = [this](int code, const String& description) { transportDidFail(code, description); };

    CocoaCurlSocketStream::Options options;
    options.url = m_url;
    options.port = port();
    options.secure = shouldUseSSL();
    options.acceptsAnyCertificate = DeprecatedGlobalSettings::allowsAnySSLCertificate() || m_shouldAcceptInsecureCertificates;
    options.proxyFilterResults = WTF::move(proxyFilterResults);
    m_transport = CocoaCurlSocketStream::create(WTF::move(options), WTF::move(transportClient));
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
