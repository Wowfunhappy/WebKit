#include "config.h"
#include "LegacyExtensionNetwork.h"

#include "AuthenticationChallengeDisposition.h"
#include "Decoder.h"
#include "LegacyExtensionErrors.h"
#include "LegacyExtensionNetworkMessages.h"
#include "LegacyExtensionNetworkProxyMessages.h"
#include "LegacyExtensionScheme.h"
#include "MessageNames.h"
#include "NetworkCache.h"
#include "NetworkCacheEntry.h"
#include "NetworkConnectionToWebProcess.h"
#include "NetworkDataTaskCurlCocoa.h"
#include "NetworkLoad.h"
#include "NetworkProcess.h"
#include "NetworkResourceLoader.h"
#include "WebErrors.h"
#include "WebSocketChannelMessages.h"
#include <WebCore/AuthenticationChallenge.h>
#include <WebCore/ClientOrigin.h>
#include <WebCore/Credential.h>
#include <WebCore/CocoaCurlTransfer.h>
#include <WebCore/CocoaCookie.h>
#include <WebCore/CookieJar.h>
#include <WebCore/HTTPHeaderMap.h>
#include <WebCore/HTTPStatusCodes.h>
#include <WebCore/ParsedContentType.h>
#include <WebCore/ResourceError.h>
#include <WebCore/ResourceRequest.h>
#include <WebCore/ResourceResponse.h>
#include <WebCore/NetworkStorageSession.h>
#include <WebCore/SecurityOrigin.h>
#include <wtf/ProcessID.h>
#include <wtf/cocoa/RuntimeApplicationChecksCocoa.h>
#include <wtf/RunLoop.h>
#include <wtf/URLParser.h>
#include <wtf/WallTime.h>
#include <wtf/text/Base64.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringToIntegerConversion.h>

namespace WebKit {

using namespace WebCore;

static constexpr auto onBeforeRequest = "onBeforeRequest"_s;
static constexpr auto onBeforeSendHeaders = "onBeforeSendHeaders"_s;
static constexpr auto onSendHeaders = "onSendHeaders"_s;
static constexpr auto onBeforeRedirect = "onBeforeRedirect"_s;
static constexpr auto onHeadersReceived = "onHeadersReceived"_s;
static constexpr auto onResponseStarted = "onResponseStarted"_s;
static constexpr auto onCompleted = "onCompleted"_s;
static constexpr auto onErrorOccurred = "onErrorOccurred"_s;
static constexpr auto onAuthRequired = "onAuthRequired"_s;
static constexpr auto requestBodyOption = "requestBody"_s;
static constexpr auto extraHeadersOption = "extraHeaders"_s;

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

static bool isFromCache(const ResourceResponse& response)
{
    switch (response.source()) {
    case ResourceResponse::Source::DiskCache:
    case ResourceResponse::Source::DiskCacheAfterValidation:
    case ResourceResponse::Source::MemoryCache:
    case ResourceResponse::Source::MemoryCacheAfterValidation:
        return true;
    default:
        return false;
    }
}

static void addResponseFields(JSON::Object& details, const ResourceResponse& response)
{
    details.setDouble("statusCode"_s, response.httpStatusCode());
    details.setString("statusLine"_s, makeString(response.httpVersion().isEmpty() ? "HTTP/1.1"_s : response.httpVersion(), ' ', response.httpStatusCode(), ' ', response.httpStatusText()));
    details.setArray("responseHeaders"_s, headersArray(response.httpHeaderFields()));
    details.setBoolean("fromCache"_s, isFromCache(response));
}

// A redirect an extension makes before the request is sent, as Chrome reports it: 307 Internal Redirect,
// which keeps the method and body.
static ResourceResponse internalRedirectResponse(const URL& from, const URL& to)
{
    ResourceResponse response;
    response.setURL(URL { from });
    response.setHTTPStatusCode(307);
    response.setHTTPStatusText("Internal Redirect"_s);
    response.setHTTPVersion("HTTP/1.1"_s);
    response.setHTTPHeaderField(HTTPHeaderName::Location, to.string());
    response.setHTTPHeaderField(String { "Non-Authoritative-Reason"_s }, "WebRequest API"_s);
    return response;
}

// A response an onHeadersReceived verdict redirects, as Chrome rewrites it: 302 Found, to the new location.
static ResourceResponse redirectedResponse(const ResourceResponse& response, const URL& to)
{
    ResourceResponse redirectResponse = response;
    redirectResponse.setHTTPStatusCode(302);
    redirectResponse.setHTTPStatusText("Found"_s);
    redirectResponse.setHTTPVersion("HTTP/1.1"_s);
    redirectResponse.setHTTPHeaderField(HTTPHeaderName::Location, to.string());
    return redirectResponse;
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
        retargeted.removeHTTPHeaderField(HTTPHeaderName::Cookie);
    if (auto authorization = redirectedRequest.httpHeaderField(HTTPHeaderName::Authorization); !authorization.isNull()
        && linkedOnOrAfterSDKWithBehavior(SDKAlignedBehavior::AuthorizationHeaderOnSameOriginRedirects)
        && protocolHostAndPortAreEqual(redirectedRequest.url(), target))
        retargeted.setHTTPHeaderField(HTTPHeaderName::Authorization, authorization);
    return retargeted;
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

// Response headers with each held Set-Cookie field as an entry of its own, as the response carried them.
static void setSetCookieFields(JSON::Object& details, const Vector<String>& fields)
{
    auto headers = JSON::Array::create();
    if (RefPtr current = details.getArray("responseHeaders"_s)) {
        for (auto& value : *current) {
            RefPtr header = value->asObject();
            if (header && !equalLettersIgnoringASCIICase(header->getString("name"_s), "set-cookie"_s))
                headers->pushObject(header.releaseNonNull());
        }
    }
    for (auto& field : fields) {
        auto entry = JSON::Object::create();
        entry->setString("name"_s, "Set-Cookie"_s);
        entry->setString("value"_s, field);
        headers->pushObject(WTF::move(entry));
    }
    details.setArray("responseHeaders"_s, WTF::move(headers));
}

static Vector<String> setCookieFields(JSON::Array& headers)
{
    Vector<String> fields;
    for (auto& value : headers) {
        RefPtr header = value->asObject();
        if (header && equalLettersIgnoringASCIICase(header->getString("name"_s), "set-cookie"_s))
            fields.append(header->getString("value"_s));
    }
    return fields;
}

// Request headers with the fields the network layer adds as a listener sees them: none for an empty value.
static Ref<JSON::Array> requestHeadersWithFields(const ResourceRequest& request, const Vector<LegacyExtensionNetwork::GeneratedField>& fields)
{
    auto listenerRequest = request;
    for (auto& field : fields) {
        if (field.shown.isEmpty())
            listenerRequest.removeHTTPHeaderField(field.name);
        else
            listenerRequest.setHTTPHeaderField(field.name, field.shown);
    }
    return headersArray(listenerRequest.httpHeaderFields());
}

// The name and filename parameters of a multipart part's Content-Disposition header.
static std::pair<String, String> formDataDispositionNames(StringView disposition)
{
    String name;
    String filename;
    size_t index = disposition.find(';');
    while (index != notFound) {
        size_t start = index + 1;
        size_t equals = disposition.find('=', start);
        if (equals == notFound)
            break;
        auto key = disposition.substring(start, equals - start).trim(isASCIIWhitespace<char16_t>);
        size_t valueStart = equals + 1;
        while (valueStart < disposition.length() && isASCIIWhitespace(disposition[valueStart]))
            valueStart++;
        String value;
        if (valueStart < disposition.length() && disposition[valueStart] == '"') {
            size_t end = disposition.find('"', valueStart + 1);
            if (end == notFound)
                break;
            value = disposition.substring(valueStart + 1, end - valueStart - 1).toString();
            index = disposition.find(';', end + 1);
        } else {
            index = disposition.find(';', valueStart);
            value = disposition.substring(valueStart, (index == notFound ? disposition.length() : index) - valueStart).trim(isASCIIWhitespace<char16_t>).toString();
        }
        if (equalLettersIgnoringASCIICase(key, "name"_s))
            name = WTF::move(value);
        else if (equalLettersIgnoringASCIICase(key, "filename"_s))
            filename = WTF::move(value);
    }
    return { WTF::move(name), WTF::move(filename) };
}

static void appendFormValue(JSON::Object& formData, const String& name, const String& value)
{
    RefPtr values = formData.getArray(name);
    if (!values) {
        values = JSON::Array::create();
        formData.setArray(name, Ref { *values });
    }
    values->pushString(value);
}

// A multipart/form-data body's fields; a file part's value is its filename. The body's bytes stand in for
// its file elements with nothing, which only a file part's content occupies.
static RefPtr<JSON::Object> parseMultipartFormData(std::span<const uint8_t> body, const String& boundary)
{
    if (boundary.isEmpty())
        return nullptr;
    String text { body };
    auto delimiter = makeString("--"_s, boundary);
    size_t position = text.find(delimiter);
    if (position == notFound)
        return nullptr;
    auto formData = JSON::Object::create();
    while (true) {
        position += delimiter.length();
        if (text.substring(position, 2) == "--"_s)
            return formData;
        if (text.substring(position, 2) != "\r\n"_s)
            return nullptr;
        size_t headersEnd = text.find("\r\n\r\n"_s, position + 2);
        if (headersEnd == notFound)
            return nullptr;
        size_t next = text.find(makeString("\r\n"_s, delimiter), headersEnd + 4);
        if (next == notFound)
            return nullptr;
        String name;
        String filename;
        bool hasDisposition = false;
        for (auto line : StringView(text).substring(position + 2, headersEnd - position - 2).split('\n')) {
            line = line.trim(isASCIIWhitespace<char16_t>);
            size_t colon = line.find(':');
            if (colon == notFound || !equalLettersIgnoringASCIICase(line.left(colon).trim(isASCIIWhitespace<char16_t>), "content-disposition"_s))
                continue;
            hasDisposition = true;
            std::tie(name, filename) = formDataDispositionNames(line.substring(colon + 1));
        }
        if (!hasDisposition || name.isNull())
            return nullptr;
        auto content = body.subspan(headersEnd + 4, next - headersEnd - 4);
        appendFormValue(formData, String::fromUTF8(name.latin1().span()), filename.isNull() ? String::fromUTF8ReplacingInvalidSequences(content) : String::fromUTF8(filename.latin1().span()));
        position = next + 2;
    }
}

// webRequest's requestBody: a URL-encoded or multipart form POST's fields, otherwise the body's raw
// elements, bytes in base64 for the API script to turn into ArrayBuffers.
static RefPtr<JSON::Object> requestBody(const ResourceRequest& request)
{
    RefPtr body = request.httpBody();
    if (!body || body->elements().isEmpty())
        return nullptr;

    auto requestBody = JSON::Object::create();
    if (equalLettersIgnoringASCIICase(request.httpMethod(), "post"_s)) {
        Vector<uint8_t> bytes;
        for (auto& element : body->elements()) {
            if (auto* data = std::get_if<Vector<uint8_t>>(&element.data))
                bytes.appendVector(*data);
        }
        auto contentType = ParsedContentType::create(request.httpContentType());
        RefPtr<JSON::Object> formData;
        if (contentType && contentType->mimeType() == "application/x-www-form-urlencoded"_s) {
            formData = JSON::Object::create();
            for (auto& [name, value] : WTF::URLParser::parseURLEncodedForm(String::fromUTF8ReplacingInvalidSequences(bytes.span())))
                appendFormValue(*formData, name, value);
        } else if (contentType && contentType->mimeType() == "multipart/form-data"_s)
            formData = parseMultipartFormData(bytes.span(), contentType->parameterValueForName("boundary"_s));
        if (formData) {
            requestBody->setObject("formData"_s, formData.releaseNonNull());
            return requestBody;
        }
    }

    auto raw = JSON::Array::create();
    for (auto& element : body->elements()) {
        auto entry = JSON::Object::create();
        WTF::switchOn(element.data,
            [&](const Vector<uint8_t>& data) {
                entry->setString("bytes"_s, base64EncodeToString(data.span()));
            },
            [&](const FormDataElement::EncodedFileData& file) {
                entry->setString("file"_s, file.filename);
            },
            [&](const FormDataElement::EncodedBlobData&) {
            });
        if (entry->size())
            raw->pushObject(WTF::move(entry));
    }
    requestBody->setArray("raw"_s, WTF::move(raw));
    return requestBody;
}

LegacyExtensionNetwork& LegacyExtensionNetwork::singleton()
{
    static NeverDestroyed<LegacyExtensionNetwork> network;
    return network;
}

void LegacyExtensionNetwork::initialize(NetworkProcess& networkProcess)
{
    LegacyExtensions::registerExtensionScheme();
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

void LegacyExtensionNetwork::setListeners(Vector<String>&& observedEvents, Vector<String>&& listenerOptions, String&& blockingListeners)
{
    m_listenerOptions.clear();
    for (auto& option : listenerOptions)
        m_listenerOptions.add(WTF::move(option));
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
            RefPtr access = listener->getObject("access"_s);
            eventListeners.append({ listener->getString("extension"_s), access ? LegacyExtensions::WebsiteAccess::fromJSON(*access) : LegacyExtensions::WebsiteAccess { }, stringsFromJSON(*listener, "urls"_s), stringsFromJSON(*listener, "types"_s), listener->getDouble("tabId"_s) });
        }
        if (!eventListeners.isEmpty())
            m_blockingListeners.add(eventName, WTF::move(eventListeners));
    }
}

// Whether a blocking listener's filter matches the event's details, as the API script decides for each
// listener; an extension's listeners see its own safari-extension:// resources and no other extension's,
// and web requests only within its website access.
bool LegacyExtensionNetwork::blocks(ASCIILiteral eventName, const JSON::Object& details) const
{
    auto iterator = m_blockingListeners.find(String { eventName });
    if (iterator == m_blockingListeners.end())
        return false;
    URL url { details.getString("url"_s) };
    auto type = details.getString("type"_s);
    auto tabID = details.getDouble("tabId"_s);
    for (auto& listener : iterator->value) {
        if (url.protocolIs("safari-extension"_s) ? url.host() != listener.extensionKey : !listener.access.allows(url))
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
    addResponseFields(details, response);
    details->setBoolean("fromCache"_s, fromCache);
    return details;
}

// A request an extension cancels fails as one WebKit's content rules block, as Chrome fails it with
// net::ERR_BLOCKED_BY_CLIENT.
static ResourceError cancellationError(const ResourceRequest& request)
{
    return blockedByContentBlockerError(request);
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
    return NetworkDataTaskCurlCocoa::cookieHeader(*session, request, frameID, pageID, checker.m_webPageProxyID ? std::optional { *checker.m_webPageProxyID } : std::nullopt, checker.storedCredentialsPolicy());
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
    if (RefPtr loader = checker.m_networkResourceLoader.get())
        m_loaders.add(*loader);
    auto redirectResponse = m_redirectResponses.take(checker);
    // An extension's Cookie edit is its exchange's alone: a redirect generates its own.
    if (auto editedCookie = m_editedCookies.take(checker); !editedCookie.isNull() && request.httpHeaderField(HTTPHeaderName::Cookie) == editedCookie)
        request.removeHTTPHeaderField(HTTPHeaderName::Cookie);
    if (m_observedEvents.isEmpty() || !isInterceptable(request.url()))
        return false;

    if (checker.isRedirected() && observes(onBeforeRedirect)) {
        auto details = requestDetails(checker, request);
        details->setString("url"_s, checker.m_previousURL.string());
        details->setString("redirectUrl"_s, request.url().string());
        if (redirectResponse)
            addResponseFields(details, *redirectResponse);
        notify(onBeforeRedirect, details->toJSONString());
    }

    return interceptBeforeRequest(checker, request, client, handler);
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
            request.setURL(WTF::move(redirectURL));
            if (checker->isRedirected())
                m_extensionRedirectTargets.set(*checker, request.url());
            if (isInterceptable(request.url()) && interceptBeforeRequest(*checker, request, client, handler))
                return;
            m_resumingRequests.add(*checker);
            checker->checkRequest(WTF::move(request), client, WTF::move(handler));
            return;
        }

        if (interceptRequestHeaders(*checker, request, client, handler))
            return;
        m_resumingRequests.add(*checker);
        checker->checkRequest(WTF::move(request), client, WTF::move(handler));
    });
    return true;
}

// onBeforeSendHeaders and onSendHeaders, with the headers the request is sent with. "extraHeaders" listeners
// see the fields the network layer adds to a request that carries none -- the Cookie field it generates,
// and its Accept-Language and Accept-Encoding -- and a verdict that changes or removes one sends the
// verdict's field instead, an empty field standing for a removed one.
bool LegacyExtensionNetwork::interceptRequestHeaders(NetworkLoadChecker& checker, ResourceRequest& request, ContentSecurityPolicyClient* client, NetworkLoadChecker::ValidationHandler& handler)
{
    Vector<GeneratedField> generatedFields;
    if (hasOption(onBeforeSendHeaders, extraHeadersOption) || hasOption(onSendHeaders, extraHeadersOption)) {
        generatedFields.append({ HTTPHeaderName::Cookie, request.httpHeaderField(HTTPHeaderName::Cookie), cookieHeader(checker, request) });
        for (auto [name, defaultValue] : { std::pair { HTTPHeaderName::AcceptLanguage, cocoaCurlDefaultAcceptLanguage() }, std::pair { HTTPHeaderName::AcceptEncoding, cocoaCurlDefaultAcceptEncoding() } }) {
            auto carried = request.httpHeaderField(name);
            generatedFields.append({ name, carried, carried.isNull() ? defaultValue : carried });
        }
    }
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
            request.setHTTPHeaderFields(headerMap(*headers));
            for (auto& field : generatedFields) {
                auto sent = request.httpHeaderField(field.name);
                if (sent.isEmpty() == field.shown.isEmpty() && (sent.isEmpty() || sent == field.shown)) {
                    if (field.carried.isNull())
                        request.removeHTTPHeaderField(field.name);
                    else
                        request.setHTTPHeaderField(field.name, field.carried);
                    continue;
                }
                field.shown = sent.isNull() ? emptyString() : sent;
                request.setHTTPHeaderField(field.name, field.shown);
                field.carried = field.shown;
                if (field.name == HTTPHeaderName::Cookie)
                    m_editedCookies.set(*checker, field.shown);
            }
        }

        if (observes(onSendHeaders)) {
            auto details = requestDetails(*checker, request);
            details->setArray("requestHeaders"_s, requestHeadersWithFields(request, generatedFields));
            notify(onSendHeaders, details->toJSONString());
        }
        m_resumingRequests.add(*checker);
        checker->checkRequest(WTF::move(request), hasClient ? loader.get() : nullptr, WTF::move(handler));
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
    if (m_observedEvents.isEmpty() || !isInterceptable(redirectResponse.url()))
        return false;
    m_redirectResponses.set(checker, makeUnique<ResourceResponse>(redirectResponse));
    // A redirect an extension made has no response headers of its own to report.
    if (isExtensionRedirect)
        return false;

    auto details = requestDetails(checker, request.isNull() ? redirectRequest : request);
    details->setString("url"_s, redirectResponse.url().string());
    addResponseFields(details, redirectResponse);
    RefPtr redirectLoader = checker.m_networkResourceLoader.get();
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
                auto data = redirectResponse.crossThreadData();
                data.httpHeaderFields = headerMap(*headers);
                redirectResponse = ResourceResponse::fromCrossThreadData(WTF::move(data));
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
    if (m_observedEvents.isEmpty() || !isInterceptable(response.url()))
        return false;
    // A successful revalidation reaches the extensions as the cached response.
    if (loader.m_cacheEntryForValidation && response.httpStatusCode() == httpStatus304NotModified)
        return false;

    auto details = responseDetails(loader, response, false);
    if (RefPtr task = curlTask(loader); task && task->heldCookies())
        setSetCookieFields(details, *task->heldCookies());
    // A redirect a load does not follow has had its onHeadersReceived as a redirect.
    if (response.type() == ResourceResponse::Type::Opaqueredirect) {
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
            RunLoop::mainSingleton().dispatch([this, weakLoader = WTF::move(weakLoader)] {
                RefPtr loader = weakLoader.get();
                if (loader && loader->m_networkLoad)
                    loader->didFailLoading(cancellationError(loader->originalRequest()));
            });
            return completionHandler(PolicyAction::Ignore);
        }
        if (RefPtr headers = verdict ? verdict->getArray("responseHeaders"_s) : nullptr) {
            auto data = response.crossThreadData();
            data.httpHeaderFields = headerMap(*headers);
            response = ResourceResponse::fromCrossThreadData(WTF::move(data));
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
            loader->didFailLoading(cancellationError(loader->originalRequest()));
            return;
        }
        if (RefPtr headers = verdict ? verdict->getArray("responseHeaders"_s) : nullptr) {
            auto data = entry->response().crossThreadData();
            data.httpHeaderFields = headerMap(*headers);
            RefPtr<FragmentedSharedBuffer> buffer = entry->buffer();
            entry = protect(loader->m_cache)->makeEntry(loader->originalRequest(), ResourceResponse::fromCrossThreadData(WTF::move(data)), entry->privateRelayed(), WTF::move(buffer));
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

// The WebExtensions name of an HTTP authentication scheme; null for a challenge that is not HTTP
// authentication.
static String authenticationSchemeName(const AuthenticationChallenge& challenge)
{
    using Scheme = ProtectionSpace::AuthenticationScheme;
    switch (challenge.protectionSpace().authenticationScheme()) {
    case Scheme::HTTPBasic:
        return "basic"_s;
    case Scheme::HTTPDigest:
        return "digest"_s;
    case Scheme::NTLM:
        return "ntlm"_s;
    case Scheme::Negotiate:
        return "negotiate"_s;
    case Scheme::Default: {
        auto& response = challenge.failureResponse();
        auto field = response.httpHeaderField(challenge.protectionSpace().isProxy() ? "Proxy-Authenticate"_s : "WWW-Authenticate"_s);
        auto token = StringView(field).trim(isASCIIWhitespace<char16_t>);
        if (size_t end = token.find(isASCIIWhitespace<char16_t>); end != notFound)
            token = token.left(end);
        return token.isEmpty() ? String() : token.convertToASCIILowercase();
    }
    default:
        return { };
    }
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
    RefPtr<NetworkResourceLoader> loader;
    for (auto& candidate : m_loaders) {
        if (candidate.m_networkLoad == &networkLoad) {
            loader = &candidate;
            break;
        }
    }
    if (!loader)
        return false;

    auto& protectionSpace = challenge.protectionSpace();
    auto details = loaderDetails(*loader);
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
        connection.connection().send(Messages::WebSocketChannel::DidClose { 1006, emptyString() }, decoder.destinationID());
    }
    return true;
}

// onCompleted and onErrorOccurred.
void LegacyExtensionNetwork::loaderDidFinish(NetworkResourceLoader& loader, NetworkResourceLoader::LoadResult result)
{
    bool succeeded = result == NetworkResourceLoader::LoadResult::Success;
    auto error = m_loadErrors.take(loader);
    auto eventName = succeeded ? onCompleted : onErrorOccurred;
    if (!observes(eventName))
        return;
    auto& request = loader.m_networkLoad ? loader.m_networkLoad->currentRequest() : loader.originalRequest();
    if (!isInterceptable(request.url()))
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

} // namespace WebKit
