#import "config.h"
#import "LegacyExtensionDevTools.h"

#import "LegacyExtensionContentMessages.h"
#import "LegacyExtensionHost.h"
#import "PageInspectorTarget.h"
#import "WebFrameProxy.h"
#import "WebInspectorUIProxy.h"
#import "WebPageInspectorController.h"
#import "WebPageProxy.h"
#import "WebProcessProxy.h"
#import <WebKitLegacy/WebFrame.h>
#import <WebKitLegacy/WebView.h>
#import <JavaScriptCore/InspectorFrontendChannel.h>
#import <wtf/RetainPtr.h>
#import <wtf/WeakPtr.h>
#import <wtf/HashSet.h>
#import <wtf/NeverDestroyed.h>
#import <wtf/text/MakeString.h>

namespace WebKit {

static constexpr auto extensionScheme = "safari-extension"_s;

// The WebKit 1 preferences of devtools pages, whose defaults WebLegacyExtensionPageObserver registers with
// those of Safari's own extension views.
static NSString * const devToolsPagePreferencesIdentifier = @"ExtensionDevToolsPage";

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

// Whether the devtools API shows an extension a URL: a web URL within its website access, one of its own files,
// or a URL of no site.
static bool allowsURL(const LegacyExtensions::WebsiteAccess& access, const String& extensionKey, const URL& url)
{
    if (url.protocolIs(extensionScheme))
        return url.host() == extensionKey;
    if (url.protocolIsData() || url.protocolIsAbout())
        return true;
    if (url.protocolIsBlob())
        return access.allows(URL { url.path().toString() });
    return access.allows(url);
}

class LegacyExtensionDevToolsSession final : public RefCounted<LegacyExtensionDevToolsSession>, public Inspector::FrontendChannel {
public:
    static Ref<LegacyExtensionDevToolsSession> create(WebPageProxy& inspectedPage)
    {
        return adoptRef(*new LegacyExtensionDevToolsSession(inspectedPage));
    }

    ~LegacyExtensionDevToolsSession()
    {
        ASSERT(m_pages.isEmpty());
    }

    double tabID() const { return m_tabID; }

    void close()
    {
        while (!m_pages.isEmpty())
            closePage(m_pages.begin()->key);
    }

    // Devtools pages. The session is a frontend of the tab's inspector controller while it has a devtools page.

    void openPage(const String& extensionKey, const URL& url)
    {
        if (!m_connected)
            connect();
        RetainPtr webView = adoptNS([[WebView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600) frameName:nil groupName:nil]);
        [webView.get() setPreferencesIdentifier:devToolsPagePreferencesIdentifier];
        [webView.get() setMaintainsBackForwardList:NO];
        RetainPtr previousWebView = m_pages.take(extensionKey);
        m_pages.set(extensionKey, webView);
        [previousWebView.get() close];
        [[webView.get() mainFrame] loadRequest:[NSURLRequest requestWithURL:url.createNSURL().get()]];
    }

    void closePage(const String& extensionKey)
    {
        if (RetainPtr webView = m_pages.take(extensionKey))
            [webView.get() close];
        if (m_pages.isEmpty() && m_connected)
            disconnect();
    }

    bool hasPageFrame(const void* frame, const String& extensionKey) const
    {
        auto iterator = m_pages.find(extensionKey);
        return iterator != m_pages.end() && (__bridge const void*)[iterator->value.get() mainFrame] == frame;
    }

    // devtools.inspectedWindow.eval: in the main world of the main frame, or of the frame `frameURL` names, with
    // the Command Line API, as upstream's WebInspectorExtensionController.evaluateScriptForExtension evaluates;
    // the result is the record Chrome's ExtensionServer answers with.
    void evaluate(const String& expression, const String& frameURL, const LegacyExtensions::WebsiteAccess& access, const String& extensionKey, CompletionHandler<void(Ref<JSON::Object>&&)>&& completionHandler)
    {
        auto params = JSON::Object::create();
        params->setString("expression"_s, expression);
        params->setString("objectGroup"_s, "extension-evaluation"_s);
        params->setBoolean("includeCommandLineAPI"_s, true);
        params->setBoolean("returnByValue"_s, true);
        params->setBoolean("generatePreview"_s, false);
        params->setBoolean("saveResult"_s, false);

        auto evaluate = [this, protectedThis = Ref { *this }](Ref<JSON::Object>&& params, CompletionHandler<void(Ref<JSON::Object>&&)>&& completionHandler) {
            sendCommand("Runtime.evaluate"_s, WTF::move(params), [completionHandler = WTF::move(completionHandler)](RefPtr<JSON::Object>&& result, String&& error) mutable {
                RefPtr object = result ? result->getObject("result"_s) : nullptr;
                if (!error.isNull() || !object)
                    return completionHandler(protocolErrorStatus(error));
                auto answer = JSON::Object::create();
                if (result->getBoolean("wasThrown"_s).value_or(false)) {
                    answer->setBoolean("isException"_s, true);
                    answer->setString("value"_s, object->getString("description"_s));
                } else if (RefPtr value = object->getValue("value"_s))
                    answer->setValue("value"_s, value.releaseNonNull());
                completionHandler(WTF::move(answer));
            });
        };

        if (frameURL.isEmpty()) {
            RefPtr page = m_inspectedPage.get();
            RefPtr mainFrame = page ? page->mainFrame() : nullptr;
            if (!mainFrame)
                return completionHandler(notFoundStatus("<top>"_s));
            if (!allowsURL(access, extensionKey, mainFrame->url()))
                return completionHandler(failedStatus("Permission denied"_s));
            return evaluate(WTF::move(params), WTF::move(completionHandler));
        }

        // The frame's context comes from its web process, which numbers it as the page's inspector does.
        RefPtr page = m_inspectedPage.get();
        if (!page)
            return completionHandler(notFoundStatus(frameURL));
        protect(page->legacyMainFrameProcess())->sendWithAsyncReply(Messages::LegacyExtensionContent::ExecutionContextForFrameURL(page->webPageIDInMainFrameProcess(), frameURL), [frameURL, access, extensionKey, params = WTF::move(params), evaluate = WTF::move(evaluate), completionHandler = WTF::move(completionHandler)](std::optional<int> contextID, URL&& url) mutable {
            if (!contextID)
                return completionHandler(notFoundStatus(frameURL));
            if (!allowsURL(access, extensionKey, url))
                return completionHandler(failedStatus("Permission denied"_s));
            params->setInteger("contextId"_s, *contextID);
            evaluate(WTF::move(params), WTF::move(completionHandler));
        }, 0);
    }

    // devtools.inspectedWindow.reload, as Chrome's ExtensionServer reloads: a user agent the extension gives
    // replaces the page's until the extension reloads without one, and an injected script runs in every frame of
    // the reloaded page, ahead of the page's own scripts, until the next navigation starts.
    void reload(JSON::Object* options, const LegacyExtensions::WebsiteAccess& access, const String& extensionKey)
    {
        RefPtr page = m_inspectedPage.get();
        RefPtr mainFrame = page ? page->mainFrame() : nullptr;
        if (!mainFrame || !allowsURL(access, extensionKey, mainFrame->url()))
            return;

        auto userAgent = options ? options->getString("userAgent"_s) : String();
        if (!userAgent.isEmpty()) {
            m_userAgent = userAgent;
            m_userAgentOwner = extensionKey;
            sendUserAgent(m_pageTargetID);
        } else if (m_userAgentOwner == extensionKey) {
            m_userAgent = { };
            m_userAgentOwner = { };
            sendUserAgent(m_pageTargetID);
        }

        auto injectedScript = options ? options->getString("injectedScript"_s) : String();
        if (!injectedScript.isEmpty()) {
            m_bootstrapSource = makeString("(function(){"_s, injectedScript, "})()"_s);
            m_bootstrapScript = BootstrapScript::AwaitingLoad;
            sendBootstrapScript(m_pageTargetID);
        } else if (m_bootstrapScript != BootstrapScript::None)
            clearBootstrapScript();

        auto params = JSON::Object::create();
        params->setBoolean("ignoreCache"_s, options && options->getBoolean("ignoreCache"_s).value_or(false));
        sendCommand("Page.reload"_s, WTF::move(params), [](auto&&, auto&&) { });
    }

    // devtools.network.getHAR: the requests that finished since the inspector opened and that the extension may
    // see, and the page the main frame shows, from which LegacyExtensionAPI.js builds the HAR log.
    Ref<JSON::Object> archive(const LegacyExtensions::WebsiteAccess& access, const String& extensionKey) const
    {
        auto records = JSON::Array::create();
        for (auto& request : m_finishedRequests) {
            if (allowsURL(access, extensionKey, request.url))
                records->pushObject(request.record.copyRef());
        }
        auto result = JSON::Object::create();
        result->setArray("records"_s, WTF::move(records));
        if (m_mainFramePage)
            result->setObject("page"_s, Ref { *m_mainFramePage });
        return result;
    }

    // A HAR entry's getContent(): the response body, as Chrome's ExtensionServer answers with it.
    void content(double requestID, const LegacyExtensions::WebsiteAccess& access, const String& extensionKey, CompletionHandler<void(Ref<JSON::Object>&&)>&& completionHandler)
    {
        auto index = m_finishedRequests.findIf([&](auto& request) {
            return static_cast<double>(request.identifier) == requestID;
        });
        if (index == notFound)
            return completionHandler(notFoundStatus(String::number(requestID)));
        auto& request = m_finishedRequests[index];
        if (!allowsURL(access, extensionKey, request.url))
            return completionHandler(failedStatus("Permission denied"_s));
        auto params = JSON::Object::create();
        params->setString("requestId"_s, request.requestID);
        sendCommand("Network.getResponseBody"_s, WTF::move(params), [completionHandler = WTF::move(completionHandler)](RefPtr<JSON::Object>&& result, String&& error) mutable {
            auto answer = JSON::Object::create();
            if (!error.isNull() || !result) {
                answer->setString("encoding"_s, emptyString());
                answer->setValue("content"_s, JSON::Value::null());
                return completionHandler(WTF::move(answer));
            }
            answer->setString("encoding"_s, result->getBoolean("base64Encoded"_s).value_or(false) ? "base64"_s : emptyString());
            answer->setString("content"_s, result->getString("body"_s));
            completionHandler(WTF::move(answer));
        }, request.targetID);
    }

    void didStartProvisionalLoad()
    {
        switch (m_bootstrapScript) {
        case BootstrapScript::None:
            return;
        case BootstrapScript::AwaitingLoad:
            m_bootstrapScript = BootstrapScript::Active;
            return;
        case BootstrapScript::Active:
            clearBootstrapScript();
            return;
        }
    }

    // Inspector::FrontendChannel.
    ConnectionType connectionType() const final { return ConnectionType::Local; }

    void sendMessageToFrontend(const String& message) final
    {
        auto value = JSON::Value::parseJSON(message);
        RefPtr object = value ? value->asObject() : nullptr;
        if (!object)
            return;
        if (auto identifier = object->getInteger("id"_s)) {
            // A reply to Target.sendMessageToTarget: only an error says anything of the command it carried.
            if (*identifier >= 0)
                return;
            auto innerIdentifier = m_outerCommands.take(-*identifier);
            RefPtr error = object->getObject("error"_s);
            if (innerIdentifier && error)
                finishCommand(innerIdentifier, nullptr, error->getString("message"_s));
            return;
        }
        RefPtr params = object->getObject("params"_s);
        if (!params)
            return;
        auto method = object->getString("method"_s);
        if (method == "Target.dispatchMessageFromTarget"_s)
            return dispatchMessageFromTarget(params->getString("targetId"_s), params->getString("message"_s));
        if (method == "Target.targetCreated"_s) {
            RefPtr info = params->getObject("targetInfo"_s);
            if (!info || info->getString("type"_s) != "page"_s)
                return;
            // A provisional page target receives the page's overrides before it is resumed, as upstream's
            // frontend gives one its state: the injected script only while the reload it is for has yet to start
            // loading, since a target made later is another navigation's.
            auto targetID = info->getString("targetId"_s);
            if (!info->getBoolean("isProvisional"_s).value_or(false)) {
                m_pageTargetID = targetID;
                return;
            }
            m_provisionalTargetIDs.add(targetID);
            enableDomains(targetID);
            sendUserAgent(targetID);
            if (m_bootstrapScript == BootstrapScript::AwaitingLoad)
                sendBootstrapScript(targetID);
            return;
        }
        if (method == "Target.didCommitProvisionalTarget"_s) {
            m_pageTargetID = params->getString("newTargetId"_s);
            m_provisionalTargetIDs.remove(m_pageTargetID);
            return;
        }
        if (method == "Target.targetDestroyed"_s)
            targetDestroyed(params->getString("targetId"_s));
    }

private:
    void connect()
    {
        RefPtr page = m_inspectedPage.get();
        if (!page)
            return;
        m_pageTargetID = PageInspectorTarget::toTargetID(page->webPageIDInMainFrameProcess());
        if (RefPtr mainFrame = page->mainFrame()) {
            m_mainFramePage = JSON::Object::create();
            m_mainFramePage->setString("url"_s, mainFrame->url().string());
        }
        m_connected = true;
        page->inspectorController().connectFrontend(*this);
        enableDomains(m_pageTargetID);
    }

    // The domains whose instrumentation the session needs, as a frontend enables what it uses: Page, for the user
    // agent override and the injected script, and Network, for the requests. The inspector's own frontend, which
    // loads after the session connects, enables them too and is answered that they are enabled already.
    void enableDomains(const String& targetID)
    {
        sendCommand("Page.enable"_s, JSON::Object::create(), [](auto&&, auto&&) { }, targetID);
        sendCommand("Network.enable"_s, JSON::Object::create(), [](auto&&, auto&&) { }, targetID);
    }

    // The page's overrides end with the session, whose recorded requests and contexts go with it.
    void disconnect()
    {
        if (!m_userAgentOwner.isNull()) {
            m_userAgent = { };
            m_userAgentOwner = { };
            sendUserAgent(m_pageTargetID);
        }
        if (m_bootstrapScript != BootstrapScript::None)
            clearBootstrapScript();
        m_connected = false;
        if (RefPtr page = m_inspectedPage.get())
            page->inspectorController().disconnectFrontend(*this);
        for (auto& command : std::exchange(m_commands, { }).values())
            command.handler(nullptr, "The Web Inspector closed."_s);
        m_outerCommands.clear();
        m_provisionalTargetIDs.clear();
        m_loadingRequests.clear();
        m_finishedRequests.clear();
        m_mainFramePage = nullptr;
        m_walltimeOffset = std::nullopt;
    }

    void clearBootstrapScript()
    {
        m_bootstrapScript = BootstrapScript::None;
        m_bootstrapSource = { };
        sendCommand("Page.setBootstrapScript"_s, JSON::Object::create(), [](auto&&, auto&&) { });
        for (auto& targetID : m_provisionalTargetIDs)
            sendCommand("Page.setBootstrapScript"_s, JSON::Object::create(), [](auto&&, auto&&) { }, targetID);
    }

    void sendBootstrapScript(const String& targetID)
    {
        auto params = JSON::Object::create();
        params->setString("source"_s, m_bootstrapSource);
        sendCommand("Page.setBootstrapScript"_s, WTF::move(params), [](auto&&, auto&&) { }, targetID);
    }

    explicit LegacyExtensionDevToolsSession(WebPageProxy& inspectedPage)
        : m_inspectedPage(inspectedPage)
        , m_tabID(static_cast<double>(inspectedPage.identifier().toUInt64()))
    {
    }

    using CommandHandler = CompletionHandler<void(RefPtr<JSON::Object>&&, String&&)>;

    struct Command {
        String targetID;
        CommandHandler handler;
    };

    // A finished or loading request of the page: its record, in the shape LegacyExtensionAPI.js reads, and
    // the target and protocol request ID whose body getContent() asks for.
    struct Request {
        uint64_t identifier { 0 };
        String targetID;
        String requestID;
        URL url;
        Ref<JSON::Object> record { JSON::Object::create() };
        // Whether getHAR reports the request: the main frame's current document's requests are logged.
        bool isLogged { true };
    };

    enum class BootstrapScript : uint8_t { None, AwaitingLoad, Active };

    // A command to a target of the page, the page target by default.
    void sendCommand(const String& method, Ref<JSON::Object>&& params, CommandHandler&& handler, const String& targetID = { })
    {
        RefPtr page = m_inspectedPage.get();
        if (!m_connected || !page)
            return handler(nullptr, "The Web Inspector closed."_s);
        auto target = targetID.isNull() ? m_pageTargetID : targetID;
        auto innerIdentifier = m_nextCommandIdentifier++;
        auto inner = JSON::Object::create();
        inner->setInteger("id"_s, -innerIdentifier);
        inner->setString("method"_s, method);
        inner->setObject("params"_s, WTF::move(params));
        m_commands.add(innerIdentifier, Command { target, WTF::move(handler) });

        auto outerIdentifier = m_nextCommandIdentifier++;
        m_outerCommands.add(outerIdentifier, innerIdentifier);
        auto outerParams = JSON::Object::create();
        outerParams->setString("targetId"_s, target);
        outerParams->setString("message"_s, inner->toJSONString());
        auto outer = JSON::Object::create();
        outer->setInteger("id"_s, -outerIdentifier);
        outer->setString("method"_s, "Target.sendMessageToTarget"_s);
        outer->setObject("params"_s, WTF::move(outerParams));
        page->inspectorController().dispatchMessageFromFrontend(outer->toJSONString());
    }

    void finishCommand(int identifier, RefPtr<JSON::Object>&& result, String&& error)
    {
        auto command = m_commands.take(identifier);
        if (command.handler)
            command.handler(WTF::move(result), WTF::move(error));
    }

    void targetDestroyed(const String& targetID)
    {
        m_provisionalTargetIDs.remove(targetID);
        m_loadingRequests.removeIf([&](auto& entry) {
            return entry.value.targetID == targetID;
        });
        Vector<int> identifiers;
        for (auto& [identifier, command] : m_commands) {
            if (command.targetID == targetID)
                identifiers.append(identifier);
        }
        for (auto identifier : identifiers)
            finishCommand(identifier, nullptr, "The target was destroyed."_s);
    }

    void sendUserAgent(const String& targetID)
    {
        if (m_userAgentOwner.isNull() && targetID != m_pageTargetID)
            return;
        auto params = JSON::Object::create();
        if (!m_userAgent.isEmpty())
            params->setString("value"_s, m_userAgent);
        sendCommand("Page.overrideUserAgent"_s, WTF::move(params), [](auto&&, auto&&) { }, targetID);
    }

    static bool isObservedEvent(StringView method)
    {
        static constexpr ASCIILiteral events[] = {
            "Network.requestWillBeSent"_s,
            "Network.responseReceived"_s,
            "Network.dataReceived"_s,
            "Network.loadingFinished"_s,
            "Network.loadingFailed"_s,
            "Network.requestServedFromMemoryCache"_s,
            "Page.frameNavigated"_s,
            "Page.domContentEventFired"_s,
            "Page.loadEventFired"_s,
        };
        for (auto event : events) {
            if (method == event)
                return true;
        }
        return false;
    }

    // Every message of the page's targets reaches every frontend. The backend writes an event's method first and
    // a response's result or error first, so messages the session has no use for are recognized without being
    // parsed.
    void dispatchMessageFromTarget(const String& targetID, const String& message)
    {
        static constexpr auto methodPrefix = "{\"method\":\""_s;
        if (message.startsWith(methodPrefix)) {
            auto methodEnd = message.find('"', methodPrefix.length());
            if (methodEnd == notFound || !isObservedEvent(StringView { message }.substring(methodPrefix.length(), methodEnd - methodPrefix.length())))
                return;
        } else if (m_commands.isEmpty() && (message.startsWith("{\"result\":"_s) || message.startsWith("{\"error\":"_s)))
            return;

        auto value = JSON::Value::parseJSON(message);
        RefPtr object = value ? value->asObject() : nullptr;
        if (!object)
            return;
        if (auto identifier = object->getInteger("id"_s)) {
            if (*identifier >= 0)
                return;
            RefPtr error = object->getObject("error"_s);
            finishCommand(-*identifier, object->getObject("result"_s), error ? error->getString("message"_s) : String());
            return;
        }
        auto method = object->getString("method"_s);
        RefPtr params = object->getObject("params"_s);
        if (params && isObservedEvent(method))
            handleEvent(targetID, method, *params);
    }

    void handleEvent(const String& targetID, const String& method, JSON::Object& params)
    {
        if (method == "Page.frameNavigated"_s) {
            RefPtr frame = params.getObject("frame"_s);
            if (!frame || frame->getValue("parentId"_s))
                return;
            auto loaderID = frame->getString("loaderId"_s);
            auto page = JSON::Object::create();
            page->setString("url"_s, frame->getString("url"_s));
            page->setString("loaderId"_s, loaderID);
            m_mainFramePage = WTF::move(page);
            // As Chrome's network log, with Preserve log off, keeps only the new document's requests.
            m_finishedRequests.removeAllMatching([&](auto& request) {
                return request.record->getString("loaderId"_s) != loaderID;
            });
            for (auto& request : m_loadingRequests.values())
                request.isLogged = request.record->getString("loaderId"_s) == loaderID;
            return;
        }
        if (method == "Page.domContentEventFired"_s || method == "Page.loadEventFired"_s) {
            if (auto timestamp = params.getDouble("timestamp"_s); timestamp && m_mainFramePage)
                m_mainFramePage->setDouble(method == "Page.loadEventFired"_s ? "loadTimestamp"_s : "domContentLoadedTimestamp"_s, *timestamp);
            return;
        }

        auto requestID = params.getString("requestId"_s);
        if (requestID.isEmpty())
            return;
        auto key = makeString(targetID, '\n', requestID);

        if (method == "Network.requestWillBeSent"_s) {
            RefPtr request = params.getObject("request"_s);
            if (!request)
                return;
            auto timestamp = params.getDouble("timestamp"_s);
            auto walltime = params.getDouble("walltime"_s);
            if (timestamp && walltime)
                m_walltimeOffset = *walltime - *timestamp;
            auto iterator = m_loadingRequests.find(key);
            if (RefPtr redirectResponse = params.getObject("redirectResponse"_s); redirectResponse && iterator != m_loadingRequests.end()) {
                Ref record = iterator->value.record;
                auto redirect = JSON::Object::create();
                redirect->setString("url"_s, record->getString("url"_s));
                redirect->setString("method"_s, record->getString("method"_s));
                if (RefPtr headers = record->getObject("requestHeaders"_s))
                    redirect->setObject("requestHeaders"_s, headers.releaseNonNull());
                if (timestamp)
                    redirect->setDouble("timestamp"_s, *timestamp);
                redirect->setObject("response"_s, redirectResponse.releaseNonNull());
                if (RefPtr redirects = record->getArray("redirects"_s))
                    redirects->pushObject(WTF::move(redirect));
                setRequest(record, *request);
                iterator->value.url = URL { request->getString("url"_s) };
                return;
            }
            auto record = JSON::Object::create();
            record->setDouble("id"_s, static_cast<double>(m_nextRequestIdentifier));
            record->setString("frameId"_s, params.getString("frameId"_s));
            record->setString("loaderId"_s, params.getString("loaderId"_s));
            if (auto type = params.getString("type"_s); !type.isNull())
                record->setString("type"_s, type);
            if (timestamp)
                record->setDouble("timestamp"_s, *timestamp);
            if (walltime)
                record->setDouble("walltime"_s, *walltime);
            record->setArray("redirects"_s, JSON::Array::create());
            setRequest(record, *request);
            m_loadingRequests.set(key, Request { m_nextRequestIdentifier++, targetID, requestID, URL { request->getString("url"_s) }, WTF::move(record) });
            return;
        }

        if (method == "Network.requestServedFromMemoryCache"_s) {
            RefPtr resource = params.getObject("resource"_s);
            if (!resource)
                return;
            auto record = JSON::Object::create();
            record->setDouble("id"_s, static_cast<double>(m_nextRequestIdentifier));
            record->setString("frameId"_s, params.getString("frameId"_s));
            record->setString("loaderId"_s, params.getString("loaderId"_s));
            record->setString("type"_s, resource->getString("type"_s));
            record->setString("url"_s, resource->getString("url"_s));
            record->setString("method"_s, "GET"_s);
            record->setObject("requestHeaders"_s, JSON::Object::create());
            record->setArray("redirects"_s, JSON::Array::create());
            if (RefPtr response = resource->getObject("response"_s))
                record->setObject("response"_s, response.releaseNonNull());
            record->setBoolean("fromMemoryCache"_s, true);
            record->setDouble("cachedBodySize"_s, resource->getDouble("bodySize"_s).value_or(0));
            if (auto timestamp = params.getDouble("timestamp"_s)) {
                record->setDouble("timestamp"_s, *timestamp);
                record->setDouble("finishedTimestamp"_s, *timestamp);
                if (m_walltimeOffset)
                    record->setDouble("walltime"_s, *timestamp + *m_walltimeOffset);
            }
            finish(Request { m_nextRequestIdentifier++, targetID, requestID, URL { resource->getString("url"_s) }, WTF::move(record) });
            return;
        }

        auto iterator = m_loadingRequests.find(key);
        if (iterator == m_loadingRequests.end())
            return;
        Ref record = iterator->value.record;

        if (method == "Network.responseReceived"_s) {
            if (RefPtr response = params.getObject("response"_s))
                record->setObject("response"_s, response.releaseNonNull());
            if (auto type = params.getString("type"_s); !type.isNull())
                record->setString("type"_s, type);
            if (auto timestamp = params.getDouble("timestamp"_s))
                record->setDouble("responseTimestamp"_s, *timestamp);
            return;
        }
        if (method == "Network.dataReceived"_s) {
            record->setDouble("dataLength"_s, record->getDouble("dataLength"_s).value_or(0) + params.getDouble("dataLength"_s).value_or(0));
            record->setDouble("encodedDataLength"_s, record->getDouble("encodedDataLength"_s).value_or(0) + params.getDouble("encodedDataLength"_s).value_or(0));
            return;
        }
        if (method == "Network.loadingFinished"_s || method == "Network.loadingFailed"_s) {
            if (auto timestamp = params.getDouble("timestamp"_s))
                record->setDouble("finishedTimestamp"_s, *timestamp);
            if (RefPtr metrics = params.getObject("metrics"_s))
                record->setObject("metrics"_s, metrics.releaseNonNull());
            if (method == "Network.loadingFailed"_s) {
                record->setString("failureText"_s, params.getString("errorText"_s));
                record->setBoolean("canceled"_s, params.getBoolean("canceled"_s).value_or(false));
            }
            auto request = WTF::move(iterator->value);
            m_loadingRequests.remove(iterator);
            finish(WTF::move(request));
        }
    }

    static void setRequest(JSON::Object& record, JSON::Object& request)
    {
        record.setString("url"_s, request.getString("url"_s));
        record.setString("method"_s, request.getString("method"_s));
        if (RefPtr headers = request.getObject("headers"_s))
            record.setObject("requestHeaders"_s, headers.releaseNonNull());
        if (auto postData = request.getString("postData"_s); !postData.isNull())
            record.setString("postData"_s, postData);
        else
            record.remove("postData"_s);
    }

    // devtools.network.onRequestFinished, for the extensions that may see both the request and the page, as
    // Chrome's ExtensionServer notifies them.
    void finish(Request&& request)
    {
        auto arguments = JSON::Array::create();
        arguments->pushObject(request.record.copyRef());
        RefPtr page = m_inspectedPage.get();
        RefPtr mainFrame = page ? page->mainFrame() : nullptr;
        Vector<URL> urls { request.url };
        if (mainFrame)
            urls.append(mainFrame->url());
        if (request.isLogged)
            m_finishedRequests.append(WTF::move(request));
        LegacyExtensionHost::singleton().dispatchDevToolsEvent(m_tabID, "devtools.network.onRequestFinished"_s, WTF::move(arguments), [urls = WTF::move(urls)](const LegacyExtensions::WebsiteAccess& access, const String& extensionKey) {
            return std::ranges::all_of(urls, [&](auto& url) {
                return allowsURL(access, extensionKey, url);
            });
        });
    }

    WeakPtr<WebPageProxy> m_inspectedPage;
    double m_tabID { 0 };
    bool m_connected { false };
    String m_pageTargetID;
    // Each command's identifier is the negation of its key here, its wire identifier.
    int m_nextCommandIdentifier { 1 };
    HashMap<int, Command> m_commands;
    HashMap<int, int> m_outerCommands;
    HashMap<String, Request> m_loadingRequests;
    Vector<Request> m_finishedRequests;
    uint64_t m_nextRequestIdentifier { 1 };
    std::optional<double> m_walltimeOffset;
    RefPtr<JSON::Object> m_mainFramePage;
    String m_userAgent;
    String m_userAgentOwner;
    BootstrapScript m_bootstrapScript { BootstrapScript::None };
    String m_bootstrapSource;
    HashSet<String> m_provisionalTargetIDs;
    HashMap<String, RetainPtr<WebView>> m_pages;
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
    Ref session = LegacyExtensionDevToolsSession::create(inspectedPage);
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

void LegacyExtensionDevTools::didStartProvisionalLoad(WebPageProxy& page)
{
    if (RefPtr session = sessionForTab(static_cast<double>(page.identifier().toUInt64())))
        session->didStartProvisionalLoad();
}

// devtools.network.onNavigated, which Chrome sends every devtools page of the tab.
void LegacyExtensionDevTools::didCommitLoad(WebPageProxy& page, const URL& url)
{
    auto tabID = static_cast<double>(page.identifier().toUInt64());
    if (!sessionForTab(tabID))
        return;
    auto arguments = JSON::Array::create();
    arguments->pushString(url.string());
    LegacyExtensionHost::singleton().dispatchDevToolsEvent(tabID, "devtools.network.onNavigated"_s, WTF::move(arguments), [](auto&, auto&) {
        return true;
    });
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
        return session->evaluate(expression ? expression->asString() : String(), options ? options->getString("frameURL"_s) : String(), access, extensionKey, WTF::move(finish));
    }
    if (method == "devtools.inspectedWindow.reload"_s) {
        session->reload(objectArgument(0).get(), access, extensionKey);
        return finish(JSON::Object::create());
    }
    if (method == "devtools.network.getHAR"_s)
        return finish(session->archive(access, extensionKey));
    if (method == "devtools.network.getContent"_s) {
        RefPtr requestID = argument(0);
        return session->content(requestID ? requestID->asDouble().value_or(0) : 0, access, extensionKey, WTF::move(finish));
    }
    finish(failedStatus(makeString("Unsupported method "_s, method)));
}

} // namespace WebKit
