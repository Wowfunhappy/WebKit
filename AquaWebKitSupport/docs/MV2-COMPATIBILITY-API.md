# MV2 compatibility API for Safari 7 extensions

This WebKit gives Safari 7 legacy extensions (`.safariextension` bundles) a `browser` namespace modeled on the WebExtensions (MV2) API. It sits alongside Safari 7's own `safari.extension` / `safari.application` / `safari.self` API, which stays fully available. Use `browser` for what Safari 7 cannot do: messaging addressed by tab and frame, script and style injection on demand, network interception and response filtering, navigation events, cookies, document viewers, privacy settings, and the clipboard.

The engine provides only what needs the engine. Anything an extension can build from `safari.*` or the web platform, such as `runtime.getURL`, `storage`, `tabs.query`, `tabs.create`, and menus, is left to the extension's own platform layer (the uBlock Origin port's `browser-safari.js`, for example, builds these on top).

Not provided: the `ip` field of `webRequest` details, and the `documentId`, `documentLifecycle`, and `frameType` fields Chrome added after MV2.

Sources:

| Part | Path |
| --- | --- |
| The JavaScript API | `AquaWebKitSupport/source/WebKit/Shared/LegacyExtensions/LegacyExtensionAPI.js` |
| UI-process router | `AquaWebKitSupport/source/WebKit/UIProcess/LegacyExtensions/LegacyExtensionHost.{h,cpp}` |
| Web-content side | `AquaWebKitSupport/source/WebKit/WebProcess/LegacyExtensions/LegacyExtensionContent.{h,cpp}` |
| Network side (webRequest) | `AquaWebKitSupport/source/WebKit/NetworkProcess/LegacyExtensions/LegacyExtensionNetwork.{h,cpp}`, with `LegacyExtensionResponseFilter.{h,cpp}` for `filterResponseData` |
| mimeHandler | `AquaWebKitSupport/source/WebKit/UIProcess/LegacyExtensions/LegacyExtensionMimeHandlers.{h,cpp}`, `AquaWebKitSupport/source/WebCore/html/LegacyExtensionMimeHandlerDocument.{h,cpp}` |
| privacy | `AquaWebKitSupport/source/WebKit/UIProcess/LegacyExtensions/LegacyExtensionPrivacy.{h,cpp}` |
| declarativeNetRequest | `AquaWebKitSupport/source/WebKit/UIProcess/LegacyExtensions/LegacyExtensionDeclarativeNetRequest.{h,mm}`, on WebKit's own implementation in `Source/WebKit/UIProcess/Extensions/` |
| Clipboard | writes: `WebLegacyExtensionPageObserver.mm` (WebKit 1 preferences) and `LegacyExtensionContent.cpp` (web content pages); reads: `AquaWebKitSupport/source/WebKit/UIProcess/LegacyExtensions/LegacyExtensionClipboard.mm` |
| WebKit 1 page hooks | `AquaWebKitSupport/source/WebKitLegacy/mac/LegacyExtensions/WebLegacyExtensionPageObserver.mm` |
| Root-relative URLs | `AquaWebKitSupport/source/WTF/wtf/LegacyExtensionURL.{h,cpp}` |
| Test extension and server | `AquaWebKitSupport/tests/legacy-extensions/` |

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
| `browser.declarativeNetRequest` | yes | no |
| `browser.mimeHandler` | yes | no |
| `browser.privacy` | yes | no |
| `navigator.clipboard` without the page's restrictions | yes | no (page rules apply) |

`browser` is a writable, configurable, non-enumerable property of the global object. There is no `chrome` alias.

A context belongs to one document. When its frame shows another document, or when Safari withdraws the extension's content-script world (the extension is disabled or reloaded), the old context's `browser` object goes inert: its calls are dropped and its ports disconnect.

### Identifiers

- **Tab IDs** are positive integers, one per WebKit 2 page (the page's `WebPageProxyIdentifier`). Safari 7's WebKit 1 views (global page, popovers, bars) are not tabs.
- **Frame IDs** are `0` for a tab's main frame and the frame's `FrameIdentifier` otherwise. `parentFrameId` is `-1` for a main frame.
- **Extension key**: the host of the extension's `safari-extension://` URLs. It scopes every route: an extension's messages, ports, and injections reach only that extension's contexts.

### Calling conventions

Every method that returns a Promise also accepts a trailing callback, as Chrome's do. With a callback, the method returns `undefined`, and a failure calls the callback with no arguments while `browser.runtime.lastError` is set to `{ message }`. `lastError` is defined only while that callback runs.

Every message crossing between contexts is serialized as JSON. Values JSON cannot represent (functions, `undefined` members, cyclic objects, DOM nodes) do not survive the trip. A StreamFilter's bytes travel as bytes.

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

Interception happens in the network process, at the same points WebKit applies its own content rules, and, for the loads of the WebKit 1 extension views (global page, popovers, bars), in the Safari process where WebKit 1 hands each request to the network. Every request and redirect is checked, including pings, beacons, and CSP reports, as are redirect responses, responses from both the network and the disk cache, and WebSocket handshakes. An extension sees its own views' requests, workers' included, as Chrome shows an extension its background page's; another extension sees them within its website access. A synchronous `XMLHttpRequest` from a WebKit 1 view reports its events, but no verdict applies to it: the listeners run on the thread it blocks. Only `http`, `https`, `ws`, `wss`, and `safari-extension` URLs are visible. An extension sees web requests within its website access (see [`browser.cookies`](#browsercookies-host-contexts-only)), and requests for its own `safari-extension://` resources but never another extension's.

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

`requestHeaders` are the headers the request is sent with. A changed `Origin` is sent as the verdict has it; WebKit's CORS check still compares a response's `Access-Control-Allow-Origin` with the requesting document's origin, which an `onHeadersReceived` verdict can rewrite. For `"extraHeaders"` listeners they include the fields the network layer adds to a request that has none of its own: the `Cookie` header it generates, and its `Accept-Language` and `Accept-Encoding`. A verdict that changes one of these sends the new value; one that removes it sends no such field. Removing `Accept-Encoding` still decodes a response the server compresses anyway. Stored-credential `Authorization` headers are added later and are not shown, as in Chrome.

A `Cookie` header an `onBeforeSendHeaders` verdict changes or removes is the one sent for that exchange only: each redirect generates its own. The `Set-Cookie` headers of a response are stored after its `onHeadersReceived` verdicts, so a verdict that removes or changes them stores the result, and a cancelled response stores none. A redirect's cookies are stored before the redirect is followed, so the redirected request carries them. Responses to authentication challenges store their cookies at once.

`requestBody` is present when the request has a body:

- `formData`: for a `POST` whose body is `application/x-www-form-urlencoded` or `multipart/form-data`, an object mapping each field name to an array of its values. A file field's value is its filename.
- `raw`: for any other body, or a form body that does not parse, an array of `{ bytes: ArrayBuffer }` and `{ file: path }` elements.

Common fields: `requestId`, `url`, `method`, `type`, `timeStamp`, `tabId` (`-1` for a load that belongs to no tab, such as one from a WebKit 1 extension view), `frameId` (`0` for the main frame of a tab or a WebKit 1 view), `parentFrameId`, and, for subresources, `documentUrl` and `initiator` (the requesting origin).

`requestId` is a string, stable for a load across its events: `"<network pid>-<n>"`, `"<network pid>-ping-<n>"` for pings and beacons, `"<network pid>-ws-<n>"` for WebSockets. A WebKit 1 view's loads use the Safari process's pid, and `"<pid>-sync-<n>"` for synchronous requests.

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

### Displaying or downloading a response

A tab downloads a main-frame response it cannot show, such as a PDF or an archive. It also downloads an audio or video file unless the user turns on `AquaWebKitPlayMediaFilesInline` (see `AquaWebKitSupport/README.md`), whatever its headers say. An `onHeadersReceived` verdict for a `main_frame` request changes which other responses download:

- `redirectUrl` set to one of the extension's own pages, as `` `${safari.extension.baseURI}viewer.html?file=${encodeURIComponent(details.url)}` ``, opens the response in a viewer the extension supplies; PDF viewers such as pdf.js work this way. The page reads the file with `fetch(file, { credentials: 'include' })`: Safari 7 lets an extension page read the sites its website access covers without CORS headers, and a tab showing an extension page sends those sites' cookies, as a WebExtension's own pages do. The redirect re-requests the file, so check `details.method` and redirect only `GET`s.
- `responseHeaders` with another `Content-Type` shows the response as that type, for example `text/plain` for a text file served as `application/octet-stream`.
- `responseHeaders` with `Content-Disposition: attachment` downloads a response the tab would show. A `filename` parameter names the file.

The test rig's `display-or-download.safariextension` exercises each of these.

### `webRequest.filterResponseData(requestId)` → `StreamFilter`

Firefox's [`StreamFilter`](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/webRequest/StreamFilter): the response body of the load whose `requestId` a `webRequest` event reported goes to the filter, and what the filter writes is the body the page receives. The filter is created in the network process before the body reaches the page, which a blocking listener of the load's `onBeforeRequest` or `onHeadersReceived` guarantees. Bodies from the network and from the disk cache are filtered alike; the disk cache stores the body as the network sent it, so a cached response is filtered again each time it loads.

| Member | Behavior |
| --- | --- |
| `status` | `"uninitialized"`, `"transferringdata"`, `"finishedtransferringdata"`, `"suspended"`, `"closed"`, `"disconnected"`, or `"failed"` |
| `error` | the error's message, once `onerror` has fired |
| `onstart` | the body is about to arrive; from here on `write()` works |
| `ondata` | `event.data` is the next chunk, an `ArrayBuffer` |
| `onstop` | the body has all arrived; `write()` still works until `close()` |
| `onerror` | the filter failed |
| `write(data)` | adds an `ArrayBuffer` or `Uint8Array` to the body the page receives |
| `close()` | ends the body the page receives; the rest of the response is discarded |
| `disconnect()` | the rest of the response, including chunks already sent to the filter but not yet dispatched, reaches the page unfiltered |
| `suspend()`, `resume()` | hold and release the filter's data events |

The handlers are event handler attributes; `addEventListener` works too. A method called in a status that does not allow it throws `Error("Invalid state")`. The page receives nothing of the body until the filter writes, and the load does not finish until the filter is closed or disconnected. A filter whose extension context goes away disconnects.

Several filters of one load chain, as Firefox chains them: the filter attached last reads the body first, and what it writes is the input of the filter attached before it.

The filter fails with `"Invalid request ID"` when no load of the network process has the `requestId`, when the extension's website access does not cover the load, when a service worker answers the load, or when the page has already received some of its body. A WebKit 1 view's loads, pings, and WebSockets have no body to filter. A load that fails or is cancelled fails its filters with its `net::` error name, and one a service worker turns out to answer fails them with `"The response came from a service worker."`; a page a service worker serves reaches `webRequest` only through the service worker's own requests.

### `webRequest.handlerBehaviorChanged()` → `Promise<void>`

Empties the in-memory caches of the Safari process and of every web content process, so resources held there reach `webRequest` again. `MAX_HANDLER_BEHAVIOR_CHANGED_CALLS_PER_10_MINUTES` is `20`. Calls beyond it still empty the caches, as Chrome's do.

## `browser.declarativeNetRequest` (host contexts only)

WebKit's own declarativeNetRequest, the one it gives a WebExtension: rules are validated, stored, and translated to a WebKit content rule list by WebKit's implementation, and the content rule list engine applies them to every load of every tab. The rule format, priorities, limits, and error messages are that implementation's ([Chrome's documentation](https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest) describes the format).

| Member | |
| --- | --- |
| `updateDynamicRules({ addRules, removeRuleIds })`, `getDynamicRules({ ruleIds })` | Rules that persist across launches, in `~/Library/WebKit/<app>/WebExtensions/Default/<extension key>/`. |
| `updateSessionRules({ addRules, removeRuleIds })`, `getSessionRules({ ruleIds })` | Rules that last while the extension is loaded. |
| `updateEnabledRulesets({ enableRulesetIds, disableRulesetIds })`, `getEnabledRulesets()` | The static rulesets (below) that apply. The choice persists. |
| `getMatchedRules({ tabId, minTimeStamp })` | `{ rulesMatchedInfo: [{ request: { url }, timeStamp, tabId }] }` for the last five minutes' loads within the extension's website access that matched its rules. |
| `isRegexSupported({ regex, isCaseSensitive, requireCapturing })` | `{ isSupported }`, with `reason: "syntaxError"` when the content rule list engine cannot compile the expression. |
| `setExtensionActionOptions({ displayActionCountAsBadgeText, tabUpdate: { tabId, increment } })` | The count of the loads that matched the extension's rules since the tab's page committed, on the badge of the extension's toolbar items (below). |
| `MAX_NUMBER_OF_STATIC_RULESETS`, `MAX_NUMBER_OF_ENABLED_STATIC_RULESETS`, `MAX_NUMBER_OF_DYNAMIC_AND_SESSION_RULES` | 100, 50, 30000. |

An invalid argument or rule rejects the call's Promise with WebKit's message for it, as `"Invalid call to declarativeNetRequest.updateDynamicRules(). The 'addRules' value is invalid, because an error with rule at index 0: …"`.

**Static rulesets** are declared in Info.plist under the key a WebExtension manifest uses, with its keys:

```xml
<key>declarative_net_request</key>
<dict>
    <key>rule_resources</key>
    <array>
        <dict>
            <key>id</key><string>ruleset_1</string>
            <key>enabled</key><true/>
            <key>path</key><string>rules_1.json</string>
        </dict>
    </array>
</dict>
```

Each `path` names a rules file in the extension, relative to its root. Like every file in a Safari 7 extension, it needs a file extension (see [Packaging notes](#packaging-notes-for-safari-7)).

**Which loads and when.** An extension's rules apply to every tab's loads, including private windows', from when its first page loads (its global page, at Safari's launch) until none of its pages is open, as when Safari disables or reloads it. Its session rules last as long; a page reloading itself keeps them. They do not apply to the loads of the extension's own WebKit 1 views. `block`, `allow`, `allowAllRequests`, and `upgradeScheme` rules act on any URL. `redirect` and `modifyHeaders` rules act only on URLs within the extension's website access, as a WebExtension's need host permissions for them. A `redirect` to an `extensionPath` goes to the extension's file of that path.

**The badge.** With `displayActionCountAsBadgeText`, the badge of the extension's toolbar items in Safari's active browser window (its frontmost) shows the count for that window's active tab, and follows it as windows and tabs are activated, whether or not Safari is the active application. An extension that does not ask for it keeps its badge to itself.

## `browser.mimeHandler` (host contexts only)

[Chrome's document viewers](https://developer.chrome.com/docs/extensions/reference/api/mimeHandler): a document whose response has a type the extension handles shows the extension's handler page in a frame filling it, while the address bar keeps the document's URL. The handler page reads the response through `getStreamInfo()`; the response is loaded once.

The handler is declared in Info.plist under the key a WebExtension manifest uses, with its keys. `handler_url` is a path in the extension; `can_embed` also shows the handler in `<embed>`, `<object>`, and frames, not only top-level documents:

```xml
<key>mime_types_handler</key>
<dict>
    <key>application/pdf</key>
    <dict>
        <key>handler_url</key><string>viewer.html</string>
        <key>can_embed</key><true/>
    </dict>
</dict>
```

`application/pdf` is the only type an extension can handle, as in Chrome; other types are ignored. When several extensions handle a type, the one Safari loaded last, which is the one installed last, shows it. A frame below the top level whose handler does not embed gets the response as it would with no handler. A response with `Content-Disposition: attachment` still downloads.

| Member | |
| --- | --- |
| `getStreamInfo()` | `{ embedded, mimeType, originalUrl, responseHeaders, streamUrl, tabId }`, in the handler page, once the whole response has arrived. `responseHeaders` maps each header name to its value. `streamUrl` is a `blob:` URL of the handler page holding the body; read it with `fetch()`. Rejects with `"No stream is attached to this page."` anywhere else, and with `"The stream failed."` when the load failed. |
| `abortAndFallbackToNativeHandler()` | Removes the handler page and downloads the response, as a navigation of the document's frame to it with a `download` attribute does: through Safari's policy, loading the URL again. |
| `getMimeHandlerOptions(mimeType)`, `setMimeHandlerOptions(mimeType, { enabled })` | Whether the extension's handler serves the type, `true` by default. The choice persists, in the directory of the extension's `declarativeNetRequest` rules. |

## `browser.privacy` (host contexts only)

ChromeSettings with `get(details)` → `Promise<{ value, levelOfControl }>`, `set({ value, scope })`, `clear({ scope })`, and `onChange`, which reports `{ value, levelOfControl }` as the listening extension sees the setting:

| Setting | `false` turns off |
| --- | --- |
| `privacy.network.networkPredictionEnabled` | DNS prefetching (`<link rel="dns-prefetch">` and link hosts) and the preconnections pages ask for with `<link rel="preconnect">` |
| `privacy.websites.hyperlinkAuditingEnabled` | the pings of `<a ping>`; `navigator.sendBeacon()` is unaffected |

`scope` is `"regular"`, the default, which covers every tab, private windows included; other scopes reject, as in Firefox. A value must be a boolean. A setting's value is that of the extension Safari loaded last among those that set it, and `true` when none did; `levelOfControl` is `"controlled_by_this_extension"`, `"controlled_by_other_extensions"`, or `"controllable_by_this_extension"`. An extension's value persists until it calls `clear()`, and applies while the extension is loaded.

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

In the extension's own pages, `navigator.clipboard.write()`, `navigator.clipboard.writeText()` and `navigator.clipboard.readText()` work at any time, with no user gesture and no focus required, as they do in a WebExtension's pages with the clipboard permissions.

- `write(items)` and `writeText(text)` are WebKit's own: `write()` takes `ClipboardItem`s, including images (`image/png` is decoded and re-encoded, `text/html` sanitized, `text/uri-list` link-decoration filtered). In a private browsing page, their pasteboard entries expire as WebKit's ephemeral pasteboard data does.
- `readText()` reads the pasteboard's plain text. It resolves with `""` when there is no text, and rejects with a `NotAllowedError` `DOMException` when it fails.

Content scripts keep the page's clipboard rules.

WebKit 1 extension views (global page, popovers, bars) also have WebCore's asynchronous Clipboard API enabled, as WebKit 2 views have by default, and their `javaScriptCanAccessClipboard` preference on, so `document.execCommand("copy")` and `"cut"` work there without a gesture too.

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

`AquaWebKitSupport/tests/legacy-extensions/` holds the server, browser fixtures and native/API test drivers. Extension bundles and extension-owned JavaScript live outside the WebKit checkout, in the separate sibling `AquaWebKit-Extensions/` workspace. Load the bundles from that external workspace in Safari's Extension Builder.

`api-test.safariextension` exercises every namespace against the local server (`server.py`, ports 8843 and 8844, and 8845, which counts preconnections). `response-filter.safariextension` rewrites `/filter/` responses and sets the privacy settings `pages/filter.html` asks for (results in `window.__results`). `mime-handler.safariextension` displays `/mime/` PDFs and reports reads to the server log; `/mime/embed.html` embeds one, and `/mime-options/false` and `/mime-options/true` set its option. `limited-access.safariextension` has website access to `localhost` alone. `declarative-net-request.safariextension` applies rules to `pages/dnr.html` (results in `window.__results`; API calls in the server log as `dnr-api`).

`display-or-download.safariextension` decides whether `/inline/` responses display or download: open `/inline/login`, `/inline/doc.pdf` (viewer result in `window.__result`), `/inline/data.bin` and `/inline/force-download.html`, and the unaffected `/plain/` equivalents. `/plain/clip.mp4` and `/plain/server-inline.mp4` download unless `AquaWebKitPlayMediaFilesInline` is on. `hidden-tabs.safariextension` hides and shows tabs via `window.postMessage({ hiddenTabs: operation, args })`; its `global.js` lists operations, with answers in `window.__hiddenTabsResult`. Open `pages/coverage.html` from the server for aggregate results in `window.__results`. Extension Builder installs do not persist across Safari relaunches; click Install again after relaunching.

## The aqua namespace

`aqua` is a non-enumerable global in extension content scripts and extension pages. `aqua.tabs` is in every extension page: the global page, popovers, and pages loaded in tabs or frames. `aqua.mediaPlayer.createSession` and `withHandoff` are in content scripts and extension pages loaded in tabs or frames, where media elements are available. Extension pages also have `prepareHandoff` and `cancelHandoff` for dispatching a handoff from browser chrome. Web pages cannot see `aqua`.

### aqua.mediaPlayer

The native API exposes capabilities through `aqua.mediaPlayer.capabilities`: `version: 1`, `sessions`, `urlSources`, `captureSources`, `playerControl`, `resources`, `playlistProvider`, and `resourceByteLimit`. It provides media/session capabilities; handoff orchestration is extension code.

```js
const session = await aqua.mediaPlayer.createSession(video, {
    textTracks: Array.from(video.textTracks).filter(track => track.mode === "showing"),
});
const info = await session.inspect();
const source = await session.publish({ url: info.sources[0] });
const player = await source.open({
    application: "com.apple.QuickTimePlayerX",
    adapter: { position: "time", duration: "durn", rate: "rate",
               play: "MVWRplay", pause: "MVWRpaus" },
    timeout: 30,
});
await player.play(); // An explicit, separate operation.
await player.closed;
```

Session handles are bound to the creating extension world, document and media element. Creation requires a loaded media player and same-origin access. Each media element has one active native binding. Replaced documents and withdrawn extension worlds invalidate commands; they also release unopened sources and browser-route presentation. Already-owned receivers retain their independent resource lifetime.

#### Browser session

All operations return promises.

| Method | Contract |
| --- | --- |
| `inspect()` | Returns `sources` (safe native HTTP(S) candidates), `requiresCapture`, `canConnect`, and `tracksValid`. Selected external text tracks require capture. |
| `present(mode, message?)` | `opening` suppresses physical inline audio/video and shows the supplied plain-text opening label; `external` shows the handoff placard; `inline` releases presentation and disconnects any route. |
| `connect(message?)` | Selects a virtual external route, suppresses inline output, and emits native wireless/connecting notifications. The page may select its remote source. Remote-playback opt-out rejects this operation. |
| `confirmConnection()` | Marks the selected route connected after the media backend has metadata. Duration, current time, seekability and readiness remain the actual browser backend's state. |
| `disconnect()` | Clears the route and reports disconnection. It does not play, pause or seek the receiver or force browser playback restoration. |
| `publish({url, playlist?, title?})` | Publishes an independent URL source. URLs must be HTTP(S). A supplied HLS playlist must start with `#EXTM3U`, contain absolute child URLs, and fit within 1 Mi UTF-16 code units. |
| `capture(options?)` | Creates a decoded-media source and resolves when its playable stream is ready. |
| `close()` | Cancels pending capture, unopened sources, and session-dependent capture/resource publishers; disconnects the route and releases preparation holds. Accepted ordinary URL receivers remain independently owned. |

A session without an accepted receiver has a five-minute native resource lease. This is a lifetime bound, not a source-selection deadline. Extension code chooses shorter negotiation, resolver, restoration and capture deadlines and cancels through `close()`. Closing the last accepted receiver closes its session when no other source is pending. Cleanup and output restoration do not require an extension callback to run.

Extensions observe ordinary media-element events and choose when to call `video.pause()`, confirm the route, or disconnect. A connected route does not substitute a receiver clock, invent seekable ranges, intercept page controls, or synchronize QuickTime automatically. Native HLS exposes the adaptive demuxer's actual seek window, including while paused.

#### Source and player handles

A published source exposes `url`, `method` (`"url"` or `"restream"`), `closed` (a promise), `close()`, and `open({application, adapter?, timeout?})`. It can own one receiver. Opening and closing are separate from choosing a source. Closing a source revokes its resources and closes only the receiver window the API owns.

`open()` defaults to a 30-second launch deadline; `timeout` must be finite, positive, and at most 300 seconds. It returns after the application acknowledges the request and native ownership is established. It performs no automatic Play, Pause, seek or rate write. A source rejection does not select another source, negotiate a route, or start capture. The extension owns those decisions.

The player exposes:

- `url` and `closed`.
- `state()`, returning `{position, duration, rate}`. Unavailable or indefinite numeric properties are `null`. This is a scripting snapshot, not proof that audio/video is being rendered.
- `play()`, `pause()`, `seek(seconds)`, and `setRate(rate)`, each issuing only its named operation. In particular, Play does not also set the rate.
- `activate()`, which activates the owned movie without reconfiguring it.
- `close()`, which closes its source/receiver lifetime.

The adapter describes a macOS scripting player: `position`, `duration`, and `rate` are four-character numeric property codes; `play` and `pause` are eight-character event class/command pairs. It confers no arbitrary AppleScript execution. Native operations validate the retained window identity and exact URL and never claim a preexisting document. Without an adapter, the application receives a URL-open event and lifetime tracking ends at application exit; scripting controls and state queries are unavailable. `closed` indicates the end of source ownership; asynchronous cleanup of an unresponsive app window can continue afterward.

#### Extension-owned HTTP resources

A URL source published with a supplied playlist has an owned loopback endpoint. It additionally exposes:

- `setResource(name, data, contentType = "application/octet-stream")` → a resource URL. Data is a string (encoded as UTF-8), ArrayBuffer, or typed-array view. Replacement is atomic for subsequent requests; existing responses can finish from their snapshot.
- `removeResource(name)`. Removing `index.m3u8` is rejected; close the source to revoke its root.
- `setPlaylistProvider(async name => text, {timeout = 30})`. The callback supplies the root or a registered `.m3u8` resource when a receiver requests it. The name includes any request query string. A null result, rejection or timeout produces an unavailable-resource response. Passing `null` removes the provider.

Resource names are 1–128 ASCII letters, digits, dots, underscores or hyphens, excluding `.` and `..`. There are at most 256 resources and 64 MiB of stored resource data per source. Supported content types are `application/vnd.apple.mpegurl`, `application/x-mpegURL`, `video/mp2t`, `video/mp4`, `audio/mp4`, `audio/aac`, `text/vtt`, and `application/octet-stream`. Native HTTP handling supplies accurate lengths, HEAD responses and byte ranges.

Playlist providers are restricted to declared resources. They have at most 16 outstanding requests, a maximum response of 1 Mi UTF-16 code units, and a finite positive response timeout of at most 300 seconds. Closing a source, closing its session, or withdrawing its extension cancels requests and revokes the endpoint. An extension-driven publisher depends on its session, unlike an ordinary independently opened remote URL. Resource mutations and provider registration require an open session, even when an independently owned static source survives session closure.

Native code does not fetch or rewrite remote resources. Extension code owns URL mapping, authentication choices, fetching, cache policy, retries, and format compatibility.

Native monitoring checks ownership and closure, not media clocks. Transient query failures preserve ownership. Errors include `unsupported-source`, `application-unavailable`, `application-busy`, `application-timeout`, `application-start-uncertain`, `player-not-ready`, `player-state-unavailable`, `player-command-failed`, `player-closed`, and `no-source`. An uncertain launch retains conservative cleanup tracking rather than claiming or closing an unrelated window.

#### Capture

`capture({maxWidth, maxHeight, transport, videoCodec, maxHistoryDuration, minimumFreeStorage, title, openingMessage})` uses the existing decoded video and audio; it does not seek, scan the entire timeline, fetch alternative media, or extract encryption keys. The source must be playing. A paused source rejects with `not-playing`; Web Audio-routed or inaccessible protected decoder output rejects with `unsupported-source`.

Defaults are `maxWidth: 3840`, `maxHeight: 2160`, `transport: "hls"`, and `videoCodec: "h264"`. Dimensions are integer bounds from 2 through 16384, preserve aspect ratio and do not upscale. HLS uses H.264 and AAC with the source channel layout. The native producer resolves when at least three target durations are available, or when a shorter source genuinely ends. Production continues while the receiver is paused. A page seek or source replacement starts a discontinuity; source navigation or element destruction ends capture.

HLS is an accumulating event stream. Optional `maxHistoryDuration` is finite and at least nine seconds; optional `minimumFreeStorage` is a nonnegative safe integer byte count. These bound retained history and storage. Resources remain owned until the source/receiver closes. Optional experimental RTSP supports `videoCodec: "jpeg"` or `"utvideo"`, with AAC audio and no HLS history/storage options.

Selected native TextTracks are validated by identity, document, mode, and uniqueness. Native caption capture, source codec conversion, physical output suppression, storage bounds, HTTP byte ranges, and retained playback after tab closure are native responsibilities. Capture follows the page's selected audio sink; direct URLs leave audio and embedded-caption selection to the receiving app. QuickTime's supported caption and codec formats remain receiver capabilities.

#### Dispatch and page lifetime

Host contexts expose `prepareHandoff(tab)` and `cancelHandoff(ticket)`. A tab is a numeric tab ID or a `SafariBrowserTab`. The opaque, single-use ticket retains the page during browser-chrome message delivery, including when a busy page processes the message after its visible tab closes. Only the issuing extension and source page can claim it. An unclaimed ticket expires after 30 seconds.

```js
const ticket = await aqua.mediaPlayer.prepareHandoff(tab);
// Deliver the ticket to this tab's extension content script.
await aqua.mediaPlayer.withHandoff(async scope => {
    const session = await scope.createSession(video, { textTracks: [] });
    // Compose native operations here, or call an extension-owned helper.
}, { ticket });
```

`withHandoff(callback)` and nested `scope.withHandoff(callback)` retain a calling page across asynchronous selection. `scope.signal` is aborted on completion or expiry; completed scopes reject new sessions. Scopes have a five-minute lifetime bound. Accepted sources retain their own playback lifetime. Retained documents keep existing extension ports after visible tab closure, but closed tabs are absent from tab queries and cannot receive new connections.

#### Extension-owned handoff helper

The separate `AquaWebKit-Extensions/lib/MediaHandoff.js` helper is packaged with the extension as `handoff.js`. It installs the convenience `aqua.mediaPlayer.open(element, options)` and `scope.open()` in that extension's world. Extension bundles and helpers are maintained outside the WebKit checkout.

The helper owns source selection, optional `resolveSource(url)`, source-mode preference, receiver readiness checks, startup commands, fallback, coalescing, and all handoff/setup deadlines. It implements the connected-and-paused route policy: Play requests during startup and `routeSetupTimeout` (default five seconds after receiver startup) are followed by a pause; later Play disconnects and returns control to the page. Browser and receiver timelines remain independent. The helper's optional `synchronize: true` copies initial finite-source playback intent; continuous receiver synchronization is not a native API behavior.

The helper's behavior and defaults can be changed by an extension update. Native capabilities can also be used directly without loading the helper.

The external `AquaWebKit-Extensions/lib/HLSPlaylistRelay.js`, packaged as `relay.js`, provides the optional `relayPlaylists` policy. It preserves HLS renditions and metadata, rewrites playlist references to owned endpoints, and fetches media playlists on receiver requests. Media segments remain original remote URLs; no decoding or re-encoding is involved. Unrequested renditions are not polled. This keeps legacy receiver HTTP compatibility outside WebKit.

### aqua.tabs

An extension can hide tabs from Safari's tab bar without closing them, as Firefox's `tabs.hide` does. A hidden tab's page keeps running as a background tab's does. Each method also takes a trailing callback.

- `aqua.tabs.hide(tabs)` → `Promise<number[]>` hides a tab or an array of tabs and resolves to the IDs of the tabs it hid; a tab already hidden, the selected tab of a window, and a tab of a window showing all its tabs are not among them. A tab is a `browser.tabs` tab ID or, in a page with Safari's extension API, a `SafariBrowserTab`. A tab that names no open tab rejects the call with `Invalid tab ID`.
- `aqua.tabs.show(tabs)` → `Promise<void>` shows hidden tabs, each in the window it was hidden from, after the last of the tabs that preceded it there; at the end of the frontmost browser window when that window has closed; or in a new window when none is open. A tab that is not hidden is left as it is. Safari moves no tab into a window showing all its tabs: the call then rejects, and the tab stays hidden.
- `aqua.tabs.getHidden()` → `Promise<Tab[]>` the hidden tabs, described as `browser.tabs.get` describes a tab.

Hidden tabs are kept in a browser window Safari never shows, after an empty tab of its own; in `safari.application.browserWindows` that window's `visible` is false. Safari saves that window with its session like any other, so reopening the last session shows the hidden tabs in a window of their own. Safari's Merge All Windows shows hidden tabs too. As Firefox shows a hidden tab that is selected, a hidden tab Safari selects, for `activate()`, shows selected in its window, and one Safari brings to the front, for an alert of its page, shows selected in its window, which comes to the front. The tabs an extension hid show again when the extension unloads. A tab shown by Safari or by the extension unloading goes, when its window shows all its tabs, where it would go had that window closed.
