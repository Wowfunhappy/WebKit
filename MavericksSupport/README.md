# MavericksSupport

Everything that makes this WebKit fork build and run on **macOS 10.9.5 Mavericks**
with the system-installed **Safari 7.0.6**, kept self-contained so a fresh clone
*is* the build environment.

The build runs on a 10.9 host with a modern compiler (clang-22) against a modern
macOS SDK, with the deployment target pinned to 10.9 so the binaries bind to 10.9's
real frameworks at runtime. This directory vendors the toolchain, the from-source
polyfills for genuinely-missing-on-10.9 symbols, and the build/install scripts.

## The one rule: source vs. artifact

> **If a script can regenerate it, it's an artifact → gitignored, never committed.
> Otherwise it's committed** (source, or a binary we genuinely can't rebuild).

You never have to consult `.gitignore` to know which is which — it's visible from
the directory a file lives in (`vendor/` = committed binary, `scripts/`/`src/` =
source, `build/` = regenerable artifact).

## Layout

```
MavericksSupport/
│  (top level = the things you invoke, plus the file CMake needs)
├── README.md                   this file
├── bootstrap.sh                fresh-clone setup (toolchain + deps + polyfill)
├── rebuild.sh                  build: link, then stage the complete product
├── install-safari7.sh          installer: copy the staged product into the 10.9 system
├── mac10.9-toolchain.cmake     CMake toolchain entry (all paths relative)
│
├── scripts/                    supporting scripts (not entry points for a normal build)
│   ├── stage-frameworks.sh                the build's last phase: assemble WebKitBuild/Release/staged
│   ├── backup-stock-frameworks.sh         keep stock 10.9 WebKit in ../stock-webkit-backup (i386 slices)
│   ├── framework-layout.sh                sourced helper: the installed layout, shared by stage + install
│   ├── run-layout-tests.sh                layout tests: --wk1 (DumpRenderTree) | --wk2 (WebKitTestRunner)
│   ├── make-build-frameworks-runnable.sh  make the in-place build frameworks loadable, no system writes
│   ├── check-backport-markers.sh          audits divergences for MAVERICKS_BACKPORT markers
│   └── reexport-shim.sh                   sourced helper: build a reexport shim dylib
│
├── demangler/                  the demangler guard (_Z -> _z rename so symbolication can't crash)
│   ├── neutralize-demangler-crashers.py   the guard, run by scripts/stage-frameworks.sh
│   ├── demangler-crash-scan.cpp           fork-isolated crash-scan worker
│   └── demangler-crash-scan-freecheck.c   the second (double-free) detector
│
├── toolchain/                  the in-tree compiler + helper build tools
│   ├── vendor/                   COMMITTED binaries we can't rebuild:
│   │                             clang-22 + lld (bzip2-compressed), llvm-ar/nm/objcopy,
│   │                             clang.cfg/clang++.cfg, resource headers, libc++/abi/unwind
│   ├── scripts/                  COMMITTED source: build_{python3,nasm,ninja,cmake,ccache}.sh
│   ├── bootstrap.sh              reconstructs build/ from vendor/ + scripts/
│   └── build/                    ARTIFACTS (gitignored): unpacked clang + built tools
│
├── polyfill/                   the polyfill layer -- see polyfill/README.md
│   ├── polyfills/                THE POLYFILLS, by what the symbol is (constants, runtime, graphics, ...)
│   ├── mechanism/                how the layer loads (not needed to add a polyfill)
│   ├── legacy-support/           vendored macports-legacy-support (libc/POSIX gap-fills)
│   ├── headers/                  framework header overlays (declarations modern WebKit calls)
│   ├── tests/                    checks the layer's guarantees on this OS
│   ├── scripts/                  build-polyfill.sh, build-legacy-polyfills.sh
│   └── build/                    ARTIFACTS (gitignored): archives the link consumes (see below)
│
├── sdk/                        SDK patches: patch-sdk-rehome.sh (symbol re-home) + patch-sdk-availability.sh (make iOS-only soft-linked classes macOS-declarable)
├── deps/                       third-party libraries WebKit links (see deps/README.md)
│   ├── build_deps.sh             builds ICU/gcrypt/tasn1/gpg-error/brotli/woff2 -> build/ (gitignored)
│   ├── build/                    ARTIFACTS (gitignored): the built libs + headers
│   └── gstreamer/                vendored GStreamer (committed binary) + glib/ (re-vendor scripts)
├── safari7-abi/                the captured Safari-7 private ABI contract + check-abi-gap.sh
├── docs/                       prose docs: upstream-merge guide + Safari-7 ABI reference
└── tests/                      manual test pages + media
```

## Building (a fresh clone)

1. **Supply the SDK.** The macOS SDK is Apple-proprietary and not redistributed
   here. Place a `MacOSX26.1.sdk` as a **sibling of this checkout** (or set
   `MAVERICKS_SDK`). The toolchain file errors clearly if it's missing.

2. **Bootstrap the toolchain** (once): `bash MavericksSupport/toolchain/bootstrap.sh`
   — unpacks the in-tree clang and builds python3/nasm/ninja/cmake/ccache from source into
   `toolchain/build/` (gitignored).

3. **Configure + build** with the bootstrapped cmake/ninja and the toolchain file
   (`bootstrap.sh` prints the exact command).

4. **Install** onto the 10.9 target: `sudo bash MavericksSupport/install-safari7.sh`.
   The build's last phase (`scripts/stage-frameworks.sh`, run by `rebuild.sh`) already
   assembled the complete product in `WebKitBuild/Release/staged/`, laid out exactly as it
   lands on disk; installing copies that tree into `/System` and edits the host files
   nobody builds (the Dashboard Web Clip widget plist, the Web Inspector's `Main.css`, and
   Safari's `page-load-errors.css`).

To run layout tests against the build tree (never the installed system), use
`bash MavericksSupport/scripts/run-layout-tests.sh --wk1|--wk2 <tests...>` — the port
flag is mandatory, and the script's header lists the one-time driver-build prereqs.

## `polyfill/build/` contents

- `libpolyfill.a` — the C functions and data constants: the macports-legacy libc base plus the
  framework entry points 10.9 lacks or gets wrong. Force-loaded into every shipped framework
  (`WEBKIT_FRAMEWORK` in `Source/cmake/WebKitMacros.cmake`), which is what makes a polyfill win
  deterministically; also listed plainly by `OptionsMac.cmake` for the build-time tools.
- `libwtf_compat.a` — force-loaded into JavaScriptCore
  (`Source/JavaScriptCore/CMakeLists.txt`).
- `libpolyfill_classes.a` — the ObjC method polyfills, force-loaded into WebCore
  (`Source/WebCore/CMakeLists.txt`).
- `libpolyfill_classes.dylib` — the ObjC class polyfills, one shared definition each.
- `libwk_marker.a` — tags a binary as ours, so method polyfills apply to it and not to a host app.

The reproducible source lives in `polyfills/` (what we polyfill), `mechanism/` (how it loads) and
`legacy-support/` (the libc base). See `polyfill/README.md` before adding a polyfill.
