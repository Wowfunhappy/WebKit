#include "config.h"
#include "LegacyExtensionNetwork.h"

#include "APIError.h"
#include "Decoder.h"
#include "LegacyExtensionNetworkMessages.h"
#include "LegacyExtensionNetworkProxyMessages.h"
#include "MessageNames.h"
#include "NetworkCache.h"
#include "NetworkCacheEntry.h"
#include "NetworkConnectionToWebProcess.h"
#include "NetworkLoad.h"
#include "NetworkProcess.h"
#include "NetworkResourceLoader.h"
#include "WebErrors.h"
#include "WebSocketChannelMessages.h"
#include <WebCore/ClientOrigin.h>
#include <WebCore/HTTPHeaderMap.h>
#include <WebCore/HTTPStatusCodes.h>
#include <WebCore/ResourceError.h>
#include <WebCore/ResourceRequest.h>
#include <WebCore/ResourceResponse.h>
#include <WebCore/SecurityOrigin.h>
#include <wtf/ProcessID.h>
#include <wtf/RunLoop.h>
#include <wtf/WallTime.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringToIntegerConversion.h>

namespace WebKit {

using namespace WebCore;

static constexpr auto onBeforeRequest = "onBeforeRequest"_s;
static constexpr auto onSendHeaders = "onSendHeaders"_s;
static constexpr auto onBeforeRedirect = "onBeforeRedirect"_s;
static constexpr auto onHeadersReceived = "onHeadersReceived"_s;
static constexpr auto onResponseStarted = "onResponseStarted"_s;
static constexpr auto onCompleted = "onCompleted"_s;
static constexpr auto onErrorOccurred = "onErrorOccurred"_s;

// The WebExtensions resource type of a request.
static ASCIILiteral resourceType(const ResourceRequest& request, FetchOptions::Destination destination, bool isMainFrameLoad)
{
    if (isMainFrameLoad)
        return "main_frame"_s;

    switch (destination) {
    case FetchOptions::Destination::Document:
    case FetchOptions::Destination::Iframe:
        return "sub_frame"_s;
    case FetchOptions::Destination::Report:
        return "csp_report"_s;
    default:
        break;
    }

    switch (request.requester()) {
    case ResourceRequestRequester::XHR:
    case ResourceRequestRequester::Fetch:
    case ResourceRequestRequester::EventSource:
        return "xmlhttprequest"_s;
    case ResourceRequestRequester::Ping:
    case ResourceRequestRequester::Beacon:
        return "ping"_s;
    default:
        break;
    }

    switch (destination) {
    case FetchOptions::Destination::Style:
    case FetchOptions::Destination::Xslt:
        return "stylesheet"_s;
    case FetchOptions::Destination::Script:
    case FetchOptions::Destination::Json:
    case FetchOptions::Destination::Worker:
    case FetchOptions::Destination::Sharedworker:
    case FetchOptions::Destination::Serviceworker:
    case FetchOptions::Destination::Audioworklet:
    case FetchOptions::Destination::Paintworklet:
        return "script"_s;
    case FetchOptions::Destination::Image:
        return "image"_s;
    case FetchOptions::Destination::Font:
        return "font"_s;
    case FetchOptions::Destination::Audio:
    case FetchOptions::Destination::Video:
    case FetchOptions::Destination::Track:
        return "media"_s;
    case FetchOptions::Destination::Embed:
    case FetchOptions::Destination::Object:
        return "object"_s;
    default:
        return "other"_s;
    }
}

// The document a request is made for: a frame's navigation is made for its parent's document.
static URL documentURLForLoad(const NetworkResourceLoadParameters& parameters, ASCIILiteral type)
{
    if (type == "main_frame"_s)
        return { };
    if (type == "sub_frame"_s)
        return parameters.parentFrameURL;
    return parameters.documentURL;
}

static bool isInterceptable(const URL& url)
{
    return url.protocolIsInHTTPFamily() || url.protocolIs("ws"_s) || url.protocolIs("wss"_s) || url.protocolIs("safari-extension"_s);
}

// A WebExtensions match pattern (https://developer.chrome.com/docs/extensions/develop/concepts/match-patterns),
// as the API script's filters compile it: the path part matches the URL's path, query and fragment.
static bool globMatches(StringView pattern, StringView text)
{
    size_t patternIndex = 0;
    size_t textIndex = 0;
    std::optional<size_t> starIndex;
    size_t starTextIndex = 0;
    while (textIndex < text.length()) {
        if (patternIndex < pattern.length() && pattern[patternIndex] == '*') {
            starIndex = patternIndex++;
            starTextIndex = textIndex;
        } else if (patternIndex < pattern.length() && pattern[patternIndex] == text[textIndex]) {
            patternIndex++;
            textIndex++;
        } else if (starIndex) {
            patternIndex = *starIndex + 1;
            textIndex = ++starTextIndex;
        } else
            return false;
    }
    while (patternIndex < pattern.length() && pattern[patternIndex] == '*')
        patternIndex++;
    return patternIndex == pattern.length();
}

static bool matchPatternMatches(StringView pattern, const URL& url)
{
    if (pattern == "<all_urls>"_s)
        return url.protocolIsInHTTPFamily() || url.protocolIs("ws"_s) || url.protocolIs("wss"_s) || url.protocolIs("ftp"_s) || url.protocolIsFile() || url.protocolIsData() || url.protocolIs("safari-extension"_s);

    size_t schemeEnd = pattern.find("://"_s);
    if (schemeEnd == notFound)
        return false;
    auto scheme = pattern.left(schemeEnd);
    if (scheme == "*"_s) {
        if (!url.protocolIsInHTTPFamily() && !url.protocolIs("ws"_s) && !url.protocolIs("wss"_s))
            return false;
    } else if (!url.protocolIs(scheme))
        return false;

    auto rest = pattern.substring(schemeEnd + 3);
    size_t pathStart = rest.find('/');
    if (pathStart == notFound)
        return false;
    auto host = rest.left(pathStart);
    auto urlHost = url.host();
    if (host.startsWith("*."_s)) {
        auto domain = host.substring(2);
        if (!equalIgnoringASCIICase(urlHost, domain) && !(urlHost.length() > domain.length() && urlHost[urlHost.length() - domain.length() - 1] == '.' && urlHost.endsWithIgnoringASCIICase(domain)))
            return false;
    } else if (host != "*"_s && !equalIgnoringASCIICase(urlHost, host))
        return false;

    return globMatches(rest.substring(pathStart), StringView(url.string()).substring(url.pathStart()));
}

// A WebExtensions network error name (net::ERR_*) for a failed load.
static ASCIILiteral networkErrorName(const ResourceError& error)
{
    if (error.domain() == API::Error::webKitPolicyErrorDomain() && error.errorCode() == API::Error::Policy::FrameLoadBlockedByContentBlocker)
        return "net::ERR_BLOCKED_BY_CLIENT"_s;
    if (error.isCancellation())
        return "net::ERR_ABORTED"_s;
    if (error.isTimeout())
        return "net::ERR_TIMED_OUT"_s;
    if (error.domain() != "NSURLErrorDomain"_s)
        return "net::ERR_FAILED"_s;
    switch (error.errorCode()) {
    case -999: // NSURLErrorCancelled
        return "net::ERR_ABORTED"_s;
    case -1000: // NSURLErrorBadURL
        return "net::ERR_INVALID_URL"_s;
    case -1001: // NSURLErrorTimedOut
        return "net::ERR_TIMED_OUT"_s;
    case -1002: // NSURLErrorUnsupportedURL
        return "net::ERR_UNKNOWN_URL_SCHEME"_s;
    case -1003: // NSURLErrorCannotFindHost
    case -1006: // NSURLErrorDNSLookupFailed
        return "net::ERR_NAME_NOT_RESOLVED"_s;
    case -1004: // NSURLErrorCannotConnectToHost
        return "net::ERR_CONNECTION_REFUSED"_s;
    case -1005: // NSURLErrorNetworkConnectionLost
        return "net::ERR_CONNECTION_CLOSED"_s;
    case -1007: // NSURLErrorHTTPTooManyRedirects
        return "net::ERR_TOO_MANY_REDIRECTS"_s;
    case -1009: // NSURLErrorNotConnectedToInternet
        return "net::ERR_INTERNET_DISCONNECTED"_s;
    case -1011: // NSURLErrorBadServerResponse
    case -1017: // NSURLErrorCannotParseResponse
        return "net::ERR_INVALID_RESPONSE"_s;
    case -1100: // NSURLErrorFileDoesNotExist
        return "net::ERR_FILE_NOT_FOUND"_s;
    case -1200: // NSURLErrorSecureConnectionFailed
        return "net::ERR_SSL_PROTOCOL_ERROR"_s;
    case -1201: // NSURLErrorServerCertificateHasBadDate
    case -1204: // NSURLErrorServerCertificateNotYetValid
        return "net::ERR_CERT_DATE_INVALID"_s;
    case -1202: // NSURLErrorServerCertificateUntrusted
    case -1203: // NSURLErrorServerCertificateHasUnknownRoot
        return "net::ERR_CERT_AUTHORITY_INVALID"_s;
    default:
        return "net::ERR_FAILED"_s;
    }
}

static double timeStamp()
{
    return WallTime::now().secondsSinceEpoch().milliseconds();
}

static Ref<JSON::Array> headersArray(const HTTPHeaderMap& headers)
{
    auto array = JSON::Array::create();
    for (auto& header : headers) {
        auto entry = JSON::Object::create();
        entry->setString("name"_s, header.key);
        entry->setString("value"_s, header.value);
        array->pushObject(WTF::move(entry));
    }
    return array;
}

static HTTPHeaderMap headerMap(JSON::Array& array)
{
    HTTPHeaderMap headers;
    for (auto& value : array) {
        RefPtr header = value->asObject();
        if (!header)
            continue;
        auto name = header->getString("name"_s);
        if (name.isEmpty())
            continue;
        headers.add(name, header->getString("value"_s));
    }
    return headers;
}

LegacyExtensionNetwork& LegacyExtensionNetwork::singleton()
{
    static NeverDestroyed<LegacyExtensionNetwork> network;
    return network;
}

void LegacyExtensionNetwork::initialize(NetworkProcess& networkProcess)
{
    m_networkProcess = networkProcess;
    networkProcess.addMessageReceiver(Messages::LegacyExtensionNetwork::messageReceiverName(), *this);
}

static std::optional<Vector<String>> stringsFromJSON(const JSON::Object& object, const String& key)
{
    RefPtr array = object.getArray(key);
    if (!array)
        return std::nullopt;
    Vector<String> strings;
    for (auto& value : *array) {
        if (auto string = value->asString(); !string.isNull())
            strings.append(WTF::move(string));
    }
    return strings;
}

void LegacyExtensionNetwork::setListeners(Vector<String>&& observedEvents, String&& blockingListeners)
{
    m_observedEvents.clear();
    for (auto& event : observedEvents)
        m_observedEvents.add(WTF::move(event));

    m_blockingListeners.clear();
    RefPtr value = JSON::Value::parseJSON(blockingListeners);
    RefPtr events = value ? value->asObject() : nullptr;
    if (!events)
        return;
    for (auto& [eventName, listenersValue] : *events) {
        RefPtr listeners = listenersValue->asArray();
        if (!listeners)
            continue;
        Vector<BlockingListener> eventListeners;
        for (auto& listenerValue : *listeners) {
            RefPtr listener = listenerValue->asObject();
            if (!listener)
                continue;
            eventListeners.append({ listener->getString("extension"_s), stringsFromJSON(*listener, "urls"_s), stringsFromJSON(*listener, "types"_s), listener->getDouble("tabId"_s) });
        }
        if (!eventListeners.isEmpty())
            m_blockingListeners.add(eventName, WTF::move(eventListeners));
    }
}

// Whether a blocking listener's filter matches the event's details, as the API script decides for each
// listener; an extension's listeners see its own safari-extension:// resources and no other extension's.
bool LegacyExtensionNetwork::blocks(ASCIILiteral eventName, const JSON::Object& details) const
{
    auto iterator = m_blockingListeners.find(String { eventName });
    if (iterator == m_blockingListeners.end())
        return false;
    URL url { details.getString("url"_s) };
    auto type = details.getString("type"_s);
    auto tabID = details.getDouble("tabId"_s);
    for (auto& listener : iterator->value) {
        if (url.protocolIs("safari-extension"_s) && url.host() != listener.extensionKey)
            continue;
        // The router reports -1 for a load it finds no tab for, which only it can tell.
        if (listener.tabID && *listener.tabID != -1 && (!tabID || *tabID != *listener.tabID))
            continue;
        if (listener.types && !listener.types->contains(type))
            continue;
        if (listener.urlPatterns && !listener.urlPatterns->containsIf([&](auto& pattern) { return matchPatternMatches(pattern, url); }))
            continue;
        return true;
    }
    return false;
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

String LegacyExtensionNetwork::requestIdentifier(NetworkLoadChecker& checker)
{
    uint64_t identifier;
    if (RefPtr loader = checker.m_networkResourceLoader.get())
        identifier = loader->identifier().toUInt64();
    else {
        identifier = m_checkerRequestIdentifiers.ensure(checker, [&] {
            return m_nextRequestIdentifier++;
        }).iterator->value;
        return makeString(getCurrentProcessID(), "-ping-"_s, identifier);
    }
    return makeString(getCurrentProcessID(), '-', identifier);
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
    if (RefPtr origin = checker.origin(); origin && !isMainFrameLoad)
        details->setString("initiator"_s, origin->toString());
    return details;
}

Ref<JSON::Object> LegacyExtensionNetwork::loaderDetails(NetworkResourceLoader& loader)
{
    auto& parameters = loader.parameters();
    auto& request = loader.originalRequest();
    auto details = JSON::Object::create();
    details->setString("requestId"_s, makeString(getCurrentProcessID(), '-', loader.identifier().toUInt64()));
    details->setString("url"_s, (loader.m_networkLoad ? loader.m_networkLoad->currentRequest() : request).url().string());
    details->setString("method"_s, request.httpMethod());
    details->setString("type"_s, resourceType(request, parameters.options.destination, loader.isMainFrameLoad()));
    details->setDouble("timeStamp"_s, timeStamp());
    details->setDouble("tabId"_s, static_cast<double>(parameters.webPageProxyID.toUInt64()));
    details->setDouble("frameId"_s, static_cast<double>(parameters.webFrameID.toUInt64()));
    details->setDouble("parentFrameId"_s, parameters.parentFrameID ? static_cast<double>(parameters.parentFrameID->toUInt64()) : 0);
    if (!loader.isMainFrameLoad()) {
        if (auto documentURL = documentURLForLoad(parameters, resourceType(request, parameters.options.destination, false)); !documentURL.isEmpty())
            details->setString("documentUrl"_s, documentURL.string());
        if (parameters.sourceOrigin)
            details->setString("initiator"_s, parameters.sourceOrigin->toString());
    }
    return details;
}

Ref<JSON::Object> LegacyExtensionNetwork::responseDetails(NetworkResourceLoader& loader, const ResourceResponse& response, bool fromCache)
{
    auto details = loaderDetails(loader);
    details->setString("url"_s, response.url().string());
    details->setDouble("statusCode"_s, response.httpStatusCode());
    details->setString("statusLine"_s, makeString(response.httpVersion().isEmpty() ? "HTTP/1.1"_s : response.httpVersion(), ' ', response.httpStatusCode(), ' ', response.httpStatusText()));
    details->setArray("responseHeaders"_s, headersArray(response.httpHeaderFields()));
    details->setBoolean("fromCache"_s, fromCache);
    return details;
}

// onBeforeRequest and onSendHeaders.
bool LegacyExtensionNetwork::interceptRequest(NetworkLoadChecker& checker, ResourceRequest& request, ContentSecurityPolicyClient* client, NetworkLoadChecker::ValidationHandler& handler)
{
    if (m_resumingRequests.remove(checker))
        return false;
    if (m_observedEvents.isEmpty() || !isInterceptable(request.url()))
        return false;

    if (checker.isRedirected() && observes(onBeforeRedirect)) {
        auto details = requestDetails(checker, request);
        details->setString("url"_s, checker.m_previousURL.string());
        details->setString("redirectUrl"_s, request.url().string());
        notify(onBeforeRedirect, details->toJSONString());
    }

    auto details = requestDetails(checker, request);
    auto sendHeaders = [this](NetworkLoadChecker& checker, const ResourceRequest& request) {
        if (!observes(onSendHeaders))
            return;
        auto details = requestDetails(checker, request);
        details->setArray("requestHeaders"_s, headersArray(request.httpHeaderFields()));
        notify(onSendHeaders, details->toJSONString());
    };

    if (!blocks(onBeforeRequest, details)) {
        if (observes(onBeforeRequest))
            notify(onBeforeRequest, details->toJSONString());
        sendHeaders(checker, request);
        return false;
    }

    // The checker's one content security policy client is its loader, which the resumed check asks again.
    bool hasClient = !!client;
    bool isMainFrameLoad = checker.m_requestLoadType == NetworkLoadChecker::LoadType::MainFrame;
    dispatch(onBeforeRequest, details->toJSONString(), [this, weakChecker = WeakPtr { checker }, request = WTF::move(request), hasClient, handler = WTF::move(handler), isMainFrameLoad, sendHeaders = WTF::move(sendHeaders)](RefPtr<JSON::Object>&& response) mutable {
        RefPtr checker = weakChecker.get();
        if (!checker)
            return handler(ResourceError { ResourceError::Type::Cancellation });
        RefPtr loader = checker->m_networkResourceLoader.get();
        if (hasClient && !loader)
            return handler(ResourceError { ResourceError::Type::Cancellation });

        if (response && response->getBoolean("cancel"_s).value_or(false)) {
            // A navigation the extension stops is interrupted, not failed: no error page replaces it.
            if (!isMainFrameLoad)
                return handler(blockedByContentBlockerError(request));
            if (loader)
                m_loadsBlockedByExtensions.add(*loader);
            return handler(interruptedForPolicyChangeError(request));
        }

        auto originalRequest = request;
        if (response) {
            if (auto redirectURL = response->getString("redirectUrl"_s); !redirectURL.isEmpty()) {
                URL url { redirectURL };
                if (url.isValid())
                    request.setURL(WTF::move(url));
            }
            if (RefPtr headers = response->getArray("requestHeaders"_s))
                request.setHTTPHeaderFields(headerMap(*headers));
        }

        // A main frame the extension redirects follows a redirect, as a navigation WebKit's own content
        // rules redirect does; a subresource loads from the new URL in place.
        if (isMainFrameLoad && !checker->isRedirected() && request.url() != originalRequest.url()) {
            auto redirectResponse = ResourceResponse::syntheticRedirectResponse(originalRequest.url(), request.url());
            return handler(NetworkLoadChecker::RedirectionTriplet { WTF::move(originalRequest), WTF::move(request), WTF::move(redirectResponse) });
        }

        sendHeaders(*checker, request);
        m_resumingRequests.add(*checker);
        checker->checkRequest(WTF::move(request), hasClient ? loader.get() : nullptr, WTF::move(handler));
    });
    return true;
}

// onHeadersReceived and onResponseStarted, for a response from the network.
bool LegacyExtensionNetwork::interceptResponse(NetworkResourceLoader& loader, ResourceResponse& response, PrivateRelayed privateRelayed, ResponseCompletionHandler& completionHandler)
{
    if (m_resumingResponses.remove(loader))
        return false;
    if (m_observedEvents.isEmpty() || !isInterceptable(response.url()))
        return false;
    // A successful revalidation reaches the extensions as the cached response.
    if (loader.m_cacheEntryForValidation && response.httpStatusCode() == httpStatus304NotModified)
        return false;

    auto details = responseDetails(loader, response, false);
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
        if (verdict && verdict->getBoolean("cancel"_s).value_or(false)) {
            completionHandler(PolicyAction::Ignore);
            RunLoop::mainSingleton().dispatch([weakLoader = WTF::move(weakLoader)] {
                RefPtr loader = weakLoader.get();
                if (loader && loader->m_networkLoad)
                    loader->didFailLoading(blockedByContentBlockerError(loader->originalRequest()));
            });
            return;
        }
        if (verdict) {
            if (RefPtr headers = verdict->getArray("responseHeaders"_s)) {
                auto data = response.crossThreadData();
                data.httpHeaderFields = headerMap(*headers);
                response = ResourceResponse::fromCrossThreadData(WTF::move(data));
            }
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
    if (m_observedEvents.isEmpty() || !entry || !isInterceptable(entry->response().url()))
        return false;

    auto details = responseDetails(loader, entry->response(), true);
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
            loader->didFailLoading(blockedByContentBlockerError(loader->originalRequest()));
            return;
        }
        if (verdict) {
            RefPtr headers = verdict->getArray("responseHeaders"_s);
            RefPtr cache = loader->m_cache;
            if (headers && cache) {
                auto data = entry->response().crossThreadData();
                data.httpHeaderFields = headerMap(*headers);
                RefPtr<FragmentedSharedBuffer> buffer = entry->buffer();
                entry = cache->makeEntry(loader->originalRequest(), ResourceResponse::fromCrossThreadData(WTF::move(data)), entry->privateRelayed(), WTF::move(buffer));
            }
        }
        if (observes(onResponseStarted))
            notify(onResponseStarted, responseDetails(*loader, entry->response(), true)->toJSONString());
        m_resumingCacheEntries.add(*loader);
        loader->didRetrieveCacheEntry(WTF::move(entry));
    });
    return true;
}

// onBeforeRequest for a WebSocket handshake.
bool LegacyExtensionNetwork::interceptWebSocket(NetworkConnectionToWebProcess& connection, const ResourceRequest& request, WebCore::WebSocketIdentifier identifier, WebPageProxyIdentifier webPageProxyID, std::optional<FrameIdentifier> frameID, const ClientOrigin& clientOrigin, Function<void()>&& createChannel)
{
    if (!observes(onBeforeRequest))
        return false;

    auto details = JSON::Object::create();
    details->setString("requestId"_s, makeString(getCurrentProcessID(), "-ws-"_s, identifier.toUInt64()));
    details->setString("url"_s, request.url().string());
    details->setString("method"_s, "GET"_s);
    details->setString("type"_s, "websocket"_s);
    details->setDouble("timeStamp"_s, timeStamp());
    details->setDouble("tabId"_s, static_cast<double>(webPageProxyID.toUInt64()));
    details->setDouble("frameId"_s, frameID ? static_cast<double>(frameID->toUInt64()) : 0);
    details->setDouble("parentFrameId"_s, 0);
    details->setString("initiator"_s, clientOrigin.clientOrigin.toString());

    if (!blocks(onBeforeRequest, details)) {
        notify(onBeforeRequest, details->toJSONString());
        return false;
    }

    m_pendingWebSockets.ensure(connection, [] { return HashSet<uint64_t> { }; }).iterator->value.add(identifier.toUInt64());
    dispatch(onBeforeRequest, details->toJSONString(), [this, weakConnection = WeakPtr { connection }, identifier, createChannel = WTF::move(createChannel)](RefPtr<JSON::Object>&& verdict) mutable {
        RefPtr connection = weakConnection.get();
        if (!connection)
            return;
        auto iterator = m_pendingWebSockets.find(*connection);
        if (iterator == m_pendingWebSockets.end() || !iterator->value.remove(identifier.toUInt64()))
            return;
        Ref ipcConnection = connection->connection();
        if (!ipcConnection->isValid())
            return;
        if (verdict && verdict->getBoolean("cancel"_s).value_or(false)) {
            ipcConnection->send(Messages::WebSocketChannel::DidReceiveMessageError { "WebSocket connection was blocked by an extension"_s }, identifier.toUInt64());
            ipcConnection->send(Messages::WebSocketChannel::DidClose { 1006, emptyString() }, identifier.toUInt64());
            return;
        }
        createChannel();
    });
    return true;
}

void LegacyExtensionNetwork::loaderDidFail(NetworkResourceLoader& loader, const ResourceError& error)
{
    if (!observes(onErrorOccurred))
        return;
    m_loadErrors.set(loader, m_loadsBlockedByExtensions.contains(loader) ? "net::ERR_BLOCKED_BY_CLIENT"_s : networkErrorName(error));
}

bool LegacyExtensionNetwork::didReceivePendingWebSocketMessage(NetworkConnectionToWebProcess& connection, IPC::Decoder& decoder)
{
    auto iterator = m_pendingWebSockets.find(connection);
    if (iterator == m_pendingWebSockets.end() || !iterator->value.contains(decoder.destinationID()))
        return false;
    // A socket closed before it opened reports an abnormal closure.
    if (decoder.messageName() == IPC::MessageName::NetworkSocketChannel_Close) {
        iterator->value.remove(decoder.destinationID());
        connection.connection().send(Messages::WebSocketChannel::DidClose { 1006, emptyString() }, decoder.destinationID());
    }
    return true;
}

// onCompleted and onErrorOccurred.
void LegacyExtensionNetwork::loaderDidFinish(NetworkResourceLoader& loader, NetworkResourceLoader::LoadResult result)
{
    bool succeeded = result == NetworkResourceLoader::LoadResult::Success;
    auto error = m_loadErrors.take(loader);
    bool wasBlocked = m_loadsBlockedByExtensions.remove(loader);
    auto eventName = succeeded ? onCompleted : onErrorOccurred;
    if (!observes(eventName))
        return;
    auto& request = loader.m_networkLoad ? loader.m_networkLoad->currentRequest() : loader.originalRequest();
    if (!isInterceptable(request.url()))
        return;
    auto details = loaderDetails(loader);
    if (succeeded) {
        details->setDouble("statusCode"_s, loader.m_response.httpStatusCode());
        details->setBoolean("fromCache"_s, loader.m_response.source() != ResourceResponse::Source::Network);
    } else if (!error.isNull())
        details->setString("error"_s, error);
    else
        details->setString("error"_s, wasBlocked ? "net::ERR_BLOCKED_BY_CLIENT"_s : result == NetworkResourceLoader::LoadResult::Cancel ? "net::ERR_ABORTED"_s : "net::ERR_FAILED"_s);
    notify(eventName, details->toJSONString());
}

} // namespace WebKit
