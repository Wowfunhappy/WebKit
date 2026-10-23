#include "config.h"
#include "WebPageProxy.h"
#include "APIHistoryClient.h"
#include "APINavigationClient.h"
#include "APILoaderClient.h"
#include "APIPolicyClient.h"
#include "APIResourceLoadClient.h"
#include "APIInjectedBundleClient.h"
#include "APIUIClient.h"
#include "APIIconLoadingClient.h"
#include "APIFormClient.h"
#include "APIFindClient.h"
#include "APIFindMatchesClient.h"
#include "APIDiagnosticLoggingClient.h"
#include "APIContextMenuClient.h"
#include "APIFullscreenClient.h"
#include "PageLoadStateObserver.h"
#include "WebPopupMenuProxy.h"
#include "WebContextMenuProxy.h"
#include "WebFullScreenManagerProxy.h"
#include "WebInspectorUIProxy.h"
#include "WebPageInspectorController.h"
#include "WebPageDebuggable.h"

namespace WebKit {
void WebPageProxy::detachMediaPlayerTab()
{
    if (RefPtr popup = std::exchange(m_activePopupMenu, nullptr))
        popup->cancelTracking();
#if ENABLE(CONTEXT_MENUS)
    m_activeContextMenu = nullptr;
#endif
#if ENABLE(FULLSCREEN_API)
    if (RefPtr fullscreen = std::exchange(m_fullScreenManager, nullptr))
        fullscreen->detachFromClient();
#endif
    protect(m_inspector)->invalidate();
    m_inspectorController->pageClosed();
#if ENABLE(REMOTE_INSPECTOR)
    if (RefPtr debuggable = std::exchange(m_inspectorDebuggable, nullptr))
        debuggable->detachFromPage();
#endif
    setPageLoadStateObserver(nullptr);
    setHistoryClient(makeUniqueRef<API::HistoryClient>());
    setNavigationClient(makeUniqueRef<API::NavigationClient>());
    setLoaderClient(nullptr);
    setPolicyClient(nullptr);
    setResourceLoadClient(nullptr);
    setInjectedBundleClient(nullptr);
    setUIClient(makeUnique<API::UIClient>());
    setIconLoadingClient(nullptr);
    setFormClient(nullptr);
    setFindClient(nullptr);
    setFindMatchesClient(nullptr);
    setDiagnosticLoggingClient(nullptr);
#if ENABLE(CONTEXT_MENUS)
    setContextMenuClient(nullptr);
#endif
#if ENABLE(FULLSCREEN_API)
    setFullscreenClient(nullptr);
#endif
}
}
