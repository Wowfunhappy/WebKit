# MV2 compatibility API for Safari 7 extensions

This WebKit gives Safari 7 legacy extensions (`.safariextension` bundles) a `browser` namespace modeled on the WebExtensions (MV2) API. It sits alongside Safari 7's own `safari.extension` / `safari.application` / `safari.self` API, which stays fully available. Use `browser` for what Safari 7 cannot do: messaging addressed by tab and frame, script and style injection on demand, network interception, navigation events, cookies, and the clipboard.

The engine provides only what needs the engine. Anything an extension can build from `safari.*` or the web platform, such as `runtime.getURL`, `storage`, `tabs.query`, `tabs.create`, and menus, is left to the extension's own platform layer (the uBlock Origin port's `browser-safari.js`, for example, builds these on top).

Not provided: the `ip` field of `webRequest` details, and the `documentId`, `documentLifecycle`, and `frameType` fields Chrome added after MV2.

Sources:

| Part | Path |
| --- | --- |
| The JavaScript API | `MavericksSupport/source/WebKit/Shared/LegacyExtensions/LegacyExtensionAPI.js` |
| UI-process router | `MavericksSupport/source/WebKit/UIProcess/LegacyExtensions/LegacyExtensionHost.{h,cpp}` |
| Web-content side | `MavericksSupport/source/WebKit/WebProcess/LegacyExtensions/LegacyExtensionContent.{h,cpp}` |
| Network side (webRequest) | `MavericksSupport/source/WebKit/NetworkProcess/LegacyExtensions/LegacyExtensionNetwork.{h,cpp}` |
| Clipboard | `MavericksSupport/source/WebKit/UIProcess/LegacyExtensions/LegacyExtensionClipboard.mm` |
| WebKit 1 page hooks | `MavericksSupport/source/WebKitLegacy/mac/LegacyExtensions/WebLegacyExtensionPageObserver.mm` |
| Root-relative URLs | `MavericksSupport/source/WTF/wtf/LegacyExtensionURL.{h,cpp}` |
| Test extension and server | `MavericksSupport/tests/legacy-extensions/` |

## Contexts

The API is installed in two kinds of context, and the namespaces available depend on the kind.

**Host contexts** are the extension's own pages: any document whose URL is `safari-extension://<extension key>/...`. This covers the global page, toolbar popovers, and extension bars, which Safari 7 hosts in WebKit 1 views inside the Safari process, and extension pages opened in tabs or frames, which load in web content processes. In a tab or frame, the page's main world is the host context.

**Content contexts** are the extension's content scripts. Safari 7 runs each extension's content scripts (Info.plist `Content` → `Scripts`) in a script world of its own. The API is installed in that world in every frame where the world has a window object.

| Namespace | Host | Content |
| --- | --- | --- |
| `browser.runtime` (`connect`, `sendMessage`, `onConnect`, `onMessage`, `lastError`) | yes | yes |
| `browser.runtime.getFrameId` | no | yes |
| `browser.dom` | no | yes |
| `browser.tabs` | yes | no |
| `browser.webNavigation` | yes | no |
| `browser.webRequest` | yes | no |
| `browser.cookies` | yes | no |
| `navigator.clipboard` without the page's restrictions | yes | no (page rules apply) |

`browser` is a writable, configurable, non-enumerable property of the global object. There is no `chrome` alias.

A context belongs to one document. When its frame shows another document, or when Safari withdraws the extension's content-script world (the extension is disabled or reloaded), the old context's `browser` object goes inert: its calls are dropped and its ports disconnect.

### Identifiers

- **Tab IDs** are positive integers, one per WebKit 2 page (the page's `WebPageProxyIdentifier`). Safari 7's WebKit 1 views (global page, popovers, bars) are not tabs.
- **Frame IDs** are `0` for a tab's main frame and the frame's `FrameIdentifier` otherwise. `parentFrameId` is `-1` for a main frame.
- **Extension key**: the host of the extension's `safari-extension://` URLs. It scopes every route: an extension's messages, ports, and injections reach only that extension's contexts.

### Calling conventions

Every method that returns a Promise also accepts a trailing callback, as Chrome's do. With a callback, the method returns `undefined`, and a failure calls the callback with no arguments while `browser.runtime.lastError` is set to `{ message }`. `lastError` is defined only while that callback runs.

Every message crossing between contexts is serialized as JSON. Values JSON cannot represent (functions, `undefined` members, cyclic objects, DOM nodes) do not survive the trip.

Messages, port traffic, and events reach JavaScript as tasks on the receiving context's event loop, never synchronously inside the sender's call. A suspended document (for example, one in the back/forward cache) receives nothing until it resumes.

## `browser.runtime`

### `runtime.sendMessage(message)` → `Promise<any>`

Sends a one-shot message. From a content script, it goes to the extension's host contexts that have a `runtime.onMessage` listener. From a host context, it goes to the extension's *other* host contexts that have one. Content scripts cannot message each other directly.

The Promise resolves with the first response any receiver gives. It resolves with `undefined` when every receiver finishes without responding. It rejects with `"Could not establish connection. Receiving end does not exist."` when no receiver is listening.

Only the message argument is used. The Chrome form `sendMessage(extensionId, message, options)` is not supported: the first argument is always taken as the message.

### `runtime.onMessage.addListener((message, sender, sendResponse) => ...)`

To respond, a listener either:

- calls `sendResponse(value)` before returning,
- returns `true` and calls `sendResponse(value)` later, or
- returns a Promise; its fulfillment value is the response, and its rejection becomes an error for the sender.

If no listener does any of these, the receiver declines. Only the first response across all receivers reaches the sender; later calls to `sendResponse` are ignored.

`sender` is:

| Field | Present when | Value |
| --- | --- | --- |
| `url` | always | the sending document's URL |
| `tab` | the sender is in a tab | a [tab object](#tab-objects) |
| `frameId` | the sender is in a tab | the sending frame's ID |

A sender in a WebKit 1 view (global page, popover, bar) carries only `url`. There is no `sender.id`.

### `runtime.connect([extensionId,] { name })` → `Port`

Opens a long-lived port. Its receivers are the same as for `runtime.sendMessage`: from a content script, the extension's host contexts with a `runtime.onConnect` listener; from a host context, the other host contexts with one. A string `extensionId` argument is ignored.

A port opened by one context can have several receivers. Each receiver gets `onConnect`. Messages the opener posts go to every receiver, and messages a receiver posts go to the opener only. The opener's port disconnects when the opener disconnects it or when its last receiver does. Messages posted before the receivers are known are queued and delivered in order.

If no receiver exists, the opener's `port.onDisconnect` fires with `runtime.lastError.message` set to `"Could not establish connection. Receiving end does not exist."` A receiving context with no `onConnect` listener disconnects the port at once.

### `runtime.onConnect.addListener(port => ...)`

The received `port` has `name` and `sender` (the opener, described as for `onMessage`).

### `Port`

| Member | Behavior |
| --- | --- |
| `name` | the name given to `connect` (`""` if none) |
| `sender` | on received ports only |
| `postMessage(message)` | throws `"Attempting to use a disconnected port object"` after disconnection |
| `disconnect()` | ends this side; the other side's `onDisconnect` fires |
| `onMessage` | `(message, port)` |
| `onDisconnect` | `(port)`; `runtime.lastError` is set during the call when the port failed to connect |

A port also disconnects when the context on the other side goes away: its document is replaced, its frame or tab closes, or its WebKit 1 view is destroyed.

### `runtime.getFrameId(target)` → `number` (content contexts only)

Returns the frame ID of a `Window` or of a frame element's (`<iframe>`, `<frame>`, `<object>`, `<embed>`) content frame, matching the IDs `webRequest` and `webNavigation` report. Throws `"Invalid target"` for anything else.

## `browser.dom` (content contexts only)

### `dom.openOrClosedShadowRoot(element)` → `ShadowRoot | null`

Returns the element's shadow root whether it is open or closed. Content-script worlds are set up so closed shadow roots are reachable through this call.

## `browser.tabs` (host contexts only)

### Tab objects

```js
{ id, url, title, status /* "loading" | "complete" */, incognito }
```

`url` is the page's active URL. There is no `index`, `windowId`, `active`, or `favIconUrl`; use `safari.application` for window and tab-order information.

### `tabs.get(tabId)` → `Promise<Tab>`

Rejects with `"No tab with id: <tabId>."` if the tab does not exist.

### `tabs.update(tabId, { url })` → `Promise<Tab>`

Loads `url` in the tab. `url` is the only supported property. The returned tab object describes the tab at the moment of the call, before the load starts. Rejects with `"No tab with this id."`.

### `tabs.reload(tabId, { bypassCache })` → `Promise<void>`

Reloads the tab, from the origin when `bypassCache` is `true`. An unknown tab is ignored.

### `tabs.remove(tabIdOrIds)` → `Promise<void>`

Closes one tab or an array of tabs. Unknown IDs are ignored.

### `tabs.sendMessage(tabId, message, { frameId })` → `Promise<any>`

Sends a one-shot message to the extension's contexts in a tab: to one frame when `frameId` is given, otherwise to every frame the tab currently shows (frames held in the back/forward cache are excluded). In each frame the receiver is the extension's page if the frame shows one, and otherwise the extension's content script. Response rules are those of `runtime.sendMessage`. A frame with no listening content script declines.

### `tabs.connect(tabId, { name, frameId })` → `Port`

Opens a port to the extension's contexts in a tab, with the same frame selection as `tabs.sendMessage`. With no `frameId`, one port reaches every frame.

### `tabs.executeScript(tabId, { code | file, frameId, allFrames, matchAboutBlank, runAt })` → `Promise<any[]>`

Runs code in the extension's content-script world of the target frames: `frameId` (default `0`), or every frame when `allFrames` is `true`.

- `file` is a path within the extension, resolved from the extension's root. Its text is fetched by the calling page and run as code.
- The code runs through indirect `eval`, so the result is the value of its last expression statement.
- `runAt` is `"document_start"`, `"document_end"`, or `"document_idle"` (default). `document_end` waits for `DOMContentLoaded`; `document_idle` waits for `DOMContentLoaded` and then one more task.
- Documents at `about:blank` or `about:srcdoc` are targets only when `matchAboutBlank` is `true`. With `allFrames`, they are skipped; a call whose only target is one rejects with `Cannot access contents of url "about:blank".`
- The Promise resolves with an array holding one result per frame that ran the code. A result that cannot be serialized to JSON becomes `null`.
- Frames that could not run the code are left out of the array. The call rejects only when no frame ran the code, with the first error: the code's exception message, `"No tab with this id."`, `"No frame with this id."`, `"The extension has no access to this frame."`, or `"Cannot access the contents of an extension page."` (the frame shows an extension page).
- The extension must have content scripts, because the code runs in the world Safari creates for them. A frame whose content-script world has no window object yet gets one created for the injection.

### `tabs.insertCSS(tabId, { code | file, frameId, allFrames, matchAboutBlank, runAt, cssOrigin })` → `Promise<void>`

Adds a style sheet to the target frames' current documents, with the frame selection, `matchAboutBlank`, `runAt`, and failure rules of `executeScript`.

- The sheet belongs to one document only and does not appear in `document.styleSheets`.
- `cssOrigin` is `"author"` (default) or `"user"`.
- A `file` sheet's URL is the file's own `safari-extension://` URL, so relative `url(...)` references inside it resolve against the file. A `code` sheet gets a unique URL of its own, as upstream's injected sheets do, and does not resolve relative references against the page.

### `tabs.removeCSS(tabId, { code | file, frameId, allFrames, matchAboutBlank, runAt, cssOrigin })` → `Promise<void>`

Removes every sheet this extension inserted into the target documents whose source text equals the given `code` (or the given file's text).

### Tab events

Tab events go to every extension's host contexts that listen for them.

| Event | Arguments |
| --- | --- |
| `tabs.onCreated` | `(tab)` |
| `tabs.onUpdated` | `(tabId, changeInfo, tab)`; `changeInfo` holds exactly one of `status`, `title`, `url` |
| `tabs.onRemoved` | `(tabId, { windowId: -1, isWindowClosing: false })` |

## `browser.webNavigation` (host contexts only)

Navigation events go to every extension's host contexts that listen for them. All carry `tabId`, `frameId`, `parentFrameId`, `url`, `processId` (always `-1`), and `timeStamp` (milliseconds since the epoch).

| Event | Additional fields |
| --- | --- |
| `onBeforeNavigate` | none |
| `onCommitted` | `transitionType`, `transitionQualifiers` |
| `onDOMContentLoaded` | none |
| `onCompleted` | none |
| `onErrorOccurred` | `error`, a network error name as `webRequest` reports it |
| `onCreatedNavigationTarget` | replaces the common fields with `sourceTabId`, `sourceFrameId`, `sourceProcessId` (`-1`), `tabId`, `url`, `timeStamp` |

`transitionType` is `"auto_subframe"` for subframes. For main frames it is `"reload"`, `"form_submit"`, `"link"`, or `"typed"` (a load the browser or the user started). A back/forward navigation reports the transition type of the history item's first commit. `transitionQualifiers` may contain `"forward_back"` and `"server_redirect"`.

### `webNavigation.getFrame({ tabId, frameId })` → `Promise<Frame | null>`

### `webNavigation.getAllFrames({ tabId })` → `Promise<Frame[] | null>`

```js
{ frameId, parentFrameId, url, errorOccurred }
```

Both describe the frames the tab currently shows. Frames kept in the back/forward cache are excluded. Both resolve with `null` for an unknown tab, and `getFrame` also resolves with `null` for an unknown frame.

## `browser.webRequest` (host contexts only)

Interception happens in the network process, at the same points WebKit applies its own content rules. Every request and redirect is checked, including pings, beacons, and CSP reports, as are redirect responses, responses from both the network and the disk cache, and WebSocket handshakes. Only `http`, `https`, `ws`, `wss`, and `safari-extension` URLs are visible. An extension sees web requests within its website access (see [`browser.cookies`](#browsercookies-host-contexts-only)), and requests for its own `safari-extension://` resources but never another extension's.

### Listeners and filters

```js
browser.webRequest.onBeforeRequest.addListener(listener, filter, extraInfoSpec);
```

- `filter.urls`: [match patterns](https://developer.chrome.com/docs/extensions/develop/concepts/match-patterns), including `<all_urls>`. A `*` scheme matches `http`, `https`, `ws`, and `wss`. The path part matches the URL's path, query, and fragment.
- `filter.types`: resource types (below).
- `filter.tabId`: a tab ID.
- `filter.windowId` is ignored.
- `extraInfoSpec`:
  - `"blocking"` makes the listener's return value (or the fulfillment value of a returned Promise) the listener's verdict.
  - `"asyncBlocking"` (for `onAuthRequired`) passes the listener a callback as its second argument, and the value it calls that with is the verdict.
  - `"requestHeaders"` gives the listener `requestHeaders` (`onBeforeSendHeaders`, `onSendHeaders`).
  - `"responseHeaders"` gives the listener `responseHeaders` (`onHeadersReceived`, `onResponseStarted`, `onBeforeRedirect`, `onCompleted`).
  - `"requestBody"` gives the listener `requestBody` (`onBeforeRequest`).
  - `"extraHeaders"` gives the listener, and lets its verdict change, the headers Chrome withholds without it: the `Accept-Language`, `Accept-Encoding`, `Referer`, `Cookie`, and `Origin` request headers and the `Set-Cookie` response header. A verdict from a listener without it leaves those headers as they were.

Each blocking listener's filter is evaluated in the network process, so a load no blocking filter matches never waits on the extension. Listeners without `"blocking"` are notified asynchronously and their return values are ignored.

### Events

| Event | Can block | Fields beyond the common ones |
| --- | --- | --- |
| `onBeforeRequest` | yes: `cancel`, `redirectUrl` | `requestBody` |
| `onBeforeSendHeaders` | yes: `cancel`, `requestHeaders` | `requestHeaders` |
| `onSendHeaders` | no | `requestHeaders` |
| `onHeadersReceived` | yes: `cancel`, `redirectUrl`, `responseHeaders` | `statusCode`, `statusLine`, `responseHeaders`, `fromCache` |
| `onAuthRequired` | yes: `cancel`, `authCredentials` | `scheme`, `realm`, `challenger` (`host`, `port`), `isProxy`, `statusCode`, `statusLine`, `responseHeaders`, `fromCache` |
| `onResponseStarted` | no | `statusCode`, `statusLine`, `responseHeaders`, `fromCache` |
| `onBeforeRedirect` | no | `redirectUrl`, `statusCode`, `statusLine`, `responseHeaders`, `fromCache` (`url` is the URL redirected from) |
| `onCompleted` | no | `statusCode`, `statusLine`, `responseHeaders`, `fromCache` |
| `onErrorOccurred` | no | `error`, `fromCache` |

A load's events come in Chrome's order: `onBeforeRequest`, `onBeforeSendHeaders`, `onSendHeaders`, then `onHeadersReceived` for each response. A redirect response is followed by `onBeforeRedirect` and the redirected request's `onBeforeRequest`; a final response is followed by `onResponseStarted` and `onCompleted` (or `onErrorOccurred`). A redirect an extension makes reports `onBeforeRedirect` with a synthetic response and no `onHeadersReceived` of its own: `307 Internal Redirect` for one made in `onBeforeRequest`, `302 Found` for one made in `onHeadersReceived`.

`requestHeaders` are the headers the request is sent with. For `"extraHeaders"` listeners they include the fields the network layer adds to a request that has none of its own: the `Cookie` header it generates, and its `Accept-Language` and `Accept-Encoding`. A verdict that changes one of these sends the new value; one that removes it sends no such field. Removing `Accept-Encoding` still decodes a response the server compresses anyway. Stored-credential `Authorization` headers are added later and are not shown, as in Chrome.

A `Cookie` header an `onBeforeSendHeaders` verdict changes or removes is the one sent for that exchange only: each redirect generates its own. The `Set-Cookie` headers of a response are stored after its `onHeadersReceived` verdicts, so a verdict that removes or changes them stores the result, and a cancelled response stores none. A redirect's cookies are stored before the redirect is followed, so the redirected request carries them. Responses to authentication challenges store their cookies at once.

`requestBody` is present when the request has a body:

- `formData`: for a `POST` whose body is `application/x-www-form-urlencoded` or `multipart/form-data`, an object mapping each field name to an array of its values. A file field's value is its filename.
- `raw`: for any other body, or a form body that does not parse, an array of `{ bytes: ArrayBuffer }` and `{ file: path }` elements.

Common fields: `requestId`, `url`, `method`, `type`, `timeStamp`, `tabId` (`-1` for a load that belongs to no tab, such as one from a WebKit 1 extension view), `frameId`, `parentFrameId`, and, for subresources, `documentUrl` and `initiator` (the requesting origin).

`requestId` is a string, stable for a load across its events: `"<network pid>-<n>"`, `"<network pid>-ping-<n>"` for pings and beacons, `"<network pid>-ws-<n>"` for WebSockets.

`type` is one of the `browser.webRequest.ResourceType` values: `main_frame`, `sub_frame`, `stylesheet`, `script`, `image`, `font`, `object`, `xmlhttprequest` (XHR, fetch, and EventSource), `ping` (pings and beacons), `csp_report`, `media`, `websocket`, `other`. Workers, worklets, and JSON modules are `script`, and XSLT is `stylesheet`.

`error` is a Chrome network error name: `net::ERR_BLOCKED_BY_CLIENT` for loads an extension cancelled, and otherwise `net::ERR_ABORTED`, `net::ERR_TIMED_OUT`, `net::ERR_INVALID_URL`, `net::ERR_UNKNOWN_URL_SCHEME`, `net::ERR_NAME_NOT_RESOLVED`, `net::ERR_CONNECTION_REFUSED`, `net::ERR_CONNECTION_CLOSED`, `net::ERR_TOO_MANY_REDIRECTS`, `net::ERR_INTERNET_DISCONNECTED`, `net::ERR_INVALID_RESPONSE`, `net::ERR_FILE_NOT_FOUND`, `net::ERR_SSL_PROTOCOL_ERROR`, `net::ERR_CERT_DATE_INVALID`, `net::ERR_CERT_AUTHORITY_INVALID`, or `net::ERR_FAILED`.

A WebSocket handshake reports only `onBeforeRequest`, with `type: "websocket"` and `method: "GET"`.

A successful cache revalidation (a `304` for a cached entry) reports the cached response, with `fromCache: true`, not the `304`.

### Blocking verdicts

| Verdict | Effect |
| --- | --- |
| `{ cancel: true }` in `onBeforeRequest` | The load fails with `net::ERR_BLOCKED_BY_CLIENT`, as a load WebKit's content rules block does; a main-frame navigation shows Safari's error page for it. A WebSocket fails and closes with code `1006`. |
| `{ redirectUrl }` in `onBeforeRequest` | A main-frame navigation follows a `307 Internal Redirect` to the new URL, keeping its method and body, so the address and history show it. Any other request loads the new URL in place, as WebKit's content rules redirect one, after `onBeforeRedirect` and the new URL's own `onBeforeRequest`. An invalid URL is ignored. After 20 such redirects the load fails. |
| `{ cancel: true }` in `onBeforeSendHeaders` | As `cancel` in `onBeforeRequest`. |
| `{ requestHeaders }` in `onBeforeSendHeaders` | Replaces the request's header fields. |
| `{ cancel: true }` in `onHeadersReceived` | As `cancel` in `onBeforeRequest`. |
| `{ redirectUrl }` in `onHeadersReceived` | The response becomes a `302 Found` to the new URL, as Chrome rewrites it: the redirected request starts over at `onBeforeRequest`, a `POST` becoming a `GET`. A response from the cache, or one the cache revalidated, redirects the same way, without the revalidation's conditional headers. For a redirect response, the redirect goes to the new URL instead, and a request that leaves the redirect's origin loses its `Authorization`, `Origin`, and `Cookie` headers. |
| `{ responseHeaders }` in `onHeadersReceived` | Replaces the response's header fields, including for cached responses, before any `redirectUrl` of the same verdict applies. For a redirect response, a changed `Location` header moves the redirect to the new location. |
| `{ authCredentials: { username, password } }` in `onAuthRequired` | Answers the challenge with those credentials, kept for the session as the browser keeps its own. If they fail, the next challenge asks again. |
| `{ cancel: true }` in `onAuthRequired` | Continues without credentials, so the `401` or `407` response is the load's, as Chrome cancels the authentication. |

An `onAuthRequired` challenge no verdict answers goes to Safari's own authentication sheet. Only HTTP and proxy authentication reach `onAuthRequired`: `basic`, `digest`, `ntlm`, `negotiate`, or the first token of the challenge header for another scheme.

A redirect an extension makes may go to any scheme, as Chrome allows: a navigation can be sent to one of the extension's own pages. WebKit fails a subresource's redirect to a `data:` URL, so a subresource sent to `data:` loads it in place, after `onBeforeRedirect`. A main-frame navigation to a `data:` URL is refused, as WebKit refuses every top-level `data:` document the page did not load itself.

Fields that do not apply to the event are ignored: `requestHeaders` outside `onBeforeSendHeaders`, `responseHeaders` outside `onHeadersReceived`, and `redirectUrl` outside `onBeforeRequest` and `onHeadersReceived`.

When several listeners answer, whether in one extension or across extensions, they merge as Chrome merges them: any cancel wins, the first `redirectUrl` and the first `authCredentials` win, and a later header array replaces an earlier one. Within an extension, listeners run in registration order and each later listener sees the headers an earlier one set.

A listener that throws is logged and skipped. A context that goes away while a load waits on it stops being waited on.

### `webRequest.handlerBehaviorChanged()` → `Promise<void>`

Empties the in-memory caches of the Safari process and of every web content process, so resources held there reach `webRequest` again. `MAX_HANDLER_BEHAVIOR_CHANGED_CALLS_PER_10_MINUTES` is `20`. Calls beyond it still empty the caches, as Chrome's do.

## `browser.cookies` (host contexts only)

Cookies of the sites the extension's website access covers: the `Website Access` of its `Info.plist` `Permissions`, which Safari 7 also applies to its content scripts. Safari's process reads it when the extension's first page appears, and applies it to the cookies it answers with and acts on, to `onChanged`, and to `webRequest`. `Level` `All` covers every site, `Some` the `Allowed Domains` (a host, or `*.host` for the host and its subdomains), and `None` no site. Secure pages count only with `Include Secure Pages`. A cookie's site is its domain, over `https` for a secure cookie.

### Cookie objects

```js
{ name, value, domain, hostOnly, path, secure, httpOnly, sameSite, session, expirationDate, storeId }
```

`sameSite` is `"no_restriction"`, `"lax"`, or `"strict"`. `expirationDate` is in seconds since the epoch, and absent for a session cookie.

### Stores

`storeId` `"0"` is the store Safari's tabs use, and `"1"` the private browsing store, while a tab uses it. Methods take an optional `storeId`, `"0"` by default.

### `cookies.get({ url, name, storeId })` → `Promise<Cookie | null>`

The cookie a request to `url` would send with that name: the one with the longest path, then the earliest created. Rejects when the extension's website access does not cover `url`.

### `cookies.getAll({ url, domain, name, path, secure, session, storeId })` → `Promise<Cookie[]>`

The store's cookies the website access covers, narrowed by each given field: `url` to those a request to it would send, `domain` to that domain and its subdomains, the rest to exact matches. They come longest path first, then earliest created.

### `cookies.set({ url, name, value, domain, path, secure, httpOnly, sameSite, expirationDate, storeId })` → `Promise<Cookie | null>`

Sets a cookie for `url`: host-only without `domain`, on the domain and its subdomains with it; the directory of `url`'s path without `path`; a session cookie without `expirationDate`. Resolves with the cookie as stored. WebKit's cookie store does not let a cookie without `httpOnly` replace a stored HttpOnly cookie of the same name, domain, and path, as the macOS cookie store it follows does not; such a call leaves the stored cookie, and resolves with it.

### `cookies.remove({ url, name, storeId })` → `Promise<{ url, name, storeId } | null>`

Removes the cookie `cookies.get` would return. Resolves with `null` when there is none.

### `cookies.getAllCookieStores()` → `Promise<{ id, tabIds }[]>`

### `cookies.onChanged`

`({ removed, cookie, cause })` for each cookie that appears, changes, or goes, within the extension's website access. A changed cookie reports its removal with cause `"overwrite"` and then its addition with cause `"explicit"`. A cookie that goes after its expiration date reports `"expired"`; any other removal or addition reports `"explicit"`.

## Clipboard (host contexts only)

In the extension's own pages, `navigator.clipboard.writeText()` and `navigator.clipboard.readText()` work at any time, with no user gesture and no focus required, as they do in a WebExtension's pages with the clipboard permissions.

- `writeText(text)` writes plain text to the general pasteboard. In a private browsing page, the pasteboard entry expires as WebKit's ephemeral pasteboard data does.
- `readText()` reads the pasteboard's plain text. It resolves with `""` when there is no text.
- A call that fails rejects with a `NotAllowedError` `DOMException`.

Content scripts keep the page's clipboard rules.

WebKit 1 extension views (global page, popovers, bars) also have WebCore's asynchronous Clipboard API enabled, as WebKit 2 views have by default.

## Engine behaviors for extension pages and content scripts

These need no API calls.

- **Root-relative URLs in extension documents.** Safari 7 serves an extension's files at `safari-extension://<key>/<token>/<path>`, where `<token>` is fixed for each Safari launch. In an extension document, a root-relative reference such as `/js/app.js` resolves under `safari-extension://<key>/<token>/`, as a WebExtension's resolves against its origin. `/x.js` and `./x.js` from a root-level page name the same file, including for ES module identity.
- **`safari-extension:` is a secure scheme that bypasses Content Security Policy.** An extension's resources load into pages whatever the page's CSP allows.
- **Inline scripts from content scripts ignore the page's CSP.** An inline classic or module script, import map, or speculation rules element that a content-script world inserts runs even where the page's CSP forbids inline script, just as that world's own fetches, WebSockets, and workers are not subject to the page's CSP.
- **Blobs in the global page.** `blob:` URLs and `FileReader` work in the WebKit 1 global page; the extension scheme is registered with the Safari process's scheme registry.
- **`beforeload` for scripts.** Classic and module `<script>` loads dispatch the cancelable `beforeload` event, which Safari 7 content blockers rely on.

## Packaging notes for Safari 7

Safari 7's extension resource protocol has limits that apply to every file in the bundle, whichever API reads it:

- **A file with no extension crashes Safari** when it is loaded. Give every file an extension (for example, rename `serverlist` to `serverlist.txt`).
- **A zero-byte file is served as a directory** and fails with a permission error. Give it content (`/* */` for an empty script or style sheet).
- **Only `.html`, `.js`, and `.png` get a MIME type.** Other files are served without one.
- **A missing file fails like a network error** (a synchronous XHR throws `NetworkError`, and status is `0`), not with a 404.
- **URLs without the launch token fail.** `safari-extension://<key>/<path>` without `<token>/` fails with error `-1000`. Build URLs from `safari.extension.baseURI`, or use root-relative references from extension documents.

## Testing

`MavericksSupport/tests/legacy-extensions/` holds `api-test.safariextension`, which exercises every namespace against a local server (`server.py`, ports 8843 and 8844), and `limited-access.safariextension`, whose website access is `localhost` alone. Build the extensions in Safari's Extension Builder, then open `pages/coverage.html` from the server; results collect in `window.__results`. Extension Builder installs do not persist across Safari relaunches; click Install again after relaunching.
