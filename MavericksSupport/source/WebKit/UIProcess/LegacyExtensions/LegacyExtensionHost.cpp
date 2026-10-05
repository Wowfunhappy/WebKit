#include "config.h"
#include "LegacyExtensionHost.h"

#include "APIContentWorld.h"
#include "APIUserScript.h"
#include "APIUserStyleSheet.h"
#include "LegacyExtensionChannel.h"
#include "LegacyExtensionClipboard.h"
#include "LegacyExtensionContentMessages.h"
#include "LegacyExtensionErrors.h"
#include "LegacyExtensionHostMessages.h"
#include "LegacyExtensionInfoPlist.h"
#include "LegacyExtensionJavaScript.h"
#include "LegacyExtensionResources.h"
#include "LegacyExtensionScheme.h"
#include "LegacyExtensionNetworkMessages.h"
#include "LegacyExtensionNetworkProxyMessages.h"
#include "APIHTTPCookieStore.h"
#include "APINavigation.h"
#include "FrameTreeNodeData.h"
#include "InjectUserScriptImmediately.h"
#include "NetworkProcessProxy.h"
#include "PageLoadState.h"
#include "WebBackForwardList.h"
#include "WebBackForwardListItem.h"
#include "WebFrameProxy.h"
#include "WebLegacyExtensionPageObserver.h"
#include "WebPageProxy.h"
#include "WebProcessPool.h"
#include "WebProcessProxy.h"
#include "WebUserContentControllerProxy.h"
#include "WebsiteDataStore.h"
#include <JavaScriptCore/APICast.h>
#include <JavaScriptCore/JSGlobalObject.h>
#include <JavaScriptCore/JSLock.h>
#include <JavaScriptCore/WeakInlines.h>
#include <WebCore/Cookie.h>
#include <WebCore/MemoryCache.h>
#include <WebCore/ResourceRequest.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/RunLoop.h>
#include <wtf/WallTime.h>
#include <wtf/text/Base64.h>
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
    if (!message.isNull())
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

static RefPtr<WebPageProxy> pageForIdentifier(std::optional<uint64_t> rawValue)
{
    if (!rawValue || !WebPageProxyIdentifier::isValidIdentifier(*rawValue))
        return nullptr;
    RefPtr page = WebProcessProxy::webPage(WebPageProxyIdentifier { *rawValue });
    if (!page || page->isClosed())
        return nullptr;
    return page;
}

static constexpr uint64_t satelliteTabIDBase = 1ull << 32;

RefPtr<WebPageProxy> LegacyExtensionHost::pageForTabID(std::optional<double> tabID) const
{
    auto rawValue = tabID ? integerIdentifier(*tabID) : std::nullopt;
    if (!rawValue)
        return nullptr;
    bool isSatelliteTab = *rawValue >= satelliteTabIDBase;
    if (isSatelliteTab && (!m_satelliteNumber || *rawValue / satelliteTabIDBase != m_satelliteNumber))
        return nullptr;
    RefPtr page = pageForIdentifier(*rawValue % satelliteTabIDBase);
    if (!page || isSatellitePage(*page) != isSatelliteTab)
        return nullptr;
    return page;
}

double LegacyExtensionHost::tabIDForPage(const WebPageProxy& page) const
{
    auto identifier = page.identifier().toUInt64();
    if (isSatellitePage(page))
        identifier += m_satelliteNumber * satelliteTabIDBase;
    return static_cast<double>(identifier);
}

uint64_t LegacyExtensionHost::satelliteForTabID(std::optional<double> tabID)
{
    auto rawValue = tabID ? integerIdentifier(*tabID) : std::nullopt;
    return rawValue ? *rawValue / satelliteTabIDBase : 0;
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
    startHub();
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

void LegacyExtensionHost::post(IPC::Connection& connection, WebCore::FrameIdentifier frameID, WebCore::ScriptExecutionContextIdentifier documentID, URL&& documentURL, String&& extensionKey, String&& message)
{
    RefPtr frame = WebFrameProxy::webFrame(frameID);
    if (!frame || !frame->page())
        return;
    if (!protect(frame->process())->hasConnection(connection))
        return;
    m_documents.set(documentID, std::pair { frameID, documentURL });
    if (m_satelliteNumber && isSatellitePage(*frame->page())) {
        auto post = JSON::Object::create();
        post->setString("t"_s, "post"_s);
        post->setDouble("token"_s, static_cast<double>(tokenForDocument(frameID, documentID)));
        post->setString("key"_s, extensionKey);
        post->setString("message"_s, message);
        post->setObject("sender"_s, senderDescription(Endpoint { nullptr, frameID, documentID }));
        post->setString("url"_s, documentURL.string());
        post->setBoolean("extensionPage"_s, extensionKeyForURL(documentURL) == extensionKey);
        LegacyExtensions::sendToHub(post.get());
        return;
    }
    if (RefPtr context = extensionPageContext(*frame, documentID, documentURL, extensionKey)) {
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
    satelliteDocumentsDidGoAway([&](auto& document) {
        return frameIDs.contains(*document.frameID);
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
    auto satellite = endpoint.host ? endpoint.host->satellite : endpoint.satellite;
    if (satellite) {
        if (endpoint.host && !m_hostContexts.contains(endpoint.host->identifier))
            return false;
        if (!LegacyExtensions::satellites().contains(satellite))
            return false;
        auto delivery = JSON::Object::create();
        delivery->setString("t"_s, "deliver"_s);
        delivery->setDouble("token"_s, static_cast<double>(endpoint.host ? endpoint.host->remoteToken : endpoint.remoteToken));
        delivery->setString("key"_s, extensionKey);
        delivery->setString("message"_s, message);
        LegacyExtensions::sendToSatellite(satellite, delivery.get());
        return true;
    }
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
    if (auto satellite = endpoint.host ? endpoint.host->satellite : endpoint.satellite) {
        auto iterator = m_remoteSenders.find({ satellite, endpoint.host ? endpoint.host->remoteToken : endpoint.remoteToken });
        if (iterator != m_remoteSenders.end())
            return iterator->value.copyRef();
        return JSON::Object::create();
    }
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

    if (from.host && message.getDouble("tabId"_s))
        return endpointsForTab(message.getDouble("tabId"_s), message.getDouble("frameId"_s), extensionKey, WTF::move(didFindReceivers));
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

    if (from.host && message.getDouble("tabId"_s))
        return endpointsForTab(message.getDouble("tabId"_s), message.getDouble("frameId"_s), extensionKey, WTF::move(didFindReceivers));
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
        auto evict = JSON::Object::create();
        evict->setString("t"_s, "evict"_s);
        for (auto satellite : LegacyExtensions::satellites())
            LegacyExtensions::sendToSatellite(satellite, evict.get());
        resultToHostContext(context, callID, nullptr);
        return;
    }

    // navigator.clipboard.readText(), for an extension's pages.
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

    // A satellite's tabs answer for themselves; tabs.remove closes each tab where it is.
    if (method == "tabs.remove"_s) {
        if (RefPtr tabIDs = argument(0) ? argument(0)->asArray() : nullptr) {
            for (auto& tabID : *tabIDs) {
                if (auto satellite = satelliteForTabID(tabID->asDouble())) {
                    auto remove = JSON::Object::create();
                    remove->setString("t"_s, "call"_s);
                    remove->setString("method"_s, method);
                    auto removeArguments = JSON::Array::create();
                    auto removedTabIDs = JSON::Array::create();
                    removedTabIDs->pushValue(tabID.copyRef());
                    removeArguments->pushArray(WTF::move(removedTabIDs));
                    remove->setArray("args"_s, WTF::move(removeArguments));
                    LegacyExtensions::sendToSatellite(satellite, remove.get());
                }
            }
        }
    }
    if (method == "tabs.get"_s || method == "tabs.remove"_s || method == "tabs.reload"_s || method == "tabs.update"_s || method == "webNavigation.getFrame"_s || method == "webNavigation.getAllFrames"_s) {
        RefPtr details = method.startsWith("webNavigation."_s) ? objectArgument(0) : nullptr;
        auto tabID = details ? details->getDouble("tabId"_s) : numberArgument(0);
        if (auto satellite = method != "tabs.remove"_s ? satelliteForTabID(tabID) : 0)
            return forwardTabCall(satellite, context, callID, method, WTF::move(arguments));
        performTabCall(method, WTF::move(arguments), [this, context = Ref { context }, callID](RefPtr<JSON::Value>&& result, String&& error) {
            if (m_hostContexts.contains(context->identifier))
                resultToHostContext(context, callID, WTF::move(result), error);
        });
        return;
    }

    if (method == "tabs.executeScript"_s || method == "tabs.insertCSS"_s || method == "tabs.removeCSS"_s) {
        auto tabID = numberArgument(0);
        RefPtr details = objectArgument(1);
        if ((!pageForTabID(tabID) && !satelliteForTabID(tabID)) || !details) {
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
        endpointsForTab(tabID, targetFrameId, context.extensionKey, [this, context = Ref { context }, callID, method, routerCallID, requestMessage = request->toJSONString()](Vector<Endpoint>&& targets) {
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

// The tab methods a tab's own process answers: tabs.get, remove, reload and update, and webNavigation.getFrame
// and getAllFrames.
void LegacyExtensionHost::performTabCall(const String& method, RefPtr<JSON::Array>&& arguments, CompletionHandler<void(RefPtr<JSON::Value>&&, String&&)>&& completionHandler)
{
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

    if (method == "tabs.get"_s) {
        RefPtr page = pageForTabID(numberArgument(0));
        completionHandler(page ? RefPtr<JSON::Value> { tabDescription(*page) } : RefPtr<JSON::Value> { JSON::Value::null() }, { });
        return;
    }

    if (method == "tabs.remove"_s) {
        if (RefPtr tabIDs = argument(0) ? argument(0)->asArray() : nullptr) {
            for (auto& tabID : *tabIDs) {
                if (RefPtr page = pageForTabID(tabID->asDouble()))
                    page->closePage();
            }
        }
        completionHandler(nullptr, { });
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
        completionHandler(nullptr, { });
        return;
    }

    if (method == "tabs.update"_s) {
        RefPtr page = pageForTabID(numberArgument(0));
        if (!page) {
            completionHandler(nullptr, "No tab with this id."_s);
            return;
        }
        RefPtr properties = objectArgument(1);
        if (properties) {
            auto url = properties->getString("url"_s);
            if (!url.isEmpty())
                page->loadRequest(WebCore::ResourceRequest { URL { url } });
        }
        completionHandler(tabDescription(*page).ptr(), { });
        return;
    }

    if (method == "webNavigation.getFrame"_s || method == "webNavigation.getAllFrames"_s) {
        RefPtr details = objectArgument(0);
        RefPtr page = details ? pageForTabID(details->getDouble("tabId"_s)) : nullptr;
        if (!page) {
            completionHandler(JSON::Value::null(), { });
            return;
        }
        bool allFrames = method == "webNavigation.getAllFrames"_s;
        auto wantedFrameId = details->getDouble("frameId"_s).value_or(0);
        page->getAllFrames([completionHandler = WTF::move(completionHandler), allFrames, wantedFrameId](std::optional<FrameTreeNodeData>&& tree) mutable {
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
                return completionHandler(frames.ptr(), { });
            completionHandler(wantedFrame ? RefPtr<JSON::Value> { wantedFrame } : RefPtr<JSON::Value> { JSON::Value::null() }, { });
        });
        return;
    }

    completionHandler(nullptr, makeString("Unsupported method "_s, method));
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

// An event about a satellite's tab goes to the hub.
void LegacyExtensionHost::dispatchTabEvent(WebPageProxy& page, const String& eventName, Ref<JSON::Array>&& arguments)
{
    if (!isSatellitePage(page))
        return dispatchEvent(eventName, WTF::move(arguments));
    if (!m_satelliteNumber)
        return;
    auto event = JSON::Object::create();
    event->setString("t"_s, "event"_s);
    event->setString("name"_s, eventName);
    event->setArray("args"_s, WTF::move(arguments));
    LegacyExtensions::sendToHub(event.get());
}

void LegacyExtensionHost::pageWasCreated(WebPageProxy& page)
{
    auto observer = LegacyExtensionTabObserver::create(page, [](WebPageProxy& page, Ref<JSON::Object>&& changeInfo) {
        auto& host = LegacyExtensionHost::singleton();
        auto arguments = JSON::Array::create();
        arguments->pushDouble(host.tabIDForPage(page));
        arguments->pushObject(WTF::move(changeInfo));
        arguments->pushObject(host.tabDescription(page));
        host.dispatchTabEvent(page, "tabs.onUpdated"_s, WTF::move(arguments));
    });
    page.pageLoadState().addObserver(observer.get());
    tabObservers().set(page.identifier(), WTF::move(observer));

    if (isSatellitePage(page) && !m_contentControllers.contains(page.userContentController()))
        installContent(page.userContentController());

    auto arguments = JSON::Array::create();
    arguments->pushObject(tabDescription(page));
    dispatchTabEvent(page, "tabs.onCreated"_s, WTF::move(arguments));
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
    dispatchTabEvent(page, "tabs.onRemoved"_s, WTF::move(arguments));
}

static Ref<JSON::Object> navigationDetails(WebPageProxy& page, WebFrameProxy& frame, const URL& url)
{
    auto details = JSON::Object::create();
    details->setDouble("tabId"_s, LegacyExtensionHost::singleton().tabIDForPage(page));
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
    satelliteDocumentsDidGoAway([&](auto& document) {
        return *document.frameID == frame.frameID() && document.documentID != documentID;
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
    dispatchTabEvent(page, "webNavigation.onCommitted"_s, WTF::move(arguments));
}

void LegacyExtensionHost::didStartProvisionalLoad(WebPageProxy& page, WebFrameProxy& frame, const URL& url)
{
    auto arguments = JSON::Array::create();
    arguments->pushObject(navigationDetails(page, frame, url));
    dispatchTabEvent(page, "webNavigation.onBeforeNavigate"_s, WTF::move(arguments));
}

void LegacyExtensionHost::didFinishLoad(WebPageProxy& page, WebFrameProxy& frame)
{
    auto arguments = JSON::Array::create();
    arguments->pushObject(navigationDetails(page, frame, frame.url()));
    dispatchTabEvent(page, "webNavigation.onCompleted"_s, WTF::move(arguments));
}

// A frame's navigation that fails before it commits, or a committed document's load that fails.
void LegacyExtensionHost::didFailLoad(WebPageProxy& page, WebFrameProxy& frame, const URL& url, const WebCore::ResourceError& error)
{
    auto details = navigationDetails(page, frame, url);
    details->setString("error"_s, LegacyExtensions::networkErrorName(error));
    auto arguments = JSON::Array::create();
    arguments->pushObject(WTF::move(details));
    dispatchTabEvent(page, "webNavigation.onErrorOccurred"_s, WTF::move(arguments));
}

void LegacyExtensionHost::didFinishDocumentLoad(WebPageProxy& page, WebFrameProxy& frame)
{
    auto arguments = JSON::Array::create();
    arguments->pushObject(navigationDetails(page, frame, frame.url()));
    dispatchTabEvent(page, "webNavigation.onDOMContentLoaded"_s, WTF::move(arguments));
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
    dispatchTabEvent(newPage, "webNavigation.onCreatedNavigationTarget"_s, WTF::move(arguments));
}

// webRequest.

static void normalizeWebRequestDetails(JSON::Object& details)
{
    auto tabID = details.getDouble("tabId"_s);
    RefPtr page = pageForIdentifier(tabID ? integerIdentifier(*tabID) : std::nullopt);
    details.setDouble("tabId"_s, page ? LegacyExtensionHost::singleton().tabIDForPage(*page) : -1);

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
    auto webProcessIdentifier = integerIdentifier(details->getDouble("webProcess"_s).value_or(0));
    details->remove("webProcess"_s);
    normalizeWebRequestDetails(*details);

    // A satellite's web requests, those of its pools' web content processes, go to the hub's listeners.
    if (m_satelliteNumber) {
        RefPtr process = webProcessIdentifier && WebCore::ProcessIdentifier::isValidIdentifier(*webProcessIdentifier) ? WebProcessProxy::processForIdentifier(WebCore::ProcessIdentifier { *webProcessIdentifier }) : nullptr;
        RefPtr page = pageForTabID(details->getDouble("tabId"_s));
        if (process ? m_satellitePools.contains(process->processPool()) : page && isSatellitePage(*page)) {
            auto request = JSON::Object::create();
            request->setString("t"_s, "webRequest"_s);
            request->setString("name"_s, eventName);
            request->setObject("details"_s, details.releaseNonNull());
            if (completionHandler) {
                auto identifier = m_nextIdentifier++;
                m_satelliteWebRequests.add(identifier, WTF::move(completionHandler));
                request->setDouble("id"_s, static_cast<double>(identifier));
            }
            LegacyExtensions::sendToHub(request.get());
            return;
        }
    }
    dispatchWebRequestDetails(eventName, details.releaseNonNull(), WTF::move(completionHandler));
}

void LegacyExtensionHost::dispatchWebRequestDetails(const String& eventName, Ref<JSON::Object>&& details, CompletionHandler<void(String&&)>&& completionHandler)
{
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
    arguments->pushObject(WTF::move(details));
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
    updateWelcomeMessages();
    auto listeners = networkListenersMessage();
    for (auto satellite : LegacyExtensions::satellites())
        LegacyExtensions::sendToSatellite(satellite, listeners.get());
}

void LegacyExtensionHost::sendNetworkListeners(NetworkProcessProxy& networkProcess)
{
    networkProcess.send(Messages::LegacyExtensionNetwork::SetListeners(m_observedNetworkEvents, m_networkListenerOptions, m_blockingNetworkListeners), 0);
}

// The contexts an extension has in a tab's frames, here or in a satellite.
void LegacyExtensionHost::endpointsForTab(std::optional<double> tabID, std::optional<double> frameId, const String& extensionKey, CompletionHandler<void(Vector<Endpoint>&&)>&& completionHandler)
{
    if (RefPtr page = pageForTabID(tabID))
        return tabEndpoints(*page, frameId, extensionKey, WTF::move(completionHandler));
    auto satellite = satelliteForTabID(tabID);
    if (!satellite || !LegacyExtensions::satellites().contains(satellite))
        return completionHandler({ });
    auto requestID = m_nextIdentifier++;
    m_remoteEndpointsRequests.add(requestID, RemoteEndpointsRequest { satellite, extensionKey, WTF::move(completionHandler) });
    auto request = JSON::Object::create();
    request->setString("t"_s, "endpoints"_s);
    request->setDouble("requestId"_s, static_cast<double>(requestID));
    request->setDouble("tabId"_s, *tabID);
    if (frameId)
        request->setDouble("frameId"_s, *frameId);
    request->setString("key"_s, extensionKey);
    LegacyExtensions::sendToSatellite(satellite, request.get());
}

// The hub.

void LegacyExtensionHost::startHub()
{
    LegacyExtensions::startHub([](uint64_t satellite, Ref<JSON::Object>&& message) {
        LegacyExtensionHost::singleton().receiveFromSatellite(satellite, message.get());
    }, [](uint64_t satellite) {
        LegacyExtensionHost::singleton().satelliteDidGoAway(satellite);
    });
    updateWelcomeMessages();
}

// Each of Safari's web content processes reports what its pages get, and an extension's page adds content to
// them one by one: the bundle's content is all the live processes report, in the order the oldest reports it.
void LegacyExtensionHost::didChangeBundleContent(IPC::Connection& connection, String&& content)
{
    auto value = JSON::Value::parseJSON(content);
    RefPtr items = value ? value->asArray() : nullptr;
    if (!items)
        return;
    m_bundleContentByProcess.set(WebProcessProxy::fromConnection(connection)->coreProcessIdentifier(), items.releaseNonNull());
    m_bundleContentByProcess.removeIf([](auto& entry) {
        return !WebProcessProxy::processForIdentifier(entry.key);
    });
    auto processes = copyToVector(m_bundleContentByProcess.keys());
    std::ranges::sort(processes, [](auto a, auto b) {
        return a.toUInt64() < b.toUInt64();
    });
    auto merged = JSON::Array::create();
    HashSet<String> mergedItems;
    for (auto process : processes) {
        for (auto& itemValue : m_bundleContentByProcess.find(process)->value.get()) {
            RefPtr item = itemValue->asObject();
            if (item && mergedItems.add(makeString(item->getString("kind"_s), ' ', item->getString("url"_s))).isNewEntry)
                merged->pushValue(itemValue.copyRef());
        }
    }
    auto mergedContent = merged->toJSONString();
    if (mergedContent == m_bundleContent)
        return;
    m_bundleContent = WTF::move(mergedContent);
    startHub();
    auto message = JSON::Object::create();
    message->setString("t"_s, "content"_s);
    message->setString("content"_s, m_bundleContent);
    for (auto satellite : LegacyExtensions::satellites())
        LegacyExtensions::sendToSatellite(satellite, message.get());
}

Ref<JSON::Object> LegacyExtensionHost::networkListenersMessage() const
{
    auto message = JSON::Object::create();
    message->setString("t"_s, "listeners"_s);
    auto observed = JSON::Array::create();
    for (auto& eventName : m_observedNetworkEvents)
        observed->pushString(eventName);
    message->setArray("observed"_s, WTF::move(observed));
    auto options = JSON::Array::create();
    for (auto& option : m_networkListenerOptions)
        options->pushString(option);
    message->setArray("options"_s, WTF::move(options));
    message->setString("blocking"_s, m_blockingNetworkListeners);
    return message;
}

// A satellite starts with the bundle's content and the network listeners, which the channel holds for its
// welcome before any satellite is sent their changes.
void LegacyExtensionHost::updateWelcomeMessages()
{
    auto content = JSON::Object::create();
    content->setString("t"_s, "content"_s);
    content->setString("content"_s, m_bundleContent.isNull() ? "[]"_s : m_bundleContent);
    LegacyExtensions::setWelcomeMessages({ WTF::move(content), networkListenersMessage() });
}

// An extension page in a satellite's frame: a host context for one document, which the satellite's token names.
RefPtr<LegacyExtensionHost::HostContext> LegacyExtensionHost::remoteExtensionPageContext(uint64_t satellite, uint64_t token, const String& extensionKey, const URL& documentURL)
{
    if (extensionKeyForURL(documentURL) != extensionKey)
        return nullptr;
    if (RefPtr context = m_hostContexts.get(m_hostContextByRemoteToken.get({ satellite, token }))) {
        context->url = documentURL;
        return context;
    }
    Ref context = HostContext::create();
    context->identifier = m_nextIdentifier++;
    context->extensionKey = extensionKey;
    context->url = documentURL;
    context->satellite = satellite;
    context->remoteToken = token;
    m_hostContextByRemoteToken.set({ satellite, token }, context->identifier);
    loadWebsiteAccess(context->extensionKey, context->url);
    m_hostContexts.add(context->identifier, context.copyRef());
    return context;
}

void LegacyExtensionHost::forwardTabCall(uint64_t satellite, HostContext& context, double callID, const String& method, RefPtr<JSON::Array>&& arguments)
{
    if (!LegacyExtensions::satellites().contains(satellite))
        return resultToHostContext(context, callID, method == "tabs.get"_s || method.startsWith("webNavigation."_s) ? RefPtr<JSON::Value> { JSON::Value::null() } : nullptr, method == "tabs.update"_s ? "No tab with this id."_s : String());
    auto remoteCallID = m_nextIdentifier++;
    m_remoteCalls.add(remoteCallID, RemoteCall { &context, callID, satellite });
    auto call = JSON::Object::create();
    call->setString("t"_s, "call"_s);
    call->setDouble("callId"_s, static_cast<double>(remoteCallID));
    call->setString("method"_s, method);
    call->setArray("args"_s, arguments ? arguments.releaseNonNull() : JSON::Array::create());
    LegacyExtensions::sendToSatellite(satellite, call.get());
}

void LegacyExtensionHost::receiveFromSatellite(uint64_t satellite, JSON::Object& message)
{
    auto type = message.getString("t"_s);
    auto token = integerIdentifier(message.getDouble("token"_s).value_or(0)).value_or(0);

    if (type == "post"_s) {
        auto extensionKey = message.getString("key"_s);
        auto body = message.getString("message"_s);
        if (!token || extensionKey.isEmpty() || body.isNull())
            return;
        RefPtr sender = message.getObject("sender"_s);
        m_remoteSenders.set({ satellite, token }, sender ? sender.releaseNonNull() : JSON::Object::create());
        if (message.getBoolean("extensionPage"_s).value_or(false)) {
            if (RefPtr context = remoteExtensionPageContext(satellite, token, extensionKey, URL { message.getString("url"_s) }))
                return route(Endpoint { WTF::move(context) }, extensionKey, body);
        }
        return route(Endpoint { nullptr, std::nullopt, std::nullopt, satellite, token }, extensionKey, body);
    }

    if (type == "gone"_s) {
        RefPtr tokens = message.getArray("tokens"_s);
        if (!tokens)
            return;
        HashSet<uint64_t> goneTokens;
        for (auto& value : *tokens) {
            if (auto goneToken = integerIdentifier(value->asDouble().value_or(0)))
                goneTokens.add(*goneToken);
        }
        endpointsDidGoAway([&](auto& endpoint) {
            return endpoint.satellite == satellite && goneTokens.contains(endpoint.remoteToken);
        });
        for (auto goneToken : goneTokens) {
            m_remoteSenders.remove({ satellite, goneToken });
            if (auto identifier = m_hostContextByRemoteToken.take({ satellite, goneToken })) {
                if (auto context = m_hostContexts.take(identifier))
                    hostContextDidGoAway(*context);
            }
        }
        return;
    }

    if (type == "event"_s) {
        auto name = message.getString("name"_s);
        RefPtr arguments = message.getArray("args"_s);
        if (!name.isEmpty() && arguments)
            dispatchEvent(name, arguments.releaseNonNull());
        return;
    }

    if (type == "webRequest"_s) {
        auto name = message.getString("name"_s);
        RefPtr details = message.getObject("details"_s);
        if (name.isEmpty() || !details)
            return;
        auto requestID = message.getDouble("id"_s);
        if (!requestID)
            return dispatchWebRequestDetails(name, details.releaseNonNull(), { });
        dispatchWebRequestDetails(name, details.releaseNonNull(), [satellite, requestID = *requestID](String&& response) {
            auto verdict = JSON::Object::create();
            verdict->setString("t"_s, "webRequestVerdict"_s);
            verdict->setDouble("id"_s, requestID);
            verdict->setString("response"_s, response);
            LegacyExtensions::sendToSatellite(satellite, verdict.get());
        });
        return;
    }

    if (type == "callResult"_s) {
        auto callID = integerIdentifier(message.getDouble("callId"_s).value_or(0));
        auto iterator = callID ? m_remoteCalls.find(*callID) : m_remoteCalls.end();
        if (iterator == m_remoteCalls.end() || iterator->value.satellite != satellite)
            return;
        auto call = m_remoteCalls.take(iterator);
        if (!call.caller || !m_hostContexts.contains(call.caller->identifier))
            return;
        RefPtr result = message.getValue("result"_s);
        resultToHostContext(*call.caller, call.callerCallID, WTF::move(result), message.getString("error"_s));
        return;
    }

    if (type == "endpoints"_s) {
        auto requestID = integerIdentifier(message.getDouble("requestId"_s).value_or(0));
        auto iterator = requestID ? m_remoteEndpointsRequests.find(*requestID) : m_remoteEndpointsRequests.end();
        if (iterator == m_remoteEndpointsRequests.end() || iterator->value.satellite != satellite)
            return;
        auto request = m_remoteEndpointsRequests.take(iterator);
        Vector<Endpoint> endpoints;
        if (RefPtr descriptions = message.getArray("endpoints"_s)) {
            for (auto& value : *descriptions) {
                RefPtr description = value->asObject();
                auto endpointToken = description ? integerIdentifier(description->getDouble("token"_s).value_or(0)) : std::nullopt;
                if (!endpointToken)
                    continue;
                if (RefPtr sender = description->getObject("sender"_s))
                    m_remoteSenders.set({ satellite, *endpointToken }, sender.releaseNonNull());
                if (description->getBoolean("extensionPage"_s).value_or(false)) {
                    if (RefPtr context = remoteExtensionPageContext(satellite, *endpointToken, request.extensionKey, URL { description->getString("url"_s) })) {
                        endpoints.append(Endpoint { WTF::move(context) });
                        continue;
                    }
                }
                endpoints.append(Endpoint { nullptr, std::nullopt, std::nullopt, satellite, *endpointToken });
            }
        }
        request.completionHandler(WTF::move(endpoints));
        return;
    }

    if (type == "fetch"_s) {
        URL url { message.getString("url"_s) };
        auto fetchID = message.getDouble("id"_s).value_or(0);
        if (!url.protocolIs(extensionScheme))
            return LegacyExtensions::sendToSatellite(satellite, LegacyExtensions::fetchedMessage(fetchID, std::nullopt, { }).get());
        LegacyExtensions::loadExtensionResource(url, [satellite, fetchID](std::optional<Vector<uint8_t>>&& data, String&& mimeType) {
            LegacyExtensions::sendToSatellite(satellite, LegacyExtensions::fetchedMessage(fetchID, WTF::move(data), WTF::move(mimeType)).get());
        });
        return;
    }
}

void LegacyExtensionHost::satelliteDidGoAway(uint64_t satellite)
{
    endpointsDidGoAway([&](auto& endpoint) {
        return endpoint.satellite == satellite;
    });
    m_remoteSenders.removeIf([&](auto& entry) {
        return entry.key.first == satellite;
    });
    Vector<uint64_t> contextIdentifiers;
    m_hostContextByRemoteToken.removeIf([&](auto& entry) {
        if (entry.key.first != satellite)
            return false;
        contextIdentifiers.append(entry.value);
        return true;
    });
    for (auto identifier : contextIdentifiers) {
        if (auto context = m_hostContexts.take(identifier))
            hostContextDidGoAway(*context);
    }
    Vector<RemoteEndpointsRequest> requests;
    m_remoteEndpointsRequests.removeIf([&](auto& entry) {
        if (entry.value.satellite != satellite)
            return false;
        requests.append(WTF::move(entry.value));
        return true;
    });
    for (auto& request : requests)
        request.completionHandler({ });
    Vector<RemoteCall> calls;
    m_remoteCalls.removeIf([&](auto& entry) {
        if (entry.value.satellite != satellite)
            return false;
        calls.append(WTF::move(entry.value));
        return true;
    });
    for (auto& call : calls) {
        if (call.caller && m_hostContexts.contains(call.caller->identifier))
            resultToHostContext(*call.caller, call.callerCallID, nullptr, "No tab with this id."_s);
    }
}

// A satellite.

void LegacyExtensionHost::setUsesSafariExtensions(WebProcessPool& pool)
{
    m_satellitePools.add(pool);
    LegacyExtensions::serveExtensionResources([](const URL& url, CompletionHandler<void(std::optional<Vector<uint8_t>>&&, String&&)>&& completionHandler) {
        LegacyExtensionHost::singleton().fetchFromHub(url, WTF::move(completionHandler));
    });
    WebProcessPool::registerGlobalURLSchemeAsHavingCustomProtocolHandlers(extensionScheme);
    LegacyExtensions::startSatellite([](uint64_t satelliteNumber) {
        LegacyExtensionHost::singleton().connectedToHub(satelliteNumber);
    }, [](Ref<JSON::Object>&& message) {
        LegacyExtensionHost::singleton().receiveFromHub(message.get());
    }, [] {
        LegacyExtensionHost::singleton().hubDidGoAway();
    });
}

bool LegacyExtensionHost::isSatellitePage(const WebPageProxy& page) const
{
    return m_satellitePools.contains(page.configuration().processPool());
}

void LegacyExtensionHost::connectedToHub(uint64_t satelliteNumber)
{
    m_satelliteNumber = satelliteNumber;
    for (auto identifier : tabObservers().keys()) {
        RefPtr page = WebProcessProxy::webPage(identifier);
        if (!page || page->isClosed() || !isSatellitePage(*page))
            continue;
        auto arguments = JSON::Array::create();
        arguments->pushObject(tabDescription(*page));
        dispatchTabEvent(*page, "tabs.onCreated"_s, WTF::move(arguments));
    }
}

void LegacyExtensionHost::hubDidGoAway()
{
    m_satelliteNumber = 0;
    auto noContent = JSON::Array::create();
    setHubContent(noContent.get());
    m_satelliteDocuments.clear();
    m_satelliteTokens.clear();
    auto webRequests = std::exchange(m_satelliteWebRequests, { });
    for (auto& completionHandler : webRequests.values())
        completionHandler("{}"_s);
    auto fetches = std::exchange(m_satelliteFetches, { });
    for (auto& completionHandler : fetches.values())
        completionHandler(std::nullopt, { });
    m_observedNetworkEvents = { };
    m_networkListenerOptions = { };
    m_blockingNetworkListeners = { };
    for (Ref networkProcess : NetworkProcessProxy::allNetworkProcesses())
        sendNetworkListeners(networkProcess);
}

uint64_t LegacyExtensionHost::tokenForDocument(WebCore::FrameIdentifier frameID, WebCore::ScriptExecutionContextIdentifier documentID)
{
    return m_satelliteTokens.ensure({ frameID, documentID }, [&] {
        auto token = m_nextIdentifier++;
        m_satelliteDocuments.add(token, SatelliteDocument { frameID, documentID });
        return token;
    }).iterator->value;
}

void LegacyExtensionHost::satelliteDocumentsDidGoAway(NOESCAPE const Function<bool(const SatelliteDocument&)>& isGone)
{
    if (m_satelliteDocuments.isEmpty())
        return;
    auto tokens = JSON::Array::create();
    m_satelliteDocuments.removeIf([&](auto& entry) {
        if (!isGone(entry.value))
            return false;
        m_satelliteTokens.remove({ *entry.value.frameID, *entry.value.documentID });
        tokens->pushDouble(static_cast<double>(entry.key));
        return true;
    });
    if (!tokens->length() || !m_satelliteNumber)
        return;
    auto message = JSON::Object::create();
    message->setString("t"_s, "gone"_s);
    message->setArray("tokens"_s, WTF::move(tokens));
    LegacyExtensions::sendToHub(message.get());
}

// The contexts an extension has in one of this satellite's tabs, for the hub.
void LegacyExtensionHost::satelliteEndpoints(double requestID, std::optional<double> tabID, std::optional<double> frameId, const String& extensionKey)
{
    auto reply = [requestID](Ref<JSON::Array>&& endpoints) {
        auto message = JSON::Object::create();
        message->setString("t"_s, "endpoints"_s);
        message->setDouble("requestId"_s, requestID);
        message->setArray("endpoints"_s, WTF::move(endpoints));
        LegacyExtensions::sendToHub(message.get());
    };
    RefPtr page = pageForTabID(tabID);
    RefPtr targetFrame = page && frameId ? frameForTab(*page, *frameId) : nullptr;
    if (!page || (frameId && !targetFrame))
        return reply(JSON::Array::create());
    page->getAllFrames([this, reply = WTF::move(reply), extensionKey, targetFrameID = targetFrame ? std::optional { targetFrame->frameID() } : std::nullopt](std::optional<FrameTreeNodeData>&& tree) mutable {
        auto endpoints = JSON::Array::create();
        if (tree) {
            forEachFrameInTree(*tree, -1, [&](auto& info, double) {
                if ((targetFrameID && info.frameID != *targetFrameID) || !info.documentID)
                    return;
                RefPtr frame = WebFrameProxy::webFrame(info.frameID);
                if (!frame)
                    return;
                auto url = documentURL(*frame, info.documentID);
                auto endpoint = JSON::Object::create();
                endpoint->setDouble("token"_s, static_cast<double>(tokenForDocument(info.frameID, *info.documentID)));
                endpoint->setBoolean("extensionPage"_s, extensionKeyForURL(url) == extensionKey);
                endpoint->setString("url"_s, url.string());
                endpoint->setObject("sender"_s, senderDescription(Endpoint { nullptr, info.frameID, info.documentID }));
                endpoints->pushObject(WTF::move(endpoint));
            });
        }
        reply(WTF::move(endpoints));
    });
}

void LegacyExtensionHost::receiveFromHub(JSON::Object& message)
{
    auto type = message.getString("t"_s);

    if (type == "deliver"_s) {
        auto token = integerIdentifier(message.getDouble("token"_s).value_or(0));
        auto iterator = token ? m_satelliteDocuments.find(*token) : m_satelliteDocuments.end();
        if (iterator == m_satelliteDocuments.end())
            return;
        auto document = iterator->value;
        RefPtr frame = WebFrameProxy::webFrame(*document.frameID);
        if (!frame || !frame->page())
            return;
        protect(frame->process())->send(Messages::LegacyExtensionContent::Deliver(*document.frameID, *document.documentID, message.getString("key"_s), message.getString("message"_s)), 0);
        return;
    }

    if (type == "content"_s) {
        auto value = JSON::Value::parseJSON(message.getString("content"_s));
        RefPtr content = value ? value->asArray() : nullptr;
        if (content)
            setHubContent(*content);
        return;
    }

    if (type == "listeners"_s)
        return setHubNetworkListeners(message);

    if (type == "call"_s) {
        auto callID = message.getDouble("callId"_s).value_or(0);
        performTabCall(message.getString("method"_s), message.getArray("args"_s), [callID](RefPtr<JSON::Value>&& result, String&& error) {
            if (!callID)
                return;
            auto reply = JSON::Object::create();
            reply->setString("t"_s, "callResult"_s);
            reply->setDouble("callId"_s, callID);
            if (!error.isNull())
                reply->setString("error"_s, error);
            else if (result)
                reply->setValue("result"_s, result.releaseNonNull());
            LegacyExtensions::sendToHub(reply.get());
        });
        return;
    }

    if (type == "endpoints"_s)
        return satelliteEndpoints(message.getDouble("requestId"_s).value_or(0), message.getDouble("tabId"_s), message.getDouble("frameId"_s), message.getString("key"_s));

    if (type == "webRequestVerdict"_s) {
        auto requestID = integerIdentifier(message.getDouble("id"_s).value_or(0));
        if (!requestID)
            return;
        if (auto completionHandler = m_satelliteWebRequests.take(*requestID))
            completionHandler(message.getString("response"_s));
        return;
    }

    if (type == "evict"_s) {
        WebCore::MemoryCache::singleton().evictResources();
        for (Ref pool : WebProcessPool::allProcessPools())
            pool->sendToAllProcesses(Messages::LegacyExtensionContent::EvictMemoryCache());
        return;
    }

    if (type == "fetched"_s) {
        auto fetchID = integerIdentifier(message.getDouble("id"_s).value_or(0));
        if (!fetchID)
            return;
        auto completionHandler = m_satelliteFetches.take(*fetchID);
        if (!completionHandler)
            return;
        auto data = message.getString("data"_s);
        completionHandler(data.isNull() ? std::nullopt : base64Decode(data), message.getString("mimeType"_s));
        return;
    }
}

void LegacyExtensionHost::fetchFromHub(const URL& url, CompletionHandler<void(std::optional<Vector<uint8_t>>&&, String&&)>&& completionHandler)
{
    if (!m_satelliteNumber)
        return completionHandler(std::nullopt, { });
    auto fetchID = m_nextIdentifier++;
    m_satelliteFetches.add(fetchID, WTF::move(completionHandler));
    auto message = JSON::Object::create();
    message->setString("t"_s, "fetch"_s);
    message->setDouble("id"_s, static_cast<double>(fetchID));
    message->setString("url"_s, url.string());
    LegacyExtensions::sendToHub(message.get());
}

// Safari's bundle content in each satellite page's user content controller, in a content world per extension.
// As in Safari, a change adds and removes single scripts and style sheets, which leaves an extension's world,
// and its contexts in loaded pages, alive; an extension whose content cannot change that way, in order, gets
// all of it again.
void LegacyExtensionHost::setHubContent(JSON::Array& content)
{
    struct NewItem {
        String identity;
        String extensionKey;
        Ref<JSON::Object> item;
    };
    Vector<NewItem> newItems;
    for (auto& value : content) {
        RefPtr item = value->asObject();
        if (!item)
            continue;
        auto extensionKey = extensionKeyForURL(URL { item->getString("url"_s) });
        if (extensionKey.isEmpty() || extensionKey != item->getString("key"_s))
            continue;
        newItems.append({ item->toJSONString(), WTF::move(extensionKey), item.releaseNonNull() });
    }

    HashSet<String> extensionKeys;
    for (auto& installed : m_hubContent)
        extensionKeys.add(installed.extensionKey);
    for (auto& newItem : newItems)
        extensionKeys.add(newItem.extensionKey);

    HashSet<String> newIdentities;
    for (auto& newItem : newItems)
        newIdentities.add(newItem.identity);
    HashSet<String> reinstalledExtensions;
    for (auto& extensionKey : extensionKeys) {
        Vector<String> installedIdentities;
        for (auto& installed : m_hubContent) {
            if (installed.extensionKey == extensionKey)
                installedIdentities.append(installed.identity);
        }
        // What stays keeps its order, and what is added follows it.
        Vector<String> keptInNewOrder;
        bool addedBeforeKept = false;
        bool sawAdded = false;
        for (auto& newItem : newItems) {
            if (newItem.extensionKey != extensionKey)
                continue;
            if (installedIdentities.contains(newItem.identity)) {
                addedBeforeKept |= sawAdded;
                keptInNewOrder.append(newItem.identity);
            } else
                sawAdded = true;
        }
        Vector<String> keptInInstalledOrder;
        for (auto& identity : installedIdentities) {
            if (newIdentities.contains(identity))
                keptInInstalledOrder.append(identity);
        }
        if (addedBeforeKept || keptInInstalledOrder != keptInNewOrder)
            reinstalledExtensions.add(extensionKey);
    }

    auto isKept = [&](const HubContentItem& installed) {
        return newIdentities.contains(installed.identity) && !reinstalledExtensions.contains(installed.extensionKey);
    };
    for (auto& installed : m_hubContent) {
        if (isKept(installed))
            continue;
        for (Ref controller : m_contentControllers) {
            if (installed.script)
                controller->removeUserScript(*installed.script);
            else
                controller->removeUserStyleSheet(*installed.styleSheet);
        }
    }

    auto strings = [](JSON::Object& item, const String& name) {
        Vector<String> strings;
        if (RefPtr array = item.getArray(name)) {
            for (auto& value : *array) {
                if (auto string = value->asString(); !string.isNull())
                    strings.append(WTF::move(string));
            }
        }
        return strings;
    };
    HashMap<String, HubContentItem> keptItems;
    for (auto& installed : m_hubContent) {
        if (isKept(installed))
            keptItems.add(installed.identity, installed);
    }
    Vector<HubContentItem> installedContent;
    Vector<HubContentItem> addedItems;
    for (auto& newItem : newItems) {
        if (auto kept = keptItems.take(newItem.identity); kept.script || kept.styleSheet) {
            installedContent.append(WTF::move(kept));
            continue;
        }
        Ref world = m_hubContentWorlds.ensure(newItem.extensionKey, [&] {
            return API::ContentWorld::sharedWorldWithName(makeString("safari-extension:"_s, newItem.extensionKey));
        }).iterator->value;
        auto& item = newItem.item.get();
        URL url { item.getString("url"_s) };
        auto injectedFrames = item.getBoolean("top"_s).value_or(false) ? WebCore::UserContentInjectedFrames::InjectInTopFrameOnly : WebCore::UserContentInjectedFrames::InjectInAllFrames;
        HubContentItem added { newItem.identity, newItem.extensionKey, nullptr, nullptr };
        if (item.getString("kind"_s) == "script"_s) {
            auto injectionTime = item.getBoolean("start"_s).value_or(true) ? WebCore::UserScriptInjectionTime::DocumentStart : WebCore::UserScriptInjectionTime::DocumentEnd;
            added.script = API::UserScript::create(WebCore::UserScript { item.getString("source"_s), WTF::move(url), strings(item, "allow"_s), strings(item, "block"_s), injectionTime, injectedFrames }, world);
        } else {
            auto level = item.getBoolean("author"_s).value_or(false) ? WebCore::UserStyleLevel::Author : WebCore::UserStyleLevel::User;
            added.styleSheet = API::UserStyleSheet::create(WebCore::UserStyleSheet { item.getString("source"_s), url, strings(item, "allow"_s), strings(item, "block"_s), injectedFrames, WebCore::UserContentMatchParentFrame::Never, level }, world);
        }
        addedItems.append(added);
        installedContent.append(WTF::move(added));
    }
    m_hubContent = WTF::move(installedContent);
    m_hubContentWorlds.removeIf([&](auto& entry) {
        return !m_hubContent.containsIf([&](auto& installed) {
            return installed.extensionKey == entry.key;
        });
    });

    for (Ref controller : m_contentControllers) {
        for (auto& added : addedItems)
            addContent(controller, added);
    }
}

void LegacyExtensionHost::addContent(WebUserContentControllerProxy& controller, const HubContentItem& item)
{
    if (item.script)
        controller.addUserScript(*item.script, InjectUserScriptImmediately::No);
    else
        controller.addUserStyleSheet(*item.styleSheet);
}

void LegacyExtensionHost::installContent(WebUserContentControllerProxy& controller)
{
    m_contentControllers.add(controller);
    for (auto& item : m_hubContent)
        addContent(controller, item);
}

// The hub's listeners, of which the blocking ones for this satellite's tabs and for any tab apply here.
void LegacyExtensionHost::setHubNetworkListeners(JSON::Object& message)
{
    auto strings = [&](const String& name) {
        Vector<String> strings;
        if (RefPtr array = message.getArray(name)) {
            for (auto& value : *array) {
                if (auto string = value->asString(); !string.isNull())
                    strings.append(WTF::move(string));
            }
        }
        return strings;
    };
    auto blocking = JSON::Object::create();
    auto value = JSON::Value::parseJSON(message.getString("blocking"_s));
    if (RefPtr hubBlocking = value ? value->asObject() : nullptr) {
        for (auto& [eventName, listenersValue] : *hubBlocking) {
            RefPtr listeners = listenersValue->asArray();
            if (!listeners)
                continue;
            auto applicable = JSON::Array::create();
            for (auto& listenerValue : *listeners) {
                RefPtr listener = listenerValue->asObject();
                if (!listener)
                    continue;
                if (auto tabID = listener->getDouble("tabId"_s); tabID && *tabID != -1) {
                    RefPtr page = pageForTabID(tabID);
                    if (!page)
                        continue;
                    listener->setDouble("tabId"_s, static_cast<double>(page->identifier().toUInt64()));
                }
                applicable->pushObject(listener.releaseNonNull());
            }
            if (applicable->length())
                blocking->setArray(eventName, WTF::move(applicable));
        }
    }
    m_observedNetworkEvents = strings("observed"_s);
    m_networkListenerOptions = strings("options"_s);
    m_blockingNetworkListeners = blocking->toJSONString();
    for (Ref networkProcess : NetworkProcessProxy::allNetworkProcesses())
        sendNetworkListeners(networkProcess);
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
