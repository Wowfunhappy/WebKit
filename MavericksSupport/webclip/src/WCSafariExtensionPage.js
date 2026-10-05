// Safari 7's extension API for an extension page of the clip's copy of Safari's extensions -- its global page
// or a popover, which the plug-in loads in WebKit 1 views as Safari does and never shows. Evaluated once per
// page with the plug-in's native object and the page's options; returns the function that hands the page a
// message from a content script of the clip's page.
//
// The clip is one browser window whose tabs are the clip's web views; it has no toolbar item, bar or menu.
// Messages cross as structured clones, as Safari's do.

(function (native, options) {
"use strict";

// Safari's extension events: listeners in registration order; each a function or an object with handleEvent.
const listenersKey = Symbol("listeners");

class SafariEventTarget {
    constructor() {
        this[listenersKey] = [];
    }

    addEventListener(type, listener, useCapture) {
        if (typeof listener !== "function" && !(listener && typeof listener.handleEvent === "function"))
            return;
        const capture = !!useCapture;
        if (!this[listenersKey].some(entry => entry.type === type && entry.listener === listener && entry.capture === capture))
            this[listenersKey].push({ type: String(type), listener, capture });
    }

    removeEventListener(type, listener, useCapture) {
        const capture = !!useCapture;
        const index = this[listenersKey].findIndex(entry => entry.type === type && entry.listener === listener && entry.capture === capture);
        if (index !== -1)
            this[listenersKey].splice(index, 1);
    }
}

const listenersFor = (target, type, phase) => target[listenersKey].filter(entry => entry.type === type && (phase === 2 || entry.capture === (phase === 1)));

// Dispatches a Safari event along its path, outermost first: capturing listeners of each ancestor, the
// target's own listeners, then the ancestors' other listeners, innermost first. Returns the event and whether
// a listener stopped its propagation.
const dispatchSafariEvent = (target, ancestors, properties) => {
    let stopped = false;
    const event = Object.assign({
        target,
        currentTarget: null,
        eventPhase: 0,
        bubbles: true,
        cancelable: true,
        defaultPrevented: false,
        timeStamp: Date.now(),
        CAPTURING_PHASE: 1,
        AT_TARGET: 2,
        BUBBLING_PHASE: 3,
        stopPropagation() {
            stopped = true;
        },
        preventDefault() {
            this.defaultPrevented = true;
        },
    }, properties);
    const invoke = (currentTarget, phase) => {
        for (const { listener } of listenersFor(currentTarget, event.type, phase)) {
            event.currentTarget = currentTarget;
            event.eventPhase = phase;
            try {
                if (typeof listener === "function")
                    listener.call(currentTarget, event);
                else
                    listener.handleEvent(event);
            } catch (error) {
                console.error(error);
            }
        }
    };
    for (const ancestor of ancestors.slice().reverse()) {
        if (!stopped)
            invoke(ancestor, 1);
    }
    if (!stopped)
        invoke(target, 2);
    for (const ancestor of ancestors) {
        if (!stopped)
            invoke(ancestor, 3);
    }
    return { event, stopped };
};

// Safari's exceptions for empty arguments and for URLs outside the extension.
const nonEmpty = (value, what) => {
    const string = value === undefined || value === null ? "" : String(value);
    if (!string)
        throw `${what} cannot be empty.`;
    return string;
};
const extensionURL = url => {
    const string = nonEmpty(url, "url");
    if (!string.startsWith(options.baseURI))
        throw "url needs to be a safari-extension:// URL for this extension.";
    return string;
};

const application = new SafariEventTarget();

// The clip's window, whose active tab is the web view the clip shows.
const browserWindow = new SafariEventTarget();
Object.defineProperties(browserWindow, {
    tabs: { get: () => native.tabs().map(tabForToken), enumerable: true },
    activeTab: {
        get: () => {
            const tokens = native.tabs();
            return tokens.length ? tabForToken(tokens[tokens.length - 1]) : null;
        },
        enumerable: true,
    },
});
Object.assign(browserWindow, {
    visible: true,
    activate() { },
    close() { },
    insertTab() { },
    openTab() {
        return null;
    },
});

// A web view of the clip as a SafariBrowserTab: its URL navigates it, and its page receives the messages the
// extension dispatches to it.
const tabs = new Map();
const tabPath = [browserWindow, application];
const tabForToken = token => {
    let tab = tabs.get(token);
    if (tab)
        return tab;
    tab = new SafariEventTarget();
    Object.defineProperties(tab, {
        url: {
            get: () => native.tabURL(token),
            set: url => native.setTabURL(token, nonEmpty(url, "url")),
            enumerable: true,
        },
        title: {
            get: () => native.tabTitle(token),
            enumerable: true,
        },
    });
    Object.assign(tab, {
        browserWindow,
        reader: undefined,
        page: {
            dispatchMessage(name, message) {
                native.dispatchMessageToTab(token, nonEmpty(name, "Message name"), message);
            },
        },
        activate() { },
        close() { },
        visibleContentsAsDataURL(callback) {
            if (typeof callback !== "function")
                throw "callback must be a function.";
            native.visibleContentsOfTab(token, callback);
        },
    });
    tabs.set(token, tab);
    return tab;
};

// Settings: JSON values the copy keeps, read as properties too. A stored null is a value; a setting with none
// reads as undefined. The runtime tells every page of the extension of a change.
const settingsStore = () => {
    const store = new SafariEventTarget();
    let settings;
    const read = key => {
        const json = native.setting(String(key));
        return json === undefined || json === null ? undefined : JSON.parse(json);
    };
    const write = (key, value) => {
        if (value === undefined)
            native.removeSetting(key);
        else
            native.setSetting(key, JSON.stringify(value));
    };
    const methods = {
        getItem(key) {
            const value = read(String(key));
            return value === undefined ? null : value;
        },
        setItem: (key, value) => write(String(key), value),
        removeItem: key => write(String(key), undefined),
        clear() {
            for (const key of native.settingNames())
                write(key, undefined);
        },
        addEventListener: store.addEventListener.bind(store),
        removeEventListener: store.removeEventListener.bind(store),
    };
    settings = new Proxy(store, {
        get(target, property) {
            if (typeof property !== "string")
                return target[property];
            if (Object.prototype.hasOwnProperty.call(methods, property))
                return methods[property];
            const value = read(property);
            return value === undefined ? target[property] : value;
        },
        set(target, property, value) {
            if (typeof property !== "string")
                return false;
            write(property, value);
            return true;
        },
        deleteProperty(target, property) {
            write(String(property), undefined);
            return true;
        },
        has(target, property) {
            return typeof property === "string" && (property in methods || read(property) !== undefined);
        },
        ownKeys() {
            return native.settingNames();
        },
        getOwnPropertyDescriptor(target, property) {
            const value = typeof property === "string" ? read(property) : undefined;
            return value === undefined ? undefined : { value, writable: true, enumerable: true, configurable: true };
        },
    });
    return settings;
};

// Secure settings: a clip keeps none. Reading or writing one throws, as Safari throws its API's errors.
const secureSettingsStore = () => {
    const unavailable = () => {
        throw "Secure settings are not available in Web Clips.";
    };
    const store = new SafariEventTarget();
    Object.assign(store, { getItem: unavailable, setItem: unavailable, removeItem: unavailable, clear: unavailable });
    return new Proxy(store, {
        get(target, property) {
            return typeof property !== "string" || property in target ? target[property] : unavailable();
        },
        set: unavailable,
        deleteProperty: unavailable,
        has(target, property) {
            return typeof property !== "string" || property in target ? property in target : unavailable();
        },
    });
};

// The extension's popovers, whose pages the plug-in keeps loaded; the clip never shows one.
const popoverObjects = new Map();
const popover = ({ identifier, url, width, height }) => {
    let object = popoverObjects.get(identifier);
    if (!object) {
        object = new SafariEventTarget();
        Object.defineProperty(object, "contentWindow", { get: () => native.popoverWindow(identifier), enumerable: true });
        Object.assign(object, { identifier, visible: false, hide() { } });
        popoverObjects.set(identifier, object);
    }
    Object.assign(object, { url, width, height });
    return object;
};
const popovers = () => {
    const descriptions = native.popovers();
    for (const identifier of Array.from(popoverObjects.keys())) {
        if (!descriptions.some(description => description.identifier === identifier))
            popoverObjects.delete(identifier);
    }
    return descriptions.map(popover);
};

const contentList = patterns => Array.isArray(patterns) ? patterns.map(String) : [];

Object.defineProperties(application, {
    browserWindows: { get: () => [browserWindow], enumerable: true },
    activeBrowserWindow: { get: () => browserWindow, enumerable: true },
});
Object.assign(application, {
    privateBrowsing: { enabled: false },
    openBrowserWindow() {
        return null;
    },
});

const extension = {
    baseURI: options.baseURI,
    bundleVersion: options.bundleVersion,
    displayVersion: options.displayVersion,
    globalPage: options.hasGlobalPage ? { get contentWindow() { return options.isGlobalPage ? window : native.globalPageWindow(); } } : null,
    settings: settingsStore(),
    secureSettings: secureSettingsStore(),
    toolbarItems: [],
    bars: [],
    menus: [],
    get popovers() {
        return popovers();
    },
    createPopover(identifier, url, width, height) {
        const description = { identifier: nonEmpty(identifier, "identifier"), url: extensionURL(url), width, height };
        native.createPopover(description.identifier, description.url, typeof width === "number" ? width : undefined, typeof height === "number" ? height : undefined);
        popoverObjects.delete(description.identifier);
        return popover(description);
    },
    removePopover(identifier) {
        native.removePopover(nonEmpty(identifier, "identifier"));
        popoverObjects.delete(String(identifier));
    },
    addContentScript(source, whitelist, blacklist, runAtEnd) {
        return native.addContent("script", nonEmpty(source, "source"), "", contentList(whitelist), contentList(blacklist), !!runAtEnd);
    },
    addContentScriptFromURL(url, whitelist, blacklist, runAtEnd) {
        return native.addContent("script", "", extensionURL(url), contentList(whitelist), contentList(blacklist), !!runAtEnd);
    },
    addContentStyleSheet(source, whitelist, blacklist) {
        return native.addContent("sheet", nonEmpty(source, "source"), "", contentList(whitelist), contentList(blacklist), false);
    },
    addContentStyleSheetFromURL(url, whitelist, blacklist) {
        return native.addContent("sheet", "", extensionURL(url), contentList(whitelist), contentList(blacklist), false);
    },
    removeContentScript(url) {
        native.removeContent("script", extensionURL(url));
    },
    removeContentScripts() {
        native.removeContent("script", "");
    },
    removeContentStyleSheet(url) {
        native.removeContent("sheet", extensionURL(url));
    },
    removeContentStyleSheets() {
        native.removeContent("sheet", "");
    },
};

const ownPopover = options.popover !== undefined ? popovers().find(candidate => candidate.identifier === options.popover) : undefined;
Object.defineProperty(window, "safari", { value: { application, extension, self: ownPopover || new SafariEventTarget() }, writable: true, configurable: true });

const fromJSON = json => json === null || json === undefined ? null : JSON.parse(json);

// The runtime's events for the page.
return {
    // A content script's message, from a page of the clip: it goes from the page's tab out through the window
    // to the application. Returns the message the event ends with and whether a listener stopped its
    // propagation.
    message(token, name, message) {
        const { event, stopped } = dispatchSafariEvent(tabForToken(token), tabPath, { type: "message", name, message });
        return [event.message, stopped];
    },
    // beforeNavigate, before a tab's page navigates to the URL, and navigate, once it has loaded. Returns
    // whether a listener prevented the navigation.
    navigation(token, type, url) {
        const { event } = dispatchSafariEvent(tabForToken(token), tabPath, type === "beforeNavigate" ? { type, url } : { type });
        return event.defaultPrevented;
    },
    settingChanged(key, oldValue, newValue) {
        dispatchSafariEvent(extension.settings, [], { type: "change", key, oldValue: fromJSON(oldValue), newValue: fromJSON(newValue) });
    },
};
})
