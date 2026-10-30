# The `browser` API for Safari 7 extensions

This WebKit gives Safari 7 legacy extensions (`.safariextension` bundles) a `browser` namespace modeled on the WebExtensions API. It sits alongside Safari 7's own `safari.extension` / `safari.application` / `safari.self` API, which stays fully available. Use `browser` for what Safari 7 cannot do: messaging addressed by tab and frame, script and style injection on demand, hiding tabs, capturing tabs as images and saving them as PDF, DNS lookups, network interception and response filtering, navigation events, cookies, document viewers, privacy settings, the clipboard, and pages that work with a tab's Web Inspector.

The engine provides only what needs the engine. Anything an extension can build from `safari.*` or the web platform, such as `runtime.getURL`, `storage`, `tabs.query`, `tabs.create`, and menus, is left to the extension's own platform layer (the uBlock Origin port's `browser-safari.js`, for example, builds these on top).

Extensions also get the `aqua` namespace for media handoff and Web Inspector access; see [EXTENSION-AQUA-API.md](EXTENSION-AQUA-API.md).

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
| proxy | `AquaWebKitSupport/source/WebKit/UIProcess/LegacyExtensions/LegacyExtensionProxy.{h,cpp}` (settings), `AquaWebKitSupport/source/WebCore/platform/network/cocoa/CocoaCurlProxyConfiguration.{h,mm}` (routes), with `proxy.onRequest` in the network side and `LegacyExtensionViewNetwork.{h,cpp}` |
| declarativeNetRequest | `AquaWebKitSupport/source/WebKit/UIProcess/LegacyExtensions/LegacyExtensionDeclarativeNetRequest.{h,mm}`, on WebKit's own implementation in `Source/WebKit/UIProcess/Extensions/` |
| tabs.captureTab, tabs.saveAsPDF, dns | `AquaWebKitSupport/source/WebKit/UIProcess/LegacyExtensions/LegacyExtensionTabCapture.{h,mm}`, `LegacyExtensionSaveAsPDF.{h,mm}`, `LegacyExtensionDNS.{h,cpp}` |
| Clipboard | writes: `WebLegacyExtensionPageObserver.mm` (WebKit 1 preferences) and `LegacyExtensionContent.cpp` (web content pages); reads: `AquaWebKitSupport/source/WebKit/UIProcess/LegacyExtensions/LegacyExtensionClipboard.mm` |
| WebKit 1 page hooks | `AquaWebKitSupport/source/WebKitLegacy/mac/LegacyExtensions/WebLegacyExtensionPageObserver.mm` |
| devtools | `AquaWebKitSupport/source/WebKit/UIProcess/LegacyExtensions/LegacyExtensionDevTools.{h,mm}`, with hooks in `Source/WebKit/UIProcess/Inspector/WebInspectorUIProxy.cpp`, on WebKit's inspector extensions (`API::InspectorExtension`); the Web Inspector frontend's part is in `AquaWebKitSupport/source/WebCore/inspector/InspectorFrontendClassicBridge.h` |
| Relative URLs in extension documents | `AquaWebKitSupport/source/WTF/wtf/LegacyExtensionURL.{h,cpp}` |
| WebKit 1 views' BroadcastChannels, message ports, shared workers and Web Locks | `AquaWebKitSupport/source/WebKit/UIProcess/LegacyExtensions/LegacyExtensionViewConnection.{h,cpp}` |
| Test extension and server | `AquaWebKitSupport/tests/legacy-extensions/` |

## Contexts

The API is installed in two kinds of context, and the namespaces available depend on the kind.

**Host contexts** are the extension's own pages: any document whose URL is `safari-extension://<extension key>/...`. This covers the global page, toolbar popovers, and extension bars, which Safari 7 hosts in WebKit 1 views inside the Safari process, and extension pages opened in tabs or frames, which load in web content processes. In a tab or frame, the page's main world is the host context.

A **devtools page** is a host context too: the page an extension's Info.plist names as its `WebExtensionDevtoolsPage`, which Safari's process hosts in a hidden WebKit 1 view for each tab whose Web Inspector is open (see [`browser.devtools`](#browserdevtools-devtools-pages-only)).

**Content contexts** are the extension's content scripts. Safari 7 runs each extension's content scripts (Info.plist `Content` → `Scripts`) in a script world of its own. The API is installed in that world in every frame where the world has a window object.

| Namespace | Host | Content |
| --- | --- | --- |
| `browser.runtime` (`connect`, `sendMessage`, `onConnect`, `onMessage`, `lastError`) | yes | yes |
| `browser.runtime.onConnectExternal`, `browser.runtime.onMessageExternal` | yes | no |
| `browser.runtime.getFrameId` | no | yes |
| `browser.dom` | no | yes |
| `browser.tabs` | yes | no |
| `browser.dns` | yes | no |
| `browser.webNavigation` | yes | no |
| `browser.webRequest` | yes | no |
| `browser.cookies` | yes | no |
| `browser.declarativeNetRequest` | yes | no |
| `browser.mimeHandler` | yes | no |
| `browser.privacy` | yes | no |
| `browser.proxy` | yes | no |
| `browser.devtools` | devtools pages only | no |
| `navigator.clipboard` without the page's restrictions | yes | no (page rules apply) |

`browser` is a writable, configurable, non-enumerable property of the global object. There is no `chrome` alias.

A context belongs to one document. When its frame shows another document (other than by keeping it in the back/forward cache, [below](#messaging-between-extensions)), or when Safari withdraws the user content a content script came from (the extension is disabled or reloaded), the old context is invalidated, as Chrome invalidates the contexts of a document that is gone and of an unloaded extension. A WebKit 1 view's context is invalidated likewise when the view shows another document or is destroyed, which Safari does when it disables the extension, and an extension page in a tab is invalidated when Safari disables or reloads its extension ([Loaded extensions](#loaded-extensions)). In an invalidated context, every `browser` and `aqua` method throws `"Extension context invalidated."` when called and every event when read, and so do a port's `postMessage` and `disconnect` and its `onMessage` and `onDisconnect` when read, even on a port that was already disconnected. Nothing reaches its listeners, so its ports never fire `onDisconnect` and its pending `sendMessage` Promises never settle. The other ends of its ports get `onDisconnect`.

### Loaded extensions

An extension is loaded while Safari presents it: while it has a global page, bar (hidden or shown), or popover, which Safari keeps while it has the extension enabled, or while a web content process holds its content scripts or style sheets, which Safari adds to every web content process while it has the extension enabled. Its pages in tabs and its devtools pages do not keep it loaded. Safari disabling or reloading an extension unloads it. When Safari 7 disables an extension, it leaves the extension's pages that tabs show open; those pages are invalidated (below). When Extension Builder reloads an extension, Safari serves it at a new root and reloads its tabs; a page of the copy it replaced, at the old root, no longer opens, and any such page still showing is invalidated. A page of an extension Safari has not loaded yet stays valid; once Safari loads the extension, the page is invalidated only if its files are at another root.

### Identifiers

- **Tab IDs** are positive integers, one per WebKit 2 page (the page's `WebPageProxyIdentifier`). Safari 7's WebKit 1 views (global page, popovers, bars) are not tabs.
- **Frame IDs** are `0` for a tab's main frame and the frame's `FrameIdentifier` otherwise. `parentFrameId` is `-1` for a main frame.
- **Extension key**: the host of the extension's `safari-extension://` URLs, `<CFBundleIdentifier>-<developer ID>`, the developer ID being the ten characters naming the Safari Developer certificate that signed the extension (`com.example.MyExtension-U5LEPOL722`). A Web Clip's copy of an extension adds `.<clip identifier>`. The key scopes every route: an extension's messages, ports, and injections reach only that extension's contexts, except the messages and ports it addresses to another extension by ID.
- **Extension IDs**: `sender.id` is the extension key without a Web Clip's clip identifier (`com.example.MyExtension-U5LEPOL722`), which names one extension: any developer can choose any bundle identifier, but the developer ID is the signer's. `runtime.sendMessage` and `runtime.connect` accept that ID, the full extension key, or the bare bundle identifier (`CFBundleIdentifier`).

### Calling conventions

Every method that returns a Promise also accepts a trailing callback, as Chrome's do. With a callback, the method returns `undefined`, and a failure calls the callback with no arguments while `browser.runtime.lastError` is set to `{ message }`. `lastError` is defined only while that callback runs.

Every message crossing between contexts is serialized as JSON. Values JSON cannot represent (functions, `undefined` members, cyclic objects, DOM nodes) do not survive the trip. A StreamFilter's bytes travel as bytes.

Messages, port traffic, and events reach JavaScript as tasks on the receiving context's event loop, never synchronously inside the sender's call. A suspended document (for example, one in the back/forward cache) receives nothing until it resumes.

Host events wait while the extension's Info.plist is being read and, when `Chrome` → `Global Page` declares a background document, until that document's `DOMContentLoaded` handlers finish. This includes tabs, windows, navigation, cookies, privacy, proxy.onProxyError, devtools and declarativeNetRequest notifications; the router selects interested contexts when it releases each event. WebRequest and proxy.onRequest events reach the listeners registered when the request reaches them, once their website access is known. Registered listeners can answer while the global page is loading. Blocking requests wait for those listener responses. Deferred messages and host notifications share an arrival-order queue; an extension that is ready can proceed while another waits. A reload or disable/enable starts a new wait. Events from an unloaded extension generation are discarded, and pending blocking requests are released.


## `browser.runtime`

### `runtime.sendMessage([extensionId,] message, [options])` → `Promise<any>`

Sends a one-shot message. Without an `extensionId`, it is internal: from a content script, it goes to the extension's host contexts that have a `runtime.onMessage` listener; from a host context, it goes to the extension's *other* host contexts that have one. Content scripts cannot message each other directly.

With an `extensionId` naming another extension, from a host context or a content script, it goes to that extension's host contexts that have a `runtime.onMessageExternal` listener, never to its `runtime.onMessage` listeners or its content scripts. An `extensionId` of `null`, `undefined` or `""`, or one naming the caller's own extension, makes the message internal, as in Chrome.

The arguments are those of Chrome's `sendMessage(optional string extensionId, any message, optional object options, optional function callback)`. A trailing function is the callback. One remaining argument is the message. Two are `(extensionId, message)` when the first is a string, `null` or `undefined`, and `(message, options)` otherwise. Three are `(extensionId, message, options)`. Any other arguments throw a `TypeError`. `options` is accepted and ignored.

Internal and external messages wait for the receiving extension's Info.plist. If `Chrome` → `Global Page` names a global page, they wait until its main document's `DOMContentLoaded` handlers finish before the router selects listeners, even when the sender is the global page itself or the global-page view has not appeared yet. An extension without a global page routes once its manifest is read. Reloading or disabling and enabling the extension resets readiness. A sender's queued messages and subsequent connect, post and disconnect traffic retain their order; routes from a vanished sender are discarded. `tabs.sendMessage` and `tabs.connect` address tab contexts and do not wait for global-page readiness.

If the global-page view finishes loading without `DOMContentLoaded`, or its frame is destroyed, the router releases waiting work to the available listeners. That global page remains failed for subsequent traffic; another global-page view or document, or a new extension load, starts a fresh wait.

The Promise resolves with the first response any receiver gives. It resolves with `undefined` when every receiver finishes without responding. It rejects with `"Could not establish connection. Receiving end does not exist."` when no receiver is listening after this readiness wait, including when the extension `extensionId` names is not installed, is disabled, or has no `onMessageExternal` listener.

### `runtime.onMessage.addListener((message, sender, sendResponse) => ...)`

To respond, a listener either:

- calls `sendResponse(value)` before returning,
- returns `true` and calls `sendResponse(value)` later, or
- returns a Promise; its fulfillment value is the response, and its rejection becomes an error for the sender.

If no listener does any of these, the receiver declines. Only the first response across all receivers reaches the sender; later calls to `sendResponse` are ignored.

`sender` is:

| Field | Present when | Value |
| --- | --- | --- |
| `id` | always | the sending extension's [ID](#identifiers), `<CFBundleIdentifier>-<developer ID>` |
| `url` | always | the sending document's URL |
| `tab` | the sender is in a tab | a [tab object](#tab-objects) |
| `frameId` | the sender is in a tab | the sending frame's ID |

A sender in a WebKit 1 view (global page, popover, bar) carries `id` and `url` only.

### `runtime.onMessageExternal.addListener((message, sender, sendResponse) => ...)` (host contexts only)

Receives the messages other extensions address to this one, with `sender` and responses as for `runtime.onMessage`; `sender.id` names the sending extension. Every extension can message every other: there is no `externally_connectable`, and a listener that accepts only some senders checks `sender.id`, which includes the signer's developer ID.

### `runtime.connect([extensionId,] [{ name }])` → `Port`

Opens a long-lived port. Its receivers are those of `runtime.sendMessage` given the same `extensionId`: without one, from a content script, the extension's host contexts with a `runtime.onConnect` listener, and from a host context, the other host contexts with one; with another extension's ID, that extension's host contexts with a `runtime.onConnectExternal` listener. The arguments are those of Chrome's `connect(optional string extensionId, optional object connectInfo)`, each matched by its type.

Internal and external connections use the manifest and `DOMContentLoaded` readiness wait of `runtime.sendMessage`, including on reload. Load failure or destruction of the global page releases queued connections to the available listeners; later connections also route without waiting until a new global page starts. The returned port accepts messages during the wait, and its traffic follows the queued connection in order.

A port opened by one context can have several receivers. Each receiver gets `onConnect` (or `onConnectExternal`). Messages the opener posts go to every receiver, and messages a receiver posts go to the opener only. The opener's port disconnects when the opener disconnects it or when its last receiver does. Messages posted before the receivers are known are queued and delivered in order.

If no receiver exists, the opener's `port.onDisconnect` fires with `runtime.lastError.message` set to `"Could not establish connection. Receiving end does not exist."` A receiving context with no `onConnect` (or `onConnectExternal`) listener disconnects the port at once.

### `runtime.onConnect.addListener(port => ...)`

The received `port` has `name` and `sender` (the opener, described as for `onMessage`).

### `runtime.onConnectExternal.addListener(port => ...)` (host contexts only)

Receives the ports other extensions open to this one, as `runtime.onConnect` receives internal ones; `port.sender.id` names the opening extension.

### Messaging between extensions

An `extensionId` names an extension by its bundle identifier or by its extension key, with or without a clip identifier. It names only extensions in the caller's own Web Clip, and from outside Web Clips only extensions outside them. Two installed extensions can share a bundle identifier (copies signed by different developers), and their bundle identifier names both; each extension key names one alone. An ID that names the caller's own extension makes the message or port internal, as in Chrome, so when the caller shares its bundle identifier with another extension, that bundle identifier reaches only the caller's own contexts and the other extension receives nothing. A bundle identifier the caller does not have reaches every extension that has it, each as one of the receivers.

A disabled extension has no host contexts, so a message or port addressed to it finds no receiver. When an extension is disabled or reloaded, the other ends of the ports its content scripts and host contexts hold get `onDisconnect`.

When a document enters the back/forward cache, the ports and one-shot messages its contexts hold close, as Chrome closes them, with `"The page keeping the extension port is moved into back/forward cache, so the message channel is closed."`:

- the other side of a port gets `onDisconnect` with that `runtime.lastError`;
- a message the document received and has not answered rejects the sender's Promise with it, once no other receiver is still pending;
- the document itself is told nothing: after it resumes, its ports never fire `onDisconnect` and their `postMessage` does nothing, and its unanswered `sendMessage` Promises never settle.

The channels of a document that is destroyed close with no error.

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
{ id, url, title, status /* "loading" | "complete" */, incognito, hidden, audible, mutedInfo: { muted } }
```

`url` is the URL of the page the tab shows, as in Chrome: the main frame's last committed URL, or for an error page the URL that failed to load; a navigation in progress has not changed it. `url` and `title` are present only when the extension sees the page, as Safari 7's own `SafariBrowserTab` shows them: a page of the extension, or, with any website access, a blank page or a page within it. `tabs.onUpdated` leaves them out of `changeInfo` for such a tab, and does not fire for a change of nothing else. `status` is `"loading"` while any load is in progress. `hidden` is whether the tab is hidden with `tabs.hide`. `audible` is whether the page is playing audio, muted or not. There is no `index`, `windowId`, `active`, or `favIconUrl`; use `safari.application` for window and tab-order information and `tabs.get` for each `SafariBrowserTab`'s ID.

### `tabs.get(tab)` → `Promise<Tab>`

`tab` is a tab ID or, in a page with Safari's extension API, a `SafariBrowserTab`; the result's `id` is that tab's ID. Rejects with `"No tab with id: <tabId>."` for an ID that names no open tab, and with a `TypeError` for a `SafariBrowserTab` of no open window.

### `tabs.update(tabId, { url, muted })` → `Promise<Tab>`

Loads `url` in the tab, and mutes or unmutes its audio by `muted`. These are the only supported properties. A relative `url` is resolved from the extension's root. As in Chrome, a `javascript:` URL is refused (`"JavaScript URLs are not allowed in chrome.tabs.update. Use chrome.tabs.executeScript instead."`; use `tabs.executeScript`), as is a `file:` URL (`"Cannot navigate to a file URL without local file access."`), and an invalid one rejects with `"Invalid url: \"<url>\"."`. The returned tab object describes the tab at the moment of the call, before the load starts. Rejects with `"No tab with this id."` for an unknown tab.

### `tabs.goBack(tabId)` and `tabs.goForward(tabId)` → `Promise<void>`

Go back or forward in the tab's history, as Safari's Back and Forward buttons do, and resolve at once. A tab is a tab ID or a `SafariBrowserTab`. With no tab, the call acts on the calling extension page's own tab or, from the global page, a popover or a bar, on the active tab of the frontmost window. A tab with no history in that direction is left as it is.

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
- The code runs as a classic script of that world, so the result is the script's completion value, and its top-level `let`, `const`, `class`, `var` and `function` declarations stay visible to later injections and to the content scripts. A call made during a user gesture runs the code with that gesture.
- `runAt` is `"document_start"`, `"document_end"`, or `"document_idle"` (default). `document_end` waits for `DOMContentLoaded`; `document_idle` waits for `DOMContentLoaded` and then one more task.
- A frame is a target only within the extension's website access (see [`browser.cookies`](#browsercookies-host-contexts-only)), by its URL, or by its origin for an `about:blank` or `about:srcdoc` document, as WebKit's own `executeScript` checks a frame's permission. A frame showing one of the extension's own pages counts too; another extension's page never does. When the frame the call names, or the main frame with `allFrames`, is outside the website access, the call rejects with Chrome's `Cannot access contents of the page. Extension manifest must request permission to access the respective host.`, which does not name the URL; `allFrames` leaves out the other frames outside it.
- Documents at `about:blank` or `about:srcdoc` are targets only when `matchAboutBlank` is `true`. With `allFrames`, they are skipped; a call whose only target is one rejects with `Cannot access contents of url "about:blank".`
- The Promise resolves with an array holding one result per frame that ran the code, converted as Chrome converts it: a value JSON cannot hold (a function, a symbol, a BigInt, `undefined`, a non-finite number) is `null` in an array and left out of an object, a property whose getter throws is `null`, an object met again on its own path is `null`, and nesting stops at a depth of 100. Code that throws gives `null`, and its exception goes to the frame's console.
- Frames that could not run the code are left out of the array. The call rejects only when no frame ran the code, with the first error: `"No tab with this id."`, `"No frame with this id."`, `"The extension has no access to this frame."`, or `"Cannot access the contents of an extension page."` (the frame shows an extension page).
- The extension must have content scripts, because the code runs in the world Safari creates for them. A frame whose content-script world has no window object yet gets one created for the injection.

### `tabs.insertCSS(tabId, { code | file, frameId, allFrames, matchAboutBlank, runAt, cssOrigin })` → `Promise<void>`

Adds a style sheet to the target frames' current documents, with the frame selection, `matchAboutBlank`, `runAt`, and failure rules of `executeScript`.

- The sheet belongs to one document only and does not appear in `document.styleSheets`.
- `cssOrigin` is `"author"` (default) or `"user"`.
- A `file` sheet's URL is the file's own `safari-extension://` URL, so relative `url(...)` references inside it resolve against the file. A `code` sheet gets a unique URL of its own, as upstream's injected sheets do, and does not resolve relative references against the page.

### `tabs.removeCSS(tabId, { code | file, frameId, allFrames, matchAboutBlank, runAt, cssOrigin })` → `Promise<void>`

Removes every sheet this extension inserted into the target documents whose source text equals the given `code` (or the given file's text).

### `tabs.hide(tabIds)` → `Promise<number[]>`

Hides tabs from Safari's tab bar without closing them, as Firefox's `tabs.hide` does, and resolves to the IDs of the tabs it hid. A hidden tab's page keeps running as a background tab's does. `tabIds` is a tab or an array of tabs; a tab is a tab ID or, in a page with Safari's extension API, a `SafariBrowserTab`. A tab already hidden, the selected tab of a window, and a tab of a window showing all its tabs (View > Show All Tabs) are not hidden. An ID that names no open tab rejects the call with `Invalid tab ID: <tabId>`; a `SafariBrowserTab` of no open window rejects it with a `TypeError`.

### `tabs.show(tabIds)` → `Promise<void>`

Shows hidden tabs, each in the window it was hidden from, after the last of the tabs that preceded it there; at the end of the frontmost browser window when that window has closed; or in a new window when none is open. A tab that is not hidden is left as it is. Safari moves no tab into a window showing all its tabs: the call then rejects, and the tab stays hidden.

Hidden tabs are kept in a browser window Safari never shows, after an empty tab of its own; in `safari.application.browserWindows` that window's `visible` is false. Safari saves that window with its session like any other, so reopening the last session shows the hidden tabs in a window of their own. Hidden tabs stay hidden through Merge All Windows. Safari shows a hidden tab when `SafariBrowserWindow.insertTab` moves it to another window. As Firefox shows a hidden tab that is selected, a hidden tab Safari selects, for `activate()`, shows selected in its window, and one Safari brings to the front, for an alert of its page, shows selected in its window, which comes to the front. The tabs an extension hid show again when the extension unloads. A tab shown by Safari or by the extension unloading goes, when its window shows all its tabs, where it would go had that window closed.

### `tabs.captureTab(tabId, { format, quality, rect, scale })` → `Promise<string>`

Firefox's `tabs.captureTab`: an image of an area of a tab's page, as a data URL, whether the tab is selected, in the background, or hidden. With no `tabId` (an object as the first argument is the options), the active tab of the frontmost browser window.

- `format` is `"png"` (default) or `"jpeg"`, and `quality`, from 0 to 100 (default 92), is the JPEG quality. The image is encoded as `canvas.toDataURL()` encodes one.
- `rect` `{ x, y, width, height }` is the area in CSS pixels of the document, which may extend beyond the viewport. Without it, the visible viewport, scroll bars excluded.
- `scale` is image pixels per CSS pixel, the screen's `devicePixelRatio` by default; the page's zoom multiplies it, as in Firefox.
- As Firefox's needs the `<all_urls>` permission, it needs website access to every site: `Level` `All` with `Include Secure Pages` (see [`browser.cookies`](#browsercookies-host-contexts-only)). Without it, the call rejects with `Missing host permission for the tab`.
- A tab showing another extension's page is captured as Firefox 153 and later capture another add-on's page: scaled, up or down, to 300 pixels on its longer side, blurred by `blur(5px)`, with the artifacts of a JPEG of quality 20; with `rect`, a 1-pixel black PNG or gray JPEG.
- The call rejects with `Invalid tab ID: <tabId>`, with `Cannot access activeTab` when no window shows a tab, with `Cannot capture invisible tab` for a tab with no size or no web content process, and with `An unexpected error occurred` when the area cannot be painted, as when it is too large for a bitmap.
- The arguments are checked as Firefox's schema checks them. A call whose arguments fail throws Firefox's message, such as ``Type error for parameter options (Error processing format: Invalid enumeration value "gif") for tabs.captureTab.``. `resetScrollPosition` is accepted and ignored, as Firefox ignores it for extensions Mozilla does not sign.

There is no `tabs.captureVisibleTab`: Safari 7's `SafariBrowserTab.visibleContentsAsDataURL(callback)` captures the visible tab.

### `tabs.saveAsPDF(pageSettings)` → `Promise<string>`

Firefox's `tabs.saveAsPDF`: saves the page of the active tab of the frontmost browser window as a PDF file. A save panel for PDF files, a sheet on the tab's window, asks for the file. It suggests `toFileName`, or else the page's title, the last segment of its URL's path, or its host, with the characters a file name cannot hold replaced by `_`. There is no way to skip the panel, as in Firefox. The call resolves with:

- `"saved"`, or `"replaced"` when the user chose an existing file and confirmed replacing it;
- `"canceled"` when the user cancelled the panel;
- `"not_saved"` or `"not_replaced"` when printing the page or writing the file failed, as when the page is in a print session of Safari's, from its Print sheet, when the file is chosen.

It rejects with `Cannot access activeTab` when no window shows a tab. `pageSettings` is checked as Firefox's schema checks it: a field Firefox does not define throws, as in `Type error for parameter pageSettings (Unexpected property "silentMode") for tabs.saveAsPDF.`.

The page is printed as Safari's File > Export as PDF prints it, with WebKit 2's printing: laid out for print on paper of the settings' size less its margins, paginated, and drawn page by page. Each page goes on a sheet of the paper's size, scaled to the area inside the margins, at its top. The page's web content process runs the whole print, from laying the page out for paper to returning it to the screen, before any print Safari starts on it meanwhile.

| `pageSettings` field | Default | |
| --- | --- | --- |
| `paperSizeUnit` | `0` | `0` for inches, `1` for millimeters |
| `paperWidth`, `paperHeight` | `8.5`, `11` | in `paperSizeUnit`s |
| `orientation` | `0` | `1` turns the paper to landscape |
| `marginTop`, `marginRight`, `marginBottom`, `marginLeft` | `0.5` | in inches |
| `shrinkToFit` | `true` | when `false`, `scaling` applies; WebKit's print layout shrinks a page wider than the paper either way |
| `scaling` | `1` | the size of the content: `0.5` is half size |
| `showBackgroundColors`, `showBackgroundImages` | `false` | WebKit prints background colors and images together, when either is `true`, for this print of this page only; Safari's "Print backgrounds" setting is left as it is. A page's `print-color-adjust: exact` prints its backgrounds regardless |
| `toFileName` | | the suggested file name |
| `headerLeft`, `headerCenter`, `headerRight`, `footerLeft`, `footerCenter`, `footerRight`, `edgeTop`, `edgeRight`, `edgeBottom`, `edgeLeft` | | accepted, and not printed: WebKit's printing has no headers or footers of its own |

### Tab events

Tab events go to every extension's host contexts that listen for them, with `url` and `title` as [Tab objects](#tab-objects) give them.

`tabs.onUpdated` reports navigations as Chrome does: `{ status: "loading" }` when a main-frame load or same-document navigation commits, and `{ status: "complete" }` when the tab next stops loading. A navigation that never commits, such as an HTTPS upgrade that falls back to HTTP, reports nothing. Changes within 25 ms of the first are reported together, as WebKit's own `tabs.onUpdated` reports them.

| Event | Arguments |
| --- | --- |
| `tabs.onCreated` | `(tab)` |
| `tabs.onUpdated` | `(tabId, changeInfo, tab)`; `changeInfo` is one of `{ status: "loading" }` with `url` when the URL changed, `{ status: "complete" }`, `{ title }`, `{ hidden }`, `{ audible }`, `{ mutedInfo }` |
| `tabs.onRemoved` | `(tabId, { windowId: -1, isWindowClosing: false })` |

## `browser.dns` (host contexts only)

### `dns.resolve(hostname, flags)` → `Promise<{ addresses, canonicalName, isTRR }>`

Firefox's `dns.resolve`: resolves a host name with the system resolver, as Firefox's native resolver does, off the main thread.

- `addresses` holds the address strings in the resolver's order, without repeats. An IPv6 address carries no zone, so `fe80::1%lo0` is `fe80::1`.
- `canonicalName` is present only with the `canonical_name` flag: the resolver's canonical name, or the host name when the resolver gives none.
- `isTRR` is `false`.
- An IP address literal resolves to itself, as its own canonical name, whatever the flags. A name that is not ASCII is looked up by its ACE form.
- A name that does not resolve rejects with `NS_ERROR_UNKNOWN_HOST`.
- The arguments are checked as Firefox's schema checks them: an unknown flag throws ``Type error for parameter flags (Error processing 0: Invalid enumeration value "…") for dns.resolve.``, and a `hostname` that is not a string throws `Incorrect argument types for dns.resolve.`.

| Flag | Effect |
| --- | --- |
| `canonical_name` | adds `canonicalName` |
| `disable_ipv6` | IPv4 addresses only; it takes precedence over `disable_ipv4` |
| `disable_ipv4` | IPv6 addresses only |
| `allow_name_collisions` | keeps ICANN's name-collision address `127.0.53.53`, which is otherwise dropped |
| `offline` | a name rejects with `NS_ERROR_OFFLINE`: Firefox answers it from its own cache, and the only cache here is the system resolver's |
| `speculate` | rejects with `NS_ERROR_DNS_LOOKUP_QUEUE_FULL` while `privacy.network.networkPredictionEnabled` is `false`, as Firefox refuses a speculative lookup while DNS prefetching is off |
| `bypass_cache` | none: every lookup goes to the system resolver |
| `disable_trr`, `priority_low`, `priority_medium` | none: there is no DNS over HTTPS and no lookup queue |

## `browser.webNavigation` (host contexts only)

Navigation events go to the host contexts that listen for them of every extension that sees the event's `url`, as a tab's `url` is seen (see [Tab objects](#tab-objects)), as WebKit's own webNavigation events need permission for the frame's URL. All carry `tabId`, `frameId`, `parentFrameId`, `url`, `processId` (always `-1`), and `timeStamp` (milliseconds since the epoch).

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

Both describe the frames the tab currently shows. Frames kept in the back/forward cache are excluded. A frame's `url` is present only when the extension sees it, as a tab's is. Both resolve with `null` for an unknown tab, and `getFrame` also resolves with `null` for an unknown frame.

## `browser.webRequest` (host contexts only)

Interception happens in the network process, at the same points WebKit applies its own content rules, and, for the loads of the WebKit 1 extension views (global page, popovers, bars), in the Safari process where WebKit 1 hands each request to the network. Every request and redirect is checked, including pings, beacons, and CSP reports, as are redirect responses, responses from both the network and the disk cache, and WebSocket handshakes. An extension sees its own views' requests, workers' included, as Chrome shows an extension its background page's; another extension sees web requests within its website access (see [`browser.cookies`](#browsercookies-host-contexts-only)). A synchronous `XMLHttpRequest` from a WebKit 1 view reports its events, but no verdict applies to it: the listeners run on the thread it blocks. Visible schemes are `http`, `https`, `ws`, `wss`, and the owning extension's `safari-extension`. `onBeforeSendHeaders`, `onSendHeaders` and `onHeadersReceived` apply to HTTP(S) requests and WS(S) opening handshakes; an extension's own `safari-extension://` files receive the other events. `onAuthRequired` follows an HTTP or proxy authentication challenge.

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

An HTTP(S) load's events come in Chrome's order: `onBeforeRequest`, `onBeforeSendHeaders`, `onSendHeaders`, then `onHeadersReceived` for each response. A redirect response is followed by `onBeforeRedirect` and the redirected request's `onBeforeRequest`; a final response is followed by `onResponseStarted` and `onCompleted` (or `onErrorOccurred`). An extension-resource load follows `onBeforeRequest` with `onResponseStarted` and `onCompleted`, or `onErrorOccurred` on failure. A redirect an extension makes reports `onBeforeRedirect` with a synthetic response and no `onHeadersReceived` of its own: `307 Internal Redirect` for one made in `onBeforeRequest`, `302 Found` for one made in `onHeadersReceived`.

`requestHeaders` are the headers the request is sent with. A changed `Origin` is sent as the verdict has it; WebKit's CORS check still compares a response's `Access-Control-Allow-Origin` with the requesting document's origin, which an `onHeadersReceived` verdict can rewrite. For `"extraHeaders"` listeners they include the fields the network layer adds to a request that has none of its own: the `Cookie` header it generates, and its `Accept-Language` and `Accept-Encoding`. A verdict that changes one of these sends the new value; one that removes it sends no such field. Removing `Accept-Encoding` still decodes a response the server compresses anyway. Stored-credential `Authorization` headers are added later and are not shown, as in Chrome.

A `Cookie` header an `onBeforeSendHeaders` verdict changes or removes is the one sent for that exchange only: each redirect generates its own. The `Set-Cookie` headers of a response are stored after its `onHeadersReceived` verdicts, so a verdict that removes or changes them stores the result, and a cancelled response stores none. A redirect's cookies are stored before the redirect is followed, so the redirected request carries them. Responses to authentication challenges store their cookies at once.

`requestBody` is present when the request has a body:

- `formData`: for a `POST` whose body is `application/x-www-form-urlencoded` or `multipart/form-data`, an object mapping each field name to an array of its values. A file field's value is its filename.
- `raw`: for any other body, or a form body that does not parse, an array of `{ bytes: ArrayBuffer }` and `{ file: path }` elements.

Common fields: `requestId`, `url`, `method`, `type`, `timeStamp`, `tabId` (`-1` for a load that belongs to no tab, such as one from a WebKit 1 extension view), `frameId` (`0` for the main frame of a tab or a WebKit 1 view), `parentFrameId`, and, for subresources, `documentUrl` and `initiator` (the requesting origin).

`requestId` is a string, stable for a load across its events: `"<network pid>-<n>"`, `"<network pid>-ping-<n>"` for pings and beacons, `"<network pid>-ws-<n>"` for WebSockets. A WebKit 1 view's loads use the Safari process's pid, and `"<pid>-sync-<n>"` for synchronous requests.

`type` is one of the `browser.webRequest.ResourceType` values: `main_frame`, `sub_frame`, `stylesheet`, `script`, `image`, `font`, `object`, `xmlhttprequest` (XHR, fetch, and EventSource), `ping` (pings and beacons), `csp_report`, `media`, `websocket`, `other`. Workers, worklets, and JSON modules are `script`, and XSLT is `stylesheet`.

`error` is a Chrome network error name: `net::ERR_BLOCKED_BY_CLIENT` for loads an extension cancelled, and otherwise `net::ERR_ABORTED`, `net::ERR_TIMED_OUT`, `net::ERR_INVALID_URL`, `net::ERR_UNKNOWN_URL_SCHEME`, `net::ERR_NAME_NOT_RESOLVED`, `net::ERR_CONNECTION_REFUSED`, `net::ERR_CONNECTION_CLOSED`, `net::ERR_TOO_MANY_REDIRECTS`, `net::ERR_INTERNET_DISCONNECTED`, `net::ERR_INVALID_RESPONSE`, `net::ERR_FILE_NOT_FOUND`, `net::ERR_SSL_PROTOCOL_ERROR`, `net::ERR_CERT_DATE_INVALID`, `net::ERR_CERT_AUTHORITY_INVALID`, or `net::ERR_FAILED`.

Each webRequest listener receives its own copy of the original event details; a blocking verdict does not replace the details delivered to later listeners.

A WebSocket handshake reports `onBeforeRequest`, `onBeforeSendHeaders`, `onSendHeaders`, `onHeadersReceived`, then `onResponseStarted` and `onCompleted` on a successful upgrade, or one `onErrorOccurred` on failure. Every exchange keeps its request ID, `type: "websocket"` and `method: "GET"`. Request-header listeners need `extraHeaders` to see Cookie. Host, the WebSocket key/protocol/extensions and authorization headers stay with the transport; listeners cannot read, remove or replace them. Pragma, Cache-Control and other HTTP stream-owned fields are also hidden. Every request-header listener sees Connection, Upgrade and Sec-WebSocket-Version, and they retain their transport values after a verdict. Blocking header listeners can edit the exposed fields or cancel; response edits apply before handshake validation. Cancellation reports `net::ERR_BLOCKED_BY_CLIENT`. Closing or navigating away while a verdict is pending reports one `net::ERR_ABORTED`, and a late verdict has no effect.

WebSocket `redirectUrl` verdicts are ignored in both request and response stages, as Chrome does. A network redirect followed by the Cocoa WebKit 2 transport reports the response's `onHeadersReceived`, `onBeforeRedirect`, then a fresh `proxy.onRequest` and `onBeforeRequest` for the next URL before its header events. The new proxy answer selects that connection's route. WebKit 2's 401 handshake path reports `onAuthRequired`, supporting credentials or cancellation; retry headers retain the same request ID and keep Authorization hidden. The upstream WebKit 1 client rejects non-101 responses, so its 3xx and 401 responses end in `onErrorOccurred`. Established WebSocket messages and closing frames are outside webRequest.


A successful cache revalidation (a `304` for a cached entry) reports the cached response, with `fromCache: true`, not the `304`.

### Blocking verdicts

| Verdict | Effect |
| --- | --- |
| `{ cancel: true }` in `onBeforeRequest` | The load fails with `net::ERR_BLOCKED_BY_CLIENT`, as a load WebKit's content rules block does; a main-frame navigation shows Safari's error page for it. A WebSocket fails and closes with code `1006`. |
| `{ redirectUrl }` in `onBeforeRequest` | A main-frame navigation follows a `307 Internal Redirect` to the new URL, keeping its method and body, so the address and history show it. Any other request loads the new URL in place, as WebKit's content rules redirect one, after `onBeforeRedirect` and the new URL's own `onBeforeRequest`, and is checked as a request for the new URL: a cross-origin XHR or fetch redirected to a `data:` URL or to an extension file succeeds as it does in Chrome, and a `data:` URL answers with status 200. An invalid URL is ignored. After 20 such redirects the load fails. |
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

WebKit's own declarativeNetRequest, the one it gives a WebExtension: rules are validated, stored, and translated to a WebKit content rule list by WebKit's implementation, and the content rule list engine applies them to every load of every tab except a load of an extension's own files (`safari-extension:` URLs, any extension's), which no rule matches, as in Chrome. The rule format, priorities, limits, and error messages are that implementation's ([Chrome's documentation](https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest) describes the format).

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

**Which loads and when.** An extension's rules apply to every tab's loads, including private windows', while the extension is [loaded](#loaded-extensions): from Safari's launch, for an extension Safari has enabled, until Safari disables or reloads it. Its session rules last as long; a page reloading itself keeps them. They do not apply to the loads of the extension's own WebKit 1 views. `block`, `allow`, `allowAllRequests`, and `upgradeScheme` rules act on any URL. `redirect` and `modifyHeaders` rules act only on URLs within the extension's website access, as a WebExtension's need host permissions for them. A `redirect` to an `extensionPath` goes to the extension's file of that path.

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

`application/pdf` is the only type an extension can handle, as in Chrome; other types are ignored. The handler shows only responses within the extension's website access (a `blob:` URL by its origin); any other response is handled as with no handler. When several extensions handle a type, the one Safari loaded last, which is the one installed last, shows it. A frame below the top level whose handler does not embed gets the response as it would with no handler. A response with `Content-Disposition: attachment` still downloads.

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

## `browser.proxy` (host contexts only)

Chromium's `proxy.settings` and `proxy.onProxyError`, and Firefox's `proxy.onRequest` and `proxy.onError`. They route every load and WebSocket: the network processes' for tabs and extension pages in tabs, and those of the global page, popovers and bars, which WebKit 1 makes in Safari's process. Loads that no extension routes take the system's proxy settings (System Preferences, PAC and exceptions), as they do without the API.

### `proxy.settings`

A ChromeSetting whose value is a [ProxyConfig](https://developer.chrome.com/docs/extensions/reference/api/proxy#type-ProxyConfig): `get({ incognito })` → `Promise<{ value, levelOfControl, incognitoSpecific? }>`, `set({ value, scope })`, `clear({ scope })`, and `onChange`, which reports `{ value, levelOfControl }` as the listening extension sees the setting. Control works as `browser.privacy`'s does: the value of the extension Safari loaded last among those that set one, `{ mode: "system" }` when none did, persisted until the extension calls `clear()` and applied while it is loaded; `scope` is `"regular"`, the default, which covers private windows too; other scopes reject. `get()` reports the value normalized as Chromium does: servers carry their `scheme` (`"http"` when absent) and `port` (80 for `http`, 1080 for SOCKS), and only the fields the mode reads remain.

| `mode` | Loads go |
| --- | --- |
| `direct` | directly |
| `system` | by the system's settings |
| `fixed_servers` | through `rules.singleProxy` for every URL; or `proxyForHttp`, `proxyForHttps`, `proxyForFtp` by scheme (`ws:` and `wss:` taking `http`'s and `https`'s), with `fallbackProxy` for a scheme that has none; directly when no server applies |
| `pac_script` | where the `pacScript` (`data`, or `url`) answers, through the system's PAC interpreter; a script that fails leaves the load direct, or fails it when `pacScript.mandatory` is true |
| `auto_detect` | where the script the system's proxy auto-discovery finds answers |

A server's `scheme` is `http`, `https` (an HTTP proxy reached over TLS, port 443 by default), `socks4` or `socks5` (the proxy resolves the host); `quic` rejects with `Proxy scheme 'quic' is not supported.`. An HTTPS proxy's certificate is evaluated by the system's trust store for the proxy's host, and a load through a proxy whose certificate is not trusted fails, with no exception offered. `rules.bypassList` takes Chromium's rules: `<local>` (hosts without a dot that are not IP literals), `[scheme://]host-pattern[:port]` with `*` and `?` wildcards and a leading `.` standing for `*.`, IP literals, `ip/prefix` ranges, and `<-loopback>`. As in Chromium, `fixed_servers` and `pac_script` never proxy `localhost`, `*.localhost`, loopback and link-local addresses unless `<-loopback>` is listed; a rule that does not parse is ignored. A `pacScript.url` naming one of the extension's own files, a `data:` URL or a `blob:` URL is read when `set()` is called, and the script travels with the value; other URLs are fetched by the system's PAC interpreter. Invalid values reject with Chromium's messages, such as `Proxy mode 'fixed_servers' requires a 'rules' field.` and `Proxy rule for singleProxy and proxyForHttp set.`.

A PAC answer (the system's or `pac_script`'s) or `onRequest` answer naming several servers tries each in turn when the connection to the one before it fails, as CFNetwork tries the routes it resolves. A changed route never reuses a pooled connection made through another proxy: curl matches connections by proxy type, host, port and credentials.

### `proxy.onRequest.addListener(listener, filter, extraInfoSpec)`

Firefox's per-request routing. `filter` is a webRequest `RequestFilter` (`urls`, `types`, `tabId`), within the extension's website access; `extraInfoSpec` may hold `"requestHeaders"`. The listener receives webRequest-shaped details (`requestId`, `url`, `method`, `type`, `tabId`, `frameId`, `parentFrameId`, `timeStamp`, `documentUrl`, `originUrl`, `initiator`, `incognito`, `thirdParty`, `fromCache`, and `requestHeaders` with that option) before any of the request's webRequest events, and for each redirect's request again. It returns, or resolves a Promise with:

- `undefined`: the route stays as it was;
- `null`: the load connects directly;
- a ProxyInfo, or an array of them in failover order: `{ type, host, port, username, password, proxyDNS, failoverTimeout, proxyAuthorizationHeader, connectionIsolationKey }`. A `null` entry ends the list; without one, the route the answer replaces follows the list. `type` `"direct"` stands for that route itself, so it does not bypass a proxy that `proxy.settings` or the system gives the load; return `null` for a direct connection.

Listeners answer in registration order (contexts in the order they were created), each answer acting on the route the ones before it left, as Firefox applies its proxy filters; the first route is the one `proxy.settings` or the system gives the load. `type` is `"http"` (or `"proxy"`), `"https"` (an HTTP proxy reached over TLS), `"socks"` (SOCKS5) or `"socks4"`. `username` and `password` authenticate to SOCKS proxies, and `proxyDNS` lets a SOCKS proxy resolve the host; an HTTP proxy's 407 goes to `webRequest.onAuthRequired` and then to Safari, as Firefox sends it. `proxyAuthorizationHeader` is sent to an HTTP or HTTPS proxy with every request and CONNECT. `failoverTimeout` limits the connection to a server that has a later one to fail over to. Connections carrying a `proxyAuthorizationHeader` or `connectionIsolationKey` are shared only by loads with the same ones.

`onRequest` sees every request, pings, beacons, CSP reports and WebSocket handshakes (`type` `"websocket"`, with the `ws:` or `wss:` URL) included. The one exception is a synchronous XHR of the global page, a popover or a bar: it blocks Safari's main thread, where the listeners would have to run, so it takes `proxy.settings` and the system's route, as it gets webRequest events with no verdict.

### `proxy.onError`

Firefox's: an `onRequest` listener of this context threw, or answered with something that is not a valid ProxyInfo (`ProxyInfoData: …`, Firefox's messages). The listener receives `{ message, fileName, lineNumber, stack }`; the request keeps its route.

### `proxy.onProxyError`

Chromium's, delivered to every extension: `{ fatal: true, error: "net::ERR_PROXY_CONNECTION_FAILED", details: "" }` when a load fails because its proxy cannot be reached or resolved (after any failover), and `{ fatal: false, error: "net::ERR_PAC_SCRIPT_FAILED", details }` when a `pac_script` script fails and the load goes direct.

## `browser.cookies` (host contexts only)

Cookies of the sites the extension's website access covers: the `Website Access` of its `Info.plist` `Permissions`, which Safari 7 also applies to its content scripts. Safari's process reads it when the extension [loads](#loaded-extensions), and applies it to the cookies it answers with and acts on, to `onChanged`, and to `webRequest`. `Level` `All` covers every site, `Some` the `Allowed Domains` (a host, or `*.host` for the host and its subdomains), and `None` no site. Secure pages count only with `Include Secure Pages`. A cookie's site is its domain, over `https` for a secure cookie.

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

## `browser.devtools` (devtools pages only)

[Chrome's devtools API](https://developer.chrome.com/docs/extensions/reference/api/devtools), for a page that works with the Web Inspector. An extension names its devtools page in Info.plist, with a path from the extension's root, as a WebExtension manifest's `devtools_page` does:

```xml
<key>WebExtensionDevtoolsPage</key>
<string>devtools.html</string>
```

While a tab's Web Inspector is open, every [loaded](#loaded-extensions) extension that names a devtools page has one for that tab, in a hidden WebKit 1 view in Safari's process, where Safari 7 hosts the extension's global page. The extension is an inspector extension of that tab's Web Inspector, as a WebExtension with a devtools page is in WebKit: the page opens once the inspector has loaded and registered the extension, or when the extension loads while the inspector is open, and closes with the inspector or when the extension unloads. An extension with no global page, bar, popover, or content script is never loaded: Safari serves none of its files, so no URL carries the per-launch root its devtools page would load from. The devtools page is a host context of the extension: it has every host namespace, exchanges messages and ports with the extension's other contexts (as a sender it carries only `url`), and has `browser.devtools`. Safari's `safari` object is not defined in it.

The devtools methods follow Chrome's conventions, not the general ones above: each takes a trailing callback or, without one, returns a Promise, and reports failures in Chrome's records rather than through `runtime.lastError`:

```js
{ code, description, details, isError: true }
```

`code` is `"E_NOTFOUND"`, `"E_FAILED"`, `"E_NOTSUPPORTED"`, or `"E_PROTOCOLERROR"`; `description` is Chrome's format string for it, such as `"Object not found: %s"`, and `details` holds its arguments.

The inspected page and its requests are visible as the extension's website access allows (see [`browser.cookies`](#browsercookies-host-contexts-only)), as Chrome restricts its devtools pages by their host permissions: a URL counts when it is a web URL within the website access, a `data:` or `about:` URL, a `blob:` URL of such an origin, or one of the extension's own files.

### `devtools.inspectedWindow.tabId`

The ID of the inspected tab.

### `devtools.inspectedWindow.eval(expression, [{ frameURL }], [callback])`

Evaluates `expression` in the main world of the inspected tab's main frame, or of the frame `frameURL` names, with the Web Inspector's Command Line API, as WebKit's own Web Inspector evaluates an extension's code: `$0` is the node selected in the inspector's DOM tree, and `$()`, `$$()`, `$x()`, `inspect()` and the API's other functions are defined. The result is returned by value, as JSON. The evaluation stops at an exception when the inspector's debugger breaks on exceptions.

| Outcome | Callback | Promise |
| --- | --- | --- |
| a result | `callback(result)` | resolves with `result` |
| the code throws | `callback(undefined, { isException: true, value })`, `value` being the exception as a string | rejects with `{ isException: true, value }` |
| the evaluation fails | `callback(undefined, record)` | rejects with `Error("DevTools API encountered an error")` |

A frame matches `frameURL` as in WebKit's Web Inspector: by its URL, else, when `frameURL` has no fragment, by its URL without its fragment, else, when `frameURL` has no query either, by its URL without query and fragment. The evaluation fails with `E_NOTFOUND` when no frame matches (`"<top>"` when the tab has no main frame), with `E_FAILED` `"Permission denied"` when the extension's website access does not cover the frame, with `E_PROTOCOLERROR` when the inspected page fails the evaluation, and with `E_NOTSUPPORTED` for the `useContentScriptContext` and `scriptExecutionContext` options, which are not supported.

### `devtools.inspectedWindow.reload([{ ignoreCache, userAgent, injectedScript }])`

Reloads the inspected tab, from the origin when `ignoreCache` is `true`, as Chrome's does; a string argument is taken as `userAgent`. Returns `undefined`. Nothing happens when the extension's website access does not cover the page.

- `userAgent` replaces the user agent of the page's requests and its `navigator.userAgent` until the same extension reloads without one, the extension unloads, or the inspector closes, including in a web process the page moves to.
- `injectedScript` runs, wrapped in a function, in the main world of every frame of the reloaded page, as the frame's global object is created and ahead of the page's scripts, including in a web process the reload moves the page to; documents the tab shows after it run without it.

### `devtools.network.onRequestFinished`

`(request)` for each request of the inspected tab that finishes or fails, when the extension may see both the request and the page: its [HAR entry](#har-entries).

### `devtools.network.getHAR([callback])`

The HAR 1.2 log of the requests that finished and that the extension may see, as Chrome's network log keeps them with Preserve log off: the requests of the main frame's current document, from when the inspector registered the first extension with a devtools page, as the page opens. A main-frame navigation drops the requests of the documents before it.

```js
{ version: "1.2", creator: { name: "WebKit Web Inspector", version: "1.0" }, pages, entries }
```

`pages` holds one page, `"page_0"`, the main frame's current document: `title` is its URL, `startedDateTime` its request's, and `pageTimings` gives `onContentLoad` and `onLoad` in milliseconds after that request. Every entry belongs to `"page_0"`. Each redirect of a request is an entry of its own, ahead of the request's.

### HAR entries

Entries are as WebKit's Web Inspector exports them: `startedDateTime`, `time`, `request` (`method`, `url`, `httpVersion`, `cookies`, `headers`, `queryString`, `postData`, `headersSize`, `bodySize`), `response` (`status`, `statusText`, `httpVersion`, `cookies`, `headers`, `content` with `size`, `compression` and `mimeType`, `redirectURL`, `headersSize`, `bodySize`, `_transferSize`, and `_error` for a failed request), `cache`, `timings`, and `serverIPAddress`, `_serverPort`, `connection`, `_fetchType` and `_priority` where known. Sizes and timings the network layer does not report are `-1`. A request's entry has, on its prototype, `getContent([callback])`: `callback(content, encoding)`, or a Promise of `{ content, encoding }`, the response body, with `encoding` `"base64"` for a body held as base64 and `""` otherwise; `content` is `null` when the body is no longer available. For a request the extension may not see, the callback gets no arguments and the Promise rejects with `Error("DevTools API encountered an error")`.

### `devtools.network.onNavigated`

`(url)` when the inspected tab's main frame commits a new document.

### Not provided

`devtools.panels` is not provided: Safari 7's Web Inspector, the frontend this WebKit serves, has no extension tabs, and its document's Content Security Policy, `default-src 'self'`, admits no frame from another origin, as an extension's panel page is. Neither are `devtools.inspectedWindow.getResources`, `devtools.network.addRequestHeaders`, `devtools.performance`, `devtools.recorder`, or `devtools.languageServices`.

## Clipboard (host contexts only)

In the extension's own pages, `navigator.clipboard.write()`, `navigator.clipboard.writeText()` and `navigator.clipboard.readText()` work at any time, with no user gesture and no focus required, as they do in a WebExtension's pages with the clipboard permissions.

- `write(items)` and `writeText(text)` are WebKit's own: `write()` takes `ClipboardItem`s, including images (`image/png` is decoded and re-encoded, `text/html` sanitized, `text/uri-list` link-decoration filtered). In a private browsing page, their pasteboard entries expire as WebKit's ephemeral pasteboard data does.
- `readText()` reads the pasteboard's plain text. It resolves with `""` when there is no text, and rejects with a `NotAllowedError` `DOMException` when it fails.

Content scripts keep the page's clipboard rules.

WebKit 1 extension views (global page, popovers, bars) also have WebCore's asynchronous Clipboard API enabled, as WebKit 2 views have by default, and their `javaScriptCanAccessClipboard` preference on, so `document.execCommand("copy")` and `"cut"` work there without a gesture too.

## Engine behaviors for extension pages and content scripts

These need no API calls.

- **Relative URLs in extension documents.** Safari 7 serves an extension's files at `safari-extension://<key>/<token>/<path>`, where `<token>` is fixed for each Safari launch. In an extension document, relative references resolve within `safari-extension://<key>/<token>/` as a WebExtension's resolve within its origin: a root-relative reference such as `/js/app.js` resolves under it, and dot-segments stop at it, so `../styles/a.css` from a root-level page is `styles/a.css`. `/x.js`, `./x.js` and `../x.js` from a root-level page name the same file, including for ES module identity.
- **Shared storage in WebKit 1 extension views.** Global pages, popovers, bars and devtools pages use the default persistent session's network-process storage for `localStorage` and IndexedDB, shared with tabs and frames of the same `safari-extension://<key>` origin; dedicated workers share IndexedDB. Storage events reach the other views of that origin; different extensions remain isolated, and `sessionStorage` belongs to each Page.
- **BroadcastChannel, SharedWorker and Web Locks in the WebKit 1 views.** The global page, popovers and bars have them, as WebKit 2 views do, and share them with the extension's pages in tabs and frames: a channel reaches all of the extension's pages, `new SharedWorker(url)` connects every page to one worker, and a lock held by one page holds for all. Safari's process takes part in the default session's channels, message ports and shared workers over a network process connection of its own, and uses that session's lock manager.
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

The startup fixture set contains `messaging-a.safariextension`, `messaging-b.safariextension`, `messaging-failed.safariextension` and `startup-pages/README.md` with the exact procedure. Its independent server serves `http://127.0.0.1:8867/startup.html`: content scripts record document-start messages and ports, and global pages register runtime and blocking webRequest listeners in `DOMContentLoaded`. Messaging A's `startup.html` popover also records its launch-time message/port order. Restore the fixture tab on a cold launch and refresh its global snapshots to check the document-start messages. The missing-global-page fixture records both initial and repeated receiving-end errors; `bootstrap.html` exercises external scripts needed by both global pages during startup. Repeat the checks after reload and disable/enable.

`check-webrequest-readiness.py` locates `webrequest-readiness.safariextension` through `AQUAWEBKIT_EXTENSIONS_DIR`, defaulting to the sibling workspace. Run `prepare`, `cert` and `serve`, follow its certificate instructions, and install the working copy in Extension Builder. Use matching options for `configure --reload` and `check`: `module` checks module startup, fetches and HTTP/HTTPS tabs; `--filter`, `--nonblocking` and `no-module` select controls. `normal`, `startup` and `preload` check request timing and verdicts; `failed` checks navigation failure, and `--wk2 --resource-stages` checks extension-tab requests and resource events.

`api-test.safariextension` exercises every namespace against the local server (`server.py`, ports 8843 and 8844, and 8845, which counts preconnections). `response-filter.safariextension` rewrites `/filter/` responses and sets the privacy settings `pages/filter.html` asks for (results in `window.__results`). `mime-handler.safariextension` displays `/mime/` PDFs and reports reads to the server log; `/mime/embed.html` embeds one, and `/mime-options/false` and `/mime-options/true` set its option. `limited-access.safariextension` has website access to `localhost` alone. `access-boundaries.safariextension`, also limited to `localhost`, checks from `http://localhost:8843/access.html` that executeScript, insertCSS, `tabs.update`, tab URLs and titles, and webNavigation keep within that access (results in the server log as `access-boundaries`); its PDF handler shows `access-blob-pdf.html`'s blob: PDF from `localhost` and not from `127.0.0.1` (`access-viewer` in the server log). `declarative-net-request.safariextension` applies rules to `pages/dnr.html` (results in `window.__results`; API calls in the server log as `dnr-api`). `proxy.safariextension` sets `proxy.settings` and answers `proxy.onRequest` for `pages/proxy.html` against the test proxies of `proxy.py` (HTTP on 8856, HTTP requiring `Proxy-Authorization` on 8857, SOCKS5 checking the credentials a client offers on 8858, HTTPS on 8860, nothing on 8859), using hosts under `.proxy-test`, which resolve nowhere; each case's `pass` collects in `window.__results`, and `window.__done` is set at the end. The HTTPS proxy cases connect through it when its certificate, `build/proxy-tls/cert.pem`, is trusted (`security add-trusted-cert -r trustRoot -p ssl -k ~/Library/Keychains/login.keychain build/proxy-tls/cert.pem`), and check that the loads fail when it is not. A content blocker that drops third-party pings, such as uBlock Origin, cancels the page's beacon after `onRequest` has answered for it (`onBeforeRequest` follows `onRequest`), so `onRequestBeacon` passes with such extensions turned off. `check-system-proxy-failover.py` points the primary network service at a PAC file answering `PROXY 127.0.0.1:8859; PROXY 127.0.0.1:8856` for `.proxy-test` hosts (and the service's own route for every other host), opens `pages/system-proxy.html`, which checks that a load and a page's WebSocket reach their host through 8856, prints its results and restores the service's settings; it needs `sudo` without a password.

`display-or-download.safariextension` decides whether `/inline/` responses display or download: open `/inline/login`, `/inline/doc.pdf` (viewer result in `window.__result`), `/inline/data.bin` and `/inline/force-download.html`, and the unaffected `/plain/` equivalents. `/plain/clip.mp4` and `/plain/server-inline.mp4` download unless `AquaWebKitPlayMediaFilesInline` is on. `hidden-tabs.safariextension` hides and shows tabs via `window.postMessage({ hiddenTabs: operation, args })`; its `global.js` lists operations, with answers in `window.__hiddenTabsResult`. `capture-pdf-dns.safariextension` runs `dns.resolve` and `tabs.captureTab` cases when `pages/capture-pdf-dns.html` loads, capturing that tab, a background tab of `pages/capture-color.html` and the same tab hidden (results in `window.__results`), and `savePDF()` there calls `tabs.saveAsPDF` (status in `window.__pdfResult`). `compat-test.safariextension` checks Chrome-compatible behaviors on `pages/compat.html` (results in the page's `data-compat-*` attributes): onBeforeRequest redirects of same- and cross-origin XHR and fetch to `data:` and to extension files, declarativeNetRequest leaving extension files alone, executeScript declarations, result conversion and gestures, and dot-segments at the extension root; its `page.html`, opened in a tab, checks BroadcastChannel, Web Locks and SharedWorker shared with the global page, and `gestureProbe()` there, run from AppleScript's `do JavaScript`, injects with the gesture. `pages/data-download.html` downloads a 64 KiB `data:` URL. `canload.safariextension` checks Safari 7's own `safari.self.tab.canLoad` on `pages/canload.html` (see that page for where the answers are), in a cross-origin frame (`pages/canload-xframe.html`, answers in `window.__frameAnswers`), in a tab opened with `window.open` (`pages/canload-open.html`), and from loads made while typing (`pages/canload-input.html`). `devtools.safariextension` has a devtools page that runs the `browser.devtools` cases once a tab of `pages/devtools.html` has its Web Inspector open: `window.postMessage({ devtools: "results" })` there puts its results in `window.__devtoolsResult` (`"globalResults"` gives the copies its global page received, `"diag"` what reached its `onRequestFinished`), and `window.postMessage({ devtools: "eval", expression })` evaluates through `inspectedWindow.eval`, for checks such as `$0` after selecting a node. `devtools-content-only.safariextension` has only a content script and a devtools page, which puts its evaluations of the inspected tab in `window.__devtoolsContentOnlyResult` there. Install `shared-storage.safariextension` and `shared-storage-isolation.safariextension`, show both extension bars, then open `/shared-storage.html` on the local server and click **Run storage tests** to check localStorage, storage events, IndexedDB, workers, Blob values and origin isolation across WebKit 1 views and tabs (results in `window.__results`). The page's `prepareStorageRecovery()` and `checkStorageRecovery()`, run before and after terminating the Networking process, check persistent data and the existing WebKit 1 worker's recovery (`window.__results.recovery`). Open `pages/coverage.html` from the server for aggregate results in `window.__results`. On Safari 7.1.8, Extension Builder installs persist across relaunches; click Reload to package changes from the working copy.
