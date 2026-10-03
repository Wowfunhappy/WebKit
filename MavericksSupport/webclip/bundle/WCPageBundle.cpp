// The Web Clip plug-in's injected bundle, loaded into each clip's web content process.
//
// Stock Web Clip turns scrolling off in its WebView's main frame (-[WebFrameView setAllowsScrolling:NO]),
// so the user cannot scroll the clip's page. The bundle gives each page's main frame the scrolling mode
// of a scrolling="no" frame, which every view the frame creates takes on: the user cannot scroll it,
// and the plug-in still scrolls it to show the clip.

#include "cmakeconfig.h"

#include <wtf/Platform.h>
#include <JavaScriptCore/JSExportMacros.h>
#include <WebCore/PlatformExportMacros.h>
#include <pal/ExportMacros.h>
#include <wtf/text/WTFString.h>

#include <WebCore/LocalFrame.h>
#include <WebKit/WKBundle.h>
#include <WebKit/WKBundleFrame.h>
#include <WebKit/WKBundleInitialize.h>
#include <WebKit/WKBundlePage.h>

static void didCreatePage(WKBundleRef, WKBundlePageRef page, const void*)
{
    WKBundleFrameRef mainFrame = WKBundlePageGetMainFrame(page);
    if (!mainFrame)
        return;
    if (RefPtr frame = WebCore::LocalFrame::fromJSContext(WKBundleFrameGetJavaScriptContext(mainFrame)))
        frame->setScrollingMode(WebCore::ScrollbarMode::AlwaysOff);
}

extern "C" WK_EXPORT void WKBundleInitialize(WKBundleRef bundle, WKTypeRef)
{
    static WKBundleClientV1 client = {
        { 1, nullptr },
        didCreatePage,
        nullptr,
        nullptr,
        nullptr,
        nullptr,
    };
    WKBundleSetClient(bundle, &client.base);
}
