// `browser.devtools` for Safari 7 legacy extensions: the devtools pages and the inspected tab they act on.
//
// An extension whose Info.plist names a `WebExtensionDevtoolsPage` gets that page, for each tab whose Web
// Inspector is open, as a hidden WebKit 1 view in this process, as Safari 7 hosts the extension's global page;
// the router makes it a host context of the extension with the devtools API. Each such extension is an
// inspector extension of the tab's Web Inspector (API::InspectorExtension), registered once the frontend has
// loaded, as upstream's WebExtensionContext registers a devtools page's extension; its page opens then and lives
// while both the inspector and the extension do. The frontend acts for it over its own connection to the page:
// evaluating code (Runtime.evaluate with the Command Line API, which shares the inspector's inspected node),
// reloading the tab, and reporting main-frame navigations. The Network domain's requests, which
// devtools.network describes as HAR entries, come from the frontend too: it answers for them when the UI process
// runs its InspectorFrontendAPI functions in the inspector page, and posts each finished request to the
// page's `devToolsNetwork` script message handler. The classic frontend's half of all this is
// InspectorFrontendClassicBridge.h's.

#pragma once

#include "LegacyExtensionWebsiteAccess.h"
#include <wtf/CompletionHandler.h>
#include <wtf/Expected.h>
#include <wtf/HashMap.h>
#include <wtf/JSONValues.h>
#include <wtf/Ref.h>
#include <wtf/URL.h>
#include <wtf/text/WTFString.h>

namespace WebKit {

class WebInspectorUIProxy;
class WebPageProxy;

class LegacyExtensionDevToolsSession;

class LegacyExtensionDevTools {
public:
    static LegacyExtensionDevTools& singleton();

    // The local Web Inspector of a tab opens and closes: WebInspectorUIProxy's hooks, beside upstream's
    // WebExtensionController::inspectorWillOpen and inspectorWillClose.
    void inspectorWillOpen(WebInspectorUIProxy&, WebPageProxy& inspectedPage);
    void inspectorWillClose(WebInspectorUIProxy&);

    // The router's extensions: one is loaded, from the root its files are served at, with the devtools page its
    // Info.plist names (null for none), and unloaded.
    void extensionDidLoad(const String& extensionKey, const URL& root, const String& devToolsPage);
    void extensionDidUnload(const String& extensionKey);

    // The inspected tab of a devtools page of the extension whose WebKit 1 main frame `frame` is.
    std::optional<double> inspectedTabForFrame(const void* frame, const String& extensionKey) const;

    // devtools.* router calls from a devtools page of the extension, for the inspected tab.
    using CallResult = Expected<RefPtr<JSON::Value>, String>;
    void performCall(double inspectedTabID, const String& extensionKey, const LegacyExtensions::WebsiteAccess&, const String& method, RefPtr<JSON::Array>&& arguments, CompletionHandler<void(CallResult&&)>&&);

private:
    friend class NeverDestroyed<LegacyExtensionDevTools>;
    LegacyExtensionDevTools() = default;

    RefPtr<LegacyExtensionDevToolsSession> sessionForTab(double tabID) const;

    struct Extension {
        URL root;
        String devToolsPage;
    };

    HashMap<const WebInspectorUIProxy*, Ref<LegacyExtensionDevToolsSession>> m_sessions;
    HashMap<String, Extension> m_extensions;
};

} // namespace WebKit
