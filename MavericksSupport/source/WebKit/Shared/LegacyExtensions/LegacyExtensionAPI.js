// The `browser` namespace WebKit gives Safari 7 legacy extensions, shaped after the WebExtensions API.
//
// Evaluated once per extension context. `kind` is "host" for the extension's own pages -- the global page
// and toolbar popovers, which Safari hosts in WebKit 1 views, and pages opened in tabs or frames -- and
// "content" for content scripts. `native.send(json)` hands one message to the LegacyExtension router;
// the returned function receives the router's messages, one JSON string at a time. Everything crossing that boundary is JSON, so messages carry exactly what
// Chrome's extension messaging carries.

(function (native, kind) {
"use strict";

const isHost = kind === "host";

const send = message => native.send(JSON.stringify(message));

const randomId = () => {
    const words = new Uint32Array(4);
    crypto.getRandomValues(words);
    return Array.from(words, word => word.toString(36)).join("");
};

let lastError;
const withLastError = (message, callback) => {
    lastError = message === undefined ? undefined : { message };
    try {
        callback();
    } finally {
        lastError = undefined;
    }
};

const errorMessage = error => String(error && error.message !== undefined ? error.message : error);

// Promise-returning API methods also take a trailing callback, as Chrome's do.
const withOptionalCallback = (args, run) => {
    const callback = typeof args[args.length - 1] === "function" ? args.pop() : undefined;
    const promise = run(...args);
    if (!callback)
        return promise;
    promise.then(result => withLastError(undefined, () => callback(result)), error => withLastError(errorMessage(error), () => callback()));
    return undefined;
};

const eventInterestNames = new Set();
let interestUpdateScheduled = false;
const scheduleInterestUpdate = () => {
    if (interestUpdateScheduled)
        return;
    interestUpdateScheduled = true;
    queueMicrotask(() => {
        interestUpdateScheduled = false;
        const events = {};
        for (const [name, event] of trackedEvents) {
            if (!event.hasListeners())
                continue;
            const blockingFilters = event._listeners.filter(entry => Array.isArray(entry.extraInfoSpec) && entry.extraInfoSpec.includes("blocking")).map(({ filter }) => {
                if (!filter || typeof filter !== "object")
                    return {};
                const { urls, types, tabId } = filter;
                return { urls: Array.isArray(urls) ? urls : undefined, types: Array.isArray(types) ? types : undefined, tabId: typeof tabId === "number" ? tabId : undefined };
            });
            events[name] = blockingFilters.length ? { blockingFilters } : {};
        }
        send({ t: "interest", events });
    });
};

class Event {
    constructor(name) {
        this._listeners = [];
        this._name = name;
    }

    addListener(callback, filter, extraInfoSpec) {
        if (typeof callback !== "function")
            throw new TypeError("Event listener must be a function");
        if (this.hasListener(callback))
            return;
        this._listeners.push({ callback, filter, extraInfoSpec });
        if (this._name)
            scheduleInterestUpdate();
    }

    removeListener(callback) {
        const index = this._listeners.findIndex(entry => entry.callback === callback);
        if (index === -1)
            return;
        this._listeners.splice(index, 1);
        if (this._name)
            scheduleInterestUpdate();
    }

    hasListener(callback) {
        return this._listeners.some(entry => entry.callback === callback);
    }

    hasListeners() {
        return this._listeners.length !== 0;
    }

    _fire(...args) {
        for (const { callback } of this._listeners.slice()) {
            try {
                callback(...args);
            } catch (error) {
                console.error(error);
            }
        }
    }
}

const trackedEvents = new Map();
const trackedEvent = name => {
    const event = new Event(name);
    trackedEvents.set(name, event);
    return event;
};

// Ports.

const ports = new Map();

class Port {
    constructor(portId, name, sender) {
        this.name = name;
        if (sender !== undefined)
            this.sender = sender;
        this.onMessage = new Event();
        this.onDisconnect = new Event();
        this._portId = portId;
        this._connected = true;
        ports.set(portId, this);
    }

    postMessage(message) {
        if (!this._connected)
            throw new Error("Attempting to use a disconnected port object");
        send({ t: "post", portId: this._portId, msg: message });
    }

    disconnect() {
        if (!this._connected)
            return;
        this._connected = false;
        ports.delete(this._portId);
        send({ t: "disconnect", portId: this._portId });
    }

    _didReceiveMessage(message) {
        this.onMessage._fire(message, this);
    }

    _didDisconnect(error) {
        if (!this._connected)
            return;
        this._connected = false;
        ports.delete(this._portId);
        withLastError(error, () => this.onDisconnect._fire(this));
    }
}

const connect = (name, target) => {
    const port = new Port(randomId(), name === undefined ? "" : String(name));
    send(Object.assign({ t: "connect", portId: port._portId, name: port.name }, target));
    return port;
};

// One-shot messages.

const pendingReplies = new Map();

const sendMessage = (message, target) => new Promise((resolve, reject) => {
    const msgId = randomId();
    pendingReplies.set(msgId, { resolve, reject });
    send(Object.assign({ t: "message", msgId, msg: message }, target));
});

const onMessage = trackedEvent("runtime.onMessage");
const onConnect = trackedEvent("runtime.onConnect");

const didReceiveOneShotMessage = ({ msgId, msg, sender }) => {
    let responded = false;
    const respond = reply => {
        if (responded)
            return;
        responded = true;
        send(Object.assign({ t: "reply", msgId }, reply));
    };
    const sendResponse = response => respond({ response });
    let willRespondAsynchronously = false;
    for (const { callback } of onMessage._listeners.slice()) {
        let result;
        try {
            result = callback(msg, sender, sendResponse);
        } catch (error) {
            console.error(error);
            continue;
        }
        if (result === true)
            willRespondAsynchronously = true;
        else if (result && typeof result.then === "function") {
            willRespondAsynchronously = true;
            result.then(sendResponse, error => respond({ error: errorMessage(error) }));
        }
    }
    if (!willRespondAsynchronously)
        respond({ none: true });
};

// Router calls.

const pendingCalls = new Map();
let nextCallIdentifier = 1;

const callRouter = (method, ...args) => new Promise((resolve, reject) => {
    const callId = nextCallIdentifier++;
    pendingCalls.set(callId, { resolve, reject });
    send({ t: "call", callId, method, args });
});

// Match patterns (https://developer.chrome.com/docs/extensions/develop/concepts/match-patterns).

const escapeForRegExp = string => string.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

const compileMatchPattern = pattern => {
    if (pattern === "<all_urls>")
        return /^(?:https?|wss?|ftp|file|data|safari-extension):/;
    const match = /^(\*|[a-z][a-z0-9+.-]*):\/\/(\*|\*\.[^/*]+|[^/*]+)?(\/.*)$/.exec(pattern);
    if (!match)
        return null;
    const [, scheme, host = "", path] = match;
    const schemeSource = scheme === "*" ? "(?:https?|wss?)" : escapeForRegExp(scheme);
    let hostSource;
    if (host === "*")
        hostSource = "[^/]*";
    else if (host.startsWith("*."))
        hostSource = `(?:[^/]*\\.)?${escapeForRegExp(host.slice(2))}(?::\\d+)?`;
    else
        hostSource = `${escapeForRegExp(host)}(?::\\d+)?`;
    const pathSource = path.split("*").map(escapeForRegExp).join(".*");
    return new RegExp(`^${schemeSource}://${hostSource}${pathSource}$`);
};

const compiledFilters = new WeakMap();
const filterMatches = (filter, details) => {
    if (!filter || typeof filter !== "object")
        return true;
    if (typeof filter.tabId === "number" && filter.tabId !== details.tabId)
        return false;
    if (Array.isArray(filter.types) && !filter.types.includes(details.type))
        return false;
    if (!Array.isArray(filter.urls))
        return true;
    let patterns = compiledFilters.get(filter);
    if (!patterns) {
        patterns = filter.urls.map(compileMatchPattern).filter(Boolean);
        compiledFilters.set(filter, patterns);
    }
    const url = details.url;
    return patterns.some(pattern => pattern.test(url));
};

// webRequest listeners run in registration order; their blocking responses merge as Chrome merges
// the responses of one extension: any cancel wins, the first redirect wins, header rewrites stack.
const dispatchWebRequestEvent = async (event, details) => {
    const response = {};
    for (const { callback, filter, extraInfoSpec } of event._listeners.slice()) {
        if (!filterMatches(filter, details))
            continue;
        const blocking = Array.isArray(extraInfoSpec) && extraInfoSpec.includes("blocking");
        let result;
        try {
            result = callback(Object.assign({}, details));
            if (blocking && result && typeof result.then === "function")
                result = await result;
        } catch (error) {
            console.error(error);
            continue;
        }
        if (!blocking || !result || typeof result !== "object")
            continue;
        if (result.cancel === true)
            response.cancel = true;
        if (typeof result.redirectUrl === "string" && response.redirectUrl === undefined)
            response.redirectUrl = result.redirectUrl;
        if (Array.isArray(result.requestHeaders)) {
            response.requestHeaders = result.requestHeaders;
            details.requestHeaders = result.requestHeaders;
        }
        if (Array.isArray(result.responseHeaders)) {
            response.responseHeaders = result.responseHeaders;
            details.responseHeaders = result.responseHeaders;
        }
    }
    return response;
};

// Namespaces.

const browser = {};

browser.runtime = {
    get lastError() {
        return lastError;
    },
    connect(...args) {
        const connectInfo = args.find(argument => argument && typeof argument === "object") || {};
        return connect(connectInfo.name);
    },
    sendMessage(...args) {
        return withOptionalCallback(args, message => sendMessage(message, { }));
    },
    onConnect,
    onMessage,
};

if (!isHost) {
    const runWhen = (runAt, callback) => {
        const readyState = document.readyState;
        if (runAt === "document_start" || (runAt === "document_end" && readyState !== "loading"))
            return callback();
        if (readyState === "loading") {
            document.addEventListener("DOMContentLoaded", () => runWhen(runAt === "document_idle" ? "document_idle" : "document_end", callback), { once: true });
            return;
        }
        setTimeout(callback, 0);
    };

    const didReceiveExecuteScript = ({ callId, code, runAt }) => runWhen(runAt || "document_idle", () => {
        let result;
        try {
            result = (0, eval)(code);
        } catch (exception) {
            send({ t: "result", callId, error: errorMessage(exception) });
            return;
        }
        try {
            send({ t: "result", callId, result });
        } catch {
            send({ t: "result", callId, result: null });
        }
    });

    // A file's style sheet is based at the file; code's, as upstream's, has a URL of its own.
    const didReceiveStyleSheet = ({ callId, op, code, origin, url, runAt }) => runWhen(runAt || "document_idle", () => {
        if (op === "insert")
            native.insertCSS(code, origin === "author", url || "");
        else
            native.removeCSS(code);
        send({ t: "result", callId });
    });

    browser.dom = {
        openOrClosedShadowRoot(element) {
            return element.openOrClosedShadowRoot;
        },
    };

    // The frame ID of a window or of a frame element's content, as webRequest and webNavigation report it.
    browser.runtime.getFrameId = target => {
        const frameId = native.frameId(target);
        if (typeof frameId !== "number" || frameId < 0)
            throw new Error("Invalid target");
        return frameId;
    };

    Object.assign(receiverTable(), {
        exec: didReceiveExecuteScript,
        css: didReceiveStyleSheet,
    });
}

if (isHost) {
    const webRequestEventNames = ["onBeforeRequest", "onBeforeSendHeaders", "onSendHeaders", "onHeadersReceived", "onResponseStarted", "onBeforeRedirect", "onCompleted", "onErrorOccurred"];
    browser.webRequest = {
        ResourceType: {
            MAIN_FRAME: "main_frame",
            SUB_FRAME: "sub_frame",
            STYLESHEET: "stylesheet",
            SCRIPT: "script",
            IMAGE: "image",
            FONT: "font",
            OBJECT: "object",
            XMLHTTPREQUEST: "xmlhttprequest",
            PING: "ping",
            CSP_REPORT: "csp_report",
            MEDIA: "media",
            WEBSOCKET: "websocket",
            OTHER: "other",
        },
        MAX_HANDLER_BEHAVIOR_CHANGED_CALLS_PER_10_MINUTES: 20,
        handlerBehaviorChanged(...args) {
            return withOptionalCallback(args, () => callRouter("webRequest.handlerBehaviorChanged"));
        },
    };
    for (const name of webRequestEventNames)
        browser.webRequest[name] = trackedEvent(`webRequest.${name}`);

    browser.webNavigation = {
        onCommitted: trackedEvent("webNavigation.onCommitted"),
        onDOMContentLoaded: trackedEvent("webNavigation.onDOMContentLoaded"),
        onCreatedNavigationTarget: trackedEvent("webNavigation.onCreatedNavigationTarget"),
        getFrame(...args) {
            return withOptionalCallback(args, details => callRouter("webNavigation.getFrame", details));
        },
        getAllFrames(...args) {
            return withOptionalCallback(args, details => callRouter("webNavigation.getAllFrames", details));
        },
    };

    const extensionBaseURL = () => {
        const safari = globalThis.safari;
        return safari && safari.extension && safari.extension.baseURI ? safari.extension.baseURI : location.href;
    };
    const resourceURL = path => new URL(String(path).replace(/^\/+/, ""), extensionBaseURL()).href;
    const resourceText = async path => {
        const response = await fetch(resourceURL(path));
        return response.text();
    };
    const injectionTarget = details => ({
        allFrames: details.allFrames === true,
        frameId: typeof details.frameId === "number" ? details.frameId : 0,
        matchAboutBlank: details.matchAboutBlank === true,
        runAt: details.runAt || "document_idle",
    });

    browser.tabs = {
        get(...args) {
            return withOptionalCallback(args, tabId => callRouter("tabs.get", tabId).then(tab => {
                if (!tab)
                    throw new Error(`No tab with id: ${tabId}.`);
                return tab;
            }));
        },
        remove(...args) {
            return withOptionalCallback(args, tabIds => callRouter("tabs.remove", Array.isArray(tabIds) ? tabIds : [tabIds]));
        },
        reload(...args) {
            return withOptionalCallback(args, (tabId, reloadProperties) => callRouter("tabs.reload", tabId, reloadProperties || {}));
        },
        update(...args) {
            return withOptionalCallback(args, (tabId, updateProperties) => callRouter("tabs.update", tabId, updateProperties || {}));
        },
        executeScript(...args) {
            return withOptionalCallback(args, async (tabId, details = {}) => {
                const code = typeof details.file === "string" ? await resourceText(details.file) : String(details.code);
                return callRouter("tabs.executeScript", tabId, Object.assign(injectionTarget(details), { code }));
            });
        },
        insertCSS(...args) {
            return withOptionalCallback(args, async (tabId, details = {}) => {
                const isFile = typeof details.file === "string";
                const code = isFile ? await resourceText(details.file) : String(details.code);
                await callRouter("tabs.insertCSS", tabId, Object.assign(injectionTarget(details), { code, cssOrigin: details.cssOrigin === "user" ? "user" : "author", url: isFile ? resourceURL(details.file) : undefined }));
            });
        },
        removeCSS(...args) {
            return withOptionalCallback(args, async (tabId, details = {}) => {
                const isFile = typeof details.file === "string";
                const code = isFile ? await resourceText(details.file) : String(details.code);
                await callRouter("tabs.removeCSS", tabId, Object.assign(injectionTarget(details), { code, cssOrigin: details.cssOrigin === "user" ? "user" : "author", url: isFile ? resourceURL(details.file) : undefined }));
            });
        },
        sendMessage(...args) {
            return withOptionalCallback(args, (tabId, message, options = {}) => sendMessage(message, { tabId, frameId: typeof options.frameId === "number" ? options.frameId : undefined }));
        },
        connect(tabId, connectInfo = {}) {
            return connect(connectInfo.name, { tabId, frameId: typeof connectInfo.frameId === "number" ? connectInfo.frameId : undefined });
        },
        onCreated: trackedEvent("tabs.onCreated"),
        onRemoved: trackedEvent("tabs.onRemoved"),
        onUpdated: trackedEvent("tabs.onUpdated"),
    };
}

// Incoming messages.

function receiverTable() {
    if (!receiverTable.table) {
        receiverTable.table = {
            connect({ portId, name, sender }) {
                const port = new Port(portId, name, sender);
                if (!onConnect.hasListeners()) {
                    port._connected = false;
                    ports.delete(portId);
                    send({ t: "disconnect", portId });
                    return;
                }
                onConnect._fire(port);
            },
            post({ portId, msg }) {
                const port = ports.get(portId);
                if (port)
                    port._didReceiveMessage(msg);
            },
            disconnect({ portId, error }) {
                const port = ports.get(portId);
                if (port)
                    port._didDisconnect(error);
            },
            message: didReceiveOneShotMessage,
            reply({ msgId, response, error, none }) {
                const pending = pendingReplies.get(msgId);
                if (!pending)
                    return;
                pendingReplies.delete(msgId);
                if (error !== undefined)
                    pending.reject(new Error(error));
                else
                    pending.resolve(none ? undefined : response);
            },
            result({ callId, result, error }) {
                const pending = pendingCalls.get(callId);
                if (!pending)
                    return;
                pendingCalls.delete(callId);
                if (error !== undefined)
                    pending.reject(new Error(error));
                else
                    pending.resolve(result);
            },
            exec({ callId }) {
                send({ t: "result", callId, error: "Cannot access the contents of an extension page." });
            },
            css({ callId }) {
                send({ t: "result", callId, error: "Cannot access the contents of an extension page." });
            },
            event({ name, args, token }) {
                const event = trackedEvents.get(name);
                if (name.startsWith("webRequest.")) {
                    const dispatch = event ? dispatchWebRequestEvent(event, args[0]) : Promise.resolve({});
                    if (token !== undefined)
                        dispatch.then(result => send({ t: "respond", token, result }), () => send({ t: "respond", token, result: {} }));
                    return;
                }
                if (event)
                    event._fire(...args);
            },
        };
    }
    return receiverTable.table;
}

Object.defineProperty(globalThis, "browser", { value: browser, writable: true, configurable: true, enumerable: false });

return json => {
    const message = JSON.parse(json);
    const handler = receiverTable()[message.t];
    if (handler)
        handler(message);
};
})
