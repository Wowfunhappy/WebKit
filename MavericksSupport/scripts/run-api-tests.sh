#!/bin/bash
# Run a TestWebKitAPI binary against the build-dir frameworks on macOS 10.9, without installing
# anything over the system.
#
# The binaries are part of every build.sh run (ENABLE_API_TESTS is a port default in
# MavericksSupport/cmake/OptionsMacMavericks.cmake), so a green build has them matched to its frameworks.
#
# Usage:  bash MavericksSupport/scripts/run-api-tests.sh <binary> [gtest args...]
#         bash MavericksSupport/scripts/run-api-tests.sh --port-surface
#   e.g.  bash MavericksSupport/scripts/run-api-tests.sh TestWebKitAPI --gtest_filter='WKHTTPCookieStore.*'
#         bash MavericksSupport/scripts/run-api-tests.sh TestWTF --gtest_list_tests
#
# Expectations live in MavericksSupport/tests/port-surface/api-tests.txt: `run <binary>` names the
# binaries --port-surface runs in full, and `<binary> <Suite.Test> [ Skip ]` leaves a test out of every
# run. Every executed test must pass; unexpected failures make the run exit 1.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BINDIR="$ROOT/WebKitBuild/Release/bin"
EXPECTATIONS="$ROOT/MavericksSupport/tests/port-surface/api-tests.txt"

if [ $# -lt 1 ]; then
    echo "Usage: bash MavericksSupport/scripts/run-api-tests.sh <binary> [gtest args...] | --port-surface" >&2
    exit 2
fi
# `run <binary> [gtest filter]` lines: FILTER_<binary> carries the filter the binary is enumerated with.
if [ "$1" = "--port-surface" ]; then
    BINARIES=""
    while read -r _run binary filter; do
        BINARIES="$BINARIES $binary"
        [ -n "$filter" ] && eval "FILTER_$binary=\"--gtest_filter=$filter\""
    done < <(grep '^run[[:space:]]' "$EXPECTATIONS")
    shift
else
    BINARIES="$1"; shift
fi
for BINARY in $BINARIES; do
    if [ ! -x "$BINDIR/$BINARY" ]; then
        echo "$BINARY not built — run MavericksSupport/build.sh" >&2
        exit 1
    fi
done

# An aborted run orphans build-tree test processes (killing the runner does not reach grandchildren),
# and an orphan parked on a GL-retrying page spams "CoreAnimation: failed to create OpenGL context"
# until 10.9's WindowServer hits its null-texture compositor race and takes the login session down.
reap_test_orphans() {
    # Anchored at argv[0]: an unanchored pattern also matches helpers that merely carry a binary's
    # path in their arguments, and reaping one of those kills the run's own setup step.
    # Its own loop variable: this runs at the end of every inner iteration, and $BINARY is the outer
    # loop's, so reusing it here would leave the next test running out of the last-reaped binary.
    local reapBinary
    for reapBinary in $BINARIES; do
        pkill -9 -f "^$BINDIR/$reapBinary" 2>/dev/null
    done
    pkill -9 -f "WebKitBuild/Release/.*com\.apple\.WebKit\.(WebContent|Networking)" 2>/dev/null
    return 0
}
reap_test_orphans
trap reap_test_orphans EXIT INT TERM

BIN_PATHS=""
for BINARY in $BINARIES; do BIN_PATHS="$BIN_PATHS $BINDIR/$BINARY"; done
if ! bash "$ROOT/MavericksSupport/scripts/make-build-binaries-runnable.sh" $BIN_PATHS; then
    echo "ERROR: could not make the build products loadable" >&2
    exit 1
fi

# The test binaries link Quartz, which transitively loads the SYSTEM (installed-backport) WebKit stack.
# Without a substitution dyld makes a second image of every framework the build tree also provides, and
# the duplicates register the same ObjC classes twice and split the private GStreamer runtime's GObject
# type system. Naming the directory the build puts its frameworks in gives dyld the substitution, so
# exactly one image of each loads.
export DYLD_FRAMEWORK_PATH="$ROOT/WebKitBuild/Release/lib${DYLD_FRAMEWORK_PATH:+:$DYLD_FRAMEWORK_PATH}"
export __XPC_DYLD_FRAMEWORK_PATH="$DYLD_FRAMEWORK_PATH"

# Match webkitpy.port.base.Port.setup_environ_for_server: DateMath and other
# API tests use Pacific time, independently of the machine's time zone.
export TZ=US/Pacific

# Enumeration answers in one process; execution applies expectations below.
for arg in "$@"; do
    case "$arg" in
        --gtest_list_tests)
            for BINARY in $BINARIES; do "$BINDIR/$BINARY" "$@" || exit $?; done
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

expectation_for() { # binary test -> Skip | Pass
    local found
    found=$(awk -v binary="$1" -v test="$2" '
        $1 == binary && $2 == test && $3 == "[" { result = $4 }
        END { print result }' "$EXPECTATIONS")
    echo "${found:-Pass}"
}

EXPECTED=0
UNEXPECTED=0
SKIPPED=0
UNEXPECTED_NAMES=""
for BINARY in $BINARIES; do
    eval "FILTER=\${FILTER_$BINARY-}"
    if ! TESTS=$("$BINDIR/$BINARY" --gtest_list_tests ${FILTER:+"$FILTER"} "$@" |
        awk -f "$ROOT/MavericksSupport/scripts/parse-api-test-list.awk"); then
        echo "$BINARY: failed to enumerate tests" >&2
        exit 1
    fi
    if [ -z "$TESTS" ]; then
        echo "$BINARY: no tests matched" >&2
        exit 1
    fi
    for TEST in $TESTS; do
        EXPECTATION=$(expectation_for "$BINARY" "$TEST")
        if [ "$EXPECTATION" = "Skip" ]; then
            SKIPPED=$((SKIPPED + 1))
            continue
        fi
        OUT_FILE=$(mktemp "${TMPDIR:-/tmp}/wk_api_test.XXXXXX")
        "$ROOT/MavericksSupport/toolchain/build/python3/bin/python3" \
            "$ROOT/MavericksSupport/scripts/run-api-test-with-timeout.py" --timeout "$TEST_TIMEOUT" \
            "$BINDIR/$BINARY" --gtest_filter="$TEST" ${GTEST_ARGS[@]+"${GTEST_ARGS[@]}"} > "$OUT_FILE" 2>&1
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
