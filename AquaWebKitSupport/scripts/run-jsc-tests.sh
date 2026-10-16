#!/bin/bash
# Run JavaScriptCore's test suites (Tools/Scripts/run-javascriptcore-tests: testmasm, testair, testb3,
# testdfg, testwasmdebugger, then the run-jsc-stress-tests collections) against the build-dir products on
# macOS 10.9, without installing anything over the system.
#
# The binaries are part of every build.sh run, so a green build has them matched to its frameworks.
#
# Usage:  bash AquaWebKitSupport/scripts/run-jsc-tests.sh [run-javascriptcore-tests args...]
#   e.g.  bash AquaWebKitSupport/scripts/run-jsc-tests.sh
#         bash AquaWebKitSupport/scripts/run-jsc-tests.sh --testmasm --testb3
#         bash AquaWebKitSupport/scripts/run-jsc-tests.sh --jsc-stress --filter='^stress/array-'
#
# With no arguments it runs this port's JSC suite: upstream's test binaries and stress collections, the
# collections in run-jsc-stress-tests' --quick mode set (--no-quick runs every mode). testapi is outside
# the suite: its Objective-C tests exercise JSScript, bytecode-cache and module-loader API that no 10.9
# client uses. Tests are selected by upstream's own conditions (`//@ skip if ...`, the yaml collections)
# and each runs once. The stress results land in $AQUAWEBKIT_JSC_TEST_DIR/Release/jsc-stress-results,
# outside the checkout (default: the per-user temporary directory).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="$ROOT/WebKitBuild/Release"
TEST_BINARIES="jsc testmasm testair testb3 testdfg testwasmdebugger"

for BINARY in $TEST_BINARIES; do
    if [ ! -x "$BUILD/bin/$BINARY" ]; then
        echo "$BINARY not built — run AquaWebKitSupport/build.sh" >&2
        exit 1
    fi
done
. "$ROOT/AquaWebKitSupport/scripts/cctools.sh"

# At most 2 parallel test processes: the VM's 4 cores are shared with builds and Safari.
CHILD_PROCESSES=2
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --child-processes=*) CHILD_PROCESSES="${1#*=}" ;;
        --child-processes) CHILD_PROCESSES="${2-}"; shift ;;
        *) ARGS+=("$1") ;;
    esac
    shift
done
if ! [ "$CHILD_PROCESSES" -ge 1 ] 2>/dev/null || [ "$CHILD_PROCESSES" -gt 2 ]; then
    echo "ERROR: --child-processes=$CHILD_PROCESSES refused — use 1 or 2." >&2
    exit 1
fi

# run-javascriptcore-tests takes --root as an Apple product directory, where the executables sit
# beside JavaScriptCore.framework (the layout OptionsCocoa.cmake builds). This port builds them into
# bin/ and lib/, so the root holds copies of both, which also keeps a run on one build while later
# builds relink the tree. The stress runner finds the framework beside jsc only when that directory
# is named for its configuration.
PRODUCTS="${AQUAWEBKIT_JSC_TEST_DIR:-$(getconf DARWIN_USER_TEMP_DIR)AquaWebKitJSCTests}/Release"
mkdir -p "$PRODUCTS" || exit 1
PRODUCTS="$(cd "$PRODUCTS" && pwd -P)" || exit 1

# Every process a run starts carries AQUAWEBKIT_JSC_TEST_RUN=<the root> in its environment, inherited
# through the runners, their make and its test scripts. The reap stops this script's descendants and
# every process of this user whose environment carries that entry, then kills them all. Each one is
# stopped before more are looked for, so none forks past the walk. That covers what a killed earlier
# run left behind, whose make, test scripts and jsc outlive its runners. The listing runs without the
# entry, so its own ps and awk are not among the processes it finds.
export AQUAWEBKIT_JSC_TEST_RUN="$PRODUCTS"
stop_process() { # pid
    case " $STOPPED " in *" $1 "*) return 1;; esac
    kill -STOP "$1" 2>/dev/null
    STOPPED="$STOPPED $1"
}
stop_descendants() { # pid
    local child
    for child in $(pgrep -P "$1"); do
        stop_process "$child"
        stop_descendants "$child"
    done
}
# ps -E appends a process's environment to its arguments; the part past what plain ps prints for the
# same pid is the environment, and only an entry there counts.
run_processes() {
    (
        unset AQUAWEBKIT_JSC_TEST_RUN
        awk -v self=$$ -v uid="$(id -u)" -v entry=" AQUAWEBKIT_JSC_TEST_RUN=$PRODUCTS " '
            { line = $0; sub(/^ +/, "", line) }
            FNR == NR { argvLength[$1] = length(line); next }
            $1 != self && $2 == uid && ($1 in argvLength) &&
                index(substr(line, argvLength[$1] + 1) " ", entry) { print $1 }
        ' <(ps -wwx -o pid=,uid=,command=) <(ps -wwEx -o pid=,uid=,command=)
    )
}
reap_test_orphans() {
    local pid found
    STOPPED=""
    stop_descendants $$
    found=1
    while [ -n "$found" ]; do
        found=""
        for pid in $(run_processes); do
            stop_process "$pid" && found=1
        done
    done
    [ -n "$STOPPED" ] && kill -9 $STOPPED 2>/dev/null
    return 0
}
# The reap is machine-wide and the root is shared, so a run holds the lock the other test runners take.
# A signal ends the run, and the EXIT trap alone reaps and releases the lock.
. "$ROOT/AquaWebKitSupport/scripts/test-run-lock.sh"
trap 'exit 130' INT
trap 'exit 143' TERM
acquire_test_run_lock
cleanup() {
    reap_test_orphans
    release_test_run_lock
    return 0
}
trap cleanup EXIT
reap_test_orphans

rm -rf "$PRODUCTS/JavaScriptCore.framework" || exit 1
cp -Rp "$BUILD/lib/JavaScriptCore.framework" "$PRODUCTS/" || exit 1
for BINARY in $TEST_BINARIES; do
    cp -p "$BUILD/bin/$BINARY" "$PRODUCTS/$BINARY" || exit 1
done

PRODUCT_MACHOS="$PRODUCTS/JavaScriptCore.framework/Versions/A/JavaScriptCore"
for BINARY in $TEST_BINARIES; do PRODUCT_MACHOS="$PRODUCT_MACHOS $PRODUCTS/$BINARY"; done
if ! bash "$ROOT/AquaWebKitSupport/scripts/make-build-binaries-runnable.sh" $PRODUCT_MACHOS; then
    echo "ERROR: could not make the build products loadable" >&2
    exit 1
fi

# run-jsc-stress-tests runs on `/usr/bin/env ruby`; WebKit's Ruby scripts run on the toolchain's.
export PATH="$ROOT/AquaWebKitSupport/toolchain/build/ruby/bin:$PATH"
export AQUAWEBKIT_LIPO="$CCTOOLS/lipo"
export RUN_JAVASCRIPTCORE_TESTS_TESTAPI=false

# --no-fail-fast is upstream's tester configuration (build-webkit-org RunJavaScriptCoreTests);
# --quick bounds the mode matrix to what this VM's compute affords;
# --no-retry gives every test exactly one run; --no-copy runs the root's copies in place.
# --child-processes comes last, so no abbreviation of it among the passed arguments overrides it.
# The runner runs in the background so a signal to this script reaches the trap without waiting for it.
/usr/bin/perl -I"$ROOT/Tools/Scripts" -I"$ROOT/AquaWebKitSupport/scripts" -MToolchainLipo \
    "$ROOT/Tools/Scripts/run-javascriptcore-tests" \
    --root="$PRODUCTS" --release --no-build --no-copy --no-fail-fast --no-retry --quick \
    ${ARGS[@]+"${ARGS[@]}"} --child-processes="$CHILD_PROCESSES" &
wait $!
