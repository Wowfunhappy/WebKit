# Sourced by test-run-lock.sh, products-lock.sh and deps/build_deps.sh.
#
# A lock is a flock(2) on a file, taken through a descriptor the shell keeps open. The kernel
# drops it when the holder unlocks or when the last descriptor sharing it closes, so a holder that dies
# releases it. Bash has no flock builtin; the system perl takes and drops it on the shell's descriptor.
# A child that can outlive its parent is started with the descriptor closed (<fd>>&-), so it never
# keeps the parent's lock.

# fd_lock <fd> <file> try|wait [shared]: opens <file> on <fd> and locks it, exclusively or shared with
# other shared holders. try fails at once while a conflicting lock is held; wait blocks until it is
# free, in a background perl the shell waits on, so a trapped signal still ends the caller.
# FD_LOCK_WAITER is that perl while it waits; a caller's exit path stops it (fd_lock_stop_waiter), or
# it would take and drop the lock after the caller is gone.
FD_LOCK_WAITER=""
fd_lock() {
    local fd="$1" file="$2" mode="$3" kind=LOCK_EX status
    [ "${4:-}" = shared ] && kind=LOCK_SH
    mkdir -p "$(dirname "$file")" || return 2
    # Read-only, so a lock file another user (a run under sudo) created opens all the same.
    [ -e "$file" ] || : >> "$file" || return 2
    eval "exec $fd<\"\$file\"" || return 2
    if [ "$mode" = try ]; then
        /usr/bin/perl -MFcntl=:flock -e 'open(my $f, "<&=", $ARGV[0]) or exit 2; exit(flock($f, '"$kind"' | LOCK_NB) ? 0 : 1)' "$fd"
        status=$?
    else
        /usr/bin/perl -MFcntl=:flock -e 'open(my $f, "<&=", $ARGV[0]) or exit 2; exit(flock($f, '"$kind"') ? 0 : 1)' "$fd" &
        FD_LOCK_WAITER=$!
        wait "$FD_LOCK_WAITER"
        status=$?
        FD_LOCK_WAITER=""
    fi
    [ $status -eq 0 ] || eval "exec $fd>&-"
    return $status
}

fd_lock_stop_waiter() {
    [ -n "$FD_LOCK_WAITER" ] && kill "$FD_LOCK_WAITER" 2>/dev/null
    FD_LOCK_WAITER=""
    return 0
}

# fd_unlock <fd>: drops the lock held through <fd> and closes it.
fd_unlock() {
    /usr/bin/perl -MFcntl=:flock -e 'open(my $f, "<&=", $ARGV[0]) or exit; flock($f, LOCK_UN)' "$1" 2>/dev/null
    eval "exec $1>&-"
    return 0
}
