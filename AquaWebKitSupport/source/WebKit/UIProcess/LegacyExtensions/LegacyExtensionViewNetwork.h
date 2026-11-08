// webRequest for the loads of Safari 7's WebKit 1 extension views: the global page, popovers and extension
// bars, which WebKit 1 loads in the Safari process. A load belongs to an extension view when the view's main
// frame shows one of the extension's pages, or is navigating to one. Its events go to the router as the
// network process's do for WebKit 2 loads, with tabId -1 and frameId naming the view's frame (0 for its main
// frame), and it waits on blocking listeners at the points LegacyLoadInterceptor names. The StreamFilters of
// webRequest.filterResponseData read a load's body in place of its loader, which receives their output.

#pragma once

#include "LegacyExtensionFilteredMultipart.h"
#include "LegacyExtensionResponseFilter.h"
#include "LegacyExtensionWebRequest.h"
#include <WebCore/CocoaCurlProxyConfiguration.h>
#include <WebCore/LegacyLoadInterceptor.h>
#include <WebCore/NetworkLoadMetrics.h>
#include <WebCore/NetworkingContext.h>
#include <WebCore/ResourceError.h>
#include <WebCore/ResourceRequest.h>
#include <WebCore/ResourceResponse.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/WeakHashMap.h>
#include <wtf/WeakHashSet.h>

namespace WebCore {
class CocoaCurlResourceHandle;
class SecurityOrigin;
class LocalFrame;
}

namespace WebKit {

class LegacyExtensionViewDetachedLoad;
class LegacyExtensionViewPing;

class LegacyExtensionViewNetwork final : public WebCore::LegacyLoadInterceptor {
public:
    static LegacyExtensionViewNetwork& singleton();

    void setListeners(const Vector<String>& observedEvents, const Vector<String>& listenerOptions, const String& blockingListeners);

    // webRequest.filterResponseData. A filter attaches to the ResourceLoader load whose requestId it names, when
    // the extension sees the load and its loader has received none of the body; its events go to
    // LegacyExtensionHost::dispatchResponseFilterEvent.
    void createResponseFilter(uint64_t filterID, const String& requestID, const String& extensionKey, const LegacyExtensions::WebsiteAccess*);
    void writeResponseFilter(uint64_t filterID, Ref<WebCore::SharedBuffer>&&, uint64_t dispatched);
    void closeResponseFilter(uint64_t filterID);
    void disconnectResponseFilter(uint64_t filterID, uint64_t dispatched);
    void suspendResponseFilter(uint64_t filterID);
    void resumeResponseFilter(uint64_t filterID);

private:
    friend class NeverDestroyed<LegacyExtensionViewNetwork>;
    friend class LegacyExtensionViewDetachedLoad;
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
        RefPtr<WebCore::SecurityOrigin> sourceOrigin;
        bool isMainFrameLoad { false };
        bool isRedirected { false };
        unsigned internalRedirectCount { 0 };
        RefPtr<WebCore::NetworkingContext> networkingContext;
        URL url;
        String method;
        // The Cookie field an onBeforeSendHeaders verdict set, which is its exchange's alone.
        String editedCookie;
        // The proxy.onRequest answers for the load's latest request, and the request's URL.
        URL proxyAnswersURL;
        Vector<WebCore::CocoaCurlProxyFilterResult> proxyFilterResults;
        WebCore::ResourceResponse response;
        // Whether the loader has received some of the body, which no filter can attach to any more.
        bool hasDeliveredBody { false };
    };

    // The StreamFilters of one load. Their output reaches the loader in tasks of the main run loop, as the
    // network's data does, and waits while the loader defers its load. The end of their output finishes the
    // load, with the network's metrics when the network finished first.
    struct FilteredResponse : RefCounted<FilteredResponse>, CanMakeWeakPtr<FilteredResponse> {
        static Ref<FilteredResponse> create() { return adoptRef(*new FilteredResponse); }
        WeakPtr<WebCore::ResourceLoader> loader;
        RefPtr<LegacyExtensionResponseFilter> filter;
        // Whether the response the loader receives has been seen, and for a multipart response, what splits the
        // filters' output into its parts.
        bool hasResponse { false };
        RefPtr<LegacyExtensionFilteredMultipart> multipart;
        bool inputFinished { false };
        std::optional<WebCore::NetworkLoadMetrics> metrics;
        // The network's encoded bytes the loader has not been told of, unless the network does not count them.
        long long pendingEncodedDataLength { 0 };
        bool encodedDataLengthIsKnown { true };
        // Output not yet delivered: chunks, then null for the end.
        Deque<RefPtr<WebCore::SharedBuffer>> output;
        // The parts split from a multipart response's output, not yet delivered: a part's response, which the parts
        // after it wait on, a chunk of a part's body, or the end of the parts with its error.
        struct Part {
            std::optional<WebCore::ResourceResponse> response;
            CompletionHandler<void(bool)> proceed;
            RefPtr<WebCore::SharedBuffer> data;
            std::optional<WebCore::ResourceError> end;
        };
        Deque<Part> parts;
        bool isDeliveryScheduled { false };
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
    bool needsStorageConnection(WebCore::ResourceLoader&, const WebCore::ResourceRequest&) const;
    bool interceptStart(WebCore::ResourceLoader&) final;
    bool interceptRedirection(WebCore::ResourceLoader&, WebCore::ResourceRequest&, WebCore::ResourceResponse& redirectResponse, CompletionHandler<void(WebCore::ResourceRequest&&)>&) final;
    bool interceptResponse(WebCore::ResourceLoader&, WebCore::ResourceResponse&, CompletionHandler<void()>&) final;
    bool interceptResponseHeaders(WebCore::ResourceLoader&, WebCore::ResourceResponse&, CompletionHandler<void()>&);
    void responseWillReachLoader(WebCore::ResourceLoader&, const WebCore::ResourceResponse&);
    bool interceptAuthenticationChallenge(WebCore::ResourceLoader&, const WebCore::AuthenticationChallenge&) final;
    bool interceptResponseData(WebCore::ResourceLoader&, const WebCore::FragmentedSharedBuffer&, long long encodedDataLength) final;
    bool interceptFinish(WebCore::ResourceLoader&, const WebCore::NetworkLoadMetrics&) final;
    void loaderDidResume(WebCore::ResourceLoader&) final;
    void loaderDidFail(WebCore::ResourceLoader&, const WebCore::ResourceError&) final;
    bool holdsReceivedCookies(const WebCore::ResourceHandle&) final;
    Vector<WebCore::CocoaCurlProxyFilterResult> proxyFilterResults(const WebCore::ResourceHandle&, const URL&) final;
    bool hasProxyFilters() const final { return m_listeners.observes(LegacyExtensions::proxyOnRequest); }
    bool allowsNetworkPrediction() const final;
    bool refusesPing(const WebCore::ResourceRequest&) const final;
    RefPtr<WebCore::LegacyLoadInterceptor::Load> pingLoad(WebCore::LocalFrame&, const WebCore::ResourceRequest&, const WebCore::FetchOptions&) final;
    RefPtr<WebCore::LegacyLoadInterceptor::SynchronousLoad> willLoadSynchronously(WebCore::FrameLoader&, const WebCore::ResourceRequest&, const WebCore::FetchOptions&) final;
    bool interceptWebSocket(WebCore::Document&, const URL&, CompletionHandler<void(bool, Vector<WebCore::CocoaCurlProxyFilterResult>&&, RefPtr<WebCore::LegacyWebSocketHandshake>&&)>&&) final;

    RefPtr<Load> createLoad(WebCore::LocalFrame*, const WebCore::ResourceRequest&, WebCore::FetchOptions::Destination, bool isMainFrameLoad, String&& requestId);
    Ref<JSON::Object> details(const Load&) const;
    Ref<JSON::Object> responseDetails(const Load&, const WebCore::ResourceResponse&) const;
    String generatedCookie(const Load&, const WebCore::ResourceRequest&) const;

    void notify(ASCIILiteral eventName, Ref<JSON::Object>&& details);
    void dispatch(ASCIILiteral eventName, Ref<JSON::Object>&& details, CompletionHandler<void(RefPtr<JSON::Object>&&)>&&);

    // onBeforeRedirect for a redirect's request, then the request's onBeforeRequest, onBeforeSendHeaders and
    // onSendHeaders.
    void willSendRequest(Ref<Load>&&, WebCore::ResourceRequest&&, const WebCore::ResourceResponse& redirectResponse, RequestCompletion&&);
    // proxy.onRequest, before the request's webRequest events.
    void proxyRequest(Ref<Load>&&, WebCore::ResourceRequest&&, RequestCompletion&&);
    // Firefox's proxy.RequestDetails, or null when no proxy.onRequest listener answers for the request.
    RefPtr<JSON::Object> proxyRequestDetails(const Load&, const WebCore::ResourceRequest&);
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

    RefPtr<FilteredResponse> filteredResponse(uint64_t filterID) const { return m_responseFilters.get(filterID); }
    void outputFilteredResponse(FilteredResponse&, RefPtr<WebCore::SharedBuffer>&&);
    void scheduleFilteredOutputDelivery(FilteredResponse&);
    void deliverFilteredOutput(FilteredResponse&);
    void finishFilteredLoad(FilteredResponse&, WebCore::ResourceLoader&);
    LegacyExtensionMultipartSplit splitFilteredMultipart(FilteredResponse&, WebCore::ResourceLoader&, const WebCore::ResourceResponse&);
    void queueFilteredPart(FilteredResponse&, FilteredResponse::Part&&);
    void discardFilteredOutput(FilteredResponse&);
    static long long takeEncodedDataLength(FilteredResponse&);
    void removeFilteredResponse(FilteredResponse&);

    LegacyExtensions::WebRequestListeners m_listeners;
    WeakHashMap<WebCore::ResourceLoader, Ref<Load>> m_loads;
    // The loaders entering start() again with the request their webRequest steps approved.
    WeakHashSet<WebCore::ResourceLoader> m_resumingStarts;
    WeakHashSet<WebCore::ResourceLoader> m_resumingChallenges;
    WeakHashSet<LegacyExtensionViewPing> m_pings;
    WeakHashMap<WebCore::ResourceLoader, Ref<FilteredResponse>> m_filteredResponses;
    // Each filter's load.
    HashMap<uint64_t, Ref<FilteredResponse>> m_responseFilters;
    HashSet<Ref<LegacyExtensionViewDetachedLoad>> m_detachedLoads;
    uint64_t m_nextIdentifier { 1 };
};

} // namespace WebKit
