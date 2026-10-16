# Sourced by run-layout-tests.sh, run-api-tests.sh, run-jsc-tests.sh, run-test262.sh,
# tests/cocoa-curl/run.sh, tests/image-decoders/incremental-video-image.sh and
# tests/cdm-proxy-key-system/run.sh, which set ROOT.
#
# One test run at a time: each runner reaps its drivers and services machine-wide, the layout runner's
# http/wpt servers own fixed ports, and the products copy (test-products-snapshot.sh) and results
# directories are shared, so a second invocation waits for the first to finish. The lock is an
# fd-lock.sh lock on descriptor 9, which a runner closes for every child that can outlive it.
. "$ROOT/AquaWebKitSupport/scripts/fd-lock.sh"
TEST_RUN_LOCK="$ROOT/WebKitBuild/.test-run.lock"
TEST_RUN_LOCK_HELD=""

acquire_test_run_lock() {
    if ! fd_lock 9 "$TEST_RUN_LOCK" try; then
        echo "waiting: another test run holds $TEST_RUN_LOCK" >&2
        fd_lock 9 "$TEST_RUN_LOCK" wait || exit 1
    fi
    TEST_RUN_LOCK_HELD=1
}

# Only the run that took the lock releases it; one still waiting for it stops waiting.
release_test_run_lock() {
    fd_lock_stop_waiter
    [ -n "$TEST_RUN_LOCK_HELD" ] && fd_unlock 9
    TEST_RUN_LOCK_HELD=""
    return 0
}
