Run with an installed JavaScriptCore/GLib runtime and a configured build tree:

```sh
AquaWebKitSupport/toolchain/build/python3/bin/python3 AquaWebKitSupport/tests/glib-main-context/run.py
```

The runner compiles the GLib bridge, `MainThreadSharedTimerCF.cpp`, and the WTF RunLoop,
MainThread and Cocoa WorkQueue sources with WebCore's compile flags. It links the installed
JavaScriptCore, GLib and C++ runtime and the lock and libSystem objects from
`polyfill/build/libpolyfill.a`. Objects and the executable live in
`WebKitBuild/Release/glib-main-context/`. Compiler and linker commands and output append to
`/tmp/wk_build.log`; test results stream to stdout.

The main thread owns GLib's default context. Ready work posts one deduplicated message to the
bridge's own mach-port run-loop source. A run-loop pass performs one signaled version-0 source,
such as the RunLoop's, then handles one port message, so RunLoop functions queued by one GLib
iteration run before the next. Each message runs one context iteration and returns to the run
loop, so the run loop's observers run between two iterations; the bridge posts another message
while a GLib source is ready. RunLoop function-dispatch suspension holds only RunLoop functions:
a suspended batch runs a pass after the next GLib iteration.

GLib deadlines use one persistent main-thread `RunLoop::Timer`. Its outstanding fire time only
moves earlier while armed; its callback clears that time and requests an iteration. Entry to
an iteration stops the timer and clears its outstanding fire time. The helper polls descriptors
with an infinite timeout and requests ready work through the same deduplicated source.
The queued flag resets on entry to an iteration, and the helper is disarmed there.
Before-waiting and exit observers prepare main-thread sources.

The harness serves GLib's default context on the main CF/NSRunLoop and checks:

- Main-thread GLib timeouts fire between 100 and 160 ms, including with the descriptor helper blocked.
- A GLib idle dispatches within 1000 observer passes and 100 ms while a zero-delay CF timer reposts.
- A 20 ms GLib timeout fires between 20 and 40 ms while a zero-delay CF timer reposts with 15 ms of synchronous work per callout and the descriptor helper is blocked.
- Every descriptor-helper poll uses an infinite timeout.
- Chained main-thread idle sources advance without an outside wake-up, and repeating idles share the loop with CF timers.
- A CF source and a 2 ms CF timer run within 10 ms while RunLoop work reposts.
- Zero-delay WebCore shared and CF control timers fire within 10 ms while RunLoop or main WorkQueue work reposts. Eight combinations cover dispatch suspension and a blocked descriptor helper; reposting ends after 100 ms.
- A finite main WorkQueue chain completes across dispatch suspension alongside the shared timer.
- Registered private modes deliver the shared timer once, support registration after arming and cancellation, and leave common-mode RunLoop, callOnMainThread and GLib work pending until the loop returns to common modes.
- Waits run `-[NSRunLoop runMode:beforeDate:]` with a distant-future date, as `-[NSRunLoop run]` does in WebContent; a common-mode CF timer bounds them.
- Default-priority descriptor backlogs of 200 and 20 bytes and their RunLoop callbacks finish within 500 ms, in FIFO order, including suspended dispatch.
- A custom GSource holds 200 queued messages at `RunLoopDispatcher` priority and dispatches one item per call, matching a bus watch. The messages and their RunLoop callbacks complete within 500 ms, an Exit or BeforeWaiting rendering observer runs between every two messages, and each message's RunLoop callback completes in FIFO order before the next message.
- A dispatcher-priority GLib source made ready while a suspended cycle holds a RunLoop function dispatches before that function runs, and a rendering observer runs after the suspension before both.
- A dispatcher-priority GLib idle dispatches within 10 ms while a RunLoop function reposts itself for 100 ms.
- An eight-round dispatcher-priority GSource queues a RunLoop callback that spins a 30 ms nested default-mode CF loop. A 5 ms GLib timeout is armed before the first round. The remaining rounds dispatch inside the nested loop, no dispatch runs inside another, and the timeout fires once on the main thread inside the nested loop. A continuously signaled CF control source keeps the nested loop awake, and the descriptor helper is blocked, isolating deadline-timer delivery from BeforeWaiting and helper wakeups.

A harness-local `g_poll` wrapper records helper timeout arguments and controls helper blocking.
A completion observer ends predicate-based waits, and a 30-second watchdog bounds a stalled main
thread. The runner reports each check and an overall result, followed by the pass count.

`--bridge-source <file>` compiles another copy of the bridge into the same harness, and
`--output-dir <dir>` keeps its objects apart from the default build. The runner prints the bridge
source path before compiling it.
