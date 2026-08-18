# Bounded-parallel compile queue, sourced by the polyfill build scripts.
#
# Each compile here writes its own object and reads nobody else's, so the only ordering that matters
# is that a batch has finished before something archives or links its objects -- which is what
# cc_wait marks. Diagnostics are captured per compile and replayed in queue order, so each unit's
# warnings arrive together, under the source file they came from.
#
# Set CC_LOGDIR to a writable directory before the first cc_queue call.
CC_JOBS=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
CC_PIDS=""; CC_LOGS=""; CC_RC=0; CC_N=0

_cc_reap() {  # oldest queued compile first
    local pid; set -- $CC_PIDS; pid="$1"; shift; CC_PIDS="$*"
    wait "$pid" || CC_RC=1
}

cc_queue() {  # queue one compile
    while [ "$(set -- $CC_PIDS; echo $#)" -ge "$CC_JOBS" ]; do _cc_reap; done
    local log="$CC_LOGDIR/cc.$CC_N.log"; CC_N=$((CC_N + 1)); CC_LOGS="$CC_LOGS $log"
    "$@" > "$log" 2>&1 &
    CC_PIDS="$CC_PIDS $!"
}

cc_wait() {  # the queue must be empty, and every compile in it must have succeeded
    local log
    while [ -n "$CC_PIDS" ]; do _cc_reap; done
    for log in $CC_LOGS; do if [ -s "$log" ]; then cat "$log"; fi; done
    CC_LOGS=""
    if [ "$CC_RC" != 0 ]; then
        echo "### a compile failed (see the diagnostics above)" >&2
        exit 1
    fi
}
