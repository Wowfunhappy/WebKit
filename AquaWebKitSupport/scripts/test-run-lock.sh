# Sourced by run-layout-tests.sh, run-api-tests.sh, run-jsc-tests.sh and run-test262.sh, which set ROOT.
#
# One test run at a time: each runner reaps the build tree's drivers and services machine-wide, the layout
# runner's http/wpt servers own fixed ports, and its results directory is shared, so a second invocation
# waits for the first to finish. The lock is a directory (bash 3.2 has no flock) holding the owner's pid,
# and is stale once that pid is gone; ps answers that for a root-owned run started under sudo as well as
# for our own.
TEST_RUN_LOCK="$ROOT/WebKitBuild/Release/bin/.run-layout-tests.lock"

acquire_test_run_lock() {
    local owner
    until mkdir "$TEST_RUN_LOCK" 2>/dev/null; do
        owner=$(cat "$TEST_RUN_LOCK/pid" 2>/dev/null)
        if [ -n "$owner" ] && ! ps -p "$owner" >/dev/null 2>&1; then
            if rm -rf "$TEST_RUN_LOCK" 2>/dev/null; then
                continue
            fi
            echo "stale lock owned by pid $owner cannot be removed (try: sudo rm -rf $TEST_RUN_LOCK)" >&2
        else
            echo "waiting: another test run (pid ${owner:-?}) is running" >&2
        fi
        sleep 15
    done
    echo $$ > "$TEST_RUN_LOCK/pid"
}

# Only the run that holds the lock releases it.
release_test_run_lock() {
    [ "$(cat "$TEST_RUN_LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$TEST_RUN_LOCK"
    return 0
}
