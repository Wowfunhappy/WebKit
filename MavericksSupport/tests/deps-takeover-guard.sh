#!/bin/bash
# Check dependency publication's distinction between waiters and active consumers.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && /bin/pwd -P)"
SCRIPT="${1:-$ROOT/MavericksSupport/deps/build_deps.sh}"
WORK=$(mktemp -d /tmp/webkit-deps-takeover-test.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
mkdir -p "$REPO/MavericksSupport" "$REPO/WebKitBuild/Release/.takeover-waiters"
REPO="$(cd "$REPO" && /bin/pwd -P)"
WEBKIT_BUILD="$REPO/MavericksSupport/build.sh"
DEST="$REPO/MavericksSupport/deps/build"
ps() {
    case "$*" in
        '-axo pid=,command=')
            printf '123 bash %s\n' "$WEBKIT_BUILD"
            if [ -n "${EXTRA_CONSUMER:-}" ]; then printf '124 bash %s\n' "$WEBKIT_BUILD"; fi
            ;;
        '-o command= -p 123'|'-o command= -p 124') printf 'bash %s\n' "$WEBKIT_BUILD" ;;
        '-o lstart= -p 123'|'-o lstart= -p 124') printf '%s\n' 'Sun Sep 13 21:00:00 2026' ;;
        '-o ppid= -p 123') echo 1 ;;
        '-o ppid= -p 124') echo "${WAITER_PARENT:-1}" ;;
        *) return 1 ;;
    esac
}
eval "$(sed -n '/^_webkit_build_pids() {/,/^}/p' "$SCRIPT")"
eval "$(sed -n '/^_refuse_under_webkit_build() {/,/^}/p' "$SCRIPT")"
unset WK_BUILD_AWAITING_DEPS
expect_blocked() {
    if (_refuse_under_webkit_build) > "$WORK/output" 2>&1; then
        echo 'FAIL active consumer was accepted' >&2
        exit 1
    fi
    if ! grep -q 'FATAL: a WebKit build is running' "$WORK/output"; then
        cat "$WORK/output" >&2
        exit 1
    fi
}
expect_blocked
echo 'PASS active build blocks publication'
ps -o lstart= -p 123 > "$REPO/WebKitBuild/Release/.takeover-waiters/123"
_refuse_under_webkit_build
echo 'PASS takeover waiter permits publication'
EXTRA_CONSUMER=1
expect_blocked
WAITER_PARENT=123
_refuse_under_webkit_build
unset WAITER_PARENT
echo 'PASS a verified waiter shell helper permits publication'
unset EXTRA_CONSUMER
echo 'PASS another active consumer blocks publication alongside a waiter'
printf '%s\n' 'different process start time' > "$REPO/WebKitBuild/Release/.takeover-waiters/123"
expect_blocked
echo 'PASS stale PID marker still blocks publication'
rm "$REPO/WebKitBuild/Release/.takeover-waiters/123"
expect_blocked
echo 'PASS resumed build blocks publication'
WK_BUILD_AWAITING_DEPS=123 _refuse_under_webkit_build
echo 'PASS synchronous dependency owner permits publication'

BUILD_SCRIPT="${2:-$ROOT/MavericksSupport/build.sh}"
CLEANUP=$(sed -n '/^trap .*TAKEOVER_MARKER/p' "$BUILD_SCRIPT")
[ -n "$CLEANUP" ]
if (
    TAKEOVER_MARKER="$WORK/marker"
    touch "$TAKEOVER_MARKER"
    build_log_report() { printf '%s\n' "$1" > "$WORK/report-status"; }
    eval "$CLEANUP"
    exit 7
); then
    echo 'FAIL cleanup changed the failing exit status' >&2
    exit 1
else
    [ "$?" -eq 7 ]
fi
[ ! -e "$WORK/marker" ]
[ "$(cat "$WORK/report-status")" = 7 ]
echo 'PASS waiter cleanup preserves failure reporting and exit status'
