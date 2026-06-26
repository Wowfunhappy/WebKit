// MAVERICKS_BACKPORT: WebTransport requires Network.framework features (nw_connection_group_t)
// from 10.14+. Provide minimal stubs so NetworkConnectionToWebProcess::initializeWebTransportSession
// links cleanly. WebTransport unsupported in this build — initialize calls back nullopt and create
// returns nullptr; NetworkConnectionToWebProcess handles those cases.

// MAVERICKS_BACKPORT: stub translation unit replaces the Network.framework implementation.
#include "config.h"
#include "NetworkTransportSession.h"

// MAVERICKS_BACKPORT: only the connection-info / completion-handler headers are needed for the stubs.
#include <WebCore/WebTransportConnectionInfo.h>
#include <wtf/CompletionHandler.h>

namespace WebKit {

// MAVERICKS_BACKPORT: WebTransport unsupported on 10.9; create returns nullptr.
RefPtr<NetworkTransportSession> NetworkTransportSession::create(NetworkConnectionToWebProcess&, WebTransportSessionIdentifier, URL&&, WebCore::WebTransportOptions&&, WebKit::WebPageProxyIdentifier&&, WebCore::ClientOrigin&&)
{
    return nullptr;
}

// MAVERICKS_BACKPORT: WebTransport unsupported on 10.9; initialize calls back nullopt.
void NetworkTransportSession::initialize(CompletionHandler<void(std::optional<WebCore::WebTransportConnectionInfo>&&)>&& completionHandler)
{
    completionHandler(std::nullopt);
}

}
