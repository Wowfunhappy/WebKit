#include "config.h"
#include "LegacyExtensionHost.h"
#include "MediaRestreamServer.h"

#include "LegacyExtensionClipboard.h"
#include "LegacyExtensionContentMessages.h"
#include "LegacyExtensionDNS.h"
#include "LegacyExtensionDeclarativeNetRequest.h"
#include "LegacyExtensionDevTools.h"
#include "LegacyExtensionErrors.h"
#include "LegacyExtensionHiddenTabs.h"
#include "LegacyExtensionHostMessages.h"
#include "LegacyExtensionInfoPlist.h"
#include "LegacyExtensionInput.h"
#include "LegacyExtensionInspector.h"
#include "LegacyExtensionJavaScript.h"
#include "LegacyExtensionMimeHandlers.h"
#include "LegacyExtensionPrivacy.h"
#include "LegacyExtensionProxy.h"
#include "LegacyExtensionSaveAsPDF.h"
#include "LegacyExtensionScheme.h"
#include "LegacyExtensionTabCapture.h"
#include "LegacyExtensionViewConnection.h"
#include "LegacyExtensionViewNetwork.h"
#include "LegacyExtensionNetworkMessages.h"
#include "LegacyExtensionNetworkProxyMessages.h"
#include "APIHTTPCookieStore.h"
#include "APINavigation.h"
#include "APINavigationClient.h"
#include "APIPageConfiguration.h"
#include "APIWebsitePolicies.h"
#include "FrameTreeNodeData.h"
#include "NetworkProcessProxy.h"
#include "PageLoadState.h"
#include "SharedBufferReference.h"
#include "WKAPICast.h"
#include "WKPage.h"
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
#include <WebCore/CocoaCurlProxyConfiguration.h>
#include <WebCore/ContentRuleListResults.h>
#include <WebCore/Cookie.h>
#include <WebCore/MemoryCache.h>
#include <WebCore/ResourceRequest.h>
#include <WebCore/SharedBuffer.h>
#include <WebCore/UserGestureIndicator.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/OptionSet.h>
#include <wtf/cocoa/RuntimeApplicationChecksCocoa.h>
#include <wtf/RunLoop.h>
#include <wtf/Scope.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/WallTime.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringToIntegerConversion.h>
#include <cmath>
#include <limits>

namespace WebKit {

static constexpr auto extensionScheme = "safari-extension"_s;
static constexpr auto noReceiverError = "Could not establish connection. Receiving end does not exist."_s;
// Chrome's error for the channels of a document that enters the back/forward cache (extension_message_port.cc).
static constexpr auto closedWhenPageEntersBackForwardCacheError = "The page keeping the extension port is moved into back/forward cache, so the message channel is closed."_s;

// A tab's URL: its main frame's committed URL, as Chrome's Tab.url is, or the URL an error page stands for.
static const URL& tabURL(WebPageProxy& page)
{
    auto& pageLoadState = page.pageLoadState();
    return pageLoadState.unreachableURL().isEmpty() ? pageLoadState.url() : pageLoadState.unreachableURL();
}

// A page's tabs.onUpdated source, reporting navigations as Chrome's TabsEventRouter does: a main-frame commit reports
// the tab loading, with its URL when that changed, and the tab's first stop loading after a commit reports it
// complete. A navigation that never commits, such as an HTTPS upgrade WebKit falls back from, reports nothing.
// Changes are reported together, with the tab's state at that time, after upstream's tabs.onUpdated coalescing delay
// (WebExtensionContext::didChangeTabProperties).
class LegacyExtensionTabObserver final : public PageLoadStateObserverBase, public RefCounted<LegacyExtensionTabObserver> {
public:
    static Ref<LegacyExtensionTabObserver> create(WebPageProxy& page, Function<void(WebPageProxy&, Ref<JSON::Object>&&)>&& didUpdate)
    {
        return adoptRef(*new LegacyExtensionTabObserver(page, WTF::move(didUpdate)));
    }

    void ref() const final { RefCounted::ref(); }
    void deref() const final { RefCounted::deref(); }

    void didCommitMainFrameNavigation()
    {
        m_didCommit = true;
        scheduleUpdate();
    }

    enum class Property : uint8_t {
        Hidden = 1 << 0,
        Audible = 1 << 1,
        Muted = 1 << 2,
    };
    void didChange(Property property)
    {
        m_changedProperties.add(property);
        scheduleUpdate();
    }

private:
    LegacyExtensionTabObserver(WebPageProxy& page, Function<void(WebPageProxy&, Ref<JSON::Object>&&)>&& didUpdate)
        : m_page(page)
        , m_didUpdate(WTF::move(didUpdate))
        , m_url(tabURL(page))
        , m_title(page.pageLoadState().title())
    {
    }

    void scheduleUpdate()
    {
        if (std::exchange(m_updateIsScheduled, true))
            return;
        constexpr auto updatedEventDelay = 25_ms;
        RunLoop::mainSingleton().dispatchAfter(updatedEventDelay, [protectedThis = Ref { *this }] {
            protectedThis->update();
        });
    }

    void update()
    {
        m_updateIsScheduled = false;
        RefPtr page = m_page.get();
        if (!page)
            return;
        if (std::exchange(m_didCommit, false)) {
            m_completeIsPending = true;
            auto changeInfo = JSON::Object::create();
            changeInfo->setString("status"_s, "loading"_s);
            if (auto& url = tabURL(*page); url != m_url) {
                m_url = url;
                changeInfo->setString("url"_s, url.string());
            }
            m_didUpdate(*page, WTF::move(changeInfo));
        }
        if (auto& title = page->pageLoadState().title(); !equalIgnoringNullity(title, m_title)) {
            m_title = title;
            auto changeInfo = JSON::Object::create();
            changeInfo->setString("title"_s, title);
            m_didUpdate(*page, WTF::move(changeInfo));
        }
        auto changedProperties = std::exchange(m_changedProperties, { });
        if (changedProperties.contains(Property::Hidden)) {
            auto changeInfo = JSON::Object::create();
            changeInfo->setBoolean("hidden"_s, LegacyExtensionHiddenTabs::singleton().isHidden(*page));
            m_didUpdate(*page, WTF::move(changeInfo));
        }
        if (changedProperties.contains(Property::Audible)) {
            auto changeInfo = JSON::Object::create();
            changeInfo->setBoolean("audible"_s, page->isPlayingAudio());
            m_didUpdate(*page, WTF::move(changeInfo));
        }
        if (changedProperties.contains(Property::Muted)) {
            auto mutedInfo = JSON::Object::create();
            mutedInfo->setBoolean("muted"_s, page->isAudioMuted());
            auto changeInfo = JSON::Object::create();
            changeInfo->setObject("mutedInfo"_s, WTF::move(mutedInfo));
            m_didUpdate(*page, WTF::move(changeInfo));
        }
        if (m_completeIsPending && !page->pageLoadState().isLoading()) {
            m_completeIsPending = false;
            auto changeInfo = JSON::Object::create();
            changeInfo->setString("status"_s, "complete"_s);
            m_didUpdate(*page, WTF::move(changeInfo));
        }
    }

    void willChangeIsLoading() final { }
    void didChangeIsLoading() final { scheduleUpdate(); }
    void willChangeTitle() final { }
    void didChangeTitle() final { scheduleUpdate(); }
    void willChangeActiveURL() final { }
    void didChangeActiveURL() final { }
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
    URL m_url;
    String m_title;
    OptionSet<Property> m_changedProperties;
    bool m_didCommit { false };
    bool m_completeIsPending { false };
    bool m_updateIsScheduled { false };
};

static HashMap<WebPageProxyIdentifier, Ref<LegacyExtensionTabObserver>>& tabObservers()
{
    static NeverDestroyed<HashMap<WebPageProxyIdentifier, Ref<LegacyExtensionTabObserver>>> observers;
    return observers;
}

// The active tab of the frontmost browser window: Safari 7's activeBrowserWindow.activeTab, and Firefox's
// tabTracker.activeTab.
static RefPtr<WebPageProxy> activeTabOfFrontmostWindow()
{
    Vector<Ref<WebPageProxy>> pages;
    for (auto identifier : tabObservers().keys()) {
        if (RefPtr page = WebProcessProxy::webPage(identifier))
            pages.append(page.releaseNonNull());
    }
    return LegacyExtensionDeclarativeNetRequest::activeTabOfFrontmostWindow(pages);
}

// The native object LegacyExtensionAPI.js receives in a host context.
struct HostContextNative {
    uint64_t hostContextIdentifier;
    std::optional<double> inspectedTabID;
};

static JSValueRef hostContextSend(JSContextRef context, JSObjectRef, JSObjectRef thisObject, size_t argumentCount, const JSValueRef arguments[], JSValueRef*)
{
    auto* native = static_cast<HostContextNative*>(JSObjectGetPrivate(thisObject));
    auto message = LegacyExtensions::stringArgument(context, argumentCount, arguments, 0);
    if (!message.isNull())
        LegacyExtensionHost::singleton().postFromHostContext(native->hostContextIdentifier, message, LegacyExtensions::bufferArgument(context, argumentCount, arguments, 1));
    return JSValueMakeUndefined(context);
}

// isProcessingUserGesture(): whether the caller runs inside a user gesture, which a call it makes carries on as
// upstream's API calls do.
// isValid(): whether the context is valid, as for content contexts.
static JSValueRef hostContextIsValid(JSContextRef context, JSObjectRef, JSObjectRef thisObject, size_t, const JSValueRef[], JSValueRef*)
{
    auto* native = static_cast<HostContextNative*>(JSObjectGetPrivate(thisObject));
    return JSValueMakeBoolean(context, LegacyExtensionHost::singleton().isHostContextValid(native->hostContextIdentifier));
}

static JSValueRef hostContextIsProcessingUserGesture(JSContextRef context, JSObjectRef, JSObjectRef, size_t, const JSValueRef[], JSValueRef*)
{
    return JSValueMakeBoolean(context, WebCore::UserGestureIndicator::processingUserGesture());
}

// inspectedTabId(): in a devtools page, the tab its Web Inspector inspects; elsewhere undefined.
static JSValueRef hostContextInspectedTabID(JSContextRef context, JSObjectRef, JSObjectRef thisObject, size_t, const JSValueRef[], JSValueRef*)
{
    auto* native = static_cast<HostContextNative*>(JSObjectGetPrivate(thisObject));
    if (!native || !native->inspectedTabID)
        return JSValueMakeUndefined(context);
    return JSValueMakeNumber(context, *native->inspectedTabID);
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
            { "isValid", hostContextIsValid, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontDelete },
            { "isProcessingUserGesture", hostContextIsProcessingUserGesture, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontDelete },
            { "inspectedTabId", hostContextInspectedTabID, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontDelete },
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
    if (!page || page->isClosed() || MediaRestreamServer::singleton().isDetached(*page))
        return nullptr;
    return page;
}

// A tab reference from tabReference in LegacyExtensionAPI.js: `{ tabId }`, or `{ window, index }`, its place in
// Safari's browserWindows and their tabs.
static RefPtr<WebPageProxy> pageForTabReference(const JSON::Object* reference)
{
    if (!reference)
        return nullptr;
    if (auto tabID = reference->getDouble("tabId"_s))
        return pageForTabID(tabID);
    auto isIndex = [](std::optional<double> value) {
        return value && *value >= 0 && *value <= std::numeric_limits<uint32_t>::max() && std::floor(*value) == *value;
    };
    auto window = reference->getDouble("window"_s);
    auto index = reference->getDouble("index"_s);
    if (!isIndex(window) || !isIndex(index))
        return nullptr;
    return LegacyExtensionHiddenTabs::pageOfSafariTab(static_cast<size_t>(*window), static_cast<size_t>(*index));
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

static URL extensionRoot(const URL&);

static String extensionKeyForURL(const URL& url)
{
    if (!url.protocolIs(extensionScheme))
        return { };
    return url.host().toString();
}

// Whether an extension sees a page's URL and title, as Safari 7's ExtensionAPIExtension::canAccessPageURL decides it
// for SafariBrowserTab: one of the extension's own pages, or, with any website access, a blank page or a web page
// within it.
static bool canAccessPageURL(const LegacyExtensions::WebsiteAccess& access, const String& extensionKey, const URL& url)
{
    if (extensionKeyForURL(url) == extensionKey)
        return true;
    if (access.level == LegacyExtensions::WebsiteAccess::Level::None)
        return false;
    return url.isEmpty() || url.isAboutBlank() || access.allows(url);
}

// Safari 7 keys an extension "<CFBundleIdentifier>-<developer ID>", the ID being the ten characters naming
// the Safari Developer certificate that signed it; a Web Clip's copy of an extension adds ".<clip identifier>".
struct ExtensionKeyParts {
    StringView bundleIdentifier;
    StringView safariKey;
    StringView clip;
};

static ExtensionKeyParts extensionKeyParts(StringView extensionKey)
{
    static constexpr unsigned developerIDLength = 10;
    auto separator = extensionKey.reverseFind('-');
    if (separator == notFound)
        return { extensionKey, extensionKey, { } };
    auto developerID = extensionKey.substring(separator + 1);
    if (developerID.length() < developerIDLength || (developerID.length() > developerIDLength && developerID[developerIDLength] != '.'))
        return { extensionKey, extensionKey, { } };
    for (unsigned i = 0; i < developerIDLength; ++i) {
        if (!isASCIIDigit(developerID[i]) && !isASCIIUpper(developerID[i]))
            return { extensionKey, extensionKey, { } };
    }
    auto safariKeyLength = separator + 1 + developerIDLength;
    return { extensionKey.left(separator), extensionKey.left(safariKeyLength), extensionKey.substring(safariKeyLength) };
}

// runtime.sendMessage and runtime.connect name an extension of the sender's clip by its bundle identifier or
// its key, with or without the clip identifier.
static bool extensionIdNames(const String& extensionId, const String& extensionKey, const String& senderExtensionKey)
{
    auto parts = extensionKeyParts(extensionKey);
    if (parts.clip != extensionKeyParts(senderExtensionKey).clip)
        return false;
    return extensionId == extensionKey || extensionId == parts.safariKey || extensionId == parts.bundleIdentifier;
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
    if (WTF::MacApplication::isSafari())
        LegacyExtensionViewConnection::singleton().install();
    WebSetLegacyExtensionPageObserver(&pageObserver());
    WebCore::LegacyLoadInterceptor::setSingleton(&LegacyExtensionViewNetwork::singleton());
    // privacy's onChange, with each extension's view of the setting.
    LegacyExtensionPrivacy::singleton().setChangeObserver([this](const String& name) {
        auto eventName = makeString("privacy."_s, name, ".onChange"_s);
        for (auto& context : copyToVector(m_hostContexts.values())) {
            if (!context->interests.contains(eventName))
                continue;
            auto arguments = JSON::Array::create();
            arguments->pushObject(LegacyExtensionPrivacy::singleton().details(context->extensionKey, name));
            auto event = JSON::Object::create();
            event->setString("t"_s, "event"_s);
            event->setString("name"_s, eventName);
            event->setArray("args"_s, WTF::move(arguments));
            deliver(Endpoint { context.ptr(), std::nullopt }, context->extensionKey, event->toJSONString());
        }
    });
    // proxy.settings' onChange, with each extension's view of the setting.
    LegacyExtensionProxy::singleton().setChangeObserver([this] {
        for (auto& context : copyToVector(m_hostContexts.values())) {
            if (!context->interests.contains("proxy.settings.onChange"_s))
                continue;
            auto arguments = JSON::Array::create();
            arguments->pushObject(LegacyExtensionProxy::singleton().details(context->extensionKey));
            auto event = JSON::Object::create();
            event->setString("t"_s, "event"_s);
            event->setString("name"_s, "proxy.settings.onChange"_s);
            event->setArray("args"_s, WTF::move(arguments));
            deliver(Endpoint { context.ptr(), std::nullopt }, context->extensionKey, event->toJSONString());
        }
    });
    // The proxy errors of this process's own loads.
    WebCore::CocoaCurlProxyConfiguration::setErrorObserver([this](bool fatal, const String& error, const String& details) {
        auto event = JSON::Object::create();
        event->setBoolean("fatal"_s, fatal);
        event->setString("error"_s, error);
        event->setString("details"_s, details);
        dispatchProxyError(event->toJSONString());
    });
}

void LegacyExtensionHost::webProcessCreated(WebProcessProxy& process)
{
    process.addMessageReceiver(Messages::LegacyExtensionHost::messageReceiverName(), *this);
}

void LegacyExtensionHost::webProcessDidInitialize(WebProcessProxy& process)
{
    LegacyExtensionMimeHandlers::singleton().sendHandlers(process);
}

// An extension whose content scripts or style sheets a web process holds is loaded: Safari adds them to every
// web process while it has the extension enabled, under the root the extension's files are served at, and
// withdraws them when it disables or reloads the extension.
void LegacyExtensionHost::setUserContentExtensionRoots(IPC::Connection& connection, Vector<String>&& rootStrings)
{
    Vector<URL> roots;
    for (auto& rootString : rootStrings) {
        URL root { rootString };
        if (extensionRoot(root) == root)
            roots.append(WTF::move(root));
    }
    auto processIdentifier = WebProcessProxy::fromConnection(connection)->coreProcessIdentifier();
    if (roots.isEmpty())
        m_userContentExtensionRoots.remove(processIdentifier);
    else
        m_userContentExtensionRoots.set(processIdentifier, roots);
    updateUserContentExtensions(roots);
}

void LegacyExtensionHost::webProcessWillShutDown(WebProcessProxy& process)
{
    LegacyExtensionInspector::singleton().webProcessWillShutDown(process);
    if (m_userContentExtensionRoots.remove(process.coreProcessIdentifier()))
        updateUserContentExtensions();
}

// Each extension's root is the one it is loaded from while a process still reports it, as while Safari moves
// a reloaded extension's content to its new root, and otherwise the one a process reported last; a reported
// root the extension was moved from counts toward its presence but does not become its root again.
void LegacyExtensionHost::updateUserContentExtensions(const Vector<URL>& latestRoots)
{
    HashMap<String, URL> extensions;
    for (auto& roots : m_userContentExtensionRoots.values()) {
        for (auto& root : roots)
            extensions.add(extensionKeyForURL(root), root);
    }
    for (auto& root : latestRoots)
        extensions.set(extensionKeyForURL(root), root);
    for (auto& [extensionKey, root] : extensions) {
        auto loadedRoot = m_websiteAccessRoots.get(extensionKey);
        bool loadedRootIsReported = std::ranges::any_of(m_userContentExtensionRoots.values(), [&](auto& roots) {
            return roots.contains(loadedRoot);
        });
        if (loadedRootIsReported)
            root = loadedRoot;
    }
    auto previous = std::exchange(m_userContentExtensions, extensions);
    for (auto& [extensionKey, root] : extensions) {
        m_extensionsPresentInSafari.add(extensionKey);
        loadWebsiteAccess(extensionKey, root);
    }
    for (auto& extensionKey : previous.keys()) {
        if (!m_userContentExtensions.contains(extensionKey))
            unloadExtensionIfUnused(extensionKey);
    }
}

void LegacyExtensionHost::networkProcessCreated(NetworkProcessProxy& networkProcess)
{
    networkProcess.addMessageReceiver(Messages::LegacyExtensionNetworkProxy::messageReceiverName(), m_networkProxy);
    sendNetworkListeners(networkProcess);
    LegacyExtensionPrivacy::singleton().sendSettings(networkProcess);
    LegacyExtensionProxy::singleton().sendSettings(networkProcess);
}

// The StreamFilters of a network process's loads fail with it.
void LegacyExtensionHost::networkProcessDidTerminate(NetworkProcessProxy& networkProcess)
{
    Vector<uint64_t> filterIDs;
    for (auto& [filterID, filter] : m_responseFilters) {
        if (filter.networkProcess.get() == &networkProcess)
            filterIDs.append(filterID);
    }
    for (auto filterID : filterIDs)
        dispatchResponseFilterEvent(filterID, "error"_s, nullptr, "The network process terminated."_s);
}

// Host contexts.

void LegacyExtensionHost::didClearWindowObject(const void* frame, JSC::JSGlobalObject& globalObject, const URL& documentURL)
{
    String previousExtensionKey;
    if (auto identifier = m_hostContextByFrame.take(frame)) {
        if (auto context = m_hostContexts.take(identifier)) {
            if (!context->devToolsTabID)
                previousExtensionKey = context->extensionKey;
            hostContextDidGoAway(*context, ContextIsReplaced::Yes);
        }
    }
    // A reloaded page's extension stays loaded.
    auto unloadPreviousExtensionIfUnused = makeScopeExit([&] {
        if (!previousExtensionKey.isNull())
            unloadExtensionIfUnused(previousExtensionKey);
    });

    auto extensionKey = extensionKeyForURL(documentURL);
    if (extensionKey.isEmpty())
        return;

    Ref context = HostContext::create();
    context->identifier = m_nextIdentifier++;
    context->frame = frame;
    context->extensionKey = extensionKey;
    context->url = documentURL;
    context->globalObject = JSC::Weak<JSC::JSGlobalObject>(&globalObject);
    context->devToolsTabID = LegacyExtensionDevTools::singleton().inspectedTabForFrame(frame, extensionKey);

    if (!LegacyExtensions::installAPI(globalObject, LegacyExtensions::ContextKind::Host, hostContextNativeClass(), new HostContextNative { context->identifier, context->devToolsTabID }))
        return;

    m_hostContextByFrame.add(frame, context->identifier);
    if (!context->devToolsTabID)
        m_extensionsPresentInSafari.add(extensionKey);
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

void LegacyExtensionHost::postFromHostContext(uint64_t hostContextIdentifier, const String& message, RefPtr<WebCore::SharedBuffer>&& data)
{
    RefPtr context = m_hostContexts.get(hostContextIdentifier);
    if (!context)
        return;
    route(Endpoint { context, std::nullopt }, context->extensionKey, message, WTF::move(data));
}

void LegacyExtensionHost::hostContextDidGoAway(HostContext& context, ContextIsReplaced isReplaced)
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

    // A filter whose context is gone passes the rest of the body through, as a disconnected one does.
    Vector<uint64_t> filterIDs;
    for (auto& [filterID, filter] : m_responseFilters) {
        if (filter.hostContextIdentifier == context.identifier)
            filterIDs.append(filterID);
    }
    for (auto filterID : filterIDs) {
        if (RefPtr networkProcess = m_responseFilters.get(filterID).networkProcess.get())
            networkProcess->send(Messages::LegacyExtensionNetwork::DisconnectResponseFilter(filterID, m_responseFilters.get(filterID).dispatched), 0);
        removeResponseFilter(filterID);
    }

    if (hadNetworkInterests)
        updateNetworkListeners();
    if (!m_cookieObservers.isEmpty())
        updateCookieObservers();
    if (isReplaced == ContextIsReplaced::No && !context.devToolsTabID)
        unloadExtensionIfUnused(context.extensionKey);
}

// An extension is loaded while Safari presents it: while it has the global page, bars and popovers Safari keeps
// while the extension is enabled, or a web process holds its user content. Its pages in tabs and its devtools
// pages do not keep it loaded; its devtools pages live only while it is loaded.
bool LegacyExtensionHost::isRetiredRoot(const String& extensionKey, const URL& root) const
{
    auto iterator = m_retiredRoots.find(extensionKey);
    return iterator != m_retiredRoots.end() && iterator->value.contains(root.string());
}

bool LegacyExtensionHost::isPresentInSafari(const String& extensionKey) const
{
    if (m_userContentExtensions.contains(extensionKey))
        return true;
    return std::ranges::any_of(m_hostContexts.values(), [&](auto& context) {
        return context->extensionKey == extensionKey && !context->frameID && !context->devToolsTabID;
    });
}

void LegacyExtensionHost::unloadExtensionIfUnused(const String& extensionKey)
{
    if (isPresentInSafari(extensionKey))
        return;
    // Safari disabled or reloaded the extension, and keeps any of its pages that tabs show: those belong to an
    // extension that is gone.
    if (m_extensionsPresentInSafari.remove(extensionKey))
        invalidateExtensionPages(extensionKey);
    extensionDidUnload(extensionKey);
}

void LegacyExtensionHost::invalidateExtensionPages(const String& extensionKey, const URL& root)
{
    for (auto& context : copyToVector(m_hostContexts.values())) {
        if (context->extensionKey == extensionKey && context->frameID && (root.isNull() || extensionRoot(context->url) != root))
            invalidateExtensionPage(context);
    }
}

// The context ends its ports, messages, webRequest verdicts and StreamFilters as a context that goes away does,
// and stays to drop what its page sends.
void LegacyExtensionHost::invalidateExtensionPage(HostContext& context)
{
    if (context.isInvalidated || !context.frameID || !context.documentID)
        return;
    context.isInvalidated = true;
    if (RefPtr frame = WebFrameProxy::webFrame(*context.frameID))
        protect(frame->process())->send(Messages::LegacyExtensionContent::InvalidateExtensionPage(*context.frameID, *context.documentID), 0);
    hostContextDidGoAway(context, ContextIsReplaced::Yes);
}

// Content contexts.

void LegacyExtensionHost::beginMediaPlayerHandoff(IPC::Connection& connection, WebCore::FrameIdentifier frameID, uint64_t request, uint64_t parent, String&& ticket, String&& extensionKey, CompletionHandler<void(Expected<bool, String>&&)>&& completion)
{
    RefPtr frame = WebFrameProxy::webFrame(frameID);
    if (!frame || !frame->page() || !protect(frame->process())->hasConnection(connection))
        return completion(makeUnexpected("no-source"_s));
    auto& server = MediaRestreamServer::singleton();
    if (!ticket.isNull()) {
        if (parent || !server.claimHandoff(*frame->page(), frame->process(), ticket, extensionKey, request))
            return completion(makeUnexpected("no-source"_s));
        return completion(true);
    }
    if (parent ? !server.hasHandoff(*frame->page(), connection, parent) : server.isDetached(*frame->page()))
        return completion(makeUnexpected("no-source"_s));
    if (!MediaRestreamServer::singleton().beginHandoff(*frame->page(), frame->process(), request))
        return completion(makeUnexpected("no-source"_s));
    completion(true);
}

void LegacyExtensionHost::activateMediaPlayer(IPC::Connection& connection, uint64_t identifier, CompletionHandler<void(Expected<bool, String>&&)>&& completion)
{
    MediaRestreamServer::singleton().activate(connection, identifier, WTF::move(completion));
}

void LegacyExtensionHost::controlMediaPlayer(IPC::Connection& connection, uint64_t identifier, String&& command, double value, CompletionHandler<void(bool)>&& completion)
{
    MediaRestreamServer::singleton().control(connection, identifier, command, value, WTF::move(completion));
}

void LegacyExtensionHost::endMediaPlayerHandoff(IPC::Connection& connection, uint64_t request)
{
    MediaRestreamServer::singleton().endHandoff(connection, request);
}

void LegacyExtensionHost::publishMediaSource(IPC::Connection& connection, WebCore::FrameIdentifier frameID, WebCore::ScriptExecutionContextIdentifier documentID, URL&& documentURL, String&& extensionKey, uint64_t request, uint64_t identifier, URL&& url, String&& playlist, String&& title, String&& codec, CompletionHandler<void(Expected<URL, String>&&)>&& completion)
{
    RefPtr frame = WebFrameProxy::webFrame(frameID);
    if (!frame || !frame->page() || !protect(frame->process())->hasConnection(connection) || extensionKey.isEmpty() || !MediaRestreamServer::singleton().hasHandoff(*frame->page(), connection, request))
        return completion(makeUnexpected("no-source"_s));
    if ((!url.isEmpty() && !url.protocolIsInHTTPFamily()) || playlist.length() > 1024 * 1024 || (!playlist.isEmpty() && (url.isEmpty() || !playlist.startsWith("#EXTM3U"_s))))
        return completion(makeUnexpected("unsupported-source"_s));
    m_documents.set(documentID, std::pair { frameID, documentURL });
    MediaRestreamServer::singleton().publish(*frame->page(), frame->process(), identifier, url, playlist, title, codec, WTF::move(completion));
}

void LegacyExtensionHost::openPublishedMedia(IPC::Connection& connection, uint64_t identifier, String&& application, String&& adapter, double timeout, CompletionHandler<void(Expected<URL, String>&&)>&& completion)
{
    MediaRestreamServer::singleton().open(connection, identifier, application, adapter, timeout, WTF::move(completion));
}

void LegacyExtensionHost::mediaPlayerState(IPC::Connection& connection, uint64_t identifier, CompletionHandler<void(Expected<String, String>&&)>&& completion)
{
    MediaRestreamServer::singleton().state(connection, identifier, WTF::move(completion));
}

void LegacyExtensionHost::setMediaResource(IPC::Connection& connection, uint64_t identifier, String&& name, String&& type, std::optional<IPC::SharedBufferReference>&& bytes, CompletionHandler<void(Expected<URL, String>&&)>&& completion)
{
    if (bytes && bytes->span().size() > 64 * 1024 * 1024)
        return completion(makeUnexpected("resource-quota-exceeded"_s));
    RefPtr<WebCore::SharedBuffer> data;
    if (bytes)
        data = WebCore::SharedBuffer::create(bytes->span());
    MediaRestreamServer::singleton().setResource(connection, identifier, name, type, WTF::move(data), WTF::move(completion));
}

void LegacyExtensionHost::setMediaPlaylistProvider(IPC::Connection& connection, uint64_t identifier, bool enabled, CompletionHandler<void(bool)>&& completion)
{
    completion(MediaRestreamServer::singleton().setPlaylistProvider(connection, identifier, enabled));
}

void LegacyExtensionHost::endRestream(IPC::Connection& connection, uint64_t identifier)
{
    MediaRestreamServer::singleton().end(connection, identifier);
}

void LegacyExtensionHost::completeRestream(IPC::Connection& connection, uint64_t identifier)
{
    MediaRestreamServer::singleton().complete(connection, identifier);
}

void LegacyExtensionHost::post(IPC::Connection& connection, WebCore::FrameIdentifier frameID, WebCore::ScriptExecutionContextIdentifier documentID, URL&& documentURL, String&& extensionKey, String&& message, IPC::SharedBufferReference&& data)
{
    RefPtr frame = WebFrameProxy::webFrame(frameID);
    if (!frame || !frame->page())
        return;
    if (!protect(frame->process())->hasConnection(connection))
        return;
    if (MediaRestreamServer::singleton().isDetached(*frame->page())) {
        auto value = JSON::Value::parseJSON(message);
        RefPtr object = value ? value->asObject() : nullptr;
        if (!object)
            return;
        auto portID = object->getString("portId"_s);
        auto iterator = m_ports.find(portID);
        if (iterator == m_ports.end())
            return;
        Endpoint endpoint { nullptr, frameID, documentID, extensionKey };
        if (auto identifier = m_hostContextByRemoteFrame.get(frameID)) {
            if (RefPtr context = m_hostContexts.get(identifier); context && context->documentID == documentID && context->extensionKey == extensionKey)
                endpoint = Endpoint { context, std::nullopt, std::nullopt };
        }
        auto type = object->getString("t"_s);
        if (type == "post"_s)
            routePost(endpoint, message, portID);
        else if (type == "disconnect"_s)
            routeDisconnect(endpoint, portID);
        return;
    }
    m_documents.set(documentID, std::pair { frameID, documentURL });
    if (RefPtr context = extensionPageContext(*frame, documentID, documentURL, extensionKey)) {
        route(Endpoint { context, std::nullopt, std::nullopt }, extensionKey, message, data.unsafeBuffer());
        return;
    }
    route(Endpoint { nullptr, frameID, documentID, extensionKey }, extensionKey, message);
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
            hostContextDidGoAway(*context, ContextIsReplaced::Yes);
        }
    }
    Ref context = HostContext::create();
    context->identifier = m_nextIdentifier++;
    context->extensionKey = extensionKey;
    context->url = documentURL;
    context->frameID = frame.frameID();
    context->documentID = documentID;
    m_hostContextByRemoteFrame.set(frame.frameID(), context->identifier);
    m_hostContexts.add(context->identifier, context.copyRef());
    // A page of a copy of the extension Safari replaced. A page of an extension Safari does not present yet, as a
    // tab Safari restores before it loads its extensions, stays valid until Safari presents the extension.
    auto pageRoot = extensionRoot(documentURL);
    auto currentRoot = m_websiteAccessRoots.get(extensionKey);
    if (isRetiredRoot(extensionKey, pageRoot) || (m_extensionsPresentInSafari.contains(extensionKey) && currentRoot.isValid() && pageRoot != currentRoot))
        invalidateExtensionPage(context);
    else if (!currentRoot.isValid())
        loadWebsiteAccess(context->extensionKey, context->url);
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

bool LegacyExtensionHost::isEnteringBackForwardCache(const Endpoint& endpoint) const
{
    auto documentID = endpoint.host ? endpoint.host->documentID : endpoint.documentID;
    return documentID && m_documentsEnteringBackForwardCache.contains(*documentID);
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
    m_documentsEnteringBackForwardCache.removeIf([&](auto& entry) {
        return frameIDs.contains(entry.value);
    });
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
    // As Chrome closes the channels of a document that enters the back/forward cache, the other ends learn
    // why, and the document itself is told nothing; the ends of a destroyed document go away with no error.
    for (auto& [portID, endpoint] : portEnds)
        routeDisconnect(endpoint, portID, isEnteringBackForwardCache(endpoint) ? String { closedWhenPageEntersBackForwardCacheError } : String { });

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
        bool isCached = isEnteringBackForwardCache(endpoint);
        // The channel closes, with Chrome's error, when its last pending receiver enters the cache unanswered.
        auto reply = JSON::Object::create();
        reply->setString("msgId"_s, messageID);
        if (isCached && !message.answered && message.pendingReceivers.size() == 1)
            reply->setString("error"_s, closedWhenPageEntersBackForwardCacheError);
        else
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

void LegacyExtensionHost::route(const Endpoint& from, const String& extensionKey, const String& message, RefPtr<WebCore::SharedBuffer>&& data)
{
    if (from.host && from.host->isInvalidated)
        return;
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

    // A document with extension contexts entering the back/forward cache, ahead of its frame's commit of
    // another document.
    if (type == "cached"_s) {
        auto documentID = from.host ? from.host->documentID : from.documentID;
        auto frameID = from.host ? from.host->frameID : from.frameID;
        if (documentID && frameID)
            m_documentsEnteringBackForwardCache.set(*documentID, *frameID);
        return;
    }

    // A content-script context whose world was withdrawn.
    if (type == "gone"_s) {
        if (!from.host)
            endpointDidGoAway(from);
        return;
    }

    if (!from.host)
        return;
    if (type == "respond"_s)
        return routeWebRequestResponse(*from.host, *object);
    if (type == "interest"_s)
        return routeInterest(*from.host, *object);
    if (type == "call"_s)
        return performCall(*from.host, *object);
    if (type == "filter"_s)
        return routeResponseFilter(*from.host, *object, WTF::move(data));
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

// Two installed extensions can share a bundle identifier, which names each of them, while an extension's key
// names it alone. An ID that names the sender's own extension is an internal message, as in Chrome, which
// never comes here: another extension with the sender's bundle identifier receives nothing.
Vector<LegacyExtensionHost::Endpoint> LegacyExtensionHost::externalHostContextsListeningTo(const String& extensionId, const String& senderExtensionKey, const String& eventName) const
{
    Vector<Endpoint> endpoints;
    for (auto& context : m_hostContexts.values()) {
        if (!extensionIdNames(extensionId, context->extensionKey, senderExtensionKey))
            continue;
        if (context->interests.contains(eventName))
            endpoints.append(Endpoint { context.copyRef(), std::nullopt });
    }
    return endpoints;
}

const String& LegacyExtensionHost::extensionKeyOf(const Endpoint& endpoint)
{
    return endpoint.host ? endpoint.host->extensionKey : endpoint.extensionKey;
}

static void forEachFrameInTree(const FrameTreeNodeData& node, double parentFrameId, NOESCAPE const Function<void(const FrameInfoData&, double parentFrameId)>& function)
{
    function(node.info, parentFrameId);
    double frameId = node.info.isMainFrame ? 0 : static_cast<double>(node.info.frameID.toUInt64());
    for (auto& child : node.children)
        forEachFrameInTree(child, frameId, function);
}

void LegacyExtensionHost::tabFrames(WebPageProxy& page, std::optional<double> frameId, CompletionHandler<void(Vector<FrameInfoData>&&)>&& completionHandler)
{
    RefPtr targetFrame = frameId ? frameForTab(page, *frameId) : nullptr;
    if (frameId && !targetFrame)
        return completionHandler({ });
    page.getAllFrames([targetFrameID = targetFrame ? std::optional { targetFrame->frameID() } : std::nullopt, completionHandler = WTF::move(completionHandler)](std::optional<FrameTreeNodeData>&& tree) mutable {
        Vector<FrameInfoData> frames;
        if (tree) {
            forEachFrameInTree(*tree, -1, [&](auto& info, double) {
                if (!targetFrameID || info.frameID == *targetFrameID)
                    frames.append(info);
            });
        }
        completionHandler(WTF::move(frames));
    });
}

std::optional<LegacyExtensionHost::Endpoint> LegacyExtensionHost::tabFrameEndpoint(const FrameInfoData& info, const String& extensionKey)
{
    RefPtr frame = WebFrameProxy::webFrame(info.frameID);
    if (!frame)
        return std::nullopt;
    if (RefPtr context = extensionPageContext(*frame, info.documentID, documentURL(*frame, info.documentID), extensionKey)) {
        if (context->isInvalidated)
            return std::nullopt;
        return Endpoint { WTF::move(context), std::nullopt, std::nullopt };
    }
    return Endpoint { nullptr, frame->frameID(), info.documentID, extensionKey };
}

void LegacyExtensionHost::tabEndpoints(WebPageProxy& page, std::optional<double> frameId, const String& extensionKey, CompletionHandler<void(Vector<Endpoint>&&)>&& completionHandler)
{
    tabFrames(page, frameId, [this, extensionKey, completionHandler = WTF::move(completionHandler)](Vector<FrameInfoData>&& frames) mutable {
        Vector<Endpoint> endpoints;
        for (auto& info : frames) {
            if (auto endpoint = tabFrameEndpoint(info, extensionKey))
                endpoints.append(WTF::move(*endpoint));
        }
        completionHandler(WTF::move(endpoints));
    });
}

void LegacyExtensionHost::deliver(const Endpoint& endpoint, const String& extensionKey, const String& message, RefPtr<WebCore::SharedBuffer>&& data, bool existingPort)
{
    withWebsiteAccess(extensionKeyOf(endpoint), [this, endpoint, extensionKey, message, data = WTF::move(data), existingPort](const LegacyExtensions::WebsiteAccess&) mutable {
        deliverNow(endpoint, extensionKey, message, WTF::move(data), existingPort);
    });
}

bool LegacyExtensionHost::deliverNow(const Endpoint& endpoint, const String& extensionKey, const String& message, RefPtr<WebCore::SharedBuffer>&& data, bool existingPort)
{
    ASSERT(!m_websiteAccessWaiters.contains(extensionKeyOf(endpoint)));
    Markable<WebCore::FrameIdentifier> frameID = endpoint.frameID;
    Markable<WebCore::ScriptExecutionContextIdentifier> documentID = endpoint.documentID;
    if (RefPtr context = endpoint.host) {
        if (!m_hostContexts.contains(context->identifier) || context->isInvalidated)
            return false;
        if (!context->frameID) {
            auto* globalObject = context->globalObject.get();
            if (!globalObject)
                return false;
            return LegacyExtensions::deliver(*globalObject, message, WTF::move(data));
        }
        frameID = context->frameID;
        documentID = context->documentID;
    }
    RefPtr frame = WebFrameProxy::webFrame(frameID);
    if (!frame || !frame->page() || (!existingPort && MediaRestreamServer::singleton().isDetached(*frame->page())))
        return false;
    protect(frame->process())->send(Messages::LegacyExtensionContent::Deliver(*frameID, documentID ? std::optional { *documentID } : std::nullopt, extensionKey, message, IPC::SharedBufferReference { WTF::move(data) }), 0);
    return true;
}

// The receiving extension's access decides how the sender's tab appears, as Chrome's MessageService scrubs it for
// the receiver.
LegacyExtensionHost::SenderDescription LegacyExtensionHost::senderDescription(const Endpoint& endpoint) const
{
    auto sender = JSON::Object::create();
    sender->setString("id"_s, extensionKeyParts(extensionKeyOf(endpoint)).safariKey.toString());
    Markable<WebCore::FrameIdentifier> frameID = endpoint.frameID;
    if (RefPtr context = endpoint.host) {
        if (!context->frameID) {
            sender->setString("url"_s, context->url.string());
            return { sender.copyRef(), WTF::move(sender), { } };
        }
        frameID = context->frameID;
    }
    RefPtr frame = WebFrameProxy::webFrame(frameID);
    if (!frame)
        return { sender.copyRef(), WTF::move(sender), { } };
    sender->setDouble("frameId"_s, frameIDForFrame(*frame));
    sender->setString("url"_s, documentURL(*frame, endpoint.documentID).string());
    RefPtr page = frame->page();
    if (!page)
        return { sender.copyRef(), WTF::move(sender), { } };
    auto hidden = JSON::Object::create();
    for (auto& [name, value] : sender.get())
        hidden->setValue(name, value.copyRef());
    sender->setObject("tab"_s, tabDescription(*page, true));
    hidden->setObject("tab"_s, tabDescription(*page, false));
    return { WTF::move(sender), WTF::move(hidden), tabURL(*page) };
}

void LegacyExtensionHost::deliverSeeingPage(const Endpoint& endpoint, const URL& pageURL, const String& visibleMessage, const String& hiddenMessage)
{
    auto extensionKey = extensionKeyOf(endpoint);
    withWebsiteAccess(extensionKey, [this, endpoint, extensionKey, pageURL, visibleMessage, hiddenMessage](const LegacyExtensions::WebsiteAccess& access) {
        auto& message = canAccessPageURL(access, extensionKey, pageURL) ? visibleMessage : hiddenMessage;
        if (!message.isNull())
            deliver(endpoint, extensionKey, message);
    });
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
    // An extension ID other than the sender's own reaches runtime.onConnectExternal.
    auto extensionId = message.getString("extensionId"_s);
    bool isExternal = !extensionId.isEmpty() && !extensionIdNames(extensionId, extensionKey, extensionKey);
    if (isExternal)
        connect->setBoolean("external"_s, true);
    auto sender = senderDescription(from);
    connect->setObject("sender"_s, WTF::move(sender.visible));
    auto visibleConnectMessage = connect->toJSONString();
    connect->setObject("sender"_s, WTF::move(sender.hidden));
    auto hiddenConnectMessage = connect->toJSONString();

    // Until its receivers are known, a port keeps what its opener posts.
    m_ports.add(portID, Port { from, { }, true, { } });
    auto didFindReceivers = [this, portID, pageURL = WTF::move(sender.pageURL), visibleConnectMessage = WTF::move(visibleConnectMessage), hiddenConnectMessage = WTF::move(hiddenConnectMessage)](Vector<Endpoint>&& receivers) {
        auto iterator = m_ports.find(portID);
        if (iterator == m_ports.end())
            return;
        auto& port = iterator->value;
        auto opener = port.opener;
        if (receivers.isEmpty()) {
            m_ports.remove(iterator);
            auto disconnect = JSON::Object::create();
            disconnect->setString("t"_s, "disconnect"_s);
            disconnect->setString("portId"_s, portID);
            disconnect->setString("error"_s, noReceiverError);
            deliver(opener, extensionKeyOf(opener), disconnect->toJSONString());
            return;
        }
        port.receivers = receivers;
        port.isResolving = false;
        auto queuedMessages = std::exchange(port.queuedMessages, { });
        for (auto& receiver : receivers)
            deliverSeeingPage(receiver, pageURL, visibleConnectMessage, hiddenConnectMessage);
        for (auto& queuedMessage : queuedMessages) {
            for (auto& receiver : receivers)
                deliver(receiver, extensionKeyOf(receiver), queuedMessage);
        }
    };

    if (isExternal)
        return didFindReceivers(externalHostContextsListeningTo(extensionId, extensionKey, "runtime.onConnectExternal"_s));
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
            deliver(receiver, extensionKeyOf(receiver), message, nullptr, true);
        return;
    }
    if (port.receivers.contains(from))
        deliver(port.opener, extensionKeyOf(port.opener), message, nullptr, true);
}

void LegacyExtensionHost::routeDisconnect(const Endpoint& from, const String& portID, const String& error)
{
    auto iterator = m_ports.find(portID);
    if (iterator == m_ports.end())
        return;

    auto disconnect = JSON::Object::create();
    disconnect->setString("t"_s, "disconnect"_s);
    disconnect->setString("portId"_s, portID);
    if (!error.isNull())
        disconnect->setString("error"_s, error);
    auto disconnectMessage = disconnect->toJSONString();

    auto& port = iterator->value;
    if (port.opener == from) {
        auto receivers = std::exchange(port.receivers, { });
        m_ports.remove(iterator);
        for (auto& receiver : receivers)
            deliver(receiver, extensionKeyOf(receiver), disconnectMessage, nullptr, true);
        return;
    }
    if (!port.receivers.removeAll(from) || !port.receivers.isEmpty())
        return;
    auto opener = port.opener;
    m_ports.remove(iterator);
    deliver(opener, extensionKeyOf(opener), disconnectMessage, nullptr, true);
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
    // An extension ID other than the sender's own reaches runtime.onMessageExternal.
    auto extensionId = message.getString("extensionId"_s);
    bool isExternal = !extensionId.isEmpty() && !extensionIdNames(extensionId, extensionKey, extensionKey);
    if (isExternal)
        forwarded->setBoolean("external"_s, true);
    auto sender = senderDescription(from);
    forwarded->setObject("sender"_s, WTF::move(sender.visible));
    auto visibleMessage = forwarded->toJSONString();
    forwarded->setObject("sender"_s, WTF::move(sender.hidden));
    auto hiddenMessage = forwarded->toJSONString();

    auto didFindReceivers = [this, from, messageID, pageURL = WTF::move(sender.pageURL), visibleMessage = WTF::move(visibleMessage), hiddenMessage = WTF::move(hiddenMessage)](Vector<Endpoint>&& receivers) {
        if (receivers.isEmpty()) {
            auto reply = JSON::Object::create();
            reply->setString("t"_s, "reply"_s);
            reply->setString("msgId"_s, messageID);
            reply->setString("error"_s, noReceiverError);
            deliver(from, extensionKeyOf(from), reply->toJSONString());
            return;
        }
        if (!m_oneShotMessages.add(messageID, OneShotMessage { from, receivers, false }).isNewEntry)
            return;
        for (auto& receiver : receivers)
            deliverSeeingPage(receiver, pageURL, visibleMessage, hiddenMessage);
    };

    if (isExternal)
        return didFindReceivers(externalHostContextsListeningTo(extensionId, extensionKey, "runtime.onMessageExternal"_s));
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
    if (finished)
        m_oneShotMessages.remove(iterator);

    // Delivery can run the sender's JavaScript, and through it this router, before it returns.
    if (answers)
        deliver(sender, extensionKeyOf(sender), answer->toJSONString());
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

void LegacyExtensionHost::resultWithTab(HostContext& context, double callID, WebPageProxy& page)
{
    withWebsiteAccess(context.extensionKey, [this, context = Ref { context }, callID, pageURL = tabURL(page), visible = tabDescription(page, true), hidden = tabDescription(page, false)](const LegacyExtensions::WebsiteAccess& access) mutable {
        if (!m_hostContexts.contains(context->identifier))
            return;
        Ref tab = canAccessPageURL(access, context->extensionKey, pageURL) ? WTF::move(visible) : WTF::move(hidden);
        resultToHostContext(context, callID, RefPtr<JSON::Value> { WTF::move(tab) });
    });
}

// The tab's URL and title only when the extension sees them, as upstream's WebExtensionTab::parameters gives them.
Ref<JSON::Object> LegacyExtensionHost::tabDescription(WebPageProxy& page, bool seesPage) const
{
    auto tab = JSON::Object::create();
    tab->setDouble("id"_s, tabIDForPage(page));
    if (seesPage) {
        tab->setString("url"_s, tabURL(page).string());
        tab->setString("title"_s, page.pageLoadState().title());
    }
    tab->setString("status"_s, page.pageLoadState().isLoading() ? "loading"_s : "complete"_s);
    tab->setBoolean("incognito"_s, page.sessionID().isEphemeral());
    tab->setBoolean("hidden"_s, LegacyExtensionHiddenTabs::singleton().isHidden(page));
    tab->setBoolean("audible"_s, page.isPlayingAudio());
    auto mutedInfo = JSON::Object::create();
    mutedInfo->setBoolean("muted"_s, page.isAudioMuted());
    tab->setObject("mutedInfo"_s, WTF::move(mutedInfo));
    return tab;
}

// Whether tabs.executeScript, insertCSS and removeCSS reach a frame's document: one within the extension's website
// access by the URL upstream checks (WebExtensionDynamicScripts executeScript), or by its origin for an about:blank
// or about:srcdoc document, which has its creator's; or one of the extension's own pages, which answers for itself.
static bool canScriptFrame(const LegacyExtensions::WebsiteAccess& access, const String& extensionKey, const FrameInfoData& info)
{
    auto& url = info.request.url();
    if (!info.documentID)
        return false;
    if (extensionKeyForURL(url) == extensionKey)
        return true;
    if (url.isAboutBlank() || url.isAboutSrcDoc())
        return access.allows(info.securityOrigin.toURL());
    return access.allows(url);
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

    // devtools, from a devtools page, for its inspected tab within the extension's website access.
    if (method.startsWith("devtools."_s)) {
        if (!context.devToolsTabID)
            return resultToHostContext(context, callID, nullptr, makeString("Unsupported method "_s, method));
        withWebsiteAccess(context.extensionKey, [this, context = Ref { context }, callID, method, arguments](const LegacyExtensions::WebsiteAccess& access) mutable {
            if (!m_hostContexts.contains(context->identifier))
                return;
            LegacyExtensionDevTools::singleton().performCall(*context->devToolsTabID, context->extensionKey, access, method, WTF::move(arguments), [this, context, callID](LegacyExtensionDevTools::CallResult&& result) {
                if (!m_hostContexts.contains(context->identifier))
                    return;
                if (!result)
                    return resultToHostContext(context, callID, nullptr, result.error());
                resultToHostContext(context, callID, WTF::move(result.value()));
            });
        });
        return;
    }

    // Chrome's contract: memory-cache hits never reach webRequest, so a changed listener empties the
    // memory caches, the UI process's for its WebKit 1 pages and every web process's.
    if (method == "webRequest.handlerBehaviorChanged"_s) {
        WebCore::MemoryCache::singleton().evictResources();
        for (Ref pool : WebProcessPool::allProcessPools())
            pool->sendToAllProcesses(Messages::LegacyExtensionContent::EvictMemoryCache());
        resultToHostContext(context, callID, nullptr);
        return;
    }

    // For the toolbar badges of an extension that displays action counts: `displaying`, whether it does, and
    // `count`, that of the active tab of the frontmost browser window (Safari 7's activeBrowserWindow), absent
    // when no window shows a tab.
    if (method == "declarativeNetRequest.activeTabActionCount"_s) {
        RefPtr declarativeNetRequest = m_declarativeNetRequests.get(context.extensionKey);
        RefPtr activeTab = activeTabOfFrontmostWindow();
        auto count = declarativeNetRequest && activeTab ? declarativeNetRequest->actionCountForTab(tabIDForPage(*activeTab)) : std::nullopt;
        auto answer = JSON::Object::create();
        answer->setBoolean("displaying"_s, declarativeNetRequest && declarativeNetRequest->displaysActionCount());
        if (count)
            answer->setDouble("count"_s, *count);
        resultToHostContext(context, callID, WTF::move(answer));
        return;
    }

    // declarativeNetRequest, once the extension's Info.plist is read.
    if (method.startsWith("declarativeNetRequest."_s)) {
        withWebsiteAccess(context.extensionKey, [this, context = Ref { context }, callID, method = method.substring(22), callArgument = argument(0)](const LegacyExtensions::WebsiteAccess&) mutable {
            RefPtr declarativeNetRequest = m_declarativeNetRequests.get(context->extensionKey);
            if (!m_hostContexts.contains(context->identifier) || !declarativeNetRequest)
                return;
            declarativeNetRequest->performCall(method, WTF::move(callArgument), [](double tabID) {
                return !!pageForTabID(tabID);
            }, [this, context, callID](LegacyExtensionDeclarativeNetRequest::CallResult&& result) {
                if (!m_hostContexts.contains(context->identifier))
                    return;
                if (!result)
                    return resultToHostContext(context, callID, nullptr, result.error());
                resultToHostContext(context, callID, WTF::move(result.value()));
            });
        });
        return;
    }

    // mimeHandler's options, by MIME type: getOptions(mimeType) and setOptions(mimeType, { enabled }).
    if (method == "mimeHandler.getOptions"_s || method == "mimeHandler.setOptions"_s) {
        RefPtr mimeTypeValue = argument(0);
        auto mimeType = mimeTypeValue ? mimeTypeValue->asString() : String();
        if (mimeType.isEmpty())
            return resultToHostContext(context, callID, nullptr, "A MIME type is required."_s);
        if (method == "mimeHandler.setOptions"_s) {
            RefPtr options = objectArgument(1);
            LegacyExtensionMimeHandlers::singleton().setOptions(context.extensionKey, mimeType, !options || options->getBoolean("enabled"_s).value_or(true));
            return resultToHostContext(context, callID, nullptr);
        }
        resultToHostContext(context, callID, LegacyExtensionMimeHandlers::singleton().options(context.extensionKey, mimeType));
        return;
    }

    // privacy's settings: get(name), set(name, value, scope) and clear(name, scope). Only the regular scope is
    // supported, as in Firefox.
    // proxy.settings: get(details), set(value, scope, pacData) and clear(scope). Only the regular scope is supported,
    // as in Firefox. `pacData` is the script of a pac_script value's URL the extension read itself.
    if (method == "proxy.settings.get"_s || method == "proxy.settings.set"_s || method == "proxy.settings.clear"_s) {
        if (method == "proxy.settings.get"_s) {
            auto details = LegacyExtensionProxy::singleton().details(context.extensionKey);
            if (RefPtr options = objectArgument(0); options && options->getBoolean("incognito"_s).value_or(false))
                details->setBoolean("incognitoSpecific"_s, false);
            return resultToHostContext(context, callID, WTF::move(details));
        }
        RefPtr scopeValue = argument(method == "proxy.settings.set"_s ? 1 : 0);
        if (auto scope = scopeValue ? scopeValue->asString() : String(); scope != "regular"_s)
            return resultToHostContext(context, callID, nullptr, makeString("The scope \""_s, scope, "\" is not supported."_s));
        if (method == "proxy.settings.clear"_s) {
            LegacyExtensionProxy::singleton().clear(context.extensionKey);
            return resultToHostContext(context, callID, nullptr);
        }
        RefPtr value = objectArgument(0);
        if (!value)
            return resultToHostContext(context, callID, nullptr, "Error at property 'value': Invalid type: expected object."_s);
        RefPtr pacDataValue = argument(2);
        auto error = LegacyExtensionProxy::singleton().set(context.extensionKey, *value, pacDataValue ? pacDataValue->asString() : String());
        return resultToHostContext(context, callID, nullptr, error);
    }

    if (method == "privacy.get"_s || method == "privacy.set"_s || method == "privacy.clear"_s) {
        RefPtr nameValue = argument(0);
        auto name = nameValue ? nameValue->asString() : String();
        if (!LegacyExtensionPrivacy::isSetting(name))
            return resultToHostContext(context, callID, nullptr, makeString("Unknown setting "_s, name));
        if (method == "privacy.get"_s)
            return resultToHostContext(context, callID, LegacyExtensionPrivacy::singleton().details(context.extensionKey, name));
        RefPtr scopeValue = argument(method == "privacy.set"_s ? 2 : 1);
        if (auto scope = scopeValue ? scopeValue->asString() : String(); scope != "regular"_s)
            return resultToHostContext(context, callID, nullptr, makeString("The scope \""_s, scope, "\" is not supported."_s));
        if (method == "privacy.clear"_s) {
            LegacyExtensionPrivacy::singleton().clear(context.extensionKey, name);
            return resultToHostContext(context, callID, nullptr);
        }
        RefPtr value = argument(1);
        auto boolean = value ? value->asBoolean() : std::nullopt;
        if (!boolean)
            return resultToHostContext(context, callID, nullptr, makeString("The value of "_s, name, " must be a boolean."_s));
        LegacyExtensionPrivacy::singleton().set(context.extensionKey, name, *boolean);
        return resultToHostContext(context, callID, nullptr);
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

    if (method == "tabs.get"_s) {
        RefPtr page = pageForTabID(numberArgument(0));
        if (!page)
            return resultToHostContext(context, callID, JSON::Value::null());
        resultWithTab(context, callID, *page);
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

    if (method == "aqua.mediaPlayer.prepareHandoff"_s) {
        RefPtr page = pageForTabReference(objectArgument(0).get());
        RefPtr frame = page ? page->mainFrame() : nullptr;
        auto ticket = frame ? MediaRestreamServer::singleton().prepareHandoff(*page, frame->process(), context.extensionKey) : String { };
        resultToHostContext(context, callID, ticket.isEmpty() ? nullptr : JSON::Value::create(ticket).ptr(), ticket.isEmpty() ? "no-source"_s : String { });
        return;
    }
    // aqua.input: dispatchMouseEvent(tab, event), dispatchKeyEvent(tab, event) and insertText(tab, text).
    if (method == "aqua.input.dispatchMouseEvent"_s || method == "aqua.input.dispatchKeyEvent"_s || method == "aqua.input.insertText"_s) {
        RefPtr page = pageForTabReference(objectArgument(0).get());
        if (!page)
            return resultToHostContext(context, callID, nullptr, "No tab with this id."_s);
        withWebsiteAccess(context.extensionKey, [this, context = Ref { context }, callID, method, page = page.releaseNonNull(), input = argument(1)](const LegacyExtensions::WebsiteAccess& access) {
            if (!m_hostContexts.contains(context->identifier))
                return;
            auto finish = [this, context, callID](LegacyExtensions::InputResult&& result) {
                if (m_hostContexts.contains(context->identifier))
                    resultToHostContext(context, callID, nullptr, result ? String() : result.error());
            };
            if (method == "aqua.input.insertText"_s)
                return finish(LegacyExtensions::insertText(page, context->extensionKey, access, input ? input->asString() : String()));
            RefPtr event = input ? input->asObject() : nullptr;
            if (!event)
                return finish(makeUnexpected("An input event is an object."_s));
            if (method == "aqua.input.dispatchMouseEvent"_s)
                return LegacyExtensions::dispatchMouseEvent(page, context->extensionKey, access, *event, WTF::move(finish));
            LegacyExtensions::dispatchKeyEvent(page, context->extensionKey, access, *event, WTF::move(finish));
        });
        return;
    }

    // aqua.inspector: attach(tab), detach(tab) and sendMessage(tab, message).
    if (method == "aqua.inspector.attach"_s || method == "aqua.inspector.detach"_s || method == "aqua.inspector.sendMessage"_s) {
        RefPtr page = pageForTabReference(objectArgument(0).get());
        if (!page)
            return resultToHostContext(context, callID, nullptr, "No tab with this id."_s);
        if (method == "aqua.inspector.sendMessage"_s) {
            RefPtr message = argument(1);
            auto result = LegacyExtensionInspector::singleton().sendMessage(*page, context.extensionKey, message ? message->asString() : String());
            return resultToHostContext(context, callID, nullptr, result ? String() : result.error());
        }
        if (method == "aqua.inspector.detach"_s) {
            auto result = LegacyExtensionInspector::singleton().detach(*page, context.extensionKey);
            return resultToHostContext(context, callID, nullptr, result ? String() : result.error());
        }
        withWebsiteAccess(context.extensionKey, [this, context = Ref { context }, callID, page = page.releaseNonNull()](const LegacyExtensions::WebsiteAccess& access) {
            if (!m_hostContexts.contains(context->identifier))
                return;
            auto result = LegacyExtensionInspector::singleton().attach(page, context->extensionKey, access);
            resultToHostContext(context, callID, nullptr, result ? String() : result.error());
        });
        return;
    }

    if (method == "aqua.mediaPlayer.cancelHandoff"_s) {
        RefPtr value = argument(0);
        MediaRestreamServer::singleton().cancelHandoff(value ? value->asString() : String { }, context.extensionKey);
        resultToHostContext(context, callID, nullptr);
        return;
    }

    // tabs.hide and tabs.show: tabs hidden from Safari's tab bar, as Firefox hides them. As in Firefox, a tab
    // that names no open tab rejects the call.
    if (method == "tabs.hide"_s || method == "tabs.show"_s) {
        // Every tab is found before any moves, since a move changes the places of the tabs after it.
        Vector<Ref<WebPageProxy>> pages;
        if (RefPtr tabs = argument(0) ? argument(0)->asArray() : nullptr) {
            for (auto& tabValue : *tabs) {
                RefPtr tab = tabValue->asObject();
                auto tabID = tab ? tab->getDouble("tabId"_s) : std::nullopt;
                RefPtr page = pageForTabReference(tab.get());
                if (!page) {
                    resultToHostContext(context, callID, nullptr, tabID ? makeString("Invalid tab ID: "_s, *tabID) : "Invalid tab."_s);
                    return;
                }
                pages.append(page.releaseNonNull());
            }
        }
        if (method == "tabs.show"_s) {
            auto stillHidden = LegacyExtensionHiddenTabs::singleton().show(pages);
            if (!stillHidden.isEmpty()) {
                resultToHostContext(context, callID, nullptr, makeString("Safari could not show tab "_s, stillHidden.first().toUInt64(), ": its window shows all its tabs."_s));
                return;
            }
            resultToHostContext(context, callID, nullptr);
            return;
        }
        auto hiddenTabIDs = JSON::Array::create();
        for (auto identifier : LegacyExtensionHiddenTabs::singleton().hide(context.extensionKey, pages))
            hiddenTabIDs->pushDouble(static_cast<double>(identifier.toUInt64()));
        resultToHostContext(context, callID, WTF::move(hiddenTabIDs));
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
            // A relative URL names a file of the extension, as upstream resolves it against the extension's base URL.
            // As in Chrome (ExtensionTabUtil::PrepareURLForNavigation), a javascript: URL is not navigated to, and
            // neither is a file: URL, which needs local file access Safari 7 extensions do not have.
            if (auto urlString = properties->getString("url"_s); !urlString.isEmpty()) {
                URL url { extensionRoot(context.url), urlString };
                if (!url.isValid())
                    return resultToHostContext(context, callID, nullptr, makeString("Invalid url: \""_s, urlString, "\"."_s));
                if (url.protocolIsJavaScript())
                    return resultToHostContext(context, callID, nullptr, "JavaScript URLs are not allowed in chrome.tabs.update. Use chrome.tabs.executeScript instead."_s);
                if (url.protocolIsFile())
                    return resultToHostContext(context, callID, nullptr, "Cannot navigate to a file URL without local file access."_s);
                page->loadRequest(WebCore::ResourceRequest { WTF::move(url) });
            }
            if (auto muted = properties->getBoolean("muted"_s)) {
                auto mutedState = page->mutedStateFlags();
                mutedState.set(WebCore::MediaProducerMutedState::AudioIsMuted, *muted);
                page->setMuted(mutedState);
            }
        }
        resultWithTab(context, callID, *page);
        return;
    }

    // With no tab (`{ current }`), the calling page's own tab, as upstream's getCurrentTab takes it, or else the
    // active tab of the frontmost window.
    if (method == "tabs.goBack"_s || method == "tabs.goForward"_s) {
        RefPtr reference = objectArgument(0);
        RefPtr<WebPageProxy> page;
        if (RefPtr current = reference ? reference->getValue("current"_s) : nullptr) {
            if (RefPtr frame = WebFrameProxy::webFrame(context.frameID))
                page = frame->page();
            if (!page)
                page = pageForTabReference(current->asObject().get());
        } else
            page = pageForTabReference(reference.get());
        if (!page) {
            resultToHostContext(context, callID, nullptr, "No tab with this id."_s);
            return;
        }
        if (method == "tabs.goBack"_s)
            WKPageGoBack(toAPI(page.get()));
        else
            WKPageGoForward(toAPI(page.get()));
        resultToHostContext(context, callID, nullptr);
        return;
    }

    // tabs.captureTab(tabId, options), of the active tab of the frontmost window when there is no tab, as
    // Firefox takes it. As Firefox's needs <all_urls>, it needs website access to every site. A tab showing
    // another extension's page is captured blurred.
    if (method == "tabs.captureTab"_s) {
        auto tabID = numberArgument(0);
        RefPtr page = tabID ? pageForTabID(tabID) : activeTabOfFrontmostWindow();
        if (!page)
            return resultToHostContext(context, callID, nullptr, tabID ? makeString("Invalid tab ID: "_s, *tabID) : "Cannot access activeTab"_s);
        LegacyExtensions::TabCaptureOptions options;
        if (RefPtr details = objectArgument(1)) {
            options.jpeg = details->getString("format"_s) == "jpeg"_s;
            options.quality = details->getDouble("quality"_s);
            options.scale = details->getDouble("scale"_s);
            if (RefPtr rect = details->getObject("rect"_s))
                options.rect = WebCore::FloatRect(rect->getDouble("x"_s).value_or(0), rect->getDouble("y"_s).value_or(0), rect->getDouble("width"_s).value_or(0), rect->getDouble("height"_s).value_or(0));
        }
        auto owningExtension = extensionKeyForURL(URL { page->pageLoadState().url() });
        auto blur = !owningExtension.isNull() && owningExtension != context.extensionKey ? LegacyExtensions::BlurCapture::Yes : LegacyExtensions::BlurCapture::No;
        withWebsiteAccess(context.extensionKey, [this, context = Ref { context }, callID, page = page.releaseNonNull(), options, blur](const LegacyExtensions::WebsiteAccess& access) {
            if (!m_hostContexts.contains(context->identifier))
                return;
            if (!access.coversEverySite())
                return resultToHostContext(context, callID, nullptr, "Missing host permission for the tab"_s);
            if (page->isClosed())
                return resultToHostContext(context, callID, nullptr, makeString("Invalid tab ID: "_s, tabIDForPage(page)));
            LegacyExtensions::captureTab(page, options, blur, [this, context, callID](Expected<String, String>&& dataURL) {
                if (!m_hostContexts.contains(context->identifier))
                    return;
                if (!dataURL)
                    return resultToHostContext(context, callID, nullptr, dataURL.error());
                resultToHostContext(context, callID, JSON::Value::create(dataURL.value()));
            });
        });
        return;
    }

    // tabs.saveAsPDF(pageSettings), of the active tab of the frontmost window, as Firefox takes it.
    if (method == "tabs.saveAsPDF"_s) {
        RefPtr page = activeTabOfFrontmostWindow();
        if (!page)
            return resultToHostContext(context, callID, nullptr, "Cannot access activeTab"_s);
        RefPtr pageSettings = objectArgument(0);
        if (!pageSettings)
            pageSettings = JSON::Object::create();
        LegacyExtensions::saveTabAsPDF(*page, *pageSettings, [this, context = Ref { context }, callID](String&& status) {
            if (m_hostContexts.contains(context->identifier))
                resultToHostContext(context, callID, JSON::Value::create(WTF::move(status)));
        });
        return;
    }

    // dns.resolve(hostname, flags), with the system resolver. A speculative lookup is refused while DNS
    // prefetching is off, as privacy.network.networkPredictionEnabled turns it off in Firefox.
    if (method == "dns.resolve"_s) {
        RefPtr hostnameValue = argument(0);
        Vector<String> flags;
        if (RefPtr flagValues = argument(1) ? argument(1)->asArray() : nullptr) {
            for (auto& flag : *flagValues)
                flags.append(flag->asString());
        }
        auto predictionEnabled = LegacyExtensionPrivacy::singleton().details(context.extensionKey, "network.networkPredictionEnabled"_s)->getBoolean("value"_s).value_or(true);
        LegacyExtensions::resolveHostname(hostnameValue ? hostnameValue->asString() : String { }, flags, !predictionEnabled, [this, context = Ref { context }, callID](Expected<Ref<JSON::Object>, String>&& record) {
            if (!m_hostContexts.contains(context->identifier))
                return;
            if (!record)
                return resultToHostContext(context, callID, nullptr, record.error());
            resultToHostContext(context, callID, WTF::move(record.value()));
        });
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
        // A frame's URL only when the extension sees it, as upstream's frameParametersForFrame gives it.
        withWebsiteAccess(context.extensionKey, [this, context = Ref { context }, callID, allFrames, wantedFrameId, page = page.releaseNonNull()](const LegacyExtensions::WebsiteAccess& access) {
            page->getAllFrames([this, context, callID, allFrames, wantedFrameId, access](std::optional<FrameTreeNodeData>&& tree) {
                if (!m_hostContexts.contains(context->identifier))
                    return;
                auto frames = JSON::Array::create();
                RefPtr<JSON::Object> wantedFrame;
                if (tree) {
                    forEachFrameInTree(*tree, -1, [&](auto& info, double parentFrameId) {
                        double frameId = info.isMainFrame ? 0 : static_cast<double>(info.frameID.toUInt64());
                        auto description = JSON::Object::create();
                        description->setBoolean("errorOccurred"_s, info.errorOccurred);
                        if (canAccessPageURL(access, context->extensionKey, info.request.url()))
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
        if (method == "tabs.executeScript"_s) {
            request->setString("t"_s, "exec"_s);
            request->setBoolean("userGesture"_s, details->getBoolean("userGesture"_s).value_or(false));
        } else {
            request->setString("t"_s, "css"_s);
            request->setString("op"_s, method == "tabs.insertCSS"_s ? "insert"_s : "remove"_s);
            request->setString("origin"_s, details->getString("cssOrigin"_s));
            // A file's style sheet is based at the file, which is the extension's own.
            if (URL fileURL { details->getString("url"_s) }; fileURL.protocolIs("safari-extension"_s) && fileURL.host() == context.extensionKey)
                request->setString("url"_s, fileURL.string());
        }
        auto targetFrameId = allFrames ? std::nullopt : std::optional<double> { details->getDouble("frameId"_s).value_or(0) };
        // As in Chrome, the frame the call names, or the main frame with allFrames, must be within the extension's
        // website access, and allFrames leaves out the other frames that are not.
        withWebsiteAccess(context.extensionKey, [this, context = Ref { context }, callID, method, routerCallID, requestMessage = request->toJSONString(), page = page.releaseNonNull(), targetFrameId](const LegacyExtensions::WebsiteAccess& access) mutable {
            if (!m_hostContexts.contains(context->identifier))
                return;
            tabFrames(page, targetFrameId, [this, context = WTF::move(context), callID, method, routerCallID, requestMessage = WTF::move(requestMessage), access, isFrameNamed = !!targetFrameId](Vector<FrameInfoData>&& frames) {
                if (!m_hostContexts.contains(context->identifier))
                    return;
                Vector<Endpoint> targets;
                for (auto& info : frames) {
                    if (!canScriptFrame(access, context->extensionKey, info)) {
                        // Chrome's error for a page whose URL the extension does not see (kCannotAccessPage).
                        if (isFrameNamed || info.isMainFrame)
                            return resultToHostContext(context, callID, nullptr, "Cannot access contents of the page. Extension manifest must request permission to access the respective host."_s);
                        continue;
                    }
                    if (auto endpoint = tabFrameEndpoint(info, context->extensionKey))
                        targets.append(WTF::move(*endpoint));
                }
                if (targets.isEmpty())
                    return resultToHostContext(context, callID, nullptr, "No frame with this id."_s);
                m_routerCalls.add(routerCallID, RouterCall { context.ptr(), callID, method, targets, JSON::Array::create(), { } });
                for (auto& target : targets)
                    deliver(target, context->extensionKey, requestMessage);
            });
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

// The events the network ends dispatch: webRequest's, as their names without the namespace, and proxy.onRequest.
static bool isNetworkEvent(const String& name)
{
    return name.startsWith("webRequest."_s) || name == LegacyExtensions::proxyOnRequest;
}

static String networkEventName(const String& name)
{
    return name.startsWith("webRequest."_s) ? name.substring(11) : name;
}

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
        if (isNetworkEvent(interest.key) && (!context.interests.contains(interest.key) || context.interests.get(interest.key) != interest.value))
            networkInterestsChanged = true;
    }
    for (auto& interest : context.interests) {
        if (isNetworkEvent(interest.key) && !interests.contains(interest.key))
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
        withWebsiteAccess(context->extensionKey, [this, context, url, message](const LegacyExtensions::WebsiteAccess& access) {
            if (access.allows(url))
                deliver(Endpoint { context.ptr(), std::nullopt }, context->extensionKey, message);
        });
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

// An extension Safari reloads serves its files from a new root, whose Info.plist is read again. The root it is
// moved from is retired: a web process still reporting the replaced copy's user content cannot move it back.
void LegacyExtensionHost::loadWebsiteAccess(const String& extensionKey, const URL& url)
{
    auto root = extensionRoot(url);
    if (!root.isValid() || m_websiteAccessRoots.get(extensionKey) == root || isRetiredRoot(extensionKey, root))
        return;
    if (auto previousRoot = m_websiteAccessRoots.get(extensionKey); previousRoot.isValid()) {
        m_retiredRoots.ensure(extensionKey, [] { return HashSet<String> { }; }).iterator->value.add(previousRoot.string());
        // The pages tabs show of the copy Safari replaced.
        invalidateExtensionPages(extensionKey, root);
        LegacyExtensionInspector::singleton().extensionDidUnload(extensionKey);
    }
    m_websiteAccessRoots.set(extensionKey, root);
    if (RefPtr declarativeNetRequest = m_declarativeNetRequests.take(extensionKey))
        declarativeNetRequest->unload();
    // Until the new access is read, the network ends hold the extension's blocking events for the router.
    if (m_websiteAccess.remove(extensionKey))
        updateNetworkListeners();
    m_websiteAccessWaiters.ensure(extensionKey, [] { return Vector<Function<void(const LegacyExtensions::WebsiteAccess&)>> { }; });
    LegacyExtensions::loadInfoPlist(root, [this, extensionKey, root](LegacyExtensions::InfoPlist&& infoPlist) {
        if (m_websiteAccessRoots.get(extensionKey) != root)
            return;
        m_websiteAccess.set(extensionKey, WTF::move(infoPlist.websiteAccess));
        auto& loaded = m_websiteAccess.find(extensionKey)->value;
        loadDeclarativeNetRequest(extensionKey, root, WTF::move(infoPlist.declarativeNetRequest), loaded);
        LegacyExtensionMimeHandlers::singleton().extensionDidLoad(extensionKey, root, WTF::move(infoPlist.mimeTypesHandler), loaded);
        LegacyExtensionPrivacy::singleton().extensionDidLoad(extensionKey);
        LegacyExtensionProxy::singleton().extensionDidLoad(extensionKey);
        for (auto& waiter : m_websiteAccessWaiters.take(extensionKey))
            waiter(loaded);
        updateNetworkListeners();
        LegacyExtensionDevTools::singleton().extensionDidLoad(extensionKey, root, infoPlist.devToolsPage);
    });
}

void LegacyExtensionHost::extensionDidUnload(const String& extensionKey)
{
    LegacyExtensionDevTools::singleton().extensionDidUnload(extensionKey);
    LegacyExtensionInspector::singleton().extensionDidUnload(extensionKey);
    MediaRestreamServer::singleton().cancelPreparedHandoffs(extensionKey);
    LegacyExtensionHiddenTabs::singleton().extensionDidUnload(extensionKey);
    LegacyExtensionMimeHandlers::singleton().extensionDidUnload(extensionKey);
    LegacyExtensionPrivacy::singleton().extensionDidUnload(extensionKey);
    LegacyExtensionProxy::singleton().extensionDidUnload(extensionKey);
    m_websiteAccessRoots.remove(extensionKey);
    m_websiteAccessWaiters.remove(extensionKey);
    if (m_websiteAccess.remove(extensionKey))
        updateNetworkListeners();
    RefPtr declarativeNetRequest = m_declarativeNetRequests.take(extensionKey);
    if (!declarativeNetRequest)
        return;
    declarativeNetRequest->unload();
    for (auto identifier : tabObservers().keys()) {
        if (RefPtr page = WebProcessProxy::webPage(identifier))
            updateContentRuleListActionPatterns(*page);
    }
}

// declarativeNetRequest. Each loaded extension's rule list is in every page's user content controller, and
// its website access is where its redirect and modifyHeaders rules act, as a WebExtension's host permissions
// are for its declarativeNetRequestWithHostAccess rules.

Vector<Ref<WebUserContentControllerProxy>> LegacyExtensionHost::userContentControllers() const
{
    Vector<Ref<WebUserContentControllerProxy>> controllers;
    for (auto identifier : tabObservers().keys()) {
        RefPtr page = WebProcessProxy::webPage(identifier);
        if (!page)
            continue;
        Ref controller = page->userContentController();
        if (!controllers.containsIf([&](auto& other) { return other.ptr() == controller.ptr(); }))
            controllers.append(WTF::move(controller));
    }
    return controllers;
}

void LegacyExtensionHost::updateContentRuleListActionPatterns(WebPageProxy& page)
{
    HashMap<String, Vector<String>> patterns;
    for (auto& declarativeNetRequest : m_declarativeNetRequests.values())
        patterns.set(declarativeNetRequest->extensionKey(), declarativeNetRequest->actionPatterns());
    page.configuration().defaultWebsitePolicies().setActiveContentRuleListActionPatterns(WTF::move(patterns));
}

void LegacyExtensionHost::loadDeclarativeNetRequest(const String& extensionKey, const URL& root, RefPtr<JSON::Object>&& declarativeNetRequestEntry, const LegacyExtensions::WebsiteAccess& websiteAccess)
{
    Ref declarativeNetRequest = LegacyExtensionDeclarativeNetRequest::create(extensionKey, root, WTF::move(declarativeNetRequestEntry), websiteAccess);
    declarativeNetRequest->setActionCountObserver([this, extensionKey](double tabID, double count) {
        auto arguments = JSON::Array::create();
        arguments->pushDouble(tabID);
        arguments->pushDouble(count);
        auto event = JSON::Object::create();
        event->setString("t"_s, "event"_s);
        event->setString("name"_s, "declarativeNetRequest.actionCount"_s);
        event->setArray("args"_s, WTF::move(arguments));
        auto message = event->toJSONString();
        for (auto& context : m_hostContexts.values()) {
            if (context->extensionKey == extensionKey && context->frame)
                deliver(Endpoint { context.ptr(), std::nullopt }, extensionKey, message);
        }
    });
    m_declarativeNetRequests.set(extensionKey, declarativeNetRequest.copyRef());
    for (auto identifier : tabObservers().keys()) {
        if (RefPtr page = WebProcessProxy::webPage(identifier))
            updateContentRuleListActionPatterns(*page);
    }
    declarativeNetRequest->load();
}

void LegacyExtensionHost::contentRuleListNotification(WebPageProxy& page, const URL& url, const WebCore::ContentRuleListResults& results)
{
    if (MediaRestreamServer::singleton().isDetached(page))
        return;
    for (auto& result : results.results) {
        if (RefPtr declarativeNetRequest = m_declarativeNetRequests.get(result.first))
            declarativeNetRequest->handleContentRuleListNotificationForTab(tabIDForPage(page), url);
    }
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

void LegacyExtensionHost::dispatchEvent(const String& eventName, const URL& pageURL, RefPtr<JSON::Array>&& visibleArguments, RefPtr<JSON::Array>&& hiddenArguments)
{
    auto message = [&](RefPtr<JSON::Array>&& arguments) {
        if (!arguments)
            return String();
        auto event = JSON::Object::create();
        event->setString("t"_s, "event"_s);
        event->setString("name"_s, eventName);
        event->setArray("args"_s, arguments.releaseNonNull());
        return event->toJSONString();
    };
    auto visibleMessage = message(WTF::move(visibleArguments));
    auto hiddenMessage = message(WTF::move(hiddenArguments));
    for (auto& context : copyToVector(m_hostContexts.values())) {
        if (context->interests.contains(eventName))
            deliverSeeingPage(Endpoint { context.ptr(), std::nullopt }, pageURL, visibleMessage, hiddenMessage);
    }
}

void LegacyExtensionHost::dispatchNavigationEvent(const String& eventName, Ref<JSON::Object>&& details, const URL& url)
{
    auto arguments = JSON::Array::create();
    arguments->pushObject(WTF::move(details));
    dispatchEvent(eventName, url, WTF::move(arguments), nullptr);
}

void LegacyExtensionHost::dispatchExtensionEvent(const String& extensionKey, const String& eventName, Ref<JSON::Array>&& arguments)
{
    auto listeners = hostContextsListeningTo(extensionKey, eventName, { });
    if (listeners.isEmpty())
        return;
    auto event = JSON::Object::create();
    event->setString("t"_s, "event"_s);
    event->setString("name"_s, eventName);
    event->setArray("args"_s, WTF::move(arguments));
    auto message = event->toJSONString();
    for (auto& endpoint : listeners)
        deliver(endpoint, extensionKey, message);
}

void LegacyExtensionHost::dispatchDevToolsEvent(double inspectedTabID, const String& eventName, Ref<JSON::Array>&& arguments, Function<bool(const LegacyExtensions::WebsiteAccess&, const String& extensionKey)>&& allows)
{
    Vector<Ref<HostContext>> listeners;
    for (auto& context : m_hostContexts.values()) {
        if (context->devToolsTabID != inspectedTabID || !context->interests.contains(eventName))
            continue;
        auto access = m_websiteAccess.find(context->extensionKey);
        if (access != m_websiteAccess.end() && allows(access->value, context->extensionKey))
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

// The navigation client of the C API pages Safari 7 creates, which install none: it reports the content rule
// lists a load matched, as a WebExtension browser's navigation delegate does.
class LegacyExtensionNavigationClient final : public API::NavigationClient {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(LegacyExtensionNavigationClient);
    void contentRuleListNotification(WebPageProxy& page, URL&& url, WebCore::ContentRuleListResults&& results) final
    {
        LegacyExtensionHost::singleton().contentRuleListNotification(page, url, results);
    }
    void didSameDocumentNavigation(WebPageProxy& page, API::Navigation*, SameDocumentNavigationType, API::Object*) final
    {
        LegacyExtensionHost::singleton().didCommitMainFrameNavigation(page);
    }
};

void LegacyExtensionHost::pageWasCreated(WebPageProxy& page)
{
    page.setNavigationClient(makeUniqueRef<LegacyExtensionNavigationClient>());
    auto observer = LegacyExtensionTabObserver::create(page, [](WebPageProxy& page, Ref<JSON::Object>&& changeInfo) {
        LegacyExtensionHost::singleton().reportTabUpdate(page, WTF::move(changeInfo));
    });
    page.pageLoadState().addObserver(observer.get());
    bool controllerHasRules = userContentControllers().containsIf([&](auto& controller) {
        return controller.ptr() == &page.userContentController();
    });
    tabObservers().set(page.identifier(), WTF::move(observer));
    updateContentRuleListActionPatterns(page);
    if (!controllerHasRules) {
        for (auto& declarativeNetRequest : m_declarativeNetRequests.values())
            declarativeNetRequest->addDeclarativeNetRequestRules(page.userContentController());
    }

    auto visibleArguments = JSON::Array::create();
    visibleArguments->pushObject(tabDescription(page, true));
    auto hiddenArguments = JSON::Array::create();
    hiddenArguments->pushObject(tabDescription(page, false));
    dispatchEvent("tabs.onCreated"_s, tabURL(page), WTF::move(visibleArguments), WTF::move(hiddenArguments));
    if (!m_cookieObservers.isEmpty())
        updateCookieObservers();
}

// An extension that does not see the tab's URL and title gets a change of neither, and no event for a change of
// nothing else.
void LegacyExtensionHost::reportTabUpdate(WebPageProxy& page, Ref<JSON::Object>&& changeInfo)
{
    if (!tabObservers().contains(page.identifier()))
        return;
    auto hiddenChangeInfo = JSON::Object::create();
    for (auto& [name, value] : changeInfo.get()) {
        if (name != "url"_s && name != "title"_s)
            hiddenChangeInfo->setValue(name, value.copyRef());
    }
    auto visibleArguments = JSON::Array::create();
    visibleArguments->pushDouble(tabIDForPage(page));
    visibleArguments->pushObject(WTF::move(changeInfo));
    visibleArguments->pushObject(tabDescription(page, true));
    RefPtr<JSON::Array> hiddenArguments;
    if (hiddenChangeInfo->size()) {
        hiddenArguments = JSON::Array::create();
        hiddenArguments->pushDouble(tabIDForPage(page));
        hiddenArguments->pushObject(WTF::move(hiddenChangeInfo));
        hiddenArguments->pushObject(tabDescription(page, false));
    }
    dispatchEvent("tabs.onUpdated"_s, tabURL(page), WTF::move(visibleArguments), WTF::move(hiddenArguments));
}

void LegacyExtensionHost::tabHiddenDidChange(WebPageProxy& page)
{
    if (RefPtr observer = tabObservers().get(page.identifier()))
        observer->didChange(LegacyExtensionTabObserver::Property::Hidden);
}

void LegacyExtensionHost::tabAudibleDidChange(WebPageProxy& page)
{
    if (RefPtr observer = tabObservers().get(page.identifier()))
        observer->didChange(LegacyExtensionTabObserver::Property::Audible);
}

void LegacyExtensionHost::tabMutedDidChange(WebPageProxy& page)
{
    if (RefPtr observer = tabObservers().get(page.identifier()))
        observer->didChange(LegacyExtensionTabObserver::Property::Muted);
}

void LegacyExtensionHost::pageWillClose(WebPageProxy& page)
{
    Vector<WebCore::FrameIdentifier> frameIDs;
    if (RefPtr mainFrame = page.mainFrame()) {
        forEachFrame(*mainFrame, [&](auto& frame) {
            frameIDs.append(frame.frameID());
        });
    }
    framesDidGoAway(frameIDs);

    if (!MediaRestreamServer::singleton().isDetached(page))
        tabWillClose(page);
}

void LegacyExtensionHost::tabWillClose(WebPageProxy& page)
{
    LegacyExtensionHiddenTabs::singleton().pageWillClose(page);
    LegacyExtensionInspector::singleton().tabWillClose(page);
    if (auto observer = tabObservers().take(page.identifier()))
        page.pageLoadState().removeObserver(*observer);
    for (auto& declarativeNetRequest : m_declarativeNetRequests.values())
        declarativeNetRequest->tabWasRemoved(tabIDForPage(page));

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
    Ref protectedPage { page };
    if (frame.isMainFrame())
        MediaRestreamServer::singleton().cancelPreparedHandoffs(page);
    if (protectedPage->isClosed() || MediaRestreamServer::singleton().isDetached(page))
        return;
    // A tab's declarativeNetRequest action count is its current page's.
    if (frame.isMainFrame()) {
        didCommitMainFrameNavigation(page);
        for (auto& declarativeNetRequest : m_declarativeNetRequests.values())
            declarativeNetRequest->resetActionCount(tabIDForPage(page));
        LegacyExtensionInspector::singleton().mainFrameURLDidChange(page, url);
    }

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
            // Another page of the same extension takes over the frame's context, so the extension stays loaded.
            if (extensionKeyForURL(url) == context->extensionKey)
                extensionPageContext(frame, documentID, url, context->extensionKey);
            else {
                m_hostContextByRemoteFrame.remove(frame.frameID());
                m_hostContexts.remove(identifier);
                hostContextDidGoAway(*context);
            }
        }
    }
    m_documentsEnteringBackForwardCache.removeIf([&](auto& entry) {
        return entry.value == frame.frameID() && (!documentID || entry.key != *documentID);
    });

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
    dispatchNavigationEvent("webNavigation.onCommitted"_s, WTF::move(details), url);
}

void LegacyExtensionHost::didCommitMainFrameNavigation(WebPageProxy& page)
{
    if (RefPtr observer = tabObservers().get(page.identifier()))
        observer->didCommitMainFrameNavigation();
}

void LegacyExtensionHost::didStartProvisionalLoad(WebPageProxy& page, WebFrameProxy& frame, const URL& url)
{
    if (MediaRestreamServer::singleton().isDetached(page))
        return;
    if (frame.isMainFrame())
        LegacyExtensionInspector::singleton().mainFrameURLDidChange(page, url);
    dispatchNavigationEvent("webNavigation.onBeforeNavigate"_s, navigationDetails(page, frame, url), url);
}

void LegacyExtensionHost::didFinishLoad(WebPageProxy& page, WebFrameProxy& frame)
{
    if (MediaRestreamServer::singleton().isDetached(page))
        return;
    dispatchNavigationEvent("webNavigation.onCompleted"_s, navigationDetails(page, frame, frame.url()), frame.url());
}

// A frame's navigation that fails before it commits, or a committed document's load that fails.
void LegacyExtensionHost::didFailLoad(WebPageProxy& page, WebFrameProxy& frame, const URL& url, const WebCore::ResourceError& error)
{
    if (MediaRestreamServer::singleton().isDetached(page))
        return;
    auto details = navigationDetails(page, frame, url);
    details->setString("error"_s, LegacyExtensions::networkErrorName(error));
    dispatchNavigationEvent("webNavigation.onErrorOccurred"_s, WTF::move(details), url);
}

void LegacyExtensionHost::didFinishDocumentLoad(WebPageProxy& page, WebFrameProxy& frame)
{
    if (MediaRestreamServer::singleton().isDetached(page))
        return;
    dispatchNavigationEvent("webNavigation.onDOMContentLoaded"_s, navigationDetails(page, frame, frame.url()), frame.url());
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
    dispatchNavigationEvent("webNavigation.onCreatedNavigationTarget"_s, WTF::move(details), url);
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
    dispatchWebRequestEvent(eventName, details.releaseNonNull(), WTF::move(completionHandler));
}

void LegacyExtensionHost::dispatchWebRequestEvent(const String& eventName, Ref<JSON::Object>&& details, CompletionHandler<void(String&&)>&& completionHandler)
{
    auto qualifiedName = eventName == LegacyExtensions::proxyOnRequest ? eventName : makeString("webRequest."_s, eventName);
    // An extension's own resources are visible only to that extension; a web request, only to the extensions
    // whose website access covers it. A context whose extension's website access is still being read hears
    // the event once it is read.
    URL requestURL { details->getString("url"_s) };
    auto owningExtension = extensionKeyForURL(requestURL);
    Vector<Ref<HostContext>> listeners;
    Vector<Ref<HostContext>> waitingListeners;
    for (auto& context : m_hostContexts.values()) {
        if (!context->interests.contains(qualifiedName))
            continue;
        if (!owningExtension.isNull()) {
            if (context->extensionKey != owningExtension)
                continue;
            if (m_websiteAccessWaiters.contains(context->extensionKey)) {
                waitingListeners.append(context);
                continue;
            }
        } else if (auto iterator = m_websiteAccess.find(context->extensionKey); iterator == m_websiteAccess.end()) {
            if (m_websiteAccessWaiters.contains(context->extensionKey))
                waitingListeners.append(context);
            continue;
        } else if (!iterator->value.allows(requestURL))
            continue;
        listeners.append(context);
    }

    if (listeners.isEmpty() && waitingListeners.isEmpty()) {
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

    auto deliverOnceAllowed = [this, requestURL, isOwnResource = !owningExtension.isNull()](Ref<HostContext>&& context, const String& message, Function<void(bool)>&& didDeliver) {
        auto extensionKey = context->extensionKey;
        withWebsiteAccess(extensionKey, [this, requestURL, isOwnResource, context = WTF::move(context), message, didDeliver = WTF::move(didDeliver)](const LegacyExtensions::WebsiteAccess& access) mutable {
            didDeliver(m_hostContexts.contains(context->identifier) && (isOwnResource || access.allows(requestURL)) && deliverNow(Endpoint { context.ptr(), std::nullopt }, context->extensionKey, message));
        });
    };

    if (!completionHandler) {
        auto message = event->toJSONString();
        for (auto& context : listeners)
            deliver(Endpoint { context.ptr(), std::nullopt }, context->extensionKey, message);
        for (auto& context : waitingListeners)
            deliverOnceAllowed(context.copyRef(), message, [](bool) { });
        return;
    }

    auto token = m_nextIdentifier++;
    event->setDouble("token"_s, static_cast<double>(token));
    auto message = event->toJSONString();
    WebRequestCall call { { }, JSON::Object::create(), WTF::move(completionHandler) };
    for (auto& context : listeners)
        call.pendingHostContexts.append(context->identifier);
    for (auto& context : waitingListeners)
        call.pendingHostContexts.append(context->identifier);
    m_webRequestCalls.add(token, WTF::move(call));
    for (auto& context : listeners) {
        if (!deliverNow(Endpoint { context.ptr(), std::nullopt }, context->extensionKey, message)) {
            if (auto iterator = m_webRequestCalls.find(token); iterator != m_webRequestCalls.end())
                iterator->value.pendingHostContexts.removeAll(context->identifier);
        }
    }
    for (auto& context : waitingListeners) {
        deliverOnceAllowed(context.copyRef(), message, [this, token, identifier = context->identifier](bool delivered) {
            if (delivered)
                return;
            if (auto iterator = m_webRequestCalls.find(token); iterator != m_webRequestCalls.end())
                iterator->value.pendingHostContexts.removeAll(identifier);
            finishWebRequestCallIfComplete(token);
        });
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
        // proxy.onRequest answers, each context's after those of the contexts created before it.
        if (RefPtr answers = result->getArray("proxy"_s); answers && answers->length()) {
            RefPtr contextAnswers = call.response->getObject("proxyByContext"_s);
            if (!contextAnswers) {
                contextAnswers = JSON::Object::create();
                call.response->setObject("proxyByContext"_s, Ref { *contextAnswers });
            }
            contextAnswers->setArray(String::number(context.identifier), answers.releaseNonNull());
        }
    }
    finishWebRequestCallIfComplete(*token);
}

void LegacyExtensionHost::finishWebRequestCallIfComplete(uint64_t token)
{
    auto iterator = m_webRequestCalls.find(token);
    if (iterator == m_webRequestCalls.end() || !iterator->value.pendingHostContexts.isEmpty())
        return;
    auto call = m_webRequestCalls.take(iterator);
    if (RefPtr contextAnswers = call.response->getObject("proxyByContext"_s)) {
        Vector<std::pair<uint64_t, Ref<JSON::Array>>> ordered;
        for (auto& [identifier, answers] : *contextAnswers) {
            if (RefPtr array = answers->asArray())
                ordered.append({ parseInteger<uint64_t>(identifier).value_or(0), array.releaseNonNull() });
        }
        std::ranges::sort(ordered, { }, &std::pair<uint64_t, Ref<JSON::Array>>::first);
        auto merged = JSON::Array::create();
        for (auto& [identifier, answers] : ordered) {
            for (auto& answer : answers.get())
                merged->pushValue(answer.copyRef());
        }
        call.response->remove("proxyByContext"_s);
        call.response->setArray("proxy"_s, WTF::move(merged));
    }
    call.completionHandler(call.response->toJSONString());
}

void LegacyExtensionHost::updateNetworkListeners()
{
    Vector<String> observed;
    Vector<String> options;
    auto blocking = JSON::Object::create();
    for (auto& context : m_hostContexts.values()) {
        for (auto& [name, interest] : context->interests) {
            if (!isNetworkEvent(name))
                continue;
            auto eventName = networkEventName(name);
            if (!observed.contains(eventName))
                observed.append(eventName);
            RefPtr interestValue = JSON::Value::parseJSON(interest);
            RefPtr interestObject = interestValue ? interestValue->asObject() : nullptr;
            if (!interestObject)
                continue;
            for (auto option : { "requestBody"_s, "extraHeaders"_s, "requestHeaders"_s }) {
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
    LegacyExtensionViewNetwork::singleton().setListeners(m_observedNetworkEvents, m_networkListenerOptions, m_blockingNetworkListeners);
    for (Ref networkProcess : NetworkProcessProxy::allNetworkProcesses())
        sendNetworkListeners(networkProcess);
}

// proxy.onProxyError reaches every extension, as Chromium's ProxyEventRouter broadcasts it.
void LegacyExtensionHost::dispatchProxyError(const String& detailsJSON)
{
    auto value = JSON::Value::parseJSON(detailsJSON);
    RefPtr details = value ? value->asObject() : nullptr;
    if (!details)
        return;
    auto arguments = JSON::Array::create();
    arguments->pushObject(details.releaseNonNull());
    dispatchEvent(LegacyExtensions::proxyOnProxyError, WTF::move(arguments));
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
    if (eventName == LegacyExtensions::proxyOnProxyError)
        return LegacyExtensionHost::singleton().dispatchProxyError(details);
    LegacyExtensionHost::singleton().dispatchWebRequestEvent(eventName, details, { });
}

void LegacyExtensionNetworkProxy::responseFilterEvent(uint64_t filterID, String&& event, IPC::SharedBufferReference&& data, String&& error)
{
    LegacyExtensionHost::singleton().dispatchResponseFilterEvent(filterID, event, data.unsafeBuffer(), error);
}

// webRequest.filterResponseData. A context names its filters and attaches each to a load by the load's
// requestId, "<network process pid>-<n>"; loads of no network process, such as pings and WebSockets, have
// requestIds of another form, and no filter attaches to them.

void LegacyExtensionHost::routeResponseFilter(HostContext& context, JSON::Object& message, RefPtr<WebCore::SharedBuffer>&& data)
{
    auto contextFilterID = message.getString("filterId"_s);
    if (contextFilterID.isEmpty())
        return;
    auto key = makeString(context.identifier, ':', contextFilterID);
    auto operation = message.getString("op"_s);

    if (operation == "create"_s) {
        if (m_responseFilterIDs.contains(key))
            return;
        auto filterID = m_nextIdentifier++;
        m_responseFilterIDs.set(key, filterID);
        m_responseFilters.set(filterID, ResponseFilter { context.identifier, contextFilterID, nullptr, 0 });
        auto requestID = message.getString("requestId"_s);
        size_t separator = requestID.find('-');
        auto processID = separator == notFound ? std::nullopt : parseInteger<int>(StringView { requestID }.left(separator));
        auto requestIdentifier = separator == notFound ? std::nullopt : parseInteger<uint64_t>(StringView { requestID }.substring(separator + 1));
        RefPtr<NetworkProcessProxy> networkProcess;
        for (Ref candidate : NetworkProcessProxy::allNetworkProcesses()) {
            if (processID && candidate->processID() == *processID)
                networkProcess = WTF::move(candidate);
        }
        if (!networkProcess || !requestIdentifier || !*requestIdentifier) {
            dispatchResponseFilterEvent(filterID, "error"_s, nullptr, "Invalid request ID"_s);
            return;
        }
        auto iterator = m_responseFilters.find(filterID);
        iterator->value.networkProcess = *networkProcess;
        auto access = m_websiteAccess.find(context.extensionKey);
        networkProcess->send(Messages::LegacyExtensionNetwork::CreateResponseFilter(filterID, *requestIdentifier, context.extensionKey, access != m_websiteAccess.end() ? access->value.toJSON()->toJSONString() : String { }), 0);
        return;
    }

    auto filterID = m_responseFilterIDs.get(key);
    auto iterator = m_responseFilters.find(filterID);
    if (!filterID || iterator == m_responseFilters.end())
        return;
    RefPtr networkProcess = iterator->value.networkProcess.get();
    if (!networkProcess)
        return;
    auto dispatched = integerIdentifier(message.getDouble("dispatched"_s).value_or(0)).value_or(0);
    iterator->value.dispatched = std::max(iterator->value.dispatched, dispatched);
    if (operation == "write"_s)
        networkProcess->send(Messages::LegacyExtensionNetwork::WriteResponseFilter(filterID, IPC::SharedBufferReference { WTF::move(data) }, dispatched), 0);
    else if (operation == "suspend"_s)
        networkProcess->send(Messages::LegacyExtensionNetwork::SuspendResponseFilter(filterID), 0);
    else if (operation == "resume"_s)
        networkProcess->send(Messages::LegacyExtensionNetwork::ResumeResponseFilter(filterID), 0);
    else if (operation == "close"_s) {
        networkProcess->send(Messages::LegacyExtensionNetwork::CloseResponseFilter(filterID), 0);
        removeResponseFilter(filterID);
    } else if (operation == "disconnect"_s) {
        networkProcess->send(Messages::LegacyExtensionNetwork::DisconnectResponseFilter(filterID, dispatched), 0);
        removeResponseFilter(filterID);
    }
}

void LegacyExtensionHost::removeResponseFilter(uint64_t filterID)
{
    auto filter = m_responseFilters.take(filterID);
    m_responseFilterIDs.remove(makeString(filter.hostContextIdentifier, ':', filter.contextFilterID));
}

void LegacyExtensionHost::dispatchResponseFilterEvent(uint64_t filterID, const String& event, RefPtr<WebCore::SharedBuffer>&& data, const String& error)
{
    auto iterator = m_responseFilters.find(filterID);
    if (iterator == m_responseFilters.end())
        return;
    RefPtr context = m_hostContexts.get(iterator->value.hostContextIdentifier);
    auto message = JSON::Object::create();
    message->setString("t"_s, "filter"_s);
    message->setString("filterId"_s, iterator->value.contextFilterID);
    message->setString("ev"_s, event);
    if (!error.isNull())
        message->setString("error"_s, error);
    if (event == "error"_s)
        removeResponseFilter(filterID);
    if (context)
        deliver(Endpoint { context, std::nullopt }, context->extensionKey, message->toJSONString(), WTF::move(data));
}

} // namespace WebKit
