// The Web Clip plug-in's injected bundle, loaded into each clip's web content process.
//
// Stock Web Clip turns scrolling off in its WebView's main frame (-[WebFrameView setAllowsScrolling:NO]),
// so the user cannot scroll the clip's page. The bundle gives each page's main frame the scrolling mode
// of a scrolling="no" frame, which every view the frame creates takes on: the user cannot scroll it,
// and the plug-in still scrolls it to show the clip.
//
// The plug-in scrolls each page it loads to the clip's recorded place at commit, before the page is
// built, so the main frame's scroll position does not anchor to content until the plug-in says the
// clip has its place in the page; from then on it does, and keeps the clip's content in view when the
// page changes above it.

#include "cmakeconfig.h"

#include <wtf/Platform.h>
#include <JavaScriptCore/JSExportMacros.h>
#include <WebCore/PlatformExportMacros.h>
#include <pal/ExportMacros.h>
#include <wtf/text/WTFString.h>

#include <WebCore/DocumentView.h>
#include <WebCore/LocalFrame.h>
#include <WebCore/LocalFrameView.h>
#include <WebCore/ScrollAnchoringSuppressionHandle.h>
#include <WebKit/WKBundle.h>
#include <WebKit/WKBundleFrame.h>
#include <WebKit/WKBundleInitialize.h>
#include <WebKit/WKBundlePage.h>
#include <WebKit/WKBundlePageLoaderClient.h>
#include <WebKit/WKBundleScriptWorld.h>
#include <WebKit/WKString.h>
#include <wtf/HashMap.h>
#include <wtf/NeverDestroyed.h>
#include <memory>
#include <utility>

struct ClipPage {
    ~ClipPage() { anchorPageScroll(); }

    void anchorPageScroll()
    {
        WebCore::endScrollAnchoringSuppression(std::exchange(anchoringSuppression, nullptr));
    }

    RefPtr<WebCore::LocalFrame> mainFrame;
    WebCore::ScrollAnchoringSuppressionScope* anchoringSuppression { nullptr };
};

static HashMap<WKBundlePageRef, std::unique_ptr<ClipPage>>& clipPages()
{
    static NeverDestroyed<HashMap<WKBundlePageRef, std::unique_ptr<ClipPage>>> pages;
    return pages;
}

// The bundle reaches the main frame through a script world of its own, never the page's: a wrapper the
// page's world got early would stay with the window WebKit hands on to the first page loaded, and one
// made for the frame's initial empty document lacks the interfaces of a secure context, such as
// SubtleCrypto and CryptoKey.
static WKBundleScriptWorldRef bundleWorld()
{
    static WKBundleScriptWorldRef world = WKBundleScriptWorldCreateWorld();
    return world;
}

static void didCommitLoadForFrame(WKBundlePageRef page, WKBundleFrameRef frame, WKTypeRef*, const void*)
{
    if (!WKBundleFrameIsMainFrame(frame))
        return;
    auto* clipPage = clipPages().get(page);
    if (!clipPage)
        return;
    if (!clipPage->mainFrame) {
        RefPtr mainFrame = WebCore::LocalFrame::fromJSContext(WKBundleFrameGetJavaScriptContextForWorld(frame, bundleWorld()));
        if (!mainFrame)
            return;
        mainFrame->setScrollingMode(WebCore::ScrollbarMode::AlwaysOff);
        clipPage->mainFrame = WTF::move(mainFrame);
    }
    clipPage->anchorPageScroll();
    if (RefPtr view = clipPage->mainFrame->view())
        clipPage->anchoringSuppression = WebCore::beginScrollAnchoringSuppression(*view);
}

static void didCreatePage(WKBundleRef, WKBundlePageRef page, const void*)
{
    clipPages().set(page, std::make_unique<ClipPage>());

    static WKBundlePageLoaderClientV0 loaderClient = [] {
        WKBundlePageLoaderClientV0 client { };
        client.base.version = 0;
        client.didCommitLoadForFrame = didCommitLoadForFrame;
        return client;
    }();
    WKBundlePageSetPageLoaderClient(page, &loaderClient.base);
}

static void willDestroyPage(WKBundleRef, WKBundlePageRef page, const void*)
{
    clipPages().remove(page);
}

static void didReceiveMessageToPage(WKBundleRef, WKBundlePageRef page, WKStringRef name, WKTypeRef, const void*)
{
    if (!WKStringIsEqualToUTF8CString(name, "AnchorPageScroll"))
        return;
    if (auto* clipPage = clipPages().get(page))
        clipPage->anchorPageScroll();
}

extern "C" WK_EXPORT void WKBundleInitialize(WKBundleRef bundle, WKTypeRef)
{
    static WKBundleClientV1 client = {
        { 1, nullptr },
        didCreatePage,
        willDestroyPage,
        nullptr,
        nullptr,
        didReceiveMessageToPage,
    };
    WKBundleSetClient(bundle, &client.base);
}
