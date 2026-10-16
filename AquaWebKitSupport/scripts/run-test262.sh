#!/bin/bash
# Run test262 (Tools/Scripts/test262-runner over JSTests/test262) against the build's jsc on macOS 10.9,
# without installing anything over the system. A run's jsc and JavaScriptCore.framework are a copy of
# the last build finished in WebKitBuild/Release (test-products-snapshot.sh), so builds during the run
# leave it alone.
#
# Usage:  bash AquaWebKitSupport/scripts/run-test262.sh [test262-runner args...]
#   e.g.  bash AquaWebKitSupport/scripts/run-test262.sh
#         bash AquaWebKitSupport/scripts/run-test262.sh --test-only test/intl402
#         bash AquaWebKitSupport/scripts/run-test262.sh -o test/built-ins/Temporal -o test/intl402/Temporal
#         bash AquaWebKitSupport/scripts/run-test262.sh --failing-files
#
# With no arguments it runs what upstream's runner runs by default: every test under JSTests/test262/test,
# filtered by JSTests/test262/config.yaml and judged against JSTests/test262/expectations.yaml. Only
# failures outside the expectations count, and the exit status is 1 when there is one. The runner writes
# its results (results.yaml, summary.txt, index.html) to $AQUAWEBKIT_TEST262_DIR/test262-results
# (default: WebKitBuild/Test262); --stats and --failing-files read the last run's results from there.
# --save, which rewrites the checked-in expectations, is refused. The run names the build it tests when
# it starts and in its last line.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# At most 2 parallel test processes: the VM's 4 cores are shared with builds and Safari.
CHILD_PROCESSES=2
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --child-processes=*|-p=*) CHILD_PROCESSES="${1#*=}" ;;
        --child-processes|-p) CHILD_PROCESSES="${2-}"; shift ;;
        *)
            # Getopt::Long matches case-insensitively and takes any unique abbreviation.
            case "$(echo "$1" | tr '[:upper:]' '[:lower:]')" in
                -sa|-sav|-save|--sa|--sav|--save)
                    echo "ERROR: $1 refused — it rewrites JSTests/test262/expectations.yaml." >&2
                    exit 1 ;;
            esac
            ARGS+=("$1") ;;
    esac
    shift
done
if ! [ "$CHILD_PROCESSES" -ge 1 ] 2>/dev/null || [ "$CHILD_PROCESSES" -gt 2 ]; then
    echo "ERROR: --child-processes=$CHILD_PROCESSES refused — use 1 or 2." >&2
    exit 1
fi

# The runner writes its results under $PWD, this directory.
PRODUCTS="${AQUAWEBKIT_TEST262_DIR:-$ROOT/WebKitBuild/Test262}"
mkdir -p "$PRODUCTS" || exit 1
PRODUCTS="$(cd "$PRODUCTS" && pwd -P)" || exit 1

# Every process a run starts carries AQUAWEBKIT_TEST262_RUN=<the products directory> in its environment,
# inherited through the runner, its forked children and their jsc. The reap stops this script's
# descendants and every process of this user whose environment carries that entry, then kills them all.
# Each one is stopped before more are looked for, so none forks past the walk. That covers what a killed
# earlier run left behind, whose children and jsc outlive its runner. The listing runs without the entry,
# so its own ps and awk are not among the processes it finds.
export AQUAWEBKIT_TEST262_RUN="$PRODUCTS"
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
        unset AQUAWEBKIT_TEST262_RUN
        awk -v self=$$ -v uid="$(id -u)" -v entry=" AQUAWEBKIT_TEST262_RUN=$PRODUCTS " '
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
# The reap is machine-wide and the snapshot is shared, so a run holds the lock the other test runners take.
# A signal ends the run, and the EXIT trap alone reaps and releases the locks.
. "$ROOT/AquaWebKitSupport/scripts/test-run-lock.sh"
. "$ROOT/AquaWebKitSupport/scripts/test-products-snapshot.sh"
trap 'exit 130' INT
trap 'exit 143' TERM
acquire_test_run_lock
cleanup() {
    reap_test_orphans
    release_products_lock
    release_test_run_lock
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
if [ ! -x "$TEST_PRODUCTS/bin/jsc" ] || [ ! -d "$TEST_PRODUCTS/lib/JavaScriptCore.framework" ]; then
    echo "jsc is not in the copy — run AquaWebKitSupport/build.sh" >&2
    exit 1
fi
# The runner keeps a DYLD_FRAMEWORK_PATH it is given, and otherwise names the directory holding jsc.
export DYLD_FRAMEWORK_PATH="$TEST_PRODUCTS/lib"

# The runner loads its YAML and Parallel::ForkManager from its bundled Tools/Scripts/test262/local.
# --jsc and --child-processes come last, so no abbreviation of them among the passed arguments overrides
# them. The runner runs in the background so a signal to this script reaches the trap without waiting for it,
# and without the test-run lock's descriptor, which its forked children would otherwise keep.
cd "$PRODUCTS" || exit 1
PWD="$PRODUCTS" /usr/bin/perl "$ROOT/Tools/Scripts/test262-runner" \
    ${ARGS[@]+"${ARGS[@]}"} --jsc="$TEST_PRODUCTS/bin/jsc" --child-processes="$CHILD_PROCESSES" 9>&- &
wait $!
