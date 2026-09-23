This harness verifies the installed release build's origin-access IPC boundary.
Run it after building and installing matching frameworks:

```
MavericksSupport/toolchain/build/python3/bin/python3 MavericksSupport/tests/origin-access/run.py
```

A local HTTP server and WKWebView check actual CORS behavior for add, remove, and
reset. Ordinary process pools must reject each message. The test preference and
a UI-configured native injected bundle independently authorize the operations.
Both authorized cases are repeated after a preference update and a NetworkProcess
restart.

Release builds have the JavaScript IPC testing API compiled out. The harness uses
the host debugger to load its probe into WebContent and invoke the production
Encoder, String coder, network connection, and dispatch code. The probe resolves
private symbols from the installed image's symbol table. Loading the probe through
the debugger does not set the process pool's injected-bundle authorization. The
native-bundle case additionally configures the same bundle through the embedder
API before launching WebContent.

Generated binaries live in WebKitBuild/Release/origin-access. Compilation and
linking append to /tmp/wk_build.log. Optional arguments select individual cases:
AddOriginAccessAllowListEntry, RemoveOriginAccessAllowListEntry,
ResetOriginAccessAllowLists, test, or bundle. --compile-only builds the fixtures.
