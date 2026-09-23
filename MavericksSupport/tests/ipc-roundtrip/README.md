Run after a successful build and installation:

```sh
MavericksSupport/toolchain/build/python3/bin/python3 MavericksSupport/tests/ipc-roundtrip/run.py
```

The harness uses the build's compile flags and headers, compiles upstream Encoder, Decoder and logging definitions,
and links the installed frameworks and their private C++ runtime.
Compiler and linker output goes to `/tmp/wk_build.log`; the executable lives under
`WebKitBuild/Release/ipc-roundtrip`.

It checks mutable, immutable and file requests through CoreIPCNSURLRequest, comparing every
native property-list field and the concrete request class. Repeated requests cross autorelease-pool drains
to verify the protocol-key filters retain their static collections. SameSite checks preserve native URL,
empty cross-site URL and absent site states through mutable and immutable POST requests. HTTP bodies travel separately through
WebCore::FormData and are absent from these fixtures. The direct property-list queries use the
polyfill's scoped selector; the framework's real IPC coder calls it through its normal selector mapping.

Data Detectors coverage scans native results, round-trips DDScannerResult and DDActionContext,
and verifies rejection of mismatched DD classes and an implicitly allowed NSNumber root. All decoders validate the asynchronous
message header and destination ID before reading the payload.
