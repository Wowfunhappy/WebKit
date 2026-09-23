Run `bash MavericksSupport/tests/iframe-history/run.sh` after installing WebKit.
The standalone WK1 WebView loads the existing iframe pushState and sibling-removal
layout tests and checks their terminal document text. It can run alongside the
layout runner without changing its server or driver processes. The layout suite
remains the full testRunner-based verification.

`bash MavericksSupport/tests/iframe-history/run-wk2.sh` runs the same two documents
in a standalone WKWebView to verify the separate WK2 tree behavior.

`bash MavericksSupport/tests/iframe-history/run-referrer.sh` is a separate WK1
diagnostic against an already running layout HTTP server on port 8000. It creates
offscreen popup WebViews and enables BroadcastChannel as the layout runner does.
The upstream about:blank inheritance test passes; the two cross-origin navigation
tests reproduce the unchanged WK1 policy-cache defect documented by upstream bug
309645. Their failed assertions are retained in this diagnostic. The upstream fix
in 42cc878 resets WK2's provisional frame proxy and does not repair WK1.
