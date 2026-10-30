#pragma once

namespace WebCore {

class ResourceResponse;
class SocketStreamHandle;

// WebSocketChannel reports its validation of the server handshake, which completes the handle's webRequest exchange.
void legacyWebSocketHandshakeDidValidate(SocketStreamHandle&, const ResourceResponse&, bool connected);

} // namespace WebCore
