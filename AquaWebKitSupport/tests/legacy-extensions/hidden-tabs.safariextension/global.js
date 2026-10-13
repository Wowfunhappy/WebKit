// Operations the server's pages ask for:
//   state: the windows Safari's extension API lists, each with whether it is visible and the URLs of its
//          tabs, and the hidden tabs.
//   hideOthers: hides every tab of the active window but its active one, by SafariBrowserTab.
//   hideActive: hides the active tab, which stays shown.
//   hideIds / showIds: hides or shows the tabs of the given IDs.
//   showAll: shows every hidden tab.
//   showThenHide: shows the tabs of the given IDs and hides them again as soon as that is done.
//   hideBlank: opens a blank background tab in the active window and hides it.
//   removeIds: closes the tabs of the given IDs with browser.tabs.remove.
//   activateHidden: activates the first hidden tab with Safari's extension API.
//   openProbeTab: opens probe.html in a new tab of the active window.
const state = async () => ({
    windows: safari.application.browserWindows.map(window => ({ visible: window.visible, tabs: window.tabs.map(tab => tab.url) })),
    hidden: await aqua.tabs.getHidden(),
});

const operations = {
    state,
    hideOthers: () => {
        const window = safari.application.activeBrowserWindow;
        return aqua.tabs.hide(window.tabs.filter(tab => tab !== window.activeTab));
    },
    hideActive: () => aqua.tabs.hide(safari.application.activeBrowserWindow.activeTab),
    hideIds: ids => aqua.tabs.hide(ids),
    showIds: async ids => {
        await aqua.tabs.show(ids);
        return state();
    },
    showThenHide: async ids => {
        await aqua.tabs.show(ids);
        return aqua.tabs.hide(ids);
    },
    hideBlank: () => aqua.tabs.hide(safari.application.activeBrowserWindow.openTab("background")),
    removeIds: async ids => {
        await browser.tabs.remove(ids);
        return state();
    },
    activateHidden: async () => {
        const hiddenWindow = safari.application.browserWindows.find(window => !window.visible);
        hiddenWindow.tabs[1].activate();
        return state();
    },
    openProbeTab: () => {
        safari.application.activeBrowserWindow.openTab("background").url = safari.extension.baseURI + "probe.html";
    },
    showAll: async () => {
        const hidden = await aqua.tabs.getHidden();
        await aqua.tabs.show(hidden.map(tab => tab.id));
        return state();
    },
};

safari.application.addEventListener("message", async event => {
    if (event.name !== "hiddenTabs")
        return;
    const { operation, args } = event.message;
    let result;
    try {
        result = { value: await operations[operation](...args) };
    } catch (error) {
        result = { error: String(error && error.message || error) };
    }
    event.target.page.dispatchMessage("hiddenTabsResult", result);
}, false);
