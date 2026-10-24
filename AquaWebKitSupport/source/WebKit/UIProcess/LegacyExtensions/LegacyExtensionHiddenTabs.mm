#import "config.h"
#import "LegacyExtensionHiddenTabs.h"

#import "LegacyExtensionHost.h"
#import "WKAPICast.h"
#import "WebPageProxy.h"
#import "WebProcessProxy.h"
#import <AppKit/AppKit.h>
#import <wtf/NeverDestroyed.h>
#import <wtf/RunLoop.h>

// Safari 7's browser windows, documents and tabs, as Safari's own tab dragging moves a tab between windows.
@protocol LegacyExtensionSafariDocumentController <NSObject>
- (NSArray *)orderedBrowserDocuments;
- (id)createHiddenEmptyBrowserDocument;
@end

@protocol LegacyExtensionSafariDocument <NSObject>
- (NSWindowController *)browserWindowControllerMac;
@end

@protocol LegacyExtensionSafariWindowController <NSObject>
- (NSArray *)orderedTabViewItems;
- (id)selectedTab;
- (unsigned long long)numberOfTabs;
- (void)moveTabFromOtherWindow:(id)tabViewItem toIndex:(unsigned)index andSelect:(BOOL)select;
- (void)_selectTab:(id)tabViewItem;
// These take a tab's view.
- (void)closeTabWithoutConfirming:(NSView *)view;
- (void)closeTabOrWindowWithoutConfirming:(NSView *)view;
- (void)_moveTabToNewWindow:(id)tabViewItem;
@end

@protocol LegacyExtensionSafariTabViewItem <NSObject>
- (NSView *)wkView;
@end

@protocol LegacyExtensionWKView <NSObject>
- (WKPageRef)pageRef;
@end

static void* tabViewContext = &tabViewContext;

// Safari moves a tab between windows by taking its item out of one window's tab view and putting it into
// another's, which sets the item's tabView.
@interface WKLegacyExtensionHiddenTabObserver : NSObject
@end

@implementation WKLegacyExtensionHiddenTabObserver

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (context != tabViewContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    WebKit::LegacyExtensionHiddenTabs::singleton().tabViewItemDidMove();
}

@end

namespace WebKit {

using SafariWindowController = NSWindowController<LegacyExtensionSafariWindowController>;

LegacyExtensionHiddenTabs& LegacyExtensionHiddenTabs::singleton()
{
    static NeverDestroyed<LegacyExtensionHiddenTabs> hiddenTabs;
    return hiddenTabs;
}

static id<LegacyExtensionSafariDocumentController> documentController()
{
    return (id<LegacyExtensionSafariDocumentController>)[NSClassFromString(@"BrowserDocumentController") sharedDocumentController];
}

static WebPageProxy* pageOfTabViewItem(id tabViewItem)
{
    return toImpl([(id<LegacyExtensionWKView>)[(id<LegacyExtensionSafariTabViewItem>)tabViewItem wkView] pageRef]);
}

// Safari's browser windows, frontmost first, as the extension API lists them.
static Vector<RetainPtr<SafariWindowController>> browserWindows()
{
    Vector<RetainPtr<SafariWindowController>> windows;
    for (id<LegacyExtensionSafariDocument> document in [documentController() orderedBrowserDocuments])
        windows.append((SafariWindowController *)[document browserWindowControllerMac]);
    return windows;
}

// Whether the window shows all its tabs (Tab View) or is going to or from it: Safari's _tabLineupState, which
// moveTabFromOtherWindow: checks on the window a tab moves to. A window's tabs leave its tab view meanwhile,
// so moving one out of it makes Safari close the window, and its other tabs with it.
static bool showsAllTabs(NSWindowController *windowController)
{
    return [[windowController valueForKey:@"tabLineupState"] intValue];
}

// A browser window is open while Safari lists it; its controller can outlive it.
static bool isOpen(NSWindowController *windowController)
{
    return windowController && browserWindows().containsIf([&](auto& window) {
        return window.get() == windowController;
    });
}

static RetainPtr<SafariWindowController> windowOfTabViewItem(id tabViewItem)
{
    for (auto& window : browserWindows()) {
        if ([[window orderedTabViewItems] containsObject:tabViewItem])
            return window;
    }
    return nil;
}

LegacyExtensionHiddenTabs::LegacyExtensionHiddenTabs()
    : m_tabViewItemObserver(adoptNS([[WKLegacyExtensionHiddenTabObserver alloc] init]))
{
}

LegacyExtensionHiddenTabs::HiddenTab::~HiddenTab()
{
    if (tabViewObserver)
        [tabViewItem.get() removeObserver:tabViewObserver.get() forKeyPath:@"tabView" context:tabViewContext];
}

void LegacyExtensionHiddenTabs::observeHiddenWindow(NSWindow *window)
{
    // Safari brings a hidden tab to the front, for an alert of its page, by ordering the hidden window in.
    for (NSString *name in @[ NSWindowDidBecomeKeyNotification, NSWindowDidBecomeMainNotification, NSWindowDidChangeOcclusionStateNotification ]) {
        m_hiddenWindowObservers.append([[NSNotificationCenter defaultCenter] addObserverForName:name object:window queue:nil usingBlock:^(NSNotification *) {
            hiddenWindowChanged();
        }]);
    }
    // Merge All Windows moves every tab of every window, the hidden window's own tab too, into the front window
    // and closes the windows it emptied. The hidden tabs move on into a new hidden window, in the order Safari put
    // them, before Safari draws them there.
    m_hiddenWindowObservers.append([[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification object:window queue:nil usingBlock:^(NSNotification *) {
        for (auto& observer : std::exchange(m_hiddenWindowObservers, { }))
            [[NSNotificationCenter defaultCenter] removeObserver:observer.get()];
        RetainPtr hiddenWindowTab = WTF::move(m_hiddenWindowTab);
        m_hiddenWindow = nil;
        RetainPtr mergeWindow = windowOfTabViewItem(hiddenWindowTab.get());
        if (!mergeWindow || [mergeWindow window] == window)
            return;
        Vector<RetainPtr<id>> mergedTabs;
        for (id item in [mergeWindow orderedTabViewItems]) {
            RefPtr page = pageOfTabViewItem(item);
            if (page && m_tabs.contains(page->identifier()))
                mergedTabs.append(item);
        }
        for (auto& item : mergedTabs)
            moveToHiddenWindow(item.get());
        RunLoop::mainSingleton().dispatch([hiddenWindowTab = WTF::move(hiddenWindowTab)] {
            if (RetainPtr window = windowOfTabViewItem(hiddenWindowTab.get()))
                [window closeTabWithoutConfirming:[(id<LegacyExtensionSafariTabViewItem>)hiddenWindowTab.get() wkView]];
        });
    }]);
}

RetainPtr<NSWindowController> LegacyExtensionHiddenTabs::hiddenWindow() const
{
    RetainPtr window = m_hiddenWindow.get();
    return isOpen(window.get()) ? window : nil;
}

RefPtr<WebPageProxy> LegacyExtensionHiddenTabs::pageOfSafariTab(size_t windowIndex, size_t tabIndex)
{
    auto windows = browserWindows();
    if (windowIndex >= windows.size())
        return nullptr;
    NSArray *tabs = [windows[windowIndex] orderedTabViewItems];
    if (tabIndex >= tabs.count)
        return nullptr;
    return pageOfTabViewItem(tabs[tabIndex]);
}

// A background tab's view is in no window, so the page's tab is found among the windows' tabs.
static RetainPtr<SafariWindowController> windowOfPage(WebPageProxy& page, id& tabViewItem)
{
    for (auto& window : browserWindows()) {
        for (id item in [window orderedTabViewItems]) {
            if (pageOfTabViewItem(item) == &page) {
                tabViewItem = item;
                return window;
            }
        }
    }
    return nil;
}

Vector<WebPageProxyIdentifier> LegacyExtensionHiddenTabs::hide(const String& extensionKey, const Vector<Ref<WebPageProxy>>& pages)
{
    forgetShownTabs();

    // Each tab's place is taken before any tab moves.
    Vector<std::pair<WebPageProxyIdentifier, std::unique_ptr<HiddenTab>>> tabsToHide;
    for (auto& page : pages) {
        if (m_tabs.contains(page->identifier()))
            continue;
        id tabViewItem = nil;
        RetainPtr windowController = windowOfPage(page, tabViewItem);
        SafariWindowController *window = windowController.get();
        if (!window || [window selectedTab] == tabViewItem || showsAllTabs(window))
            continue;
        Vector<WebPageProxyIdentifier> precedingTabs;
        for (id item in [window orderedTabViewItems]) {
            if (item == tabViewItem)
                break;
            if (RefPtr precedingPage = pageOfTabViewItem(item))
                precedingTabs.append(precedingPage->identifier());
        }
        tabsToHide.append({ page->identifier(), makeUnique<HiddenTab>(extensionKey, tabViewItem, window, WTF::move(precedingTabs)) });
    }

    Vector<WebPageProxyIdentifier> hidden;
    for (auto& [identifier, hiddenTab] : tabsToHide) {
        if (!moveToHiddenWindow(hiddenTab->tabViewItem.get()))
            continue;
        hidden.append(identifier);
        hiddenTab->tabViewObserver = m_tabViewItemObserver;
        [hiddenTab->tabViewItem.get() addObserver:m_tabViewItemObserver.get() forKeyPath:@"tabView" options:0 context:tabViewContext];
        m_tabs.add(identifier, WTF::move(hiddenTab));
        hiddenStateDidChange(identifier, true);
    }
    closeHiddenWindowIfEmpty();
    return hidden;
}

// Moves the tab to the end of the hidden window, which this makes when there is none, and returns whether Safari
// moved it there.
bool LegacyExtensionHiddenTabs::moveToHiddenWindow(id tabViewItem)
{
    RetainPtr hiddenWindowController = hiddenWindow();
    if (!hiddenWindowController) {
        // The window keeps its own empty tab selected, so its title stays as it is made. Safari lists a browser
        // window in the Window menu as it makes it and again whenever its title changes.
        id<LegacyExtensionSafariDocument> document = [documentController() createHiddenEmptyBrowserDocument];
        hiddenWindowController = [document browserWindowControllerMac];
        m_hiddenWindowTab = [(SafariWindowController *)hiddenWindowController.get() selectedTab];
        [[hiddenWindowController window] setExcludedFromWindowsMenu:YES];
        [NSApp removeWindowsItem:[hiddenWindowController window]];
        m_hiddenWindow = hiddenWindowController.get();
        observeHiddenWindow([hiddenWindowController window]);
    }
    SafariWindowController *hiddenWindow = (SafariWindowController *)hiddenWindowController.get();
    [hiddenWindow moveTabFromOtherWindow:tabViewItem toIndex:static_cast<unsigned>([hiddenWindow numberOfTabs]) andSelect:NO];
    return [[hiddenWindow orderedTabViewItems] containsObject:tabViewItem];
}

Vector<WebPageProxyIdentifier> LegacyExtensionHiddenTabs::show(const Vector<Ref<WebPageProxy>>& pages)
{
    forgetShownTabs();
    Vector<WebPageProxyIdentifier> stillHidden;
    for (auto& page : pages) {
        if (m_tabs.contains(page->identifier()) && !showTab(page->identifier(), Destination::WindowItWasHiddenFrom, Raise::No))
            stillHidden.append(page->identifier());
    }
    closeHiddenWindowIfEmpty();
    return stillHidden;
}

// Shows the tab in the window it was hidden from, after the last of the tabs that preceded it there, unless that
// window has closed or, for Destination::AnyWindow, shows all its tabs. It then goes to the end of the frontmost
// browser window that does not show all its tabs, or into a new window. Returns whether Safari moved the tab out
// of the hidden window.
bool LegacyExtensionHiddenTabs::showTab(WebPageProxyIdentifier identifier, Destination destination, Raise raise)
{
    auto& hiddenTab = *m_tabs.get(identifier);
    RetainPtr hiddenWindowController = hiddenWindow();
    SafariWindowController *hiddenWindow = (SafariWindowController *)hiddenWindowController.get();
    id tabViewItem = hiddenTab.tabViewItem.get();
    bool selects = raise == Raise::Yes || [hiddenWindow selectedTab] == tabViewItem;

    RetainPtr windowController = hiddenTab.window.get();
    SafariWindowController *window = isOpen(windowController.get()) ? (SafariWindowController *)windowController.get() : nil;
    if (window && showsAllTabs(window) && destination == Destination::AnyWindow)
        window = nil;
    unsigned index = 0;
    if (window) {
        NSArray *tabs = [window orderedTabViewItems];
        for (NSUInteger i = 0; i < tabs.count; ++i) {
            RefPtr tabPage = pageOfTabViewItem(tabs[i]);
            if (tabPage && hiddenTab.precedingTabs.contains(tabPage->identifier()))
                index = static_cast<unsigned>(i + 1);
        }
    } else {
        for (auto& candidate : browserWindows()) {
            if (candidate.get() != hiddenWindow && !showsAllTabs(candidate.get())) {
                window = candidate.get();
                break;
            }
        }
        index = static_cast<unsigned>([window numberOfTabs]);
    }

    // Its own tab selected again, the hidden window has no hidden tab for Safari to select as this one leaves.
    if ([hiddenWindow selectedTab] == tabViewItem)
        [hiddenWindow _selectTab:m_hiddenWindowTab.get()];
    if (window) {
        [window moveTabFromOtherWindow:tabViewItem toIndex:index andSelect:selects];
        if (raise == Raise::Yes)
            [[window window] makeKeyAndOrderFront:nil];
    } else
        [hiddenWindow _moveTabToNewWindow:tabViewItem];

    if ([[hiddenWindow orderedTabViewItems] containsObject:tabViewItem])
        return false;
    m_tabs.remove(identifier);
    hiddenStateDidChange(identifier, false);
    return true;
}

void LegacyExtensionHiddenTabs::webViewDidMoveToWindow(WebPageProxy& page, NSWindow *window)
{
    RetainPtr hiddenWindowController = hiddenWindow();
    if (window && window == [hiddenWindowController window] && m_tabs.contains(page.identifier()))
        hiddenWindowChanged();
}

void LegacyExtensionHiddenTabs::hiddenWindowChanged()
{
    // Safari is amid selecting or ordering: its update of the window goes first.
    RunLoop::mainSingleton().dispatch([this] {
        RetainPtr hiddenWindowController = hiddenWindow();
        if (!hiddenWindowController)
            return;
        // A hidden tab Safari selects is shown, selected, in a window, as Firefox shows a hidden tab that is
        // selected; when Safari ordered the hidden window in to bring the tab to the front, that window comes
        // to the front instead. The hidden window leaves the screen and the Window menu, where Safari lists a
        // browser window whenever its title changes.
        NSWindow *window = [hiddenWindowController window];
        Raise raise = [window isVisible] ? Raise::Yes : Raise::No;
        id selectedTab = [(SafariWindowController *)hiddenWindowController.get() selectedTab];
        for (auto& [identifier, hiddenTab] : m_tabs) {
            if (hiddenTab->tabViewItem.get() == selectedTab) {
                showTab(identifier, Destination::AnyWindow, raise);
                break;
            }
        }
        if ([window isVisible])
            [window orderOut:nil];
        [NSApp removeWindowsItem:window];
        closeHiddenWindowIfEmpty();
    });
}

void LegacyExtensionHiddenTabs::tabViewItemDidMove()
{
    // Safari is amid moving the tab: its move completes first.
    RunLoop::mainSingleton().dispatch([this] {
        forgetShownTabs();
    });
}

// A tab can leave the hidden window by Safari's own means, which show it, such as an extension's
// SafariBrowserWindow.insertTab.
void LegacyExtensionHiddenTabs::forgetShownTabs()
{
    RetainPtr hiddenWindowController = hiddenWindow();
    NSArray *hiddenTabViewItems = [(SafariWindowController *)hiddenWindowController.get() orderedTabViewItems];
    Vector<WebPageProxyIdentifier> shownTabs;
    m_tabs.removeIf([&](auto& entry) {
        if ([hiddenTabViewItems containsObject:entry.value->tabViewItem.get()])
            return false;
        shownTabs.append(entry.key);
        return true;
    });
    for (auto identifier : shownTabs)
        hiddenStateDidChange(identifier, false);
    closeHiddenWindowIfEmpty();
}

void LegacyExtensionHiddenTabs::hiddenStateDidChange(WebPageProxyIdentifier identifier, bool hidden)
{
    if (RefPtr page = WebProcessProxy::webPage(identifier))
        LegacyExtensionHost::singleton().tabHiddenDidChange(*page, hidden);
}

// The hidden window closes with its own tab once that is all it holds.
void LegacyExtensionHiddenTabs::closeHiddenWindowIfEmpty()
{
    RetainPtr hiddenWindowController = hiddenWindow();
    SafariWindowController *hiddenWindow = (SafariWindowController *)hiddenWindowController.get();
    if (hiddenWindow && m_hiddenWindowTab && [[hiddenWindow orderedTabViewItems] isEqualToArray:@[ m_hiddenWindowTab.get() ]])
        [hiddenWindow closeTabOrWindowWithoutConfirming:[(id<LegacyExtensionSafariTabViewItem>)m_hiddenWindowTab.get() wkView]];
}

bool LegacyExtensionHiddenTabs::isHidden(WebPageProxy& page) const
{
    auto* hiddenTab = m_tabs.get(page.identifier());
    if (!hiddenTab)
        return false;
    RetainPtr hiddenWindowController = hiddenWindow();
    return [[(SafariWindowController *)hiddenWindowController.get() orderedTabViewItems] containsObject:hiddenTab->tabViewItem.get()];
}

void LegacyExtensionHiddenTabs::pageWillClose(WebPageProxy& page)
{
    if (!m_tabs.remove(page.identifier()))
        return;
    // Safari takes the closed tab out of the hidden window after this.
    RunLoop::mainSingleton().dispatch([this] {
        closeHiddenWindowIfEmpty();
    });
}

void LegacyExtensionHiddenTabs::extensionDidUnload(const String& extensionKey)
{
    forgetShownTabs();
    Vector<WebPageProxyIdentifier> identifiers;
    for (auto& [identifier, hiddenTab] : m_tabs) {
        if (hiddenTab->extensionKey == extensionKey)
            identifiers.append(identifier);
    }
    for (auto identifier : identifiers)
        showTab(identifier, Destination::AnyWindow, Raise::No);
    closeHiddenWindowIfEmpty();
}

} // namespace WebKit
