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

`AquaWebKitSupport/tests/legacy-extensions/` holds `api-test.safariextension`, which exercises every namespace against a local server (`server.py`, ports 8843 and 8844, and 8845, which counts preconnections), `response-filter.safariextension`, which rewrites the server's `/filter/` responses and sets the privacy settings `pages/filter.html` asks for (results in `window.__results`), `mime-handler.safariextension`, whose viewer shows the server's `/mime/` PDFs and reports what it read to the server log (`/mime/embed.html` embeds one; `/mime-options/false` and `/mime-options/true` set its option), `limited-access.safariextension`, whose website access is `localhost` alone, `declarative-net-request.safariextension`, whose rules act on the loads of `pages/dnr.html` (results in `window.__results`; the extension reports its API calls to the server log as `dnr-api`), and `display-or-download.safariextension`, which decides whether the server's `/inline/` responses display or download: open `/inline/login`, then `/inline/doc.pdf` (its viewer shows `window.__result`), `/inline/data.bin` and `/inline/force-download.html`, and the `/plain/` paths of the same names, which no extension changes. `/plain/clip.mp4` and `/plain/server-inline.mp4` (the server's own `Content-Disposition: inline`) download unless `AquaWebKitPlayMediaFilesInline` is on. `hidden-tabs.safariextension` hides and shows tabs with `aqua.tabs` as a server page asks with `window.postMessage({ hiddenTabs: operation, args })`; its `global.js` lists the operations, and the answer lands in the page's `window.__hiddenTabsResult`. Build the extensions in Safari's Extension Builder, then open `pages/coverage.html` from the server; results collect in `window.__results`. Extension Builder installs do not persist across Safari relaunches; click Install again after relaunching.

## The aqua namespace

`aqua` is a non-enumerable global in extension content scripts and extension pages. `aqua.tabs` is in every extension page: the global page, popovers, and pages loaded in tabs or frames. `aqua.mediaPlayer.open` and `withHandoff` are in content scripts and extension pages loaded in tabs or frames, where media elements are available. Extension pages also have `prepareHandoff` and `cancelHandoff` for dispatching a handoff from browser chrome. Web pages cannot see `aqua`.

### aqua.mediaPlayer

`application` is the target macOS application’s bundle identifier, such as `com.apple.QuickTimePlayerX` or `io.mpv`. The Send to QuickTime extension explicitly selects QuickTime Player.

```js
const handoff = await aqua.mediaPlayer.open(video, {
    application: "com.apple.QuickTimePlayerX",
    title: document.title,
    openingMessage: "Opening QuickTime…",
    adapter: {
        position: "time", duration: "durn", rate: "rate",
        play: "MVWRplay", pause: "MVWRpaus"
    }
});
```

The required `application` option selects an installed macOS app by bundle identifier. The app must accept HTTP(S) URLs through macOS URL delivery. The Promise resolves to `{ method: "url" | "restream", url }` after delivery succeeds.

The element may be an `HTMLVideoElement` or `HTMLAudioElement`. `sourceMode` controls delivery: `"auto"` (the default) tries direct sources before decoded capture, `"direct"` tries only direct sources and site route negotiation, and `"capture"` goes directly to decoded capture. A direct-only request with no usable route rejects with `no-direct-source` after restoring local playback from any attempted negotiation. Resolver errors, uncertain receiver launches and failures to restore the source remain terminal errors. Extensions can try direct-only handoffs across their preferred elements before choosing one for capture; capture still requires that element to be playing.

A toolbar or context-menu handler can reserve its source tab before dispatching a content-script message:

```js
// Extension global page.
const page = tab.page;
const ticket = await aqua.mediaPlayer.prepareHandoff(tab);
try {
    page.dispatchMessage("open-media", { ticket });
} catch (error) {
    await aqua.mediaPlayer.cancelHandoff(ticket);
    throw error;
}

// Extension content script receiving that message.
await aqua.mediaPlayer.withHandoff(scope => scope.open(video, options), { ticket });
```

`prepareHandoff` accepts a numeric tab ID or `SafariBrowserTab` and returns a single-use opaque ticket. The reservation retains the page during message delivery, including when a busy page processes the message after its Safari tab closes. Only the issuing extension and source page can claim it. Claiming transfers ownership to the content scope; cancellation, navigation, extension unload, or 30 seconds without a claim releases the reservation. Invalid, expired, and reused tickets reject with `no-source`. `cancelHandoff` is harmless after a ticket is claimed or released.

`aqua.mediaPlayer.withHandoff(async scope => { ... })` retains the calling page while an extension chooses among several handoffs, including across awaited failed attempts after tab closure. Use `scope.open(element, options)` inside the callback; ordinary unscoped opens cannot start on closed tabs. The scope returns the callback's result or propagates its error and releases the page hold when the callback settles. `scope.withHandoff(callback)` creates a nested scope. Successful handoffs retain their own playback lifetime. A scope expires after five minutes with `handoff-timeout`. `scope.signal` is aborted on completion or expiry, and completed scopes reject further opens. Expiry releases the scope's hold without cancelling independently owned media sessions. Navigation or extension unload invalidates further calls from the old content context.

A retained document keeps its existing `runtime.Port` connections after its visible tab closes. Those ports can finish an operation and deliver its result in either direction. The closed tab is absent from tab queries and cannot receive new connections. Ports disconnect when their document is released, navigates, or its extension unloads.

Native HLS playlists and progressive HTTP(S) media files use their original URL directly. For MediaSource, the API first considers the site's HTTP(S) `<source>` alternatives in document order, respecting media queries and remote-playback opt-out. These are the alternate sources sites supply for AirPlay. When there is no alternative URL and the site listens for wireless playback availability or route changes, an adapter-backed handoff announces an external route through the native media element. The site can then select its own remote URL, as it does for AirPlay. Negotiation has a 30-second deadline; an unavailable route returns to local playback before capture is attempted, with a separate 15-second deadline for local source readiness. Selecting native text tracks prevents route negotiation so that those tracks can accompany captured media. An alternative rejected by the receiver falls back to the next candidate, then to decoded capture. Media without a usable direct source uses a tokenized loopback HLS stream of decoded video and audio. The target application does not affect the capture codecs.

The optional `routeTimeout` is a finite number of seconds, at least 1, for site/AirPlay-style remote-source negotiation. It defaults to 30. When it expires, the API restores the local source and proceeds to the next direct candidate or decoded capture. It does not change the separate source-restoration, resolver, capture-startup, or receiver-launch deadlines.

The optional `capture: { maxWidth, maxHeight, transport, videoCodec, maxHistoryDuration }` configures decoded fallback capture. `maxWidth` and `maxHeight` bound video dimensions. Both dimensions must be integers from 2 through 16384; an omitted dimension defaults to 3840 or 2160 respectively. Frames fit inside that box without upscaling, retaining aspect ratio and using even dimensions for chroma sampling. `maxHistoryDuration` is an optional HLS-only finite number of seconds, at least 9, that bounds retained media and subtitle history; omitting it retains the complete capture. Omitting `capture` retains the source dimensions. Direct URL and site-negotiated playback use the original media unchanged. Capture preserves the selected audio channel layout; an unsupported encoder layout rejects the request instead of downmixing.

The default transport and video codec are `hls` and `h264`. Experimental `transport: "rtsp"` accepts `videoCodec: "jpeg"` (quality 100 Motion JPEG) or `"utvideo"` (lossless encoding of the converted 8-bit YUV 4:2:0 input). Audio is AAC with the source channel layout. RTSP uses a loopback listener in the UI process; encoded frames cross IPC on demand with bounded queues. RTP transport is negotiated with the receiver. Each video sample carries a QuickTime generic RTP description, supporting receivers with the corresponding decoder. This transport is live, has no captured-history seeking or WebVTT rendition menu, and carries updated video sample descriptions across resolution changes; changes to the audio configuration require a new session. The production direct URL/HLS routes are unaffected. Extensions choose the transport; the target application remains a separate option.

The optional `resolveSource(url)` function runs before each direct-source attempt, after site route negotiation when needed. It can asynchronously return `{ url }`, or `{ url, playlist }` with an HLS playlist and absolute resource URLs. Returning `undefined` preserves the candidate. The URL must use HTTP(S); a supplied playlist must start with `#EXTM3U` and fit within 1 Mi UTF-16 code units. A supplied playlist is served from a session-specific loopback URL; its remote child playlists and media are fetched directly by the receiver. Source association and playback controls stay tied to the original media element. A rejected, invalid or timed-out resolver rejects the handoff with `source-resolution-failed`; it does not silently choose another language or capture. Resolution has a 30-second deadline. Source replacement during resolution rejects with `no-source`. Repeated calls share the existing handoff and do not run another resolver.

The optional `adapter` describes a macOS scripting player: `position`, `duration`, and `rate` are four-character numeric property codes; `play` and `pause` are eight-character event class/command pairs. The adapter opens HTTP(S) URLs and locally produced RTSP streams through the standard macOS open-document event. An acknowledged document and one new window with the exact media URL establish ownership. Native commands and lifecycle monitoring use that retained window identity directly; an inconclusive property query leaves the session active. The API rejects malformed descriptions and never claims a preexisting document. The example is QuickTime's dictionary; an extension targeting another app supplies that app's dictionary. The adapter waits up to 30 seconds for a new document and readable position/rate properties before configuring it. A requested nonzero starting position waits for a finite receiver duration covering that position and a successful seek. Live streams use the receiver’s default starting position and need no finite duration. Cancellation and timeout release the producer; separate cleanup tracks acquired window identities and session-unique restream URLs. An unconfirmed direct launch reserves its app/URL pair, reports `application-start-uncertain`, and leaves the original element paused. If an acknowledged document exposes its exact URL after the opening deadline, cleanup closes the uniquely identified new window and releases that reservation; otherwise the reservation lasts until the app exits. Without an adapter, lifetime tracking ends at application exit.

For an ordinary or static-alternative URL handoff, the original element is paused normally and retains its MediaSource attachment and buffered data. For a site-negotiated route, the site selects a new source on the original element. The receiver owns playback and seeking. For a site-negotiated remote route, the media element mirrors receiver position, duration, playback rate and pause state; its playback and seek commands are forwarded through the adapter. The receiver owns decoding while the route is active. Original-URL handoffs with a finite browser duration carry the current position. Site-negotiated routes also carry the source position and playback intent. Live streams and static alternative URLs use the receiver’s default starting position because their timeline mapping is unknown. Closing the receiver restores inline presentation and prior playback intent when the original tab and source survive. For finite original-URL handoffs, the last observed target position is restored when it remains seekable. A negotiated route exposes the last receiver position during the site's return to local playback. If the site does not replace its local source within 15 seconds, the element is left paused. Static alternative-URL handoffs resume the original page position. Closing the source tab retains the session until the receiver closes.

The adapter carries playback controls. Direct URL handoffs leave audio selection to the receiver, including alternate tracks described by standard HLS audio groups or media-file metadata. The browser’s current audio selection is not transferred to the receiver. Audio-track metadata does not force capture. When capture is needed for the source, it follows the page’s selected rendering sink; alternate languages are not exported as selectable receiver tracks. Initially disabled audio is omitted from capture; enabling it later requires a new capture session. Capturing an audio-only source with all tracks disabled rejects with `unsupported-source`.

Repeated calls for the same live element, extension, target app, adapter and selected tracks share the pending operation when `sourceMode` also matches. An existing handoff can be reactivated by `"auto"` or a mode matching its actual transport. A direct-only call on an existing capture rejects with `no-direct-source`. Other configuration mismatches reject with `application-busy`; close the receiver first. Reactivation preserves the receiver's position. Completed captured history remains an active handoff until its receiver closes.

Both paths immediately suppress inline video and physical audio output and show a spinner in the browser's private media controls. The optional `openingMessage` string supplies the entire startup label as plain text, limited to 1024 UTF-16 code units. The extension owns wording and localization; omitted or empty text leaves the spinner without a label. After receiver acceptance, the placard changes to the external-playback message. Modern controls use their PiP placard; classic controls show the same handoff message. The site-negotiated path exposes native wireless presentation changes; the capture path uses private presentation state. The AirPlay polyfill is independent.

Capture starts at the next common decoded audio/video interval reaching the selected rendering sinks. Live capture opens the receiver after at least nine seconds of media, covering three HLS target durations. Completed short clips open when their final playlist is ready. The browser continues normal playback while a continuous platform H.264 encoder and AAC encoder produce HLS segments. Audio is tapped at playsink's decoded input before device conversion, so the output device's channel limit does not downmix capture. Audio output is 48 kHz AAC-LC at 160 kbit/s per channel, preserving the selected channel count and positions. Video uses H.264 Baseline. Hardware VideoToolbox encoding uses a 100 Mbit/s target; machines without a hardware H.264 encoder use x264 with the ultrafast preset, normal frame threading, CRF 10 and variance-based adaptive quantization (`aq-mode=1`). Software encoding uses a 240 Mbit/s VBV ceiling and a 240 Mbit buffer, constrained to Level 5.2. The ceiling takes priority over CRF quality on unusually complex frames. Actual bitrate varies with picture complexity. One-second fragment and keyframe targets provide headroom for high-bitrate fragments; exhausting a transport budget ends the session. VideoToolbox encoding requires hardware acceleration. Video retains the initial frame size and pixel aspect ratio. Its output frame rate matches the source, with a minimum of one frame per second for HLS fragment boundaries; variable-frame-rate input with no declared rate uses 30 fps. Adaptive size changes are scaled to that output geometry. Playback in the receiving app follows the rendered timing and positive playback rate of the page. Subtitle cue times and inline timestamps follow the same timing. A source rate change starts a discontinuity. Reverse playback is unsupported. With pitch preservation disabled, the rendered PCM sample rate must be representable as an integer; other rates reject with `unsupported-source`.

Decoded capture performs no timeline scan, scripted seek, whole-video index or media refetch. Its HLS event playlist retains produced media and subtitles for rewind. Without `maxHistoryDuration`, it retains the complete recording. With a limit, it advances media and discontinuity sequence numbers while evicting older segments, and its completed VOD contains the retained window. Bounded histories rotate anonymous storage files so files containing only evicted segments close; a short grace period serves requests made from a recently replaced playlist. Encoder input, fragment delivery and disk queues have bounded memory, and delivery waits for outstanding writes to complete. EOS changes the playlist type from EVENT to VOD and adds ENDLIST after both streams drain.

For decoded capture, the source must already be playing. Capture preserves its currentTime, paused, muted, volume and playbackRate properties. While the handoff is pending or active, the physical audio output receives silent PCM while capture retains the original samples. Pausing the receiver leaves the source playing and its recording growing, so the receiver can catch up to the current captured position. A pause initiated by the page stops production until the page resumes. Media routed through a WebAudio graph is unsupported because its processed, potentially mixed output belongs to a separate audio destination.

Playback continues after tab closure by retaining the producing page. Source navigation and element destruction end capture. A MediaSource replacement drains the current encoder and resumes from the new decoder in the same receiver window, adding an HLS discontinuity. Decoder EOS finalizes capture only after the media element itself ends; a subsequent stream restarts the encoder instead of publishing a premature ENDLIST. On a negotiated direct route, a same-URL decoder replacement keeps the route; a different media URL detaches the browser association while leaving the receiver's existing video playing. An accepted ordinary direct handoff also survives page media reloads and errors by detaching its browser association. A source seek starts a new HLS discontinuity after playback settles. Site JavaScript still runs and can affect playback; this API does not guarantee invisibility to every site or bypass its playback policy.

The optional `textTracks` array selects WebVTT renditions by native `TextTrack` identity. Omit it to export enabled subtitle/caption tracks; pass `[]` to export none. Entries must be distinct, enabled subtitle, caption, or forced-caption tracks belonging to the media element. Invalid entries reject with `unsupported-source`. Selection is captured at handoff; selected hidden tracks can receive future cues. After decoder replacement, a selected in-band track reconnects only to a unique replacement with the same ID, kind, language and label. Cue text, timing, layout, regions and styles are exported. Published segments are immutable. The Desktop extension selects currently showing tracks. Captions drawn solely as page DOM overlays are outside decoded video and native TextTrack capture. Direct URL handoffs preserve embedded captions carried by the original URL. Selected page-owned tracks require restreaming; selected embedded tracks also require restreaming when the only URL candidates are separate alternatives.

Subtitle rendering follows the receiver's capabilities. QuickTime 10.2i plays embedded CEA-608 closed captions. In tests, its legacy subtitle menu did not expose separate HLS WebVTT tracks, and non-forced WebVTT renditions were not displayed automatically. Selected forced renditions render, but an empty selected forced rendition can stall its legacy selection. QuickTime 10.3 and the native AVFoundation probe render exported cues. Mavericks AVFoundation ignores tested WebVTT CSS colors and can duplicate overlapping cues or replace them early at format discontinuities.

Encrypted media is captured only through the ordinary decoded output of the existing playback pipeline. The API does not obtain keys, alter license requests, or make protected/opaque output readable. Decoder output that cannot negotiate through the capture converters rejects with `unsupported-source`.

The optional `title` string supplies a display name for captured media or an extension-supplied playlist, limited to 1024 UTF-16 code units. Capture uses a session-specific named loopback playlist, or `index.m3u8` when the title is empty. Direct handoffs use the resolved URL. They start a loopback listener only for an extension-supplied playlist. The receiver determines how it displays the URL name. The Desktop QuickTime extension selects media-session metadata, the media element title, or the page title, and substitutes division slashes (`∕`) because QuickTime interprets literal slashes as filename separators.

Restreams require Safari and the target application to remain running. Closing the source tab is supported. QuickTime also releases a session when its particular movie window closes, even if the app stays open. A target pause does not expire the session. Direct URL delivery pauses the browser element; closing its tab leaves the independently opened URL playing in the target.

The Promise rejects with an Error whose `message` is `no-source` for missing media or an ended capture source, `not-playing` for a paused capture source, `unsupported-source` for an unsupported pipeline, track selection or source change, `application-unavailable` if the target cannot receive the URL, `application-timeout` if receiver startup exceeds its deadline, `capture-timeout` if initial capture makes no progress for 30 seconds or selected subtitles remain unavailable after media startup, or `application-busy` if the target URL already has an owner. A direct attempt advances to the next candidate and then capture after a definitive unsupported-source rejection. Receiver startup timeouts are terminal errors. An uncertain launch is terminal.

The Desktop extension resolves multilingual YouTube remote playlists using their `YT-EXT-XTAGS` original-audio role and `YT-EXT-AUDIO-CONTENT-ID`. It retains every video quality in that original-audio group. This selects the original language, including when the page has selected a dub. Other sources retain their original URLs and native audio choices. This format handling lives entirely in the extension. QuickTime 10.2i did not expose its Languages menu for either a translated multilingual HLS master or a control with separate audio-only renditions; both exposed selectable languages in the native AVFoundation probe.

The standalone example extension is `~/Desktop/SendToQuickTime.safariextension`, outside this repository. Load it in Safari 7’s Extension Builder; its `README.txt` describes media selection and toolbar behavior.

### aqua.tabs

An extension can hide tabs from Safari's tab bar without closing them, as Firefox's `tabs.hide` does. A hidden tab's page keeps running as a background tab's does. Each method also takes a trailing callback.

- `aqua.tabs.hide(tabs)` → `Promise<number[]>` hides a tab or an array of tabs and resolves to the IDs of the tabs it hid; a tab already hidden, the selected tab of a window, and a tab of a window showing all its tabs are not among them. A tab is a `browser.tabs` tab ID or, in a page with Safari's extension API, a `SafariBrowserTab`. A tab that names no open tab rejects the call with `Invalid tab ID`.
- `aqua.tabs.show(tabs)` → `Promise<void>` shows hidden tabs, each in the window it was hidden from, after the last of the tabs that preceded it there; at the end of the frontmost browser window when that window has closed; or in a new window when none is open. A tab that is not hidden is left as it is. Safari moves no tab into a window showing all its tabs: the call then rejects, and the tab stays hidden.
- `aqua.tabs.getHidden()` → `Promise<Tab[]>` the hidden tabs, described as `browser.tabs.get` describes a tab.

Hidden tabs are kept in a browser window Safari never shows, after an empty tab of its own; in `safari.application.browserWindows` that window's `visible` is false. Safari saves that window with its session like any other, so reopening the last session shows the hidden tabs in a window of their own. Safari's Merge All Windows shows hidden tabs too. As Firefox shows a hidden tab that is selected, a hidden tab Safari selects, for `activate()`, shows selected in its window, and one Safari brings to the front, for an alert of its page, shows selected in its window, which comes to the front. The tabs an extension hid show again when the extension unloads. A tab shown by Safari or by the extension unloading goes, when its window shows all its tabs, where it would go had that window closed.
