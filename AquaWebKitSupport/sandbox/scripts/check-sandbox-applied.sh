#!/bin/bash
# check-sandbox-applied.sh — prove the running child processes are actually confined.
#
# "Safari still works" is not evidence of a sandbox; neither is a profile that compiles. The only
# thing that settles it is asking the kernel about the live processes, which is what sandbox_check()
# does. Run this with Safari open on a page.
#
# Reports every WebContent / Networking / GPU / webpushd process it finds, and fails if any of them is
# unconfined or answers "permitted" to something its profile must deny.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/check-sandbox-applied.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

if ! /usr/bin/clang -o "$WORK/sbstatus" "$HERE/sbstatus.c"; then
    echo "ERROR: could not build the sandbox status harness" >&2
    exit 2
fi

# The child processes, by the basename of the executable path `ps -Ao comm=` reports, so the
# script's own shells and `ps` never match.
pidsForProcess() # $1 = exact executable basename, also matched with a ".<variant>" suffix
{
    ps -Ao pid=,comm= | while read -r pid command; do
        case "${command##*/}" in "$1"|"$1".*) printf '%s ' "$pid";; esac
    done
}

status=0
found=0
for entry in com.apple.WebKit.WebContent:webcontent com.apple.WebKit.Networking:networking com.apple.WebKit.GPU:gpu webpushd:webpushd; do
    process="${entry%%:*}"
    pids="$(pidsForProcess "$process")"
    if [ -z "$pids" ]; then
        echo "== $process: not running"
        continue
    fi
    found=1
    echo "== $process"
    # shellcheck disable=SC2086
    "$WORK/sbstatus" "${entry##*:}" $pids || status=1
done

if [ "$found" = 0 ]; then
    echo "No WebKit child processes are running — open a page in Safari first." >&2
    exit 2
fi
exit $status
