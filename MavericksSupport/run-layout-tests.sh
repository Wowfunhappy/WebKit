#!/bin/bash
# MAVERICKS_BACKPORT: run WebKit layout tests against the build-dir DumpRenderTree (WebKit1) on macOS 10.9.
#
# Prereqs (one-time): build the drivers with the layout-test config enabled —
#   cmake -S . -B WebKitBuild/Release -DDEVELOPER_MODE=ON -DENABLE_LAYOUT_TESTS=ON \
#         -DENABLE_API_TESTS=OFF -DDEVELOPER_MODE_FATAL_WARNINGS=OFF
#   ninja -C WebKitBuild/Release DumpRenderTree ImageDiff LayoutTestHelper
# (Flip ENABLE_LAYOUT_TESTS back OFF + rebuild before install-safari7.sh: the test build instruments WebCore
#  with Internals and must not be shipped over the system.)
#
# This wrapper (a) makes the in-place build-dir frameworks loadable without installing them over the system
# — redirecting the post-10.9 framework deps (QuartzCore CAPresentationModifier, etc.) onto the polyfill,
# exactly like install-safari7.sh does — and (b) puts the polyfill dylibs on DYLD_LIBRARY_PATH. The build
# frameworks stay test-instrumented; the shipping system frameworks are untouched.
#
# Usage:  bash MavericksSupport/run-layout-tests.sh [run-webkit-tests args] <test paths...>
#   e.g.  bash MavericksSupport/run-layout-tests.sh storage/domstorage/localstorage/
#         bash MavericksSupport/run-layout-tests.sh --child-processes=4 webaudio/ fast/dom/
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ ! -x "$ROOT/WebKitBuild/Release/bin/DumpRenderTree" ]; then
    echo "DumpRenderTree not built — see the prereqs at the top of $0" >&2
    exit 1
fi

# MAVERICKS_BACKPORT: orphan hygiene + worker cap — same rationale as run-layout-tests-wk2.sh
# (aborted runs orphan build-tree test processes; a GL-retrying orphan can crash 10.9's
# WindowServer and take down the whole login session).
reap_test_orphans() {
    pkill -9 -f "WebKitBuild/Release/bin/DumpRenderTree" 2>/dev/null
    pkill -9 -f "WebKitBuild/Release/bin/WebKitTestRunner" 2>/dev/null
    pkill -9 -f "WebKitBuild/Release/.*com\.apple\.WebKit\.(WebContent|Networking)" 2>/dev/null
    return 0
}
reap_test_orphans
trap reap_test_orphans EXIT INT TERM
for arg in "$@"; do
    case "$arg" in
        --child-processes=*)
            n="${arg#*=}"
            if [ "$n" -gt 2 ] 2>/dev/null; then
                echo "ERROR: --child-processes=$n refused — >2 parallel workers can crash 10.9's WindowServer (grey screen, session logout). Use --child-processes=2." >&2
                exit 1
            fi;;
    esac
done

# Re-apply the in-place framework surgery (idempotent; must run after any relink). This stages the polyfills into
# the build's @rpath dir and rewrites all polyfill deps to @rpath, so the WebKit2 XPC services (which launchd
# spawns without DYLD_*) resolve them self-contained from the build tree.
bash "$ROOT/MavericksSupport/make-build-frameworks-runnable.sh" >/dev/null 2>&1

# MAVERICKS_BACKPORT: point the leaf-name libpolyfill_classes.dylib resolution at OUR repo's polyfill build dir
# (NOT /usr/local/lib, NOT a system path). This matters only when the Safari 7 backport is ALSO installed
# system-wide: the test driver links Quartz, which transitively loads the SYSTEM (installed-backport)
# JavaScriptCore.framework and its bundled libpolyfill_classes.dylib. Without this, the build's @rpath copy and
# the system framework's bundled copy are two different files => duplicate ObjC class registration => crash. The
# leaf override unifies both loads onto the single repo copy. Self-contained to the repo; never written to /usr.
export DYLD_LIBRARY_PATH="$ROOT/MavericksSupport/polyfill/build${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"

# No exec: the runner must stay our child so the EXIT trap can reap orphans even
# when this wrapper is interrupted.
/usr/local/bin/python3 "$ROOT/Tools/Scripts/run-webkit-tests" \
    -1 --no-build --no-new-test-results --release --root="$ROOT/WebKitBuild/Release/bin" \
    "$@"
exit $?
