#!/bin/bash
# check-sandbox-applied.sh — prove the running child processes are actually confined.
#
# "Safari still works" is not evidence of a sandbox; neither is a profile that compiles. The only
# thing that settles it is asking the kernel about the live processes, which is what sandbox_check()
# does. Run this with Safari open on a page.
#
# Reports every WebContent / Networking / webpushd process it finds, and fails if any of them is
# unconfined or answers "permitted" to something its profile must deny.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/check-sandbox-applied.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

if ! /usr/bin/clang -o "$WORK/sbstatus" "$HERE/sbstatus.c"; then
    echo "ERROR: could not build the sandbox status harness" >&2
    exit 2
fi

# Find the child processes by EXACT executable name.
#
# Not `pgrep -f`: that matches against full command lines, so it also matches this script's own
# pgrep/subshell — whose command line contains the pattern — and those transient shell processes are
# of course unsandboxed. The result is a gate that intermittently reports "NOT SANDBOXED" for pids
# that are its own plumbing and exits nonzero on a perfectly confined system. A gate that fails green
# is a gate people learn to ignore. (`pgrep -x` is not the answer either: it matches a truncated
# accounting name and finds none of these.)
#
# `ps -Ao pid=,comm=` gives the executable path; comparing its basename exactly cannot match `ps`,
# `bash` or `grep`, so the script can never see itself.
pidsForProcess() # $1 = exact executable basename
{
    ps -Ao pid=,comm= | while read -r pid command; do
        [ "${command##*/}" = "$1" ] && printf '%s ' "$pid"
    done
}

status=0
found=0
for process in com.apple.WebKit.WebContent com.apple.WebKit.Networking webpushd; do
    pids="$(pidsForProcess "$process")"
    if [ -z "$pids" ]; then
        echo "== $process: not running"
        continue
    fi
    found=1
    echo "== $process"
    # shellcheck disable=SC2086
    "$WORK/sbstatus" $pids || status=1
done

if [ "$found" = 0 ]; then
    echo "No WebKit child processes are running — open a page in Safari first." >&2
    exit 2
fi
exit $status
