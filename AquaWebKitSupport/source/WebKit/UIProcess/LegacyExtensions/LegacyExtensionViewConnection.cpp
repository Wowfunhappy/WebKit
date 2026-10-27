#include "config.h"
#include "LegacyExtensionViewConnection.h"

#include "Decoder.h"
#include "HandleMessage.h"
#include "NetworkBroadcastChannelRegistryMessages.h"
#include "NetworkConnectionToWebProcessMessages.h"
#include "NetworkProcessConnectionMessages.h"
#include "NetworkProcessConnectionParameters.h"
#include "NetworkProcessMessages.h"
#include "NetworkProcessProxy.h"
#include "SharedPreferencesForWebProcess.h"
#include "WebBroadcastChannelRegistryMessages.h"
#include "WebLegacyExtensionPageObserver.h"
#include "WebPreferencesStore.h"
#include "WebSharedWorkerObjectConnectionMessages.h"
#include "WebSharedWorkerServerConnectionMessages.h"
#include "WebsiteDataStore.h"
#include <WebCore/BroadcastChannel.h>
#include <WebCore/BroadcastChannelRegistry.h>
#include <WebCore/ClientOrigin.h>
#include <WebCore/MessagePort.h>
#include <WebCore/MessagePortChannelProvider.h>
#include <WebCore/MessageWithMessagePorts.h>
#include <WebCore/NonSerializedDataToken.h>
#include <WebCore/PartitionedSecurityOrigin.h>
#include <WebCore/ProcessIdentifier.h>
#include <WebCore/ResourceError.h>
#include <WebCore/SerializedScriptValue.h>
#include <WebCore/SharedWorkerKey.h>
#include <WebCore/SharedWorkerObjectConnection.h>
#include <WebCore/SharedWorkerProvider.h>
#include <WebCore/WebLockRegistry.h>
#include <WebCore/WorkerFetchResult.h>
#include <WebCore/WorkerInitializationData.h>
#include <WebCore/WorkerOptions.h>
#include <wtf/CallbackAggregator.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/RunLoop.h>

namespace WebKit {

using namespace WebCore;

static Ref<WebsiteDataStore> sessionDataStore()
{
    if (RefPtr dataStore = WebsiteDataStore::existingDataStoreForSessionID(PAL::SessionID::defaultSessionID()))
        return dataStore.releaseNonNull();
    return WebsiteDataStore::defaultDataStore();
}

// The message ports of this process's WebKit 1 views, held by the network process as a web process's are.
class LegacyExtensionViewMessagePorts final : public MessagePortChannelProvider {
public:
    static LegacyExtensionViewMessagePorts& singleton()
    {
        static NeverDestroyed<LegacyExtensionViewMessagePorts> provider;
        return provider;
    }

    void ref() const { }
    void deref() const { }

    void messagePortSentToRemote(const MessagePortIdentifier& port)
    {
        auto inProcessPortMessages = m_inProcessPortMessages.take(port);
        for (auto& message : inProcessPortMessages)
            postMessageToRemote(WTF::move(message), port);
    }

    void messagesAvailableForPort(const MessagePortIdentifier& port)
    {
        MessagePort::notifyMessageAvailable(port);
    }

    void dropNonSerializableInProcessCache(NonSerializedDataIdentifier identifier)
    {
        m_nonSerializedDataRegistry.remove(identifier);
    }

    void connectionClosed()
    {
        m_inProcessPortMessages.clear();
        m_portsKnownToNetworkProcess.clear();
        MessagePort::notifyAllConnectionsClosed();
    }

private:
    friend class NeverDestroyed<LegacyExtensionViewMessagePorts>;
    LegacyExtensionViewMessagePorts() = default;

    void createNewMessagePortChannel(const MessagePortIdentifier& port1, const MessagePortIdentifier& port2) final
    {
        m_inProcessPortMessages.add(port1, Vector<MessageWithMessagePorts> { });
        m_inProcessPortMessages.add(port2, Vector<MessageWithMessagePorts> { });
        m_portsKnownToNetworkProcess.add(port1);
        m_portsKnownToNetworkProcess.add(port2);
        LegacyExtensionViewConnection::singleton().send(Messages::NetworkConnectionToWebProcess::CreateNewMessagePortChannel { port1, port2 });
    }

    void entangleLocalPortInThisProcessToRemote(const MessagePortIdentifier& local, const MessagePortIdentifier& remote) final
    {
        m_inProcessPortMessages.add(local, Vector<MessageWithMessagePorts> { });
        m_portsKnownToNetworkProcess.add(local);
        LegacyExtensionViewConnection::singleton().send(Messages::NetworkConnectionToWebProcess::EntangleLocalPortInThisProcessToRemote { local, remote });
    }

    void messagePortDisentangled(const MessagePortIdentifier& port) final
    {
        m_portsKnownToNetworkProcess.remove(port);
        LegacyExtensionViewConnection::singleton().send(Messages::NetworkConnectionToWebProcess::MessagePortDisentangled { port });
    }

    void messagePortClosed(const MessagePortIdentifier& port) final
    {
        m_inProcessPortMessages.remove(port);
        if (!m_portsKnownToNetworkProcess.remove(port))
            return;
        LegacyExtensionViewConnection::singleton().send(Messages::NetworkConnectionToWebProcess::MessagePortClosed { port });
    }

    void takeAllMessagesForPort(const MessagePortIdentifier& port, CompletionHandler<void(Vector<MessageWithMessagePorts>&&, CompletionHandler<void()>&&)>&& completionHandler) final
    {
        if (!m_portsKnownToNetworkProcess.contains(port))
            return completionHandler({ }, [] { });

        LegacyExtensionViewConnection::singleton().sendWithAsyncReply(Messages::NetworkConnectionToWebProcess::TakeAllMessagesForPort { port }, [completionHandler = WTF::move(completionHandler), port](Vector<MessageWithMessagePorts>&& messages, std::optional<MessageBatchIdentifier> messageBatchIdentifier) mutable {
            if (!messageBatchIdentifier)
                return completionHandler({ }, [] { });

            auto& provider = LegacyExtensionViewMessagePorts::singleton();
            for (auto& message : messages) {
                auto& serializedScriptValue = message.message;
                if (!serializedScriptValue)
                    continue;
                if (auto token = serializedScriptValue->nonSerializedDataToken()) {
                    if (token->processIdentifier == Process::identifier())
                        serializedScriptValue->sharedBufferContentsArray() = provider.m_nonSerializedDataRegistry.take(token->identifier);
                    else
                        LegacyExtensionViewConnection::singleton().send(Messages::NetworkConnectionToWebProcess::DropNonSerializableInProcessCache { token->processIdentifier, token->identifier });
                    serializedScriptValue->setNonSerializedDataToken(std::nullopt);
                }
            }

            auto iterator = provider.m_inProcessPortMessages.find(port);
            if (iterator != provider.m_inProcessPortMessages.end())
                messages.appendVector(std::exchange(iterator->value, { }));
            completionHandler(WTF::move(messages), [messageBatchIdentifier] {
                LegacyExtensionViewConnection::singleton().send(Messages::NetworkConnectionToWebProcess::DidDeliverMessagePortMessages { *messageBatchIdentifier });
            });
        });
    }

    void postMessageToRemote(MessageWithMessagePorts&& message, const MessagePortIdentifier& remoteTarget) final
    {
        auto iterator = m_inProcessPortMessages.find(remoteTarget);
        if (iterator != m_inProcessPortMessages.end()) {
            iterator->value.append(WTF::move(message));
            MessagePort::notifyMessageAvailable(remoteTarget);
            return;
        }

        for (auto& port : message.transferredPorts)
            messagePortSentToRemote(port.first);

        Vector<URL> blobURLs;
        if (auto& serializedScriptValue = message.message) {
            blobURLs = serializedScriptValue->blobURLs().map([](auto& blobURL) {
                return URL { blobURL };
            });
            if (serializedScriptValue->sharedBufferContentsArray() && !serializedScriptValue->sharedBufferContentsArray()->isEmpty()) {
                auto identifier = NonSerializedDataIdentifier::generate();
                m_nonSerializedDataRegistry.add(identifier, std::exchange(serializedScriptValue->sharedBufferContentsArray(), nullptr));
                serializedScriptValue->setNonSerializedDataToken(SerializedScriptValue::NonSerializedDataToken { Process::identifier(), identifier });
            }
        }

        LegacyExtensionViewConnection::singleton().send(Messages::NetworkConnectionToWebProcess::PostMessageToRemote { message, remoteTarget, blobURLs });
    }

    HashMap<MessagePortIdentifier, Vector<MessageWithMessagePorts>> m_inProcessPortMessages;
    HashMap<NonSerializedDataIdentifier, std::unique_ptr<Vector<JSC::ArrayBufferContents>>> m_nonSerializedDataRegistry;
    HashSet<MessagePortIdentifier> m_portsKnownToNetworkProcess;
};

// The default session's BroadcastChannels, which a channel of this process reaches through the network process
// as a web process's does. A channel of an opaque origin reaches the channels of this process alone.
class LegacyExtensionViewBroadcastChannels final : public BroadcastChannelRegistry {
public:
    static LegacyExtensionViewBroadcastChannels& singleton()
    {
        static NeverDestroyed<Ref<LegacyExtensionViewBroadcastChannels>> registry = adoptRef(*new LegacyExtensionViewBroadcastChannels);
        return registry.get();
    }

    void postMessageToRemote(const ClientOrigin& clientOrigin, const String& name, MessageWithMessagePorts&& message, CompletionHandler<void()>&& completionHandler)
    {
        auto callbackAggregator = CallbackAggregator::create(WTF::move(completionHandler));
        PartitionedSecurityOrigin origin { clientOrigin.topOrigin.securityOrigin(), clientOrigin.clientOrigin.securityOrigin() };
        postMessageLocally(origin, name, std::nullopt, *message.message, WTF::move(callbackAggregator));
    }

    void registerChannelsWithNetworkProcess()
    {
        for (auto& [origin, channelsForOrigin] : m_channelsPerOrigin) {
            if (auto clientOrigin = toClientOrigin(origin)) {
                for (auto& name : channelsForOrigin.keys())
                    LegacyExtensionViewConnection::singleton().send(Messages::NetworkBroadcastChannelRegistry::RegisterChannel { *clientOrigin, name });
            }
        }
    }

private:
    LegacyExtensionViewBroadcastChannels() = default;

    static std::optional<ClientOrigin> toClientOrigin(const PartitionedSecurityOrigin& origin)
    {
        if (origin.topOrigin->isOpaque() || origin.clientOrigin->isOpaque())
            return std::nullopt;
        return ClientOrigin { origin.topOrigin->data(), origin.clientOrigin->data() };
    }

    void registerChannel(const PartitionedSecurityOrigin& origin, const String& name, BroadcastChannelIdentifier identifier) final
    {
        auto& channelsForOrigin = m_channelsPerOrigin.ensure(origin, [] { return HashMap<String, Vector<BroadcastChannelIdentifier>> { }; }).iterator->value;
        auto& channelsForName = channelsForOrigin.ensure(name, [] { return Vector<BroadcastChannelIdentifier> { }; }).iterator->value;
        channelsForName.append(identifier);
        if (channelsForName.size() == 1) {
            if (auto clientOrigin = toClientOrigin(origin))
                LegacyExtensionViewConnection::singleton().send(Messages::NetworkBroadcastChannelRegistry::RegisterChannel { *clientOrigin, name });
        }
    }

    void unregisterChannel(const PartitionedSecurityOrigin& origin, const String& name, BroadcastChannelIdentifier identifier) final
    {
        auto channelsPerOriginIterator = m_channelsPerOrigin.find(origin);
        if (channelsPerOriginIterator == m_channelsPerOrigin.end())
            return;
        auto& channelsForOrigin = channelsPerOriginIterator->value;
        auto channelsForNameIterator = channelsForOrigin.find(name);
        if (channelsForNameIterator == channelsForOrigin.end())
            return;
        if (!channelsForNameIterator->value.removeFirst(identifier) || !channelsForNameIterator->value.isEmpty())
            return;

        channelsForOrigin.remove(channelsForNameIterator);
        if (auto clientOrigin = toClientOrigin(origin))
            LegacyExtensionViewConnection::singleton().send(Messages::NetworkBroadcastChannelRegistry::UnregisterChannel { *clientOrigin, name });
        if (channelsForOrigin.isEmpty())
            m_channelsPerOrigin.remove(channelsPerOriginIterator);
    }

    void postMessage(const PartitionedSecurityOrigin& origin, const String& name, BroadcastChannelIdentifier source, Ref<SerializedScriptValue>&& message, CompletionHandler<void()>&& completionHandler) final
    {
        auto callbackAggregator = CallbackAggregator::create(WTF::move(completionHandler));
        auto blobURLs = message->blobURLs().map([](auto& blobURL) {
            return URL { blobURL };
        });
        // The IPC goes first: postMessageLocally() consumes the SerializedScriptValue, possibly on another thread.
        if (auto clientOrigin = toClientOrigin(origin))
            LegacyExtensionViewConnection::singleton().sendWithAsyncReply(Messages::NetworkBroadcastChannelRegistry::PostMessage { *clientOrigin, name, MessageWithMessagePorts { message.copyRef(), { } }, WTF::move(blobURLs) }, [callbackAggregator] { });
        postMessageLocally(origin, name, source, WTF::move(message), WTF::move(callbackAggregator));
    }

    void postMessageLocally(const PartitionedSecurityOrigin& origin, const String& name, std::optional<BroadcastChannelIdentifier> sourceInProcess, Ref<SerializedScriptValue>&& message, Ref<CallbackAggregator>&& callbackAggregator)
    {
        auto channelsPerOriginIterator = m_channelsPerOrigin.find(origin);
        if (channelsPerOriginIterator == m_channelsPerOrigin.end())
            return;
        auto channelsForNameIterator = channelsPerOriginIterator->value.find(name);
        if (channelsForNameIterator == channelsPerOriginIterator->value.end())
            return;

        auto channelIdentifiers = channelsForNameIterator->value;
        size_t numberOfMessagesNeeded = channelIdentifiers.size();
        for (auto& channelIdentifier : channelIdentifiers) {
            if (channelIdentifier == sourceInProcess)
                --numberOfMessagesNeeded;
        }
        for (auto& channelIdentifier : channelIdentifiers) {
            if (channelIdentifier == sourceInProcess)
                continue;
            auto messageToDispatch = numberOfMessagesNeeded-- > 1 ? message->clone() : WTF::move(message);
            BroadcastChannel::dispatchMessageTo(channelIdentifier, WTF::move(messageToDispatch), [callbackAggregator] { });
        }
    }

    HashMap<PartitionedSecurityOrigin, HashMap<String, Vector<BroadcastChannelIdentifier>>> m_channelsPerOrigin;
};

// The shared workers of this process's WebKit 1 views, run by the network process's shared worker server as a web
// process's are.
class LegacyExtensionViewSharedWorkers final : public SharedWorkerObjectConnection, public SharedWorkerProvider {
public:
    static LegacyExtensionViewSharedWorkers& singleton()
    {
        static NeverDestroyed<Ref<LegacyExtensionViewSharedWorkers>> connection = adoptRef(*new LegacyExtensionViewSharedWorkers);
        return connection.get();
    }

    void didReceiveMessage(IPC::Connection& connection, IPC::Decoder& decoder)
    {
        if (decoder.messageName() == Messages::WebSharedWorkerObjectConnection::FetchScriptInClient::name())
            IPC::handleMessageAsync<Messages::WebSharedWorkerObjectConnection::FetchScriptInClient>(connection, decoder, this, &LegacyExtensionViewSharedWorkers::fetchScriptInClient);
        else if (decoder.messageName() == Messages::WebSharedWorkerObjectConnection::NotifyWorkerObjectOfLoadCompletion::name())
            IPC::handleMessage<Messages::WebSharedWorkerObjectConnection::NotifyWorkerObjectOfLoadCompletion>(connection, decoder, this, &LegacyExtensionViewSharedWorkers::notifyWorkerObjectOfLoadCompletion);
        else if (decoder.messageName() == Messages::WebSharedWorkerObjectConnection::PostErrorToWorkerObject::name())
            IPC::handleMessage<Messages::WebSharedWorkerObjectConnection::PostErrorToWorkerObject>(connection, decoder, this, &LegacyExtensionViewSharedWorkers::postErrorToWorkerObject);
        else if (decoder.messageName() == Messages::WebSharedWorkerObjectConnection::ReportNetworkUsageToWorkerObject::name())
            IPC::handleMessage<Messages::WebSharedWorkerObjectConnection::ReportNetworkUsageToWorkerObject>(connection, decoder, this, &LegacyExtensionViewSharedWorkers::reportNetworkUsageToWorkerObject);
    }

private:
    LegacyExtensionViewSharedWorkers() = default;

    // The server takes a shared worker request from a process whose documents have the worker's top origin as a
    // first party.
    static Site firstParty(const SharedWorkerKey& key)
    {
        return Site { key.origin.topOrigin };
    }

    SharedWorkerObjectConnection* sharedWorkerConnection() final { return this; }

    void requestSharedWorker(const SharedWorkerKey& key, SharedWorkerObjectIdentifier identifier, TransferredMessagePort&& port, const WorkerOptions& options) final
    {
        LegacyExtensionViewMessagePorts::singleton().messagePortSentToRemote(port.first);
        LegacyExtensionViewConnection::singleton().whenFirstPartyAllowed(firstParty(key), [key, identifier, port = WTF::move(port), options]() mutable {
            LegacyExtensionViewConnection::singleton().send(Messages::WebSharedWorkerServerConnection::RequestSharedWorker { key, identifier, WTF::move(port), options });
        });
    }

    void sharedWorkerObjectIsGoingAway(const SharedWorkerKey& key, SharedWorkerObjectIdentifier identifier) final
    {
        LegacyExtensionViewConnection::singleton().whenFirstPartyAllowed(firstParty(key), [key, identifier] {
            LegacyExtensionViewConnection::singleton().send(Messages::WebSharedWorkerServerConnection::SharedWorkerObjectIsGoingAway { key, identifier });
        });
    }

    void suspendForBackForwardCache(const SharedWorkerKey& key, SharedWorkerObjectIdentifier identifier) final
    {
        LegacyExtensionViewConnection::singleton().whenFirstPartyAllowed(firstParty(key), [key, identifier] {
            LegacyExtensionViewConnection::singleton().send(Messages::WebSharedWorkerServerConnection::SuspendForBackForwardCache { key, identifier });
        });
    }

    void resumeForBackForwardCache(const SharedWorkerKey& key, SharedWorkerObjectIdentifier identifier) final
    {
        LegacyExtensionViewConnection::singleton().whenFirstPartyAllowed(firstParty(key), [key, identifier] {
            LegacyExtensionViewConnection::singleton().send(Messages::WebSharedWorkerServerConnection::ResumeForBackForwardCache { key, identifier });
        });
    }
};

LegacyExtensionViewConnection& LegacyExtensionViewConnection::singleton()
{
    static NeverDestroyed<LegacyExtensionViewConnection> connection;
    return connection;
}

void LegacyExtensionViewConnection::install()
{
    MessagePortChannelProvider::setSharedProvider(LegacyExtensionViewMessagePorts::singleton());
    SharedWorkerProvider::setSharedProvider(LegacyExtensionViewSharedWorkers::singleton());
    WebLockRegistry::setSharedRegistry(sessionDataStore()->webLockRegistry());
    WebSetLegacyExtensionBroadcastChannelRegistry(LegacyExtensionViewBroadcastChannels::singleton());
}

// A message holds references to its arguments, so one waiting for the connection waits encoded, as
// AuxiliaryProcessProxy's do.
template<typename Message> void LegacyExtensionViewConnection::send(Message&& message)
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

template<typename Message, typename CompletionHandler> void LegacyExtensionViewConnection::sendWithAsyncReply(Message&& message, CompletionHandler&& completionHandler)
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

void LegacyExtensionViewConnection::whenFirstPartyAllowed(const Site& site, Function<void()>&& sendMessages)
{
    if (m_allowedFirstParties.contains(site))
        return sendMessages();
    auto addResult = m_messagesAwaitingFirstParty.add(site, Vector<Function<void()>> { });
    addResult.iterator->value.append(WTF::move(sendMessages));
    if (!addResult.isNewEntry)
        return;
    // The network process takes the first party on its connection to this process, which a message on this
    // connection does not overtake: the waiting messages go once it replies.
    sessionDataStore()->networkProcess().sendWithAsyncReply(Messages::NetworkProcess::AddAllowedFirstPartyForCookies { Process::identifier(), site, LoadedWebArchive::No }, [site, generation = m_connectionGeneration] {
        auto& connection = LegacyExtensionViewConnection::singleton();
        if (connection.m_connectionGeneration != generation)
            return;
        connection.m_allowedFirstParties.add(site);
        for (auto& sendMessages : connection.m_messagesAwaitingFirstParty.take(site))
            sendMessages();
    });
}

// As WebsiteDataStore::getNetworkProcessConnection does for a web process, a request the network process fails is
// tried once more on the next run loop iteration, with a new network process if the failed one is still the session's.
void LegacyExtensionViewConnection::connect(ShouldRetryOnFailure shouldRetryOnFailure)
{
    if (m_isConnecting)
        return;
    m_isConnecting = true;
    Ref dataStore = sessionDataStore();
    Ref networkProcess = dataStore->networkProcess();
    NetworkProcessConnectionParameters parameters;
    parameters.sharedPreferencesForWebProcess = sharedPreferencesForWebProcess(WebPreferencesStore { }, false);
    networkProcess->sendWithAsyncReply(Messages::NetworkProcess::CreateNetworkConnectionToWebProcess { Process::identifier(), dataStore->sessionID(), parameters }, [weakNetworkProcess = WeakPtr { networkProcess.get() }, shouldRetryOnFailure](std::optional<IPC::Connection::Handle>&& handle, auto) mutable {
        LegacyExtensionViewConnection::singleton().didConnect(WTF::move(handle), WTF::move(weakNetworkProcess), shouldRetryOnFailure);
    });
}

void LegacyExtensionViewConnection::didConnect(std::optional<IPC::Connection::Handle>&& handle, WeakPtr<NetworkProcessProxy>&& networkProcess, ShouldRetryOnFailure shouldRetryOnFailure)
{
    m_isConnecting = false;
    if (!handle) {
        if (shouldRetryOnFailure == ShouldRetryOnFailure::Yes) {
            RunLoop::mainSingleton().dispatch([networkProcess = WTF::move(networkProcess)] {
                Ref dataStore = sessionDataStore();
                if (networkProcess && dataStore->networkProcessIfExists() == networkProcess.get())
                    dataStore->terminateNetworkProcess();
                LegacyExtensionViewConnection::singleton().connect(ShouldRetryOnFailure::No);
            });
            return;
        }
        // Each waiting reply handler is called without a reply, as in AuxiliaryProcessProxy::replyToPendingMessages.
        for (auto& message : std::exchange(m_pendingMessages, { })) {
            if (message.asyncReplyHandler && message.asyncReplyHandler->completionHandler)
                message.asyncReplyHandler->completionHandler(nullptr, nullptr);
        }
        LegacyExtensionViewMessagePorts::singleton().connectionClosed();
        return;
    }
    Ref connection = IPC::Connection::createClientConnection(IPC::Connection::Identifier { WTF::move(*handle) });
    m_connection = connection.copyRef();
    connection->open(*this);
    if (std::exchange(m_needsChannelRegistration, false))
        LegacyExtensionViewBroadcastChannels::singleton().registerChannelsWithNetworkProcess();
    for (auto& message : std::exchange(m_pendingMessages, { })) {
        if (message.asyncReplyHandler)
            connection->sendMessageWithAsyncReply(WTF::move(message.encoder), WTF::move(*message.asyncReplyHandler), { });
        else
            connection->sendMessage(WTF::move(message.encoder), { });
    }
}

void LegacyExtensionViewConnection::didReceiveMessage(IPC::Connection& connection, IPC::Decoder& decoder)
{
    if (decoder.messageReceiverName() == Messages::NetworkProcessConnection::messageReceiverName()) {
        auto& ports = LegacyExtensionViewMessagePorts::singleton();
        if (decoder.messageName() == Messages::NetworkProcessConnection::MessagesAvailableForPort::name())
            IPC::handleMessage<Messages::NetworkProcessConnection::MessagesAvailableForPort>(connection, decoder, &ports, &LegacyExtensionViewMessagePorts::messagesAvailableForPort);
        else if (decoder.messageName() == Messages::NetworkProcessConnection::DropNonSerializableInProcessCache::name())
            IPC::handleMessage<Messages::NetworkProcessConnection::DropNonSerializableInProcessCache>(connection, decoder, &ports, &LegacyExtensionViewMessagePorts::dropNonSerializableInProcessCache);
        return;
    }
    if (decoder.messageReceiverName() == Messages::WebBroadcastChannelRegistry::messageReceiverName()) {
        if (decoder.messageName() == Messages::WebBroadcastChannelRegistry::PostMessageToRemote::name())
            IPC::handleMessageAsync<Messages::WebBroadcastChannelRegistry::PostMessageToRemote>(connection, decoder, &LegacyExtensionViewBroadcastChannels::singleton(), &LegacyExtensionViewBroadcastChannels::postMessageToRemote);
        return;
    }
    if (decoder.messageReceiverName() == Messages::WebSharedWorkerObjectConnection::messageReceiverName())
        LegacyExtensionViewSharedWorkers::singleton().didReceiveMessage(connection, decoder);
}

// A network process that goes away takes this process's ports with it, as a web process's; this process connects
// again, as a web process's BroadcastChannels do (WebBroadcastChannelRegistry::networkProcessCrashed), and its
// channels register on the new connection.
void LegacyExtensionViewConnection::didClose(IPC::Connection& connection)
{
    if (m_connection != &connection)
        return;
    connection.invalidate();
    m_connection = nullptr;
    ++m_connectionGeneration;
    m_allowedFirstParties.clear();
    m_messagesAwaitingFirstParty.clear();
    LegacyExtensionViewMessagePorts::singleton().connectionClosed();
    m_needsChannelRegistration = true;
    connect();
}

} // namespace WebKit
