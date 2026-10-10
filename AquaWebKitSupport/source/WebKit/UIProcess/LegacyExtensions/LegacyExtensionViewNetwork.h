// webRequest for the loads of Safari 7's WebKit 1 extension views: the global page, popovers and extension
// bars, which WebKit 1 loads in the Safari process. A load belongs to an extension view when the view's main
// frame shows one of the extension's pages, or is navigating to one. Its events go to the router as the
// network process's do for WebKit 2 loads, with tabId -1 and frameId naming the view's frame (0 for its main
// frame), and it waits on blocking listeners at the points LegacyLoadInterceptor names.

#pragma once

#include "LegacyExtensionWebRequest.h"
#include <WebCore/LegacyLoadInterceptor.h>
#include <WebCore/NetworkingContext.h>
#include <WebCore/ResourceError.h>
#include <WebCore/ResourceRequest.h>
#include <WebCore/ResourceResponse.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/WeakHashMap.h>
#include <wtf/WeakHashSet.h>

namespace WebCore {
class CocoaCurlResourceHandle;
class LocalFrame;
}

namespace WebKit {

class LegacyExtensionViewPing;

class LegacyExtensionViewNetwork final : public WebCore::LegacyLoadInterceptor {
public:
    static LegacyExtensionViewNetwork& singleton();

    void setListeners(const Vector<String>& observedEvents, const Vector<String>& listenerOptions, const String& blockingListeners);

private:
    friend class NeverDestroyed<LegacyExtensionViewNetwork>;
    friend class LegacyExtensionViewPing;
    friend class LegacyExtensionViewSynchronousLoad;
    LegacyExtensionViewNetwork() = default;

    // One load's webRequest state.
    struct Load : RefCounted<Load> {
        static Ref<Load> create() { return adoptRef(*new Load); }
        String requestId;
        ASCIILiteral type;
        double frameId { 0 };
        double parentFrameId { -1 };
        String documentURL;
        String initiator;
        bool isMainFrameLoad { false };
        bool isRedirected { false };
        unsigned internalRedirectCount { 0 };
        RefPtr<WebCore::NetworkingContext> networkingContext;
        URL url;
        String method;
        // The Cookie field an onBeforeSendHeaders verdict set, which is its exchange's alone.
        String editedCookie;
        WebCore::ResourceResponse response;
    };

    struct RequestVerdict {
        enum class Kind : uint8_t { Proceed, Fail, MainFrameRedirect };
        Kind kind;
        WebCore::ResourceRequest request;
        WebCore::ResourceResponse redirectResponse;
        WebCore::ResourceError error;
    };
    using RequestCompletion = CompletionHandler<void(RequestVerdict&&)>;

    struct ResponseVerdict {
        bool cancel { false };
        WebCore::ResourceResponse response;
        // Where a verdict sends the load: a redirect response's rewritten Location, or a redirectUrl.
        URL target;
    };
    using ResponseCompletion = CompletionHandler<void(ResponseVerdict&&)>;

    // LegacyLoadInterceptor.
    bool interceptStart(WebCore::ResourceLoader&) final;
    bool interceptRedirection(WebCore::ResourceLoader&, WebCore::ResourceRequest&, WebCore::ResourceResponse& redirectResponse, CompletionHandler<void(WebCore::ResourceRequest&&)>&) final;
    bool interceptResponse(WebCore::ResourceLoader&, WebCore::ResourceResponse&, CompletionHandler<void()>&) final;
    bool interceptAuthenticationChallenge(WebCore::ResourceLoader&, const WebCore::AuthenticationChallenge&) final;
    void loaderDidFinish(WebCore::ResourceLoader&) final;
    void loaderDidFail(WebCore::ResourceLoader&, const WebCore::ResourceError&) final;
    bool holdsReceivedCookies(const WebCore::ResourceHandle&) final;
    RefPtr<WebCore::LegacyLoadInterceptor::Load> pingLoad(WebCore::LocalFrame&, const WebCore::ResourceRequest&, const WebCore::FetchOptions&) final;
    RefPtr<WebCore::LegacyLoadInterceptor::SynchronousLoad> willLoadSynchronously(WebCore::FrameLoader&, const WebCore::ResourceRequest&, const WebCore::FetchOptions&) final;
    bool interceptWebSocket(WebCore::Document&, const URL&, CompletionHandler<void(bool)>&&) final;

    RefPtr<Load> createLoad(WebCore::LocalFrame*, const WebCore::ResourceRequest&, WebCore::FetchOptions::Destination, bool isMainFrameLoad, String&& requestId);
    Ref<JSON::Object> details(const Load&) const;
    Ref<JSON::Object> responseDetails(const Load&, const WebCore::ResourceResponse&) const;
    String generatedCookie(const Load&, const WebCore::ResourceRequest&) const;

    void notify(ASCIILiteral eventName, Ref<JSON::Object>&& details);
    void dispatch(ASCIILiteral eventName, Ref<JSON::Object>&& details, CompletionHandler<void(RefPtr<JSON::Object>&&)>&&);

    // onBeforeRedirect for a redirect's request, then the request's onBeforeRequest, onBeforeSendHeaders and
    // onSendHeaders.
    void willSendRequest(Ref<Load>&&, WebCore::ResourceRequest&&, const WebCore::ResourceResponse& redirectResponse, RequestCompletion&&);
    void beforeRequest(Ref<Load>&&, WebCore::ResourceRequest&&, RequestCompletion&&);
    void beforeSendHeaders(Ref<Load>&&, WebCore::ResourceRequest&&, RequestCompletion&&);
    // onHeadersReceived for a response, or a redirect response. The response's held Set-Cookie fields are
    // stored or discarded with the verdict.
    void headersReceived(Ref<Load>&&, WebCore::ResourceResponse&&, RefPtr<WebCore::CocoaCurlResourceHandle>&&, bool isRedirect, ResponseCompletion&&);
    void responseStarted(Load&, const WebCore::ResourceResponse&);
    void completed(Load&, const WebCore::ResourceResponse&, const WebCore::ResourceError&);

    void continueStart(WebCore::ResourceLoader&, Ref<Load>&&, RequestVerdict&&);
    void followRedirect(WebCore::ResourceLoader&, Ref<Load>&&, WebCore::ResourceRequest&&, WebCore::ResourceResponse&& redirectResponse, CompletionHandler<void(WebCore::ResourceRequest&&)>&&);
    void redirectInPlace(WebCore::ResourceLoader&, Load&, const WebCore::ResourceResponse& redirectResponse, const URL&);
    void restart(WebCore::ResourceLoader&);

    LegacyExtensions::WebRequestListeners m_listeners;
    WeakHashMap<WebCore::ResourceLoader, Ref<Load>> m_loads;
    // The loaders entering start() again with the request their webRequest steps approved.
    WeakHashSet<WebCore::ResourceLoader> m_resumingStarts;
    WeakHashSet<WebCore::ResourceLoader> m_resumingChallenges;
    WeakHashSet<LegacyExtensionViewPing> m_pings;
    uint64_t m_nextIdentifier { 1 };
};

} // namespace WebKit
