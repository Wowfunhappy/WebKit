#include "config.h"
#include "LegacyExtensionWebRequest.h"

#include "WebErrors.h"
#include <WebCore/AuthenticationChallenge.h>
#include <WebCore/CocoaCurlTransfer.h>
#include <WebCore/FormData.h>
#include <WebCore/HTTPHeaderMap.h>
#include <WebCore/ParsedContentType.h>
#include <WebCore/ResourceError.h>
#include <WebCore/ResourceRequest.h>
#include <WebCore/ResourceResponse.h>
#include <wtf/URLParser.h>
#include <wtf/WallTime.h>
#include <wtf/text/Base64.h>

namespace WebKit::LegacyExtensions {

using namespace WebCore;

ASCIILiteral resourceType(const ResourceRequest& request, FetchOptions::Destination destination, bool isMainFrameLoad)
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

bool isInterceptable(const URL& url)
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

void WebRequestListeners::set(Vector<String>&& observedEvents, Vector<String>&& listenerOptions, const String& blockingListeners)
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
            eventListeners.append({ listener->getString("extension"_s), access ? std::optional { WebsiteAccess::fromJSON(*access) } : std::nullopt, stringsFromJSON(*listener, "urls"_s), stringsFromJSON(*listener, "types"_s), listener->getDouble("tabId"_s) });
        }
        if (!eventListeners.isEmpty())
            m_blockingListeners.add(eventName, WTF::move(eventListeners));
    }
}

bool WebRequestListeners::blocks(ASCIILiteral eventName, const JSON::Object& details) const
{
    auto iterator = m_blockingListeners.find(String { eventName });
    if (iterator == m_blockingListeners.end())
        return false;
    URL url { details.getString("url"_s) };
    auto type = details.getString("type"_s);
    auto tabID = details.getDouble("tabId"_s);
    for (auto& listener : iterator->value) {
        if (url.protocolIs("safari-extension"_s) ? url.host() != listener.extensionKey : listener.access && !listener.access->allows(url))
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

double timeStamp()
{
    return WallTime::now().secondsSinceEpoch().milliseconds();
}

Ref<JSON::Array> headersArray(const HTTPHeaderMap& headers)
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

HTTPHeaderMap headerMap(JSON::Array& array)
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

bool isFromCache(const ResourceResponse& response)
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

void addResponseFields(JSON::Object& details, const ResourceResponse& response)
{
    details.setDouble("statusCode"_s, response.httpStatusCode());
    details.setString("statusLine"_s, makeString(response.httpVersion().isEmpty() ? "HTTP/1.1"_s : response.httpVersion(), ' ', response.httpStatusCode(), ' ', response.httpStatusText()));
    details.setArray("responseHeaders"_s, headersArray(response.httpHeaderFields()));
    details.setBoolean("fromCache"_s, isFromCache(response));
}

ResourceResponse responseWithHeaders(const ResourceResponse& response, JSON::Array& headers)
{
    auto data = response.crossThreadData();
    data.httpHeaderFields = headerMap(headers);
    return ResourceResponse::fromCrossThreadData(WTF::move(data));
}

ResourceResponse internalRedirectResponse(const URL& from, const URL& to)
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

ResourceResponse redirectedResponse(const ResourceResponse& response, const URL& to)
{
    ResourceResponse redirectResponse = response;
    redirectResponse.setHTTPStatusCode(302);
    redirectResponse.setHTTPStatusText("Found"_s);
    redirectResponse.setHTTPVersion("HTTP/1.1"_s);
    redirectResponse.setHTTPHeaderField(HTTPHeaderName::Location, to.string());
    return redirectResponse;
}

void setSetCookieFields(JSON::Object& details, const Vector<String>& fields)
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

Vector<String> setCookieFields(JSON::Array& headers)
{
    Vector<String> fields;
    for (auto& value : headers) {
        RefPtr header = value->asObject();
        if (header && equalLettersIgnoringASCIICase(header->getString("name"_s), "set-cookie"_s))
            fields.append(header->getString("value"_s));
    }
    return fields;
}

Vector<GeneratedField> generatedFields(const ResourceRequest& request, const String& cookie)
{
    Vector<GeneratedField> fields;
    fields.append({ HTTPHeaderName::Cookie, request.httpHeaderField(HTTPHeaderName::Cookie), cookie });
    for (auto [name, defaultValue] : { std::pair { HTTPHeaderName::AcceptLanguage, cocoaCurlDefaultAcceptLanguage() }, std::pair { HTTPHeaderName::AcceptEncoding, cocoaCurlDefaultAcceptEncoding() } }) {
        auto carried = request.httpHeaderField(name);
        fields.append({ name, carried, carried.isNull() ? defaultValue : carried });
    }
    return fields;
}

Ref<JSON::Array> requestHeadersWithFields(const ResourceRequest& request, const Vector<GeneratedField>& fields)
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

String applyRequestHeaders(ResourceRequest& request, JSON::Array& headers, Vector<GeneratedField>& fields)
{
    String editedCookie;
    request.setHTTPHeaderFields(headerMap(headers));
    for (auto& field : fields) {
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
            editedCookie = field.shown;
    }
    return editedCookie;
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

RefPtr<JSON::Object> requestBody(const ResourceRequest& request)
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

String authenticationSchemeName(const AuthenticationChallenge& challenge)
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

ResourceError cancellationError(const ResourceRequest& request)
{
    return blockedByContentBlockerError(request);
}

} // namespace WebKit::LegacyExtensions
