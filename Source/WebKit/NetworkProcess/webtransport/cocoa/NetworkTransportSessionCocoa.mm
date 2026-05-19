// 10.9 backport: WebTransport requires Network.framework features (nw_connection_group_t)
// from 10.14+. Provide minimal stubs so NetworkConnectionToWebProcess::initializeWebTransportSession
// links cleanly. WebTransport unsupported in this build — initialize calls back nullopt and create
// returns nullptr; NetworkConnectionToWebProcess handles those cases.

#include "config.h"
#include "NetworkTransportSession.h"

#include <WebCore/WebTransportConnectionInfo.h>
#include <wtf/CompletionHandler.h>

namespace WebKit {

RefPtr<NetworkTransportSession> NetworkTransportSession::create(NetworkConnectionToWebProcess&, WebTransportSessionIdentifier, URL&&, WebCore::WebTransportOptions&&, WebKit::WebPageProxyIdentifier&&, WebCore::ClientOrigin&&)
{
    return nullptr;
}

void NetworkTransportSession::initialize(CompletionHandler<void(std::optional<WebCore::WebTransportConnectionInfo>&&)>&& completionHandler)
{
    completionHandler(std::nullopt);
}

}
