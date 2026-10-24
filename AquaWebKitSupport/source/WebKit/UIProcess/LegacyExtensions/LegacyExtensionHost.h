// The UI-process router of the `browser` namespace WebKit gives Safari 7 legacy extensions.
//
// Safari 7 hosts an extension's global page and toolbar popovers in WebKit 1 views in its own process,
// and extension pages opened in tabs or frames in web content processes; with content scripts, which run
// in web content processes too, they are the extension's contexts. The router connects them: runtime
// ports and one-shot messages between contexts, the tabs/webNavigation/webRequest events and methods and
// the clipboard reads extension pages make, and the webRequest verdicts network processes wait on. Tabs are
// WebPageProxy identifiers and frames are FrameIdentifiers, with 0 standing for a tab's main frame as in
// the WebExtensions API.

#pragma once

#include "LegacyExtensionWebsiteAccess.h"
#include "MessageReceiver.h"
#include <JavaScriptCore/Weak.h>
#include <WebCore/FrameIdentifier.h>
#include <WebCore/FrameLoaderTypes.h>
#include <WebCore/ScriptExecutionContextIdentifier.h>
#include <wtf/CompletionHandler.h>
#include <wtf/HashMap.h>
#include <wtf/Expected.h>
#include <wtf/Variant.h>
#include <wtf/JSONValues.h>
#include <wtf/Markable.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/RefCounted.h>
#include <wtf/URL.h>
#include <wtf/WeakHashMap.h>
#include <wtf/text/WTFString.h>

namespace JSC {
class JSGlobalObject;
}

namespace IPC {
class SharedBufferReference;
}

namespace WebCore {
class ResourceError;
class SharedBuffer;
struct ContentRuleListResults;
struct Cookie;
}

namespace API {
class Navigation;
}

namespace WebKit {

class LegacyExtensionCookieObserver;
class LegacyExtensionDeclarativeNetRequest;
class NetworkProcessProxy;
class WebBackForwardListItem;
class WebFrameProxy;
class WebPageProxy;
class WebProcessProxy;
class WebUserContentControllerProxy;

class LegacyExtensionNetworkProxy final : public IPC::MessageReceiver {
public:
    void ref() const final { }
    void deref() const final { }

    void didReceiveMessage(IPC::Connection&, IPC::Decoder&) final;

private:
    void dispatchBlockingEvent(String&& eventName, String&& details, CompletionHandler<void(String&&)>&&);
    void dispatchEvent(String&& eventName, String&& details);
    void responseFilterEvent(uint64_t filterID, String&& event, IPC::SharedBufferReference&&, String&& error);
};

class LegacyExtensionHost final : public IPC::MessageReceiver {
public:
    static LegacyExtensionHost& singleton();

    void ref() const final { }
    void deref() const final { }

    void webProcessCreated(WebProcessProxy&);
    // A web process's state, sent once it is initialized.
    void webProcessDidInitialize(WebProcessProxy&);
    void networkProcessCreated(NetworkProcessProxy&);
    void networkProcessDidTerminate(NetworkProcessProxy&);

    void pageWasCreated(WebPageProxy&);
    void pageWillClose(WebPageProxy&);
    void tabWillClose(WebPageProxy&);
    // Reports a change of a tab's hidden state to tabs.onUpdated listeners, describing the tab as it is now.
    void tabHiddenDidChange(WebPageProxy&, bool hidden);
    void didCommitLoad(WebPageProxy&, WebFrameProxy&, Markable<WebCore::ScriptExecutionContextIdentifier> documentID, API::Navigation*, WebCore::FrameLoadType, const URL&);
    void didStartProvisionalLoad(WebPageProxy&, WebFrameProxy&, const URL&);
    void didFinishDocumentLoad(WebPageProxy&, WebFrameProxy&);
    void didFinishLoad(WebPageProxy&, WebFrameProxy&);
    void didFailLoad(WebPageProxy&, WebFrameProxy&, const URL&, const WebCore::ResourceError&);
    void didCreateNavigationTarget(WebPageProxy& sourcePage, WebCore::FrameIdentifier sourceFrameID, WebPageProxy& newPage, const URL&);
    void didDestroyFrame(WebCore::FrameIdentifier);

    void didReceiveMessage(IPC::Connection&, IPC::Decoder&) final;

    void dispatchWebRequestEvent(const String& eventName, const String& details, CompletionHandler<void(String&&)>&&);
    // An event whose details already name the load's tab and frames as the API reports them.
    void dispatchWebRequestEvent(const String& eventName, Ref<JSON::Object>&& details, CompletionHandler<void(String&&)>&&);
    void dispatchCookieChange(const WebCore::Cookie&, Ref<JSON::Array>&&);
    // An event of a StreamFilter an extension context attached to a network process's load.
    void dispatchResponseFilterEvent(uint64_t filterID, const String& event, RefPtr<WebCore::SharedBuffer>&&, const String& error);

    // declarativeNetRequest: the controllers of the pages extensions' rules apply to, and the rule lists a
    // page's load matched.
    Vector<Ref<WebUserContentControllerProxy>> userContentControllers() const;
    void contentRuleListNotification(WebPageProxy&, const URL&, const WebCore::ContentRuleListResults&);

    // WebKit 1 host contexts.
    void didClearWindowObject(const void* frame, JSC::JSGlobalObject&, const URL& documentURL);
    void frameWillBeDestroyed(const void* frame);
    void postFromHostContext(uint64_t hostContextIdentifier, const String& message, RefPtr<WebCore::SharedBuffer>&& data);

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
        // Each event a listener is registered for, with its JSON interest: the filters of its blocking
        // listeners, and the extraInfoSpec options (requestBody, extraHeaders) a listener asks for.
        HashMap<String, String> interests;
    };

    // One end of a port or a one-shot message: an extension page, or the content-script context of an
    // extension in one document of a frame of a web content process.
    struct Endpoint {
        RefPtr<HostContext> host;
        Markable<WebCore::FrameIdentifier> frameID;
        Markable<WebCore::ScriptExecutionContextIdentifier> documentID;
        bool operator==(const Endpoint&) const = default;
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

    // A StreamFilter: the host context that attached it, which names it `contextFilterID`, the network process
    // whose load it filters, and how many of its data events the context has dispatched.
    struct ResponseFilter {
        uint64_t hostContextIdentifier { 0 };
        String contextFilterID;
        WeakPtr<NetworkProcessProxy> networkProcess;
        uint64_t dispatched { 0 };
    };

    void beginMediaPlayerHandoff(IPC::Connection&, WebCore::FrameIdentifier, uint64_t request, uint64_t parent, String&& ticket, String&& extensionKey, CompletionHandler<void(Expected<bool, String>&&)>&&);
    void controlMediaPlayer(IPC::Connection&, uint64_t, String&&, double, CompletionHandler<void(bool)>&&);
    void endMediaPlayerHandoff(IPC::Connection&, uint64_t request);
    void publishMediaSource(IPC::Connection&, WebCore::FrameIdentifier, WebCore::ScriptExecutionContextIdentifier, URL&&, String&& extensionKey, uint64_t request, uint64_t identifier, URL&&, String&& playlist, String&& title, String&& codec, CompletionHandler<void(Expected<URL, String>&&)>&&);
    void openPublishedMedia(IPC::Connection&, uint64_t, String&& application, String&& adapter, double timeout, CompletionHandler<void(Expected<URL, String>&&)>&&);
    void mediaPlayerState(IPC::Connection&, uint64_t, CompletionHandler<void(Expected<String, String>&&)>&&);
    void setMediaResource(IPC::Connection&, uint64_t, String&& name, String&& type, std::optional<IPC::SharedBufferReference>&&, CompletionHandler<void(Expected<URL, String>&&)>&&);
    void setMediaPlaylistProvider(IPC::Connection&, uint64_t, bool, CompletionHandler<void(bool)>&&);
    void activateMediaPlayer(IPC::Connection&, uint64_t identifier, CompletionHandler<void(Expected<bool, String>&&)>&&);
    void completeRestream(IPC::Connection&, uint64_t);
    void endRestream(IPC::Connection&, uint64_t);
    void post(IPC::Connection&, WebCore::FrameIdentifier, WebCore::ScriptExecutionContextIdentifier, URL&& documentURL, String&& extensionKey, String&& message, IPC::SharedBufferReference&& data);

    void route(const Endpoint&, const String& extensionKey, const String& message, RefPtr<WebCore::SharedBuffer>&& data = nullptr);
    void routeConnect(const Endpoint&, const String& extensionKey, JSON::Object&);
    void routePost(const Endpoint&, const String& message, const String& portID);
    void routeDisconnect(const Endpoint&, const String& portID);
    void routeOneShotMessage(const Endpoint&, const String& extensionKey, JSON::Object&);
    void routeReply(const Endpoint&, JSON::Object&);
    void routeCallResult(const Endpoint&, JSON::Object&);
    void routeWebRequestResponse(const HostContext&, JSON::Object&);
    void routeInterest(HostContext&, JSON::Object&);
    void routeResponseFilter(HostContext&, JSON::Object&, RefPtr<WebCore::SharedBuffer>&&);
    void removeResponseFilter(uint64_t filterID);
    void performCall(HostContext&, JSON::Object&);

    Vector<Endpoint> hostContextsListeningTo(const String& extensionKey, const String& eventName, const Endpoint& except) const;
    void tabEndpoints(WebPageProxy&, std::optional<double> frameId, const String& extensionKey, CompletionHandler<void(Vector<Endpoint>&&)>&&);
    bool deliver(const Endpoint&, const String& extensionKey, const String& message, RefPtr<WebCore::SharedBuffer>&& data = nullptr, bool existingPort = false);
    Ref<JSON::Object> senderDescription(const Endpoint&) const;
    void endpointDidGoAway(const Endpoint&);
    void endpointsDidGoAway(NOESCAPE const Function<bool(const Endpoint&)>&);
    // A context its frame's next document replaces leaves the extension loaded.
    enum class ContextIsReplaced : bool { No, Yes };
    void hostContextDidGoAway(HostContext&, ContextIsReplaced = ContextIsReplaced::No);
    void unloadExtensionIfUnused(const String& extensionKey);
    void framesDidGoAway(const Vector<WebCore::FrameIdentifier>&);
    void finishRouterCallIfComplete(uint64_t);
    void finishWebRequestCallIfComplete(uint64_t);
    void dispatchEvent(const String& eventName, Ref<JSON::Array>&& arguments);
    void updateNetworkListeners();
    void updateCookieObservers();
    void loadWebsiteAccess(const String& extensionKey, const URL&);
    void loadDeclarativeNetRequest(const String& extensionKey, const URL& root, RefPtr<JSON::Object>&& declarativeNetRequestEntry, const LegacyExtensions::WebsiteAccess&);
    void updateContentRuleListActionPatterns(WebPageProxy&);
    void extensionDidUnload(const String& extensionKey);
    void withWebsiteAccess(const String& extensionKey, Function<void(const LegacyExtensions::WebsiteAccess&)>&&);
    void sendNetworkListeners(NetworkProcessProxy&);

    Ref<JSON::Object> tabDescription(WebPageProxy&) const;
    Ref<JSON::Array> tabUpdatedArguments(WebPageProxy&, Ref<JSON::Object>&& changeInfo) const;
    void resultToHostContext(HostContext&, double callID, RefPtr<JSON::Value>&& result, const String& error = { });

    RefPtr<HostContext> extensionPageContext(WebFrameProxy&, Markable<WebCore::ScriptExecutionContextIdentifier> documentID, const URL& documentURL, const String& extensionKey);
    URL documentURL(WebFrameProxy&, Markable<WebCore::ScriptExecutionContextIdentifier>) const;
    void documentsDidGoAway(NOESCAPE const Function<bool(WebCore::FrameIdentifier, WebCore::ScriptExecutionContextIdentifier)>&);

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
    HashMap<uint64_t, ResponseFilter> m_responseFilters;
    // Each filter by its host context and the context's name for it, as "<context>:<name>".
    HashMap<String, uint64_t> m_responseFilterIDs;
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
    HashMap<String, Ref<LegacyExtensionDeclarativeNetRequest>> m_declarativeNetRequests;
};

} // namespace WebKit
