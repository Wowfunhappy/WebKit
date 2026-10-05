// The UI-process router of the `browser` namespace WebKit gives Safari 7 legacy extensions.
//
// Safari 7 hosts an extension's global page and toolbar popovers in WebKit 1 views in its own process,
// and extension pages opened in tabs or frames in web content processes; with content scripts, which run
// in web content processes too, they are the extension's contexts. The router connects them: runtime
// ports and one-shot messages between contexts, the tabs/webNavigation/webRequest events and methods and
// the clipboard reads extension pages make, and the webRequest verdicts network processes wait on. Tabs are
// WebPageProxy identifiers and frames are FrameIdentifiers, with 0 standing for a tab's main frame as in
// the WebExtensions API.
//
// Other apps' web views can act as Safari tabs: a process pool that uses Safari's extensions makes its
// process a satellite of Safari's, the hub (LegacyExtensionChannel). Safari's bundle content scripts and
// style sheets go into the satellite's pages; the hub routes for them as for its own tabs, and the
// satellite carries their messages, events and web requests and acts on the hub's calls. A satellite's
// tab is its page's identifier plus its satellite number times 2^32, and its contexts are known to the
// hub by tokens.

#pragma once

#include "LegacyExtensionWebsiteAccess.h"
#include "MessageReceiver.h"
#include <JavaScriptCore/Weak.h>
#include <WebCore/FrameIdentifier.h>
#include <WebCore/FrameLoaderTypes.h>
#include <WebCore/ProcessIdentifier.h>
#include <WebCore/ScriptExecutionContextIdentifier.h>
#include <wtf/CompletionHandler.h>
#include <wtf/HashMap.h>
#include <wtf/JSONValues.h>
#include <wtf/Markable.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/RefCounted.h>
#include <wtf/URL.h>
#include <wtf/WeakHashMap.h>
#include <wtf/WeakHashSet.h>
#include <wtf/text/WTFString.h>

namespace JSC {
class JSGlobalObject;
}

namespace WebCore {
class ResourceError;
struct Cookie;
}

namespace API {
class ContentWorld;
class Navigation;
class UserScript;
class UserStyleSheet;
}

namespace WebKit {

class LegacyExtensionCookieObserver;
class NetworkProcessProxy;
class WebProcessPool;
class WebUserContentControllerProxy;
class WebBackForwardListItem;
class WebFrameProxy;
class WebPageProxy;
class WebProcessProxy;

class LegacyExtensionNetworkProxy final : public IPC::MessageReceiver {
public:
    void ref() const final { }
    void deref() const final { }

    void didReceiveMessage(IPC::Connection&, IPC::Decoder&) final;

private:
    void dispatchBlockingEvent(String&& eventName, String&& details, CompletionHandler<void(String&&)>&&);
    void dispatchEvent(String&& eventName, String&& details);
};

class LegacyExtensionHost final : public IPC::MessageReceiver {
public:
    static LegacyExtensionHost& singleton();

    void ref() const final { }
    void deref() const final { }

    void webProcessCreated(WebProcessProxy&);
    void networkProcessCreated(NetworkProcessProxy&);

    void pageWasCreated(WebPageProxy&);
    void pageWillClose(WebPageProxy&);
    void didCommitLoad(WebPageProxy&, WebFrameProxy&, Markable<WebCore::ScriptExecutionContextIdentifier> documentID, API::Navigation*, WebCore::FrameLoadType, const URL&);
    void didStartProvisionalLoad(WebPageProxy&, WebFrameProxy&, const URL&);
    void didFinishDocumentLoad(WebPageProxy&, WebFrameProxy&);
    void didFinishLoad(WebPageProxy&, WebFrameProxy&);
    void didFailLoad(WebPageProxy&, WebFrameProxy&, const URL&, const WebCore::ResourceError&);
    void didCreateNavigationTarget(WebPageProxy& sourcePage, WebCore::FrameIdentifier sourceFrameID, WebPageProxy& newPage, const URL&);
    void didDestroyFrame(WebCore::FrameIdentifier);

    void setUsesSafariExtensions(WebProcessPool&);
    void fetchFromHub(const URL&, CompletionHandler<void(std::optional<Vector<uint8_t>>&&, String&& mimeType)>&&);
    double tabIDForPage(const WebPageProxy&) const;
    RefPtr<WebPageProxy> pageForTabID(std::optional<double> tabID) const;

    void didReceiveMessage(IPC::Connection&, IPC::Decoder&) final;

    void dispatchWebRequestEvent(const String& eventName, const String& details, CompletionHandler<void(String&&)>&&);
    void dispatchCookieChange(const WebCore::Cookie&, Ref<JSON::Array>&&);

    // WebKit 1 host contexts.
    void didClearWindowObject(const void* frame, JSC::JSGlobalObject&, const URL& documentURL);
    void frameWillBeDestroyed(const void* frame);
    void postFromHostContext(uint64_t hostContextIdentifier, const String& message);

private:
    friend class NeverDestroyed<LegacyExtensionHost>;
    LegacyExtensionHost();
    ~LegacyExtensionHost();

    // An extension page: a WebKit 1 view in this process, or a frame of a web content process.
    struct HostContext : RefCounted<HostContext> {
        static Ref<HostContext> create() { return adoptRef(*new HostContext); }
        uint64_t identifier { 0 };
        String extensionKey;
        URL url;
        const void* frame { nullptr };
        JSC::Weak<JSC::JSGlobalObject> globalObject;
        Markable<WebCore::FrameIdentifier> frameID;
        Markable<WebCore::ScriptExecutionContextIdentifier> documentID;
        // An extension page in a satellite's frame.
        uint64_t satellite { 0 };
        uint64_t remoteToken { 0 };
        // Each event a listener is registered for, with its JSON interest: the filters of its blocking
        // listeners, and the extraInfoSpec options (requestBody, extraHeaders) a listener asks for.
        HashMap<String, String> interests;
    };

    // One end of a port or a one-shot message: an extension page, or the content-script context of an
    // extension in one document of a frame of a web content process, here or in a satellite.
    struct Endpoint {
        RefPtr<HostContext> host;
        Markable<WebCore::FrameIdentifier> frameID;
        Markable<WebCore::ScriptExecutionContextIdentifier> documentID;
        uint64_t satellite { 0 };
        uint64_t remoteToken { 0 };
        bool operator==(const Endpoint&) const = default;
    };

    // A call a host context made for a satellite's tab, until the satellite answers it.
    struct RemoteCall {
        RefPtr<HostContext> caller;
        double callerCallID { 0 };
        uint64_t satellite { 0 };
    };

    struct RemoteEndpointsRequest {
        uint64_t satellite { 0 };
        String extensionKey;
        CompletionHandler<void(Vector<Endpoint>&&)> completionHandler;
    };

    // A script or style sheet of Safari's bundle content, known by the JSON item it is made from.
    struct HubContentItem {
        String identity;
        String extensionKey;
        RefPtr<API::UserScript> script;
        RefPtr<API::UserStyleSheet> styleSheet;
    };

    // A document of a satellite's frame that has a context of an extension.
    struct SatelliteDocument {
        Markable<WebCore::FrameIdentifier> frameID;
        Markable<WebCore::ScriptExecutionContextIdentifier> documentID;
    };

    struct Port {
        String extensionKey;
        Endpoint opener;
        Vector<Endpoint> receivers;
        bool isResolving { false };
        Vector<String> queuedMessages;
    };

    struct OneShotMessage {
        String extensionKey;
        Endpoint sender;
        Vector<Endpoint> pendingReceivers;
        bool answered { false };
    };

    struct RouterCall {
        RefPtr<HostContext> caller;
        double callerCallID { 0 };
        String method;
        Vector<Endpoint> pendingEndpoints;
        RefPtr<JSON::Array> results;
        String error;
    };

    struct WebRequestCall {
        Vector<uint64_t> pendingHostContexts;
        RefPtr<JSON::Object> response;
        CompletionHandler<void(String&&)> completionHandler;
    };

    void post(IPC::Connection&, WebCore::FrameIdentifier, WebCore::ScriptExecutionContextIdentifier, URL&& documentURL, String&& extensionKey, String&& message);
    void didChangeBundleContent(IPC::Connection&, String&& content);

    void route(const Endpoint&, const String& extensionKey, const String& message);
    void routeConnect(const Endpoint&, const String& extensionKey, JSON::Object&);
    void routePost(const Endpoint&, const String& message, const String& portID);
    void routeDisconnect(const Endpoint&, const String& portID);
    void routeOneShotMessage(const Endpoint&, const String& extensionKey, JSON::Object&);
    void routeReply(const Endpoint&, JSON::Object&);
    void routeCallResult(const Endpoint&, JSON::Object&);
    void routeWebRequestResponse(const HostContext&, JSON::Object&);
    void routeInterest(HostContext&, JSON::Object&);
    void performCall(HostContext&, JSON::Object&);

    Vector<Endpoint> hostContextsListeningTo(const String& extensionKey, const String& eventName, const Endpoint& except) const;
    void tabEndpoints(WebPageProxy&, std::optional<double> frameId, const String& extensionKey, CompletionHandler<void(Vector<Endpoint>&&)>&&);
    void endpointsForTab(std::optional<double> tabID, std::optional<double> frameId, const String& extensionKey, CompletionHandler<void(Vector<Endpoint>&&)>&&);
    bool deliver(const Endpoint&, const String& extensionKey, const String& message);
    Ref<JSON::Object> senderDescription(const Endpoint&) const;
    void endpointDidGoAway(const Endpoint&);
    void endpointsDidGoAway(NOESCAPE const Function<bool(const Endpoint&)>&);
    void hostContextDidGoAway(HostContext&);
    void framesDidGoAway(const Vector<WebCore::FrameIdentifier>&);
    void finishRouterCallIfComplete(uint64_t);
    void finishWebRequestCallIfComplete(uint64_t);
    void dispatchEvent(const String& eventName, Ref<JSON::Array>&& arguments);
    void dispatchTabEvent(WebPageProxy&, const String& eventName, Ref<JSON::Array>&& arguments);
    void dispatchWebRequestDetails(const String& eventName, Ref<JSON::Object>&& details, CompletionHandler<void(String&&)>&&);
    void performTabCall(const String& method, RefPtr<JSON::Array>&& arguments, CompletionHandler<void(RefPtr<JSON::Value>&&, String&& error)>&&);
    void updateNetworkListeners();
    void updateCookieObservers();
    void loadWebsiteAccess(const String& extensionKey, const URL&);
    void withWebsiteAccess(const String& extensionKey, Function<void(const LegacyExtensions::WebsiteAccess&)>&&);
    void sendNetworkListeners(NetworkProcessProxy&);

    Ref<JSON::Object> tabDescription(WebPageProxy&) const;
    void resultToHostContext(HostContext&, double callID, RefPtr<JSON::Value>&& result, const String& error = { });

    RefPtr<HostContext> extensionPageContext(WebFrameProxy&, Markable<WebCore::ScriptExecutionContextIdentifier> documentID, const URL& documentURL, const String& extensionKey);
    URL documentURL(WebFrameProxy&, Markable<WebCore::ScriptExecutionContextIdentifier>) const;
    void documentsDidGoAway(NOESCAPE const Function<bool(WebCore::FrameIdentifier, WebCore::ScriptExecutionContextIdentifier)>&);

    // The hub.
    void startHub();
    void updateWelcomeMessages();
    void receiveFromSatellite(uint64_t satellite, JSON::Object&);
    void satelliteDidGoAway(uint64_t satellite);
    static uint64_t satelliteForTabID(std::optional<double> tabID);
    RefPtr<HostContext> remoteExtensionPageContext(uint64_t satellite, uint64_t token, const String& extensionKey, const URL& documentURL);
    void forwardTabCall(uint64_t satellite, HostContext&, double callID, const String& method, RefPtr<JSON::Array>&& arguments);
    Ref<JSON::Object> networkListenersMessage() const;

    // A satellite.
    bool isSatellitePage(const WebPageProxy&) const;
    void connectedToHub(uint64_t satelliteNumber);
    void receiveFromHub(JSON::Object&);
    void hubDidGoAway();
    uint64_t tokenForDocument(WebCore::FrameIdentifier, WebCore::ScriptExecutionContextIdentifier);
    void satelliteDocumentsDidGoAway(NOESCAPE const Function<bool(const SatelliteDocument&)>&);
    void satelliteEndpoints(double requestID, std::optional<double> tabID, std::optional<double> frameId, const String& extensionKey);
    void setHubContent(JSON::Array&);
    void installContent(WebUserContentControllerProxy&);
    void addContent(WebUserContentControllerProxy&, const HubContentItem&);
    void setHubNetworkListeners(JSON::Object&);

    HashMap<uint64_t, Ref<HostContext>> m_hostContexts;
    HashMap<const void*, uint64_t> m_hostContextByFrame;
    HashMap<WebCore::FrameIdentifier, uint64_t> m_hostContextByRemoteFrame;
    // The frame and URL of each document an extension context has posted from, as its web content process
    // reports them.
    HashMap<WebCore::ScriptExecutionContextIdentifier, std::pair<WebCore::FrameIdentifier, URL>> m_documents;
    HashMap<String, Port> m_ports;
    HashMap<String, OneShotMessage> m_oneShotMessages;
    HashMap<uint64_t, RouterCall> m_routerCalls;
    HashMap<uint64_t, WebRequestCall> m_webRequestCalls;
    // The transition that first committed each main-frame history item, which going back or forward to it reports.
    WeakHashMap<WebBackForwardListItem, String> m_historyItemTransitions;
    uint64_t m_nextIdentifier { 1 };
    Vector<String> m_observedNetworkEvents;
    Vector<String> m_networkListenerOptions;
    String m_blockingNetworkListeners;
    LegacyExtensionNetworkProxy m_networkProxy;
    HashMap<String, Ref<LegacyExtensionCookieObserver>> m_cookieObservers;
    HashMap<String, LegacyExtensions::WebsiteAccess> m_websiteAccess;
    HashMap<String, URL> m_websiteAccessRoots;
    HashMap<String, Vector<Function<void(const LegacyExtensions::WebsiteAccess&)>>> m_websiteAccessWaiters;

    // The hub: the content Safari's bundle gives its pages, as each process has it and merged, and what it
    // knows of satellites' contexts.
    HashMap<WebCore::ProcessIdentifier, Ref<JSON::Array>> m_bundleContentByProcess;
    String m_bundleContent;
    HashMap<std::pair<uint64_t, uint64_t>, Ref<JSON::Object>> m_remoteSenders;
    HashMap<std::pair<uint64_t, uint64_t>, uint64_t> m_hostContextByRemoteToken;
    HashMap<uint64_t, RemoteCall> m_remoteCalls;
    HashMap<uint64_t, RemoteEndpointsRequest> m_remoteEndpointsRequests;

    // A satellite: its pools, its number while it is connected to the hub, its documents' tokens, its web
    // requests awaiting the hub's verdicts, and the content its pages' user content controllers hold.
    WeakHashSet<WebProcessPool> m_satellitePools;
    uint64_t m_satelliteNumber { 0 };
    HashMap<uint64_t, SatelliteDocument> m_satelliteDocuments;
    HashMap<std::pair<WebCore::FrameIdentifier, WebCore::ScriptExecutionContextIdentifier>, uint64_t> m_satelliteTokens;
    HashMap<uint64_t, CompletionHandler<void(String&&)>> m_satelliteWebRequests;
    HashMap<uint64_t, CompletionHandler<void(std::optional<Vector<uint8_t>>&&, String&&)>> m_satelliteFetches;
    Vector<HubContentItem> m_hubContent;
    HashMap<String, Ref<API::ContentWorld>> m_hubContentWorlds;
    WeakHashSet<WebUserContentControllerProxy> m_contentControllers;
};

} // namespace WebKit
