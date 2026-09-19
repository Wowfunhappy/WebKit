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
#
# The test servers are reaped with them. layout_test_runner.py starts the http and wpt servers only
# when nothing already answers on their first port (is_http_server_running / is_wpt_server_running),
# so a server left behind by an interrupted run is adopted by every run after it -- carrying that
# run's wedged connections, saturated accept queues and expired state into results that read as
# product regressions. `wpt serve` spreads one server per port over multiprocessing children whose
# argv names neither the port nor the script, so the family is matched by our toolchain interpreter
# and the spawn entry point; the lock above is what makes that safe, since it means no run of ours
# owns a python3 of its own while this runs.
# With no argument this reaps machine-wide, which is correct only while holding the lock, when by
# definition no other run of ours is alive. `own` restricts it to this run's own process group, for
# the exit path: a wrapper that is killed while another run legitimately holds the lock would
# otherwise SIGKILL that run's driver and servers out from under it.
reap_test_orphans() {
    local scope=""
    if [ "${1-}" = own ]; then
        local pgid
        pgid=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')
        [ -n "$pgid" ] || return 0
        scope="-g $pgid"
    fi
    # Anchored at argv[0]: an unanchored pattern also matches helpers that merely carry a driver's
    # path in their arguments, and reaping one of those kills another run's setup step.
    pkill -9 $scope -f "^$ROOT/WebKitBuild/Release/bin/DumpRenderTree" 2>/dev/null
    pkill -9 $scope -f "^$ROOT/WebKitBuild/Release/bin/WebKitTestRunner" 2>/dev/null
    pkill -9 $scope -f "WebKitBuild/Release/.*com\.apple\.WebKit\.(WebContent|Networking)" 2>/dev/null
    pkill -9 $scope -f "^$ROOT/MavericksSupport/toolchain/build/python3/bin/python3 -c from multiprocessing\.spawn" 2>/dev/null
    # A forked webkitpy worker keeps the runner's own argv, and with it the inherited DNS socket.
    pkill -9 $scope -f "^$ROOT/MavericksSupport/toolchain/build/python3/bin/python3 $ROOT/Tools/Scripts/run-webkit-tests" 2>/dev/null
    pkill -9 $scope -f "^$ROOT/MavericksSupport/toolchain/build/python3/bin/python3 .*/wpt\.py serve" 2>/dev/null
    pkill -9 $scope -f "^$ROOT/MavericksSupport/toolchain/build/python3/bin/python3 .*pywebsocket3/standalone\.py" 2>/dev/null
    pkill -9 $scope -f "^$ROOT/MavericksSupport/deps/build/bin/httpd" 2>/dev/null
    # Apache's CGI helpers outlive it, and the ones that sleep on a request hold a worker slot.
    pkill -9 $scope -f "^/.*/Python $ROOT/LayoutTests/.*\.py" 2>/dev/null
    return 0
}

# One run at a time: the reap above kills every driver on the machine, the http/wpt servers own fixed
# ports, and the results directory is shared, so a second invocation waits for the first to finish.
# The lock is a directory (bash 3.2 has no flock) holding the owner's pid, and is stale once that pid
# is gone; ps answers that for a root-owned run started under sudo as well as for our own.
LOCK="$ROOT/WebKitBuild/Release/bin/.run-layout-tests.lock"
until mkdir "$LOCK" 2>/dev/null; do
    owner=$(cat "$LOCK/pid" 2>/dev/null)
    if [ -n "$owner" ] && ! ps -p "$owner" >/dev/null 2>&1; then
        if rm -rf "$LOCK" 2>/dev/null; then
            continue
        fi
        echo "stale lock owned by pid $owner cannot be removed (try: sudo rm -rf $LOCK)" >&2
    else
        echo "waiting: another run-layout-tests.sh (pid ${owner:-?}) is running" >&2
    fi
    sleep 15
done
echo $$ > "$LOCK/pid"
cleanup() {
    reap_test_orphans own
    rm -rf "$LOCK"
}
reap_test_orphans
trap cleanup EXIT INT TERM
WORKERS="--child-processes=1"
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
            ARGS+=("--test-list=$ROOT/MavericksSupport/tests/port-surface/layout-tests.txt"
                "--ignore-tests=http/tests/inspector"
                "--ignore-tests=http/tests/site-isolation/inspector"
                "--ignore-tests=http/tests/websocket/tests/hybi/inspector");;
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

export WEBKIT_HTTP_SERVER_CONF_PATH="$ROOT/MavericksSupport/deps/build/httpd.conf"

# The drivers link Quartz, which transitively loads the SYSTEM (installed-backport) WebKit stack. Left
# alone dyld makes a second image of every framework the build tree also provides -- two JavaScriptCore,
# two WebCore, two of the private GStreamer runtime -- and two GObject type systems answer GST_TYPE_CAPS
# differently, so pad templates come back with null caps and the first caps intersection dereferences one.
#
# run-webkit-tests puts --root on DYLD_FRAMEWORK_PATH, and --root names bin/, where CMake puts executables;
# the frameworks are built into lib/, so bin/ alone gives dyld nothing to substitute. Naming
# lib/ here gives it the substitution: exactly one image of each framework loads, and the driver appends
# its own --root path after ours.
export DYLD_FRAMEWORK_PATH="$ROOT/WebKitBuild/Release/lib${DYLD_FRAMEWORK_PATH:+:$DYLD_FRAMEWORK_PATH}"
export __XPC_DYLD_FRAMEWORK_PATH="$DYLD_FRAMEWORK_PATH"

# No exec: the runner must stay our child so the EXIT trap can reap orphans even
# when this wrapper is interrupted.
# Every selected test gets one attempt, and every test any expectation file records as failing or
# flaky is skipped, explicitly selected tests included.
"$ROOT/MavericksSupport/toolchain/build/python3/bin/python3" "$ROOT/Tools/Scripts/run-webkit-tests" \
    "$PORT_FLAG" --no-build --no-new-test-results --release --root="$ROOT/WebKitBuild/Release/bin" \
    $WORKERS "$@" --skip-failing-tests --skipped=always --no-retry-failures
exit $?
