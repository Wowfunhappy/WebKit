# MavericksSupport documentation

Human-facing docs for the Mavericks WebKit backport (modern WebKit as the system WebKit for Safari 7 on
macOS 10.9). The files alongside `MavericksSupport/` are build glue (scripts, the polyfill source, the
toolchain, vendored deps); this folder is the prose.

- **[UPSTREAM-MERGE-NOTES.md](UPSTREAM-MERGE-NOTES.md)** — what a future merge of newer upstream WebKit
  disturbs in this fork, and how to reconcile it. Read before every upstream merge.
- **[MAVERICKS-WEBKIT-ABI-REFERENCE.md](MAVERICKS-WEBKIT-ABI-REFERENCE.md)** — the private WebKit API contract
  the backport must satisfy on 10.9 (the frozen 725-symbol core Safari 7 binds against, across JavaScriptCore /
  WebKitLegacy / WebKit2, plus the extra legacy surface Mail and QuickLook need).

Related, but not prose (kept with the data/tooling they belong to):
- `../README.md` — overview of `MavericksSupport/` itself.
- `../safari7-abi/` — the captured ABI contract data (`safari-needs-from-*.txt`, `exports-*.txt`) and
  `check-abi-gap.sh`; its own `README.md` documents how the contract was captured.
