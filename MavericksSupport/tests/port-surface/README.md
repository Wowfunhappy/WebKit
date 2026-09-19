# Port-surface test suite

This suite exercises the Mavericks port's platform integration. `layout-tests.txt`
selects layout suites; `api-tests.txt` selects API binaries and filters.
Accessibility is excluded.

After a completed `MavericksSupport/build.sh` build, run these commands from the
repository root, one at a time:

```sh
bash MavericksSupport/scripts/run-api-tests.sh --port-surface
bash MavericksSupport/tests/image-decoders/incremental-video-image.sh
bash MavericksSupport/tests/cocoa-curl/run.sh cocoa-curl-transfer cocoa-curl-resource-handle cocoa-curl-url-cache cocoa-curl-upload cocoa-curl-downloads cocoa-curl-authentication >> /tmp/wk_build.log 2>&1
bash MavericksSupport/scripts/run-layout-tests.sh --wk1 --port-surface --no-show-results
bash MavericksSupport/scripts/run-layout-tests.sh --wk2 --port-surface --no-show-results
```

Do not overlap these runs with each other or with building/staging: the wrappers
clean up test processes and use shared build products. Keep Safari closed during
cookie tests because it shares the system cookie store. The layout wrapper's
header documents the required local WPT hostname mappings.

The native Cocoa curl probes cover response MIME selection, framing and TLS, HTTP
cache policy and metadata, request headers and upload bodies, downloads, and
authentication. Cache cases use distinct native
keys and bodies inside NSURLCache's entry limit. Their results are in
`WebKitBuild/Release/cocoa-curl-tests/fixtures/<test>.log`.

The incremental video-image probe exercises the built Image API with complete, chunked,
repeated and truncated MP4/HEICS input, including completion and frame-count checks.

Every executed test must pass, and layout failures are not automatically retried.
Skips follow the maintainer's port policy:

- upstream-known failures and flaky tests, with the relevant bug or expectation cited;
- verified native Mavericks font metrics and text rasterization differences;
- unsupported configurations and explicit scope exclusions, including accessibility, PDF plugins,
  and tests requiring the modern Inspector frontend.

Selection follows feature and directory relevance to the port, measured test runtime,
and explicit maintainer scope decisions. Apply these rules uniformly to passing and
failing tests. The layout runner skips tests marked failing or flaky in applicable
TestExpectations using `--skip-failing-tests`. WK1 also applies the current Cocoa
`mac-wk2` failure/flaky records for the shared libwebrtc test directories, preserving
their build and platform conditions and including tests that pass locally.

A `FAIL` line in an upstream text baseline is part of the expected output, not a
reason to exclude the test. These tests remain selected, including in cookies and
networking. A Mavericks-only mismatch requires a port fix. An upstream-defect skip
must cite a record for the same symptom on the backend whose code this port uses:
Cocoa for native frameworks, GLib for GStreamer or libgcrypt, and curl for networking.

The common Mavericks platform links the PBKDF2 and X25519 derivation baselines to
GLib's originals because those algorithms use its libgcrypt implementation. Their
complete expected output, including PASS and FAIL lines, remains checked.

Layout exclusions live in `LayoutTests/platform/mac-mavericks/TestExpectations`
and the `mac-mavericks-wk1` / `mac-mavericks-wk2` expectation files.

Runner regression tests use fake products and can be run directly:

```sh
MavericksSupport/toolchain/build/python3/bin/python3 MavericksSupport/tests/port-surface/api-timeout-test.py
MavericksSupport/toolchain/build/python3/bin/python3 MavericksSupport/tests/port-surface/api-runner-test.py
```

Run these files directly: their hyphenated filenames do not match ordinary
`unittest` discovery. Check the full layout summary and result index for zero
unexpected results and no unrun tests; an exit status alone is not sufficient.
