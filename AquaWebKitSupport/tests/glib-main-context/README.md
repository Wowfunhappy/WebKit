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

The bridge runs one GLib round per callout of a persistent main-thread `RunLoop::Timer`.
Ready work and GLib deadlines share that timer. An outstanding fire time can only move earlier;
the timer's callback clears it. The helper polls descriptors with an infinite timeout and
requests ready work through `RunLoop::dispatch`, which arms the timer on the main thread.
Before-waiting and exit observers prepare sources added on the main thread.

The harness serves GLib's default context on the main CF/NSRunLoop and checks:

- Main-thread GLib timeouts fire between 100 and 160 ms, including with the descriptor helper blocked.
- A GLib idle dispatches within 1000 observer passes and 100 ms while a zero-delay CF timer reposts.
- A 20 ms GLib timeout fires between 20 and 40 ms while a zero-delay CF timer reposts with 15 ms of synchronous work per callout and the descriptor helper is blocked.
- Every descriptor-helper poll uses an infinite timeout.
- Chained main-thread idle sources advance without an outside wake-up, and repeating idles share the loop with CF timers.
- Before-waiting observers run during 100 continuously ready GLib rounds.
- A CF source and a 2 ms CF timer run within 10 ms while RunLoop work reposts.
- Zero-delay WebCore shared and CF control timers fire within 10 ms while RunLoop or main WorkQueue work reposts. Eight combinations cover dispatch suspension and a blocked descriptor helper; reposting ends after 100 ms.
- A finite main WorkQueue chain completes across dispatch suspension alongside the shared timer.
- Registered private modes deliver the shared timer once, support registration after arming and cancellation, and leave common-mode RunLoop, callOnMainThread and GLib work pending until the loop returns to common modes.
- Default-priority descriptor backlogs of 200 and 20 bytes and their RunLoop callbacks finish within 500 ms, in FIFO order, including suspended dispatch.
- CF before-waiting observers and a 2 ms CF timer advance during 100 ms of continuously ready default-priority GLib traffic. The timer fires within 10 ms, before that traffic ends.

A harness-local `g_poll` wrapper records helper timeout arguments and controls helper blocking.
A completion observer ends predicate-based waits, and a 30-second watchdog bounds a stalled main
thread. The runner reports 34 checks and one overall result, for 35 results total.

`--bridge-source <file>` compiles another copy of the bridge into the same harness, and
`--output-dir <dir>` keeps its objects apart from the default build.
