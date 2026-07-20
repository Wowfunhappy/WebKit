#!/bin/bash
# MAVERICKS_BACKPORT: run WebKit layout tests against the build-dir test drivers on macOS 10.9.
# One wrapper, two ports — pick with the mandatory first argument:
#
#   --wk1   WebKit1, driver = DumpRenderTree      (run-webkit-tests -1)
#   --wk2   WebKit2, driver = WebKitTestRunner    (run-webkit-tests -2)
#
# The port is never inferred: an old habit must not silently run the wrong stack.
#
# Prereqs (one-time): build the drivers with the layout-test config enabled —
#   cmake -S . -B WebKitBuild/Release -DDEVELOPER_MODE=ON -DENABLE_LAYOUT_TESTS=ON \
#         -DENABLE_API_TESTS=OFF -DDEVELOPER_MODE_FATAL_WARNINGS=OFF
#   --wk1:  ninja -C WebKitBuild/Release DumpRenderTree ImageDiff LayoutTestHelper
#   --wk2:  ninja -C WebKitBuild/Release WebKitTestRunner TestRunnerInjectedBundle ImageDiff
# (Flip ENABLE_LAYOUT_TESTS back OFF + rebuild before install-safari7.sh: the test build instruments WebCore
#  with Internals and must not be shipped over the system.)
#
# This wrapper (a) makes the in-place build-dir frameworks loadable without installing them over the system
# — redirecting the post-10.9 framework deps (QuartzCore CAPresentationModifier, etc.) onto the polyfill,
# exactly like stage-frameworks.sh does, patching the WebContent/Networking XPC service execs and assembling the
# WebKit2 injected .bundle (Contents/MacOS + Info.plist + Resources fonts) — and (b) puts the polyfill dylibs on
# DYLD_LIBRARY_PATH. The build frameworks stay test-instrumented; the shipping system frameworks are untouched.
# See [[webkit-mavericks-wktr-wk2]].
#
# Usage:  bash MavericksSupport/scripts/run-layout-tests.sh --wk1|--wk2 [run-webkit-tests args] <test paths...>
#   e.g.  bash MavericksSupport/scripts/run-layout-tests.sh --wk1 storage/domstorage/localstorage/
#         bash MavericksSupport/scripts/run-layout-tests.sh --wk2 --child-processes=2 fast/dom/ fast/css/
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() {
    echo "Usage: bash MavericksSupport/scripts/run-layout-tests.sh --wk1|--wk2 [run-webkit-tests args] <test paths...>" >&2
    echo "       --wk1 = WebKit1/DumpRenderTree, --wk2 = WebKit2/WebKitTestRunner (required, never inferred)" >&2
}

case "${1-}" in
    --wk1) PORT_FLAG="-1"; DRIVER="DumpRenderTree";   NINJA_TARGETS="DumpRenderTree ImageDiff LayoutTestHelper" ;;
    --wk2) PORT_FLAG="-2"; DRIVER="WebKitTestRunner"; NINJA_TARGETS="WebKitTestRunner TestRunnerInjectedBundle ImageDiff" ;;
    *)     usage; exit 2 ;;
esac
shift

if [ ! -x "$ROOT/WebKitBuild/Release/bin/$DRIVER" ]; then
    echo "$DRIVER not built — see the prereqs at the top of $0" >&2
    echo "  ninja -C WebKitBuild/Release $NINJA_TARGETS" >&2
    exit 1
fi

# MAVERICKS_BACKPORT: orphan hygiene + worker cap (2026-07-06 WindowServer crash).
# An aborted run orphans build-tree test processes (kill of the python runner does not
# reach grandchildren); an orphan parked on a GL-retrying test page spams "CoreAnimation:
# failed to create OpenGL context" at frame cadence until 10.9's WindowServer hits its
# null-texture compositor race and takes the whole login session down (see
# DiagnosticReports/WindowServer_2026-07-06-140140). So: reap any stale build-tree test
# processes before starting AND on every exit, and refuse more than 2 parallel workers on
# this VM. Both drivers are reaped whichever port is selected — an orphan left by the
# other port is just as lethal.
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

# Re-apply the in-place framework surgery (idempotent; must run after any relink). Stages the polyfills into the
# build's @rpath dir and rewrites all polyfill deps to @rpath, so the WebKit2 XPC services (which launchd spawns
# without DYLD_*) resolve them self-contained from the build tree; also patches those service execs and assembles
# the WebKit2 injected bundle.
bash "$ROOT/MavericksSupport/scripts/make-build-frameworks-runnable.sh" >/dev/null 2>&1

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
    "$PORT_FLAG" --no-build --no-new-test-results --release --root="$ROOT/WebKitBuild/Release/bin" \
    "$@"
exit $?
