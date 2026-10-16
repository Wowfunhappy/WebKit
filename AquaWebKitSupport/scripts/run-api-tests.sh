#!/bin/bash
# Run a TestWebKitAPI binary against the build's frameworks on macOS 10.9, without installing
# anything over the system.
#
# The binaries are part of every build.sh run (ENABLE_API_TESTS is a port default in
# AquaWebKitSupport/cmake/OptionsMacAquaWebKit.cmake), so a green build has them matched to its frameworks.
# A run's binaries, frameworks and WebKit2 XPC services are a copy of the last build finished in
# WebKitBuild/Release (test-products-snapshot.sh), so builds during the run leave it alone. The run
# names the build it tests when it starts and in its last line; test processes run without the
# test-run lock's descriptor, so none that outlives the run keeps it.
#
# Usage:  bash AquaWebKitSupport/scripts/run-api-tests.sh [<binary> [gtest args...]]
#   e.g.  bash AquaWebKitSupport/scripts/run-api-tests.sh
#         bash AquaWebKitSupport/scripts/run-api-tests.sh TestWebKitAPI --gtest_filter='WKHTTPCookieStore.*'
#         bash AquaWebKitSupport/scripts/run-api-tests.sh TestWTF --gtest_list_tests
#
# With no binary it runs this port's API test binaries. Expectations are upstream's TestExpectations/apitests
# and this port's TestExpectations/platform/mac-mavericks/apitests (api-test-expectations.py reads them);
# tests expected to fail or to be flaky are skipped, every executed test must pass, and none is retried.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PYTHON="$ROOT/AquaWebKitSupport/toolchain/build/python3/bin/python3"
# This port's API test binaries, as each upstream port names its own (webkitpy's API_TEST_BINARY_NAMES).
PORT_API_TEST_BINARIES="TestWTF TestWebCore TestWebKitAPI"

if [ $# -eq 0 ] || [ "${1#-}" != "$1" ]; then
    BINARIES="$PORT_API_TEST_BINARIES"
else
    BINARIES="$1"; shift
fi

# An aborted run orphans its test processes (killing the runner does not reach grandchildren),
# and an orphan parked on a GL-retrying page spams "CoreAnimation: failed to create OpenGL context"
# until 10.9's WindowServer hits its null-texture compositor race and takes the login session down.
reap_test_orphans() {
    # Anchored at argv[0]: an unanchored pattern also matches helpers that merely carry a binary's
    # path in their arguments, and reaping one of those kills the run's own setup step.
    # Its own loop variable: this runs at the end of every inner iteration, and $BINARY is the outer
    # loop's, so reusing it here would leave the next test running out of the last-reaped binary.
    local reapBinary
    for reapBinary in $BINARIES; do
        pkill -9 -f "^$TEST_PRODUCTS/bin/$reapBinary" 2>/dev/null
    done
    # The copy's WebKit services. launchd starts an XPC service with its bare name as argv[0], so a
    # service is known by the executable lsof reports for it.
    local servicePid
    for servicePid in $(pgrep -f '^com\.apple\.WebKit\.(WebContent|Networking)'); do
        case "$(lsof -a -p "$servicePid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)" in
            "$TEST_PRODUCTS/"*) kill -9 "$servicePid" 2>/dev/null;;
        esac
    done
    return 0
}
# The reap above is machine-wide, so it runs only under the lock run-layout-tests.sh takes as well. A signal
# ends the run, and the EXIT trap alone reaps and releases the lock.
. "$ROOT/AquaWebKitSupport/scripts/test-run-lock.sh"
. "$ROOT/AquaWebKitSupport/scripts/test-products-snapshot.sh"
trap 'exit 130' INT
trap 'exit 143' TERM
acquire_test_run_lock
# The test binaries run in this run's own working directory, where a test's relative paths land (one creates
# and deletes resources/ and otherVolume.dmg there), never in the source tree.
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/wk_api_run.XXXXXX")
cd "$WORK_DIR" || exit 1
EXPECTATION_TABLE=""
cleanup() {
    reap_test_orphans
    release_products_lock
    release_test_run_lock
    rm -rf "$WORK_DIR"
    [ -n "$EXPECTATION_TABLE" ] && rm -f "$EXPECTATION_TABLE"
    tested_build_report
    return 0
}
trap cleanup EXIT
reap_test_orphans

if ! snapshot_test_products; then
    echo "ERROR: could not snapshot the build products" >&2
    exit 1
fi
tested_build_report
BINDIR="$TEST_PRODUCTS/bin"
for BINARY in $BINARIES; do
    if [ ! -x "$BINDIR/$BINARY" ]; then
        echo "$BINARY is not in the copy — run AquaWebKitSupport/build.sh" >&2
        exit 1
    fi
done

# The test binaries link Quartz, which transitively loads the SYSTEM (installed-backport) WebKit stack.
# Without a substitution dyld makes a second image of every framework the build tree also provides, and
# the duplicates register the same ObjC classes twice and split the private GStreamer runtime's GObject
# type system. Naming the snapshot's framework directory gives dyld the substitution, so exactly one
# image of each loads.
export DYLD_FRAMEWORK_PATH="$TEST_PRODUCTS/lib${DYLD_FRAMEWORK_PATH:+:$DYLD_FRAMEWORK_PATH}"
export __XPC_DYLD_FRAMEWORK_PATH="$DYLD_FRAMEWORK_PATH"

# Match webkitpy.port.base.Port.setup_environ_for_server: DateMath and other
# API tests use Pacific time, independently of the machine's time zone.
export TZ=US/Pacific

# Enumeration answers in one process; execution applies expectations below.
for arg in "$@"; do
    case "$arg" in
        --gtest_list_tests)
            for BINARY in $BINARIES; do "$BINDIR/$BINARY" "$@" 9>&- || exit $?; done
            exit 0
            ;;
    esac
done

# One process per test, the way Tools/Scripts/run-api-tests runs them (webkitpy/api_tests/runner.py,
# _run_single_test). Tests share a persistent website data store, so a cookie, a database or a cache one
# test leaves behind decides the next one's result when they run together.
# The filter selects which tests run; each run below names one test, so it is not forwarded.
GTEST_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --gtest_filter=*) ;;
        *) GTEST_ARGS+=("$arg") ;;
    esac
done

# A test that never finishes is reported, not waited on. WK_API_TEST_TIMEOUT is the per-test budget in
# seconds, the way Tools/Scripts/run-api-tests takes --timeout.
TEST_TIMEOUT=${WK_API_TEST_TIMEOUT:-180}

EXPECTATION_TABLE=$(mktemp "${TMPDIR:-/tmp}/wk_api_expectations.XXXXXX")
expectation_for() { # binary test -> Skip | Pass
    awk -F '\t' -v name="$1.$2" '$1 == name { print $2; exit }' "$EXPECTATION_TABLE"
}

EXPECTED=0
UNEXPECTED=0
SKIPPED=0
UNEXPECTED_NAMES=""
for BINARY in $BINARIES; do
    if ! TESTS=$("$BINDIR/$BINARY" --gtest_list_tests "$@" 9>&- |
        awk -f "$ROOT/AquaWebKitSupport/scripts/parse-api-test-list.awk"); then
        echo "$BINARY: failed to enumerate tests" >&2
        exit 1
    fi
    if [ -z "$TESTS" ]; then
        echo "$BINARY: no tests matched" >&2
        exit 1
    fi
    if ! printf '%s\n' $TESTS | sed "s/^/$BINARY./" | "$PYTHON" "$ROOT/AquaWebKitSupport/scripts/api-test-expectations.py" > "$EXPECTATION_TABLE"; then
        echo "$BINARY: failed to read the API test expectations" >&2
        exit 1
    fi
    for TEST in $TESTS; do
        EXPECTATION=$(expectation_for "$BINARY" "$TEST")
        if [ "$EXPECTATION" = "Skip" ]; then
            SKIPPED=$((SKIPPED + 1))
            continue
        fi
        OUT_FILE=$(mktemp "${TMPDIR:-/tmp}/wk_api_test.XXXXXX")
        "$ROOT/AquaWebKitSupport/toolchain/build/python3/bin/python3" \
            "$ROOT/AquaWebKitSupport/scripts/run-api-test-with-timeout.py" --timeout "$TEST_TIMEOUT" \
            "$BINDIR/$BINARY" --gtest_filter="$TEST" ${GTEST_ARGS[@]+"${GTEST_ARGS[@]}"} > "$OUT_FILE" 2>&1 9>&-
        STATUS=$?
        OUTPUT=$(cat "$OUT_FILE")
        rm -f "$OUT_FILE"
        if [ $STATUS -eq 0 ] && printf '%s' "$OUTPUT" | grep -qxF "**PASS** $TEST"; then
            RESULT=Pass
        else
            RESULT=Failure
        fi
        if [ "$RESULT" = "$EXPECTATION" ]; then
            EXPECTED=$((EXPECTED + 1))
            echo "**$RESULT** $BINARY $TEST"
        else
            UNEXPECTED=$((UNEXPECTED + 1))
            UNEXPECTED_NAMES="$UNEXPECTED_NAMES $BINARY:$TEST:$RESULT"
            echo "**$RESULT** $BINARY $TEST (expected $EXPECTATION)"
            [ "$RESULT" = "Failure" ] && printf '%s\n' "$OUTPUT" | sed 's/^/    /'
        fi
        reap_test_orphans
    done
done

echo
echo "Ran $((EXPECTED + UNEXPECTED)) tests ($SKIPPED skipped): $EXPECTED as expected, $UNEXPECTED unexpected"
if [ $UNEXPECTED -gt 0 ]; then
    echo "Unexpected:"
    for NAME in $UNEXPECTED_NAMES; do echo "  ${NAME%:*} -> ${NAME##*:}"; done
    exit 1
fi
exit 0
