// Tabs Safari 7 extensions hide from Safari's tab bar without closing them: aqua.tabs.
//
// A hidden tab moves, as a tab dragged between windows moves, into a browser window that is never shown, where
// its page keeps running as a background tab's does. Showing it moves it back into the window it was hidden
// from, after the last of the tabs that preceded it there, or to the end of the frontmost browser window when
// that window has closed. As in Firefox's tabs.hide, the selected tab of a window cannot be hidden, a hidden
// tab that Safari brings to the front is shown, and an extension's hidden tabs show again when the extension
// unloads.

#pragma once

#include "WebPageProxyIdentifier.h"
#include <memory>
#include <wtf/HashMap.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/RetainPtr.h>
#include <wtf/Vector.h>
#include <wtf/WeakObjCPtr.h>
#include <wtf/text/WTFString.h>

OBJC_CLASS NSWindow;
OBJC_CLASS NSWindowController;

namespace WebKit {

class WebPageProxy;

class LegacyExtensionHiddenTabs {
public:
    static LegacyExtensionHiddenTabs& singleton();

    // The page of the tab at `tabIndex` of the browser window at `windowIndex`, as Safari's
    // safari.application.browserWindows and SafariBrowserWindow.tabs order them.
    static RefPtr<WebPageProxy> pageOfSafariTab(size_t windowIndex, size_t tabIndex);

    // The tabs this hides: those of the pages that were shown in a window, but not as its selected tab nor in a
    // window showing all its tabs.
    Vector<WebPageProxyIdentifier> hide(const String& extensionKey, const Vector<Ref<WebPageProxy>>&);
    // The hidden tabs Safari did not move out of the hidden window, which stay hidden.
    Vector<WebPageProxyIdentifier> show(const Vector<Ref<WebPageProxy>>&);
    Vector<WebPageProxyIdentifier> hiddenTabs();

    void pageWillClose(WebPageProxy&);
    void extensionDidUnload(const String& extensionKey);
    // A page's view moved to a window, which for a hidden tab means Safari selected it in the hidden window.
    void webViewDidMoveToWindow(WebPageProxy&, NSWindow *);

private:
    friend class NeverDestroyed<LegacyExtensionHiddenTabs>;
    LegacyExtensionHiddenTabs();

    struct HiddenTab {
        WTF_DEPRECATED_MAKE_STRUCT_FAST_ALLOCATED(HiddenTab);
        String extensionKey;
        RetainPtr<id> tabViewItem;
        WeakObjCPtr<NSWindowController> window;
        Vector<WebPageProxyIdentifier> precedingTabs;
    };

    enum class Destination : bool { WindowItWasHiddenFrom, AnyWindow };
    enum class Raise : bool { No, Yes };

    RetainPtr<NSWindowController> hiddenWindow() const;
    bool showTab(WebPageProxyIdentifier, Destination, Raise);
    void observeHiddenWindow(NSWindow *);
    void hiddenWindowChanged();
    void forgetShownTabs();
    void closeHiddenWindowIfEmpty();

    HashMap<WebPageProxyIdentifier, std::unique_ptr<HiddenTab>> m_tabs;
    WeakObjCPtr<NSWindowController> m_hiddenWindow;
    // The hidden window's own empty tab, and the observers of the window.
    RetainPtr<id> m_hiddenWindowTab;
    Vector<RetainPtr<id>> m_hiddenWindowObservers;
};

} // namespace WebKit
