# Manual test pages

`port-surface/` is not a manual page: it defines the port-surface test suite (the layout tests and
API tests that exercise this port's own surface), run through `scripts/run-layout-tests.sh
--port-surface` and `scripts/run-api-tests.sh --port-surface`.

`cocoa-curl/` is not a manual page either: it holds the programs that exercise the Cocoa curl
transport directly -- transfers, uploads, cookies, HSTS, proxies and PAC, HTTP and proxy
authentication, client certificates, downloads and resume, the WebKitLegacy ResourceHandle, the
NetworkProcess data task -- with the Python fixture servers they talk to. `cocoa-curl/build.sh`
builds them against the current `WebKitBuild/Release` into `WebKitBuild/Release/cocoa-curl-tests/`;
each program's leading comment names the fixture it expects and the port.

Hand-driven pages for the 10.9 backport. Serve them over http, never `file://`:

    cd /Users/jonathan/Desktop/webkit && python3 -m http.server 8899
    open http://127.0.0.1:8899/MavericksSupport/tests/<page>

A `file://` page that requests notification permission bricks Safari 7's Preferences window,
and several pages here reach relative resources under `LayoutTests/`, so serve from the repo root.

Scoring legend: **title** = the page writes PASS/FAIL (or the measurement) into `document.title`;
**banner** = an in-page verdict element; **visual** = judge by screenshot; **manual** = needs a
click, a key press, or a hardware/manual step.

| Page / dir | Checks | Scored | Needs |
|---|---|---|---|
| `appearance-controls-test.html` | Aqua progress bars (determinate concave track, indeterminate stripes), number spinners, switch, at 1x and `zoom:4` | visual | — |
| `avf-polyfill-test.html` | Web Speech synthesis through the AVFoundation speech polyfill (voices, start/end events, pitch path) | banner | audio out |
| `brotli-decompression-test.html` | `DecompressionStream('brotli')` decodes a known blob to the exact original | title + banner | — |
| `canvas-capture-colorspace-test.html` | canvas `captureStream()` -> VideoFrame colour-space constants soft-linked from CoreMedia; PASS = "SURVIVED 60 captured frames", no WebContent crash | banner | — |
| `canvas-text-test.html` | canvas `fillText`/`measureText`: baseline placement, alignment and metrics across generic families and sizes | title + banner | — |
| `canvas_todataurl_crash_test.html` | accelerated 2D canvas `toDataURL()` does not sink the IOSurface backend (WebContent survives the next rendering update) | banner | — |
| `cookie-accept-policy/` | Safari's Privacy > "Block cookies and other website data" decides a real load: "Always" blocks a first-party `Set-Cookie`, the other two settings store it (`-[NSHTTPCookieStorage _overrideSessionCookieAcceptPolicy]`) | manual, banner | `python …/server.py`, then http://127.0.0.1:8731/, and the Privacy radio set from the UI; see the dir's README |
| `datalist-test.html` | `<input list>` suggestion dropdown appears and a pick fires `change` | manual, banner | — |
| `dnd-test.html` | HTML5 drag-and-drop events and `dropEffect` between two elements | manual, banner | — |
| `find-many-test.html` | Cmd-F over many matches ("target" in every paragraph): highlight count and scroll-to-match | manual, visual | — |
| `fixed-background-parallax-test.html` | a `background-attachment: fixed` stripe pattern stays anchored to the viewport under isolated wheel notches while the page burns 8ms per rAF; any single-frame displacement flips the stripe colour under a fixed screen point | visual, manual | notched wheel or a synthetic line-unit `CGEventCreateScrollWheelEvent` ~180ms apart |
| `fixed-test.html` | `position:fixed` stays pinned while scrolling; title reports scrollWidth/scrollY/computed position | title + visual | — |
| `forms.html` | Form controls and the scroll-corner render | visual | — |
| `gzip-suppression/server.py` | gzip `Content-Encoding` bodies CFNetwork withholds for gzip-archive responses are decoded exactly once for fetch()/XHR, over the extension x media-type x Content-Disposition matrix, plus multi-member and truncated bodies (github #74) | title + console | `python3 …/server.py`, then http://127.0.0.1:8101/ |
| `fullscreen/fullscreen-test.html` | element `requestFullscreen` / exit and the `:fullscreen` styles | manual, banner | — |
| `fullscreen/fs-tile-test.html` | full-screen page's Mission Control tile shows the page (colour grid), not a blank | manual, visual | — |
| `fullscreen/issue48-fullscreen.html` | Lion-style fullscreen: enter, exit, mid-transition exit, navigate-away; the first line after each "in" is the acceptance measurement | manual, banner | — |
| `fullscreen/video-fs-test.html` | `<video>` native fullscreen button and exit | manual, visual | `LayoutTests/media/content/test.mp4` (relative) |
| `gamepad-test.html` | Gamepad API surface (`getGamepads`, `Gamepad`, `GamepadEvent`) plus live input | title + banner; live input manual | controller for the live part |
| `github-flakiness/capture.sh`, `watch.sh` | Records fetch/XHR failures, JS errors and error UI on github.com in the front Safari tab; reports land in `/tmp/github-failure-*.txt` | shell output | Safari on github.com, network |
| `image-decoders/paste-test.html` | Copy an image out of the page and paste it back, and paste a TIFF put on the pasteboard by another application: the pasted image must decode, which is this port's TIFF decoder reading what `Pasteboard::read` hands the editor | manual (Cmd-C / Cmd-V), banner | serve the repo, then `python2.7 -c "import AppKit,Foundation; pb=AppKit.NSPasteboard.generalPasteboard(); pb.clearContents(); pb.setData_forType_(Foundation.NSData.dataWithContentsOfFile_('…/corpus/corpus-rgb.tiff'), AppKit.NSPasteboardTypeTIFF)"` for the TIFF-only case |
| `image-decoders/index.html` | Every image format this port decodes in WebCore -- PNG, animated PNG, GIF, animated GIF, BMP, ICO, JPEG, and TIFF in twelve encodings (both byte orders, greyscale, associated/unassociated/unspecified/absent alpha, one strip and many, top and bottom origin, tiled, multi-page) -- carries the same picture, and the page samples four pixels of each through a canvas | title + banner | `python3 MavericksSupport/tests/image-decoders/make-corpus.py` first (the corpus is generated, not committed) |
| `iconfont-test.html` | Material Icons ligature and codepoint glyphs render as pictograms | visual (title says "icons ready") | network (Google Fonts) |
| `multi-video-stress.html` | N concurrent GStreamer pipelines with play/pause/seek churn; RunLoop::Timer start/stop from streaming threads | banner (status line), crash count | `LayoutTests/media/content/test.mp4` (relative) |
| `pdf-transparency-test.html` | Text under opacity/blend/mask/clip/text-shadow/stroke-only survives Print-to-PDF (transparency layers on the PDF context) | manual (print), visual in the PDF | — |
| `popover-scroll-test.html` | Wheel/keyboard scrolling inside `[popover]` and `<dialog>` overflow boxes | manual, banner | — |
| `privacy-preferences/` | Advanced Tracking and Fingerprinting Protection driven by "Ask websites not to track me", the Storage Access API consent sheet (plain and organization variants), and HTTPS-by-default upgrade + fallback | see the dir's README | a local server, `127.0.0.1 wktest.example` in `/etc/hosts`, and the Privacy preference toggled between runs |
| `qltest.html` | Quick Look HTML preview launches WebContent and renders (not source text) | visual | `qlmanage -p qltest.html` |
| `quicklook-webloc/*.webloc` | Quick Look preview of `.webloc` bookmarks: local host, `/etc/hosts` alias, numeric IP, dead host, https; spinner vs "cannot be displayed" card | manual, visual | `python3 -m http.server 8899`, `127.0.0.1 wktest.example` in `/etc/hosts`, network for the remote ones |
| `search-event-test.html` | `<input type=search incremental>` fires `onsearch` on Enter | manual, title + banner | — |
| `screen-capture-test.html` | `getDisplayMedia` screen sharing: the consent sheet, then a live preview of this screen; PASS = the sampled frames keep changing | manual (click + Allow), title + banner | — |
| `secure-context-window-reuse/run.sh` | A WebKit1 host that enables the whole SDK-aligned behavior set and touches JavaScript before it loads gets a fresh window for the loaded document, with `crypto.subtle`, `SubtleCrypto`, `CryptoKey` and `showPopover` on it | shell output (PASS/FAIL) | — |
| `speech-test.html` | Web Speech synthesis: voices list, speak/pause/resume/stop | manual, banner | audio out |
| `text/zerofont.html` | `font-size:0` runs measure 0 (system, UI-type and web fonts); 1px/16px controls unmoved; icon offset matches reference. Expected values in the page's head comment | title + banner | — |
| `text/zerofallback.html` | `font-size:0` through the system-fallback path (CJK, emoji, symbols, Arabic) measures 0. Expected values in head comment | title + banner | — |
| `text/textstyles.html` | `-apple-system-*` CSS shorthands realize at macOS table sizes; system-ui weight | banner ("ALL SIZES MATCH THE macOS TABLE") + visual | — |
| `text/shape.html` | `CTFontShapeGlyphs` polyfill: synthesized vs real small caps, ligatures, kerning, NBSP runs, RTL, Zapfino kern | title + banner | — |
| `upload-file-drop.html` | File drop -> `FileReader` + `FormData`/raw-file XHR POST | banner (or DRT text dump) | DRT (`eventSender`), `upload-test.png` next to the page, an upload endpoint on `127.0.0.1:8765/upload` |
| `variable-font-test.html` | Variable-font axis instances (Amstelvar wght/wdth) realize the requested point, judged by advance width | title + banner | `LayoutTests/fast/text/variations/...` (relative) |
| `web-inspector-styles/issue87b..g.html` | Web Inspector Styles sidebar: comments in rules, one-line multi-property rules, nested rules, declarations after nested rules, non-rule braces | manual (open Inspector > Styles), visual | — |
| `webgl-shader-test.html` | ANGLE's CGL/desktop-GL backend: a shader using a loop, a short-circuiting condition and a `mat4` (the constructs the Apple GLSL tree operations rewrite) compiles, links and rasterizes a triangle | banner + visual | — |
| `webrtc-loopback-test.html` | Two in-page `RTCPeerConnection`s complete a data-channel ping/pong over libwebrtc (DTLS+SCTP+ICE), no media | banner | — |
| `webrtc-nodc-test.html` | Loopback with an audio transceiver and no data channel: offer/answer + ICE reach `connected` | banner | — |
| `webshare-quarantine-test.html` | `navigator.share({files})` -> `WKShareSheet writeFileToShareableURL:` quarantine attribute | manual, banner | — |
| `widevine-image/` | Mach-O fixup conversion and CRX3 extraction for Google's Widevine module (`WidevineCdmImage.cpp`, `WidevineCdmArchive.mm`); see `run.sh` | shell output | a built tree; optionally a real `libwidevinecdm.dylib` / `.crx3` |
| `widevine-keysystem-test.html` | `com.widevine.alpha` and `org.w3.clearkey` reach `requestMediaKeySystemAccess`, `createMediaKeys()` and `createSession()`; the Widevine arm instantiates Google's installed CDM | banner | the Widevine CDM installed (the page installs it on first run) |
