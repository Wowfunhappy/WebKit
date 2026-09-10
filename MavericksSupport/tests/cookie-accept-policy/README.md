# Cookie accept policy

Exercises Safari's Privacy > "Block cookies and other website data" against a real load, which is what
`-[NSHTTPCookieStorage _overrideSessionCookieAcceptPolicy]` makes authoritative: without it every load
answers to `NSURLSessionConfiguration`'s default instead of the cookie storage's own policy.

    python MavericksSupport/tests/cookie-accept-policy/server.py

Then open <http://127.0.0.1:8731/>. The page reports STORED, BLOCKED or ERROR for a first-party cookie
(`127.0.0.1`) and a third-party one (`localhost`), and leaves the same string in `window.RESULT` for
`osascript ... do JavaScript`.

Each run sets a cookie whose name and value nothing has stored before. That matters: under "Always" the
`Set-Cookie` that would delete a previous run's cookie is itself blocked, so a fixed cookie name reports
a stale cookie as a fresh store.

Set the level by clicking the radio. `defaults write` is not enough — Safari holds the state across
several preferences and rewrites them as a set, and a written value it does not recognise leaves the
radio where it was. The path under test is `WKCookieManagerSetHTTPCookieAcceptPolicy` ->
`WebCookieManager::setHTTPCookieAcceptPolicy` -> `CFHTTPCookieStorageSetCookieAcceptPolicy` on the CF
store, which the polyfill then makes win over the session configuration.

Expected:

| Block cookies                      | first party | third party |
| ---------------------------------- | ----------- | ----------- |
| From third parties and advertisers | STORED      | BLOCKED     |
| Always                             | BLOCKED     | BLOCKED     |
| Never                              | STORED      | STORED      |

The first-party column is what the accept policy decides. The third-party column is decided twice
over: the jar refuses a cross-site `Set-Cookie` under `OnlyFromMainDocumentDomain`, and
`NetworkStorageSession::thirdPartyCookieBlockingDecisionForRequest` refuses one whenever tracking
prevention is on (`ThirdPartyCookieBlockingMode::All` consults no classification). Both answer to the
accept policy: the account carries it across launches, so `determineTrackingPreventionStateInternal`
reads it for a session nobody has told otherwise, and `WKCookieManagerSetHTTPCookieAcceptPolicy`
carries a change of it to every session this client has.

Safari pushes the accept policy only when its own read-back disagrees with it -- at "Never" it agrees
and Safari stays silent -- so **a run that never touches the radio** is the one that tells you whether
the level travels on the account's own record rather than on that push. Quit Safari, set the level in
the previous run, and load the page as the first thing the new launch does.

A Private Browsing window belongs to a second, ephemeral session; run the table there too, both by
switching the level while it is open and by opening it after the switch.
