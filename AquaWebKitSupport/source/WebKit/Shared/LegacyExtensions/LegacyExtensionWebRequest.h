// What both ends of Safari 7 extensions' webRequest share: the network process's, for WebKit 2 loads, and
// the Safari process's, for the loads of its WebKit 1 extension views. Each end learns from the router which
// events extensions listen to and each blocking listener's filter, builds an event's details, and applies the
// router's merged verdict.

#pragma once

#include "LegacyExtensionWebsiteAccess.h"
#include <WebCore/FetchOptions.h>
#include <WebCore/HTTPHeaderNames.h>
#include <wtf/HashMap.h>
#include <wtf/HashSet.h>
#include <wtf/JSONValues.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringHash.h>

namespace WebCore {
class AuthenticationChallenge;
class HTTPHeaderMap;
class ResourceError;
class ResourceRequest;
class ResourceResponse;
enum class IsMainResourceLoad : bool;
}

namespace WebKit::LegacyExtensions {

inline constexpr auto onBeforeRequest = "onBeforeRequest"_s;
inline constexpr auto onBeforeSendHeaders = "onBeforeSendHeaders"_s;
inline constexpr auto onSendHeaders = "onSendHeaders"_s;
inline constexpr auto onBeforeRedirect = "onBeforeRedirect"_s;
inline constexpr auto onHeadersReceived = "onHeadersReceived"_s;
inline constexpr auto onResponseStarted = "onResponseStarted"_s;
inline constexpr auto onCompleted = "onCompleted"_s;
inline constexpr auto onErrorOccurred = "onErrorOccurred"_s;
inline constexpr auto onAuthRequired = "onAuthRequired"_s;
inline constexpr auto requestBodyOption = "requestBody"_s;
inline constexpr auto extraHeadersOption = "extraHeaders"_s;

// The events extensions listen to, the extraInfoSpec options their listeners ask for, and the filters of the
// blocking listeners, as the router sends them.
class WebRequestListeners {
public:
    void set(Vector<String>&& observedEvents, Vector<String>&& listenerOptions, const String& blockingListeners);

    bool isEmpty() const { return m_observedEvents.isEmpty(); }
    bool observes(ASCIILiteral eventName) const { return m_observedEvents.contains(String { eventName }); }
    bool hasOption(ASCIILiteral eventName, ASCIILiteral option) const { return m_listenerOptions.contains(makeString(eventName, ':', option)); }
    // Whether a blocking listener's filter matches the event's details, as the API script decides for each
    // listener; an extension's listeners see its own safari-extension:// resources and no other extension's,
    // and web requests only within its website access. A listener whose extension's website access is still
    // being read matches a web request its filter does, and the router decides once the access is read.
    bool blocks(ASCIILiteral eventName, const JSON::Object& details) const;

private:
    struct BlockingListener {
        String extensionKey;
        // Null while the extension's website access is being read.
        std::optional<WebsiteAccess> access;
        std::optional<Vector<String>> urlPatterns;
        std::optional<Vector<String>> types;
        std::optional<double> tabID;
    };

    HashSet<String> m_observedEvents;
    // As "<event>:<option>".
    HashSet<String> m_listenerOptions;
    HashMap<String, Vector<BlockingListener>> m_blockingListeners;
};

// A field the network layer adds to a request without one, as the request carries it and as an
// "extraHeaders" listener sees it.
struct GeneratedField {
    WebCore::HTTPHeaderName name;
    String carried;
    String shown;
};

// The WebExtensions resource type of a request.
ASCIILiteral resourceType(const WebCore::ResourceRequest&, WebCore::FetchOptions::Destination, bool isMainFrameLoad);
bool isInterceptable(const URL&);
double timeStamp();

Ref<JSON::Array> headersArray(const WebCore::HTTPHeaderMap&);
WebCore::HTTPHeaderMap headerMap(JSON::Array&);
bool isFromCache(const WebCore::ResourceResponse&);
void addResponseFields(JSON::Object&, const WebCore::ResourceResponse&);
// The response with its header fields replaced; a changed Content-Type also sets its MIME type and charset.
WebCore::ResourceResponse responseWithHeaders(const WebCore::ResourceResponse&, JSON::Array&, WebCore::IsMainResourceLoad);

// A redirect an extension makes before the request is sent, as Chrome reports it: 307 Internal Redirect,
// which keeps the method and body.
WebCore::ResourceResponse internalRedirectResponse(const URL& from, const URL& to);
// A response an onHeadersReceived verdict redirects, as Chrome rewrites it: 302 Found, to the new location.
WebCore::ResourceResponse redirectedResponse(const WebCore::ResourceResponse&, const URL& to);

// Response headers with each held Set-Cookie field as an entry of its own, as the response carried them.
void setSetCookieFields(JSON::Object& details, const Vector<String>& fields);
Vector<String> setCookieFields(JSON::Array& headers);

// The fields the network layer adds to a request that carries none: the Cookie field it generates
// (`cookie`), and its Accept-Language and Accept-Encoding.
Vector<GeneratedField> generatedFields(const WebCore::ResourceRequest&, const String& cookie);
// Request headers with the fields the network layer adds as a listener sees them: none for an empty value.
Ref<JSON::Array> requestHeadersWithFields(const WebCore::ResourceRequest&, const Vector<GeneratedField>&);
// Replaces the request's header fields with an onBeforeSendHeaders verdict's. A generated field the verdict
// changes or removes is sent as the verdict has it, an empty field standing for a removed one; the result is
// the Cookie field the verdict set, or null when it left the generated one.
String applyRequestHeaders(WebCore::ResourceRequest&, JSON::Array& headers, Vector<GeneratedField>&);

// webRequest's requestBody: a URL-encoded or multipart form POST's fields, otherwise the body's raw
// elements, bytes in base64 for the API script to turn into ArrayBuffers.
RefPtr<JSON::Object> requestBody(const WebCore::ResourceRequest&);

// The WebExtensions name of an HTTP authentication scheme; null for a challenge that is not HTTP
// authentication.
String authenticationSchemeName(const WebCore::AuthenticationChallenge&);

// A request an extension cancels fails as one WebKit's content rules block, as Chrome fails it with
// net::ERR_BLOCKED_BY_CLIENT.
WebCore::ResourceError cancellationError(const WebCore::ResourceRequest&);

} // namespace WebKit::LegacyExtensions
