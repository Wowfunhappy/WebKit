// The network-process side of webRequest for Safari 7 legacy extensions.
//
// The UI process's router tells every network process which webRequest events extensions listen to and
// the filter of each blocking listener. A load a blocking listener's filter matches waits on the event at
// the same points WebKit applies its own content rules: NetworkLoadChecker::checkRequest (onBeforeRequest
// and onBeforeSendHeaders, for every request and redirect, pings included), checkRedirection and the
// response (onHeadersReceived, for a redirect and for a network or cache response), and a WebSocket's
// creation.
//
// webRequest.filterResponseData attaches StreamFilters to a load: the body its web process would receive goes
// through them first, from the network or the cache alike. The network cache stores the body as the network
// sent it.

#pragma once

#include "LegacyExtensionResponseFilter.h"
#include "LegacyExtensionWebRequest.h"
#include "MessageReceiver.h"
#include "NetworkLoadChecker.h"
#include "NetworkLoadClient.h"
#include "NetworkResourceLoader.h"
#include "WebPageProxyIdentifier.h"
#include <WebCore/WebSocketIdentifier.h>
#include <WebCore/FrameIdentifier.h>
#include <WebCore/NetworkLoadMetrics.h>
#include <WebCore/ResourceLoaderIdentifier.h>
#include <wtf/CompletionHandler.h>
#include <wtf/HashSet.h>
#include <wtf/JSONValues.h>
#include <wtf/Markable.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/WeakHashMap.h>
#include <wtf/WeakHashSet.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringHash.h>

namespace IPC {
class SharedBufferReference;
}

namespace WebCore {
class AuthenticationChallenge;
class FragmentedSharedBuffer;
class ResourceResponse;
struct ClientOrigin;
}

namespace WebKit {

class NetworkConnectionToWebProcess;
class NetworkLoad;
class NetworkDataTaskCurlCocoa;
class NetworkProcess;

namespace NetworkCache {
class Entry;
}

class LegacyExtensionNetwork final : public IPC::MessageReceiver {
public:
    static LegacyExtensionNetwork& singleton();

    void ref() const final { }
    void deref() const final { }

    void initialize(NetworkProcess&);

    void didReceiveMessage(IPC::Connection&, IPC::Decoder&) final;

    // Each returns true when it has taken the load's continuation to wait for the extensions. A request or
    // response resumes by re-entering the same function, which that load's resume entry lets through; a
    // WebSocket's continuation creates its channel.
    bool interceptRequest(NetworkLoadChecker&, WebCore::ResourceRequest&, WebCore::ContentSecurityPolicyClient*, NetworkLoadChecker::ValidationHandler&);
    bool interceptRedirection(NetworkLoadChecker&, WebCore::ResourceRequest&, WebCore::ResourceRequest& redirectRequest, WebCore::ResourceResponse& redirectResponse, WebCore::ContentSecurityPolicyClient*, NetworkLoadChecker::RedirectionValidationHandler&);
    bool interceptResponse(NetworkResourceLoader&, WebCore::ResourceResponse&, PrivateRelayed, ResponseCompletionHandler&);
    bool interceptCachedResponse(NetworkResourceLoader&, std::unique_ptr<NetworkCache::Entry>&);
    bool interceptWebSocket(NetworkConnectionToWebProcess&, const WebCore::ResourceRequest&, WebCore::WebSocketIdentifier, WebPageProxyIdentifier, std::optional<WebCore::FrameIdentifier>, const WebCore::ClientOrigin&, Function<void()>&& createChannel);
    // A WebSocket waiting on the extensions has no channel yet: the web process closing it cancels the
    // wait, and its other channel messages have nothing to act on.
    bool didReceivePendingWebSocketMessage(NetworkConnectionToWebProcess&, IPC::Decoder&);

    // Whether a listener's onHeadersReceived can strip a response's Set-Cookie fields, which the network
    // task then holds until the verdict.
    bool holdsReceivedCookies() const { return m_listeners.hasOption(LegacyExtensions::onHeadersReceived, LegacyExtensions::extraHeadersOption); }

    bool continueWillSendRequest(NetworkResourceLoader&, WebCore::ResourceRequest&);

    bool interceptAuthenticationChallenge(NetworkLoad&, const WebCore::AuthenticationChallenge&, NegotiatedLegacyTLS, ChallengeCompletionHandler&);

    void loaderDidFail(NetworkResourceLoader&, const WebCore::ResourceError&);

    void loaderDidFinish(NetworkResourceLoader&, NetworkResourceLoader::LoadResult);

    // A chunk of the body, and the body's end, the web process receives; true when the load's StreamFilters
    // take it instead.
    bool filterResponseData(NetworkResourceLoader&, const WebCore::FragmentedSharedBuffer&);
    bool finishFilteredResponse(NetworkResourceLoader&, const WebCore::NetworkLoadMetrics&);
    bool filtersResponse(NetworkResourceLoader&) const;
    // True when a load that succeeded keeps its loader until its StreamFilters end the body, which then cleans it
    // up; a load that fails or is cancelled fails its filters.
    bool deferCleanup(NetworkResourceLoader&, NetworkResourceLoader::LoadResult);
    // A synchronous load's reply, which carries its whole body: its StreamFilters take the body and the reply
    // waits for their output.
    using SynchronousReply = CompletionHandler<void(const WebCore::ResourceError&, const WebCore::ResourceResponse, Vector<uint8_t>&&)>;
    SynchronousReply filterSynchronousReply(NetworkConnectionToWebProcess&, WebCore::ResourceLoaderIdentifier, SynchronousReply&&);

    // The privacy API's network.networkPredictionEnabled: DNS prefetching and the preconnections pages ask for.
    bool allowsNetworkPrediction() const { return m_networkPredictionEnabled; }

private:
    friend class NeverDestroyed<LegacyExtensionNetwork>;
    LegacyExtensionNetwork() = default;

    void setListeners(Vector<String>&& observedEvents, Vector<String>&& listenerOptions, String&& blockingListeners) { m_listeners.set(WTF::move(observedEvents), WTF::move(listenerOptions), blockingListeners); }

    void createResponseFilter(uint64_t filterID, uint64_t requestIdentifier, String&& extensionKey, String&& websiteAccess);
    void writeResponseFilter(uint64_t filterID, IPC::SharedBufferReference&&, uint64_t dispatched);
    void closeResponseFilter(uint64_t filterID);
    void disconnectResponseFilter(uint64_t filterID, uint64_t dispatched);
    void suspendResponseFilter(uint64_t filterID);
    void resumeResponseFilter(uint64_t filterID);
    void setPrivacySettings(bool networkPredictionEnabled, bool hyperlinkAuditingEnabled)
    {
        m_networkPredictionEnabled = networkPredictionEnabled;
        m_hyperlinkAuditingEnabled = hyperlinkAuditingEnabled;
    }

    // The StreamFilters of one load, and what the web process receives once their output ends: the network's
    // metrics, or the reply of a synchronous load. The loader lives until then; its finished network load goes
    // away when its cleanup is deferred, leaving the bytes it transferred.
    struct FilteredResponse : RefCounted<FilteredResponse> {
        uint64_t requestIdentifier { 0 };
        Markable<WebCore::ResourceLoaderIdentifier> coreIdentifier;
        WeakPtr<NetworkResourceLoader> loader;
        RefPtr<LegacyExtensionResponseFilter> filter;
        bool inputFinished { false };
        bool cleanupIsDeferred { false };
        uint64_t bytesTransferredOverNetwork { 0 };
        std::optional<WebCore::NetworkLoadMetrics> metrics;
        String error;
        SynchronousReply synchronousReply;
        WebCore::ResourceError synchronousError;
        WebCore::ResourceResponse synchronousResponse;
        Vector<uint8_t> synchronousBody;
    };
    // The URL a load ended at, which its network load no longer answers once its cleanup is deferred.
    URL currentURL(NetworkResourceLoader&) const;
    RefPtr<FilteredResponse> filteredResponse(uint64_t filterID) const;
    void sendFilterEvent(uint64_t filterID, ASCIILiteral event, RefPtr<WebCore::SharedBuffer>&&, const String& error);
    void outputFilteredResponse(uint64_t requestIdentifier, RefPtr<WebCore::SharedBuffer>&&);
    void removeFilteredResponse(FilteredResponse&);
    bool hasOption(ASCIILiteral eventName, ASCIILiteral option) const { return m_listeners.hasOption(eventName, option); }
    RefPtr<NetworkDataTaskCurlCocoa> curlTask(NetworkResourceLoader&);
    String cookieHeader(NetworkLoadChecker&, const WebCore::ResourceRequest&);

    bool interceptBeforeRequest(NetworkLoadChecker&, WebCore::ResourceRequest&, WebCore::ContentSecurityPolicyClient*, NetworkLoadChecker::ValidationHandler&);
    bool interceptRequestHeaders(NetworkLoadChecker&, WebCore::ResourceRequest&, WebCore::ContentSecurityPolicyClient*, NetworkLoadChecker::ValidationHandler&);
    void redirect(NetworkResourceLoader&, WebCore::ResourceRequest&&, const WebCore::ResourceResponse&, const URL&);
    bool loadsInPlace(NetworkResourceLoader&, const URL&);
    void redirectInPlace(NetworkLoadChecker&, NetworkResourceLoader&, WebCore::ResourceRequest&&, const WebCore::ResourceResponse&, const URL&);

    bool observes(ASCIILiteral eventName) const { return m_listeners.observes(eventName); }
    bool blocks(ASCIILiteral eventName, const JSON::Object& details) const { return m_listeners.blocks(eventName, details); }

    void notify(ASCIILiteral eventName, const String& details);
    void dispatch(ASCIILiteral eventName, const String& details, CompletionHandler<void(RefPtr<JSON::Object>&&)>&&);

    String requestIdentifier(NetworkLoadChecker&);
    Ref<JSON::Object> requestDetails(NetworkLoadChecker&, const WebCore::ResourceRequest&);
    Ref<JSON::Object> loaderDetails(NetworkResourceLoader&);
    Ref<JSON::Object> responseDetails(NetworkResourceLoader&, const WebCore::ResourceResponse&, bool fromCache);

    WeakPtr<NetworkProcess> m_networkProcess;
    LegacyExtensions::WebRequestListeners m_listeners;
    WeakHashMap<NetworkLoadChecker, uint64_t> m_checkerRequestIdentifiers;
    uint64_t m_nextRequestIdentifier { 1 };
    WeakHashSet<NetworkLoadChecker> m_resumingRequests;
    WeakHashSet<NetworkLoadChecker> m_resumingRedirections;
    WeakHashSet<NetworkDataTaskClient> m_resumingChallenges;
    // The loads whose requests the extensions have seen, which an authentication challenge's load is one of.
    WeakHashSet<NetworkResourceLoader> m_loaders;
    WeakHashSet<NetworkLoadChecker> m_extensionRedirects;
    WeakHashMap<NetworkLoadChecker, unsigned> m_internalRedirectCounts;
    WeakHashMap<NetworkLoadChecker, String> m_editedCookies;
    WeakHashMap<NetworkLoadChecker, URL> m_extensionRedirectTargets;
    struct InternalRedirectBody {
        URL url;
        String method;
        RefPtr<WebCore::FormData> body;
    };
    WeakHashMap<NetworkLoadChecker, InternalRedirectBody> m_internalRedirectBodies;
    WeakHashMap<NetworkLoadChecker, std::unique_ptr<WebCore::ResourceResponse>> m_redirectResponses;
    WeakHashSet<NetworkResourceLoader> m_resumingResponses;
    WeakHashSet<NetworkResourceLoader> m_resumingCacheEntries;
    WeakHashMap<NetworkResourceLoader, String> m_loadErrors;
    WeakHashMap<NetworkConnectionToWebProcess, HashSet<uint64_t>> m_pendingWebSockets;
    // Keyed by the load's request identifier, and each filter's to its load's.
    HashMap<uint64_t, Ref<FilteredResponse>> m_filteredResponses;
    HashMap<uint64_t, uint64_t> m_responseFilterRequests;
    // The loads the extensions have seen whose web process has received some of the body, which no filter can
    // attach to any more.
    WeakHashSet<NetworkResourceLoader> m_loadersWithDeliveredBody;
    WeakHashMap<NetworkResourceLoader, URL> m_deferredCleanupURLs;
    bool m_networkPredictionEnabled { true };
    // The privacy API's websites.hyperlinkAuditingEnabled: the pings of <a ping>.
    bool m_hyperlinkAuditingEnabled { true };
};

} // namespace WebKit
