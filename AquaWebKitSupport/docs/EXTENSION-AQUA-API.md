# The `aqua` API for Safari 7 extensions

This WebKit gives Safari 7 legacy extensions an `aqua` namespace for media handoff and Web Inspector access, alongside the `browser`
namespace described in [EXTENSION-BROWSER-API.md](EXTENSION-BROWSER-API.md), which also defines the host and
content contexts used here.

Sources: `AquaWebKitSupport/source/WebKit/Shared/LegacyExtensions/LegacyExtensionAPI.js` (the JavaScript API),
`AquaWebKitSupport/source/WebKit/UIProcess/LegacyExtensions/LegacyExtensionHost.{h,cpp}` (the UI process side) and
`AquaWebKitSupport/source/WebCore/platform/graphics/gstreamer/mse/MediaRestreamSource.cpp`, with
`AquaWebKitSupport/source/WebKit/UIProcess/LegacyExtensions/LegacyExtensionInspector.{h,cpp}` for `aqua.inspector`. Manual tests:
`AquaWebKitSupport/tests/legacy-extensions/QUICKTIME.md`.

`aqua` is a non-enumerable global in extension content scripts and extension pages. `aqua.mediaPlayer.createSession` and `withHandoff` are in content scripts and extension pages loaded in tabs or frames, where media elements are available. Extension pages also have `prepareHandoff` and `cancelHandoff` for dispatching a handoff from browser chrome. Web pages cannot see `aqua`. `aqua.inspector` is in extension pages only.

## aqua.mediaPlayer

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

### Browser session

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

### Source and player handles

A published source exposes `url`, `method` (`"url"` or `"restream"`), `closed` (a promise), `close()`, and `open({application, adapter?, timeout?})`. It can own one receiver. Opening and closing are separate from choosing a source. Closing a source revokes its resources and closes only the receiver window the API owns.

`open()` defaults to a 30-second launch deadline; `timeout` must be finite, positive, and at most 300 seconds. It returns after the application acknowledges the request and native ownership is established. It performs no automatic Play, Pause, seek or rate write. A source rejection does not select another source, negotiate a route, or start capture. The extension owns those decisions.

The player exposes:

- `url` and `closed`.
- `state()`, returning `{position, duration, rate}`. Unavailable or indefinite numeric properties are `null`. This is a scripting snapshot, not proof that audio/video is being rendered.
- `play()`, `pause()`, `seek(seconds)`, and `setRate(rate)`, each issuing only its named operation. In particular, Play does not also set the rate.
- `activate()`, which activates the owned movie without reconfiguring it.
- `close()`, which closes its source/receiver lifetime.

The adapter describes a macOS scripting player: `position`, `duration`, and `rate` are four-character numeric property codes; `play` and `pause` are eight-character event class/command pairs. It confers no arbitrary AppleScript execution. Native operations validate the retained window identity and exact URL and never claim a preexisting document. Without an adapter, the application receives a URL-open event and lifetime tracking ends at application exit; scripting controls and state queries are unavailable. `closed` indicates the end of source ownership; asynchronous cleanup of an unresponsive app window can continue afterward.

### Extension-owned HTTP resources

A URL source published with a supplied playlist has an owned loopback endpoint. It additionally exposes:

- `setResource(name, data, contentType = "application/octet-stream")` → a resource URL. Data is a string (encoded as UTF-8), ArrayBuffer, or typed-array view. Replacement is atomic for subsequent requests; existing responses can finish from their snapshot.
- `removeResource(name)`. Removing `index.m3u8` is rejected; close the source to revoke its root.
- `setPlaylistProvider(async name => text, {timeout = 30})`. The callback supplies the root or a registered `.m3u8` resource when a receiver requests it. The name includes any request query string. A null result, rejection or timeout produces an unavailable-resource response. Passing `null` removes the provider.

Resource names are 1–128 ASCII letters, digits, dots, underscores or hyphens, excluding `.` and `..`. There are at most 256 resources and 64 MiB of stored resource data per source. Supported content types are `application/vnd.apple.mpegurl`, `application/x-mpegURL`, `video/mp2t`, `video/mp4`, `audio/mp4`, `audio/aac`, `text/vtt`, and `application/octet-stream`. Native HTTP handling supplies accurate lengths, HEAD responses and byte ranges.

Playlist providers are restricted to declared resources. They have at most 16 outstanding requests, a maximum response of 1 Mi UTF-16 code units, and a finite positive response timeout of at most 300 seconds. Closing a source, closing its session, or withdrawing its extension cancels requests and revokes the endpoint. An extension-driven publisher depends on its session, unlike an ordinary independently opened remote URL. Resource mutations and provider registration require an open session, even when an independently owned static source survives session closure.

Native code does not fetch or rewrite remote resources. Extension code owns URL mapping, authentication choices, fetching, cache policy, retries, and format compatibility.

Native monitoring checks ownership and closure, not media clocks. Transient query failures preserve ownership. Errors include `unsupported-source`, `application-unavailable`, `application-busy`, `application-timeout`, `application-start-uncertain`, `player-not-ready`, `player-state-unavailable`, `player-command-failed`, `player-closed`, and `no-source`. An uncertain launch retains conservative cleanup tracking rather than claiming or closing an unrelated window.

### Capture

`capture({maxWidth, maxHeight, transport, videoCodec, maxHistoryDuration, minimumFreeStorage, title, openingMessage})` uses the existing decoded video and audio; it does not seek, scan the entire timeline, fetch alternative media, or extract encryption keys. The source must be playing. A paused source rejects with `not-playing`; Web Audio-routed or inaccessible protected decoder output rejects with `unsupported-source`.

Defaults are `maxWidth: 3840`, `maxHeight: 2160`, `transport: "hls"`, and `videoCodec: "h264"`. Dimensions are integer bounds from 2 through 16384, preserve aspect ratio and do not upscale. HLS uses H.264 and AAC with the source channel layout. The native producer resolves when at least three target durations are available, or when a shorter source genuinely ends. Production continues while the receiver is paused. A page seek or source replacement starts a discontinuity; source navigation or element destruction ends capture.

HLS is an accumulating event stream. Optional `maxHistoryDuration` is finite and at least nine seconds; optional `minimumFreeStorage` is a nonnegative safe integer byte count. These bound retained history and storage. Resources remain owned until the source/receiver closes. Optional experimental RTSP supports `videoCodec: "jpeg"` or `"utvideo"`, with AAC audio and no HLS history/storage options.

Selected native TextTracks are validated by identity, document, mode, and uniqueness. Native caption capture, source codec conversion, physical output suppression, storage bounds, HTTP byte ranges, and retained playback after tab closure are native responsibilities. Capture follows the page's selected audio sink; direct URLs leave audio and embedded-caption selection to the receiving app. QuickTime's supported caption and codec formats remain receiver capabilities.

### Dispatch and page lifetime

Host contexts expose `prepareHandoff(tab)` and `cancelHandoff(ticket)`. A tab is a numeric tab ID or a `SafariBrowserTab`. The opaque, single-use ticket retains the page during browser-chrome message delivery, including when a busy page processes the message after its visible tab closes. Only the issuing extension and source page can claim it. An unclaimed ticket expires after 30 seconds.

```js
const ticket = await aqua.mediaPlayer.prepareHandoff(tab);
// Deliver the ticket to this tab's extension content script.
await aqua.mediaPlayer.withHandoff(async scope => {
    const session = await scope.createSession(video, { textTracks: [] });
    // Compose native operations here, or call an extension-owned helper.
}, { ticket });
```

`withHandoff(callback)` and nested `scope.withHandoff(callback)` retain a calling page across asynchronous selection. `scope.signal` is aborted on completion; completed scopes reject new sessions. A scope lasts until its callback settles, or until its document stops (navigates away, enters the back/forward cache, or leaves its frame) or its content world is withdrawn, which reject it with `no-source`. Accepted sources retain their own playback lifetime. Retained documents keep existing extension ports after visible tab closure, but closed tabs are absent from tab queries and cannot receive new connections.

### Extension-owned handoff helper

The separate `AquaWebKit-Extensions/lib/MediaHandoff.js` helper is packaged with the extension as `handoff.js`. It installs the convenience `aqua.mediaPlayer.open(element, options)` and `scope.open()` in that extension's world. Extension bundles and helpers are maintained outside the WebKit checkout.

The helper owns source selection, optional `resolveSource(url)`, source-mode preference, receiver readiness checks, startup commands, fallback, coalescing, and all handoff/setup deadlines. It implements the connected-and-paused route policy: Play requests during startup and `routeSetupTimeout` (default five seconds after receiver startup) are followed by a pause; later Play disconnects and returns control to the page. Browser and receiver timelines remain independent. The helper's optional `synchronize: true` copies initial finite-source playback intent; continuous receiver synchronization is not a native API behavior.

The helper's behavior and defaults can be changed by an extension update. Native capabilities can also be used directly without loading the helper.

The external `AquaWebKit-Extensions/lib/HLSPlaylistRelay.js`, packaged as `relay.js`, provides the optional `relayPlaylists` policy. It preserves HLS renditions and metadata, rewrites playlist references to owned endpoints, and fetches media playlists on receiver requests. Media segments remain original remote URLs; no decoding or re-encoding is involved. Unrequested renditions are not polled. This keeps legacy receiver HTTP compatibility outside WebKit.

## aqua.inspector

A connection from an extension to the Web Inspector backend of a tab. The extension is a frontend of the tab's backend, as WebKit's own Web Inspector is: what it sends is the Web Inspector protocol of this WebKit, and it receives every message the backend sends. The protocol is the one this build's Web Inspector speaks, described by the domain files in `Source/JavaScriptCore/inspector/protocol/` and used by `Source/WebInspectorUI`; it is not a stable API and changes as WebKit does. It is not the Chrome DevTools Protocol.

```js
aqua.inspector.onMessage.addListener((tabId, message) => {
    const { method, params } = JSON.parse(message);
    if (method === "Target.targetCreated" && params.targetInfo.type === "page")
        pageTarget = params.targetInfo.targetId;
});
await aqua.inspector.attach(tabId);
await aqua.inspector.sendMessage(tabId, JSON.stringify({ id: 1, method: "Target.sendMessageToTarget",
    params: { targetId: pageTarget, message: JSON.stringify({ id: 1, method: "Runtime.evaluate", params: { expression: "document.title" } }) } }));
```

A tab is a tab ID, or a `SafariBrowserTab` of an open window. Methods return promises.

| Member | Contract |
| --- | --- |
| `attach(tab)` | Connects the extension to the tab's backend. While it connects, the backend announces the tab's targets with `Target.targetCreated` messages, which reach `onMessage` before the promise resolves. Rejects when the extension's Website Access is not All with Include Secure Pages, when the tab shows or is loading a page the extension does not see (one whose URL is not a web URL, one of the extension's own pages, or a `data:`, `about:` or `blob:` URL), when an extension is attached to the tab, and when another frontend, such as the tab's Web Inspector, is connected to it. |
| `detach(tab)` | Disconnects the extension. Rejects when the extension is not attached to the tab. |
| `sendMessage(tab, message)` | Hands the backend one message, a string of JSON text, as Web Inspector sends it. Rejects when the extension is not attached to the tab. |
| `onMessage` | `(tabId, message)`: each message of the backend, as JSON text, in the order the backend sends them. |
| `onDetach` | `(tabId, reason)`: the session ended other than by `detach`. `reason` is `"target_closed"` when the tab closed, its web process exited, or it began to show a page the extension does not see, and `"replaced_with_inspector"` when the user opened the tab's Web Inspector. |

The backend's top level has the `Target` and `Browser` domains. A page's own domains (`Runtime`, `Page`, `Network`, `DOM` and the rest) are its page target's: commands go to the target in `Target.sendMessageToTarget`, and the target's messages come back in `Target.dispatchMessageFromTarget`. A cross-site navigation creates a provisional page target, which `Target.didCommitProvisionalTarget` makes the page's target.

A session is the tab's only frontend. The backend's domains keep one state for all of a page's frontends and send each response to each of them, so an extension attaches only to a tab with no other frontend, and opening the tab's Web Inspector ends the session. When the session ends, the backend resets what the extension enabled or overrode. A session also ends when its extension is unloaded or reloaded, without `onDetach`.

