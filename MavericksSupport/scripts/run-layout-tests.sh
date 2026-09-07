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
#         bash MavericksSupport/scripts/run-layout-tests.sh --wk2 --port-surface
#
# --port-surface runs the suite in MavericksSupport/tests/port-surface/layout-tests.txt: the tests
# whose behaviour crosses into the parts of this port that differ from Apple's.
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
    # Anchored at argv[0]: an unanchored pattern also matches helpers that merely carry a driver's
    # path in their arguments, and reaping one of those kills another run's setup step.
    pkill -9 -f "^$ROOT/WebKitBuild/Release/bin/DumpRenderTree" 2>/dev/null
    pkill -9 -f "^$ROOT/WebKitBuild/Release/bin/WebKitTestRunner" 2>/dev/null
    pkill -9 -f "WebKitBuild/Release/.*com\.apple\.WebKit\.(WebContent|Networking)" 2>/dev/null
    return 0
}

# One run at a time: the reap above kills every driver on the machine, the http/wpt servers own fixed
# ports, and the results directory is shared, so a second invocation waits for the first to finish.
# The lock is a directory (bash 3.2 has no flock) holding the owner's pid, and is stale once that pid
# is gone.
LOCK="$ROOT/WebKitBuild/Release/bin/.run-layout-tests.lock"
until mkdir "$LOCK" 2>/dev/null; do
    owner=$(cat "$LOCK/pid" 2>/dev/null)
    if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
        rm -rf "$LOCK"
        continue
    fi
    echo "waiting: another run-layout-tests.sh (pid ${owner:-?}) is running" >&2
    sleep 15
done
echo $$ > "$LOCK/pid"
cleanup() {
    reap_test_orphans
    rm -rf "$LOCK"
}
reap_test_orphans
trap cleanup EXIT INT TERM
WORKERS="--child-processes=2"
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --child-processes=*)
            n="${arg#*=}"
            if [ "$n" -gt 2 ] 2>/dev/null; then
                echo "ERROR: --child-processes=$n refused — >2 parallel workers can crash 10.9's WindowServer (grey screen, session logout). Use --child-processes=2." >&2
                exit 1
            fi
            WORKERS=""; ARGS+=("$arg");;
        --port-surface)
            ARGS+=("--test-list=$ROOT/MavericksSupport/tests/port-surface/layout-tests.txt");;
        *) ARGS+=("$arg");;
    esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}

# --- Make the in-place build products loadable ---------------------------------------------------
if ! bash "$ROOT/MavericksSupport/scripts/make-build-binaries-runnable.sh"; then
    echo "ERROR: could not make the build products loadable" >&2
    exit 1
fi

# --- Run ------------------------------------------------------------------------------------------

# The drivers link Quartz, which transitively loads the SYSTEM (installed-backport) WebKit stack. Left
# alone dyld makes a second image of every framework the build tree also provides -- two JavaScriptCore,
# two WebCore, two of the private GStreamer runtime -- and two GObject type systems answer GST_TYPE_CAPS
# differently, so pad templates come back with null caps and the first caps intersection dereferences one.
#
# run-webkit-tests puts --root on DYLD_FRAMEWORK_PATH, and this port builds its frameworks into lib/ while
# --root names bin/ (which holds only WebInspectorUI.framework), so dyld has nothing to substitute. Naming
# lib/ here gives it the substitution: exactly one image of each framework loads, and the driver appends
# its own --root path after ours.
export DYLD_FRAMEWORK_PATH="$ROOT/WebKitBuild/Release/lib${DYLD_FRAMEWORK_PATH:+:$DYLD_FRAMEWORK_PATH}"
export __XPC_DYLD_FRAMEWORK_PATH="$DYLD_FRAMEWORK_PATH"

# No exec: the runner must stay our child so the EXIT trap can reap orphans even
# when this wrapper is interrupted.
"$ROOT/MavericksSupport/toolchain/build/python3/bin/python3" "$ROOT/Tools/Scripts/run-webkit-tests" \
    "$PORT_FLAG" --no-build --no-new-test-results --release --root="$ROOT/WebKitBuild/Release/bin" \
    $WORKERS "$@"
exit $?
