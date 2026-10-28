// The UI-process router of the `browser` namespace WebKit gives Safari 7 legacy extensions.
//
// Safari 7 hosts an extension's global page and toolbar popovers in WebKit 1 views in its own process,
// and extension pages opened in tabs or frames in web content processes; with content scripts, which run
// in web content processes too, they are the extension's contexts. The router connects them: runtime
// ports and one-shot messages between an extension's contexts and between extensions, the
// tabs/webNavigation/webRequest events and methods and the clipboard reads extension pages make, and the
// webRequest verdicts network processes wait on. Tabs are WebPageProxy identifiers and frames are
// FrameIdentifiers, with 0 standing for a tab's main frame as in the WebExtensions API.

#pragma once

#include "LegacyExtensionWebsiteAccess.h"
#include "MessageReceiver.h"
#include <JavaScriptCore/Weak.h>
#include <WebCore/FrameIdentifier.h>
#include <WebCore/FrameLoaderTypes.h>
#include <WebCore/ProcessIdentifier.h>
#include <WebCore/ScriptExecutionContextIdentifier.h>
#include <wtf/CompletionHandler.h>
#include <wtf/Deque.h>
#include <wtf/HashMap.h>
#include <wtf/HashSet.h>
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
struct FrameInfoData;
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
    void webProcessWillShutDown(WebProcessProxy&);
    void networkProcessCreated(NetworkProcessProxy&);
    void networkProcessDidTerminate(NetworkProcessProxy&);

    void pageWasCreated(WebPageProxy&);
    void pageWillClose(WebPageProxy&);
    void tabWillClose(WebPageProxy&);
    // Report changes of a tab's state to tabs.onUpdated listeners.
    void tabHiddenDidChange(WebPageProxy&);
    void tabAudibleDidChange(WebPageProxy&);
    void tabMutedDidChange(WebPageProxy&);
    void didCommitLoad(WebPageProxy&, WebFrameProxy&, Markable<WebCore::ScriptExecutionContextIdentifier> documentID, API::Navigation*, WebCore::FrameLoadType, const URL&);
    // A main-frame load or same-document navigation committed.
    void didCommitMainFrameNavigation(WebPageProxy&);
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
    // proxy.onProxyError, with its `{ fatal, error, details }` as JSON.
    void dispatchProxyError(const String& details);
    // An event of a StreamFilter an extension context attached to a network process's load.
    void dispatchResponseFilterEvent(uint64_t filterID, const String& event, RefPtr<WebCore::SharedBuffer>&&, const String& error);

    // declarativeNetRequest: the controllers of the pages extensions' rules apply to, and the rule lists a
    // page's load matched.
    Vector<Ref<WebUserContentControllerProxy>> userContentControllers() const;
    void contentRuleListNotification(WebPageProxy&, const URL&, const WebCore::ContentRuleListResults&);

    // WebKit 1 host contexts.
    void didClearWindowObject(const void* frame, JSC::JSGlobalObject&, const URL& documentURL, bool isGlobalPage);
    void globalPageViewCreated(const void* frame, const URL&);
    void globalPageDocumentLoaded(const void* frame);
    void globalPageLoadFailed(const void* frame);
    void frameWillBeDestroyed(const void* frame);
    void postFromHostContext(uint64_t hostContextIdentifier, const String& message, RefPtr<WebCore::SharedBuffer>&& data);
    // Whether a host context is registered and the router has not invalidated it.
    bool isHostContextValid(uint64_t hostContextIdentifier) const;

    // An event of an extension, to its listening host contexts.
    void dispatchExtensionEvent(const String& extensionKey, const String& eventName, Ref<JSON::Array>&& arguments);

    // A devtools event, to the listening devtools pages of the inspected tab whose extensions `allows` admits.
    void dispatchDevToolsEvent(double inspectedTabID, const String& eventName, Ref<JSON::Array>&& arguments, Function<bool(const LegacyExtensions::WebsiteAccess&, const String& extensionKey)>&& allows);

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
        // The tab a devtools page inspects. A devtools page does not keep its extension loaded.
        std::optional<double> devToolsTabID;
        // Each event a listener is registered for, with its JSON interest: the filters of its blocking
        // listeners, and the extraInfoSpec options (requestBody, extraHeaders) a listener asks for.
        HashMap<String, String> interests;
        // An extension page in a tab whose extension Safari disabled or reloaded: it is told nothing more and
        // what it sends is dropped.
        bool isInvalidated { false };
    };

    // One end of a port or a one-shot message: an extension page, or the content-script context of an
    // extension in one document of a frame of a web content process. A content-script context names its
    // extension in `extensionKey`; a host context's extension is the host's own.
    struct Endpoint {
        RefPtr<HostContext> host;
        Markable<WebCore::FrameIdentifier> frameID;
        Markable<WebCore::ScriptExecutionContextIdentifier> documentID;
        String extensionKey;
        bool operator==(const Endpoint&) const = default;
    };
    static const String& extensionKeyOf(const Endpoint&);

    enum class BackgroundState : uint8_t { Unknown, NoGlobalPage, Waiting, Loaded, Failed };
    struct ExtensionLoad {
        uint64_t identifier { 0 };
        std::optional<bool> hasGlobalPage;
        BackgroundState documentState { BackgroundState::Waiting };
        const void* globalPageFrame { nullptr };
        BackgroundState state() const
        {
            return !hasGlobalPage ? BackgroundState::Unknown : *hasGlobalPage ? documentState : BackgroundState::NoGlobalPage;
        }
    };

    struct PendingMessageRoute {
        Endpoint sender;
        String extensionKey;
        String message;
    };

    struct PendingEvent {
        String extensionKey;
        uint64_t loadIdentifier;
        Function<void()> dispatch;
        Function<void()> cancel;
    };
    using PendingTask = Variant<PendingMessageRoute, PendingEvent>;

    // The two ends of a port or a one-shot message can be contexts of different extensions.
    struct Port {
        Endpoint opener;
        Vector<Endpoint> receivers;
        bool isResolving { false };
        Vector<String> queuedMessages;
    };

    struct OneShotMessage {
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
    void setUserContentExtensionRoots(IPC::Connection&, Vector<String>&& roots);
    void updateUserContentExtensions(const Vector<URL>& latestRoots = { });

    void route(const Endpoint&, const String& extensionKey, const String& message, RefPtr<WebCore::SharedBuffer>&& data = nullptr, bool isPendingTask = false);
    bool shouldDeferMessageRoute(const Endpoint&, const String& extensionKey, JSON::Object&) const;
    bool shouldDeferExtension(const String&) const;
    void flushPendingTasks();
    void performAfterBackgroundContentLoads(const String&, Function<void()>&&, Function<void()>&& cancel = [] { });
    void dispatchPendingEvent(PendingEvent&&);
    void routeConnect(const Endpoint&, const String& extensionKey, JSON::Object&);
    void routePost(const Endpoint&, const String& message, const String& portID);
    // `error` is the runtime.lastError of the other ends' onDisconnect.
    void routeDisconnect(const Endpoint&, const String& portID, const String& error = { });
    void routeOneShotMessage(const Endpoint&, const String& extensionKey, JSON::Object&);
    void routeReply(const Endpoint&, JSON::Object&);
    void routeCallResult(const Endpoint&, JSON::Object&);
    void routeWebRequestResponse(const HostContext&, JSON::Object&);
    void routeInterest(HostContext&, JSON::Object&);
    void routeResponseFilter(HostContext&, JSON::Object&, RefPtr<WebCore::SharedBuffer>&&);
    void removeResponseFilter(uint64_t filterID);
    void performCall(HostContext&, JSON::Object&);

    Vector<Endpoint> hostContextsListeningTo(const String& extensionKey, const String& eventName, const Endpoint& except) const;
    // The host contexts listening to `eventName` of the other extensions `extensionId` names for a sender
    // of the extension `senderExtensionKey`.
    Vector<Endpoint> externalHostContextsListeningTo(const String& extensionId, const String& senderExtensionKey, const String& eventName) const;
    // A tab's frames, or the one `frameId` names: the frame tree of its documents as the web content process
    // has it, which leaves out frames kept in the back/forward cache.
    void tabFrames(WebPageProxy&, std::optional<double> frameId, CompletionHandler<void(Vector<FrameInfoData>&&)>&&);
    // The context an extension has in a frame: its page where the frame shows one, its content scripts
    // elsewhere; none where the frame shows an invalidated page of the extension.
    std::optional<Endpoint> tabFrameEndpoint(const FrameInfoData&, const String& extensionKey);
    void tabEndpoints(WebPageProxy&, std::optional<double> frameId, const String& extensionKey, CompletionHandler<void(Vector<Endpoint>&&)>&&);
    // While the receiving extension's website access is read, what goes to it waits, in order.
    void deliver(const Endpoint&, const String& extensionKey, const String& message, RefPtr<WebCore::SharedBuffer>&& data = nullptr, bool existingPort = false);
    // Whether the message reached the endpoint, for an extension whose website access is read.
    bool deliverNow(const Endpoint&, const String& extensionKey, const String& message, RefPtr<WebCore::SharedBuffer>&& data = nullptr, bool existingPort = false);
    // A message as an extension that sees the page at `pageURL` gets it, or as one that does not; a null message
    // does not reach it.
    void deliverSeeingPage(const Endpoint&, const URL& pageURL, const String& visibleMessage, const String& hiddenMessage);
    // A message's sender, with its tab as an extension that sees the tab's page gets it, and as one that does not.
    struct SenderDescription {
        Ref<JSON::Object> visible;
        Ref<JSON::Object> hidden;
        URL pageURL;
    };
    SenderDescription senderDescription(const Endpoint&) const;
    void endpointDidGoAway(const Endpoint&);
    void endpointsDidGoAway(NOESCAPE const Function<bool(const Endpoint&)>&);
    // A context its frame's next document replaces leaves the extension loaded.
    enum class ContextIsReplaced : bool { No, Yes };
    void hostContextDidGoAway(HostContext&, ContextIsReplaced = ContextIsReplaced::No);
    void unloadExtensionIfUnused(const String& extensionKey);
    bool isPresentInSafari(const String& extensionKey) const;
    bool isRetiredRoot(const String& extensionKey, const URL& root) const;
    // The extension's pages in tabs, except those at `root`.
    void invalidateExtensionPages(const String& extensionKey, const URL& root = { });
    void invalidateExtensionPage(HostContext&);
    void framesDidGoAway(const Vector<WebCore::FrameIdentifier>&);
    void finishRouterCallIfComplete(uint64_t);
    void finishWebRequestCallIfComplete(uint64_t);
    void dispatchEvent(const String& eventName, Ref<JSON::Array>&& arguments);
    // An event with its arguments as an extension that sees the page at `pageURL` gets them, and as one that does
    // not; null arguments do not reach it.
    void dispatchEvent(const String& eventName, const URL& pageURL, RefPtr<JSON::Array>&& visibleArguments, RefPtr<JSON::Array>&& hiddenArguments);
    // A webNavigation event of a frame, for the extensions that see its URL.
    void dispatchNavigationEvent(const String& eventName, Ref<JSON::Object>&& details, const URL&);
    void updateNetworkListeners();
    void updateCookieObservers();
    void loadWebsiteAccess(const String& extensionKey, const URL&);
    void loadDeclarativeNetRequest(const String& extensionKey, const URL& root, RefPtr<JSON::Object>&& declarativeNetRequestEntry, const LegacyExtensions::WebsiteAccess&);
    void updateContentRuleListActionPatterns(WebPageProxy&);
    void extensionDidUnload(const String& extensionKey);
    void withWebsiteAccess(const String& extensionKey, Function<void(const LegacyExtensions::WebsiteAccess&)>&&);
    void sendNetworkListeners(NetworkProcessProxy&);

    // A tab, with its URL and title when the extension sees its page.
    Ref<JSON::Object> tabDescription(WebPageProxy&, bool seesPage) const;
    void reportTabUpdate(WebPageProxy&, Ref<JSON::Object>&& changeInfo);
    void resultToHostContext(HostContext&, double callID, RefPtr<JSON::Value>&& result, const String& error = { });
    // A call's result that is a tab, at the time of the call, as the calling extension sees it.
    void resultWithTab(HostContext&, double callID, WebPageProxy&);

    RefPtr<HostContext> extensionPageContext(WebFrameProxy&, Markable<WebCore::ScriptExecutionContextIdentifier> documentID, const URL& documentURL, const String& extensionKey);
    URL documentURL(WebFrameProxy&, Markable<WebCore::ScriptExecutionContextIdentifier>) const;
    void documentsDidGoAway(NOESCAPE const Function<bool(WebCore::FrameIdentifier, WebCore::ScriptExecutionContextIdentifier)>&);
    bool isEnteringBackForwardCache(const Endpoint&) const;

    HashMap<uint64_t, Ref<HostContext>> m_hostContexts;
    HashMap<const void*, uint64_t> m_hostContextByFrame;
    HashMap<String, ExtensionLoad> m_extensionLoads;
    Deque<PendingTask> m_pendingTasks;
    Deque<PendingTask> m_tasksBeingFlushed;
    bool m_isFlushingPendingTasks { false };
    bool m_pendingTasksNeedFlush { false };
    HashMap<WebCore::FrameIdentifier, uint64_t> m_hostContextByRemoteFrame;
    // The frame and URL of each document an extension context has posted from, as its web content process
    // reports them.
    HashMap<WebCore::ScriptExecutionContextIdentifier, std::pair<WebCore::FrameIdentifier, URL>> m_documents;
    // The documents with extension contexts that entered the back/forward cache, by their frames, until the
    // frame's commit of another document ends their contexts' routes.
    HashMap<WebCore::ScriptExecutionContextIdentifier, WebCore::FrameIdentifier> m_documentsEnteringBackForwardCache;
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
    // The roots of the extensions whose user content each web process holds, and the extension keys and roots
    // that makes loaded.
    HashMap<WebCore::ProcessIdentifier, Vector<URL>> m_userContentExtensionRoots;
    HashMap<String, URL> m_userContentExtensions;
    // The extensions Safari presents: their global pages, bars, popovers or user content.
    HashSet<String> m_extensionsPresentInSafari;
    // The roots each extension was moved from when Safari reloaded it, which never become its root again.
    HashMap<String, HashSet<String>> m_retiredRoots;
    HashMap<String, Vector<Function<void(const LegacyExtensions::WebsiteAccess&)>>> m_websiteAccessWaiters;
    HashMap<String, Ref<LegacyExtensionDeclarativeNetRequest>> m_declarativeNetRequests;
};

} // namespace WebKit
