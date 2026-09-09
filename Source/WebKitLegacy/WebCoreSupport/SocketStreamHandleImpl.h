/*
 * Copyright (C) 2009 Apple Inc. All rights reserved.
 * Copyright (C) 2009 Google Inc. All rights reserved.
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

#pragma once

#include "SocketStreamHandle.h"
#include <pal/SessionID.h>
#include <wtf/RetainPtr.h>
#include <wtf/StreamBuffer.h>

// typedef struct __CFHTTPMessage* CFHTTPMessageRef; // MAVERICKS_BACKPORT: see the note in the private section below.

namespace WebCore {

class Credential;
class StorageSessionProvider;
class ProtectionSpace;
class SocketStreamHandleClient;
class SocketStreamCurlTransport; // MAVERICKS_BACKPORT: see the note in the private section below.

class SocketStreamHandleImpl : public SocketStreamHandle {
public:
    static Ref<SocketStreamHandleImpl> create(const URL& url, SocketStreamHandleClient& client, PAL::SessionID sessionID, const String& credentialPartition, SourceApplicationAuditToken&& auditData, const StorageSessionProvider* provider, bool shouldAcceptInsecureCertificates) { return adoptRef(*new SocketStreamHandleImpl(url, client, sessionID, credentialPartition, WTF::move(auditData), provider, shouldAcceptInsecureCertificates)); }

    virtual ~SocketStreamHandleImpl();

    static void setLegacyTLSEnabled(bool);

    void platformSend(std::span<const uint8_t> data, Function<void(bool)>&&) final;
    void platformSendHandshake(std::span<const uint8_t> data, const std::optional<CookieRequestHeaderFieldProxy>&, Function<void(bool, bool)>&&) final;
    void platformClose() final;
private:
    size_t bufferedAmount() final;
    std::optional<size_t> platformSendInternal(std::span<const uint8_t>);
    bool sendPendingData();

    SocketStreamHandleImpl(const URL&, SocketStreamHandleClient&, PAL::SessionID, const String& credentialPartition, SourceApplicationAuditToken&&, const StorageSessionProvider*, bool shouldAcceptInsecureCertificates);
    // MAVERICKS_BACKPORT: this port's socket streams run on libcurl and BoringSSL, the stack the rest
    // of its network layer uses, so what a WebSocket handshake presents is the browser's ClientHello.
    // SocketStreamCurlTransport owns the connection, its proxy route and its native trust evaluation;
    // MavericksSupport/source/WebKitLegacy/WebCoreSupport/SocketStreamHandleImplCurl.cpp implements
    // both. CFStream's pair, its PAC source and its CONNECT credentials are commented out below.
    /*
    void createStreams();
    void scheduleStreams();
    void chooseProxy();
    void chooseProxyFromArray(CFArrayRef);
    void executePACFileURL(CFURLRef);
    void removePACRunLoopSource();
    RetainPtr<CFRunLoopSourceRef> m_pacRunLoopSource;
    static void pacExecutionCallback(void* client, CFArrayRef proxyList, CFErrorRef);
    static CFStringRef copyPACExecutionDescription(void*);
    */ // MAVERICKS_BACKPORT: closes the CFStream declarations commented out above.

    void connect();
    void transportDidOpen();
    void transportDidReceiveData(std::span<const uint8_t>);
    void transportDidClose();
    void transportDidFail(int code, const String& description);

    bool shouldUseSSL() const { return m_url.protocolIs("wss"_s); }
    unsigned short port() const;

    /* // MAVERICKS_BACKPORT: opens the CFStream declarations this port replaces, kept for merges.
    void addCONNECTCredentials(CFHTTPMessageRef response);

    static void* retainSocketStreamHandle(void*);
    static void releaseSocketStreamHandle(void*);
    static CFStringRef copyCFStreamDescription(void*);
    static void readStreamCallback(CFReadStreamRef, CFStreamEventType, void*);
    static void writeStreamCallback(CFWriteStreamRef, CFStreamEventType, void*);
    void readStreamCallback(CFStreamEventType);
    void writeStreamCallback(CFStreamEventType);

    void reportErrorToClient(CFErrorRef);

    bool getStoredCONNECTProxyCredentials(const ProtectionSpace&, String& login, String& password);

    enum ConnectingSubstate { New, ExecutingPACFile, WaitingForCredentials, WaitingForConnect, Connected };
    ConnectingSubstate m_connectingSubstate;

    enum ConnectionType { Unknown, Direct, SOCKSProxy, CONNECTProxy };
    ConnectionType m_connectionType;
    RetainPtr<CFStringRef> m_proxyHost;
    RetainPtr<CFNumberRef> m_proxyPort;

    RetainPtr<CFHTTPMessageRef> m_proxyResponseMessage;
    bool m_sentStoredCredentials;
    bool m_shouldAcceptInsecureCertificates;
    RetainPtr<CFReadStreamRef> m_readStream;
    RetainPtr<CFWriteStreamRef> m_writeStream;
    */ // MAVERICKS_BACKPORT: closes the CFStream declarations commented out above.

    bool m_shouldAcceptInsecureCertificates; // MAVERICKS_BACKPORT: also declared in the block above, which this port replaces.
    RefPtr<SocketStreamCurlTransport> m_transport; // MAVERICKS_BACKPORT: owns the connection; see the note above.

    RetainPtr<CFURLRef> m_httpsURL; // ws(s): replaced with https:
    String m_credentialPartition;
    SourceApplicationAuditToken m_auditData;
    RefPtr<const StorageSessionProvider> m_storageSessionProvider;

    StreamBuffer<uint8_t, 1024 * 1024> m_buffer;
    static const unsigned maxBufferSize = 100 * 1024 * 1024;
};

} // namespace WebCore
