#!/bin/bash
# MAVERICKS_BACKPORT: run WebKit layout tests against the build-dir WebKitTestRunner (WebKit2) on macOS 10.9.
#
# Prereqs (one-time): build the WK2 drivers with the layout-test config enabled —
#   cmake -S . -B WebKitBuild/Release -DDEVELOPER_MODE=ON -DENABLE_LAYOUT_TESTS=ON \
#         -DENABLE_API_TESTS=OFF -DDEVELOPER_MODE_FATAL_WARNINGS=OFF
#   ninja -C WebKitBuild/Release WebKitTestRunner TestRunnerInjectedBundle ImageDiff
# (Flip ENABLE_LAYOUT_TESTS back OFF + rebuild before install-safari7.sh: the test build instruments WebCore
#  with Internals and must not be shipped over the system.)
#
# make-build-frameworks-runnable.sh makes the in-place build frameworks loadable (self-contained @rpath, no
# system writes), patches the WebContent/Networking XPC service execs, and assembles the injected .bundle
# (Contents/MacOS + Info.plist + Resources fonts). See [[webkit-mavericks-wktr-wk2]].
#
# Usage:  bash MavericksSupport/run-layout-tests-wk2.sh [run-webkit-tests args] <test paths...>
#   e.g.  bash MavericksSupport/run-layout-tests-wk2.sh storage/domstorage/localstorage/
#         bash MavericksSupport/run-layout-tests-wk2.sh --child-processes=4 fast/dom/ fast/css/
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ ! -x "$ROOT/WebKitBuild/Release/bin/WebKitTestRunner" ]; then
    echo "WebKitTestRunner not built — see the prereqs at the top of $0" >&2
    exit 1
fi

# MAVERICKS_BACKPORT: orphan hygiene + worker cap (2026-07-06 WindowServer crash).
# An aborted run orphans build-tree WebContent processes (kill of the python runner
# does not reach grandchildren); an orphan parked on a GL-retrying test page spams
# "CoreAnimation: failed to create OpenGL context" at frame cadence until 10.9's
# WindowServer hits its null-texture compositor race and takes the whole login
# session down (see DiagnosticReports/WindowServer_2026-07-06-140140). So: reap any
# stale build-tree test processes before starting AND on every exit, and refuse
# more than 2 parallel workers on this VM.
reap_test_orphans() {
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
                echo "ERROR: --child-processes=$n refused — >2 parallel WKTR workers can crash 10.9's WindowServer (grey screen, session logout). Use --child-processes=2." >&2
                exit 1
            fi;;
    esac
done

# Re-apply the in-place framework surgery (idempotent; must run after any relink). Stages the polyfills into the
# build @rpath dir, repoints all deps to @rpath, patches the XPC services, and assembles the injected bundle.
bash "$ROOT/MavericksSupport/make-build-frameworks-runnable.sh" >/dev/null 2>&1

# MAVERICKS_BACKPORT: point the leaf-name libpolyfill_classes.dylib resolution at OUR repo's polyfill build dir
# (NOT /usr/local/lib, NOT a system path) to unify the polyfill copy with any system-installed Safari 7 backport
# that Quartz/QuickLookUI may drag in. Self-contained to the repo; never written to /usr. See run-layout-tests.sh.
export DYLD_LIBRARY_PATH="$ROOT/MavericksSupport/polyfill/build${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"

# No exec: the runner must stay our child so the EXIT trap can reap orphans even
# when this wrapper is interrupted.
/usr/local/bin/python3 "$ROOT/Tools/Scripts/run-webkit-tests" \
    -2 --no-build --no-new-test-results --release --root="$ROOT/WebKitBuild/Release/bin" \
    "$@"
exit $?
