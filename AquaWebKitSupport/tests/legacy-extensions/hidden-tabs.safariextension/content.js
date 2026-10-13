// A page of the server asks for an operation with window.postMessage({ hiddenTabs: operation, args }); the
// global page's answer lands in the page's window.__hiddenTabsResult, as JSON.
window.addEventListener("message", event => {
    if (event.source !== window || !event.data || !event.data.hiddenTabs)
        return;
    safari.self.tab.dispatchMessage("hiddenTabs", { operation: event.data.hiddenTabs, args: event.data.args || [] });
});

safari.self.addEventListener("message", event => {
    if (event.name !== "hiddenTabsResult")
        return;
    const script = document.createElement("script");
    script.textContent = "window.__hiddenTabsResult = " + JSON.stringify(JSON.stringify(event.message)) + ";";
    document.documentElement.appendChild(script);
    script.remove();
}, false);
