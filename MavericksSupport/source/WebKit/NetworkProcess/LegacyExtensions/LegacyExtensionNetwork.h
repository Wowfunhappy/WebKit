// The network-process side of webRequest for Safari 7 legacy extensions.
//
// The UI process's router tells every network process which webRequest events extensions listen to and
// the filter of each blocking listener. A load a blocking listener's filter matches waits on the event at
// the same points WebKit applies its own content rules: NetworkLoadChecker::checkRequest (onBeforeRequest
// and onBeforeSendHeaders, for every request and redirect, pings included), checkRedirection and the
// response (onHeadersReceived, for a redirect and for a network or cache response), and a WebSocket's
// creation.

#pragma once

#include "LegacyExtensionWebsiteAccess.h"
#include "MessageReceiver.h"
#include "NetworkLoadChecker.h"
#include "NetworkLoadClient.h"
#include "NetworkResourceLoader.h"
#include "WebPageProxyIdentifier.h"
#include <WebCore/WebSocketIdentifier.h>
#include <WebCore/FrameIdentifier.h>
#include <wtf/CompletionHandler.h>
#include <wtf/HashSet.h>
#include <wtf/JSONValues.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/WeakHashMap.h>
#include <wtf/WeakHashSet.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringHash.h>

namespace WebCore {
class AuthenticationChallenge;
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
    bool holdsReceivedCookies() const { return hasOption("onHeadersReceived"_s, "extraHeaders"_s); }

    bool continueWillSendRequest(NetworkResourceLoader&, WebCore::ResourceRequest&);

    bool interceptAuthenticationChallenge(NetworkLoad&, const WebCore::AuthenticationChallenge&, NegotiatedLegacyTLS, ChallengeCompletionHandler&);

    void loaderDidFail(NetworkResourceLoader&, const WebCore::ResourceError&);

    // A field the network layer adds to a request without one, as the request carries it and as an
    // "extraHeaders" listener sees it.
    struct GeneratedField {
        WebCore::HTTPHeaderName name;
        String carried;
        String shown;
    };
    void loaderDidFinish(NetworkResourceLoader&, NetworkResourceLoader::LoadResult);

private:
    friend class NeverDestroyed<LegacyExtensionNetwork>;
    LegacyExtensionNetwork() = default;

    struct BlockingListener {
        String extensionKey;
        LegacyExtensions::WebsiteAccess access;
        std::optional<Vector<String>> urlPatterns;
        std::optional<Vector<String>> types;
        std::optional<double> tabID;
    };

    void setListeners(Vector<String>&& observedEvents, Vector<String>&& listenerOptions, String&& blockingListeners);
    bool hasOption(ASCIILiteral eventName, ASCIILiteral option) const { return m_listenerOptions.contains(makeString(eventName, ':', option)); }
    RefPtr<NetworkDataTaskCurlCocoa> curlTask(NetworkResourceLoader&);
    String cookieHeader(NetworkLoadChecker&, const WebCore::ResourceRequest&);

    bool interceptBeforeRequest(NetworkLoadChecker&, WebCore::ResourceRequest&, WebCore::ContentSecurityPolicyClient*, NetworkLoadChecker::ValidationHandler&);
    bool interceptRequestHeaders(NetworkLoadChecker&, WebCore::ResourceRequest&, WebCore::ContentSecurityPolicyClient*, NetworkLoadChecker::ValidationHandler&);
    void redirect(NetworkResourceLoader&, WebCore::ResourceRequest&&, const WebCore::ResourceResponse&, const URL&);
    bool loadsInPlace(NetworkResourceLoader&, const URL&);
    void redirectInPlace(NetworkLoadChecker&, NetworkResourceLoader&, WebCore::ResourceRequest&&, const WebCore::ResourceResponse&, const URL&);

    bool observes(ASCIILiteral eventName) const { return m_observedEvents.contains(String { eventName }); }
    bool hasBlockingListener(ASCIILiteral eventName) const { return m_blockingListeners.contains(String { eventName }); }
    bool blocks(ASCIILiteral eventName, const JSON::Object& details) const;

    void notify(ASCIILiteral eventName, const String& details);
    void dispatch(ASCIILiteral eventName, const String& details, CompletionHandler<void(RefPtr<JSON::Object>&&)>&&);

    String requestIdentifier(NetworkLoadChecker&);
    Ref<JSON::Object> requestDetails(NetworkLoadChecker&, const WebCore::ResourceRequest&);
    Ref<JSON::Object> loaderDetails(NetworkResourceLoader&);
    Ref<JSON::Object> responseDetails(NetworkResourceLoader&, const WebCore::ResourceResponse&, bool fromCache);

    WeakPtr<NetworkProcess> m_networkProcess;
    HashSet<String> m_observedEvents;
    // The extraInfoSpec options some listener of an event asks for, as "<event>:<option>".
    HashSet<String> m_listenerOptions;
    HashMap<String, Vector<BlockingListener>> m_blockingListeners;
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
};

} // namespace WebKit
