#!/bin/bash
# Run WebKit layout tests against the build-dir test drivers on macOS 10.9, without installing anything
# over the system. One wrapper, two ports — the port is never inferred:
#
#   --wk1   WebKit1, driver = DumpRenderTree      (run-webkit-tests -1)
#   --wk2   WebKit2, driver = WebKitTestRunner    (run-webkit-tests -2)
#
# The drivers are part of every build.sh run (ENABLE_LAYOUT_TESTS is a port default in
# MavericksSupport/cmake/OptionsMacMavericks.cmake), so a green build has them matched to its frameworks.
#
# The WPT suites under imported/w3c/web-platform-tests are served from web-platform.test and
# not-web-platform.test, which have to resolve to 127.0.0.1 -- this port has no Network.framework and
# so cannot use the nw_resolver_config redirection Apple's ports use, so the twelve names go in
# /etc/hosts (`wpt make-hosts-file` lists them; base.py's localhost_aliases() is the same set).
#
# Before each run make-build-binaries-runnable.sh makes the in-place build products loadable.
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
    --wk1) PORT_FLAG="-1"; DRIVER="DumpRenderTree" ;;
    --wk2) PORT_FLAG="-2"; DRIVER="WebKitTestRunner" ;;
    *)     usage; exit 2 ;;
esac
shift

if [ ! -x "$ROOT/WebKitBuild/Release/bin/$DRIVER" ]; then
    echo "$DRIVER not built — run MavericksSupport/build.sh" >&2
    exit 1
fi

# Orphan hygiene + worker cap: an aborted run orphans build-tree test processes (killing the python
# runner does not reach grandchildren), and an orphan parked on a GL-retrying test page spams
# "CoreAnimation: failed to create OpenGL context" until 10.9's WindowServer hits its null-texture
# compositor race and takes the login session down. So reap stale build-tree test processes before
# starting AND on every exit (both drivers, whichever port), and refuse more than 2 parallel workers.
reap_test_orphans() {
    pkill -9 -f "WebKitBuild/Release/bin/DumpRenderTree" 2>/dev/null
    pkill -9 -f "WebKitBuild/Release/bin/WebKitTestRunner" 2>/dev/null
    pkill -9 -f "WebKitBuild/Release/.*com\.apple\.WebKit\.(WebContent|Networking)" 2>/dev/null
    return 0
}
reap_test_orphans
trap reap_test_orphans EXIT INT TERM
WORKERS="--child-processes=2"
for arg in "$@"; do
    case "$arg" in
        --child-processes=*)
            n="${arg#*=}"
            if [ "$n" -gt 2 ] 2>/dev/null; then
                echo "ERROR: --child-processes=$n refused — >2 parallel workers can crash 10.9's WindowServer (grey screen, session logout). Use --child-processes=2." >&2
                exit 1
            fi
            WORKERS="";;
    esac
done

# --- Make the in-place build products loadable ---------------------------------------------------
if ! bash "$ROOT/MavericksSupport/scripts/make-build-binaries-runnable.sh"; then
    echo "ERROR: could not make the build products loadable" >&2
    exit 1
fi

# --- Run ------------------------------------------------------------------------------------------

# point the leaf-name libpolyfill_classes.dylib resolution at OUR repo's polyfill build dir
# (NOT /usr/local/lib, NOT a system path). This matters only when the Safari 7 backport is ALSO installed
# system-wide: the test driver links Quartz, which transitively loads the SYSTEM (installed-backport)
# JavaScriptCore.framework and its bundled libpolyfill_classes.dylib. Without this, the build's @rpath copy and
# the system framework's bundled copy are two different files => duplicate ObjC class registration => crash. The
# leaf override unifies both loads onto the single repo copy. Self-contained to the repo; never written to /usr.
export DYLD_LIBRARY_PATH="$ROOT/MavericksSupport/polyfill/build${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"

# No exec: the runner must stay our child so the EXIT trap can reap orphans even
# when this wrapper is interrupted.
"$ROOT/MavericksSupport/toolchain/build/python3/bin/python3" "$ROOT/Tools/Scripts/run-webkit-tests" \
    "$PORT_FLAG" --no-build --no-new-test-results --release --root="$ROOT/WebKitBuild/Release/bin" \
    $WORKERS "$@"
exit $?
