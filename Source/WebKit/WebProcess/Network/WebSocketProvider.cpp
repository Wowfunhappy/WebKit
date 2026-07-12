/*
 * Copyright (C) 2009, 2012 Google Inc. All rights reserved.
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

#include "config.h"
#include "WebSocketProvider.h"

#include "NetworkProcessConnection.h"
#include "WebProcess.h"
#include "WebSocketChannelManager.h"
#include "WebTransportSession.h"
#include <WebCore/DocumentInlines.h>
#include <WebCore/WebTransportSessionClient.h>
#include <WebCore/WorkerGlobalScope.h>
#include <WebCore/WorkerWebTransportSession.h>

#if USE(LIBRICE)
#include "RiceBackendProxy.h"
#endif

namespace WebKit {
using namespace WebCore;

RefPtr<ThreadableWebSocketChannel> WebSocketProvider::createWebSocketChannel(Document& document, WebSocketChannelClient& client)
{
    return WebKit::WebSocketChannel::create(m_webPageProxyID, document, client);
}

WebSocketProvider::~WebSocketProvider() = default;

WebSocketProvider::WebSocketProvider(WebPageProxyIdentifier webPageProxyID)
// MAVERICKS_BACKPORT: defer acquiring the NetworkProcess connection (m_networkProcessConnection stays null here) instead of eagerly ensuring it in the constructor; it is fetched lazily on first WebTransport use, avoiding a too-early connection bring-up on 10.9.
    : m_webPageProxyID(webPageProxyID) { }

std::pair<RefPtr<WebCore::WebTransportSession>, Ref<WebTransportSessionPromise>> WebSocketProvider::initializeWebTransportSession(ScriptExecutionContext& context, WebTransportSessionClient& client, const URL& url, const WebCore::WebTransportOptions& options)
{
    if (RefPtr scope = dynamicDowncast<WorkerGlobalScope>(context)) {
        ASSERT(!RunLoop::isMain());
        Ref workerSession = WorkerWebTransportSession::create(context.identifier(), client);

        // MAVERICKS_BACKPORT: because m_networkProcessConnection is a nullable RefPtr that starts null (see constructor), getConnection returns RefPtr and the validity check tolerates null; on null/invalid we lazily establish it on the main thread, then releaseNonNull() once known good.
        auto getConnection = [protectedThis = Ref { *this }]() -> RefPtr<IPC::Connection> {
            Locker locker { protectedThis->m_networkProcessConnectionLock };
            return protectedThis->m_networkProcessConnection;
        };
        // MAVERICKS_BACKPORT: connection is a nullable RefPtr that may start null, so guard for null before checking isValid().
        RefPtr connection = getConnection();
        if (!connection || !connection->isValid()) {
            WorkQueue::mainSingleton().dispatchSync([protectedThis = Ref { *this }] {
                ASSERT(RunLoop::isMain());
                Locker locker { protectedThis->m_networkProcessConnectionLock };
                // MAVERICKS_BACKPORT: lazily establish the connection on the main thread (m_networkProcessConnection is a nullable RefPtr), taking its address since it is now a pointer member.
                protectedThis->m_networkProcessConnection = &WebProcess::singleton().ensureNetworkProcessConnection().connection();
            });
            connection = getConnection();
        }

        // MAVERICKS_BACKPORT: connection is now a (lazily-acquired) RefPtr, so releaseNonNull() once it is known-good.
        auto [session, promise] = WebKit::WebTransportSession::initialize(connection.releaseNonNull(), workerSession, url, options, m_webPageProxyID, scope->clientOrigin());
        workerSession->attachSession(session);
        return { WTF::move(workerSession), WTF::move(promise) };
    }

    Ref document = downcast<Document>(context);
    ASSERT(RunLoop::isMain());
    auto [session, promise] = WebKit::WebTransportSession::initialize(WebProcess::singleton().ensureNetworkProcessConnection().connection(), client, url, options, m_webPageProxyID, document->clientOrigin());
    return { WTF::move(session), WTF::move(promise) };
}

#if USE(LIBRICE)
RefPtr<WebCore::RiceBackend> WebSocketProvider::createRiceBackend(WebCore::RiceBackendClient& client)
{
    return WebKit::RiceBackendProxy::create(m_webPageProxyID, client);
}
#endif

} // namespace WebKit
