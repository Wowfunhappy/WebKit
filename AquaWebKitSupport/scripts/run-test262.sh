#!/bin/bash
# Run test262 (Tools/Scripts/test262-runner over JSTests/test262) against the build-dir jsc on macOS 10.9,
# without installing anything over the system.
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
# its results (results.yaml, summary.txt, index.html) to $AQUAWEBKIT_TEST262_DIR/test262-results, outside
# the checkout (default: the per-user temporary directory); --stats and --failing-files read the last run's
# results from there. --save, which rewrites the checked-in expectations, is refused.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="$ROOT/WebKitBuild/Release"

if [ ! -x "$BUILD/bin/jsc" ] || [ ! -d "$BUILD/lib/JavaScriptCore.framework" ]; then
    echo "jsc not built — run AquaWebKitSupport/build.sh" >&2
    exit 1
fi

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

# The runner sets DYLD_FRAMEWORK_PATH to the directory holding the jsc it is given, so the products
# directory holds copies of jsc and JavaScriptCore.framework side by side. The copies also keep a run on
# one build while later builds relink the tree. The runner writes its results under $PWD.
PRODUCTS="${AQUAWEBKIT_TEST262_DIR:-$(getconf DARWIN_USER_TEMP_DIR)AquaWebKitTest262}"
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
# make-build-binaries-runnable.sh rewrites the build tree the other test runners run from, so a run holds
# the lock they take. A signal ends the run, and the EXIT trap alone reaps and releases the lock.
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
cp -p "$BUILD/bin/jsc" "$PRODUCTS/jsc" || exit 1
if ! bash "$ROOT/AquaWebKitSupport/scripts/make-build-binaries-runnable.sh" \
        "$PRODUCTS/JavaScriptCore.framework/Versions/A/JavaScriptCore" "$PRODUCTS/jsc"; then
    echo "ERROR: could not make the build products loadable" >&2
    exit 1
fi

# The runner loads its YAML and Parallel::ForkManager from its bundled Tools/Scripts/test262/local.
# --jsc and --child-processes come last, so no abbreviation of them among the passed arguments overrides
# them. The runner runs in the background so a signal to this script reaches the trap without waiting for it.
cd "$PRODUCTS" || exit 1
PWD="$PRODUCTS" /usr/bin/perl "$ROOT/Tools/Scripts/test262-runner" \
    ${ARGS[@]+"${ARGS[@]}"} --jsc="$PRODUCTS/jsc" --child-processes="$CHILD_PROCESSES" &
wait $!
