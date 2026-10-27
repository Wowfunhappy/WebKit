// Safari 7 hosts an extension's global page, popovers and bars in WebKit 1 views in its own process, and the
// extension's other pages in WebKit 2 web processes. The WebKit 1 views of this process take part in the default
// session's BroadcastChannels, message ports and shared workers as a web process does, over a network process
// connection of their own, and use the session's Web Locks, so that all of an extension's pages share them.

#pragma once

#include "Connection.h"
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

    // Makes this process's WebKit 1 views use the session's services. Runs before any WebKit 1 view has run script.
    void install();

    template<typename Message> void send(Message&&);
    template<typename Message, typename CompletionHandler> void sendWithAsyncReply(Message&&, CompletionHandler&&);
    // Runs `sendMessages` once the network process takes `domain` as a first party of this process's documents.
    void whenFirstPartyAllowed(const WebCore::Site&, Function<void()>&& sendMessages);

    void ref() const { }
    void deref() const { }

private:
    friend class NeverDestroyed<LegacyExtensionViewConnection>;
    LegacyExtensionViewConnection() = default;

    enum class ShouldRetryOnFailure : bool { No, Yes };
    void connect(ShouldRetryOnFailure = ShouldRetryOnFailure::Yes);
    void didConnect(std::optional<IPC::Connection::Handle>&&, WeakPtr<NetworkProcessProxy>&&, ShouldRetryOnFailure);

    void didReceiveMessage(IPC::Connection&, IPC::Decoder&) final;
    void didClose(IPC::Connection&) final;
    void didReceiveInvalidMessage(IPC::Connection&, IPC::MessageName, const Vector<uint32_t>&) final { }

    RefPtr<IPC::Connection> m_connection;
    bool m_isConnecting { false };
    bool m_needsChannelRegistration { false };
    uint64_t m_connectionGeneration { 0 };
    Vector<Function<void(IPC::Connection&)>> m_pendingMessages;
    HashSet<WebCore::Site> m_allowedFirstParties;
    HashMap<WebCore::Site, Vector<Function<void()>>> m_messagesAwaitingFirstParty;
};

} // namespace WebKit
