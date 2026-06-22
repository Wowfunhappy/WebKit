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
├── README.md                  this file
├── mac10.9-toolchain.cmake     CMake toolchain entry (all paths relative)
├── install-safari7.sh          installer: name-shift + deploy into the 10.9 system
│
├── toolchain/                  the in-tree compiler + helper build tools
│   ├── vendor/                   COMMITTED binaries we can't rebuild:
│   │                             clang-22 + lld (bzip2-compressed), llvm-ar/nm/objcopy,
│   │                             clang.cfg/clang++.cfg, resource headers, libc++/abi/unwind
│   ├── scripts/                  COMMITTED source: build_{python3,nasm,ninja,cmake}.sh
│   ├── bootstrap.sh              reconstructs build/ from vendor/ + scripts/
│   └── build/                    ARTIFACTS (gitignored): unpacked clang + built tools
│
├── polyfill/                   genuinely-missing-on-10.9 symbols, from source
│   ├── src/                      polyfill_stubs.m, vector_stubs.c, wtf_compat.{cpp,s}
│   ├── legacy-support/           vendored macports-legacy-support (libc/POSIX gap-fills)
│   ├── headers/                  framework header overlays (declarations modern WebKit calls)
│   ├── scripts/                  build-legacy-polyfills.sh, rebuild_wtf_compat.sh
│   └── prebuilt/                 static/dynamic archives the link consumes (see below)
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
   — unpacks the in-tree clang and builds python3/nasm/ninja/cmake from source into
   `toolchain/build/` (gitignored).

3. **Configure + build** with the bootstrapped cmake/ninja and the toolchain file
   (`bootstrap.sh` prints the exact command).

4. **Install** onto the 10.9 target: `sudo bash MavericksSupport/install-safari7.sh`.

## `polyfill/prebuilt/` contents

- `libpolyfill.a` — the 10.9-missing symbols WebKit links: the macports-legacy libc
  base, a CFString-constant table, two small CG/vImage forwarding shims, and
  `return 0` stubs for framework SPI that 10.9 lacks. Linked globally by
  `OptionsMac.cmake`.
- `libpolyfill_classes.a` / `libwtf_compat.a` — force-loaded into JavaScriptCore
  (`Source/JavaScriptCore/CMakeLists.txt`).
- `libcg_polyfill.dylib` — CoreGraphics shims, embedded into WebCore.framework by
  `install-safari7.sh`.

The reproducible source for these lives in `src/` (WebKit-specific stubs) and
`legacy-support/` (the libc base); `scripts/rebuild_wtf_compat.sh` and
`scripts/build-legacy-polyfills.sh` build their objects.
