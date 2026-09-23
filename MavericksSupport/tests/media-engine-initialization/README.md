# WK1 media discovery before WebView creation

Run `bash MavericksSupport/tests/media-engine-initialization/run.sh` against the installed frameworks. Compilation appends to `/tmp/wk_build.log`. The harness never activates or orders its offscreen window and needs no HTTP server.

The native WebKit MIME query precedes the first WebView, as happens when Mavericks' Quartz Composer WebKit plug-in is discovered. The merged AVFoundation capture registration now requires platform strategies; early support discovery must not leave the playback engine registry permanently incomplete after those strategies are published.

Two existing capture documents check exact pixel values and disable/re-enable behavior. The harness reports their original assertions and fails on FAIL/TIMEOUT. It never changes AVFoundation or GStreamer preference defaults. Before the fix, early discovery reproduces the 139 gray sample, while the same document with ordinary first-WebView initialization passes.
