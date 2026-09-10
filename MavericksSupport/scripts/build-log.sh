#!/bin/bash
# build-log.sh — SOURCED, never executed.
#
# /tmp/wk_build.log is the one build log: every script here that compiles or links appends to it.
# build_log_open points the sourcing script's output there and keeps its terminal on fd 3;
# build_log_report sends the slice of the log this run wrote back to that terminal when the script
# exits nonzero. build_log_open installs it as the EXIT trap; a script that later sets a cleanup
# trap of its own calls it from there. The report travels with the script, so it reads the same
# whether the script was invoked by a bootstrap, by build.sh, or by hand.

LOG=/tmp/wk_build.log

build_log_open() {
    exec 3>&2 >> "$LOG" 2>&1
    _BUILD_LOG_START="$(/usr/bin/stat -f%z "$LOG" 2>/dev/null || echo 0)"
    trap 'build_log_report $?' EXIT
}

# build_log_report <exit status>
build_log_report() {
    local rc="${1:-0}" size
    [ "$rc" -eq 0 ] && return 0
    [ -n "${_BUILD_LOG_START:-}" ] || return 0
    size="$(/usr/bin/stat -f%z "$LOG" 2>/dev/null || echo 0)"
    # build.sh truncates the log once per run; a start offset past the end reads as the whole file.
    [ "$size" -lt "$_BUILD_LOG_START" ] && _BUILD_LOG_START=0
    {   echo "FATAL: $(basename "$0") exited $rc; its output in $LOG:"
        tail -c "+$((_BUILD_LOG_START + 1))" "$LOG" | tail -30
    } >&3
    return 0
}
