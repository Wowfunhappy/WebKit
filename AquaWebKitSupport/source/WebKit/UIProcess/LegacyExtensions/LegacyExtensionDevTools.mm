#import "config.h"
#import "LegacyExtensionDevTools.h"

#import "APIContentWorld.h"
#import "APIInspectorExtension.h"
#import "APIInspectorExtensionClient.h"
#import "FrameInfoData.h"
#import "JavaScriptEvaluationResult.h"
#import "LegacyExtensionHost.h"
#import "RunJavaScriptParameters.h"
#import "WebFrameProxy.h"
#import "WebInspectorUIExtensionControllerProxy.h"
#import "WebInspectorUIProxy.h"
#import "WebPageProxy.h"
#import "WebScriptMessageHandler.h"
#import "WebUserContentControllerProxy.h"
#import <WebCore/ExceptionDetails.h>
#import <WebCore/RunJavaScriptParameters.h>
#import <WebKitLegacy/WebFrame.h>
#import <WebKitLegacy/WebView.h>
#import <wtf/HashSet.h>
#import <wtf/NeverDestroyed.h>
#import <wtf/RetainPtr.h>
#import <wtf/WeakPtr.h>
#import <wtf/text/MakeString.h>

namespace WebKit {

// The WebKit 1 preferences of devtools pages, whose defaults WebLegacyExtensionPageObserver registers with
// those of Safari's own extension views.
static NSString * const devToolsPagePreferencesIdentifier = @"ExtensionDevToolsPage";

// The inspector page's handler the frontend posts each finished request to.
static constexpr auto requestFinishedHandlerName = "devToolsNetwork"_s;

// Chrome's ExtensionStatus records, which its devtools API hands extensions for failed operations: the
// description is the record's format, and the details are its arguments.
static Ref<JSON::Object> errorStatus(ASCIILiteral code, ASCIILiteral description, const String& detail)
{
    auto details = JSON::Array::create();
    details->pushString(detail);
    auto status = JSON::Object::create();
    status->setString("code"_s, code);
    status->setString("description"_s, description);
    status->setArray("details"_s, WTF::move(details));
    status->setBoolean("isError"_s, true);
    return status;
}

static Ref<JSON::Object> notFoundStatus(const String& detail)
{
    return errorStatus("E_NOTFOUND"_s, "Object not found: %s"_s, detail);
}

static Ref<JSON::Object> failedStatus(const String& detail)
{
    return errorStatus("E_FAILED"_s, "Operation failed: %s"_s, detail);
}

static Ref<JSON::Object> protocolErrorStatus(const String& detail)
{
    return errorStatus("E_PROTOCOLERROR"_s, "Inspector protocol error: %s"_s, detail);
}

// A value the inspected page returned by value, as JSON; null for undefined, and for a value JSON cannot hold.
static RefPtr<JSON::Value> jsonValue(JavaScriptEvaluationResult&& result)
{
    RetainPtr object = result.toID();
    if (!object)
        return nullptr;
    NSArray *wrapper = @[ object.get() ];
    if (![NSJSONSerialization isValidJSONObject:wrapper])
        return nullptr;
    NSData *data = [NSJSONSerialization dataWithJSONObject:wrapper options:0 error:nil];
    RetainPtr string = adoptNS([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
    auto parsed = JSON::Value::parseJSON(String { string.get() });
    RefPtr array = parsed ? parsed->asArray() : nullptr;
    if (!array || !array->length())
        return nullptr;
    return array->get(0).ptr();
}

class LegacyExtensionDevToolsSession final : public RefCounted<LegacyExtensionDevToolsSession>, public CanMakeWeakPtr<LegacyExtensionDevToolsSession> {
public:
    static Ref<LegacyExtensionDevToolsSession> create(WebInspectorUIProxy& inspector, WebPageProxy& inspectedPage)
    {
        return adoptRef(*new LegacyExtensionDevToolsSession(inspector, inspectedPage));
    }

    double tabID() const { return m_tabID; }

    void close()
    {
        for (auto& extensionKey : copyToVector(m_pageURLs.keys()))
            closePage(extensionKey);
        if (RefPtr inspectorPage = m_inspectorPage.get())
            protect(inspectorPage->userContentController())->removeUserMessageHandlerForName(requestFinishedHandlerName, API::ContentWorld::pageContentWorldSingleton());
    }

    // Devtools pages. Each opens once its extension is registered with the inspector.

    void openPage(const String& extensionKey, const URL& url)
    {
        bool isRegistering = m_pageURLs.contains(extensionKey);
        m_pageURLs.set(extensionKey, url);
        if (m_extensions.contains(extensionKey))
            return loadPage(extensionKey);
        if (isRegistering)
            return;
        RefPtr extensionController = m_extensionController;
        if (!extensionController)
            return;
        extensionController->registerExtension(extensionKey, extensionKey, extensionKey, [this, protectedThis = Ref { *this }, extensionKey](Expected<Ref<API::InspectorExtension>, Inspector::ExtensionError> result) {
            if (!result)
                return;
            Ref extension = result.value();
            if (!m_pageURLs.contains(extensionKey)) {
                unregister(extension->identifier());
                return;
            }
            extension->setClient(makeUniqueRef<ExtensionClient>(*this, extensionKey));
            m_extensions.set(extensionKey, WTF::move(extension));
            loadPage(extensionKey);
        });
    }

    void closePage(const String& extensionKey)
    {
        m_pageURLs.remove(extensionKey);
        if (RetainPtr webView = m_webViews.take(extensionKey))
            [webView.get() close];
        if (m_extensions.remove(extensionKey))
            unregister(extensionKey);
    }

    bool hasPageFrame(const void* frame, const String& extensionKey) const
    {
        auto iterator = m_webViews.find(extensionKey);
        return iterator != m_webViews.end() && (__bridge const void*)[iterator->value.get() mainFrame] == frame;
    }

    // devtools.inspectedWindow.eval: in the main world of the main frame, or of the frame `frameURL` names, with
    // the Command Line API, as upstream's WebInspectorExtensionController.evaluateScriptForExtension evaluates;
    // the result is the record Chrome's ExtensionServer answers with. The frontend picks the frame by its URL as
    // upstream's _frameForFrameURL does, matching it with its fragment, or else its query, set aside only when
    // `frameURL` has none: the frame it picks has `frameURL`'s scheme and host.
    void evaluate(const String& extensionKey, const String& expression, const String& frameURL, const LegacyExtensions::WebsiteAccess& access, CompletionHandler<void(Ref<JSON::Object>&&)>&& completionHandler)
    {
        RefPtr extension = m_extensions.get(extensionKey);
        if (!extension)
            return completionHandler(protocolErrorStatus("The Web Inspector is loading."_s));
        if (frameURL.isEmpty()) {
            RefPtr page = m_inspectedPage.get();
            RefPtr mainFrame = page ? page->mainFrame() : nullptr;
            if (!mainFrame)
                return completionHandler(notFoundStatus("<top>"_s));
            if (!access.allowsForExtension(extensionKey, mainFrame->url()))
                return completionHandler(failedStatus("Permission denied"_s));
        } else if (!access.allowsForExtension(extensionKey, URL { frameURL }))
            return completionHandler(failedStatus("Permission denied"_s));

        std::optional<URL> frame;
        if (!frameURL.isEmpty())
            frame = URL { frameURL };
        extension->evaluateScript(expression, frame, std::nullopt, std::nullopt, [frameURL, completionHandler = WTF::move(completionHandler)](Inspector::ExtensionEvaluationResult&& result) mutable {
            if (!result) {
                if (result.error() == Inspector::ExtensionError::InvalidRequest)
                    return completionHandler(notFoundStatus(frameURL.isEmpty() ? "<top>"_s : frameURL));
                return completionHandler(protocolErrorStatus(Inspector::extensionErrorToString(result.error())));
            }
            auto answer = JSON::Object::create();
            if (!result->has_value()) {
                auto& exception = result->error();
                if (!exception)
                    return completionHandler(protocolErrorStatus(Inspector::extensionErrorToString(Inspector::ExtensionError::InternalError)));
                answer->setBoolean("isException"_s, true);
                answer->setString("value"_s, exception->message);
                return completionHandler(WTF::move(answer));
            }
            if (RefPtr value = jsonValue(WTF::move(result->value())))
                answer->setValue("value"_s, value.releaseNonNull());
            completionHandler(WTF::move(answer));
        });
    }

    // devtools.inspectedWindow.reload, as Chrome's ExtensionServer reloads: a user agent the extension gives
    // replaces the page's until the extension reloads without one, and an injected script runs in every frame of
    // the reloaded page, ahead of the page's own scripts, until the next navigation starts.
    void reload(const String& extensionKey, JSON::Object* options, const LegacyExtensions::WebsiteAccess& access)
    {
        RefPtr extension = m_extensions.get(extensionKey);
        RefPtr page = m_inspectedPage.get();
        RefPtr mainFrame = page ? page->mainFrame() : nullptr;
        if (!extension || !mainFrame || !access.allowsForExtension(extensionKey, mainFrame->url()))
            return;
        std::optional<String> userAgent;
        if (auto value = options ? options->getString("userAgent"_s) : String(); !value.isEmpty())
            userAgent = value;
        std::optional<String> injectedScript;
        if (auto value = options ? options->getString("injectedScript"_s) : String(); !value.isEmpty())
            injectedScript = value;
        extension->reloadIgnoringCache(options && options->getBoolean("ignoreCache"_s).value_or(false), userAgent, injectedScript, [](Inspector::ExtensionVoidResult&&) { });
    }

    // devtools.network.getHAR: the requests that finished since the inspector opened and that the extension may
    // see, and the page the main frame shows, from which LegacyExtensionAPI.js builds the HAR log.
    void archive(const String& extensionKey, const LegacyExtensions::WebsiteAccess& access, CompletionHandler<void(Ref<JSON::Object>&&)>&& completionHandler)
    {
        if (!m_extensions.contains(extensionKey))
            return completionHandler(emptyArchive());
        runInInspectorPage("InspectorFrontendAPI.devToolsNetworkArchive()"_s, WebCore::RunAsAsyncFunction::No, [extensionKey, access, completionHandler = WTF::move(completionHandler)](RefPtr<JSON::Object>&& archive) mutable {
            RefPtr records = archive ? archive->getArray("records"_s) : nullptr;
            if (!records)
                return completionHandler(emptyArchive());
            auto allowed = JSON::Array::create();
            for (auto& value : *records) {
                RefPtr record = value->asObject();
                if (record && access.allowsForExtension(extensionKey, URL { record->getString("url"_s) }))
                    allowed->pushObject(record.releaseNonNull());
            }
            auto result = JSON::Object::create();
            result->setArray("records"_s, WTF::move(allowed));
            if (RefPtr page = archive->getObject("page"_s))
                result->setObject("page"_s, page.releaseNonNull());
            completionHandler(WTF::move(result));
        });
    }

    // A HAR entry's getContent(): the response body, as Chrome's ExtensionServer answers with it.
    void content(const String& extensionKey, double requestID, const LegacyExtensions::WebsiteAccess& access, CompletionHandler<void(Ref<JSON::Object>&&)>&& completionHandler)
    {
        if (!m_extensions.contains(extensionKey))
            return completionHandler(notFoundStatus(String::number(requestID)));
        runInInspectorPage(makeString("return InspectorFrontendAPI.devToolsNetworkContent("_s, requestID, ')'), WebCore::RunAsAsyncFunction::Yes, [extensionKey, requestID, access, completionHandler = WTF::move(completionHandler)](RefPtr<JSON::Object>&& content) mutable {
            if (!content)
                return completionHandler(notFoundStatus(String::number(requestID)));
            if (!access.allowsForExtension(extensionKey, URL { content->getString("url"_s) }))
                return completionHandler(failedStatus("Permission denied"_s));
            auto answer = JSON::Object::create();
            answer->setString("encoding"_s, content->getString("encoding"_s));
            if (auto body = content->getString("content"_s); !body.isNull())
                answer->setString("content"_s, body);
            else
                answer->setValue("content"_s, JSON::Value::null());
            completionHandler(WTF::move(answer));
        });
    }

private:
    explicit LegacyExtensionDevToolsSession(WebInspectorUIProxy& inspector, WebPageProxy& inspectedPage)
        : m_inspectedPage(inspectedPage)
        , m_inspectorPage(inspector.inspectorPage())
        , m_extensionController(inspector.extensionController())
        , m_tabID(static_cast<double>(inspectedPage.identifier().toUInt64()))
    {
        if (RefPtr inspectorPage = m_inspectorPage.get())
            protect(inspectorPage->userContentController())->addUserScriptMessageHandler(WebScriptMessageHandler::create(makeUnique<RequestFinishedHandler>(*this), requestFinishedHandlerName, API::ContentWorld::pageContentWorldSingleton()));
    }

    static Ref<JSON::Object> emptyArchive()
    {
        auto result = JSON::Object::create();
        result->setArray("records"_s, JSON::Array::create());
        return result;
    }

    void loadPage(const String& extensionKey)
    {
        auto url = m_pageURLs.get(extensionKey);
        RetainPtr webView = adoptNS([[WebView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600) frameName:nil groupName:nil]);
        [webView.get() setPreferencesIdentifier:devToolsPagePreferencesIdentifier];
        [webView.get() setMaintainsBackForwardList:NO];
        RetainPtr previousWebView = m_webViews.take(extensionKey);
        m_webViews.set(extensionKey, webView);
        [previousWebView.get() close];
        [[webView.get() mainFrame] loadRequest:[NSURLRequest requestWithURL:url.createNSURL().get()]];
    }

    void unregister(const String& extensionKey)
    {
        if (RefPtr extensionController = m_extensionController)
            extensionController->unregisterExtension(extensionKey, [](Expected<void, Inspector::ExtensionError>) { });
    }

    // An InspectorFrontendAPI function of the frontend, whose answer is JSON text; null for none.
    void runInInspectorPage(const String& source, WebCore::RunAsAsyncFunction runAsAsyncFunction, CompletionHandler<void(RefPtr<JSON::Object>&&)>&& completionHandler)
    {
        RefPtr inspectorPage = m_inspectorPage.get();
        auto script = IPC::TransferString::create(source);
        if (!inspectorPage || !script)
            return completionHandler(nullptr);
        inspectorPage->runJavaScriptInMainFrame(RunJavaScriptParameters {
            WTF::move(*script),
            JSC::SourceTaintedOrigin::Untainted,
            URL { },
            runAsAsyncFunction,
            runAsAsyncFunction == WebCore::RunAsAsyncFunction::Yes ? std::optional { Vector<std::pair<String, JavaScriptEvaluationResult>> { } } : std::nullopt,
            WebCore::ForceUserGesture::No,
            WebCore::RemoveTransientActivation::Yes
        }, true, [completionHandler = WTF::move(completionHandler)](auto&& result) mutable {
            if (!result)
                return completionHandler(nullptr);
            auto value = JSON::Value::parseJSON(result->toString());
            completionHandler(value ? value->asObject() : nullptr);
        });
    }

    void inspectedPageDidNavigate(const String& extensionKey, const URL& url)
    {
        auto arguments = JSON::Array::create();
        arguments->pushString(url.string());
        LegacyExtensionHost::singleton().dispatchDevToolsEvent(m_tabID, "devtools.network.onNavigated"_s, WTF::move(arguments), [extensionKey](auto&, const String& listeningExtensionKey) {
            return listeningExtensionKey == extensionKey;
        });
    }

    // devtools.network.onRequestFinished, for the extensions that may see both the request and the page, as
    // Chrome's ExtensionServer notifies them.
    void requestDidFinish(const String& recordJSON)
    {
        auto value = JSON::Value::parseJSON(recordJSON);
        RefPtr record = value ? value->asObject() : nullptr;
        if (!record)
            return;
        Vector<URL> urls { URL { record->getString("url"_s) } };
        RefPtr page = m_inspectedPage.get();
        if (RefPtr mainFrame = page ? page->mainFrame() : nullptr)
            urls.append(mainFrame->url());
        auto arguments = JSON::Array::create();
        arguments->pushObject(record.releaseNonNull());
        LegacyExtensionHost::singleton().dispatchDevToolsEvent(m_tabID, "devtools.network.onRequestFinished"_s, WTF::move(arguments), [urls = WTF::move(urls)](const LegacyExtensions::WebsiteAccess& access, const String& extensionKey) {
            return std::ranges::all_of(urls, [&](auto& url) {
                return access.allowsForExtension(extensionKey, url);
            });
        });
    }

    class ExtensionClient final : public API::InspectorExtensionClient {
        WTF_MAKE_TZONE_ALLOCATED_INLINE(ExtensionClient);
    public:
        ExtensionClient(LegacyExtensionDevToolsSession& session, const String& extensionKey)
            : m_session(session)
            , m_extensionKey(extensionKey)
        {
        }

    private:
        void inspectedPageDidNavigate(const URL& url) final
        {
            if (RefPtr session = m_session.get())
                session->inspectedPageDidNavigate(m_extensionKey, url);
        }

        WeakPtr<LegacyExtensionDevToolsSession> m_session;
        String m_extensionKey;
    };

    class RequestFinishedHandler final : public WebScriptMessageHandler::Client {
        WTF_MAKE_TZONE_ALLOCATED_INLINE(RequestFinishedHandler);
    public:
        explicit RequestFinishedHandler(LegacyExtensionDevToolsSession& session)
            : m_session(session)
        {
        }

    private:
        void didPostMessage(WebPageProxy&, FrameInfoData&&, API::ContentWorld&, JavaScriptEvaluationResult&& message, CompletionHandler<void(Expected<JavaScriptEvaluationResult, String>&&)>&& reply) final
        {
            if (RefPtr session = m_session.get())
                session->requestDidFinish(message.toString());
            reply(makeUnexpected(String()));
        }

        WeakPtr<LegacyExtensionDevToolsSession> m_session;
    };

    WeakPtr<WebPageProxy> m_inspectedPage;
    WeakPtr<WebPageProxy> m_inspectorPage;
    RefPtr<WebInspectorUIExtensionControllerProxy> m_extensionController;
    double m_tabID { 0 };
    // The devtools page of each extension the session has, whose inspector extension is registered or registering.
    HashMap<String, URL> m_pageURLs;
    HashMap<String, Ref<API::InspectorExtension>> m_extensions;
    HashMap<String, RetainPtr<WebView>> m_webViews;
};

LegacyExtensionDevTools& LegacyExtensionDevTools::singleton()
{
    static NeverDestroyed<LegacyExtensionDevTools> devTools;
    return devTools;
}

static URL devToolsPageURL(const URL& root, const String& path)
{
    return URL { root, path.startsWith('/') ? path.substring(1) : path };
}

void LegacyExtensionDevTools::inspectorWillOpen(WebInspectorUIProxy& inspector, WebPageProxy& inspectedPage)
{
    Ref session = LegacyExtensionDevToolsSession::create(inspector, inspectedPage);
    m_sessions.set(&inspector, session.copyRef());
    for (auto& [extensionKey, extension] : m_extensions)
        session->openPage(extensionKey, devToolsPageURL(extension.root, extension.devToolsPage));
}

void LegacyExtensionDevTools::inspectorWillClose(WebInspectorUIProxy& inspector)
{
    if (RefPtr session = m_sessions.take(&inspector))
        session->close();
}

void LegacyExtensionDevTools::extensionDidLoad(const String& extensionKey, const URL& root, const String& devToolsPage)
{
    if (devToolsPage.isEmpty()) {
        extensionDidUnload(extensionKey);
        return;
    }
    m_extensions.set(extensionKey, Extension { root, devToolsPage });
    for (Ref session : copyToVector(m_sessions.values()))
        session->openPage(extensionKey, devToolsPageURL(root, devToolsPage));
}

void LegacyExtensionDevTools::extensionDidUnload(const String& extensionKey)
{
    if (!m_extensions.remove(extensionKey))
        return;
    for (Ref session : copyToVector(m_sessions.values()))
        session->closePage(extensionKey);
}

std::optional<double> LegacyExtensionDevTools::inspectedTabForFrame(const void* frame, const String& extensionKey) const
{
    for (auto& session : m_sessions.values()) {
        if (session->hasPageFrame(frame, extensionKey))
            return session->tabID();
    }
    return std::nullopt;
}

RefPtr<LegacyExtensionDevToolsSession> LegacyExtensionDevTools::sessionForTab(double tabID) const
{
    for (auto& session : m_sessions.values()) {
        if (session->tabID() == tabID)
            return session.ptr();
    }
    return nullptr;
}

void LegacyExtensionDevTools::performCall(double inspectedTabID, const String& extensionKey, const LegacyExtensions::WebsiteAccess& access, const String& method, RefPtr<JSON::Array>&& arguments, CompletionHandler<void(CallResult&&)>&& completionHandler)
{
    RefPtr session = sessionForTab(inspectedTabID);
    if (!session)
        return completionHandler(makeUnexpected("The Web Inspector of the inspected tab is not open."_s));
    auto argument = [&](size_t index) -> RefPtr<JSON::Value> {
        if (!arguments || index >= arguments->length())
            return nullptr;
        return arguments->get(index).ptr();
    };
    auto objectArgument = [&](size_t index) -> RefPtr<JSON::Object> {
        RefPtr value = argument(index);
        return value ? value->asObject() : nullptr;
    };
    auto finish = [completionHandler = WTF::move(completionHandler)](Ref<JSON::Object>&& result) mutable {
        completionHandler(RefPtr<JSON::Value> { WTF::move(result) });
    };

    if (method == "devtools.inspectedWindow.eval"_s) {
        RefPtr expression = argument(0);
        RefPtr options = objectArgument(1);
        return session->evaluate(extensionKey, expression ? expression->asString() : String(), options ? options->getString("frameURL"_s) : String(), access, WTF::move(finish));
    }
    if (method == "devtools.inspectedWindow.reload"_s) {
        session->reload(extensionKey, objectArgument(0).get(), access);
        return finish(JSON::Object::create());
    }
    if (method == "devtools.network.getHAR"_s)
        return session->archive(extensionKey, access, WTF::move(finish));
    if (method == "devtools.network.getContent"_s) {
        RefPtr requestID = argument(0);
        return session->content(extensionKey, requestID ? requestID->asDouble().value_or(0) : 0, access, WTF::move(finish));
    }
    finish(failedStatus(makeString("Unsupported method "_s, method)));
}

} // namespace WebKit
