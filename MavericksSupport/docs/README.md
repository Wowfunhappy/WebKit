# MavericksSupport documentation

Prose about the Mavericks WebKit backport (modern WebKit as the system WebKit for Safari 7 on macOS 10.9).
Everything else under `MavericksSupport/` is build glue: scripts, the polyfill source, the toolchain,
vendored deps, and each of those directories carries its own README for its own usage.

- **[UPSTREAM-MERGE-NOTES.md](UPSTREAM-MERGE-NOTES.md)** — what a merge of newer upstream WebKit disturbs in
  this fork, and how to reconcile it. Read before every upstream merge.
- **[MAVERICKS-WEBKIT-ABI-REFERENCE.md](MAVERICKS-WEBKIT-ABI-REFERENCE.md)** — the private WebKit API contract
  the backport must satisfy on 10.9: the frozen 725-symbol core Safari 7 binds against, across JavaScriptCore /
  WebKitLegacy / WebKit2, plus the extra legacy surface Mail and QuickLook need, and how the contract data in
  `../host-abi/` was captured.
