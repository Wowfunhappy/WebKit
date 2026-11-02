#include "config.h"
#include "LegacyExtensionNetwork.h"

#include "AuthenticationChallengeDisposition.h"
#include "Decoder.h"
#include "LegacyExtensionErrors.h"
#include "LegacyExtensionNetworkMessages.h"
#include "LegacyExtensionNetworkProxyMessages.h"
#include "LegacyExtensionScheme.h"
#include "MessageNames.h"
#include "MessageSenderInlines.h"
#include "NetworkCache.h"
#include "NetworkCacheEntry.h"
#include "NetworkConnectionToWebProcess.h"
#include "NetworkDataTaskCurlCocoa.h"
#include "NetworkLoad.h"
#include "NetworkProcess.h"
#include "NetworkResourceLoader.h"
#include "NetworkSession.h"
#include "ServiceWorkerNavigationPreloader.h"
#include "ServiceWorkerSoftUpdateLoader.h"
#include "SharedBufferReference.h"
#include "WebErrors.h"
#include "WebResourceLoaderMessages.h"
#include "WebSocketChannelMessages.h"
#include <WebCore/AuthenticationChallenge.h>
#include <WebCore/ClientOrigin.h>
#include <WebCore/Credential.h>
#include <WebCore/FrameLoaderTypes.h>
#include <WebCore/CocoaCookie.h>
#include <WebCore/CocoaCurlResourceRequest.h>
#include <WebCore/CookieJar.h>
#include <WebCore/HTTPHeaderMap.h>
#include <WebCore/HTTPStatusCodes.h>
#include <WebCore/ResourceError.h>
#include <WebCore/ResourceRequest.h>
#include <WebCore/ResourceResponse.h>
#include <WebCore/NetworkStorageSession.h>
#include <WebCore/RegistrableDomain.h>
#include <WebCore/SecurityOrigin.h>
#include <WebCore/SecurityPolicy.h>
#include <WebCore/SharedBuffer.h>
#include <wtf/ProcessID.h>
#include <wtf/cocoa/RuntimeApplicationChecksCocoa.h>
#include <wtf/RunLoop.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringToIntegerConversion.h>

namespace WebKit {

using namespace WebCore;
using namespace LegacyExtensions;

// The document a request is made for: a frame's navigation is made for its parent's document.
static URL documentURLForLoad(const NetworkResourceLoadParameters& parameters, ASCIILiteral type)
{
    if (type == "main_frame"_s)
        return { };
    if (type == "sub_frame"_s)
        return parameters.parentFrameURL;
    return parameters.documentURL;
}

// A redirect's request moved to another target by an onHeadersReceived verdict, rebuilt from the redirected
// request as a redirect to the target is: WebCore's redirectedRequest, with what the network task and
// NetworkResourceLoader carry across a redirect applied again for the new target.
static ResourceRequest retargetedRedirectRequest(const ResourceRequest& request, const ResourceRequest& redirectRequest, const ResourceResponse& redirectResponse, bool shouldClearReferrerOnHTTPSToHTTPRedirect, bool isMainFrameLoad)
{
    auto& redirectedRequest = request.isNull() ? redirectRequest : request;
    auto retargeted = redirectedRequest.redirectedRequest(redirectResponse, shouldClearReferrerOnHTTPSToHTTPRedirect);
    auto& target = retargeted.url();
    auto source = SecurityOrigin::create(redirectResponse.url());
    retargeted.setFirstPartyForCookies(isMainFrameLoad ? URL { target } : URL { redirectRequest.firstPartyForCookies() });
    retargeted.setIsSameSite(redirectRequest.isSameSite() && SecurityOrigin::create(target)->isSameSiteAs(source));
    if (!SecurityOrigin::create(target)->isSameOriginAs(source.get()))
        removeCocoaCurlRequestHeader(retargeted, HTTPHeaderName::Cookie);
    if (auto authorization = redirectedRequest.httpHeaderField(HTTPHeaderName::Authorization); !authorization.isNull()
        && linkedOnOrAfterSDKWithBehavior(SDKAlignedBehavior::AuthorizationHeaderOnSameOriginRedirects)
        && protocolHostAndPortAreEqual(redirectedRequest.url(), target))
        retargeted.setHTTPHeaderField(HTTPHeaderName::Authorization, authorization);
    return retargeted;
}

LegacyExtensionNetwork& LegacyExtensionNetwork::singleton()
{
    static NeverDestroyed<LegacyExtensionNetwork> network;
    return network;
}

// Each connection contributes the entries held by its injected bundle's process-local SecurityPolicy.
void LegacyExtensionNetwork::addOriginAccessAllowListEntry(NetworkConnectionToWebProcess& connection, const String& sourceOrigin, const String& protocol, const String& host, bool subdomains)
{
    Ref origin = SecurityOrigin::createFromString(sourceOrigin);
    if (origin->isOpaque())
        return;
    auto& grants = m_originAccessGrants.ensure(&connection, [] { return Vector<OriginAccessGrant> { }; }).iterator->value;
    grants.append({ origin->toString(), protocol.convertToASCIILowercase(), host.convertToASCIILowercase(), subdomains });
    SecurityPolicy::addOriginAccessAllowlistEntry(origin, protocol, host, subdomains);
}

void LegacyExtensionNetwork::removeOriginAccessAllowListEntry(NetworkConnectionToWebProcess& connection, const String& sourceOrigin, const String& protocol, const String& host, bool subdomains)
{
    Ref origin = SecurityOrigin::createFromString(sourceOrigin);
    if (origin->isOpaque())
        return;
    auto iterator = m_originAccessGrants.find(&connection);
    if (iterator == m_originAccessGrants.end() || !iterator->value.removeFirst(OriginAccessGrant { origin->toString(), protocol.convertToASCIILowercase(), host.convertToASCIILowercase(), subdomains }))
        return;
    SecurityPolicy::removeOriginAccessAllowlistEntry(origin, protocol, host, subdomains);
    if (iterator->value.isEmpty())
        m_originAccessGrants.remove(iterator);
}

void LegacyExtensionNetwork::resetOriginAccessAllowLists(NetworkConnectionToWebProcess& connection)
{
    for (auto& grant : m_originAccessGrants.take(&connection))
        SecurityPolicy::removeOriginAccessAllowlistEntry(SecurityOrigin::createFromString(grant.sourceOrigin), grant.destinationProtocol, grant.destinationHost, grant.allowDestinationSubdomains);
}

void LegacyExtensionNetwork::initialize(NetworkProcess& networkProcess)
{
    LegacyExtensions::registerExtensionScheme();
    m_networkProcess = networkProcess;
    networkProcess.addMessageReceiver(Messages::LegacyExtensionNetwork::messageReceiverName(), *this);
    CocoaCurlProxyConfiguration::setErrorObserver([this](bool fatal, const String& error, const String& details) {
        auto event = JSON::Object::create();
        event->setBoolean("fatal"_s, fatal);
        event->setString("error"_s, error);
        event->setString("details"_s, details);
        notify(proxyOnProxyError, event->toJSONString());
    });
}

void LegacyExtensionNetwork::setProxyConfiguration(String&& configuration)
{
    CocoaCurlProxyConfiguration::setCurrent(configuration.isEmpty() ? nullptr : CocoaCurlProxyConfiguration::create(configuration));
}

Vector<CocoaCurlProxyFilterResult> LegacyExtensionNetwork::proxyFilterResults(NetworkDataTaskCurlCocoa& task, const URL& url)
{
    if (m_proxyAnswers.isEmptyIgnoringNullReferences() && m_clientLoads.isEmptyIgnoringNullReferences())
        return { };
    for (auto& loader : m_loaders) {
        RefPtr networkLoad = loader.m_networkLoad;
        if (!networkLoad || networkLoad->m_task.get() != &task)
            continue;
        RefPtr checker = loader.m_networkLoadChecker;
        auto iterator = checker ? m_proxyAnswers.find(*checker) : m_proxyAnswers.end();
        if (iterator == m_proxyAnswers.end() || !equalIgnoringFragmentIdentifier(iterator->value.url, url))
            return { };
        return iterator->value.results;
    }
    for (auto entry : m_clientLoads) {
        RefPtr networkLoad = clientNetworkLoad(entry.key, entry.value);
        if (!networkLoad || networkLoad->m_task.get() != &task)
            continue;
        auto& answers = entry.value->proxyAnswers;
        if (!answers || !equalIgnoringFragmentIdentifier(answers->url, url))
            return { };
        return answers->results;
    }
    for (auto entry : m_pingTasks) {
        if (entry.value.get().get() != &task)
            continue;
        auto iterator = m_proxyAnswers.find(entry.key);
        if (iterator == m_proxyAnswers.end() || !equalIgnoringFragmentIdentifier(iterator->value.url, url))
            return { };
        return iterator->value.results;
    }
    return { };
}

void LegacyExtensionNetwork::didCreatePingTask(NetworkLoadChecker& checker, NetworkDataTask& task)
{
    if (observes(proxyOnRequest))
        m_pingTasks.set(checker, ThreadSafeWeakPtr { task });
}

void LegacyExtensionNetwork::notify(ASCIILiteral eventName, const String& details)
{
    if (RefPtr networkProcess = m_networkProcess.get())
        networkProcess->parentProcessConnection()->send(Messages::LegacyExtensionNetworkProxy::DispatchEvent(String { eventName }, details), 0);
}

void LegacyExtensionNetwork::dispatch(ASCIILiteral eventName, const String& details, CompletionHandler<void(RefPtr<JSON::Object>&&)>&& completionHandler)
{
    RefPtr networkProcess = m_networkProcess.get();
    if (!networkProcess)
        return completionHandler(nullptr);
    networkProcess->parentProcessConnection()->sendWithAsyncReply(Messages::LegacyExtensionNetworkProxy::DispatchBlockingEvent(String { eventName }, details), [completionHandler = WTF::move(completionHandler)](String&& response) mutable {
        auto value = JSON::Value::parseJSON(response);
        completionHandler(value ? value->asObject() : nullptr);
    });
}

// The <n> of a load's requestId: its loader's identifier, or a fresh one for a request a load starts after a service
// worker took an earlier one, which has its own lifecycle.
uint64_t LegacyExtensionNetwork::loadRequestIdentifier(NetworkResourceLoader& loader) const
{
    if (auto identifier = m_restartedRequestIdentifiers.get(loader))
        return identifier;
    return loader.identifier().toUInt64();
}

String LegacyExtensionNetwork::requestIdentifier(NetworkLoadChecker& checker)
{
    uint64_t identifier;
    if (RefPtr loader = checker.m_networkResourceLoader.get())
        identifier = loadRequestIdentifier(*loader);
    else {
        identifier = m_checkerRequestIdentifiers.ensure(checker, [&] {
            return m_nextRequestIdentifier++;
        }).iterator->value;
        return makeString(getCurrentProcessID(), "-ping-"_s, identifier);
    }
    return makeString(getCurrentProcessID(), '-', identifier);
}

static SecurityOrigin* requestSourceOrigin(const NetworkResourceLoadParameters& parameters)
{
    return parameters.navigationRequester ? parameters.navigationRequester->securityOrigin.ptr() : parameters.sourceOrigin.get();
}

// A service worker's script belongs to its registration, not to the frame that registers or updates it, as Chrome
// reports it: no tab, no frame and no document.
static void detachServiceWorkerScript(JSON::Object& details, FetchOptions::Destination destination)
{
    if (destination != FetchOptions::Destination::Serviceworker)
        return;
    details.setDouble("tabId"_s, -1);
    details.setDouble("frameId"_s, -1);
    details.setDouble("parentFrameId"_s, -1);
    details.remove("documentUrl"_s);
}

Ref<JSON::Object> LegacyExtensionNetwork::requestDetails(NetworkLoadChecker& checker, const ResourceRequest& request)
{
    RefPtr loader = checker.m_networkResourceLoader.get();
    bool isMainFrameLoad = checker.m_requestLoadType == NetworkLoadChecker::LoadType::MainFrame;

    auto type = resourceType(request, checker.m_options.destination, isMainFrameLoad);
    auto details = JSON::Object::create();
    details->setString("requestId"_s, requestIdentifier(checker));
    details->setString("url"_s, request.url().string());
    details->setString("method"_s, request.httpMethod());
    details->setString("type"_s, type);
    details->setDouble("timeStamp"_s, timeStamp());
    details->setDouble("tabId"_s, checker.m_webPageProxyID ? static_cast<double>(checker.m_webPageProxyID->toUInt64()) : 0);
    if (loader) {
        auto& parameters = loader->parameters();
        details->setDouble("frameId"_s, static_cast<double>(parameters.webFrameID.toUInt64()));
        details->setDouble("parentFrameId"_s, parameters.parentFrameID ? static_cast<double>(parameters.parentFrameID->toUInt64()) : 0);
        if (auto documentURL = documentURLForLoad(parameters, type); !documentURL.isEmpty())
            details->setString("documentUrl"_s, documentURL.string());
    } else if (!checker.m_frameURL.isEmpty())
        details->setString("documentUrl"_s, checker.m_frameURL.string());
    if (RefPtr origin = loader && loader->parameters().navigationRequester ? requestSourceOrigin(loader->parameters()) : checker.origin(); origin && !isMainFrameLoad)
        details->setString("initiator"_s, origin->toString());
    detachServiceWorkerScript(details, checker.m_options.destination);
    return details;
}

Ref<JSON::Object> LegacyExtensionNetwork::loaderDetails(NetworkResourceLoader& loader)
{
    auto& parameters = loader.parameters();
    auto& request = loader.originalRequest();
    auto details = JSON::Object::create();
    details->setString("requestId"_s, makeString(getCurrentProcessID(), '-', loadRequestIdentifier(loader)));
    details->setString("url"_s, currentURL(loader).string());
    details->setString("method"_s, request.httpMethod());
    details->setString("type"_s, resourceType(request, parameters.options.destination, loader.isMainFrameLoad()));
    details->setDouble("timeStamp"_s, timeStamp());
    details->setDouble("tabId"_s, static_cast<double>(parameters.webPageProxyID.toUInt64()));
    details->setDouble("frameId"_s, static_cast<double>(parameters.webFrameID.toUInt64()));
    details->setDouble("parentFrameId"_s, parameters.parentFrameID ? static_cast<double>(parameters.parentFrameID->toUInt64()) : 0);
    if (!loader.isMainFrameLoad()) {
        if (auto documentURL = documentURLForLoad(parameters, resourceType(request, parameters.options.destination, false)); !documentURL.isEmpty())
            details->setString("documentUrl"_s, documentURL.string());
        if (RefPtr origin = requestSourceOrigin(parameters))
            details->setString("initiator"_s, origin->toString());
    }
    detachServiceWorkerScript(details, parameters.options.destination);
    return details;
}

Ref<JSON::Object> LegacyExtensionNetwork::responseDetails(NetworkResourceLoader& loader, const ResourceResponse& response, bool fromCache)
{
    auto details = loaderDetails(loader);
    details->setString("url"_s, response.url().string());
    addResponseFields(details, response);
    details->setBoolean("fromCache"_s, fromCache);
    return details;
}

RefPtr<NetworkDataTaskCurlCocoa> LegacyExtensionNetwork::curlTask(NetworkResourceLoader& loader)
{
    RefPtr networkLoad = loader.m_networkLoad;
    CheckedPtr session = networkLoad ? loader.connectionToWebProcess().networkSession() : nullptr;
    if (!session || !NetworkDataTaskCurlCocoa::canHandle(*session, networkLoad->parameters()))
        return nullptr;
    return static_cast<NetworkDataTaskCurlCocoa*>(networkLoad->m_task.get());
}

// The Cookie field the network task generates for a request, which "extraHeaders" listeners see: a redirect's
// task answers for its next exchange while the load continues on it; a load an extension's redirect restarts
// gets a new task.
String LegacyExtensionNetwork::cookieHeader(NetworkLoadChecker& checker, const ResourceRequest& request)
{
    RefPtr loader = checker.m_networkResourceLoader.get();
    RefPtr networkLoad = loader ? loader->m_networkLoad : nullptr;
    if (RefPtr task = networkLoad && networkLoad->m_client ? curlTask(*loader) : nullptr)
        return task->cookieHeader(request);
    RefPtr networkProcess = m_networkProcess.get();
    CheckedPtr session = networkProcess ? networkProcess->networkSession(checker.m_sessionID) : nullptr;
    if (!session)
        return { };
    std::optional<FrameIdentifier> frameID;
    std::optional<PageIdentifier> pageID;
    if (loader) {
        frameID = loader->parameters().webFrameID;
        pageID = loader->parameters().webPageID;
    }
    return NetworkDataTaskCurlCocoa::cookieHeader(*session, request, loader ? requestSourceOrigin(loader->parameters()) : checker.origin(), frameID, pageID, checker.m_webPageProxyID ? std::optional { *checker.m_webPageProxyID } : std::nullopt, checker.storedCredentialsPolicy());
}

// The request a web process approves after a redirect; true when it goes where the load's latest redirect,
// one an extension made, sent it, which Chrome lets be any scheme. A navigation's internal redirect comes back without its body:
// a request still going to the redirect's URL with its method sends the redirect's body.
bool LegacyExtensionNetwork::continueWillSendRequest(NetworkResourceLoader& loader, ResourceRequest& request)
{
    RefPtr checker = loader.m_networkLoadChecker;
    if (!checker)
        return false;
    // A navigation's request can come back here more than once, after its service worker registrations load.
    bool isExtensionRedirect = m_extensionRedirectTargets.get(*checker) == request.url();
    auto redirect = m_internalRedirectBodies.take(*checker);
    if (redirect.body && !request.httpBody() && request.url() == redirect.url && request.httpMethod() == redirect.method)
        request.setHTTPBody(WTF::move(redirect.body));
    return isExtensionRedirect;
}

// A request the extensions saw ends as aborted when a service worker takes it, and its StreamFilters fail, before
// any of the service worker's answer reaches the page. Nothing of that answer is reported, as nothing is for a
// request a service worker takes from the start; a request it leaves to the network starts the load's events again.
void LegacyExtensionNetwork::serviceWorkerWillHandle(NetworkResourceLoader& loader)
{
    if (!m_loaders.remove(loader))
        return;
    // The request's URL, which the checker took from the request the web process approved.
    RefPtr checker = loader.m_networkLoadChecker;
    auto url = checker ? checker->m_url : currentURL(loader);
    m_takenRequests.add(loader);
    if (RefPtr response = m_filteredResponses.get(loadRequestIdentifier(loader))) {
        response->filter->fail("The response came from a service worker."_s);
        removeFilteredResponse(*response);
    }
    m_loadErrors.remove(loader);
    m_loadersWithDeliveredBody.remove(loader);
    if (!observes(onErrorOccurred) || !isInterceptable(url))
        return;
    auto details = loaderDetails(loader);
    details->setString("url"_s, url.string());
    details->setBoolean("fromCache"_s, false);
    details->setString("error"_s, "net::ERR_ABORTED"_s);
    notify(onErrorOccurred, details->toJSONString());
}

// The checks of NetworkLoadChecker::checkRequest do not apply to the request a service worker leaves to the network,
// as upstream sends it there unchecked; the extensions' verdicts do. A request a verdict changes is checked as any
// other request is.
bool LegacyExtensionNetwork::interceptServiceWorkerFallback(NetworkResourceLoader& loader, ResourceRequest& request)
{
    RefPtr checker = loader.m_networkLoadChecker;
    // A request the extensions saw that no service worker took was decided when it was checked.
    if (!checker || m_listeners.isEmpty() || m_loaders.contains(loader))
        return false;
    m_uncheckedRequests.add(*checker);
    NetworkLoadChecker::ValidationHandler handler = [this, weakLoader = WeakPtr { loader }](NetworkLoadChecker::RequestOrRedirectionTripletOrError&& result) {
        RefPtr loader = weakLoader.get();
        if (RefPtr checker = loader ? loader->m_networkLoadChecker : nullptr)
            m_uncheckedRequests.remove(*checker);
        if (!loader)
            return;
        WTF::switchOn(result,
            [&](ResourceError& error) {
                if (!error.isCancellation())
                    loader->didFailLoading(error);
            },
            [&](NetworkLoadChecker::RedirectionTriplet& triplet) {
                loader->m_isWaitingContinueWillSendRequestForCachedRedirect = true;
                loader->willSendRedirectedRequest(WTF::move(triplet.request), WTF::move(triplet.redirectRequest), WTF::move(triplet.redirectResponse), [](auto) { });
            },
            [&](ResourceRequest& request) {
                loader->restartNetworkLoad(WTF::move(request), [](auto) { });
            });
    };
    if (!interceptRequest(*checker, request, &loader, handler))
        handler(WTF::move(request));
    return true;
}

// A blocking listener's verdict lets a request on: through the rest of the checker's checks, or to the network.
void LegacyExtensionNetwork::continueRequest(NetworkLoadChecker& checker, ResourceRequest&& request, ContentSecurityPolicyClient* client, NetworkLoadChecker::ValidationHandler&& handler)
{
    if (m_uncheckedRequests.contains(checker))
        return handler(WTF::move(request));
    m_resumingRequests.add(checker);
    checker.checkRequest(WTF::move(request), client, WTF::move(handler));
}

// WebKit fails a subresource's redirect to a data: URL, which only a document's load decodes itself.
bool LegacyExtensionNetwork::loadsInPlace(NetworkResourceLoader& loader, const URL& url)
{
    return url.protocolIsData() && !loader.isMainFrameLoad() && loader.parameters().options.destination != FetchOptions::Destination::Iframe;
}

// A subresource's redirect to a data: URL, loaded in place, as an onBeforeRequest redirect of a subresource
// is: its onBeforeRedirect, then the data: URL's load in place of the load's own.
void LegacyExtensionNetwork::redirectInPlace(NetworkLoadChecker& checker, NetworkResourceLoader& loader, ResourceRequest&& request, const ResourceResponse& redirectResponse, const URL& url)
{
    if (observes(onBeforeRedirect)) {
        auto details = requestDetails(checker, request);
        details->setString("url"_s, redirectResponse.url().string());
        details->setString("redirectUrl"_s, url.string());
        addResponseFields(details, redirectResponse);
        notify(onBeforeRedirect, details->toJSONString());
    }
    request.setURL(URL { url });
    loader.restartNetworkLoad(WTF::move(request), [](auto) { });
}

// A redirect an onHeadersReceived verdict makes of a load's response. A network load's redirect restarts
// the load on the approved request, as a redirect that changes the credentials policy does; a response
// the cache alone served becomes a cached redirect. The redirected request carries none of the cache's
// revalidation.
void LegacyExtensionNetwork::redirect(NetworkResourceLoader& loader, ResourceRequest&& request, const ResourceResponse& response, const URL& url)
{
    loader.m_cacheEntryForValidation = nullptr;
    if (!loader.originalRequest().isConditional())
        request.makeUnconditional();
    auto redirectResponse = redirectedResponse(response, url);
    redirectResponse.setSource(ResourceResponse::Source::Unknown);
    if (RefPtr checker = loader.m_networkLoadChecker; checker && loadsInPlace(loader, url))
        return redirectInPlace(*checker, loader, WTF::move(request), redirectResponse, url);
    auto redirectRequest = request.redirectedRequest(redirectResponse, loader.parameters().shouldClearReferrerOnHTTPSToHTTPRedirect);
    redirectRequest.appendCookieRequestRedirectURL(response.url());
    if (loader.isMainFrameLoad())
        redirectRequest.setFirstPartyForCookies(URL { redirectRequest.url() });
    if (RefPtr checker = loader.m_networkLoadChecker) {
        m_extensionRedirects.add(*checker);
        m_extensionRedirectTargets.set(*checker, redirectRequest.url());
    }

    if (RefPtr networkLoad = loader.m_networkLoad) {
        networkLoad->clearClient();
        loader.willSendRedirectedRequest(WTF::move(request), WTF::move(redirectRequest), WTF::move(redirectResponse), [weakLoader = WeakPtr { loader }](ResourceRequest&& approvedRequest) {
            RefPtr loader = weakLoader.get();
            if (loader && !approvedRequest.isNull())
                loader->restartNetworkLoad(WTF::move(approvedRequest), [](auto) { });
        });
        return;
    }

    auto entry = protect(loader.m_cache)->makeRedirectEntry(request, redirectResponse, redirectRequest);
    loader.dispatchWillSendRequestForCacheEntry(WTF::move(request), WTF::move(entry));
}

// onBeforeRequest, onBeforeSendHeaders and onSendHeaders, and onBeforeRedirect for a followed redirect.
bool LegacyExtensionNetwork::interceptRequest(NetworkLoadChecker& checker, ResourceRequest& request, ContentSecurityPolicyClient* client, NetworkLoadChecker::ValidationHandler& handler)
{
    if (m_resumingRequests.remove(checker))
        return false;
    // A hyperlink auditing ping, which carries Ping-To, is not sent while the privacy API turns hyperlink auditing
    // off; beacons and other pings are.
    if (!m_hyperlinkAuditingEnabled && request.hasHTTPHeaderField(HTTPHeaderName::PingTo)) {
        handler(cancellationError(request));
        return true;
    }
    // A load's first request the extensions see can follow a redirect a service worker answered, which no event reports.
    bool isFirstRequest = false;
    if (RefPtr loader = checker.m_networkResourceLoader.get()) {
        isFirstRequest = m_loaders.add(*loader).isNewEntry;
        if (isFirstRequest && m_takenRequests.remove(*loader))
            m_restartedRequestIdentifiers.set(*loader, m_nextRestartedRequestIdentifier++);
    }
    auto redirectResponse = m_redirectResponses.take(checker);
    // An extension's Cookie edit is its exchange's alone: a redirect generates its own.
    if (auto editedCookie = m_editedCookies.take(checker); !editedCookie.isNull() && request.httpHeaderField(HTTPHeaderName::Cookie) == editedCookie)
        removeCocoaCurlRequestHeader(request, HTTPHeaderName::Cookie);
    if (m_listeners.isEmpty() || !isInterceptable(request.url()))
        return false;

    if (checker.isRedirected() && !isFirstRequest && observes(onBeforeRedirect)) {
        auto details = requestDetails(checker, request);
        details->setString("url"_s, checker.m_previousURL.string());
        details->setString("redirectUrl"_s, request.url().string());
        if (redirectResponse)
            addResponseFields(details, *redirectResponse);
        notify(onBeforeRedirect, details->toJSONString());
    }

    return interceptProxyRequest(checker, request, client, handler) || interceptBeforeRequest(checker, request, client, handler);
}

bool LegacyExtensionNetwork::routesThroughProxies() const
{
    if (RefPtr configuration = CocoaCurlProxyConfiguration::current(); configuration && configuration->routesThroughProxies())
        return true;
    return observes(proxyOnRequest);
}

// proxy.onRequest, which Firefox fires before a request's webRequest events, pings, beacons and reports included.
// The answers of the listeners whose filters match the request act on the route its network task connects by.
bool LegacyExtensionNetwork::interceptProxyRequest(NetworkLoadChecker& checker, ResourceRequest& request, ContentSecurityPolicyClient* client, NetworkLoadChecker::ValidationHandler& handler)
{
    m_proxyAnswers.remove(checker);
    if (!observes(proxyOnRequest) || !request.url().protocolIsInHTTPFamily())
        return false;
    // Firefox's proxy.RequestDetails.
    auto details = requestDetails(checker, request);
    details->setBoolean("fromCache"_s, false);
    details->setBoolean("incognito"_s, checker.m_sessionID.isEphemeral());
    details->setBoolean("thirdParty"_s, !request.firstPartyForCookies().isEmpty() && !RegistrableDomain(request.firstPartyForCookies()).matches(request.url()));
    if (auto documentURL = details->getString("documentUrl"_s); !documentURL.isNull())
        details->setString("originUrl"_s, documentURL);
    if (hasOption(proxyOnRequest, requestHeadersOption))
        details->setArray("requestHeaders"_s, headersArray(request.httpHeaderFields()));
    if (!blocks(proxyOnRequest, details))
        return false;

    bool hasClient = !!client;
    dispatch(proxyOnRequest, details->toJSONString(), [this, weakChecker = WeakPtr { checker }, request = WTF::move(request), hasClient, handler = WTF::move(handler)](RefPtr<JSON::Object>&& response) mutable {
        RefPtr checker = weakChecker.get();
        if (!checker)
            return handler(ResourceError { ResourceError::Type::Cancellation });
        RefPtr loader = checker->m_networkResourceLoader.get();
        if (hasClient && !loader)
            return handler(ResourceError { ResourceError::Type::Cancellation });
        if (RefPtr answers = response ? response->getArray("proxy"_s) : nullptr) {
            if (auto results = LegacyExtensions::proxyFilterResults(*answers); !results.isEmpty())
                m_proxyAnswers.set(*checker, ProxyAnswers { request.url(), WTF::move(results) });
        }
        ContentSecurityPolicyClient* client = hasClient ? loader.get() : nullptr;
        if (interceptBeforeRequest(*checker, request, client, handler))
            return;
        continueRequest(*checker, WTF::move(request), client, WTF::move(handler));
    });
    return true;
}

// A request redirected before anything is sent is checked as a request for its new URL, as one whose URL WebKit's
// content rules change before it reaches the network process is.
void LegacyExtensionNetwork::checkAsRequestFor(NetworkLoadChecker& checker, const URL& url)
{
    checker.m_url = url;
    checker.m_isSameOriginRequest = checker.isSameOrigin(url, checker.m_origin.get());
    if (checker.m_options.credentials == FetchOptions::Credentials::SameOrigin)
        checker.m_storedCredentialsPolicy = checker.m_isSameOriginRequest ? StoredCredentialsPolicy::Use : StoredCredentialsPolicy::DoNotUse;
}

// onBeforeRequest, then the request's headers. A redirect the verdict makes before the request is sent
// is Chrome's internal redirect: a main frame follows it as a redirect; any other request loads the new URL
// in place, as WebKit's content rules redirect it, after the redirect's onBeforeRedirect and the new URL's
// own onBeforeRequest.
bool LegacyExtensionNetwork::interceptBeforeRequest(NetworkLoadChecker& checker, ResourceRequest& request, ContentSecurityPolicyClient* client, NetworkLoadChecker::ValidationHandler& handler)
{
    auto details = requestDetails(checker, request);
    if (hasOption(onBeforeRequest, requestBodyOption)) {
        if (auto body = requestBody(request))
            details->setObject("requestBody"_s, body.releaseNonNull());
    }
    if (!blocks(onBeforeRequest, details)) {
        if (observes(onBeforeRequest))
            notify(onBeforeRequest, details->toJSONString());
        return interceptRequestHeaders(checker, request, client, handler);
    }

    // The checker's one content security policy client is its loader, which the resumed check asks again.
    bool hasClient = !!client;
    bool isMainFrameLoad = checker.m_requestLoadType == NetworkLoadChecker::LoadType::MainFrame;
    dispatch(onBeforeRequest, details->toJSONString(), [this, weakChecker = WeakPtr { checker }, request = WTF::move(request), hasClient, handler = WTF::move(handler), isMainFrameLoad](RefPtr<JSON::Object>&& response) mutable {
        RefPtr checker = weakChecker.get();
        if (!checker)
            return handler(ResourceError { ResourceError::Type::Cancellation });
        RefPtr loader = checker->m_networkResourceLoader.get();
        if (hasClient && !loader)
            return handler(ResourceError { ResourceError::Type::Cancellation });

        if (response && response->getBoolean("cancel"_s).value_or(false))
            return handler(cancellationError(request));

        ContentSecurityPolicyClient* client = hasClient ? loader.get() : nullptr;
        URL redirectURL { response ? response->getString("redirectUrl"_s) : String() };
        if (redirectURL.isValid() && redirectURL != request.url()) {
            auto redirectResponse = internalRedirectResponse(request.url(), redirectURL);
            if (isMainFrameLoad && !checker->isRedirected()) {
                auto originalRequest = request;
                request.appendCookieRequestRedirectURL(request.url());
                request.setURL(WTF::move(redirectURL));
                m_extensionRedirects.add(*checker);
                m_extensionRedirectTargets.set(*checker, request.url());
                if (RefPtr body = request.httpBody())
                    m_internalRedirectBodies.set(*checker, InternalRedirectBody { request.url(), request.httpMethod(), WTF::move(body) });
                return handler(NetworkLoadChecker::RedirectionTriplet { WTF::move(originalRequest), WTF::move(request), WTF::move(redirectResponse) });
            }
            auto& redirectCount = m_internalRedirectCounts.ensure(*checker, [] { return 0u; }).iterator->value;
            if (++redirectCount > ResourceLoaderOptions { }.maxRedirectCount)
                return handler(ResourceError { errorDomainWebKitInternal, 0, redirectURL, "Load cannot follow more than 20 redirections"_s });
            if (observes(onBeforeRedirect)) {
                auto details = requestDetails(*checker, request);
                details->setString("redirectUrl"_s, redirectURL.string());
                addResponseFields(details, redirectResponse);
                notify(onBeforeRedirect, details->toJSONString());
            }
            request.appendCookieRequestRedirectURL(request.url());
            request.setURL(WTF::move(redirectURL));
            // A request a verdict changes is not the one a service worker left to the network.
            m_uncheckedRequests.remove(*checker);
            if (checker->isRedirected())
                m_extensionRedirectTargets.set(*checker, request.url());
            else
                checkAsRequestFor(*checker, request.url());
            if (isInterceptable(request.url()) && (interceptProxyRequest(*checker, request, client, handler) || interceptBeforeRequest(*checker, request, client, handler)))
                return;
            continueRequest(*checker, WTF::move(request), client, WTF::move(handler));
            return;
        }

        if (interceptRequestHeaders(*checker, request, client, handler))
            return;
        continueRequest(*checker, WTF::move(request), client, WTF::move(handler));
    });
    return true;
}

// onBeforeSendHeaders and onSendHeaders, with the headers the request is sent with. "extraHeaders" listeners
// see the fields the network layer adds to a request that carries none -- the Cookie field it generates,
// and its Accept-Language and Accept-Encoding -- and a verdict that changes or removes one sends the
// verdict's field instead, an empty field standing for a removed one.
bool LegacyExtensionNetwork::interceptRequestHeaders(NetworkLoadChecker& checker, ResourceRequest& request, ContentSecurityPolicyClient* client, NetworkLoadChecker::ValidationHandler& handler)
{
    if (!isHTTPOrWebSocket(request.url()))
        return false;

    Vector<GeneratedField> generatedFields;
    if (hasOption(onBeforeSendHeaders, extraHeadersOption) || hasOption(onSendHeaders, extraHeadersOption))
        generatedFields = LegacyExtensions::generatedFields(request, cookieHeader(checker, request));
    auto details = requestDetails(checker, request);
    details->setArray("requestHeaders"_s, requestHeadersWithFields(request, generatedFields));
    if (!blocks(onBeforeSendHeaders, details)) {
        if (observes(onBeforeSendHeaders))
            notify(onBeforeSendHeaders, details->toJSONString());
        if (observes(onSendHeaders))
            notify(onSendHeaders, details->toJSONString());
        return false;
    }

    bool hasClient = !!client;
    dispatch(onBeforeSendHeaders, details->toJSONString(), [this, weakChecker = WeakPtr { checker }, request = WTF::move(request), hasClient, handler = WTF::move(handler), generatedFields = WTF::move(generatedFields)](RefPtr<JSON::Object>&& response) mutable {
        RefPtr checker = weakChecker.get();
        if (!checker)
            return handler(ResourceError { ResourceError::Type::Cancellation });
        RefPtr loader = checker->m_networkResourceLoader.get();
        if (hasClient && !loader)
            return handler(ResourceError { ResourceError::Type::Cancellation });

        if (response && response->getBoolean("cancel"_s).value_or(false))
            return handler(cancellationError(request));
        if (RefPtr headers = response ? response->getArray("requestHeaders"_s) : nullptr) {
            if (auto editedCookie = applyRequestHeaders(request, *headers, generatedFields); !editedCookie.isNull())
                m_editedCookies.set(*checker, editedCookie);
            m_uncheckedRequests.remove(*checker);
        }

        if (observes(onSendHeaders)) {
            auto details = requestDetails(*checker, request);
            details->setArray("requestHeaders"_s, requestHeadersWithFields(request, generatedFields));
            notify(onSendHeaders, details->toJSONString());
        }
        continueRequest(*checker, WTF::move(request), hasClient ? loader.get() : nullptr, WTF::move(handler));
    });
    return true;
}

// onHeadersReceived for a redirect response. The response, as the extensions leave it, is what the
// redirect's onBeforeRedirect reports.
bool LegacyExtensionNetwork::interceptRedirection(NetworkLoadChecker& checker, ResourceRequest& request, ResourceRequest& redirectRequest, ResourceResponse& redirectResponse, ContentSecurityPolicyClient* client, NetworkLoadChecker::RedirectionValidationHandler& handler)
{
    if (m_resumingRedirections.remove(checker))
        return false;
    bool isExtensionRedirect = m_extensionRedirects.remove(checker);
    if (!isExtensionRedirect)
        m_extensionRedirectTargets.remove(checker);
    // A redirect a service worker answers is not reported; the redirected request starts the load's events again.
    RefPtr redirectLoader = checker.m_networkResourceLoader.get();
    if (redirectLoader && !m_loaders.contains(*redirectLoader))
        return false;
    if (m_listeners.isEmpty() || !isInterceptable(redirectResponse.url()))
        return false;
    m_redirectResponses.set(checker, makeUnique<ResourceResponse>(redirectResponse));
    // onHeadersReceived applies only to HTTP(S) and WebSocket network redirects; extension-made redirects report onBeforeRedirect.
    if (isExtensionRedirect || !isHTTPOrWebSocket(redirectResponse.url()))
        return false;

    auto details = requestDetails(checker, request.isNull() ? redirectRequest : request);
    details->setString("url"_s, redirectResponse.url().string());
    addResponseFields(details, redirectResponse);
    if (RefPtr task = redirectLoader ? curlTask(*redirectLoader) : nullptr; task && task->heldCookies())
        setSetCookieFields(details, *task->heldCookies());
    // The redirect's cookies are stored before the redirect is followed, so its request carries them.
    if (!blocks(onHeadersReceived, details)) {
        if (observes(onHeadersReceived))
            notify(onHeadersReceived, details->toJSONString());
        if (RefPtr task = redirectLoader ? curlTask(*redirectLoader) : nullptr)
            task->storeHeldCookies();
        return false;
    }

    bool hasClient = !!client;
    dispatch(onHeadersReceived, details->toJSONString(), [this, weakChecker = WeakPtr { checker }, request = WTF::move(request), redirectRequest = WTF::move(redirectRequest), redirectResponse = WTF::move(redirectResponse), hasClient, handler = WTF::move(handler)](RefPtr<JSON::Object>&& verdict) mutable {
        RefPtr checker = weakChecker.get();
        if (!checker)
            return handler(makeUnexpected(ResourceError { ResourceError::Type::Cancellation }));
        RefPtr loader = checker->m_networkResourceLoader.get();
        if (hasClient && !loader)
            return handler(makeUnexpected(ResourceError { ResourceError::Type::Cancellation }));

        RefPtr task = loader ? curlTask(*loader) : nullptr;
        if (verdict && verdict->getBoolean("cancel"_s).value_or(false)) {
            if (task)
                task->discardHeldCookies();
            return handler(makeUnexpected(cancellationError(redirectRequest)));
        }
        if (task) {
            RefPtr headers = verdict ? verdict->getArray("responseHeaders"_s) : nullptr;
            task->storeHeldCookies(headers && task->heldCookies() ? std::optional { setCookieFields(*headers) } : std::nullopt);
        }
        if (verdict) {
            // A rewritten Location header moves the redirect to the new location; a redirectUrl rewrites the
            // response to a 302 Found to it.
            URL target;
            if (RefPtr headers = verdict->getArray("responseHeaders"_s)) {
                auto location = redirectResponse.httpHeaderField(HTTPHeaderName::Location);
                redirectResponse = responseWithHeaders(redirectResponse, *headers, loader && loader->originalRequest().requester() == ResourceRequestRequester::Main ? IsMainResourceLoad::Yes : IsMainResourceLoad::No);
                if (auto newLocation = redirectResponse.httpHeaderField(HTTPHeaderName::Location); newLocation != location)
                    target = URL { redirectResponse.url(), newLocation };
            }
            if (URL redirectURL { verdict->getString("redirectUrl"_s) }; redirectURL.isValid()) {
                redirectResponse = redirectedResponse(redirectResponse, redirectURL);
                target = WTF::move(redirectURL);
            }
            if (target.isValid() && loader && loadsInPlace(*loader, target)) {
                redirectInPlace(*checker, *loader, WTF::move(redirectRequest), redirectResponse, target);
                return handler(makeUnexpected(ResourceError { ResourceError::Type::Cancellation }));
            }
            if (target.isValid() && target != redirectRequest.url()) {
                if (redirectResponse.httpHeaderField(HTTPHeaderName::Location) != target.string())
                    redirectResponse.setHTTPHeaderField(HTTPHeaderName::Location, target.string());
                redirectRequest = retargetedRedirectRequest(request, redirectRequest, redirectResponse, loader ? loader->parameters().shouldClearReferrerOnHTTPSToHTTPRedirect : true, checker->m_requestLoadType == NetworkLoadChecker::LoadType::MainFrame);
                m_extensionRedirectTargets.set(*checker, redirectRequest.url());
            }
        }
        m_redirectResponses.set(*checker, makeUnique<ResourceResponse>(redirectResponse));
        m_resumingRedirections.add(*checker);
        checker->checkRedirection(WTF::move(request), WTF::move(redirectRequest), WTF::move(redirectResponse), hasClient ? loader.get() : nullptr, WTF::move(handler));
    });
    return true;
}

// onHeadersReceived and onResponseStarted, for a response from the network.
bool LegacyExtensionNetwork::interceptResponse(NetworkResourceLoader& loader, ResourceResponse& response, PrivateRelayed privateRelayed, ResponseCompletionHandler& completionHandler)
{
    if (m_resumingResponses.remove(loader))
        return false;
    if (m_listeners.isEmpty() || !m_loaders.contains(loader) || !isInterceptable(response.url()))
        return false;
    // A successful revalidation reaches the extensions as the cached response.
    if (loader.m_cacheEntryForValidation && response.httpStatusCode() == httpStatus304NotModified)
        return false;

    auto details = responseDetails(loader, response, false);
    if (RefPtr task = curlTask(loader); task && task->heldCookies())
        setSetCookieFields(details, *task->heldCookies());
    // Extension files have no header events; a redirect the load does not follow reports
    // its onHeadersReceived in interceptRedirection.
    if (!isHTTPOrWebSocket(response.url()) || response.type() == ResourceResponse::Type::Opaqueredirect) {
        if (observes(onResponseStarted))
            notify(onResponseStarted, details->toJSONString());
        return false;
    }
    if (!blocks(onHeadersReceived, details)) {
        if (observes(onHeadersReceived))
            notify(onHeadersReceived, details->toJSONString());
        if (observes(onResponseStarted))
            notify(onResponseStarted, details->toJSONString());
        return false;
    }

    dispatch(onHeadersReceived, details->toJSONString(), [this, weakLoader = WeakPtr { loader }, response = WTF::move(response), privateRelayed, completionHandler = WTF::move(completionHandler)](RefPtr<JSON::Object>&& verdict) mutable {
        RefPtr loader = weakLoader.get();
        if (!loader)
            return completionHandler(PolicyAction::Ignore);
        RefPtr task = curlTask(*loader);
        if (RefPtr headers = verdict ? verdict->getArray("responseHeaders"_s) : nullptr; headers && task && task->heldCookies())
            task->storeHeldCookies(setCookieFields(*headers));
        // The load's own continuation is queued before the response is ignored, whose cancellation it overtakes.
        if (verdict && verdict->getBoolean("cancel"_s).value_or(false)) {
            if (task)
                task->discardHeldCookies();
            RunLoop::mainSingleton().dispatch([weakLoader = WTF::move(weakLoader)] {
                RefPtr loader = weakLoader.get();
                if (loader && loader->m_networkLoad)
                    loader->didFailLoading(cancellationError(loader->originalRequest()));
            });
            return completionHandler(PolicyAction::Ignore);
        }
        if (RefPtr headers = verdict ? verdict->getArray("responseHeaders"_s) : nullptr) {
            response = responseWithHeaders(response, *headers, loader->originalRequest().requester() == ResourceRequestRequester::Main ? IsMainResourceLoad::Yes : IsMainResourceLoad::No);
        }
        if (URL redirectURL { verdict ? verdict->getString("redirectUrl"_s) : String() }; redirectURL.isValid()) {
            RunLoop::mainSingleton().dispatch([this, weakLoader = WTF::move(weakLoader), response = WTF::move(response), redirectURL = WTF::move(redirectURL)] {
                RefPtr loader = weakLoader.get();
                if (loader && loader->m_networkLoad)
                    redirect(*loader, ResourceRequest { loader->m_networkLoad->currentRequest() }, response, redirectURL);
            });
            return completionHandler(PolicyAction::Ignore);
        }
        if (observes(onResponseStarted))
            notify(onResponseStarted, responseDetails(*loader, response, false)->toJSONString());
        m_resumingResponses.add(*loader);
        loader->didReceiveResponse(WTF::move(response), privateRelayed, WTF::move(completionHandler));
    });
    return true;
}

// onHeadersReceived and onResponseStarted, for a response from the network cache.
bool LegacyExtensionNetwork::interceptCachedResponse(NetworkResourceLoader& loader, std::unique_ptr<NetworkCache::Entry>& entry)
{
    if (m_resumingCacheEntries.remove(loader))
        return false;
    if (m_listeners.isEmpty() || !m_loaders.contains(loader) || !entry || !isInterceptable(entry->response().url()))
        return false;

    auto details = responseDetails(loader, entry->response(), true);
    if (!isHTTPOrWebSocket(entry->response().url())) {
        if (observes(onResponseStarted))
            notify(onResponseStarted, details->toJSONString());
        return false;
    }
    if (!blocks(onHeadersReceived, details)) {
        if (observes(onHeadersReceived))
            notify(onHeadersReceived, details->toJSONString());
        if (observes(onResponseStarted))
            notify(onResponseStarted, details->toJSONString());
        return false;
    }

    dispatch(onHeadersReceived, details->toJSONString(), [this, weakLoader = WeakPtr { loader }, entry = WTF::move(entry)](RefPtr<JSON::Object>&& verdict) mutable {
        RefPtr loader = weakLoader.get();
        if (!loader)
            return;
        if (verdict && verdict->getBoolean("cancel"_s).value_or(false)) {
            loader->didFailLoading(cancellationError(loader->originalRequest()));
            return;
        }
        if (RefPtr headers = verdict ? verdict->getArray("responseHeaders"_s) : nullptr) {
            RefPtr<FragmentedSharedBuffer> buffer = entry->buffer();
            entry = protect(loader->m_cache)->makeEntry(loader->originalRequest(), responseWithHeaders(entry->response(), *headers, loader->originalRequest().requester() == ResourceRequestRequester::Main ? IsMainResourceLoad::Yes : IsMainResourceLoad::No), entry->privateRelayed(), WTF::move(buffer));
        }
        if (URL redirectURL { verdict ? verdict->getString("redirectUrl"_s) : String() }; redirectURL.isValid()) {
            auto request = loader->m_networkLoad ? loader->m_networkLoad->currentRequest() : loader->originalRequest();
            request.setURL(URL { entry->response().url() });
            redirect(*loader, WTF::move(request), entry->response(), redirectURL);
            return;
        }
        if (observes(onResponseStarted))
            notify(onResponseStarted, responseDetails(*loader, entry->response(), true)->toJSONString());
        m_resumingCacheEntries.add(*loader);
        loader->didRetrieveCacheEntry(WTF::move(entry));
    });
    return true;
}

// A navigation's preload and a service worker's update check.

Ref<LegacyExtensionNetwork::ClientLoad> LegacyExtensionNetwork::createClientLoad(ClientLoadKind kind, Ref<JSON::Object>&& details, PAL::SessionID sessionID)
{
    return adoptRef(*new ClientLoad(kind, makeString(getCurrentProcessID(), kind == ClientLoadKind::Preload ? "-preload-"_s : "-update-"_s, m_nextClientLoadIdentifier++), WTF::move(details), sessionID));
}

Ref<JSON::Object> LegacyExtensionNetwork::clientDetails(ClientLoad& load, const URL& url)
{
    auto details = JSON::Object::create();
    for (auto& [key, value] : load.details.get())
        details->setValue(key, value.copyRef());
    details->setString("requestId"_s, load.requestId);
    details->setString("url"_s, url.string());
    details->setString("method"_s, load.request.httpMethod());
    details->setDouble("timeStamp"_s, timeStamp());
    return details;
}

RefPtr<NetworkLoad> LegacyExtensionNetwork::clientNetworkLoad(NetworkLoadClient& client, ClientLoad& load)
{
    if (load.kind == ClientLoadKind::Preload)
        return static_cast<ServiceWorkerNavigationPreloader&>(client).m_networkLoad;
    return static_cast<ServiceWorkerSoftUpdateLoader&>(client).m_networkLoad;
}

RefPtr<NetworkDataTaskCurlCocoa> LegacyExtensionNetwork::clientCurlTask(ClientLoad& load, NetworkLoad* networkLoad)
{
    RefPtr networkProcess = m_networkProcess.get();
    CheckedPtr session = networkProcess && networkLoad ? networkProcess->networkSession(load.sessionID) : nullptr;
    if (!session || !NetworkDataTaskCurlCocoa::canHandle(*session, networkLoad->parameters()))
        return nullptr;
    return static_cast<NetworkDataTaskCurlCocoa*>(networkLoad->m_task.get());
}

// The loader whose fetch task creates a preload: the preload's request is the loader's, sent while the service
// worker decides, or for it. Its type, tab and frame are the loader's.
void LegacyExtensionNetwork::willCreatePreload(NetworkResourceLoader& loader)
{
    m_preloadLoader = WeakPtr { loader };
}

bool LegacyExtensionNetwork::interceptPreloadRequest(ServiceWorkerNavigationPreloader& preloader)
{
    if (m_resumingClientRequests.remove(preloader))
        return false;
    RefPtr loader = std::exchange(m_preloadLoader, nullptr).get();
    CheckedPtr session = preloader.m_session.get();
    if (!loader || !session || m_listeners.isEmpty() || !isInterceptable(preloader.m_parameters.request.url()))
        return false;

    auto details = loaderDetails(*loader);
    for (auto key : { "requestId"_s, "url"_s, "method"_s, "timeStamp"_s })
        details->remove(key);
    Ref load = createClientLoad(ClientLoadKind::Preload, WTF::move(details), session->sessionID());
    load->origin = requestSourceOrigin(loader->parameters());
    load->frameID = preloader.m_parameters.webFrameID.asOptional();
    load->pageID = preloader.m_parameters.webPageID.asOptional();
    load->webPageProxyID = preloader.m_parameters.webPageProxyID.asOptional();
    load->storedCredentialsPolicy = preloader.m_parameters.storedCredentialsPolicy;
    m_clientLoads.set(preloader, load.copyRef());

    checkClientRequest(load.copyRef(), ResourceRequest { preloader.m_parameters.request }, [this, weakPreloader = WeakPtr { preloader }, load](ClientRequestResult&& result) mutable {
        RefPtr preloader = weakPreloader.get();
        if (!preloader || load->ended)
            return;
        WTF::switchOn(result,
            [&](ResourceRequest& request) {
                preloader->m_parameters.request = WTF::move(request);
                m_resumingClientRequests.add(*preloader);
                preloader->start();
            },
            // A preload follows no redirect: the redirect is its response, which the service worker or the navigation follows.
            [&](URL& redirectURL) {
                load->isInternalRedirect = true;
                preloader->willSendRedirectedRequest({ }, { }, internalRedirectResponse(load->request.url(), redirectURL), [](auto) { });
            },
            [&](ResourceError& error) {
                preloader->didFailLoading(error);
            });
    });
    return true;
}

// An update check's request, decided before its loader is created: a check the extensions cancel or redirect fails,
// as a service worker script's redirect does.
void LegacyExtensionNetwork::willSoftUpdate(NetworkSession& session, const URL& scopeURL, ResourceRequest&& request, SoftUpdateRequestHandler&& handler)
{
    if (m_listeners.isEmpty() || !isInterceptable(request.url()))
        return handler(WTF::move(request));

    auto details = JSON::Object::create();
    details->setString("type"_s, "script"_s);
    details->setDouble("tabId"_s, -1);
    details->setDouble("frameId"_s, -1);
    details->setDouble("parentFrameId"_s, -1);
    Ref origin = SecurityOrigin::create(scopeURL);
    details->setString("initiator"_s, origin->toString());
    Ref load = createClientLoad(ClientLoadKind::SoftUpdate, WTF::move(details), session.sessionID());
    load->origin = WTF::move(origin);

    checkClientRequest(load.copyRef(), WTF::move(request), [this, load, handler = WTF::move(handler)](ClientRequestResult&& result) mutable {
        WTF::switchOn(result,
            [&](ResourceRequest& request) {
                m_creatingSoftUpdate = load.copyRef();
                handler(WTF::move(request));
                // A check whose session went away has no loader.
                if (std::exchange(m_creatingSoftUpdate, nullptr))
                    endClientLoad(load, ResourceError { ResourceError::Type::Cancellation });
            },
            // As ServiceWorkerSoftUpdateLoader::willSendRedirectedRequest fails a redirected check.
            [&](URL&) {
                ResourceError error { ResourceError::Type::Cancellation };
                endClientLoad(load, error);
                handler(makeUnexpected(WTF::move(error)));
            },
            [&](ResourceError& error) {
                endClientLoad(load, error);
                handler(makeUnexpected(WTF::move(error)));
            });
    });
}

void LegacyExtensionNetwork::didCreateSoftUpdateLoader(ServiceWorkerSoftUpdateLoader& loader)
{
    if (RefPtr load = std::exchange(m_creatingSoftUpdate, nullptr))
        m_clientLoads.set(loader, load.releaseNonNull());
}

// proxy.onRequest, onBeforeRequest, onBeforeSendHeaders and onSendHeaders, as for a load's request; the handler
// receives the request to send, the URL an onBeforeRequest verdict redirects it to, or the error it fails with.
void LegacyExtensionNetwork::checkClientRequest(Ref<ClientLoad>&& load, ResourceRequest&& request, ClientRequestHandler&& handler)
{
    load->request = request;
    if (!observes(proxyOnRequest) || !request.url().protocolIsInHTTPFamily())
        return checkClientBeforeRequest(WTF::move(load), WTF::move(request), WTF::move(handler));
    auto details = clientDetails(load, request.url());
    details->setBoolean("fromCache"_s, false);
    details->setBoolean("incognito"_s, load->sessionID.isEphemeral());
    details->setBoolean("thirdParty"_s, !request.firstPartyForCookies().isEmpty() && !RegistrableDomain(request.firstPartyForCookies()).matches(request.url()));
    if (auto documentURL = details->getString("documentUrl"_s); !documentURL.isNull())
        details->setString("originUrl"_s, documentURL);
    if (hasOption(proxyOnRequest, requestHeadersOption))
        details->setArray("requestHeaders"_s, headersArray(request.httpHeaderFields()));
    if (!blocks(proxyOnRequest, details))
        return checkClientBeforeRequest(WTF::move(load), WTF::move(request), WTF::move(handler));
    dispatch(proxyOnRequest, details->toJSONString(), [this, load = WTF::move(load), request = WTF::move(request), handler = WTF::move(handler)](RefPtr<JSON::Object>&& response) mutable {
        if (load->ended)
            return handler(ResourceError { ResourceError::Type::Cancellation });
        if (RefPtr answers = response ? response->getArray("proxy"_s) : nullptr) {
            if (auto results = LegacyExtensions::proxyFilterResults(*answers); !results.isEmpty())
                load->proxyAnswers = ProxyAnswers { request.url(), WTF::move(results) };
        }
        checkClientBeforeRequest(WTF::move(load), WTF::move(request), WTF::move(handler));
    });
}

void LegacyExtensionNetwork::checkClientBeforeRequest(Ref<ClientLoad>&& load, ResourceRequest&& request, ClientRequestHandler&& handler)
{
    auto details = clientDetails(load, request.url());
    if (hasOption(onBeforeRequest, requestBodyOption)) {
        if (auto body = requestBody(request))
            details->setObject("requestBody"_s, body.releaseNonNull());
    }
    if (!blocks(onBeforeRequest, details)) {
        if (observes(onBeforeRequest))
            notify(onBeforeRequest, details->toJSONString());
        return checkClientRequestHeaders(WTF::move(load), WTF::move(request), WTF::move(handler));
    }
    dispatch(onBeforeRequest, details->toJSONString(), [this, load = WTF::move(load), request = WTF::move(request), handler = WTF::move(handler)](RefPtr<JSON::Object>&& response) mutable {
        if (load->ended)
            return handler(ResourceError { ResourceError::Type::Cancellation });
        if (response && response->getBoolean("cancel"_s).value_or(false))
            return handler(cancellationError(request));
        if (URL redirectURL { response ? response->getString("redirectUrl"_s) : String() }; redirectURL.isValid() && redirectURL != request.url()) {
            if (observes(onBeforeRedirect)) {
                auto details = clientDetails(load, request.url());
                details->setString("redirectUrl"_s, redirectURL.string());
                addResponseFields(details, internalRedirectResponse(request.url(), redirectURL));
                notify(onBeforeRedirect, details->toJSONString());
            }
            return handler(WTF::move(redirectURL));
        }
        checkClientRequestHeaders(WTF::move(load), WTF::move(request), WTF::move(handler));
    });
}

void LegacyExtensionNetwork::checkClientRequestHeaders(Ref<ClientLoad>&& load, ResourceRequest&& request, ClientRequestHandler&& handler)
{
    if (!isHTTPOrWebSocket(request.url()))
        return handler(WTF::move(request));
    Vector<GeneratedField> generatedFields;
    if (hasOption(onBeforeSendHeaders, extraHeadersOption) || hasOption(onSendHeaders, extraHeadersOption)) {
        RefPtr networkProcess = m_networkProcess.get();
        CheckedPtr session = networkProcess ? networkProcess->networkSession(load->sessionID) : nullptr;
        generatedFields = LegacyExtensions::generatedFields(request, session ? NetworkDataTaskCurlCocoa::cookieHeader(*session, request, load->origin.get(), load->frameID, load->pageID, load->webPageProxyID, load->storedCredentialsPolicy) : String { });
    }
    auto details = clientDetails(load, request.url());
    details->setArray("requestHeaders"_s, requestHeadersWithFields(request, generatedFields));
    if (!blocks(onBeforeSendHeaders, details)) {
        if (observes(onBeforeSendHeaders))
            notify(onBeforeSendHeaders, details->toJSONString());
        if (observes(onSendHeaders))
            notify(onSendHeaders, details->toJSONString());
        load->request = request;
        return handler(WTF::move(request));
    }
    dispatch(onBeforeSendHeaders, details->toJSONString(), [this, load = WTF::move(load), request = WTF::move(request), handler = WTF::move(handler), generatedFields = WTF::move(generatedFields)](RefPtr<JSON::Object>&& response) mutable {
        if (load->ended)
            return handler(ResourceError { ResourceError::Type::Cancellation });
        if (response && response->getBoolean("cancel"_s).value_or(false))
            return handler(cancellationError(request));
        if (RefPtr headers = response ? response->getArray("requestHeaders"_s) : nullptr)
            applyRequestHeaders(request, *headers, generatedFields);
        if (observes(onSendHeaders)) {
            auto details = clientDetails(load, request.url());
            details->setArray("requestHeaders"_s, requestHeadersWithFields(request, generatedFields));
            notify(onSendHeaders, details->toJSONString());
        }
        load->request = request;
        handler(WTF::move(request));
    });
}

// onHeadersReceived and onResponseStarted, for a preload's or an update check's response from the network or the
// cache. A successful revalidation reaches the extensions as the cached response.
bool LegacyExtensionNetwork::interceptClientResponse(NetworkLoadClient& client, ResourceResponse& response, PrivateRelayed privateRelayed, ResponseCompletionHandler& completionHandler)
{
    if (m_resumingClientResponses.remove(client))
        return false;
    RefPtr load = m_clientLoads.get(client);
    if (!load || load->ended)
        return false;
    if (response.httpStatusCode() == httpStatus304NotModified) {
        bool hasCacheEntry = load->kind == ClientLoadKind::Preload ? !!static_cast<ServiceWorkerNavigationPreloader&>(client).m_cacheEntry : !!static_cast<ServiceWorkerSoftUpdateLoader&>(client).m_cacheEntry;
        if (hasCacheEntry)
            return false;
    }
    if (std::exchange(load->isInternalRedirect, false)) {
        didStartClientResponse(*load, response);
        return false;
    }

    auto details = clientDetails(*load, response.url());
    addResponseFields(details, response);
    RefPtr networkLoad = clientNetworkLoad(client, *load);
    if (RefPtr task = clientCurlTask(*load, networkLoad.get()); task && task->heldCookies())
        setSetCookieFields(details, *task->heldCookies());
    if (!isHTTPOrWebSocket(response.url()) || !blocks(onHeadersReceived, details)) {
        if (isHTTPOrWebSocket(response.url()) && observes(onHeadersReceived))
            notify(onHeadersReceived, details->toJSONString());
        didStartClientResponse(*load, response);
        return false;
    }

    dispatch(onHeadersReceived, details->toJSONString(), [this, weakClient = WeakPtr { client }, load = load.releaseNonNull(), response = WTF::move(response), privateRelayed, completionHandler = WTF::move(completionHandler)](RefPtr<JSON::Object>&& verdict) mutable {
        RefPtr client = weakClient.get();
        if (!client || load->ended)
            return completionHandler(PolicyAction::Ignore);
        RefPtr networkLoad = clientNetworkLoad(*client, load);
        RefPtr task = clientCurlTask(load, networkLoad.get());
        if (RefPtr headers = verdict ? verdict->getArray("responseHeaders"_s) : nullptr; headers && task && task->heldCookies())
            task->storeHeldCookies(setCookieFields(*headers));
        // The loader fails before the network load's own cancellation can reach it.
        if (verdict && verdict->getBoolean("cancel"_s).value_or(false)) {
            if (task)
                task->discardHeldCookies();
            if (networkLoad)
                networkLoad->clearClient();
            client->didFailLoading(cancellationError(load->request));
            return completionHandler(PolicyAction::Ignore);
        }
        if (RefPtr headers = verdict ? verdict->getArray("responseHeaders"_s) : nullptr)
            response = responseWithHeaders(response, *headers, load->details->getString("type"_s) == "main_frame"_s ? IsMainResourceLoad::Yes : IsMainResourceLoad::No);
        if (URL redirectURL { verdict ? verdict->getString("redirectUrl"_s) : String() }; redirectURL.isValid())
            response = redirectedResponse(response, redirectURL);
        didStartClientResponse(load, response);
        m_resumingClientResponses.add(*client);
        client->didReceiveResponse(WTF::move(response), privateRelayed, WTF::move(completionHandler));
    });
    return true;
}

// An update check's response from the cache, which its loader validates without receiving it.
bool LegacyExtensionNetwork::interceptSoftUpdateCacheEntry(ServiceWorkerSoftUpdateLoader& loader, NetworkCache::Entry& entry)
{
    if (m_resumingClientResponses.remove(loader))
        return false;
    RefPtr load = m_clientLoads.get(loader);
    if (!load || load->ended)
        return false;
    auto details = clientDetails(*load, entry.response().url());
    addResponseFields(details, entry.response());
    if (!isHTTPOrWebSocket(entry.response().url()) || !blocks(onHeadersReceived, details)) {
        if (isHTTPOrWebSocket(entry.response().url()) && observes(onHeadersReceived))
            notify(onHeadersReceived, details->toJSONString());
        didStartClientResponse(*load, entry.response());
        return false;
    }

    dispatch(onHeadersReceived, details->toJSONString(), [this, weakLoader = WeakPtr { loader }, load = load.releaseNonNull(), entry = makeUnique<NetworkCache::Entry>(entry)](RefPtr<JSON::Object>&& verdict) mutable {
        RefPtr loader = weakLoader.get();
        if (!loader || load->ended)
            return;
        if (verdict && verdict->getBoolean("cancel"_s).value_or(false))
            return loader->fail(cancellationError(load->request));
        auto response = entry->response();
        RefPtr headers = verdict ? verdict->getArray("responseHeaders"_s) : nullptr;
        if (headers)
            response = responseWithHeaders(response, *headers, IsMainResourceLoad::No);
        URL redirectURL { verdict ? verdict->getString("redirectUrl"_s) : String() };
        if (redirectURL.isValid())
            response = redirectedResponse(response, redirectURL);
        CheckedPtr session = loader->m_session.get();
        RefPtr cache = session ? session->cache() : nullptr;
        if ((headers || redirectURL.isValid()) && cache) {
            RefPtr<FragmentedSharedBuffer> buffer = entry->buffer();
            entry = cache->makeEntry(load->request, response, entry->privateRelayed(), WTF::move(buffer));
        }
        didStartClientResponse(load, entry->response());
        m_resumingClientResponses.add(*loader);
        loader->loadWithCacheEntry(*entry);
    });
    return true;
}

// A redirect response ends a preload, which never follows it; an update check fails on it.
void LegacyExtensionNetwork::didStartClientResponse(ClientLoad& load, const ResourceResponse& response)
{
    load.response = response;
    if (response.isRedirection() && response.httpHeaderFields().contains(HTTPHeaderName::Location)) {
        if (!response.httpHeaderFields().contains(String { "Non-Authoritative-Reason"_s }) && observes(onBeforeRedirect)) {
            auto details = clientDetails(load, response.url());
            details->setString("redirectUrl"_s, URL { response.url(), response.httpHeaderField(HTTPHeaderName::Location) }.string());
            addResponseFields(details, response);
            notify(onBeforeRedirect, details->toJSONString());
        }
        if (load.kind == ClientLoadKind::Preload)
            endClientLoad(load, { });
        return;
    }
    if (observes(onResponseStarted)) {
        auto details = clientDetails(load, response.url());
        addResponseFields(details, response);
        notify(onResponseStarted, details->toJSONString());
    }
}

void LegacyExtensionNetwork::clientLoadDidEnd(NetworkLoadClient& client, const ResourceError& error)
{
    if (RefPtr load = m_clientLoads.get(client))
        endClientLoad(*load, error);
}

// onCompleted, or onErrorOccurred with the error's name.
void LegacyExtensionNetwork::endClientLoad(ClientLoad& load, const ResourceError& error)
{
    if (std::exchange(load.ended, true))
        return;
    auto eventName = error.isNull() ? onCompleted : onErrorOccurred;
    auto& url = load.response.isNull() ? load.request.url() : load.response.url();
    if (!observes(eventName) || !isInterceptable(url))
        return;
    auto details = clientDetails(load, url);
    if (error.isNull())
        addResponseFields(details, load.response);
    else {
        details->setBoolean("fromCache"_s, isFromCache(load.response));
        details->setString("error"_s, LegacyExtensions::networkErrorName(error));
    }
    notify(eventName, details->toJSONString());
}

Vector<CocoaCurlProxyFilterResult> LegacyExtensionNetwork::takeWebSocketProxyFilterResults(NetworkConnectionToWebProcess& connection, WebCore::WebSocketIdentifier identifier)
{
    auto iterator = m_webSocketProxyFilterResults.find(connection);
    if (iterator == m_webSocketProxyFilterResults.end())
        return { };
    return iterator->value.take(identifier.toUInt64());
}

static Ref<JSON::Object> webSocketDetails(WebSocketIdentifier identifier, WebPageProxyIdentifier webPageProxyID, std::optional<FrameIdentifier> frameID, const String& initiator, const ResourceRequest& request)
{
    auto details = JSON::Object::create();
    details->setString("requestId"_s, makeString(getCurrentProcessID(), "-ws-"_s, identifier.toUInt64()));
    details->setString("url"_s, request.url().string());
    details->setString("method"_s, "GET"_s);
    details->setString("type"_s, "websocket"_s);
    details->setDouble("timeStamp"_s, timeStamp());
    details->setDouble("tabId"_s, static_cast<double>(webPageProxyID.toUInt64()));
    details->setDouble("frameId"_s, frameID ? static_cast<double>(frameID->toUInt64()) : 0);
    details->setDouble("parentFrameId"_s, 0);
    details->setString("initiator"_s, initiator);
    return details;
}

RefPtr<LegacyWebSocketHandshake> LegacyExtensionNetwork::takeWebSocketHandshake(NetworkConnectionToWebProcess& connection, WebSocketIdentifier identifier)
{
    auto iterator = m_webSocketHandshakes.find(connection);
    return iterator == m_webSocketHandshakes.end() ? nullptr : iterator->value.take(identifier.toUInt64());
}

bool LegacyExtensionNetwork::interceptWebSocket(NetworkConnectionToWebProcess& connection, const ResourceRequest& request, WebSocketIdentifier identifier, WebPageProxyIdentifier webPageProxyID, std::optional<FrameIdentifier> frameID, const ClientOrigin& clientOrigin, Function<void()>&& createChannel)
{
    if (!observesWebSocket(m_listeners))
        return false;
    RefPtr<LegacyWebSocketHandshake> handshake = adoptRef(*new LegacyExtensions::WebSocketHandshake(m_listeners,
        webSocketDetails(identifier, webPageProxyID, frameID, clientOrigin.clientOrigin.toString(), request), connection.sessionID().isEphemeral(),
        [this](ASCIILiteral event, Ref<JSON::Object>&& details) { notify(event, details->toJSONString()); },
        [this](ASCIILiteral event, Ref<JSON::Object>&& details, CompletionHandler<void(RefPtr<JSON::Object>&&)>&& completion) { dispatch(event, details->toJSONString(), WTF::move(completion)); }));
    m_webSocketHandshakes.ensure(connection, [] { return HashMap<uint64_t, RefPtr<LegacyWebSocketHandshake>> { }; }).iterator->value.set(identifier.toUInt64(), handshake);
    m_pendingWebSockets.ensure(connection, [] { return HashSet<uint64_t> { }; }).iterator->value.add(identifier.toUInt64());
    handshake->willSendRequest(ResourceRequest { request }, { }, [this, handshake, weakConnection = WeakPtr { connection }, identifier, createChannel = WTF::move(createChannel)](ResourceRequest&& request, Vector<CocoaCurlProxyFilterResult>&& proxies) mutable {
        RefPtr connection = weakConnection.get();
        if (!connection) {
            handshake->didComplete("net::ERR_ABORTED"_s);
            return;
        }
        auto pending = m_pendingWebSockets.find(*connection);
        if (pending == m_pendingWebSockets.end() || !pending->value.remove(identifier.toUInt64()))
            return;
        if (!connection->connection().isValid()) {
            handshake->didComplete("net::ERR_ABORTED"_s);
            takeWebSocketHandshake(*connection, identifier);
            return;
        }
        if (request.isNull()) {
            takeWebSocketHandshake(*connection, identifier);
            connection->connection().send(Messages::WebSocketChannel::DidReceiveMessageError { "WebSocket connection was blocked by an extension"_s }, identifier.toUInt64());
            connection->connection().send(Messages::WebSocketChannel::DidClose { 1006, emptyString() }, identifier.toUInt64());
            return;
        }
        m_webSocketProxyFilterResults.ensure(*connection, [] { return HashMap<uint64_t, Vector<CocoaCurlProxyFilterResult>> { }; }).iterator->value.set(identifier.toUInt64(), WTF::move(proxies));
        createChannel();
        if (auto unclaimed = takeWebSocketHandshake(*connection, identifier)) {
            unclaimed->didComplete("net::ERR_FAILED"_s);
            takeWebSocketProxyFilterResults(*connection, identifier);
        }
    });
    return true;
}

// onAuthRequired, for a load's HTTP or proxy authentication challenge. A verdict's authCredentials answer
// it; a cancel continues without credentials, so the 401 or 407 response is the load's, as Chrome cancels
// the authentication; a load no verdict answers leaves the challenge to the browser.
bool LegacyExtensionNetwork::interceptAuthenticationChallenge(NetworkLoad& networkLoad, const AuthenticationChallenge& challenge, NegotiatedLegacyTLS negotiatedLegacyTLS, ChallengeCompletionHandler& completionHandler)
{
    if (m_resumingChallenges.remove(networkLoad))
        return false;
    if (!observes(onAuthRequired))
        return false;
    auto scheme = authenticationSchemeName(challenge);
    if (scheme.isNull())
        return false;
    // The challenge's load is one the extensions have seen, or a preload's or an update check's.
    RefPtr<JSON::Object> loadDetails;
    for (auto& candidate : m_loaders) {
        if (candidate.m_networkLoad == &networkLoad) {
            loadDetails = loaderDetails(candidate);
            break;
        }
    }
    for (auto entry : m_clientLoads) {
        if (loadDetails)
            break;
        if (!entry.value->ended && clientNetworkLoad(entry.key, entry.value) == &networkLoad)
            loadDetails = clientDetails(entry.value, networkLoad.currentRequest().url());
    }
    if (!loadDetails)
        return false;

    auto& protectionSpace = challenge.protectionSpace();
    Ref details = loadDetails.releaseNonNull();
    addResponseFields(details, challenge.failureResponse());
    details->setString("scheme"_s, scheme);
    if (!protectionSpace.realm().isEmpty())
        details->setString("realm"_s, protectionSpace.realm());
    auto challenger = JSON::Object::create();
    challenger->setString("host"_s, protectionSpace.host());
    challenger->setDouble("port"_s, protectionSpace.port());
    details->setObject("challenger"_s, WTF::move(challenger));
    details->setBoolean("isProxy"_s, protectionSpace.isProxy());
    if (!blocks(onAuthRequired, details)) {
        notify(onAuthRequired, details->toJSONString());
        return false;
    }

    dispatch(onAuthRequired, details->toJSONString(), [this, networkLoad = Ref { networkLoad }, challenge = AuthenticationChallenge { challenge }, negotiatedLegacyTLS, completionHandler = WTF::move(completionHandler)](RefPtr<JSON::Object>&& verdict) mutable {
        if (verdict && verdict->getBoolean("cancel"_s).value_or(false))
            return completionHandler(AuthenticationChallengeDisposition::UseCredential, { });
        if (RefPtr credentials = verdict ? verdict->getObject("authCredentials"_s) : nullptr)
            return completionHandler(AuthenticationChallengeDisposition::UseCredential, Credential { credentials->getString("username"_s), credentials->getString("password"_s), CredentialPersistence::ForSession });
        m_resumingChallenges.add(networkLoad.get());
        networkLoad->didReceiveChallenge(WTF::move(challenge), negotiatedLegacyTLS, WTF::move(completionHandler));
    });
    return true;
}

void LegacyExtensionNetwork::loaderDidFail(NetworkResourceLoader& loader, const ResourceError& error)
{
    if (RefPtr response = m_filteredResponses.get(loadRequestIdentifier(loader)))
        response->error = LegacyExtensions::networkErrorName(error);
    if (!observes(onErrorOccurred))
        return;
    m_loadErrors.set(loader, LegacyExtensions::networkErrorName(error));
}

bool LegacyExtensionNetwork::didReceivePendingWebSocketMessage(NetworkConnectionToWebProcess& connection, IPC::Decoder& decoder)
{
    auto iterator = m_pendingWebSockets.find(connection);
    if (iterator == m_pendingWebSockets.end() || !iterator->value.contains(decoder.destinationID()))
        return false;
    // A socket closed before it opened reports an abnormal closure.
    if (decoder.messageName() == IPC::MessageName::NetworkSocketChannel_Close) {
        iterator->value.remove(decoder.destinationID());
        if (auto handshakes = m_webSocketHandshakes.find(connection); handshakes != m_webSocketHandshakes.end()) {
            if (RefPtr handshake = handshakes->value.take(decoder.destinationID()))
                handshake->didComplete("net::ERR_ABORTED"_s);
        }
        if (auto results = m_webSocketProxyFilterResults.find(connection); results != m_webSocketProxyFilterResults.end())
            results->value.remove(decoder.destinationID());
        connection.connection().send(Messages::WebSocketChannel::DidClose { 1006, emptyString() }, decoder.destinationID());
    }
    return true;
}

// onCompleted and onErrorOccurred.
void LegacyExtensionNetwork::loaderDidFinish(NetworkResourceLoader& loader, NetworkResourceLoader::LoadResult result)
{
    bool succeeded = result == NetworkResourceLoader::LoadResult::Success;
    m_loadersWithDeliveredBody.remove(loader);
    auto url = currentURL(loader);
    auto error = m_loadErrors.take(loader);
    auto eventName = succeeded ? onCompleted : onErrorOccurred;
    if (!m_loaders.contains(loader) || !observes(eventName))
        return;
    if (!isInterceptable(url))
        return;
    auto details = loaderDetails(loader);
    if (succeeded)
        addResponseFields(details, loader.m_response);
    else {
        details->setBoolean("fromCache"_s, isFromCache(loader.m_response));
        if (!error.isNull())
            details->setString("error"_s, error);
        else
            details->setString("error"_s, result == NetworkResourceLoader::LoadResult::Cancel ? "net::ERR_ABORTED"_s : "net::ERR_FAILED"_s);
    }
    notify(eventName, details->toJSONString());
}

// webRequest.filterResponseData.

RefPtr<LegacyExtensionNetwork::FilteredResponse> LegacyExtensionNetwork::filteredResponse(uint64_t filterID) const
{
    auto requestIdentifier = m_responseFilterRequests.get(filterID);
    return requestIdentifier ? RefPtr { m_filteredResponses.get(requestIdentifier) } : nullptr;
}

void LegacyExtensionNetwork::sendFilterEvent(uint64_t filterID, ASCIILiteral event, RefPtr<SharedBuffer>&& data, const String& error)
{
    if (RefPtr networkProcess = m_networkProcess.get())
        networkProcess->parentProcessConnection()->send(Messages::LegacyExtensionNetworkProxy::ResponseFilterEvent(filterID, String { event }, IPC::SharedBufferReference { WTF::move(data) }, error), 0);
}

// A filter attaches to a load the extension can see, before its web process receives any of the body.
void LegacyExtensionNetwork::createResponseFilter(uint64_t filterID, uint64_t requestIdentifier, String&& extensionKey, String&& websiteAccess)
{
    if (!filterID || m_responseFilterRequests.contains(filterID))
        return;
    auto reject = [&] {
        sendFilterEvent(filterID, "error"_s, nullptr, "Invalid request ID"_s);
    };
    RefPtr<NetworkResourceLoader> loader;
    for (auto& candidate : m_loaders) {
        if (loadRequestIdentifier(candidate) == requestIdentifier) {
            loader = &candidate;
            break;
        }
    }
    if (!loader || loader->isCrossOriginPrefetch() || loader->m_serviceWorkerFetchTask || m_loadersWithDeliveredBody.contains(*loader))
        return reject();
    auto& url = (loader->m_networkLoad ? loader->m_networkLoad->currentRequest() : loader->originalRequest()).url();
    auto accessValue = JSON::Value::parseJSON(websiteAccess);
    RefPtr accessObject = accessValue ? accessValue->asObject() : nullptr;
    if (url.protocolIs("safari-extension"_s) ? url.host() != extensionKey : !accessObject || !WebsiteAccess::fromJSON(*accessObject).allows(url))
        return reject();

    Ref response = m_filteredResponses.ensure(requestIdentifier, [&] {
        Ref response = adoptRef(*new FilteredResponse);
        response->requestIdentifier = requestIdentifier;
        response->coreIdentifier = loader->coreIdentifier();
        response->loader = *loader;
        response->filter = LegacyExtensionResponseFilter::create([this](uint64_t filterID, ASCIILiteral event, RefPtr<SharedBuffer>&& data, const String& error) {
            sendFilterEvent(filterID, event, WTF::move(data), error);
        }, [this, requestIdentifier](RefPtr<SharedBuffer>&& data) {
            outputFilteredResponse(requestIdentifier, WTF::move(data));
        });
        return response;
    }).iterator->value;
    if (!response->filter->canAttach())
        return reject();
    response->filter->attach(filterID);
    m_responseFilterRequests.set(filterID, requestIdentifier);
}

// The filters' output: the body the web process receives, then its end, with the network's metrics when the
// network finished first; a synchronous load's reply carries the whole output. A loader whose cleanup waited on
// the output is cleaned up after it.
void LegacyExtensionNetwork::outputFilteredResponse(uint64_t requestIdentifier, RefPtr<SharedBuffer>&& data)
{
    RefPtr response = m_filteredResponses.get(requestIdentifier);
    RefPtr loader = response ? response->loader.get() : nullptr;
    if (!loader)
        return;
    if (response->synchronousReply) {
        if (data) {
            response->synchronousBody.append(data->span());
            return;
        }
        std::exchange(response->synchronousReply, nullptr)(response->synchronousError, response->synchronousResponse, std::exchange(response->synchronousBody, { }));
    } else if (data) {
        IPC::SharedBufferReference reference { data.releaseNonNull() };
        reference.transferOwnershipToReceiver(MemoryLedger::Default);
        RefPtr networkLoad = loader->m_networkLoad;
        loader->send(Messages::WebResourceLoader::DidReceiveData(WTF::move(reference), networkLoad ? networkLoad->bytesTransferredOverNetwork() : response->bytesTransferredOverNetwork));
        return;
    } else {
        NetworkLoadMetrics metrics;
        if (response->metrics)
            metrics = *response->metrics;
        else
            metrics.markComplete();
        loader->send(Messages::WebResourceLoader::DidFinishResourceLoad(metrics));
    }
    if (response->cleanupIsDeferred) {
        removeFilteredResponse(*response);
        loader->cleanup(NetworkResourceLoader::LoadResult::Success);
    }
}

// A synchronous load waiting on its filters' output is answered as a cancelled one is.
void LegacyExtensionNetwork::removeFilteredResponse(FilteredResponse& response)
{
    if (auto reply = std::exchange(response.synchronousReply, nullptr))
        reply(ResourceError { ResourceError::Type::Cancellation }, response.synchronousResponse, { });
    for (auto filterID : response.filter->filterIDs())
        m_responseFilterRequests.remove(filterID);
    m_filteredResponses.remove(response.requestIdentifier);
}

bool LegacyExtensionNetwork::deferCleanup(NetworkResourceLoader& loader, NetworkResourceLoader::LoadResult result)
{
    RefPtr response = m_filteredResponses.get(loadRequestIdentifier(loader));
    if (!response)
        return false;
    if (response->filter->hasFinishedOutput()) {
        removeFilteredResponse(*response);
        return false;
    }
    // The finished network load goes as cleanup lets it go, so cancelling the loader leaves the load's cache entry.
    if (result == NetworkResourceLoader::LoadResult::Success && response->inputFinished) {
        response->cleanupIsDeferred = true;
        m_deferredCleanupURLs.set(loader, currentURL(loader));
        if (RefPtr networkLoad = std::exchange(loader.m_networkLoad, nullptr)) {
            response->bytesTransferredOverNetwork = networkLoad->bytesTransferredOverNetwork();
            networkLoad->clearClient();
        }
        return true;
    }
    String error;
    if (result != NetworkResourceLoader::LoadResult::Success)
        error = response->error.isNull() ? "net::ERR_ABORTED"_s : response->error;
    else if (loader.m_serviceWorkerFetchTask)
        error = "The response came from a service worker."_s;
    else
        error = "net::ERR_FAILED"_s;
    response->filter->fail(error);
    removeFilteredResponse(*response);
    return false;
}

URL LegacyExtensionNetwork::currentURL(NetworkResourceLoader& loader) const
{
    if (RefPtr networkLoad = loader.m_networkLoad)
        return networkLoad->currentRequest().url();
    if (auto url = m_deferredCleanupURLs.get(loader); !url.isNull())
        return url;
    return loader.originalRequest().url();
}

bool LegacyExtensionNetwork::filterResponseData(NetworkResourceLoader& loader, const FragmentedSharedBuffer& buffer)
{
    RefPtr response = m_filteredResponses.get(loadRequestIdentifier(loader));
    if (!response) {
        if (m_loaders.contains(loader))
            m_loadersWithDeliveredBody.add(loader);
        return false;
    }
    response->filter->receive(buffer.makeContiguous());
    return true;
}

bool LegacyExtensionNetwork::finishFilteredResponse(NetworkResourceLoader& loader, const NetworkLoadMetrics& metrics)
{
    RefPtr response = m_filteredResponses.get(loadRequestIdentifier(loader));
    if (!response) {
        if (m_loaders.contains(loader))
            m_loadersWithDeliveredBody.add(loader);
        return false;
    }
    if (!response->inputFinished) {
        response->inputFinished = true;
        response->metrics = metrics;
        response->filter->finishInput();
    }
    return true;
}

bool LegacyExtensionNetwork::filtersResponse(NetworkResourceLoader& loader) const
{
    return m_filteredResponses.contains(loadRequestIdentifier(loader));
}

auto LegacyExtensionNetwork::filterSynchronousReply(NetworkConnectionToWebProcess& connection, ResourceLoaderIdentifier coreIdentifier, SynchronousReply&& reply) -> SynchronousReply
{
    return [this, weakConnection = WeakPtr { connection }, coreIdentifier, reply = WTF::move(reply)](const ResourceError& error, const ResourceResponse response, Vector<uint8_t>&& body) mutable {
        RefPtr<FilteredResponse> filtered;
        for (auto& candidate : m_filteredResponses.values()) {
            RefPtr loader = candidate->loader.get();
            if (candidate->coreIdentifier && *candidate->coreIdentifier == coreIdentifier && loader && &loader->connectionToWebProcess() == weakConnection.get()) {
                filtered = candidate.ptr();
                break;
            }
        }
        if (!filtered || filtered->inputFinished)
            return reply(error, response, WTF::move(body));
        filtered->inputFinished = true;
        if (!error.isNull()) {
            filtered->error = LegacyExtensions::networkErrorName(error);
            return reply(error, response, WTF::move(body));
        }
        filtered->synchronousReply = WTF::move(reply);
        filtered->synchronousError = error;
        filtered->synchronousResponse = response;
        filtered->filter->receive(SharedBuffer::create(WTF::move(body)));
        filtered->filter->finishInput();
    };
}

void LegacyExtensionNetwork::writeResponseFilter(uint64_t filterID, IPC::SharedBufferReference&& data, uint64_t dispatched)
{
    RefPtr response = filteredResponse(filterID);
    if (!response)
        return;
    RefPtr buffer = data.unsafeBuffer();
    response->filter->write(filterID, buffer ? buffer.releaseNonNull() : SharedBuffer::create(), dispatched);
}

void LegacyExtensionNetwork::closeResponseFilter(uint64_t filterID)
{
    if (RefPtr response = filteredResponse(filterID))
        response->filter->close(filterID);
}

void LegacyExtensionNetwork::disconnectResponseFilter(uint64_t filterID, uint64_t dispatched)
{
    if (RefPtr response = filteredResponse(filterID))
        response->filter->disconnect(filterID, dispatched);
}

void LegacyExtensionNetwork::suspendResponseFilter(uint64_t filterID)
{
    if (RefPtr response = filteredResponse(filterID))
        response->filter->suspend(filterID);
}

void LegacyExtensionNetwork::resumeResponseFilter(uint64_t filterID)
{
    if (RefPtr response = filteredResponse(filterID))
        response->filter->resume(filterID);
}

} // namespace WebKit
