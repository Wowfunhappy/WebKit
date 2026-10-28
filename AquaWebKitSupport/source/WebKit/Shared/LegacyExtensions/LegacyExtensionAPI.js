// The `browser` namespace WebKit gives Safari 7 legacy extensions, shaped after the WebExtensions API, and
// the clipboard access their pages have.
//
// Evaluated once per extension context. `kind` is "host" for the extension's own pages -- the global page
// and toolbar popovers, which Safari hosts in WebKit 1 views, and pages opened in tabs or frames -- and
// "content" for content scripts. `native.send(json, bytes)` hands one message to the LegacyExtension
// router; the returned function receives the router's messages, one JSON string at a time. Messages are JSON,
// so they carry exactly what Chrome's extension messaging carries; a StreamFilter's message also carries its
// bytes, an ArrayBuffer or ArrayBufferView going out and an ArrayBuffer coming in.

(function (native, kind) {
"use strict";

const isHost = kind === "host";
// The DOM's Event, which StreamFilter dispatches; this script's Event class is the API's event object.
const DOMEvent = globalThis.Event;

const send = (message, bytes) => native.send(JSON.stringify(message), bytes);

// A context whose document is gone, or whose extension Safari disabled or reloaded, is invalidated. As in
// Chrome (api_binding_util.cc IsContextValidOrThrowError), every API method it calls and every event it reads
// then throws.
const checkContextIsValid = () => {
    if (!native.isValid())
        throw new Error("Extension context invalidated.");
};

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
        // Every proxy.onRequest listener answers for the requests its filter matches.
        const blockingEntries = name === "proxy.onRequest" ? event._listeners : event._listeners.filter(isBlocking);
        const blockingFilters = blockingEntries.map(({ filter }) => {
            if (!filter || typeof filter !== "object")
                return {};
            const { urls, types, tabId } = filter;
            return { urls: Array.isArray(urls) ? urls : undefined, types: Array.isArray(types) ? types : undefined, tabId: typeof tabId === "number" ? tabId : undefined };
        });
        const interest = blockingFilters.length ? { blockingFilters } : {};
        for (const option of ["requestBody", "extraHeaders", "requestHeaders"]) {
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
            if (!native.isValid())
                break;
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
        this._onMessage = new Event();
        this._onDisconnect = new Event();
        this._portId = portId;
        this._connected = true;
        ports.set(portId, this);
    }

    // Its events and methods check that the context is valid before anything else, as Chrome's port does
    // (gin_port.cc).
    get onMessage() {
        checkContextIsValid();
        return this._onMessage;
    }

    get onDisconnect() {
        checkContextIsValid();
        return this._onDisconnect;
    }

    postMessage(message) {
        checkContextIsValid();
        if (!this._connected)
            throw new Error("Attempting to use a disconnected port object");
        send({ t: "post", portId: this._portId, msg: message });
    }

    disconnect() {
        checkContextIsValid();
        if (!this._connected)
            return;
        this._connected = false;
        ports.delete(this._portId);
        send({ t: "disconnect", portId: this._portId });
    }

    _didReceiveMessage(message) {
        this._onMessage._fire(message, this);
    }

    _didDisconnect(error) {
        if (!this._connected)
            return;
        this._connected = false;
        ports.delete(this._portId);
        withLastError(error, () => this._onDisconnect._fire(this));
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
// Messages and ports from other extensions reach only host contexts.
const onMessageExternal = isHost ? trackedEvent("runtime.onMessageExternal") : new Event();
const onConnectExternal = isHost ? trackedEvent("runtime.onConnectExternal") : new Event();

const didReceiveOneShotMessage = ({ msgId, msg, sender, external }) => {
    let responded = false;
    const respond = reply => {
        if (responded)
            return;
        responded = true;
        send(Object.assign({ t: "reply", msgId }, reply));
    };
    const sendResponse = response => respond({ response });
    let willRespondAsynchronously = false;
    for (const { callback } of (external ? onMessageExternal : onMessage)._listeners.slice()) {
        let result;
        try {
            result = callback(msg, sender, sendResponse);
        } catch (error) {
            console.error(error);
        }
        if (!native.isValid())
            break;
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

// Called when a tab's declarativeNetRequest action count changes.
let actionCountChanged = () => { };

// Router calls.

const pendingCalls = new Map();
let nextCallIdentifier = 1;

const callRouter = (method, ...args) => new Promise((resolve, reject) => {
    const callId = nextCallIdentifier++;
    pendingCalls.set(callId, { resolve, reject });
    send({ t: "call", callId, method, args });
});

// A tab is a tab ID, or where Safari's extension API is, a SafariBrowserTab, which the router finds at its
// place in safari.application.browserWindows.
const tabReference = tab => {
    if (typeof tab === "number")
        return { tabId: tab };
    const application = globalThis.safari && globalThis.safari.application;
    if (application && tab && typeof tab === "object" && tab.browserWindow) {
        const window = Array.prototype.indexOf.call(application.browserWindows, tab.browserWindow);
        const index = window < 0 ? -1 : Array.prototype.indexOf.call(tab.browserWindow.tabs, tab);
        if (index >= 0)
            return { window, index };
    }
    throw new TypeError("A tab is a tab ID or a SafariBrowserTab of an open window.");
};
const tabReferences = tabs => (Array.isArray(tabs) ? tabs : [tabs]).map(tabReference);
// With no tab, `{ current }`: the router takes the calling page's own tab, or else `current`, the active tab
// of the frontmost window where Safari's extension API is.
const tabReferenceOrCurrent = tab => {
    if (tab !== undefined && tab !== null)
        return tabReference(tab);
    const application = globalThis.safari && globalThis.safari.application;
    const window = application && application.activeBrowserWindow;
    return { current: window && window.activeTab ? tabReference(window.activeTab) : null };
};

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
            if (hasExtraInfo(entry, "asyncBlocking")) {
                result = new Promise(resolve => callback(listenerDetails, resolve));
                if (!native.isValid())
                    break;
                result = await result;
            } else {
                result = callback(listenerDetails);
                if (!native.isValid())
                    break;
                if (blocking && result && typeof result.then === "function")
                    result = await result;
            }
        } catch (error) {
            console.error(error);
            if (!native.isValid())
                break;
            continue;
        }
        if (!native.isValid())
            break;
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

// Firefox's proxy.onError, which reports the errors of this context's proxy.onRequest listeners.
const proxyErrorEvent = new Event();

// Firefox's ProxyInfoData.validate, with its error messages.
const proxyInfoTypes = { direct: "direct", http: "http", https: "https", proxy: "http", socks: "socks", socks4: "socks4" };
const validateProxyInfo = info => {
    if (info === null)
        return null;
    const rawType = info !== undefined ? info.type : undefined;
    if (typeof rawType === "string" && rawType.toLowerCase() === "direct")
        return { type: "direct" };
    const type = typeof rawType === "string" ? proxyInfoTypes[rawType.toLowerCase()] : undefined;
    if (!type)
        throw new Error(`ProxyInfoData: Invalid proxy server type: "${rawType}"`);
    const { host } = info;
    if (typeof host !== "string" || host.includes(" "))
        throw new Error(`ProxyInfoData: Invalid proxy server host: "${host}"`);
    if (!host.length)
        throw new Error("ProxyInfoData: Proxy server host cannot be empty");
    const port = Number.parseInt(info.port, 10);
    if (!Number.isInteger(port))
        throw new Error(`ProxyInfoData: Invalid proxy server port: "${port}"`);
    if (port < 1 || port > 0xffff)
        throw new Error(`ProxyInfoData: Proxy server port ${port} outside range 1 to 65535`);
    for (const name of ["username", "password"]) {
        if (info[name] !== undefined && typeof info[name] !== "string")
            throw new Error(`ProxyInfoData: Invalid proxy server ${name}: "${info[name]}"`);
    }
    if (info.proxyDNS !== undefined) {
        if (typeof info.proxyDNS !== "boolean")
            throw new Error(`ProxyInfoData: Invalid proxyDNS value: "${info.proxyDNS}"`);
        if (info.proxyDNS && type !== "socks" && type !== "socks4")
            throw new Error("ProxyInfoData: proxyDNS can only be true for SOCKS proxy servers");
    }
    if (info.failoverTimeout !== undefined && (!Number.isInteger(info.failoverTimeout) || info.failoverTimeout < 1))
        throw new Error(`ProxyInfoData: Invalid failover timeout: "${info.failoverTimeout}"`);
    if (info.proxyAuthorizationHeader !== undefined) {
        if (typeof info.proxyAuthorizationHeader !== "string")
            throw new Error(`ProxyInfoData: Invalid proxy server authorization header: "${info.proxyAuthorizationHeader}"`);
        if (type !== "http" && type !== "https")
            throw new Error(`ProxyInfoData: ProxyAuthorizationHeader requires type "https" or "http"`);
    }
    if (info.connectionIsolationKey !== undefined && typeof info.connectionIsolationKey !== "string")
        throw new Error(`ProxyInfoData: Invalid proxy connection isolation key: "${info.connectionIsolationKey}"`);
    const { username, password, proxyDNS, failoverTimeout, proxyAuthorizationHeader, connectionIsolationKey } = info;
    return { type, host, port, username, password, proxyDNS, failoverTimeout, proxyAuthorizationHeader, connectionIsolationKey };
};

// proxy.onRequest listeners run in registration order, each answer acting on the route the ones before it left, as
// Firefox's ProxyChannelFilter applies them: undefined keeps the route, null connects directly, and a ProxyInfo or
// an array of them replaces it, ending at a null entry. A listener that throws or answers with an invalid
// ProxyInfo keeps the route and reports the error to proxy.onError.
const dispatchProxyRequest = async (event, details) => {
    const answers = [];
    for (const entry of event._listeners.slice()) {
        if (!filterMatches(entry.filter, details))
            continue;
        const listenerDetails = Object.assign({}, details);
        if (!hasExtraInfo(entry, "requestHeaders"))
            delete listenerDetails.requestHeaders;
        try {
            let result = entry.callback(listenerDetails);
            if (!native.isValid())
                break;
            result = await result;
            if (!native.isValid())
                break;
            if (result === undefined)
                continue;
            if (result === null) {
                answers.push(null);
                continue;
            }
            if (typeof result !== "object")
                throw new Error("ProxyInfoData: proxyData must be an object or array of objects");
            const answer = [];
            for (const info of Array.isArray(result) ? result : [result]) {
                const proxy = validateProxyInfo(info);
                answer.push(proxy);
                if (proxy === null)
                    break;
            }
            answers.push(answer);
        } catch (error) {
            if (!native.isValid())
                break;
            proxyErrorEvent._fire({ message: errorMessage(error), fileName: error && error.sourceURL, lineNumber: error && error.line, stack: error && error.stack });
            if (!native.isValid())
                break;
        }
    }
    return { proxy: answers };
};

// webRequest.filterResponseData's StreamFilter, as Firefox's: the network process sends the filter its response's
// body, and what the filter writes is the body the page receives. While the filter is suspended, events already
// on their way wait here. Each message back reports how many data events have been dispatched, so a disconnect
// lets the network process pass on the chunks the extension never handled.
const streamFilters = new Map();

class StreamFilter extends EventTarget {
    #id = randomId();
    #status = "uninitialized";
    #error = "";
    #dispatched = 0;
    #suspendedEvents = [];
    #handlers = {};

    constructor(requestId) {
        super();
        streamFilters.set(this.#id, (type, bytes, error) => this.#didReceive(type, bytes, error));
        send({ t: "filter", op: "create", filterId: this.#id, requestId: String(requestId) });
    }

    get status() {
        return this.#status;
    }

    get error() {
        return this.#error;
    }

    get onstart() { return this.#handler("start"); }
    set onstart(handler) { this.#setHandler("start", handler); }
    get ondata() { return this.#handler("data"); }
    set ondata(handler) { this.#setHandler("data", handler); }
    get onstop() { return this.#handler("stop"); }
    set onstop(handler) { this.#setHandler("stop", handler); }
    get onerror() { return this.#handler("error"); }
    set onerror(handler) { this.#setHandler("error", handler); }

    write(data) {
        if (!(data instanceof ArrayBuffer) && !(data instanceof Uint8Array))
            throw new TypeError("StreamFilter.write: Argument 1 is not an ArrayBuffer or Uint8Array.");
        if (!this.#isTransferring())
            throw new Error("Invalid state");
        this.#send("write", data);
    }

    close() {
        if (this.#status === "closed")
            return;
        if (!this.#isTransferring())
            throw new Error("Invalid state");
        this.#send("close");
        this.#end("closed");
    }

    disconnect() {
        if (this.#status === "disconnected")
            return;
        if (!this.#isTransferring())
            throw new Error("Invalid state");
        this.#send("disconnect");
        this.#end("disconnected");
    }

    suspend() {
        if (this.#status === "suspended")
            return;
        if (this.#status !== "transferringdata")
            throw new Error("Invalid state");
        this.#status = "suspended";
        this.#send("suspend");
    }

    resume() {
        if (this.#status === "transferringdata")
            return;
        if (this.#status !== "suspended")
            throw new Error("Invalid state");
        this.#status = "transferringdata";
        this.#send("resume");
        const events = this.#suspendedEvents;
        this.#suspendedEvents = [];
        for (const [type, bytes] of events) {
            if (this.#status !== "transferringdata")
                return;
            this.#dispatch(type, bytes);
        }
    }

    // Event handler attributes: the first assignment adds the listener that calls whichever handler is current.
    #handler(type) {
        return this.#handlers[type] || null;
    }

    #setHandler(type, handler) {
        if (!(type in this.#handlers)) {
            this.addEventListener(type, event => {
                const current = this.#handlers[type];
                if (typeof current === "function")
                    current.call(this, event);
            });
        }
        this.#handlers[type] = typeof handler === "function" ? handler : null;
    }

    #send(op, bytes) {
        send({ t: "filter", op, filterId: this.#id, dispatched: this.#dispatched }, bytes);
    }

    #end(status) {
        this.#status = status;
        this.#suspendedEvents = [];
        streamFilters.delete(this.#id);
    }

    #isTransferring() {
        return this.#status === "transferringdata" || this.#status === "finishedtransferringdata" || this.#status === "suspended";
    }

    #dispatch(type, bytes) {
        const event = new DOMEvent(type);
        if (type === "start")
            this.#status = "transferringdata";
        else if (type === "data") {
            ++this.#dispatched;
            Object.defineProperty(event, "data", { value: bytes || new ArrayBuffer(0), enumerable: true });
        } else if (type === "stop")
            this.#status = "finishedtransferringdata";
        this.dispatchEvent(event);
    }

    #didReceive(type, bytes, error) {
        if (type === "error") {
            this.#error = String(error);
            this.#end("failed");
            this.dispatchEvent(new DOMEvent("error"));
            return;
        }
        if (this.#status === "suspended") {
            this.#suspendedEvents.push([type, bytes]);
            return;
        }
        this.#dispatch(type, bytes);
    }
}

// Namespaces.

const browser = {};

browser.runtime = {
    get lastError() {
        return lastError;
    },
    // connect(optional string extensionId, optional object connectInfo), each argument matched by its type.
    connect(...args) {
        const extensionId = args.length && (typeof args[0] === "string" || args[0] == null) ? args.shift() : null;
        const connectInfo = args.length && (typeof args[0] === "object" || args[0] === undefined) ? args.shift() : null;
        if (args.length)
            throw new TypeError("Error in invocation of runtime.connect(optional string extensionId, optional object connectInfo): No matching signature.");
        return connect(connectInfo ? connectInfo.name : undefined, extensionId ? { extensionId } : { });
    },
    // sendMessage(optional string extensionId, any message, optional object options, optional function callback),
    // two arguments being (extensionId, message) when the first is a string, null or undefined, as Chrome's
    // MassageSendMessageArguments has it. An extensionId of null, undefined or "" is the caller's own.
    sendMessage(...args) {
        return withOptionalCallback(args, (...rest) => {
            let extensionId = null;
            let message;
            let options = null;
            if (rest.length === 1)
                [message] = rest;
            else if (rest.length === 2 && (typeof rest[0] === "string" || rest[0] == null))
                [extensionId, message] = rest;
            else if (rest.length === 2)
                [message, options] = rest;
            else if (rest.length === 3)
                [extensionId, message, options] = rest;
            if (!rest.length || rest.length > 3 || (extensionId != null && typeof extensionId !== "string") || (options != null && typeof options !== "object"))
                throw new TypeError("Error in invocation of runtime.sendMessage(optional string extensionId, any message, optional object options, optional function callback): No matching signature.");
            return sendMessage(message, extensionId ? { extensionId } : { });
        });
    },
    onConnect,
    onMessage,
};
if (isHost) {
    browser.runtime.onConnectExternal = onConnectExternal;
    browser.runtime.onMessageExternal = onMessageExternal;
}

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

    // The value of injected code as Chrome's V8ValueConverter carries it: what JSON cannot hold is null in an array
    // and left out of an object, a getter that throws gives null, an object met again on its own path is null, and
    // nesting stops at a depth of 100. Dates and regular expressions are objects like any other.
    const injectionResult = (value, path = new Set()) => {
        switch (typeof value) {
        case "boolean":
        case "string":
            return value;
        case "number":
            return Number.isFinite(value) ? value : undefined;
        case "object":
            if (value === null)
                return null;
            break;
        default:
            return undefined;
        }
        if (path.has(value))
            return null;
        if (path.size === 100)
            return undefined;
        const property = key => {
            try {
                return injectionResult(value[key], path);
            } catch {
                return null;
            }
        };
        // An object whose shape a proxy refuses to give is null.
        let length;
        let keys;
        try {
            if (Array.isArray(value))
                length = value.length;
            else
                keys = Object.keys(value);
        } catch {
            return null;
        }
        path.add(value);
        let result;
        if (keys === undefined) {
            result = [];
            for (let index = 0; index < length; ++index) {
                const element = property(index);
                result.push(element === undefined ? null : element);
            }
        } else {
            result = {};
            for (const key of keys) {
                const propertyValue = property(key);
                if (propertyValue !== undefined)
                    Object.defineProperty(result, key, { value: propertyValue, enumerable: true, writable: true, configurable: true });
            }
        }
        path.delete(value);
        return result;
    };

    // As in Chrome, a frame whose code throws gives null; the exception goes to the frame's console.
    const didReceiveExecuteScript = ({ callId, code, runAt, matchAboutBlank, userGesture }) => isReachable(matchAboutBlank) ? runWhen(runAt || "document_idle", () => {
        const result = injectionResult(native.executeScript(code, !!userGesture));
        send({ t: "result", callId, result: result === undefined ? null : result });
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
        filterResponseData(requestId) {
            return new StreamFilter(requestId);
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

    // The checks Firefox's schemas make of the arguments of tabs.captureTab, tabs.saveAsPDF and dns.resolve, with
    // its messages; a call whose arguments fail them throws.
    const schemaError = (value, schema, path = "") => {
        const fail = message => path ? `Error processing ${path}: ${message}` : message;
        const expected = type => fail(`Expected ${type} instead of ${JSON.stringify(value)}`);
        const child = name => path ? `${path}.${name}` : String(name);
        if (schema.enum) {
            if (typeof value !== "string")
                return expected("string");
            return schema.enum.includes(value) ? undefined : fail(`Invalid enumeration value ${JSON.stringify(value)}`);
        }
        switch (schema.type) {
        case "integer":
            if (!Number.isInteger(value))
                return expected("integer");
            if (schema.minimum !== undefined && value < schema.minimum)
                return fail(`Integer ${value} is too small (must be at least ${schema.minimum})`);
            if (schema.maximum !== undefined && value > schema.maximum)
                return fail(`Integer ${value} is too big (must be at most ${schema.maximum})`);
            return undefined;
        case "array":
            if (!Array.isArray(value))
                return expected("array");
            for (let index = 0; index < value.length; ++index) {
                const error = schemaError(value[index], schema.items, child(index));
                if (error)
                    return error;
            }
            return undefined;
        case "object":
            if (!value || typeof value !== "object" || Array.isArray(value))
                return expected("object");
            for (const name of Object.keys(value)) {
                if (!Object.hasOwn(schema.properties, name))
                    return fail(`Unexpected property "${name}"`);
            }
            for (const [name, property] of Object.entries(schema.properties)) {
                if (value[name] === undefined || value[name] === null) {
                    if (!property.optional)
                        return fail(`Property "${name}" is required`);
                    continue;
                }
                const error = schemaError(value[name], property, child(name));
                if (error)
                    return error;
            }
            return undefined;
        default:
            return typeof value === schema.type ? undefined : expected(schema.type);
        }
    };
    const checkParameter = (method, name, value, schema) => {
        const error = value === undefined || value === null ? undefined : schemaError(value, schema);
        if (error)
            throw new Error(`Type error for parameter ${name} (${error}) for ${method}.`);
    };
    const optional = schema => Object.assign({ optional: true }, schema);
    // extensionTypes.ImageDetails. resetScrollPosition is accepted and, as for an extension Firefox does not
    // sign, ignored.
    const imageDetailsSchema = {
        type: "object",
        properties: {
            format: optional({ enum: ["jpeg", "png"] }),
            quality: optional({ type: "integer", minimum: 0, maximum: 100 }),
            rect: optional({ type: "object", properties: { x: { type: "number" }, y: { type: "number" }, width: { type: "number" }, height: { type: "number" } } }),
            scale: optional({ type: "number" }),
            resetScrollPosition: optional({ type: "boolean" }),
        },
    };
    const pageSettingsSchema = { type: "object", properties: { } };
    for (const name of ["toFileName", "headerLeft", "headerCenter", "headerRight", "footerLeft", "footerCenter", "footerRight"])
        pageSettingsSchema.properties[name] = optional({ type: "string" });
    for (const name of ["paperSizeUnit", "orientation"])
        pageSettingsSchema.properties[name] = optional({ type: "integer" });
    for (const name of ["paperWidth", "paperHeight", "scaling", "edgeLeft", "edgeRight", "edgeTop", "edgeBottom", "marginLeft", "marginRight", "marginTop", "marginBottom"])
        pageSettingsSchema.properties[name] = optional({ type: "number" });
    for (const name of ["shrinkToFit", "showBackgroundColors", "showBackgroundImages"])
        pageSettingsSchema.properties[name] = optional({ type: "boolean" });

    browser.tabs = {
        get(...args) {
            return withOptionalCallback(args, async tabId => callRouter("tabs.get", tabReference(tabId)).then(tab => {
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
                const userGesture = native.isProcessingUserGesture();
                const code = typeof details.file === "string" ? await resourceText(details.file) : String(details.code);
                return callRouter("tabs.executeScript", tabId, Object.assign(injectionTarget(details), { code, userGesture }));
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
        goBack(...args) {
            return withOptionalCallback(args, async tabId => callRouter("tabs.goBack", tabReferenceOrCurrent(tabId)));
        },
        goForward(...args) {
            return withOptionalCallback(args, async tabId => callRouter("tabs.goForward", tabReferenceOrCurrent(tabId)));
        },
        hide(...args) {
            return withOptionalCallback(args, async tabIds => callRouter("tabs.hide", tabReferences(tabIds)));
        },
        show(...args) {
            return withOptionalCallback(args, async tabIds => {
                await callRouter("tabs.show", tabReferences(tabIds));
            });
        },
        // As Firefox matches arguments to its schema, an object first is the options of a call with no tab.
        captureTab(...args) {
            return withOptionalCallback(args, (...parameters) => {
                if (typeof parameters[0] === "object" && parameters[0] !== null)
                    parameters.unshift(null);
                const [tabId = null, options = null] = parameters;
                if ((tabId !== null && typeof tabId !== "number") || (options !== null && typeof options !== "object"))
                    throw new Error("Incorrect argument types for tabs.captureTab.");
                checkParameter("tabs.captureTab", "tabId", tabId, { type: "integer", minimum: 0 });
                checkParameter("tabs.captureTab", "options", options, imageDetailsSchema);
                return callRouter("tabs.captureTab", tabId, options || {});
            });
        },
        saveAsPDF(...args) {
            return withOptionalCallback(args, pageSettings => {
                if (pageSettings === undefined || pageSettings === null)
                    throw new Error("Incorrect argument types for tabs.saveAsPDF.");
                checkParameter("tabs.saveAsPDF", "pageSettings", pageSettings, pageSettingsSchema);
                return callRouter("tabs.saveAsPDF", pageSettings);
            });
        },
        onCreated: trackedEvent("tabs.onCreated"),
        onRemoved: trackedEvent("tabs.onRemoved"),
        onUpdated: trackedEvent("tabs.onUpdated"),
    };

    // Firefox's dns.
    const resolveFlags = ["allow_name_collisions", "bypass_cache", "canonical_name", "disable_ipv4", "disable_ipv6", "disable_trr", "offline", "priority_low", "priority_medium", "speculate"];
    browser.dns = {
        resolve(...args) {
            return withOptionalCallback(args, (hostname, flags = null) => {
                if (typeof hostname !== "string" || (flags !== null && !Array.isArray(flags)))
                    throw new Error("Incorrect argument types for dns.resolve.");
                checkParameter("dns.resolve", "flags", flags, { type: "array", items: { enum: resolveFlags } });
                return callRouter("dns.resolve", hostname, flags || []);
            });
        },
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

    // declarativeNetRequest: WebKit's, through the router, which validates each call as a WebExtension's.
    const declarativeNetRequestMethod = name => (...args) => withOptionalCallback(args, options => callRouter(`declarativeNetRequest.${name}`, options));
    browser.declarativeNetRequest = {
        updateEnabledRulesets: declarativeNetRequestMethod("updateEnabledRulesets"),
        getEnabledRulesets: declarativeNetRequestMethod("getEnabledRulesets"),
        updateDynamicRules: declarativeNetRequestMethod("updateDynamicRules"),
        getDynamicRules: declarativeNetRequestMethod("getDynamicRules"),
        updateSessionRules: declarativeNetRequestMethod("updateSessionRules"),
        getSessionRules: declarativeNetRequestMethod("getSessionRules"),
        getMatchedRules: declarativeNetRequestMethod("getMatchedRules"),
        isRegexSupported: declarativeNetRequestMethod("isRegexSupported"),
        setExtensionActionOptions: declarativeNetRequestMethod("setExtensionActionOptions"),
        MAX_NUMBER_OF_STATIC_RULESETS: 100,
        MAX_NUMBER_OF_ENABLED_STATIC_RULESETS: 50,
        MAX_NUMBER_OF_DYNAMIC_AND_SESSION_RULES: 30000,
    };

    // privacy: ChromeSettings the router keeps, of which only the regular scope is supported.
    const chromeSetting = name => ({
        get(...args) {
            return withOptionalCallback(args, () => callRouter("privacy.get", name));
        },
        set(...args) {
            return withOptionalCallback(args, (details = {}) => callRouter("privacy.set", name, details.value, details.scope === undefined ? "regular" : String(details.scope)));
        },
        clear(...args) {
            return withOptionalCallback(args, (details = {}) => callRouter("privacy.clear", name, details.scope === undefined ? "regular" : String(details.scope)));
        },
        onChange: trackedEvent(`privacy.${name}.onChange`),
    });
    // proxy: Chromium's proxy.settings, a ChromeSetting the router keeps, of which only the regular scope is
    // supported; Firefox's proxy.onRequest and proxy.onError; Chromium's proxy.onProxyError. A pac_script value's
    // script at a URL no network load reaches -- the extension's own resources, data: and blob: URLs -- is read
    // here and travels with the value.
    const proxyScope = details => details.scope === undefined ? "regular" : String(details.scope);
    const pacScriptData = async value => {
        const url = value && value.mode === "pac_script" && value.pacScript && typeof value.pacScript.url === "string" ? value.pacScript.url : "";
        try {
            const resolved = url ? new URL(url, location.href) : null;
            if (!resolved || !["safari-extension:", "data:", "blob:"].includes(resolved.protocol))
                return undefined;
            return await (await fetch(resolved.href)).text();
        } catch {
            return undefined;
        }
    };
    browser.proxy = {
        settings: {
            get(...args) {
                return withOptionalCallback(args, (details = {}) => callRouter("proxy.settings.get", { incognito: !!(details && details.incognito) }));
            },
            set(...args) {
                return withOptionalCallback(args, async (details = {}) => callRouter("proxy.settings.set", details.value, proxyScope(details), await pacScriptData(details.value)));
            },
            clear(...args) {
                return withOptionalCallback(args, (details = {}) => callRouter("proxy.settings.clear", proxyScope(details)));
            },
            onChange: trackedEvent("proxy.settings.onChange"),
        },
        onRequest: trackedEvent("proxy.onRequest"),
        onError: proxyErrorEvent,
        onProxyError: trackedEvent("proxy.onProxyError"),
    };

    browser.privacy = {
        network: {
            networkPredictionEnabled: chromeSetting("network.networkPredictionEnabled"),
        },
        websites: {
            hyperlinkAuditingEnabled: chromeSetting("websites.hyperlinkAuditingEnabled"),
        },
    };

    // mimeHandler: the handler page a document of a handled type shows reads the document's response. Its
    // streamUrl is a blob: URL of this page holding the body, which the page reads with fetch().
    const noStreamError = "No stream is attached to this page.";
    let streamInfo;
    browser.mimeHandler = {
        getStreamInfo(...args) {
            return withOptionalCallback(args, () => {
                if (typeof native.mimeHandlerStream !== "function")
                    return Promise.reject(new Error(noStreamError));
                if (!streamInfo) {
                    streamInfo = native.mimeHandlerStream().then(({ body, ...info }) => {
                        info.streamUrl = URL.createObjectURL(body);
                        return info;
                    });
                }
                return streamInfo.then(info => Object.assign({}, info));
            });
        },
        abortAndFallbackToNativeHandler(...args) {
            return withOptionalCallback(args, async () => {
                if (typeof native.mimeHandlerFallBack !== "function" || !native.mimeHandlerFallBack())
                    throw new Error(noStreamError);
            });
        },
        getMimeHandlerOptions(...args) {
            return withOptionalCallback(args, mimeType => callRouter("mimeHandler.getOptions", String(mimeType)));
        },
        setMimeHandlerOptions(...args) {
            return withOptionalCallback(args, (mimeType, options = {}) => callRouter("mimeHandler.setOptions", String(mimeType), { enabled: options.enabled !== false }));
        },
    };

    // The action count a displayActionCountAsBadgeText extension shows: the badge of its toolbar items in the
    // active browser window, for that window's active tab, which the router finds as the tab shown in the
    // frontmost window. Safari adds `safari` to the page after this script runs, so it is looked up when a
    // count changes, and from then on the badges follow Safari's window and tab activations too.
    let badgesFollowActivation = false;
    const updateBadges = countChanged => {
        const application = typeof safari === "object" && safari ? safari.application : undefined;
        const toolbarItems = typeof safari === "object" && safari && safari.extension ? safari.extension.toolbarItems : undefined;
        if (!application || !toolbarItems)
            return;
        if (!badgesFollowActivation) {
            badgesFollowActivation = true;
            application.addEventListener("activate", () => updateBadges(false), true);
        }
        // When the extension stops displaying counts, every counted tab's count changes to 0, which clears
        // the badge; an extension that does not display them keeps its badge to itself.
        const setBadges = badge => {
            for (const item of toolbarItems) {
                if (item.browserWindow === application.activeBrowserWindow)
                    item.badge = badge;
            }
        };
        callRouter("declarativeNetRequest.activeTabActionCount").then(({ displaying, count }) => {
            if (!displaying) {
                if (countChanged)
                    setBadges(0);
                return;
            }
            if (count !== undefined)
                setBadges(count);
        }, () => { });
    };
    actionCountChanged = () => updateBadges(true);

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

// devtools, in a devtools page: native.inspectedTabId() is the tab its Web Inspector inspects. The methods follow
// Chrome's devtools API (ExtensionAPI.ts): a trailing callback, or else a Promise, and failures reported as
// Chrome's ExtensionServer records ({ code, description, details, isError }) rather than through lastError.
if (isHost && typeof native.inspectedTabId === "function" && typeof native.inspectedTabId() === "number") {
    const devToolsError = () => new Error("DevTools API encountered an error");
    const failedRecord = error => ({ code: "E_FAILED", description: "Operation failed: %s", details: [errorMessage(error)], isError: true });
    const callbackOrPromise = args => {
        const callback = typeof args[args.length - 1] === "function" ? args[args.length - 1] : undefined;
        if (callback)
            return { callback };
        let resolve, reject;
        const promise = new Promise((resolvePromise, rejectPromise) => {
            resolve = resolvePromise;
            reject = rejectPromise;
        });
        return { promise, resolve, reject };
    };

    // HAR entries, as upstream's WI.HARBuilder writes them from the WI.Resource the Network domain's events
    // describe. A record is a request's events as the router collected them.
    const harDate = seconds => typeof seconds === "number" && Number.isFinite(seconds) ? new Date(seconds * 1000).toISOString() : "";
    const headerValue = (headers, name) => {
        const lowercaseName = name.toLowerCase();
        for (const key in headers || {}) {
            if (key.toLowerCase() === lowercaseName)
                return headers[key];
        }
        return undefined;
    };
    const harHeaders = headers => Object.keys(headers || {}).map(name => ({ name, value: headers[name] }));
    const parseQueryString = queryString => {
        if (!queryString)
            return [];
        const decode = string => {
            try {
                return decodeURIComponent(string.replace(/\+/g, " "));
            } catch {
                return string;
            }
        };
        return queryString.split("&").map(parameter => {
            let index = parameter.indexOf("=");
            if (index === -1)
                index = parameter.length;
            return { name: decode(parameter.substring(0, index)), value: decode(parameter.substring(index + 1)) };
        });
    };
    const httpVersion = protocol => ({ "h2": "HTTP/2", "http/1.0": "HTTP/1.0", "http/1.1": "HTTP/1.1", "spdy/2": "SPDY/2", "spdy/3": "SPDY/3", "spdy/3.1": "SPDY/3.1" })[protocol] || "";
    const requestCookies = header => {
        if (!header || !header.trim())
            return [];
        const cookies = [];
        for (const pair of header.trim().split(/; /)) {
            const match = pair.match(/^([^\s=]+)[ \t]*=[ \t]*(.*)$/);
            if (match)
                cookies.push({ name: match[1], value: match[2] });
        }
        return cookies;
    };
    const responseCookies = (header, requestSentSeconds) => {
        const cookies = [];
        for (const line of (header || "").split(/, (?![0-9])/)) {
            const nameValue = line.match(/^([^\s=]+)[ \t]*=[ \t]*([^;]*)/);
            if (!nameValue)
                continue;
            const cookie = { name: nameValue[1], value: nameValue[2] };
            let expires = null;
            let maxAge = null;
            let httpOnly = false;
            let secure = false;
            let sameSite = "None";
            for (const attribute of line.substring(nameValue[0].length).split(/; ?/)) {
                const match = attribute && attribute.match(/^([^\s=]+)(?:=(.*))?$/);
                if (!match)
                    continue;
                const value = match[2];
                switch (match[1].toLowerCase()) {
                case "expires":
                    expires = new Date(value);
                    if (isNaN(expires.getTime()))
                        expires = null;
                    break;
                case "max-age":
                    maxAge = /^\d+$/.test(value || "") ? parseInt(value, 10) : null;
                    break;
                case "path":
                    cookie.path = value;
                    break;
                case "domain":
                    cookie.domain = value;
                    break;
                case "secure":
                    secure = true;
                    break;
                case "httponly":
                    httpOnly = true;
                    break;
                case "samesite": {
                    const lowercaseValue = (value || "").toLowerCase();
                    sameSite = lowercaseValue === "lax" ? "Lax" : lowercaseValue === "strict" ? "Strict" : "None";
                    break;
                }
                }
            }
            let expirationDate = null;
            if (expires || maxAge)
                expirationDate = maxAge ? new Date((typeof requestSentSeconds === "number" ? requestSentSeconds * 1000 : Date.now()) + maxAge * 1000) : expires;
            cookie.expires = expirationDate ? expirationDate.toISOString() : "";
            cookie.httpOnly = httpOnly;
            cookie.secure = secure;
            if (sameSite !== "None")
                cookie.sameSite = sameSite;
            cookies.push(cookie);
        }
        return cookies;
    };
    const number = value => typeof value === "number" ? value : NaN;

    // WI.ResourceTimingData.fromPayload, with its getters' fallbacks to the request's event times.
    const timingData = record => {
        const payload = (record.response && record.response.timing) || {};
        const startTime = number(payload.startTime);
        let fetchStart = number(payload.fetchStart);
        if (isNaN(fetchStart) || fetchStart < startTime)
            fetchStart = startTime;
        const offset = value => value > 0 ? fetchStart + value / 1000 : NaN;
        const data = {
            startTime,
            domainLookupStart: offset(payload.domainLookupStart),
            domainLookupEnd: offset(payload.domainLookupEnd),
            connectStart: offset(payload.connectStart),
            connectEnd: offset(payload.connectEnd),
            secureConnectionStart: offset(payload.secureConnectionStart),
            requestStart: offset(payload.requestStart),
            responseStart: offset(payload.responseStart),
            responseEnd: number(record.finishedTimestamp) || offset(payload.responseEnd),
        };
        for (const key of Object.keys(data))
            data[key] = data[key] || NaN;
        if (data.domainLookupStart >= data.domainLookupEnd)
            data.domainLookupStart = data.domainLookupEnd = NaN;
        if (data.connectStart >= data.connectEnd)
            data.connectStart = data.connectEnd = NaN;
        const sent = number(record.timestamp);
        return {
            startTime: data.startTime || sent,
            domainLookupStart: data.domainLookupStart,
            domainLookupEnd: data.domainLookupEnd,
            connectStart: data.connectStart,
            connectEnd: data.connectEnd,
            secureConnectionStart: data.secureConnectionStart,
            requestStart: data.requestStart || data.startTime || sent,
            responseStart: data.responseStart || data.startTime || number(record.responseTimestamp) || number(record.finishedTimestamp),
            responseEnd: data.responseEnd || number(record.finishedTimestamp),
        };
    };

    const harTimings = timing => {
        const result = { blocked: -1, dns: -1, connect: -1, ssl: -1, send: 0, wait: 0, receive: 0 };
        if (!timing.startTime || !timing.responseEnd)
            return result;
        const { startTime, domainLookupStart, domainLookupEnd, connectStart, connectEnd, secureConnectionStart, requestStart, responseStart, responseEnd } = timing;
        result.blocked = ((domainLookupStart || connectStart || requestStart) - startTime) * 1000;
        if (domainLookupStart)
            result.dns = ((domainLookupEnd || connectStart || requestStart) - domainLookupStart) * 1000;
        if (connectStart)
            result.connect = ((connectEnd || requestStart) - connectStart) * 1000;
        if (secureConnectionStart)
            result.ssl = ((connectEnd || requestStart) - secureConnectionStart) * 1000;
        result.send = (domainLookupEnd || connectEnd) ? (requestStart - (connectEnd || domainLookupEnd)) * 1000 : 0;
        result.wait = (responseStart - requestStart) * 1000;
        result.receive = (responseEnd - responseStart) * 1000;
        return result;
    };

    const harEntry = record => {
        const response = record.response || {};
        const metrics = record.metrics || {};
        const requestHeaders = metrics.requestHeaders || response.requestHeaders || record.requestHeaders || {};
        const responseHeaders = response.headers || {};
        const cached = !!record.fromMemoryCache || response.source === "memory-cache" || response.source === "disk-cache";
        const responseBodySize = number(metrics.responseBodyDecodedSize);
        const responseBodyTransferSize = number(metrics.responseBodyBytesReceived);
        const responseHeadersTransferSize = number(metrics.responseHeaderBytesReceived);
        const estimatedSize = number(record.dataLength) || 0;
        let size = estimatedSize;
        if (!isNaN(number(record.cachedBodySize)) && record.fromMemoryCache)
            size = record.cachedBodySize;
        else if (!isNaN(responseBodySize) && responseBodySize !== 0)
            size = responseBodySize;
        let estimatedEncodedSize;
        if (!isNaN(responseBodyTransferSize))
            estimatedEncodedSize = responseBodyTransferSize;
        else if (cached)
            estimatedEncodedSize = 0;
        else if (!isNaN(Number(headerValue(responseHeaders, "Content-Length"))))
            estimatedEncodedSize = Number(headerValue(responseHeaders, "Content-Length"));
        else if (!isNaN(number(record.encodedDataLength)))
            estimatedEncodedSize = record.encodedDataLength;
        else
            estimatedEncodedSize = estimatedSize;
        let decodedSize = !isNaN(responseBodySize) ? responseBodySize : size;
        let encodedSize = !isNaN(responseBodyTransferSize) ? responseBodyTransferSize : estimatedEncodedSize;
        if (isNaN(decodedSize))
            decodedSize = 0;
        if (isNaN(encodedSize))
            encodedSize = 0;
        const timing = timingData(record);
        const url = record.url || "";
        let queryString = "";
        try {
            queryString = new URL(url).search.substring(1);
        } catch { }

        const request = {
            method: record.method || "",
            url,
            httpVersion: httpVersion(metrics.protocol),
            cookies: requestCookies(headerValue(requestHeaders, "Cookie")),
            headers: harHeaders(requestHeaders),
            queryString: parseQueryString(queryString),
            headersSize: !isNaN(number(metrics.requestHeaderBytesSent)) ? metrics.requestHeaderBytesSent : -1,
            bodySize: !isNaN(number(metrics.requestBodyBytesSent)) ? metrics.requestBodyBytesSent : -1,
        };
        if (record.postData) {
            const contentType = headerValue(requestHeaders, "Content-Type") || "";
            request.postData = {
                mimeType: contentType,
                text: record.postData,
                params: /^application\/x-www-form-urlencoded\s*(;.*)?$/i.test(contentType) ? parseQueryString(record.postData) : [],
            };
        }

        const harResponse = {
            status: response.status || 0,
            statusText: response.statusText || "",
            httpVersion: httpVersion(metrics.protocol),
            cookies: responseCookies(headerValue(responseHeaders, "Set-Cookie"), record.walltime),
            headers: harHeaders(responseHeaders),
            content: { size: decodedSize, compression: decodedSize - encodedSize, mimeType: response.mimeType || "x-unknown" },
            redirectURL: headerValue(responseHeaders, "Location") || "",
            headersSize: !isNaN(responseHeadersTransferSize) ? responseHeadersTransferSize : -1,
            bodySize: !isNaN(responseBodyTransferSize) ? responseBodyTransferSize : -1,
        };
        if (!isNaN(responseHeadersTransferSize + responseBodyTransferSize))
            harResponse._transferSize = responseHeadersTransferSize + responseBodyTransferSize;
        if (record.failureText)
            harResponse._error = record.failureText;

        const entry = {
            pageref: "page_0",
            startedDateTime: harDate(record.walltime),
            time: timing.startTime && timing.responseEnd ? (timing.responseEnd - timing.startTime) * 1000 : 0,
            request,
            response: harResponse,
            cache: {},
            timings: harTimings(timing),
        };
        if (metrics.remoteAddress) {
            entry.serverIPAddress = metrics.remoteAddress.replace(/:\d+$/, "");
            const port = parseInt(metrics.remoteAddress.substring(metrics.remoteAddress.lastIndexOf(":") + 1));
            if (entry.serverIPAddress && !isNaN(port))
                entry._serverPort = port;
        }
        if (metrics.connectionIdentifier)
            entry.connection = String(metrics.connectionIdentifier);
        const fetchType = { "network": "Network Load", "memory-cache": "Memory Cache", "disk-cache": "Disk Cache", "service-worker": "Service Worker", "inspector-override": "Inspector Override" }[record.fromMemoryCache ? "memory-cache" : response.source];
        if (fetchType)
            entry._fetchType = fetchType;
        if (["low", "medium", "high"].includes(metrics.priority))
            entry._priority = metrics.priority;
        return entry;
    };

    const redirectEntries = record => record.redirects.map(redirect => {
        const response = redirect.response || {};
        const responseHeaders = response.headers || {};
        const walltime = typeof record.walltime === "number" && typeof redirect.timestamp === "number" ? record.walltime + (redirect.timestamp - record.timestamp) : undefined;
        return {
            pageref: "page_0",
            startedDateTime: harDate(walltime),
            time: 0,
            request: { method: redirect.method || "", url: redirect.url || "", httpVersion: "", cookies: [], headers: harHeaders(redirect.requestHeaders), queryString: [], headersSize: -1, bodySize: -1 },
            response: { status: response.status || 0, statusText: response.statusText || "", httpVersion: "", cookies: [], headers: harHeaders(responseHeaders), content: { size: 0, mimeType: "x-unknown" }, redirectURL: responseHeaders.Location || responseHeaders.location || "", headersSize: -1, bodySize: -1 },
            cache: {},
            timings: { blocked: -1, dns: -1, connect: -1, ssl: -1, send: 0, wait: 0, receive: 0 },
        };
    });

    // A request's entry carries getContent() on its prototype, as Chrome's Request objects do.
    const requestEntry = record => Object.setPrototypeOf(harEntry(record), {
        getContent(...args) {
            const { callback, promise, resolve, reject } = callbackOrPromise(args);
            callRouter("devtools.network.getContent", record.id).catch(failedRecord).then(response => {
                if (response && response.isError && reject)
                    return reject(devToolsError());
                const { content, encoding } = response || {};
                if (resolve)
                    resolve({ content, encoding });
                if (callback)
                    callback(content, encoding);
            });
            return promise;
        },
    });

    const harLog = ({ records, page }) => {
        page = page || {};
        const main = records.find(record => record.loaderId === page.loaderId && record.type === "Document");
        const pageTimings = {};
        if (main && typeof page.domContentLoadedTimestamp === "number")
            pageTimings.onContentLoad = (page.domContentLoadedTimestamp - main.timestamp) * 1000;
        if (main && typeof page.loadTimestamp === "number")
            pageTimings.onLoad = (page.loadTimestamp - main.timestamp) * 1000;
        const entries = [];
        for (const record of records) {
            entries.push(...redirectEntries(record));
            entries.push(requestEntry(record));
        }
        return {
            version: "1.2",
            creator: { name: "WebKit Web Inspector", version: "1.0" },
            pages: [{ startedDateTime: harDate(main && main.walltime), id: "page_0", title: page.url || "", pageTimings }],
            entries,
        };
    };

    const onRequestFinished = trackedEvent("devtools.network.onRequestFinished");
    onRequestFinished._fire = function(record) {
        Event.prototype._fire.call(this, requestEntry(record));
    };

    browser.devtools = {
        inspectedWindow: {
            tabId: native.inspectedTabId(),
            eval(expression, optionsOrCallback) {
                const options = typeof optionsOrCallback === "object" && optionsOrCallback !== null ? optionsOrCallback : {};
                const { callback, promise, resolve, reject } = callbackOrPromise(Array.from(arguments));
                const unsupported = ["useContentScriptContext", "scriptExecutionContext"].find(name => options[name]);
                const evaluation = unsupported
                    ? Promise.resolve({ code: "E_NOTSUPPORTED", description: "Object does not support requested operation: %s", details: [unsupported], isError: true })
                    : callRouter("devtools.inspectedWindow.eval", String(expression), { frameURL: typeof options.frameURL === "string" ? options.frameURL : undefined }).catch(failedRecord);
                evaluation.then(result => {
                    if (result.isError && reject)
                        return reject(devToolsError());
                    if (result.isException) {
                        if (reject)
                            reject(result);
                    } else if (resolve)
                        resolve(result.value);
                    if (!callback)
                        return;
                    if (result.isError || result.isException)
                        callback(undefined, result);
                    else
                        callback(result.value);
                });
                return promise;
            },
            reload(optionsOrUserAgent) {
                let options = {};
                if (typeof optionsOrUserAgent === "object" && optionsOrUserAgent !== null)
                    options = optionsOrUserAgent;
                else if (typeof optionsOrUserAgent === "string")
                    options = { userAgent: optionsOrUserAgent };
                callRouter("devtools.inspectedWindow.reload", {
                    ignoreCache: options.ignoreCache === true,
                    userAgent: typeof options.userAgent === "string" ? options.userAgent : undefined,
                    injectedScript: typeof options.injectedScript === "string" ? options.injectedScript : undefined,
                }).catch(() => { });
            },
        },
        network: {
            onRequestFinished,
            onNavigated: trackedEvent("devtools.network.onNavigated"),
            getHAR(...args) {
                const { callback, promise, resolve, reject } = callbackOrPromise(args);
                callRouter("devtools.network.getHAR").then(archive => {
                    const log = harLog(archive);
                    if (resolve)
                        resolve(log);
                    if (callback)
                        callback(log);
                }, () => {
                    if (reject)
                        reject(devToolsError());
                });
                return promise;
            },
        },
    };
}

// Incoming messages.

function receiverTable() {
    if (!receiverTable.table) {
        receiverTable.table = {
            connect({ portId, name, sender, external }) {
                const port = new Port(portId, name, sender);
                const event = external ? onConnectExternal : onConnect;
                if (!event.hasListeners()) {
                    port._connected = false;
                    ports.delete(portId);
                    send({ t: "disconnect", portId });
                    return;
                }
                event._fire(port);
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
            filter({ filterId, ev, error }, bytes) {
                const didReceive = streamFilters.get(filterId);
                if (didReceive)
                    didReceive(ev, bytes, error);
            },
            event({ name, args, token }) {
                if (name === "declarativeNetRequest.actionCount") {
                    actionCountChanged();
                    return;
                }
                const event = trackedEvents.get(name);
                if (name === "proxy.onRequest") {
                    const dispatch = event ? dispatchProxyRequest(event, args[0]) : Promise.resolve({});
                    if (token !== undefined)
                        dispatch.then(result => send({ t: "respond", token, result }), () => send({ t: "respond", token, result: {} }));
                    return;
                }
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

const aqua = {};
if (typeof native.createMediaSession === "function") {
    const wrapSource = source => {
        const command = (name, options = {}, data) => source.command(name, JSON.stringify(options), data);
        const player = Object.freeze({
            url: source.url,
            closed: source.closed,
            state: () => command("state"),
            play: () => command("play"),
            pause: () => command("pause"),
            seek: value => command("seek", { value }),
            setRate: value => command("rate", { value }),
            activate: () => command("activate"),
            close: () => command("close"),
        });
        return Object.freeze({
            url: source.url,
            method: source.capture ? "restream" : "url",
            closed: source.closed,
            close: () => command("close"),
            setResource: (name, data, type = "application/octet-stream") => command("resource", { name, type }, typeof data === "string" ? new TextEncoder().encode(data) : data),
            removeResource: name => command("remove-resource", { name }),
            setPlaylistProvider: (handler, { timeout = 30 } = {}) => {
                if (handler !== null && typeof handler !== "function")
                    return Promise.reject(new TypeError("A playlist provider must be a function or null"));
                const callback = handler && ((name, complete) => {
                    Promise.resolve().then(() => handler(name)).then(text => complete(typeof text === "string" ? text : undefined), () => complete());
                });
                return command("playlist-provider", { timeout }, callback);
            },
            open: async ({ application, adapter, timeout = 30 } = {}) => {
                await command("open", { application, adapter: adapter === undefined ? "" : JSON.stringify(adapter), timeout });
                return player;
            },
        });
    };
    const createSession = async (element, options = {}, parent) => {
        const handle = await native.createMediaSession(element, options.textTracks, parent);
        const command = (name, options = {}) => handle.command(name, JSON.stringify(options));
        return Object.freeze({
            inspect: () => command("inspect"),
            connect: (message = "") => command("connect", { message }),
            confirmConnection: () => command("connected"),
            disconnect: () => command("disconnect"),
            present: (mode, message = "") => command("present", { mode, message }),
            publish: async options => wrapSource(await command("publish", options)),
            capture: async (options = {}) => wrapSource(await command("capture", { maxWidth: 3840, maxHeight: 2160, transport: "hls", videoCodec: "h264", ...options })),
            close: () => command("close"),
        });
    };
    const withHandoff = async (callback, parent, ticket) => {
        if (typeof callback !== "function")
            throw new TypeError("withHandoff requires a function");
        let value, error, failed = false;
        const controller = new AbortController();
        try {
            await native.withMediaPlayerHandoff((complete, identifier) => {
                const scope = {
                    signal: controller.signal,
                    createSession: (element, options) => createSession(element, options, identifier),
                    withHandoff: callback => withHandoff(callback, identifier),
                };
                Promise.resolve().then(() => callback(scope)).then(result => {
                    value = result;
                    complete();
                }, reason => {
                    error = reason;
                    failed = true;
                    complete();
                });
            }, parent, ticket);
            if (failed)
                throw error;
            return value;
        } finally {
            controller.abort();
        }
    };
    aqua.mediaPlayer = { capabilities: Object.freeze({ version: 1, sessions: true, urlSources: true, captureSources: true, playerControl: true, resources: true, playlistProvider: true, resourceByteLimit: 64 * 1024 * 1024 }), createSession: (element, options) => createSession(element, options), withHandoff: (callback, options = {}) => {
        if (options.ticket !== undefined && (typeof options.ticket !== "string" || !options.ticket.length))
            return Promise.reject(new TypeError("A handoff ticket must be a string"));
        return withHandoff(callback, undefined, options.ticket);
    } };
}
if (isHost) {
    aqua.mediaPlayer = Object.assign(aqua.mediaPlayer || {}, {
        prepareHandoff: async tab => callRouter("aqua.mediaPlayer.prepareHandoff", tabReference(tab)),
        cancelHandoff: ticket => callRouter("aqua.mediaPlayer.cancelHandoff", ticket),
    });
    // A connection to the Web Inspector backend of a tab, whose messages are this WebKit's Web Inspector protocol
    // as JSON text.
    aqua.inspector = {
        attach: async tab => {
            await callRouter("aqua.inspector.attach", tabReference(tab));
        },
        detach: async tab => {
            await callRouter("aqua.inspector.detach", tabReference(tab));
        },
        sendMessage: async (tab, message) => {
            if (typeof message !== "string")
                throw new TypeError("An inspector message is a string");
            await callRouter("aqua.inspector.sendMessage", tabReference(tab), message);
        },
        onMessage: trackedEvent("aqua.inspector.onMessage"),
        onDetach: trackedEvent("aqua.inspector.onDetach"),
    };
    // User input to a tab, as AppKit events its web view handles (EXTENSION-AQUA-API.md).
    const inputEvent = (event, name) => {
        if (!event || typeof event !== "object")
            throw new TypeError(`A ${name} is an object`);
        return event;
    };
    aqua.input = {
        dispatchMouseEvent: async (tab, event) => {
            await callRouter("aqua.input.dispatchMouseEvent", tabReference(tab), inputEvent(event, "mouse event"));
        },
        dispatchKeyEvent: async (tab, event) => {
            await callRouter("aqua.input.dispatchKeyEvent", tabReference(tab), inputEvent(event, "key event"));
        },
        performEditingAction: async (tab, action) => {
            if (typeof action !== "string")
                throw new TypeError("An editing action is a selector name string");
            await callRouter("aqua.input.performEditingAction", tabReference(tab), action);
        },
        insertText: async (tab, text) => {
            if (typeof text !== "string")
                throw new TypeError("Inserted text is a string");
            await callRouter("aqua.input.insertText", tabReference(tab), text);
        },
    };
}
// Every method of a namespace and of its nested namespaces checks that the context is valid when called, and
// every event when read, as Chrome's bindings do (api_binding.cc RunAPIBindingHandlerCallback, GetEventObject).
const guardNamespace = namespace => {
    for (const key of Object.getOwnPropertyNames(namespace)) {
        const descriptor = Object.getOwnPropertyDescriptor(namespace, key);
        if (!descriptor.configurable || !("value" in descriptor))
            continue;
        const value = descriptor.value;
        if (typeof value === "function") {
            Object.defineProperty(namespace, key, Object.assign(descriptor, {
                value: function (...args) {
                    checkContextIsValid();
                    return value.apply(this, args);
                },
            }));
        } else if (value instanceof Event) {
            Object.defineProperty(namespace, key, {
                get() {
                    checkContextIsValid();
                    return value;
                },
                enumerable: descriptor.enumerable,
                configurable: true,
            });
        } else if (value && typeof value === "object" && !Object.isFrozen(value) && Object.getPrototypeOf(value) === Object.prototype)
            guardNamespace(value);
    }
};
guardNamespace(browser);
guardNamespace(aqua);

if (Object.keys(aqua).length)
    Object.defineProperty(globalThis, "aqua", { value: aqua, writable: true, configurable: true, enumerable: false });

Object.defineProperty(globalThis, "browser", { value: browser, writable: true, configurable: true, enumerable: false });

return (json, bytes) => {
    if (!native.isValid())
        return;
    const message = JSON.parse(json);
    const handler = receiverTable()[message.t];
    if (handler)
        handler(message, bytes);
};
})
