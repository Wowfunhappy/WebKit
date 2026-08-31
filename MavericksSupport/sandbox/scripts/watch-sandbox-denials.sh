#!/bin/bash
# watch-sandbox-denials.sh — show what the sandbox is actually denying WebKit's child processes.
#
# Denials are the only honest source for what a profile still needs to grant. Run this, drive the
# browser through the feature that misbehaves, and read what was denied; then grant exactly that in
# the matching profile under MavericksSupport/sandbox/.
#
# 10.9 reports denials two ways and both matter: the kernel logs the enforcement itself, and
# sandboxd logs a symbolicated report with the stack that tripped it. Both land in
# /var/log/system.log.
#
#   watch-sandbox-denials.sh            follow new denials until interrupted
#   watch-sandbox-denials.sh --since    print the denials already in the log, then follow
set -u

LOG=/var/log/system.log
# The child processes this port sandboxes. webpushd's profile is applied by its own applySandbox().
# 10.9's kernel and sandboxd log both XPC services under the TRUNCATED process name
# "com.apple.WebKit" (not WebContent/Networking), so that name must be in the process filter or
# every kernel-logged denial from the two services is silently dropped.
FILTER='deny |Sandbox: |sandboxd'
PROCESSES='com\.apple\.WebKit|WebContent|Networking|WebProcess|NetworkProcess|webpushd'

if [ ! -r "$LOG" ]; then
    echo "ERROR: cannot read $LOG (try: sudo $0)" >&2
    exit 1
fi

if [ "${1:-}" = "--since" ]; then
    echo "=== denials already in $LOG ==="
    grep -E "$FILTER" "$LOG" | grep -E "$PROCESSES" || echo "(none)"
    echo
fi

echo "=== following $LOG for new denials (ctrl-C to stop) ==="
tail -F -n 0 "$LOG" | grep -E --line-buffered "$FILTER" | grep -E --line-buffered "$PROCESSES"
