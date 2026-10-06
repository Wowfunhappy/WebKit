Run after a successful build and installation:

```sh
AquaWebKitSupport/toolchain/build/python3/bin/python3 AquaWebKitSupport/tests/glib-main-context/run.py
```

The harness compiles `AquaWebKitSupport/source/WebCore/platform/graphics/gstreamer/GLibMainContextAquaWebKit.cpp`
with WebCore's compile flags, links the installed JavaScriptCore and GLib runtime, and serves GLib's default
context from the main `NSRunLoop`, as WebContent does. It checks that a timeout added on the main thread fires
on time, that idle sources added from the main thread run without another wake-up, that a repeating idle source
leaves run-loop timers running, and that a `G_PRIORITY_DEFAULT` descriptor source drains its backlog promptly
while RunLoop work queued by each dispatch runs before the next one. A watchdog fails the run if the main
thread stops returning to the run loop.
Compiler and linker output goes to `/tmp/wk_build.log`.
