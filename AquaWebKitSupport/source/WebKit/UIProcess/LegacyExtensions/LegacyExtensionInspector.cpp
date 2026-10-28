#include "config.h"
#include "LegacyExtensionInspector.h"

#include "LegacyExtensionHost.h"
#include "PageLoadState.h"
#include "WebInspectorUIProxy.h"
#include "WebFrameProxy.h"
#include "WebPageInspectorController.h"
#include "WebPageProxy.h"
#include "WebProcessProxy.h"
#include <JavaScriptCore/InspectorFrontendChannel.h>
#include <wtf/JSONValues.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/WeakPtr.h>
#include <wtf/text/MakeString.h>

namespace WebKit {

static double tabIDForPage(const WebPageProxy& page)
{
    return static_cast<double>(page.identifier().toUInt64());
}

class LegacyExtensionInspectorSession final : public Inspector::FrontendChannel {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(LegacyExtensionInspectorSession);
public:
    LegacyExtensionInspectorSession(WebPageProxy& page, const String& extensionKey, const LegacyExtensions::WebsiteAccess& access)
        : m_page(page)
        , m_tabID(tabIDForPage(page))
        , m_extensionKey(extensionKey)
        , m_websiteAccess(access)
    {
    }

    const String& extensionKey() const { return m_extensionKey; }
    RefPtr<WebPageProxy> page() const { return m_page.get(); }
    double tabID() const { return m_tabID; }
    bool allows(const URL& url) const { return m_websiteAccess.allowsForExtension(m_extensionKey, url); }

    // As the first frontend, the session is announced the page's targets while it connects.
    void connect()
    {
        if (RefPtr page = m_page.get())
            page->inspectorController().connectFrontend(*this);
    }

    void disconnect()
    {
        if (RefPtr page = m_page.get())
            page->inspectorController().disconnectFrontend(*this);
    }

    void send(const String& message)
    {
        if (RefPtr page = m_page.get())
            page->inspectorController().dispatchMessageFromFrontend(message);
    }

    // Inspector::FrontendChannel.
    ConnectionType connectionType() const final { return ConnectionType::Local; }

    void sendMessageToFrontend(const String& message) final
    {
        auto arguments = JSON::Array::create();
        arguments->pushDouble(m_tabID);
        arguments->pushString(message);
        LegacyExtensionHost::singleton().dispatchExtensionEvent(m_extensionKey, "aqua.inspector.onMessage"_s, WTF::move(arguments));
    }

private:
    WeakPtr<WebPageProxy> m_page;
    double m_tabID { 0 };
    String m_extensionKey;
    LegacyExtensions::WebsiteAccess m_websiteAccess;
};

LegacyExtensionInspector& LegacyExtensionInspector::singleton()
{
    static NeverDestroyed<LegacyExtensionInspector> inspector;
    return inspector;
}

LegacyExtensionInspector::LegacyExtensionInspector() = default;
LegacyExtensionInspector::~LegacyExtensionInspector() = default;

auto LegacyExtensionInspector::attach(WebPageProxy& page, const String& extensionKey, const LegacyExtensions::WebsiteAccess& access) -> Result
{
    auto tabID = tabIDForPage(page);
    if (page.isClosed())
        return makeUnexpected(makeString("No tab with id: "_s, tabID, '.'));
    if (!access.coversEverySite())
        return makeUnexpected("Missing host permission for the tab"_s);
    if (m_sessions.contains(page.identifier()))
        return makeUnexpected(makeString("An inspector session is already attached to the tab with id: "_s, tabID, '.'));
    // A Web Inspector that is opening connects its frontend once the page has shown it.
    if (page.hasInspectorFrontend() || (page.inspector() && page.inspector()->isConnected()))
        return makeUnexpected(makeString("Another Web Inspector frontend is connected to the tab with id: "_s, tabID, '.'));

    auto session = makeUnique<LegacyExtensionInspectorSession>(page, extensionKey, access);
    auto& pageLoadState = page.pageLoadState();
    // The page the tab shows, and the one it is loading.
    if (!session->allows(pageLoadState.url()) || (!pageLoadState.provisionalURL().isEmpty() && !session->allows(pageLoadState.provisionalURL())))
        return makeUnexpected(makeString("Cannot access the page of the tab with id: "_s, tabID, '.'));
    auto& connected = *session;
    m_sessions.add(page.identifier(), WTF::move(session));
    connected.connect();
    return { };
}

auto LegacyExtensionInspector::detach(WebPageProxy& page, const String& extensionKey) -> Result
{
    auto iterator = m_sessions.find(page.identifier());
    if (iterator == m_sessions.end() || iterator->value->extensionKey() != extensionKey)
        return makeUnexpected(makeString("The extension is not attached to the tab with id: "_s, tabIDForPage(page), '.'));
    endSession(page.identifier(), { });
    return { };
}

auto LegacyExtensionInspector::sendMessage(WebPageProxy& page, const String& extensionKey, const String& message) -> Result
{
    auto iterator = m_sessions.find(page.identifier());
    if (iterator == m_sessions.end() || iterator->value->extensionKey() != extensionKey)
        return makeUnexpected(makeString("The extension is not attached to the tab with id: "_s, tabIDForPage(page), '.'));
    iterator->value->send(message);
    return { };
}

void LegacyExtensionInspector::localInspectorWillOpen(WebPageProxy& page)
{
    endSession(page.identifier(), "replaced_with_inspector"_s);
}

void LegacyExtensionInspector::tabWillClose(WebPageProxy& page)
{
    endSession(page.identifier(), "target_closed"_s);
}

void LegacyExtensionInspector::webProcessWillShutDown(WebProcessProxy& process)
{
    Vector<WebPageProxyIdentifier> identifiers;
    for (auto& [identifier, session] : m_sessions) {
        RefPtr page = session->page();
        if (page && &page->legacyMainFrameProcess() == &process)
            identifiers.append(identifier);
    }
    for (auto identifier : identifiers)
        endSession(identifier, "target_closed"_s);
}

void LegacyExtensionInspector::mainFrameURLDidChange(WebPageProxy& page, const URL& url)
{
    auto iterator = m_sessions.find(page.identifier());
    if (iterator != m_sessions.end() && !iterator->value->allows(url))
        endSession(page.identifier(), "target_closed"_s);
}

void LegacyExtensionInspector::extensionDidUnload(const String& extensionKey)
{
    Vector<WebPageProxyIdentifier> identifiers;
    for (auto& [identifier, session] : m_sessions) {
        if (session->extensionKey() == extensionKey)
            identifiers.append(identifier);
    }
    for (auto identifier : identifiers)
        endSession(identifier, { });
}

void LegacyExtensionInspector::endSession(WebPageProxyIdentifier identifier, ASCIILiteral reason)
{
    auto session = m_sessions.take(identifier);
    if (!session)
        return;
    session->disconnect();
    if (reason.isNull())
        return;
    auto arguments = JSON::Array::create();
    arguments->pushDouble(session->tabID());
    arguments->pushString(reason);
    LegacyExtensionHost::singleton().dispatchExtensionEvent(session->extensionKey(), "aqua.inspector.onDetach"_s, WTF::move(arguments));
}

} // namespace WebKit
