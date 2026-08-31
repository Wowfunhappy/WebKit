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
| Never                              | STORED      | BLOCKED     |

The third-party column is constant because `NetworkStorageSession::m_thirdPartyCookieBlockingMode`
defaults to `ThirdPartyCookieBlockingMode::All`, which blocks every third-party cookie without
consulting a classification. The first-party column is what the accept policy decides.
