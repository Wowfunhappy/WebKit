// The `browser` namespace WebKit gives Safari 7 legacy extensions, shaped after the WebExtensions API, and
// the clipboard access their pages have.
//
// Evaluated once per extension context. `kind` is "host" for the extension's own pages -- the global page
// and toolbar popovers, which Safari hosts in WebKit 1 views, and pages opened in tabs or frames -- and
// "content" for content scripts. `native.send(json)` hands one message to the LegacyExtension router;
// the returned function receives the router's messages, one JSON string at a time. Everything crossing
// that boundary is JSON, so messages carry exactly what Chrome's extension messaging carries.

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

const hasExtraInfo = ({ extraInfoSpec }, name) => Array.isArray(extraInfoSpec) && extraInfoSpec.includes(name);
// A listener whose answer the load waits for: its return value, or with "asyncBlocking" (onAuthRequired's)
// the argument it passes the callback it receives.
const isBlocking = entry => hasExtraInfo(entry, "blocking") || hasExtraInfo(entry, "asyncBlocking");

// The router learns of a listener as it is added, so a request the context makes next reaches it.
const updateInterest = () => {
    const events = {};
    for (const [name, event] of trackedEvents) {
        if (!event.hasListeners())
            continue;
        const blockingFilters = event._listeners.filter(isBlocking).map(({ filter }) => {
            if (!filter || typeof filter !== "object")
                return {};
            const { urls, types, tabId } = filter;
            return { urls: Array.isArray(urls) ? urls : undefined, types: Array.isArray(types) ? types : undefined, tabId: typeof tabId === "number" ? tabId : undefined };
        });
        const interest = blockingFilters.length ? { blockingFilters } : {};
        for (const option of ["requestBody", "extraHeaders"]) {
            if (event._listeners.some(entry => hasExtraInfo(entry, option)))
                interest[option] = true;
        }
        events[name] = interest;
    }
    send({ t: "interest", events });
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
            updateInterest();
    }

    removeListener(callback) {
        const index = this._listeners.findIndex(entry => entry.callback === callback);
        if (index === -1)
            return;
        this._listeners.splice(index, 1);
        if (this._name)
            updateInterest();
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

// Details a listener receives only when its extraInfoSpec asks for them.
const optionalDetails = ["requestBody", "requestHeaders", "responseHeaders"];

// Headers a listener sees, and can change, only with "extraHeaders", as in Chrome. A verdict from another
// listener keeps them as they are.
const extraHeaderNames = {
    requestHeaders: new Set(["accept-language", "accept-encoding", "referer", "cookie", "origin"]),
    responseHeaders: new Set(["set-cookie"]),
};
const isExtraHeader = (kind, { name }) => extraHeaderNames[kind].has(String(name).toLowerCase());

// requestBody's raw bytes arrive in base64.
const decodeRequestBody = details => {
    const raw = details.requestBody && details.requestBody.raw;
    if (!Array.isArray(raw))
        return;
    for (const element of raw) {
        if (typeof element.bytes === "string")
            element.bytes = Uint8Array.from(atob(element.bytes), character => character.charCodeAt(0)).buffer;
    }
};

// webRequest listeners run in registration order; their blocking responses merge as Chrome merges
// the responses of one extension: any cancel wins, the first redirect and the first credentials win,
// header rewrites stack.
const dispatchWebRequestEvent = async (event, details) => {
    decodeRequestBody(details);
    const response = {};
    for (const entry of event._listeners.slice()) {
        const { callback, filter } = entry;
        if (!filterMatches(filter, details))
            continue;
        const blocking = isBlocking(entry);
        const listenerDetails = Object.assign({}, details);
        for (const name of optionalDetails) {
            if (!hasExtraInfo(entry, name))
                delete listenerDetails[name];
        }
        const extraHeaders = hasExtraInfo(entry, "extraHeaders");
        for (const kind of Object.keys(extraHeaderNames)) {
            if (!extraHeaders && Array.isArray(listenerDetails[kind]))
                listenerDetails[kind] = listenerDetails[kind].filter(header => !isExtraHeader(kind, header));
        }
        let result;
        try {
            if (hasExtraInfo(entry, "asyncBlocking"))
                result = await new Promise(resolve => callback(listenerDetails, resolve));
            else {
                result = callback(listenerDetails);
                if (blocking && result && typeof result.then === "function")
                    result = await result;
            }
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
        if (result.authCredentials && typeof result.authCredentials === "object" && response.authCredentials === undefined)
            response.authCredentials = { username: String(result.authCredentials.username), password: String(result.authCredentials.password) };
        for (const kind of Object.keys(extraHeaderNames)) {
            if (!Array.isArray(result[kind]))
                continue;
            const headers = extraHeaders || !Array.isArray(details[kind]) ? result[kind] : result[kind].filter(header => !isExtraHeader(kind, header)).concat(details[kind].filter(header => isExtraHeader(kind, header)));
            response[kind] = headers;
            details[kind] = headers;
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

    // about:blank and about:srcdoc documents, whatever their query and fragment, are reached only with
    // matchAboutBlank.
    const isAboutBlankOrSrcdoc = () => {
        const url = new URL(document.URL);
        return url.protocol === "about:" && (url.pathname === "blank" || url.pathname === "srcdoc");
    };
    const isReachable = matchAboutBlank => matchAboutBlank || !isAboutBlankOrSrcdoc();
    const unreachable = callId => send({ t: "result", callId, error: `Cannot access contents of url "${document.URL}".` });

    const didReceiveExecuteScript = ({ callId, code, runAt, matchAboutBlank }) => isReachable(matchAboutBlank) ? runWhen(runAt || "document_idle", () => {
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
    }) : unreachable(callId);

    // A file's style sheet is based at the file; code's, as upstream's, has a URL of its own.
    const didReceiveStyleSheet = ({ callId, op, code, origin, url, runAt, matchAboutBlank }) => isReachable(matchAboutBlank) ? runWhen(runAt || "document_idle", () => {
        if (op === "insert")
            native.insertCSS(code, origin === "author", url || "");
        else
            native.removeCSS(code);
        send({ t: "result", callId });
    }) : unreachable(callId);

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
    const webRequestEventNames = ["onBeforeRequest", "onBeforeSendHeaders", "onSendHeaders", "onHeadersReceived", "onAuthRequired", "onResponseStarted", "onBeforeRedirect", "onCompleted", "onErrorOccurred"];
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
        onBeforeNavigate: trackedEvent("webNavigation.onBeforeNavigate"),
        onCommitted: trackedEvent("webNavigation.onCommitted"),
        onDOMContentLoaded: trackedEvent("webNavigation.onDOMContentLoaded"),
        onCompleted: trackedEvent("webNavigation.onCompleted"),
        onErrorOccurred: trackedEvent("webNavigation.onErrorOccurred"),
        onCreatedNavigationTarget: trackedEvent("webNavigation.onCreatedNavigationTarget"),
        getFrame(...args) {
            return withOptionalCallback(args, details => callRouter("webNavigation.getFrame", details));
        },
        getAllFrames(...args) {
            return withOptionalCallback(args, details => callRouter("webNavigation.getAllFrames", details));
        },
    };

    // A path within the extension, from its root.
    const resourceURL = path => new URL(`/${String(path).replace(/^\/+/, "")}`, location.href).href;
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

    // cookies. The router reads and writes a cookie store within the extension's website access; matching a
    // URL and the details' filters is Chrome's cookies API over the cookies it answers with.
    const domainMatches = (host, domain) => {
        const bare = domain.replace(/^\./, "").toLowerCase();
        host = host.toLowerCase();
        return host === bare || (domain.startsWith(".") && host.endsWith(`.${bare}`));
    };
    const isDomainOrSubdomain = (domain, ancestor) => {
        const bare = domain.replace(/^\./, "").toLowerCase();
        const bareAncestor = ancestor.replace(/^\./, "").toLowerCase();
        return bare === bareAncestor || bare.endsWith(`.${bareAncestor}`);
    };
    const pathMatches = (path, cookiePath) => path === cookiePath || (path.startsWith(cookiePath) && (cookiePath.endsWith("/") || path[cookiePath.length] === "/"));
    const cookieMatchesURL = (cookie, url) => domainMatches(url.hostname, cookie.domain) && pathMatches(url.pathname || "/", cookie.path) && (!cookie.secure || url.protocol === "https:");
    const storeCookies = (storeId, url) => callRouter("cookies.getAll", storeId === undefined ? "0" : String(storeId), url && url.href);
    // Chrome's order: the longest path first, then the earliest created.
    const sortCookies = cookies => cookies.sort((a, b) => b.path.length - a.path.length || a.created - b.created);
    const publicCookie = ({ created, ...cookie }) => cookie;
    const cookieForURL = async (details = {}) => {
        const url = new URL(details.url);
        const cookies = await storeCookies(details.storeId, url);
        const [cookie] = sortCookies(cookies.filter(cookie => cookie.name === details.name && cookieMatchesURL(cookie, url)));
        return cookie || null;
    };
    const cookies = {
        get(...args) {
            return withOptionalCallback(args, async details => {
                const cookie = await cookieForURL(details);
                return cookie && publicCookie(cookie);
            });
        },
        getAll(...args) {
            return withOptionalCallback(args, async (details = {}) => {
                const url = typeof details.url === "string" ? new URL(details.url) : null;
                const cookies = (await storeCookies(details.storeId, url)).filter(cookie => (!url || cookieMatchesURL(cookie, url))
                    && (details.domain === undefined || isDomainOrSubdomain(cookie.domain, String(details.domain)))
                    && (details.name === undefined || cookie.name === details.name)
                    && (details.path === undefined || cookie.path === details.path)
                    && (details.secure === undefined || cookie.secure === details.secure)
                    && (details.session === undefined || cookie.session === details.session));
                return sortCookies(cookies).map(publicCookie);
            });
        },
        set(...args) {
            return withOptionalCallback(args, async (details = {}) => {
                const url = new URL(details.url);
                const storeId = details.storeId === undefined ? "0" : String(details.storeId);
                const directory = url.pathname.slice(0, url.pathname.lastIndexOf("/")) || "/";
                const cookie = {
                    name: details.name === undefined ? "" : String(details.name),
                    value: details.value === undefined ? "" : String(details.value),
                    domain: details.domain === undefined ? url.hostname : `.${String(details.domain).replace(/^\./, "")}`,
                    path: details.path === undefined ? directory : String(details.path),
                    secure: details.secure === true,
                    httpOnly: details.httpOnly === true,
                    sameSite: ["lax", "strict"].includes(details.sameSite) ? details.sameSite : "no_restriction",
                    expirationDate: typeof details.expirationDate === "number" ? details.expirationDate : undefined,
                };
                await callRouter("cookies.set", storeId, cookie, url.href);
                const [stored] = sortCookies((await storeCookies(storeId, url)).filter(candidate => candidate.name === cookie.name && candidate.domain === cookie.domain && candidate.path === cookie.path));
                return stored ? publicCookie(stored) : null;
            });
        },
        remove(...args) {
            return withOptionalCallback(args, async (details = {}) => {
                const cookie = await cookieForURL(details);
                if (!cookie)
                    return null;
                await callRouter("cookies.remove", cookie.storeId, cookie, details.url);
                return { url: details.url, name: details.name, storeId: cookie.storeId };
            });
        },
        getAllCookieStores(...args) {
            return withOptionalCallback(args, () => callRouter("cookies.getAllCookieStores"));
        },
        onChanged: trackedEvent("cookies.onChanged"),
    };
    browser.cookies = cookies;

    // navigator.clipboard: an extension's page writes and reads the general pasteboard whenever it asks, as a
    // WebExtension's pages with the clipboard permissions do. WebKit 1 extension views allow writes through
    // their preferences; a page in a web content process writes with its page's clipboard access granted for
    // the call. Reads go to the router.
    if (typeof Clipboard === "function") {
        const clipboard = navigator.clipboard;
        const { write, writeText, readText } = Clipboard.prototype;
        const clipboardMethods = {
            readText() {
                if (this !== clipboard)
                    return readText.apply(this, arguments);
                return callRouter("clipboard.readText").catch(() => {
                    throw new DOMException("The request is not allowed by the user agent or the platform in the current context, possibly because the user denied permission.", "NotAllowedError");
                });
            },
        };
        if (native.withClipboardWriteAccess) {
            const withWriteAccess = (method, thisValue, args) => {
                if (thisValue !== clipboard)
                    return method.apply(thisValue, args);
                return native.withClipboardWriteAccess(() => method.apply(thisValue, args));
            };
            Object.assign(clipboardMethods, {
                write(data) {
                    return withWriteAccess(write, this, arguments);
                },
                writeText(data) {
                    return withWriteAccess(writeText, this, arguments);
                },
            });
        }
        for (const name of Object.keys(clipboardMethods))
            Object.defineProperty(Clipboard.prototype, name, { value: clipboardMethods[name], writable: true, enumerable: true, configurable: true });
    }
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
