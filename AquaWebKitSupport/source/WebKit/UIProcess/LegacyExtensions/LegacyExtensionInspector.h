// `aqua.inspector` for Safari 7 legacy extensions: an extension's connection to the Web Inspector backend of a tab.
//
// An attached extension is a frontend of the tab's WebPageInspectorController, as upstream's automation passthrough
// (InspectorPassthroughChannel) is: each message it sends reaches the backend as it is, and each message of the
// backend reaches its aqua.inspector.onMessage listeners. The backend's agents keep one state for all frontends,
// announce the page's targets to the first frontend only, and send every response to every frontend
// (FrontendRouter::sendResponse), so a session is the tab's only frontend: an extension attaches to a tab that has
// no other, and the tab's Web Inspector opening ends the session. The backend reaches every frame and load of the
// page, so attaching takes website access to every site, and the session ends when the tab shows a page the
// extension does not see.

#pragma once

#include "LegacyExtensionWebsiteAccess.h"
#include "WebPageProxyIdentifier.h"
#include <wtf/Expected.h>
#include <wtf/HashMap.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/URL.h>
#include <wtf/text/WTFString.h>

namespace WebKit {

class LegacyExtensionInspectorSession;
class WebPageProxy;
class WebProcessProxy;

class LegacyExtensionInspector {
public:
    static LegacyExtensionInspector& singleton();

    // aqua.inspector calls of an extension, for a tab.
    using Result = Expected<void, String>;
    Result attach(WebPageProxy&, const String& extensionKey, const LegacyExtensions::WebsiteAccess&);
    Result detach(WebPageProxy&, const String& extensionKey);
    Result sendMessage(WebPageProxy&, const String& extensionKey, const String& message);

    // The tab's Web Inspector is about to open: WebInspectorUIProxy::connect's hook.
    void localInspectorWillOpen(WebPageProxy&);
    void tabWillClose(WebPageProxy&);
    // A web process exits. The backend does not reconnect a tab's target to the process that replaces it.
    void webProcessWillShutDown(WebProcessProxy&);
    // A main-frame load of the tab starts, or commits, at the URL.
    void mainFrameURLDidChange(WebPageProxy&, const URL&);
    // The extension is unloaded, or Safari replaced it with a new copy.
    void extensionDidUnload(const String& extensionKey);

private:
    friend class NeverDestroyed<LegacyExtensionInspector>;
    LegacyExtensionInspector();
    ~LegacyExtensionInspector();

    // The session of the tab ends; with a reason, its extension's onDetach listeners hear of it.
    void endSession(WebPageProxyIdentifier, ASCIILiteral reason);

    HashMap<WebPageProxyIdentifier, std::unique_ptr<LegacyExtensionInspectorSession>> m_sessions;
};

} // namespace WebKit
