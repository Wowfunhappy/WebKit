#include "config.h"
#include "LegacyExtensionHost.h"

#include "LegacyExtensionClipboard.h"
#include "LegacyExtensionContentMessages.h"
#include "LegacyExtensionErrors.h"
#include "LegacyExtensionHostMessages.h"
#include "LegacyExtensionInfoPlist.h"
#include "LegacyExtensionJavaScript.h"
#include "LegacyExtensionScheme.h"
#include "LegacyExtensionNetworkMessages.h"
#include "LegacyExtensionNetworkProxyMessages.h"
#include "APIHTTPCookieStore.h"
#include "APINavigation.h"
#include "FrameTreeNodeData.h"
#include "NetworkProcessProxy.h"
#include "PageLoadState.h"
#include "WebBackForwardList.h"
#include "WebBackForwardListItem.h"
#include "WebFrameProxy.h"
#include "WebLegacyExtensionPageObserver.h"
#include "WebPageProxy.h"
#include "WebProcessPool.h"
#include "WebProcessProxy.h"
#include "WebsiteDataStore.h"
#include <JavaScriptCore/APICast.h>
#include <JavaScriptCore/JSCast.h>
#include <JavaScriptCore/JSGlobalObject.h>
#include <JavaScriptCore/JSLock.h>
#include <JavaScriptCore/WeakInlines.h>
#include <WebCore/Cookie.h>
#include <WebCore/Document.h>
#include <WebCore/JSDOMWindow.h>
#include <WebCore/LocalDOMWindow.h>
#include <WebCore/MemoryCache.h>
#include <WebCore/PlatformPasteboard.h>
#include <WebCore/ResourceRequest.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/RunLoop.h>
#include <wtf/WallTime.h>
#include <wtf/text/MakeString.h>
#include <cmath>

namespace WebKit {

static constexpr auto extensionScheme = "safari-extension"_s;
static constexpr auto noReceiverError = "Could not establish connection. Receiving end does not exist."_s;

// A page's tabs.onUpdated source.
class LegacyExtensionTabObserver final : public PageLoadStateObserverBase, public RefCounted<LegacyExtensionTabObserver> {
public:
    static Ref<LegacyExtensionTabObserver> create(WebPageProxy& page, Function<void(WebPageProxy&, Ref<JSON::Object>&&)>&& didUpdate)
    {
        return adoptRef(*new LegacyExtensionTabObserver(page, WTF::move(didUpdate)));
    }

    void ref() const final { RefCounted::ref(); }
    void deref() const final { RefCounted::deref(); }

private:
    LegacyExtensionTabObserver(WebPageProxy& page, Function<void(WebPageProxy&, Ref<JSON::Object>&&)>&& didUpdate)
        : m_page(page)
        , m_didUpdate(WTF::move(didUpdate))
    {
    }

    void report(Ref<JSON::Object>&& changeInfo)
    {
        if (RefPtr page = m_page.get())
            m_didUpdate(*page, WTF::move(changeInfo));
    }

    void willChangeIsLoading() final { }
    void didChangeIsLoading() final
    {
        RefPtr page = m_page.get();
        if (!page)
            return;
        auto changeInfo = JSON::Object::create();
        changeInfo->setString("status"_s, page->pageLoadState().isLoading() ? "loading"_s : "complete"_s);
        report(WTF::move(changeInfo));
    }
    void willChangeTitle() final { }
    void didChangeTitle() final
    {
        RefPtr page = m_page.get();
        if (!page)
            return;
        auto changeInfo = JSON::Object::create();
        changeInfo->setString("title"_s, page->pageLoadState().title());
        report(WTF::move(changeInfo));
    }
    void willChangeActiveURL() final { }
    void didChangeActiveURL() final
    {
        RefPtr page = m_page.get();
        if (!page)
            return;
        auto changeInfo = JSON::Object::create();
        changeInfo->setString("url"_s, page->pageLoadState().activeURL().string());
        report(WTF::move(changeInfo));
    }
    void willChangeHasOnlySecureContent() final { }
    void didChangeHasOnlySecureContent() final { }
    void willChangeEstimatedProgress() final { }
    void didChangeEstimatedProgress() final { }
    void willChangeCanGoBack() final { }
    void didChangeCanGoBack() final { }
    void willChangeCanGoForward() final { }
    void didChangeCanGoForward() final { }
    void willChangeNetworkRequestsInProgress() final { }
    void didChangeNetworkRequestsInProgress() final { }
    void willChangeCertificateInfo() final { }
    void didChangeCertificateInfo() final { }
    void willChangeWebProcessIsResponsive() final { }
    void didChangeWebProcessIsResponsive() final { }
    void didSwapWebProcesses() final { }

    WeakPtr<WebPageProxy> m_page;
    Function<void(WebPageProxy&, Ref<JSON::Object>&&)> m_didUpdate;
};

static HashMap<WebPageProxyIdentifier, Ref<LegacyExtensionTabObserver>>& tabObservers()
{
    static NeverDestroyed<HashMap<WebPageProxyIdentifier, Ref<LegacyExtensionTabObserver>>> observers;
    return observers;
}

// The native object LegacyExtensionAPI.js receives in a host context.
struct HostContextNative {
    uint64_t hostContextIdentifier;
};

static JSValueRef hostContextSend(JSContextRef context, JSObjectRef, JSObjectRef thisObject, size_t argumentCount, const JSValueRef arguments[], JSValueRef*)
{
    auto* native = static_cast<HostContextNative*>(JSObjectGetPrivate(thisObject));
    auto message = LegacyExtensions::stringArgument(context, argumentCount, arguments, 0);
    if (native && !message.isNull())
        LegacyExtensionHost::singleton().postFromHostContext(native->hostContextIdentifier, message);
    return JSValueMakeUndefined(context);
}

static void hostContextFinalize(JSObjectRef object)
{
    delete static_cast<HostContextNative*>(JSObjectGetPrivate(object));
}

static JSClassRef hostContextNativeClass()
{
    static JSClassRef nativeClass = [] {
        static const JSStaticFunction functions[] = {
            { "send", hostContextSend, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontDelete },
            { nullptr, nullptr, 0 },
        };
        JSClassDefinition definition = kJSClassDefinitionEmpty;
        definition.className = "LegacyExtensionNative";
        definition.staticFunctions = functions;
        definition.finalize = hostContextFinalize;
        return JSClassCreate(&definition);
    }();
    return nativeClass;
}

// An identifier an extension passes as a JSON number, when that number is a positive integer that
// converts to uint64_t exactly.
static std::optional<uint64_t> integerIdentifier(double value)
{
    constexpr double maximumSafeInteger = 9007199254740991.0;
    if (!(value > 0 && value <= maximumSafeInteger) || std::trunc(value) != value)
        return std::nullopt;
    return static_cast<uint64_t>(value);
}

static std::optional<WebCore::FrameIdentifier> frameIdentifier(double value)
{
    auto rawValue = integerIdentifier(value);
    if (!rawValue || !WebCore::FrameIdentifier::isValidIdentifier(*rawValue))
        return std::nullopt;
    return WebCore::FrameIdentifier { *rawValue };
}

static RefPtr<WebPageProxy> pageForTabID(std::optional<double> tabID)
{
    auto rawValue = tabID ? integerIdentifier(*tabID) : std::nullopt;
    if (!rawValue || !WebPageProxyIdentifier::isValidIdentifier(*rawValue))
        return nullptr;
    RefPtr page = WebProcessProxy::webPage(WebPageProxyIdentifier { *rawValue });
    if (!page || page->isClosed())
        return nullptr;
    return page;
}

static double tabIDForPage(const WebPageProxy& page)
{
    return static_cast<double>(page.identifier().toUInt64());
}

// The WebExtensions frame ID: 0 for a tab's main frame.
static double frameIDForFrame(const WebFrameProxy& frame)
{
    return frame.isMainFrame() ? 0 : static_cast<double>(frame.frameID().toUInt64());
}

static double parentFrameIDForFrame(const WebFrameProxy& frame)
{
    RefPtr parent = frame.parentFrame();
    return parent ? frameIDForFrame(*parent) : -1;
}

static RefPtr<WebFrameProxy> frameForTab(WebPageProxy& page, double frameId)
{
    if (!frameId)
        return page.mainFrame();
    auto identifier = frameIdentifier(frameId);
    if (!identifier)
        return nullptr;
    RefPtr frame = WebFrameProxy::webFrame(*identifier);
    if (!frame || frame->page() != &page)
        return nullptr;
    return frame;
}

static void forEachFrame(WebFrameProxy& frame, NOESCAPE const Function<void(WebFrameProxy&)>& function)
{
    function(frame);
    for (Ref child : frame.childFrames())
        forEachFrame(child, function);
}

static String extensionKeyForURL(const URL& url)
{
    if (!url.protocolIs(extensionScheme))
        return { };
    return url.host().toString();
}

static double timeStamp()
{
    return WallTime::now().secondsSinceEpoch().milliseconds();
}

static const WebLegacyExtensionPageObserver& pageObserver()
{
    static const WebLegacyExtensionPageObserver observer {
        [](const void* frame, JSGlobalContextRef context, CFURLRef documentURL) {
            LegacyExtensionHost::singleton().didClearWindowObject(frame, *toJS(context), URL { documentURL });
        },
        [](const void* frame) {
            LegacyExtensionHost::singleton().frameWillBeDestroyed(frame);
        },
    };
    return observer;
}

// cookies. Chrome's store IDs: "0" is the store Safari's tabs use, "1" the private browsing store.
static constexpr auto persistentCookieStoreID = "0"_s;
static constexpr auto privateCookieStoreID = "1"_s;

static RefPtr<WebsiteDataStore> dataStoreForCookieStoreID(const String& storeID)
{
    bool isPrivate = storeID == privateCookieStoreID;
    if (!isPrivate && storeID != persistentCookieStoreID)
        return nullptr;
    for (auto identifier : tabObservers().keys()) {
        RefPtr page = WebProcessProxy::webPage(identifier);
        if (page && !page->isClosed() && page->sessionID().isEphemeral() == isPrivate)
            return &page->websiteDataStore();
    }
    if (isPrivate)
        return nullptr;
    if (RefPtr dataStore = WebsiteDataStore::existingDataStoreForSessionID(PAL::SessionID::defaultSessionID()))
        return dataStore;
    return &WebsiteDataStore::defaultDataStore();
}

static ASCIILiteral sameSiteName(WebCore::Cookie::SameSitePolicy policy)
{
    switch (policy) {
    case WebCore::Cookie::SameSitePolicy::Lax:
        return "lax"_s;
    case WebCore::Cookie::SameSitePolicy::Strict:
        return "strict"_s;
    case WebCore::Cookie::SameSitePolicy::None:
        break;
    }
    return "no_restriction"_s;
}

// A cookie as Chrome's cookies API describes it, with its creation time for ordering.
static Ref<JSON::Object> cookieDescription(const WebCore::Cookie& cookie, const String& storeID)
{
    auto description = JSON::Object::create();
    description->setString("name"_s, cookie.name);
    description->setString("value"_s, cookie.value);
    description->setString("domain"_s, cookie.domain);
    description->setBoolean("hostOnly"_s, !cookie.domain.startsWith('.'));
    description->setString("path"_s, cookie.path);
    description->setBoolean("secure"_s, cookie.secure);
    description->setBoolean("httpOnly"_s, cookie.httpOnly);
    description->setString("sameSite"_s, sameSiteName(cookie.sameSite));
    description->setBoolean("session"_s, cookie.session || !cookie.expires);
    if (!cookie.session && cookie.expires)
        description->setDouble("expirationDate"_s, *cookie.expires / 1000);
    description->setString("storeId"_s, storeID);
    description->setDouble("created"_s, cookie.created);
    return description;
}

static WebCore::Cookie cookieFromDescription(const JSON::Object& description)
{
    WebCore::Cookie cookie;
    cookie.name = description.getString("name"_s);
    cookie.value = description.getString("value"_s);
    cookie.domain = description.getString("domain"_s);
    cookie.path = description.getString("path"_s);
    cookie.secure = description.getBoolean("secure"_s).value_or(false);
    cookie.httpOnly = description.getBoolean("httpOnly"_s).value_or(false);
    auto sameSite = description.getString("sameSite"_s);
    cookie.sameSite = sameSite == "lax"_s ? WebCore::Cookie::SameSitePolicy::Lax : sameSite == "strict"_s ? WebCore::Cookie::SameSitePolicy::Strict : WebCore::Cookie::SameSitePolicy::None;
    cookie.created = description.getDouble("created"_s).value_or(WallTime::now().secondsSinceEpoch().milliseconds());
    if (auto expirationDate = description.getDouble("expirationDate"_s)) {
        cookie.expires = *expirationDate * 1000;
        cookie.session = false;
    } else
        cookie.session = true;
    return cookie;
}

static String cookieKey(const WebCore::Cookie& cookie)
{
    return makeString(cookie.name, '\n', cookie.domain, '\n', cookie.path);
}

// The site a cookie belongs to, as website access covers it: its domain, over https for a secure cookie.
static URL cookieURL(const WebCore::Cookie& cookie)
{
    auto domain = cookie.domain.startsWith('.') ? cookie.domain.substring(1) : cookie.domain;
    return URL { makeString(cookie.secure ? "https://"_s : "http://"_s, domain, cookie.path) };
}

static bool cookiesDiffer(const WebCore::Cookie& a, const WebCore::Cookie& b)
{
    return a.value != b.value || a.expires != b.expires || a.session != b.session || a.httpOnly != b.httpOnly || a.secure != b.secure || a.sameSite != b.sameSite;
}

// The cookie stores whose changes reach cookies.onChanged listeners, each with the cookies it held when
// last read.
class LegacyExtensionCookieObserver final : public API::HTTPCookieStoreObserver {
public:
    static Ref<LegacyExtensionCookieObserver> create(WebsiteDataStore& dataStore, const String& storeID)
    {
        return adoptRef(*new LegacyExtensionCookieObserver(dataStore, storeID));
    }

    ~LegacyExtensionCookieObserver()
    {
        if (RefPtr dataStore = m_dataStore.get())
            dataStore->cookieStore().unregisterObserver(*this);
    }

    WebsiteDataStore* dataStore() const { return m_dataStore.get(); }

private:
    LegacyExtensionCookieObserver(WebsiteDataStore& dataStore, const String& storeID)
        : m_dataStore(dataStore)
        , m_storeID(storeID)
    {
        dataStore.cookieStore().registerObserver(*this);
        read();
    }

    void cookiesDidChange(API::HTTPCookieStore&) final
    {
        if (std::exchange(m_isReading, true)) {
            m_changedWhileReading = true;
            return;
        }
        read();
    }

    // Each change as Chrome reports it: a removal, an addition, or an overwrite reported as the old
    // cookie's removal and the new one's addition.
    void read()
    {
        RefPtr dataStore = m_dataStore.get();
        if (!dataStore)
            return;
        m_isReading = true;
        dataStore->cookieStore().cookies([weakThis = WeakPtr { *this }](Vector<WebCore::Cookie>&& cookies) {
            RefPtr protectedThis = weakThis.get();
            if (!protectedThis)
                return;
            HashMap<String, size_t> index;
            for (size_t i = 0; i < cookies.size(); ++i)
                index.set(cookieKey(cookies[i]), i);
            if (protectedThis->m_hasRead)
                protectedThis->reportChanges(cookies, index);
            protectedThis->m_cookies = WTF::move(cookies);
            protectedThis->m_cookieIndex = WTF::move(index);
            protectedThis->m_hasRead = true;
            protectedThis->m_isReading = false;
            if (std::exchange(protectedThis->m_changedWhileReading, false))
                protectedThis->cookiesDidChange(protectedThis->m_dataStore->cookieStore());
        });
    }

    void reportChanges(const Vector<WebCore::Cookie>& current, const HashMap<String, size_t>& currentIndex)
    {
        auto now = WallTime::now().secondsSinceEpoch().milliseconds();
        auto report = [&](const WebCore::Cookie& cookie, bool removed, ASCIILiteral cause) {
            auto changeInfo = JSON::Object::create();
            changeInfo->setBoolean("removed"_s, removed);
            changeInfo->setObject("cookie"_s, cookieDescription(cookie, m_storeID));
            changeInfo->setString("cause"_s, cause);
            auto arguments = JSON::Array::create();
            arguments->pushObject(WTF::move(changeInfo));
            LegacyExtensionHost::singleton().dispatchCookieChange(cookie, WTF::move(arguments));
        };
        for (auto& cookie : m_cookies) {
            auto iterator = currentIndex.find(cookieKey(cookie));
            if (iterator == currentIndex.end())
                report(cookie, true, cookie.expires && *cookie.expires <= now ? "expired"_s : "explicit"_s);
            else if (cookiesDiffer(cookie, current[iterator->value]))
                report(cookie, true, "overwrite"_s);
        }
        for (auto& cookie : current) {
            auto iterator = m_cookieIndex.find(cookieKey(cookie));
            if (iterator == m_cookieIndex.end() || cookiesDiffer(m_cookies[iterator->value], cookie))
                report(cookie, false, "explicit"_s);
        }
    }

    WeakPtr<WebsiteDataStore> m_dataStore;
    String m_storeID;
    Vector<WebCore::Cookie> m_cookies;
    HashMap<String, size_t> m_cookieIndex;
    bool m_hasRead { false };
    bool m_isReading { false };
    bool m_changedWhileReading { false };
};

LegacyExtensionHost& LegacyExtensionHost::singleton()
{
    static NeverDestroyed<LegacyExtensionHost> host;
    return host;
}

LegacyExtensionHost::~LegacyExtensionHost() = default;

LegacyExtensionHost::LegacyExtensionHost()
{
    LegacyExtensions::registerExtensionScheme();
    WebSetLegacyExtensionPageObserver(&pageObserver());
}

void LegacyExtensionHost::webProcessCreated(WebProcessProxy& process)
{
    process.addMessageReceiver(Messages::LegacyExtensionHost::messageReceiverName(), *this);
}

void LegacyExtensionHost::networkProcessCreated(NetworkProcessProxy& networkProcess)
{
    networkProcess.addMessageReceiver(Messages::LegacyExtensionNetworkProxy::messageReceiverName(), m_networkProxy);
    sendNetworkListeners(networkProcess);
}

// Host contexts.

void LegacyExtensionHost::didClearWindowObject(const void* frame, JSC::JSGlobalObject& globalObject, const URL& documentURL)
{
    if (auto identifier = m_hostContextByFrame.take(frame)) {
        if (auto context = m_hostContexts.take(identifier))
            hostContextDidGoAway(*context);
    }

    auto extensionKey = extensionKeyForURL(documentURL);
    if (extensionKey.isEmpty())
        return;

    Ref context = HostContext::create();
    context->identifier = m_nextIdentifier++;
    context->frame = frame;
    context->extensionKey = extensionKey;
    context->url = documentURL;
    context->globalObject = JSC::Weak<JSC::JSGlobalObject>(&globalObject);

    if (!LegacyExtensions::installAPI(globalObject, LegacyExtensions::ContextKind::Host, hostContextNativeClass(), new HostContextNative { context->identifier }))
        return;

    m_hostContextByFrame.add(frame, context->identifier);
    loadWebsiteAccess(context->extensionKey, context->url);
    m_hostContexts.add(context->identifier, WTF::move(context));
}

void LegacyExtensionHost::frameWillBeDestroyed(const void* frame)
{
    auto identifier = m_hostContextByFrame.take(frame);
    if (!identifier)
        return;
    if (auto context = m_hostContexts.take(identifier))
        hostContextDidGoAway(*context);
}

void LegacyExtensionHost::postFromHostContext(uint64_t hostContextIdentifier, const String& message)
{
    RefPtr context = m_hostContexts.get(hostContextIdentifier);
    if (!context)
        return;
    route(Endpoint { context, std::nullopt }, context->extensionKey, message);
}

// A WebKit 1 context's document is in this process; a web content process reports its documents'.
String LegacyExtensionHost::pasteboardOriginIdentifier(const HostContext& context) const
{
    if (context.frameID)
        return context.pasteboardOriginIdentifier;
    auto* window = dynamicDowncast<WebCore::JSDOMWindow>(context.globalObject.get());
    RefPtr localWindow = window ? dynamicDowncast<WebCore::LocalDOMWindow>(window->wrapped()) : nullptr;
    RefPtr document = localWindow ? localWindow->document() : nullptr;
    return document ? document->originIdentifierForPasteboard() : String { };
}

void LegacyExtensionHost::hostContextDidGoAway(HostContext& context)
{
    bool hadNetworkInterests = false;
    for (auto& name : context.interests.keys()) {
        if (name.startsWith("webRequest."_s))
            hadNetworkInterests = true;
    }
    context.interests.clear();
    endpointDidGoAway(Endpoint { &context, std::nullopt });

    Vector<uint64_t> webRequestTokens;
    for (auto& [token, call] : m_webRequestCalls) {
        if (call.pendingHostContexts.removeAll(context.identifier))
            webRequestTokens.append(token);
    }
    for (auto token : webRequestTokens)
        finishWebRequestCallIfComplete(token);

    m_routerCalls.removeIf([&](auto& entry) {
        return entry.value.caller.get() == &context;
    });

    if (hadNetworkInterests)
        updateNetworkListeners();
    if (!m_cookieObservers.isEmpty())
        updateCookieObservers();
}

// Content contexts.

void LegacyExtensionHost::post(IPC::Connection& connection, WebCore::FrameIdentifier frameID, WebCore::ScriptExecutionContextIdentifier documentID, URL&& documentURL, String&& pasteboardOriginIdentifier, String&& extensionKey, String&& message)
{
    RefPtr frame = WebFrameProxy::webFrame(frameID);
    if (!frame || !frame->page())
        return;
    if (!protect(frame->process())->hasConnection(connection))
        return;
    m_documents.set(documentID, std::pair { frameID, documentURL });
    if (RefPtr context = extensionPageContext(*frame, documentID, documentURL, extensionKey)) {
        context->pasteboardOriginIdentifier = WTF::move(pasteboardOriginIdentifier);
        route(Endpoint { context, std::nullopt, std::nullopt }, extensionKey, message);
        return;
    }
    route(Endpoint { nullptr, frameID, documentID }, extensionKey, message);
}

// A frame showing one of the extension's own pages speaks for that page, not for a content script. A
// context belongs to one document of the frame: the frame's next document is another page.
RefPtr<LegacyExtensionHost::HostContext> LegacyExtensionHost::extensionPageContext(WebFrameProxy& frame, Markable<WebCore::ScriptExecutionContextIdentifier> documentID, const URL& documentURL, const String& extensionKey)
{
    if (extensionKeyForURL(documentURL) != extensionKey)
        return nullptr;
    if (auto identifier = m_hostContextByRemoteFrame.get(frame.frameID())) {
        if (RefPtr context = m_hostContexts.get(identifier)) {
            if (context->documentID == documentID) {
                context->url = documentURL;
                return context;
            }
            m_hostContextByRemoteFrame.remove(frame.frameID());
            m_hostContexts.remove(identifier);
            hostContextDidGoAway(*context);
        }
    }
    Ref context = HostContext::create();
    context->identifier = m_nextIdentifier++;
    context->extensionKey = extensionKey;
    context->url = documentURL;
    context->frameID = frame.frameID();
    context->documentID = documentID;
    m_hostContextByRemoteFrame.set(frame.frameID(), context->identifier);
    loadWebsiteAccess(context->extensionKey, context->url);
    m_hostContexts.add(context->identifier, context.copyRef());
    return context;
}

// A document's URL as its contexts last reported it, else as the UI process knows the frame's.
URL LegacyExtensionHost::documentURL(WebFrameProxy& frame, Markable<WebCore::ScriptExecutionContextIdentifier> documentID) const
{
    if (documentID) {
        auto iterator = m_documents.find(*documentID);
        if (iterator != m_documents.end())
            return iterator->value.second;
    }
    return frame.url();
}

void LegacyExtensionHost::documentsDidGoAway(NOESCAPE const Function<bool(WebCore::FrameIdentifier, WebCore::ScriptExecutionContextIdentifier)>& isGone)
{
    m_documents.removeIf([&](auto& entry) {
        return isGone(entry.value.first, entry.key);
    });
}

void LegacyExtensionHost::didDestroyFrame(WebCore::FrameIdentifier frameID)
{
    framesDidGoAway({ frameID });
}

void LegacyExtensionHost::framesDidGoAway(const Vector<WebCore::FrameIdentifier>& frameIDs)
{
    endpointsDidGoAway([&](auto& endpoint) {
        return !endpoint.host && endpoint.frameID && frameIDs.contains(*endpoint.frameID);
    });
    documentsDidGoAway([&](auto frameID, auto) {
        return frameIDs.contains(frameID);
    });
    for (auto frameID : frameIDs) {
        if (auto identifier = m_hostContextByRemoteFrame.take(frameID)) {
            if (auto context = m_hostContexts.take(identifier))
                hostContextDidGoAway(*context);
        }
    }
}

void LegacyExtensionHost::endpointDidGoAway(const Endpoint& endpoint)
{
    endpointsDidGoAway([&](auto& candidate) {
        return candidate == endpoint;
    });
}

void LegacyExtensionHost::endpointsDidGoAway(NOESCAPE const Function<bool(const Endpoint&)>& isGone)
{
    Vector<std::pair<String, Endpoint>> portEnds;
    for (auto& [portID, port] : m_ports) {
        if (isGone(port.opener))
            portEnds.append({ portID, port.opener });
        for (auto& receiver : port.receivers) {
            if (isGone(receiver))
                portEnds.append({ portID, receiver });
        }
    }
    for (auto& [portID, endpoint] : portEnds)
        routeDisconnect(endpoint, portID);

    Vector<std::pair<String, Endpoint>> messageEnds;
    for (auto& [messageID, message] : m_oneShotMessages) {
        if (isGone(message.sender))
            messageEnds.append({ messageID, message.sender });
        for (auto& receiver : message.pendingReceivers) {
            if (isGone(receiver))
                messageEnds.append({ messageID, receiver });
        }
    }
    for (auto& [messageID, endpoint] : messageEnds) {
        auto iterator = m_oneShotMessages.find(messageID);
        if (iterator == m_oneShotMessages.end())
            continue;
        auto& message = iterator->value;
        if (message.sender == endpoint) {
            m_oneShotMessages.remove(iterator);
            continue;
        }
        auto reply = JSON::Object::create();
        reply->setString("msgId"_s, messageID);
        reply->setBoolean("none"_s, true);
        routeReply(endpoint, reply.get());
    }

    Vector<uint64_t> callIDs;
    for (auto& [callID, call] : m_routerCalls) {
        if (call.pendingEndpoints.removeAllMatching([&](auto& endpoint) { return isGone(endpoint); }))
            callIDs.append(callID);
    }
    for (auto callID : callIDs)
        finishRouterCallIfComplete(callID);
}

// Routing.

void LegacyExtensionHost::route(const Endpoint& from, const String& extensionKey, const String& message)
{
    auto value = JSON::Value::parseJSON(message);
    RefPtr object = value ? value->asObject() : nullptr;
    if (!object)
        return;
    auto type = object->getString("t"_s);

    if (type == "connect"_s)
        return routeConnect(from, extensionKey, *object);
    if (type == "post"_s)
        return routePost(from, message, object->getString("portId"_s));
    if (type == "disconnect"_s)
        return routeDisconnect(from, object->getString("portId"_s));
    if (type == "message"_s)
        return routeOneShotMessage(from, extensionKey, *object);
    if (type == "reply"_s)
        return routeReply(from, *object);
    if (type == "result"_s)
        return routeCallResult(from, *object);

    if (!from.host)
        return;
    if (type == "respond"_s)
        return routeWebRequestResponse(*from.host, *object);
    if (type == "interest"_s)
        return routeInterest(*from.host, *object);
    if (type == "call"_s)
        return performCall(*from.host, *object);
}

Vector<LegacyExtensionHost::Endpoint> LegacyExtensionHost::hostContextsListeningTo(const String& extensionKey, const String& eventName, const Endpoint& except) const
{
    Vector<Endpoint> endpoints;
    for (auto& context : m_hostContexts.values()) {
        if (context->extensionKey != extensionKey || except.host == context.ptr())
            continue;
        if (context->interests.contains(eventName))
            endpoints.append(Endpoint { context.copyRef(), std::nullopt });
    }
    return endpoints;
}

// The frames a tab shows: the frame tree of its documents as the web content process has it, which leaves
// out frames kept in the back/forward cache.
static void forEachFrameInTree(const FrameTreeNodeData& node, double parentFrameId, NOESCAPE const Function<void(const FrameInfoData&, double parentFrameId)>& function)
{
    function(node.info, parentFrameId);
    double frameId = node.info.isMainFrame ? 0 : static_cast<double>(node.info.frameID.toUInt64());
    for (auto& child : node.children)
        forEachFrameInTree(child, frameId, function);
}

// The contexts an extension has in a tab's frames: its pages where a frame shows one, its content scripts
// elsewhere.
void LegacyExtensionHost::tabEndpoints(WebPageProxy& page, std::optional<double> frameId, const String& extensionKey, CompletionHandler<void(Vector<Endpoint>&&)>&& completionHandler)
{
    auto endpointFor = [this, extensionKey](WebFrameProxy& frame, Markable<WebCore::ScriptExecutionContextIdentifier> documentID) {
        if (RefPtr context = extensionPageContext(frame, documentID, documentURL(frame, documentID), extensionKey))
            return Endpoint { WTF::move(context), std::nullopt, std::nullopt };
        return Endpoint { nullptr, frame.frameID(), documentID };
    };
    RefPtr targetFrame = frameId ? frameForTab(page, *frameId) : nullptr;
    if (frameId && !targetFrame)
        return completionHandler({ });
    page.getAllFrames([endpointFor = WTF::move(endpointFor), targetFrameID = targetFrame ? std::optional { targetFrame->frameID() } : std::nullopt, completionHandler = WTF::move(completionHandler)](std::optional<FrameTreeNodeData>&& tree) mutable {
        Vector<Endpoint> endpoints;
        if (tree) {
            forEachFrameInTree(*tree, -1, [&](auto& info, double) {
                if (targetFrameID && info.frameID != *targetFrameID)
                    return;
                if (RefPtr frame = WebFrameProxy::webFrame(info.frameID))
                    endpoints.append(endpointFor(*frame, info.documentID));
            });
        }
        completionHandler(WTF::move(endpoints));
    });
}

bool LegacyExtensionHost::deliver(const Endpoint& endpoint, const String& extensionKey, const String& message)
{
    Markable<WebCore::FrameIdentifier> frameID = endpoint.frameID;
    Markable<WebCore::ScriptExecutionContextIdentifier> documentID = endpoint.documentID;
    if (RefPtr context = endpoint.host) {
        if (!m_hostContexts.contains(context->identifier))
            return false;
        if (!context->frameID) {
            auto* globalObject = context->globalObject.get();
            if (!globalObject)
                return false;
            return LegacyExtensions::deliver(*globalObject, message);
        }
        frameID = context->frameID;
        documentID = context->documentID;
    }
    RefPtr frame = WebFrameProxy::webFrame(frameID);
    if (!frame || !frame->page())
        return false;
    protect(frame->process())->send(Messages::LegacyExtensionContent::Deliver(*frameID, documentID ? std::optional { *documentID } : std::nullopt, extensionKey, message), 0);
    return true;
}

Ref<JSON::Object> LegacyExtensionHost::senderDescription(const Endpoint& endpoint) const
{
    auto sender = JSON::Object::create();
    Markable<WebCore::FrameIdentifier> frameID = endpoint.frameID;
    if (RefPtr context = endpoint.host) {
        if (!context->frameID) {
            sender->setString("url"_s, context->url.string());
            return sender;
        }
        frameID = context->frameID;
    }
    RefPtr frame = WebFrameProxy::webFrame(frameID);
    if (!frame)
        return sender;
    if (RefPtr page = frame->page())
        sender->setObject("tab"_s, tabDescription(*page));
    sender->setDouble("frameId"_s, frameIDForFrame(*frame));
    sender->setString("url"_s, documentURL(*frame, endpoint.documentID).string());
    return sender;
}

void LegacyExtensionHost::routeConnect(const Endpoint& from, const String& extensionKey, JSON::Object& message)
{
    auto portID = message.getString("portId"_s);
    if (portID.isEmpty() || m_ports.contains(portID))
        return;

    auto connect = JSON::Object::create();
    connect->setString("t"_s, "connect"_s);
    connect->setString("portId"_s, portID);
    connect->setString("name"_s, message.getString("name"_s));
    connect->setObject("sender"_s, senderDescription(from));

    // Until its receivers are known, a port keeps what its opener posts.
    m_ports.add(portID, Port { extensionKey, from, { }, true, { } });
    auto didFindReceivers = [this, portID, connectMessage = connect->toJSONString()](Vector<Endpoint>&& receivers) {
        auto iterator = m_ports.find(portID);
        if (iterator == m_ports.end())
            return;
        auto& port = iterator->value;
        auto opener = port.opener;
        auto extensionKey = port.extensionKey;
        if (receivers.isEmpty()) {
            m_ports.remove(iterator);
            auto disconnect = JSON::Object::create();
            disconnect->setString("t"_s, "disconnect"_s);
            disconnect->setString("portId"_s, portID);
            disconnect->setString("error"_s, noReceiverError);
            deliver(opener, extensionKey, disconnect->toJSONString());
            return;
        }
        port.receivers = receivers;
        port.isResolving = false;
        auto queuedMessages = std::exchange(port.queuedMessages, { });
        for (auto& receiver : receivers)
            deliver(receiver, extensionKey, connectMessage);
        for (auto& queuedMessage : queuedMessages) {
            for (auto& receiver : receivers)
                deliver(receiver, extensionKey, queuedMessage);
        }
    };

    if (from.host && message.getDouble("tabId"_s)) {
        RefPtr page = pageForTabID(message.getDouble("tabId"_s));
        if (!page)
            return didFindReceivers({ });
        return tabEndpoints(*page, message.getDouble("frameId"_s), extensionKey, WTF::move(didFindReceivers));
    }
    didFindReceivers(hostContextsListeningTo(extensionKey, "runtime.onConnect"_s, from));
}

void LegacyExtensionHost::routePost(const Endpoint& from, const String& message, const String& portID)
{
    auto iterator = m_ports.find(portID);
    if (iterator == m_ports.end())
        return;
    if (iterator->value.isResolving) {
        if (iterator->value.opener == from)
            iterator->value.queuedMessages.append(message);
        return;
    }
    auto port = iterator->value;
    if (port.opener == from) {
        for (auto& receiver : port.receivers)
            deliver(receiver, port.extensionKey, message);
        return;
    }
    if (port.receivers.contains(from))
        deliver(port.opener, port.extensionKey, message);
}

void LegacyExtensionHost::routeDisconnect(const Endpoint& from, const String& portID)
{
    auto iterator = m_ports.find(portID);
    if (iterator == m_ports.end())
        return;

    auto disconnect = JSON::Object::create();
    disconnect->setString("t"_s, "disconnect"_s);
    disconnect->setString("portId"_s, portID);
    auto disconnectMessage = disconnect->toJSONString();

    auto& port = iterator->value;
    if (port.opener == from) {
        auto receivers = std::exchange(port.receivers, { });
        auto extensionKey = port.extensionKey;
        m_ports.remove(iterator);
        for (auto& receiver : receivers)
            deliver(receiver, extensionKey, disconnectMessage);
        return;
    }
    if (!port.receivers.removeAll(from) || !port.receivers.isEmpty())
        return;
    auto opener = port.opener;
    auto extensionKey = port.extensionKey;
    m_ports.remove(iterator);
    deliver(opener, extensionKey, disconnectMessage);
}

void LegacyExtensionHost::routeOneShotMessage(const Endpoint& from, const String& extensionKey, JSON::Object& message)
{
    auto messageID = message.getString("msgId"_s);
    if (messageID.isEmpty() || m_oneShotMessages.contains(messageID))
        return;

    auto forwarded = JSON::Object::create();
    forwarded->setString("t"_s, "message"_s);
    forwarded->setString("msgId"_s, messageID);
    if (auto body = message.getValue("msg"_s))
        forwarded->setValue("msg"_s, body.releaseNonNull());
    forwarded->setObject("sender"_s, senderDescription(from));

    auto didFindReceivers = [this, from, extensionKey, messageID, forwardedMessage = forwarded->toJSONString()](Vector<Endpoint>&& receivers) {
        if (receivers.isEmpty()) {
            auto reply = JSON::Object::create();
            reply->setString("t"_s, "reply"_s);
            reply->setString("msgId"_s, messageID);
            reply->setString("error"_s, noReceiverError);
            deliver(from, extensionKey, reply->toJSONString());
            return;
        }
        if (!m_oneShotMessages.add(messageID, OneShotMessage { extensionKey, from, receivers, false }).isNewEntry)
            return;
        for (auto& receiver : receivers)
            deliver(receiver, extensionKey, forwardedMessage);
    };

    if (from.host && message.getDouble("tabId"_s)) {
        RefPtr page = pageForTabID(message.getDouble("tabId"_s));
        if (!page)
            return didFindReceivers({ });
        return tabEndpoints(*page, message.getDouble("frameId"_s), extensionKey, WTF::move(didFindReceivers));
    }
    didFindReceivers(hostContextsListeningTo(extensionKey, "runtime.onMessage"_s, from));
}

void LegacyExtensionHost::routeReply(const Endpoint& from, JSON::Object& reply)
{
    auto messageID = reply.getString("msgId"_s);
    auto iterator = m_oneShotMessages.find(messageID);
    if (iterator == m_oneShotMessages.end())
        return;
    auto& message = iterator->value;
    if (!message.pendingReceivers.removeAll(from))
        return;

    auto answer = JSON::Object::create();
    answer->setString("t"_s, "reply"_s);
    answer->setString("msgId"_s, messageID);
    bool declined = reply.getBoolean("none"_s).value_or(false);
    bool answers = !declined && !message.answered;
    if (answers) {
        message.answered = true;
        if (auto response = reply.getValue("response"_s))
            answer->setValue("response"_s, response.releaseNonNull());
        if (auto error = reply.getString("error"_s); !error.isNull())
            answer->setString("error"_s, error);
    }
    bool finished = message.pendingReceivers.isEmpty();
    if (finished && !message.answered) {
        answers = true;
        answer->setBoolean("none"_s, true);
    }
    auto sender = message.sender;
    auto extensionKey = message.extensionKey;
    if (finished)
        m_oneShotMessages.remove(iterator);

    // Delivery can run the sender's JavaScript, and through it this router, before it returns.
    if (answers)
        deliver(sender, extensionKey, answer->toJSONString());
}

// Router calls: the methods host contexts cannot answer themselves.

void LegacyExtensionHost::resultToHostContext(HostContext& context, double callID, RefPtr<JSON::Value>&& result, const String& error)
{
    auto message = JSON::Object::create();
    message->setString("t"_s, "result"_s);
    message->setDouble("callId"_s, callID);
    if (!error.isNull())
        message->setString("error"_s, error);
    else if (result)
        message->setValue("result"_s, result.releaseNonNull());
    deliver(Endpoint { &context, std::nullopt }, context.extensionKey, message->toJSONString());
}

Ref<JSON::Object> LegacyExtensionHost::tabDescription(WebPageProxy& page) const
{
    auto tab = JSON::Object::create();
    tab->setDouble("id"_s, tabIDForPage(page));
    tab->setString("url"_s, page.pageLoadState().activeURL().string());
    tab->setString("title"_s, page.pageLoadState().title());
    tab->setString("status"_s, page.pageLoadState().isLoading() ? "loading"_s : "complete"_s);
    tab->setBoolean("incognito"_s, page.sessionID().isEphemeral());
    return tab;
}

void LegacyExtensionHost::performCall(HostContext& context, JSON::Object& call)
{
    auto callID = call.getDouble("callId"_s).value_or(0);
    auto method = call.getString("method"_s);
    RefPtr arguments = call.getArray("args"_s);
    auto argument = [&](size_t index) -> RefPtr<JSON::Value> {
        if (!arguments || index >= arguments->length())
            return nullptr;
        return arguments->get(index).ptr();
    };
    auto numberArgument = [&](size_t index) -> std::optional<double> {
        RefPtr value = argument(index);
        return value ? value->asDouble() : std::nullopt;
    };
    auto objectArgument = [&](size_t index) -> RefPtr<JSON::Object> {
        RefPtr value = argument(index);
        return value ? value->asObject() : nullptr;
    };

    // Chrome's contract: memory-cache hits never reach webRequest, so a changed listener empties the
    // memory caches, the UI process's for its WebKit 1 pages and every web process's.
    if (method == "webRequest.handlerBehaviorChanged"_s) {
        WebCore::MemoryCache::singleton().evictResources();
        for (Ref pool : WebProcessPool::allProcessPools())
            pool->sendToAllProcesses(Messages::LegacyExtensionContent::EvictMemoryCache());
        resultToHostContext(context, callID, nullptr);
        return;
    }

    // navigator.clipboard's text methods, for an extension's pages.
    if (method == "clipboard.writeText"_s) {
        RefPtr text = argument(0);
        auto string = text ? text->asString() : String();
        if (string.isNull()) {
            resultToHostContext(context, callID, nullptr, "Invalid text."_s);
            return;
        }
        RefPtr frame = context.frameID ? WebFrameProxy::webFrame(*context.frameID) : nullptr;
        RefPtr page = frame ? frame->page() : nullptr;
        auto lifetime = page && page->sessionID().isEphemeral() ? WebCore::PasteboardDataLifetime::Ephemeral : WebCore::PasteboardDataLifetime::Persistent;
        LegacyExtensions::writeClipboardText(string, pasteboardOriginIdentifier(context), lifetime);
        resultToHostContext(context, callID, nullptr);
        return;
    }

    if (method == "clipboard.readText"_s) {
        auto text = LegacyExtensions::readClipboardText();
        if (!text) {
            resultToHostContext(context, callID, nullptr, "The clipboard changed while it was read."_s);
            return;
        }
        resultToHostContext(context, callID, JSON::Value::create(text->isNull() ? emptyString() : *text));
        return;
    }

    // cookies, within the extension's website access: getAll(storeId, url?) answers the store's cookies it
    // covers; set and remove(storeId, cookie, url) act on a cookie it covers, for a URL it covers.
    if (method.startsWith("cookies."_s) && method != "cookies.getAllCookieStores"_s) {
        RefPtr storeIDValue = argument(0);
        auto storeID = storeIDValue ? storeIDValue->asString() : String();
        RefPtr urlValue = argument(method == "cookies.getAll"_s ? 1 : 2);
        URL url { urlValue ? urlValue->asString() : String() };
        RefPtr description = objectArgument(1);
        withWebsiteAccess(context.extensionKey, [this, context = Ref { context }, callID, method, storeID, url = WTF::move(url), description = WTF::move(description)](const LegacyExtensions::WebsiteAccess& access) {
            if (!m_hostContexts.contains(context->identifier))
                return;
            RefPtr dataStore = dataStoreForCookieStoreID(storeID);
            if (!dataStore)
                return resultToHostContext(context, callID, nullptr, makeString("Invalid cookie store id: \""_s, storeID, "\"."_s));
            if (url.isValid() && !access.allows(url))
                return resultToHostContext(context, callID, nullptr, makeString("No website access for cookies at url: \""_s, url.string(), "\"."_s));
            if (method == "cookies.getAll"_s) {
                dataStore->cookieStore().cookies([this, context, callID, storeID, access](Vector<WebCore::Cookie>&& cookies) {
                    if (!m_hostContexts.contains(context->identifier))
                        return;
                    auto descriptions = JSON::Array::create();
                    for (auto& cookie : cookies) {
                        if (access.allows(cookieURL(cookie)))
                            descriptions->pushObject(cookieDescription(cookie, storeID));
                    }
                    resultToHostContext(context, callID, descriptions.ptr());
                });
                return;
            }
            if (!description || !url.isValid() || (method != "cookies.set"_s && method != "cookies.remove"_s))
                return resultToHostContext(context, callID, nullptr, makeString("Unsupported method "_s, method));
            auto cookie = cookieFromDescription(*description);
            if (!access.allows(cookieURL(cookie)))
                return resultToHostContext(context, callID, nullptr, makeString("No website access for cookies at url: \""_s, cookieURL(cookie).string(), "\"."_s));
            auto finish = [this, context, callID] {
                if (m_hostContexts.contains(context->identifier))
                    resultToHostContext(context, callID, nullptr);
            };
            if (method == "cookies.set"_s)
                dataStore->cookieStore().setCookies({ WTF::move(cookie) }, WTF::move(finish));
            else
                dataStore->cookieStore().deleteCookie(cookie, WTF::move(finish));
        });
        return;
    }

    if (method == "cookies.getAllCookieStores"_s) {
        auto stores = JSON::Array::create();
        for (auto storeID : { persistentCookieStoreID, privateCookieStoreID }) {
            bool isPrivate = storeID == privateCookieStoreID;
            auto tabIDs = JSON::Array::create();
            for (auto identifier : tabObservers().keys()) {
                RefPtr page = WebProcessProxy::webPage(identifier);
                if (page && !page->isClosed() && page->sessionID().isEphemeral() == isPrivate)
                    tabIDs->pushDouble(tabIDForPage(*page));
            }
            if (isPrivate && !tabIDs->length())
                continue;
            auto store = JSON::Object::create();
            store->setString("id"_s, storeID);
            store->setArray("tabIds"_s, WTF::move(tabIDs));
            stores->pushObject(WTF::move(store));
        }
        resultToHostContext(context, callID, stores.ptr());
        return;
    }

    if (method == "tabs.get"_s) {
        RefPtr page = pageForTabID(numberArgument(0));
        resultToHostContext(context, callID, page ? RefPtr<JSON::Value> { tabDescription(*page) } : RefPtr<JSON::Value> { JSON::Value::null() });
        return;
    }

    if (method == "tabs.remove"_s) {
        if (RefPtr tabIDs = argument(0) ? argument(0)->asArray() : nullptr) {
            for (auto& tabID : *tabIDs) {
                if (RefPtr page = pageForTabID(tabID->asDouble()))
                    page->closePage();
            }
        }
        resultToHostContext(context, callID, nullptr);
        return;
    }

    if (method == "tabs.reload"_s) {
        if (RefPtr page = pageForTabID(numberArgument(0))) {
            OptionSet<WebCore::ReloadOption> options;
            RefPtr properties = objectArgument(1);
            if (properties && properties->getBoolean("bypassCache"_s).value_or(false))
                options.add(WebCore::ReloadOption::FromOrigin);
            page->reload(options);
        }
        resultToHostContext(context, callID, nullptr);
        return;
    }

    if (method == "tabs.update"_s) {
        RefPtr page = pageForTabID(numberArgument(0));
        if (!page) {
            resultToHostContext(context, callID, nullptr, "No tab with this id."_s);
            return;
        }
        RefPtr properties = objectArgument(1);
        if (properties) {
            auto url = properties->getString("url"_s);
            if (!url.isEmpty())
                page->loadRequest(WebCore::ResourceRequest { URL { url } });
        }
        resultToHostContext(context, callID, tabDescription(*page).ptr());
        return;
    }

    if (method == "webNavigation.getFrame"_s || method == "webNavigation.getAllFrames"_s) {
        RefPtr details = objectArgument(0);
        RefPtr page = details ? pageForTabID(details->getDouble("tabId"_s)) : nullptr;
        if (!page) {
            resultToHostContext(context, callID, JSON::Value::null());
            return;
        }
        bool allFrames = method == "webNavigation.getAllFrames"_s;
        auto wantedFrameId = details->getDouble("frameId"_s).value_or(0);
        page->getAllFrames([this, context = Ref { context }, callID, allFrames, wantedFrameId](std::optional<FrameTreeNodeData>&& tree) {
            if (!m_hostContexts.contains(context->identifier))
                return;
            auto frames = JSON::Array::create();
            RefPtr<JSON::Object> wantedFrame;
            if (tree) {
                forEachFrameInTree(*tree, -1, [&](auto& info, double parentFrameId) {
                    double frameId = info.isMainFrame ? 0 : static_cast<double>(info.frameID.toUInt64());
                    auto description = JSON::Object::create();
                    description->setBoolean("errorOccurred"_s, info.errorOccurred);
                    description->setString("url"_s, info.request.url().string());
                    description->setDouble("frameId"_s, frameId);
                    description->setDouble("parentFrameId"_s, parentFrameId);
                    if (frameId == wantedFrameId)
                        wantedFrame = description.copyRef();
                    frames->pushObject(WTF::move(description));
                });
            }
            if (allFrames)
                return resultToHostContext(context, callID, frames.ptr());
            resultToHostContext(context, callID, wantedFrame ? RefPtr<JSON::Value> { wantedFrame } : RefPtr<JSON::Value> { JSON::Value::null() });
        });
        return;
    }

    if (method == "tabs.executeScript"_s || method == "tabs.insertCSS"_s || method == "tabs.removeCSS"_s) {
        RefPtr page = pageForTabID(numberArgument(0));
        RefPtr details = objectArgument(1);
        if (!page || !details) {
            resultToHostContext(context, callID, nullptr, "No tab with this id."_s);
            return;
        }
        bool allFrames = details->getBoolean("allFrames"_s).value_or(false);
        auto routerCallID = m_nextIdentifier++;
        auto request = JSON::Object::create();
        request->setDouble("callId"_s, static_cast<double>(routerCallID));
        request->setString("code"_s, details->getString("code"_s));
        request->setString("runAt"_s, details->getString("runAt"_s));
        request->setBoolean("matchAboutBlank"_s, details->getBoolean("matchAboutBlank"_s).value_or(false));
        if (method == "tabs.executeScript"_s)
            request->setString("t"_s, "exec"_s);
        else {
            request->setString("t"_s, "css"_s);
            request->setString("op"_s, method == "tabs.insertCSS"_s ? "insert"_s : "remove"_s);
            request->setString("origin"_s, details->getString("cssOrigin"_s));
            // A file's style sheet is based at the file, which is the extension's own.
            if (URL fileURL { details->getString("url"_s) }; fileURL.protocolIs("safari-extension"_s) && fileURL.host() == context.extensionKey)
                request->setString("url"_s, fileURL.string());
        }
        auto targetFrameId = allFrames ? std::nullopt : std::optional<double> { details->getDouble("frameId"_s).value_or(0) };
        tabEndpoints(*page, targetFrameId, context.extensionKey, [this, context = Ref { context }, callID, method, routerCallID, requestMessage = request->toJSONString()](Vector<Endpoint>&& targets) {
            if (!m_hostContexts.contains(context->identifier))
                return;
            if (targets.isEmpty())
                return resultToHostContext(context, callID, nullptr, "No frame with this id."_s);
            m_routerCalls.add(routerCallID, RouterCall { context.ptr(), callID, method, targets, JSON::Array::create(), { } });
            for (auto& target : targets)
                deliver(target, context->extensionKey, requestMessage);
        });
        return;
    }

    resultToHostContext(context, callID, nullptr, makeString("Unsupported method "_s, method));
}

void LegacyExtensionHost::routeCallResult(const Endpoint& from, JSON::Object& message)
{
    auto callID = integerIdentifier(message.getDouble("callId"_s).value_or(0));
    if (!callID)
        return;
    auto iterator = m_routerCalls.find(*callID);
    if (iterator == m_routerCalls.end())
        return;
    auto& call = iterator->value;
    if (!call.pendingEndpoints.removeFirst(from))
        return;
    auto error = message.getString("error"_s);
    if (!error.isNull()) {
        if (call.error.isNull())
            call.error = error;
    } else if (call.method == "tabs.executeScript"_s) {
        auto result = message.getValue("result"_s);
        call.results->pushValue(result ? result.releaseNonNull() : JSON::Value::null());
    }
    finishRouterCallIfComplete(*callID);
}

void LegacyExtensionHost::finishRouterCallIfComplete(uint64_t callID)
{
    auto iterator = m_routerCalls.find(callID);
    if (iterator == m_routerCalls.end() || !iterator->value.pendingEndpoints.isEmpty())
        return;
    auto call = m_routerCalls.take(iterator);
    if (!call.caller || !m_hostContexts.contains(call.caller->identifier))
        return;
    // A call fails when no frame ran it; frames that could not run it are left out of the results.
    if (!call.error.isNull() && (call.method != "tabs.executeScript"_s || !call.results->length()))
        return resultToHostContext(*call.caller, call.callerCallID, nullptr, call.error);
    if (call.method == "tabs.executeScript"_s)
        return resultToHostContext(*call.caller, call.callerCallID, RefPtr<JSON::Value> { call.results.get() });
    resultToHostContext(*call.caller, call.callerCallID, nullptr);
}

// Events.

void LegacyExtensionHost::routeInterest(HostContext& context, JSON::Object& message)
{
    RefPtr events = message.getObject("events"_s);
    HashMap<String, String> interests;
    if (events) {
        for (auto& [name, value] : *events) {
            RefPtr object = value->asObject();
            interests.add(name, object ? object->toJSONString() : "{}"_s);
        }
    }
    bool networkInterestsChanged = false;
    for (auto& interest : interests) {
        if (interest.key.startsWith("webRequest."_s) && (!context.interests.contains(interest.key) || context.interests.get(interest.key) != interest.value))
            networkInterestsChanged = true;
    }
    for (auto& interest : context.interests) {
        if (interest.key.startsWith("webRequest."_s) && !interests.contains(interest.key))
            networkInterestsChanged = true;
    }
    context.interests = WTF::move(interests);
    if (networkInterestsChanged)
        updateNetworkListeners();
    updateCookieObservers();
}

// cookies.onChanged observes each store a listener's extension can read while some context listens.
void LegacyExtensionHost::updateCookieObservers()
{
    bool hasListener = false;
    for (auto& context : m_hostContexts.values())
        hasListener |= context->interests.contains("cookies.onChanged"_s);
    if (!hasListener) {
        m_cookieObservers.clear();
        return;
    }
    for (auto storeID : { persistentCookieStoreID, privateCookieStoreID }) {
        RefPtr dataStore = dataStoreForCookieStoreID(storeID);
        auto iterator = m_cookieObservers.find(storeID);
        if (iterator != m_cookieObservers.end() && iterator->value->dataStore() == dataStore.get())
            continue;
        if (!dataStore) {
            m_cookieObservers.remove(storeID);
            continue;
        }
        m_cookieObservers.set(storeID, LegacyExtensionCookieObserver::create(*dataStore, storeID));
    }
}

// A cookie's change reaches the listeners of the extensions whose website access covers it.
void LegacyExtensionHost::dispatchCookieChange(const WebCore::Cookie& cookie, Ref<JSON::Array>&& arguments)
{
    auto event = JSON::Object::create();
    event->setString("t"_s, "event"_s);
    event->setString("name"_s, "cookies.onChanged"_s);
    event->setArray("args"_s, WTF::move(arguments));
    auto message = event->toJSONString();
    auto url = cookieURL(cookie);
    for (auto& context : copyToVector(m_hostContexts.values())) {
        if (!context->interests.contains("cookies.onChanged"_s))
            continue;
        auto iterator = m_websiteAccess.find(context->extensionKey);
        if (iterator != m_websiteAccess.end() && iterator->value.allows(url))
            deliver(Endpoint { context.ptr(), std::nullopt }, context->extensionKey, message);
    }
}

// Website access. Each extension's is read from its Info.plist when its first page appears; what waits on it
// runs once it is read, and until then its webRequest listeners see nothing.
static URL extensionRoot(const URL& url)
{
    auto path = url.path();
    size_t tokenEnd = path.find('/', 1);
    if (!url.protocolIs(extensionScheme) || !path.startsWith('/') || tokenEnd == notFound)
        return { };
    URL root = url;
    root.setPath(path.left(tokenEnd + 1));
    root.removeQueryAndFragmentIdentifier();
    return root;
}

// An extension Safari reloads serves its files from a new root, whose Info.plist is read again.
void LegacyExtensionHost::loadWebsiteAccess(const String& extensionKey, const URL& url)
{
    auto root = extensionRoot(url);
    if (!root.isValid() || m_websiteAccessRoots.get(extensionKey) == root)
        return;
    m_websiteAccessRoots.set(extensionKey, root);
    m_websiteAccess.remove(extensionKey);
    m_websiteAccessWaiters.ensure(extensionKey, [] { return Vector<Function<void(const LegacyExtensions::WebsiteAccess&)>> { }; });
    LegacyExtensions::loadWebsiteAccess(root, [this, extensionKey, root](LegacyExtensions::WebsiteAccess&& access) {
        if (m_websiteAccessRoots.get(extensionKey) != root)
            return;
        m_websiteAccess.set(extensionKey, WTF::move(access));
        auto& loaded = m_websiteAccess.find(extensionKey)->value;
        for (auto& waiter : m_websiteAccessWaiters.take(extensionKey))
            waiter(loaded);
        updateNetworkListeners();
    });
}

void LegacyExtensionHost::withWebsiteAccess(const String& extensionKey, Function<void(const LegacyExtensions::WebsiteAccess&)>&& function)
{
    if (auto iterator = m_websiteAccess.find(extensionKey); iterator != m_websiteAccess.end())
        return function(iterator->value);
    if (auto iterator = m_websiteAccessWaiters.find(extensionKey); iterator != m_websiteAccessWaiters.end())
        return iterator->value.append(WTF::move(function));
    function({ });
}

void LegacyExtensionHost::dispatchEvent(const String& eventName, Ref<JSON::Array>&& arguments)
{
    Vector<Ref<HostContext>> listeners;
    for (auto& context : m_hostContexts.values()) {
        if (context->interests.contains(eventName))
            listeners.append(context);
    }
    if (listeners.isEmpty())
        return;
    auto event = JSON::Object::create();
    event->setString("t"_s, "event"_s);
    event->setString("name"_s, eventName);
    event->setArray("args"_s, WTF::move(arguments));
    auto message = event->toJSONString();
    for (auto& context : listeners)
        deliver(Endpoint { context.ptr(), std::nullopt }, context->extensionKey, message);
}

void LegacyExtensionHost::pageWasCreated(WebPageProxy& page)
{
    auto observer = LegacyExtensionTabObserver::create(page, [](WebPageProxy& page, Ref<JSON::Object>&& changeInfo) {
        auto& host = LegacyExtensionHost::singleton();
        auto arguments = JSON::Array::create();
        arguments->pushDouble(tabIDForPage(page));
        arguments->pushObject(WTF::move(changeInfo));
        arguments->pushObject(host.tabDescription(page));
        host.dispatchEvent("tabs.onUpdated"_s, WTF::move(arguments));
    });
    page.pageLoadState().addObserver(observer.get());
    tabObservers().set(page.identifier(), WTF::move(observer));

    auto arguments = JSON::Array::create();
    arguments->pushObject(tabDescription(page));
    dispatchEvent("tabs.onCreated"_s, WTF::move(arguments));
    if (!m_cookieObservers.isEmpty())
        updateCookieObservers();
}

void LegacyExtensionHost::pageWillClose(WebPageProxy& page)
{
    if (auto observer = tabObservers().take(page.identifier()))
        page.pageLoadState().removeObserver(*observer);

    Vector<WebCore::FrameIdentifier> frameIDs;
    if (RefPtr mainFrame = page.mainFrame()) {
        forEachFrame(*mainFrame, [&](auto& frame) {
            frameIDs.append(frame.frameID());
        });
    }
    framesDidGoAway(frameIDs);

    auto removeInfo = JSON::Object::create();
    removeInfo->setDouble("windowId"_s, -1);
    removeInfo->setBoolean("isWindowClosing"_s, false);
    auto arguments = JSON::Array::create();
    arguments->pushDouble(tabIDForPage(page));
    arguments->pushObject(WTF::move(removeInfo));
    dispatchEvent("tabs.onRemoved"_s, WTF::move(arguments));
}

static Ref<JSON::Object> navigationDetails(WebPageProxy& page, WebFrameProxy& frame, const URL& url)
{
    auto details = JSON::Object::create();
    details->setDouble("tabId"_s, tabIDForPage(page));
    details->setDouble("frameId"_s, frameIDForFrame(frame));
    details->setDouble("parentFrameId"_s, parentFrameIDForFrame(frame));
    details->setString("url"_s, url.string());
    details->setDouble("processId"_s, -1);
    details->setDouble("timeStamp"_s, timeStamp());
    return details;
}

void LegacyExtensionHost::didCommitLoad(WebPageProxy& page, WebFrameProxy& frame, Markable<WebCore::ScriptExecutionContextIdentifier> documentID, API::Navigation* navigation, WebCore::FrameLoadType loadType, const URL& url)
{
    // The frame's subframes, and every context of the frame's other documents, are gone.
    Vector<WebCore::FrameIdentifier> subframeIDs;
    forEachFrame(frame, [&](auto& subframe) {
        if (&subframe != &frame)
            subframeIDs.append(subframe.frameID());
    });
    framesDidGoAway(subframeIDs);
    endpointsDidGoAway([&](auto& endpoint) {
        return !endpoint.host && endpoint.frameID == frame.frameID() && endpoint.documentID != documentID;
    });
    documentsDidGoAway([&](auto frameID, auto candidate) {
        return frameID == frame.frameID() && candidate != documentID;
    });
    if (auto identifier = m_hostContextByRemoteFrame.get(frame.frameID())) {
        RefPtr context = m_hostContexts.get(identifier);
        if (context && context->documentID != documentID) {
            m_hostContextByRemoteFrame.remove(frame.frameID());
            m_hostContexts.remove(identifier);
            hostContextDidGoAway(*context);
        }
    }

    auto details = navigationDetails(page, frame, url);
    bool isBackForward = loadType == WebCore::FrameLoadType::Back || loadType == WebCore::FrameLoadType::Forward || loadType == WebCore::FrameLoadType::IndexedBackForward;
    RefPtr historyItem = frame.isMainFrame() ? page.backForwardList().currentItem() : nullptr;
    auto transitionType = [&] -> String {
        if (!frame.isMainFrame())
            return "auto_subframe"_s;
        if (isBackForward) {
            if (auto transition = historyItem ? m_historyItemTransitions.get(*historyItem) : String(); !transition.isNull())
                return transition;
            return "link"_s;
        }
        if (loadType == WebCore::FrameLoadType::Reload || loadType == WebCore::FrameLoadType::ReloadFromOrigin || loadType == WebCore::FrameLoadType::ReloadExpiredOnly)
            return "reload"_s;
        auto& action = navigation ? navigation->lastNavigationAction() : std::nullopt;
        switch (action ? action->navigationType : WebCore::NavigationType::Other) {
        case WebCore::NavigationType::FormSubmitted:
        case WebCore::NavigationType::FormResubmitted:
            return "form_submit"_s;
        case WebCore::NavigationType::Reload:
            return "reload"_s;
        case WebCore::NavigationType::LinkClicked:
            return "link"_s;
        default:
            return navigation && navigation->isRequestFromClientOrUserInput() ? "typed"_s : "link"_s;
        }
    }();
    if (historyItem && !isBackForward)
        m_historyItemTransitions.set(*historyItem, transitionType);
    details->setString("transitionType"_s, transitionType);
    auto qualifiers = JSON::Array::create();
    if (isBackForward)
        qualifiers->pushString("forward_back"_s);
    if (navigation && navigation->currentRequestIsRedirect())
        qualifiers->pushString("server_redirect"_s);
    details->setArray("transitionQualifiers"_s, WTF::move(qualifiers));

    auto arguments = JSON::Array::create();
    arguments->pushObject(WTF::move(details));
    dispatchEvent("webNavigation.onCommitted"_s, WTF::move(arguments));
}

void LegacyExtensionHost::didStartProvisionalLoad(WebPageProxy& page, WebFrameProxy& frame, const URL& url)
{
    auto arguments = JSON::Array::create();
    arguments->pushObject(navigationDetails(page, frame, url));
    dispatchEvent("webNavigation.onBeforeNavigate"_s, WTF::move(arguments));
}

void LegacyExtensionHost::didFinishLoad(WebPageProxy& page, WebFrameProxy& frame)
{
    auto arguments = JSON::Array::create();
    arguments->pushObject(navigationDetails(page, frame, frame.url()));
    dispatchEvent("webNavigation.onCompleted"_s, WTF::move(arguments));
}

// A frame's navigation that fails before it commits, or a committed document's load that fails.
void LegacyExtensionHost::didFailLoad(WebPageProxy& page, WebFrameProxy& frame, const URL& url, const WebCore::ResourceError& error)
{
    auto details = navigationDetails(page, frame, url);
    details->setString("error"_s, LegacyExtensions::networkErrorName(error));
    auto arguments = JSON::Array::create();
    arguments->pushObject(WTF::move(details));
    dispatchEvent("webNavigation.onErrorOccurred"_s, WTF::move(arguments));
}

void LegacyExtensionHost::didFinishDocumentLoad(WebPageProxy& page, WebFrameProxy& frame)
{
    auto arguments = JSON::Array::create();
    arguments->pushObject(navigationDetails(page, frame, frame.url()));
    dispatchEvent("webNavigation.onDOMContentLoaded"_s, WTF::move(arguments));
}

void LegacyExtensionHost::didCreateNavigationTarget(WebPageProxy& sourcePage, WebCore::FrameIdentifier sourceFrameID, WebPageProxy& newPage, const URL& url)
{
    auto details = JSON::Object::create();
    details->setDouble("sourceTabId"_s, tabIDForPage(sourcePage));
    RefPtr sourceFrame = WebFrameProxy::webFrame(sourceFrameID);
    details->setDouble("sourceFrameId"_s, sourceFrame ? frameIDForFrame(*sourceFrame) : 0);
    details->setDouble("sourceProcessId"_s, -1);
    details->setDouble("tabId"_s, tabIDForPage(newPage));
    details->setString("url"_s, url.string());
    details->setDouble("timeStamp"_s, timeStamp());
    auto arguments = JSON::Array::create();
    arguments->pushObject(WTF::move(details));
    dispatchEvent("webNavigation.onCreatedNavigationTarget"_s, WTF::move(arguments));
}

// webRequest.

static void normalizeWebRequestDetails(JSON::Object& details)
{
    auto tabID = details.getDouble("tabId"_s);
    details.setDouble("tabId"_s, pageForTabID(tabID) ? *tabID : -1);

    auto rawFrameID = details.getDouble("frameId"_s).value_or(0);
    auto rawParentFrameID = details.getDouble("parentFrameId"_s).value_or(0);
    RefPtr frame = frameIdentifier(rawFrameID) ? WebFrameProxy::webFrame(frameIdentifier(rawFrameID)) : nullptr;
    RefPtr parentFrame = frameIdentifier(rawParentFrameID) ? WebFrameProxy::webFrame(frameIdentifier(rawParentFrameID)) : nullptr;
    if (frame)
        details.setDouble("frameId"_s, frameIDForFrame(*frame));
    else if (!rawParentFrameID)
        details.setDouble("frameId"_s, 0);
    if (parentFrame)
        details.setDouble("parentFrameId"_s, frameIDForFrame(*parentFrame));
    else
        details.setDouble("parentFrameId"_s, rawParentFrameID ? rawParentFrameID : -1);
}

void LegacyExtensionHost::dispatchWebRequestEvent(const String& eventName, const String& detailsJSON, CompletionHandler<void(String&&)>&& completionHandler)
{
    auto value = JSON::Value::parseJSON(detailsJSON);
    RefPtr details = value ? value->asObject() : nullptr;
    if (!details) {
        if (completionHandler)
            completionHandler("{}"_s);
        return;
    }
    normalizeWebRequestDetails(*details);

    auto qualifiedName = makeString("webRequest."_s, eventName);
    // An extension's own resources are visible only to that extension; a web request, only to the extensions
    // whose website access covers it.
    URL requestURL { details->getString("url"_s) };
    auto owningExtension = extensionKeyForURL(requestURL);
    Vector<Ref<HostContext>> listeners;
    for (auto& context : m_hostContexts.values()) {
        if (!context->interests.contains(qualifiedName))
            continue;
        if (!owningExtension.isNull()) {
            if (context->extensionKey != owningExtension)
                continue;
        } else if (auto iterator = m_websiteAccess.find(context->extensionKey); iterator == m_websiteAccess.end() || !iterator->value.allows(requestURL))
            continue;
        listeners.append(context);
    }

    if (listeners.isEmpty()) {
        if (completionHandler)
            completionHandler("{}"_s);
        return;
    }

    auto event = JSON::Object::create();
    event->setString("t"_s, "event"_s);
    event->setString("name"_s, qualifiedName);
    auto arguments = JSON::Array::create();
    arguments->pushObject(details.releaseNonNull());
    event->setArray("args"_s, WTF::move(arguments));

    if (!completionHandler) {
        auto message = event->toJSONString();
        for (auto& context : listeners)
            deliver(Endpoint { context.ptr(), std::nullopt }, context->extensionKey, message);
        return;
    }

    auto token = m_nextIdentifier++;
    event->setDouble("token"_s, static_cast<double>(token));
    auto message = event->toJSONString();
    WebRequestCall call { { }, JSON::Object::create(), WTF::move(completionHandler) };
    for (auto& context : listeners)
        call.pendingHostContexts.append(context->identifier);
    m_webRequestCalls.add(token, WTF::move(call));
    for (auto& context : listeners) {
        if (!deliver(Endpoint { context.ptr(), std::nullopt }, context->extensionKey, message)) {
            if (auto iterator = m_webRequestCalls.find(token); iterator != m_webRequestCalls.end())
                iterator->value.pendingHostContexts.removeAll(context->identifier);
        }
    }
    finishWebRequestCallIfComplete(token);
}

void LegacyExtensionHost::routeWebRequestResponse(const HostContext& context, JSON::Object& message)
{
    auto token = integerIdentifier(message.getDouble("token"_s).value_or(0));
    if (!token)
        return;
    auto iterator = m_webRequestCalls.find(*token);
    if (iterator == m_webRequestCalls.end())
        return;
    auto& call = iterator->value;
    if (!call.pendingHostContexts.removeFirst(context.identifier))
        return;

    // Chrome's merge across extensions: any cancel wins, the first redirect and the first credentials win,
    // header rewrites replace.
    if (RefPtr result = message.getObject("result"_s)) {
        if (result->getBoolean("cancel"_s).value_or(false))
            call.response->setBoolean("cancel"_s, true);
        if (auto redirectURL = result->getString("redirectUrl"_s); !redirectURL.isNull() && call.response->getString("redirectUrl"_s).isNull())
            call.response->setString("redirectUrl"_s, redirectURL);
        if (RefPtr credentials = result->getObject("authCredentials"_s); credentials && !call.response->getObject("authCredentials"_s))
            call.response->setObject("authCredentials"_s, credentials.releaseNonNull());
        if (RefPtr headers = result->getArray("requestHeaders"_s))
            call.response->setArray("requestHeaders"_s, headers.releaseNonNull());
        if (RefPtr headers = result->getArray("responseHeaders"_s))
            call.response->setArray("responseHeaders"_s, headers.releaseNonNull());
    }
    finishWebRequestCallIfComplete(*token);
}

void LegacyExtensionHost::finishWebRequestCallIfComplete(uint64_t token)
{
    auto iterator = m_webRequestCalls.find(token);
    if (iterator == m_webRequestCalls.end() || !iterator->value.pendingHostContexts.isEmpty())
        return;
    auto call = m_webRequestCalls.take(iterator);
    call.completionHandler(call.response->toJSONString());
}

void LegacyExtensionHost::updateNetworkListeners()
{
    Vector<String> observed;
    Vector<String> options;
    auto blocking = JSON::Object::create();
    for (auto& context : m_hostContexts.values()) {
        for (auto& [name, interest] : context->interests) {
            if (!name.startsWith("webRequest."_s))
                continue;
            auto eventName = name.substring(11);
            if (!observed.contains(eventName))
                observed.append(eventName);
            RefPtr interestValue = JSON::Value::parseJSON(interest);
            RefPtr interestObject = interestValue ? interestValue->asObject() : nullptr;
            if (!interestObject)
                continue;
            for (auto option : { "requestBody"_s, "extraHeaders"_s }) {
                auto qualifiedOption = makeString(eventName, ':', option);
                if (interestObject->getBoolean(option).value_or(false) && !options.contains(qualifiedOption))
                    options.append(WTF::move(qualifiedOption));
            }
            RefPtr filters = interestObject->getArray("blockingFilters"_s);
            if (!filters)
                continue;
            RefPtr listeners = blocking->getArray(eventName);
            if (!listeners) {
                listeners = JSON::Array::create();
                blocking->setArray(eventName, Ref { *listeners });
            }
            for (auto& filterValue : *filters) {
                RefPtr filter = filterValue->asObject();
                if (!filter)
                    continue;
                filter->setString("extension"_s, context->extensionKey);
                if (auto iterator = m_websiteAccess.find(context->extensionKey); iterator != m_websiteAccess.end())
                    filter->setObject("access"_s, iterator->value.toJSON());
                listeners->pushObject(filter.releaseNonNull());
            }
        }
    }
    auto blockingListeners = blocking->toJSONString();
    if (observed == m_observedNetworkEvents && options == m_networkListenerOptions && blockingListeners == m_blockingNetworkListeners)
        return;
    m_observedNetworkEvents = WTF::move(observed);
    m_networkListenerOptions = WTF::move(options);
    m_blockingNetworkListeners = WTF::move(blockingListeners);
    for (Ref networkProcess : NetworkProcessProxy::allNetworkProcesses())
        sendNetworkListeners(networkProcess);
}

void LegacyExtensionHost::sendNetworkListeners(NetworkProcessProxy& networkProcess)
{
    networkProcess.send(Messages::LegacyExtensionNetwork::SetListeners(m_observedNetworkEvents, m_networkListenerOptions, m_blockingNetworkListeners), 0);
}

void LegacyExtensionNetworkProxy::dispatchBlockingEvent(String&& eventName, String&& details, CompletionHandler<void(String&&)>&& completionHandler)
{
    LegacyExtensionHost::singleton().dispatchWebRequestEvent(eventName, details, WTF::move(completionHandler));
}

void LegacyExtensionNetworkProxy::dispatchEvent(String&& eventName, String&& details)
{
    LegacyExtensionHost::singleton().dispatchWebRequestEvent(eventName, details, { });
}

} // namespace WebKit
