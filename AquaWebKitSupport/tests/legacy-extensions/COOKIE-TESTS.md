# Local extension cookie tests

`cookie-server.py` serves HTTP/WS on loopback port 8877 and HTTPS/WSS on 8878.
Supply a trusted local certificate and key with `--cert` and `--key`. Its request
and extension-registration log is created as `results/cookies/server.jsonl` beside
these drivers. Set `AQUAWEBKIT_COOKIE_TEST_DIR` for the server and drivers to use a
different results directory. Start the server before loading the fixtures.

`check-extension-cookies.py prepare` writes the All, Some, None, and HTTP-only
fixtures into `AquaWebKit-Extensions`, beside the WebKit checkout. Load them through
Safari's Extension Builder. The fixtures register their current extension URLs
with the server. After preparing updated files or relaunching Safari, run
`check-extension-cookies.py reload` to install their current contents and wait for
fresh URL registrations. Read that workspace's README for extension setup.

`check-extension-cookies.py run` records `verified.json` in the results directory.
It seeds local HTTP/HTTPS cookies and exercises global pages, extension tabs,
extension iframes, ordinary pages and ordinary cross-site iframes under Safari
privacy policies 0, 2 and 1. The driver reads Safari's selected privacy policy
before changing it and restores it on exit, including a failed seed operation.
An explicit `--phase` selects a different output filename.

Run `check-cookie-matrix.py PATH/verified.json` to check the capture. Ordinary
same-site requests send unspecified/None, Lax and Strict cookies. Ordinary
cross-site requests send only unspecified/None at policy 0 and none at policies
2 and 1. Fetch `omit` sends none; cross-origin fetch `same-origin` and XHR without
credentials send none. The checker uses these expectations directly.

The supplementary drivers cover workers, the extension bar, embedded web pages,
fresh-host acceptance, generated webRequest headers, DOM cookie visibility,
network-process restart, and permission revocation/restoration. Run the primary
matrix first to seed their cookies and populate the registration log. The
supplementary acceptance cases use `ext-cookie.test` and its subdomains, which
must resolve to loopback. Policy-changing drivers restore the selected policy;
the permission driver also restores the fixture's original plist and installed version.

The native policy test is `../cocoa-curl/cocoa-curl-extension-cookies.mm`. It is
included in the cocoa-curl suite's default discovery and uses a fresh, isolated
native cookie jar. Its redirect tests append real hops explicitly and distinguish
those from WebSocket cookie-URL normalization.

`check-extension-cookie-headers.py [phase]` matches every fetch/XHR response and WebSocket handshake
to its generated `extraHeaders` event by host and path. It asserts Cookie
values on the wire, the empty Cookie result of a removal verdict, and that changing
Origin preserves the source-origin cookie permission. Failures are recorded beside
both observations in `PHASE-headers.json`.

`check-cookie-response-redirects.py` uses an All-access observer to redirect
responses requested by the Some-access fixture. It checks permitted-to-permitted
and denied-to-permitted hops for global-page and tab fetches and pings, using both
initial and final wire records. WK1 uses `<a ping>` because upstream disables
Beacon API in WebKitLegacy; WK2 uses `sendBeacon`. The driver temporarily enables
hyperlink auditing through its fixture and restores its prior value and controller,
recorded in `response-redirects-settings.json`. Results are in `response-redirects.json`.

`check-cookie-parent-navigation.py` first loads a cross-site child, then has its
extension parent replace that child's URL with a permitted site. It checks WK1
global pages, WK2 tabs, and ordinary web parents under all three privacy policies.
A web-parent control also replaces an existing extension child with a cross-site
web page and checks that it inherits no extension cookie privilege. The final
child posts its server-recorded request cookies to the parent; the
capture is `parent-navigation.json`, including extension webRequest initiator
metadata and generated Cookie headers for diagnosis. A failure in the WK2 existing-child case
requires comparing `sourceOrigin` with the existing `navigationRequester` carrier.

Re-run `prepare` and reload the cookie fixtures before these drivers so the global
page includes their message handlers. Run the primary matrix first to seed cookies.
The existing Networking-restart and permission-lifecycle drivers remain part of
the verification sequence.

`../cocoa-curl/cocoa-curl-extension-cookie-handoff.mm` exercises a real WK1
ResourceHandle-to-WebDownload transfer. The loopback download fixture on port 18982
returns the first byte of a 401 body, keeping the remainder pending; ResourceHandle declines the challenge, and the adopted WebDownload
answers it. The authenticated retry must send the seeded None/Lax/Strict cookies
and store the response's new cookies, including HttpOnly Strict, under both native
first-party acceptance and explicit third-party blocking. Only that retry sends
Set-Cookie, so the store assertions exercise the download owner. The test uses an
isolated jar and removes its generated download directory.

When the shared build and Safari are free, rebuild/install/relaunch before running
the browser matrix and supplementary drivers. Run the marker gate after the last
edit under Source/ and retain its output with the build and runtime evidence.

`check-extension-cookies-extra.py approved` covers HTTP/HTTPS and WS/WSS from
dedicated/shared workers, the bar and the popover under all three policies. Check
its 243 cases with `check-cookie-extra-matrix.py PATH/approved-extra.json`. Both
matrix checkers require complete case coverage, including all transport results.

`check-cookie-permissions.py` requires Some installed from its canonical fixture
directory. It checks both the WK1 global page and WK2 tab, installs a None version,
quits Safari and verifies the old PID exits with `kill -0`, relaunches, reloads the
fixture and checks ordinary-policy cookies. It then installs the saved Some version
and repeats the verified relaunch, expecting all eight cookies again. Safari 7's
in-memory extension metadata retains the old Website Access list across same-session
reinstallation; the lifecycle test therefore checks revocation after relaunch.
The driver saves each PID transition and all HTTP/XHR/WebSocket observations in
`permission-lifecycle.json` and restores the user's original privacy setting.

`check-cookie-websockets.py --phase verified` checks WK1 global-page and WK2 tab
handshakes under policies 0/2/1. Start `cookie-server.py` with the ordinary trusted
certificate/key arguments and `--websocket-proxies 8879 8880`. Resolve
ext-cookie.test to loopback and include localhost, ext-cookie.test and 127.0.0.1
in the certificate. Prepare and install the All observer and Some requester;
relaunch Safari after installing the certificate, then reload the fixtures.
The driver and server share `AQUAWEBKIT_COOKIE_TEST_DIR` when set.

The 334-case matrix retains the original 172 cases and adds complete handshake
event ordering, one terminal event, protected-header injection, response-header
repair/rejection/cancellation, ignored response redirect verdicts, authentication,
proxy credentials and per-hop routing, next-hop onBeforeRequest cancellation,
pass-through header ordering, and close/navigation during held request and response
header verdicts. Hidden credential and transport fields must stay out of listener
details; Connection remains visible and resists replacement. Upgrade responses
retain the full `HTTP/1.1 101 Switching Protocols` status line. Cookie still requires
extraHeaders. The local proxies use synthetic credentials
and forward only to the three loopback fixture hosts on ports 8877/8878. HTTP proxy
credentials use `proxyAuthorizationHeader`. Normal server upgrades complete the
WebSocket closing handshake before closing the connection.

WK1 rejects a network redirect at its first non-101 response. WK2 follows the four
permission chains and repeats onHeadersReceived → onBeforeRedirect → proxy.onRequest
→ onBeforeRequest → header events at each hop. Its all-permitted chain keeps
Lax/Strict; a visited denied hop taints the remaining chain. Safari's native policy
blocks a denied target at 2/1, while a later permitted target can read U cookies.
WK2 401 retries report onAuthRequired and keep their credentials hidden. WK1's
upstream 401 behavior is tested as a response followed by an error.

The delayed tests wait until the observer holds a blocking verdict, then close the
requester's socket or navigate its document. They require the terminal error before
releasing the verdict, no later header send or second terminal event, and no late
wire bytes. A held response necessarily has one initial handshake request; its
server records zero client frames after that response. A held request must send
no HTTP handshake at all. `pages/cookie-websocket-observer.js` supplies the listeners;
the generated global fixture supplies the close/navigation controls.

`websocket-console.py` starts read-only native DTrace probes from
`websocket-console.d` for Safari and its WebContent processes during the final matrix.
It observes Document::addConsoleMessage inside the native WebSocket error path,
after the caller materializes the message text.
It requires noninteractive sudo, stops every probe in cleanup, records expected
Upgrade-failure positive controls for WK1 and WK2, and rejects the generic
"Failed to send WebSocket handshake" error or tracing faults. No missing probe or
positive control counts as a console pass. The result files retain console logs
and `console-check.json`. This tracing runs only during an authorized browser test.

`check-cookie-websocket-pass-through.py` compares the original WK1 handshake buffer
at `platformSendInternal` with the exact bytes a dedicated loopback server receives.
Run this check with only the All/Some fixtures enabled, and restore the other
extensions afterwards. It checks a control and a blocking onBeforeRequest-only listener, requiring one
listener event and zero request-header or response-header interception calls.
`websocket-handshake-bytes.d` supplies the native buffer and interception probes;
`pass-through.json` retains both byte strings as base64. The driver removes its
listener, closes its windows and stops its trace and server.

Results are `PHASE-websockets.json`, with wire records, all events, comparisons,
console results and explicit coverage checks. `--baseline` captures the original
120 cases; missing events remain failures. The checker is also importable for
synthetic negative tests. Drivers restore their listeners, windows and privacy
setting; fixture installation and certificate/proxy-server cleanup follow the
same suite workflow. Seeded extck_ cookies last one day for instrumented runs;
remove these fixture cookies from localhost, 127.0.0.1 and ext-cookie.test during cleanup.
The full matrix and existing header driver must be rerun on
the newly installed build after a verified Safari relaunch.

`check-webrequest-listener-details.js` runs the API dispatcher’s actual JavaScript
in Node. It checks independent listener snapshots, binary request-body copies,
request-header deltas, extraHeaders isolation, and response-field deltas. The live
WebSocket remove/replace cases also use a second blocking listener without
extraHeaders; its added header must reach the wire without undoing the Cookie edit.
