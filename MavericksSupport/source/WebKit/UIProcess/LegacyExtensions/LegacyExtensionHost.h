// The UI-process router of the `browser` namespace WebKit gives Safari 7 legacy extensions.
//
// Safari 7 hosts an extension's global page and toolbar popovers in WebKit 1 views in its own process,
// and extension pages opened in tabs or frames in web content processes; with content scripts, which run
// in web content processes too, they are the extension's contexts. The router connects them: runtime
// ports and one-shot messages between contexts, the tabs/webNavigation/webRequest events and methods and
// the clipboard extension pages use, and the webRequest verdicts network processes wait on. Tabs are
// WebPageProxy identifiers and frames are FrameIdentifiers, with 0 standing for a tab's main frame as in
// the WebExtensions API.

#pragma once

#include "MessageReceiver.h"
#include <JavaScriptCore/Weak.h>
#include <WebCore/FrameIdentifier.h>
#include <WebCore/FrameLoaderTypes.h>
#include <WebCore/ScriptExecutionContextIdentifier.h>
#include <wtf/CompletionHandler.h>
#include <wtf/HashMap.h>
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

namespace API {
class Navigation;
}

namespace WebKit {

class NetworkProcessProxy;
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
    void didFinishDocumentLoad(WebPageProxy&, WebFrameProxy&);
    void didCreateNavigationTarget(WebPageProxy& sourcePage, WebCore::FrameIdentifier sourceFrameID, WebPageProxy& newPage, const URL&);
    void didDestroyFrame(WebCore::FrameIdentifier);

    void didReceiveMessage(IPC::Connection&, IPC::Decoder&) final;

    void dispatchWebRequestEvent(const String& eventName, const String& details, CompletionHandler<void(String&&)>&&);

    // WebKit 1 host contexts.
    void didClearWindowObject(const void* frame, JSC::JSGlobalObject&, const URL& documentURL);
    void frameWillBeDestroyed(const void* frame);
    void postFromHostContext(uint64_t hostContextIdentifier, const String& message);

private:
    friend class NeverDestroyed<LegacyExtensionHost>;
    LegacyExtensionHost();

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
        // The document's Document::originIdentifierForPasteboard, as its web content process reports it.
        String pasteboardOriginIdentifier;
        // Each event a listener is registered for, with the JSON filters of its blocking listeners.
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

    void post(IPC::Connection&, WebCore::FrameIdentifier, WebCore::ScriptExecutionContextIdentifier, URL&& documentURL, String&& pasteboardOriginIdentifier, String&& extensionKey, String&& message);

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
    bool deliver(const Endpoint&, const String& extensionKey, const String& message);
    Ref<JSON::Object> senderDescription(const Endpoint&) const;
    void endpointDidGoAway(const Endpoint&);
    void endpointsDidGoAway(NOESCAPE const Function<bool(const Endpoint&)>&);
    void hostContextDidGoAway(HostContext&);
    void framesDidGoAway(const Vector<WebCore::FrameIdentifier>&);
    void finishRouterCallIfComplete(uint64_t);
    void finishWebRequestCallIfComplete(uint64_t);
    void dispatchEvent(const String& eventName, Ref<JSON::Array>&& arguments);
    void updateNetworkListeners();
    void sendNetworkListeners(NetworkProcessProxy&);

    Ref<JSON::Object> tabDescription(WebPageProxy&) const;
    void resultToHostContext(HostContext&, double callID, RefPtr<JSON::Value>&& result, const String& error = { });

    String pasteboardOriginIdentifier(const HostContext&) const;
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
    // The transition that first committed each main-frame history item, which going back or forward to it reports.
    WeakHashMap<WebBackForwardListItem, String> m_historyItemTransitions;
    uint64_t m_nextIdentifier { 1 };
    Vector<String> m_observedNetworkEvents;
    String m_blockingNetworkListeners;
    LegacyExtensionNetworkProxy m_networkProxy;
};

} // namespace WebKit
