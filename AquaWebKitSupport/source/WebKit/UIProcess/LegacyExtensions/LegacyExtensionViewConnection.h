// Safari 7 hosts an extension's global page, popovers and bars in WebKit 1 views in its own process, and the
// extension's other pages in WebKit 2 web processes. The WebKit 1 views of this process take part in the default
// session's storage, BroadcastChannels, message ports and shared workers as a web process does, over a network process
// connection of their own, and use the session's Web Locks, so that all of an extension's pages share them.

#pragma once

#include "Connection.h"
#include "Encoder.h"
#include <WebCore/Site.h>
#include <wtf/Function.h>
#include <wtf/HashMap.h>
#include <wtf/HashSet.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/WeakPtr.h>

namespace WebKit {

class NetworkProcessProxy;

class LegacyExtensionViewConnection final : public IPC::Connection::Client {
public:
    static LegacyExtensionViewConnection& singleton();

    // Installs the default session's services for Safari's WebKit 1 extension views.
    void install();

    template<typename Message> void send(Message&&);
    template<typename Message, typename CompletionHandler> void sendWithAsyncReply(Message&&, CompletionHandler&&);
    template<typename Message> void sendForOrigin(Message&&, const WebCore::Site&);
    RefPtr<IPC::Connection> connection(const WebCore::Site& site) const { return m_allowedFirstParties.contains(site) ? m_connection : nullptr; }
    void allowFilesAccess(const Vector<String>&, CompletionHandler<void()>&&);
    void sendEncoded(UniqueRef<IPC::Encoder>&&);
    // Reports readiness after the network process accepts the site, or failure when the connection is lost.
    void whenFirstPartyAllowed(const WebCore::Site&, Function<void(bool)>&&);

    void ref() const { }
    void deref() const { }

private:
    friend class NeverDestroyed<LegacyExtensionViewConnection>;
    LegacyExtensionViewConnection() = default;

    enum class ShouldRetryOnFailure : bool { No, Yes };
    void connect(ShouldRetryOnFailure = ShouldRetryOnFailure::Yes);
    void didConnect(std::optional<IPC::Connection::Handle>&&, WeakPtr<NetworkProcessProxy>&&, ShouldRetryOnFailure);
    void allowFirstParty(const WebCore::Site&);

    void didReceiveMessage(IPC::Connection&, IPC::Decoder&) final;
    void didClose(IPC::Connection&) final;
    void didReceiveInvalidMessage(IPC::Connection&, IPC::MessageName, const Vector<uint32_t>&) final { }

    RefPtr<IPC::Connection> m_connection;
    bool m_isConnecting { false };
    bool m_needsChannelRegistration { false };
    uint64_t m_connectionGeneration { 0 };
    // Messages waiting for the connection, as AuxiliaryProcessProxy keeps them.
    struct PendingMessage {
        UniqueRef<IPC::Encoder> encoder;
        std::optional<IPC::Connection::AsyncReplyHandler> asyncReplyHandler;
    };
    Vector<PendingMessage> m_pendingMessages;
    struct PendingFileAccess {
        Vector<String> paths;
        CompletionHandler<void()> completionHandler;
    };
    Vector<PendingFileAccess> m_pendingFileAccess;
    HashSet<WebCore::Site> m_firstParties;
    HashSet<WebCore::Site> m_allowedFirstParties;
    HashMap<WebCore::Site, Vector<Function<void(bool)>>> m_messagesAwaitingFirstParty;
};

} // namespace WebKit

template<typename Message> void WebKit::LegacyExtensionViewConnection::send(Message&& message)
{
    if (RefPtr connection = m_connection) {
        connection->send(std::forward<Message>(message), 0);
        return;
    }
    auto encoder = makeUniqueRef<IPC::Encoder>(Message::name(), 0);
    message.encode(encoder.get());
    m_pendingMessages.append({ WTF::move(encoder), std::nullopt });
    connect();
}

template<typename Message, typename CompletionHandler> void WebKit::LegacyExtensionViewConnection::sendWithAsyncReply(Message&& message, CompletionHandler&& completionHandler)
{
    if (RefPtr connection = m_connection) {
        connection->sendWithAsyncReply(std::forward<Message>(message), std::forward<CompletionHandler>(completionHandler), 0);
        return;
    }
    auto encoder = makeUniqueRef<IPC::Encoder>(Message::name(), 0);
    message.encode(encoder.get());
    m_pendingMessages.append({ WTF::move(encoder), IPC::Connection::makeAsyncReplyHandler<Message>(std::forward<CompletionHandler>(completionHandler)) });
    connect();
}

template<typename Message> void WebKit::LegacyExtensionViewConnection::sendForOrigin(Message&& message, const WebCore::Site& site)
{
    auto encoder = makeUniqueRef<IPC::Encoder>(Message::name(), 0);
    message.encode(encoder.get());
    whenFirstPartyAllowed(site, [this, encoder = WTF::move(encoder)](bool allowed) mutable {
        if (allowed)
            sendEncoded(WTF::move(encoder));
    });
}
