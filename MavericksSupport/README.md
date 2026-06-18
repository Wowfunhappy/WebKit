# MavericksSupport

Build-time and link-time support layer that makes this WebKit fork buildable
and runnable on macOS 10.9.5 Mavericks with the system-installed Safari 9.1.3.

Modern WebKit (~Safari 17) targets macOS 13+ and assumes APIs that don't
exist on 10.9. This directory provides the polyfills, framework header
overlays, and build scripts that bridge the gap.

## Layout

```
MavericksSupport/
├── README.md
├── compat.h               10.9 compatibility header (availability shims,
│                          missing-symbol forward declarations)
├── polyfill_stubs.m       WebKit-specific C/ObjC polyfill stubs
├── vector_stubs.c         Sandbox vector stubs
├── wtf_compat.cpp         WTF compatibility shims
├── wtf_compat_asm.s       WTF compatibility assembly
├── polyfill/              Framework header overlays (Accessibility,
│                          AppKit, AudioToolbox, CommonCrypto, CoreML,
│                          CoreTelephony, IOSurface, NaturalLanguage,
│                          Network, QuartzCore, Speech,
│                          UniformTypeIdentifiers, VideoToolbox, WebGPU,
│                          libwebrtc, mach, os, simd, sys, webm,
│                          compression.h)
├── sdk-overlay/           SDK overlay (Foundation.framework)
├── scripts/               Build / install / verification scripts
│   ├── postbuild_webkit.sh    Postbuild that installs WebKit into both
│   │                          /System/Library/Frameworks and
│   │                          /System/Library/StagedFrameworks/Safari
│   └── verify_fixes.sh       Source-level sanity check that all
│                             backport fixes are present
└── prebuilt/              Prebuilt static and dynamic libraries
    ├── libpolyfill.a            Combined polyfill (macports-legacy-support
    │                            members + WebKit-specific stubs)
    ├── libpolyfill_noobjc.a     Same minus ObjC class stubs
    ├── libpolyfill_classes.a    ObjC class stubs only
    ├── libwtf_compat.a
    ├── libwtf_compat.dylib
    └── libcg_polyfill.dylib     CoreGraphics runtime polyfill
```

## External dependencies (not vendored here)

These live outside the fork. Get or build them once:

1. **Custom Clang toolchain (Clang 22 recommended)**

   Modern WebKit needs a C++23-capable compiler. The system clang on 10.9
   is far too old. Use a stock LLVM release built against the polyfill;
   see https://github.com/Wowfunhappy/macports-legacy-support for the
   approach (the same `libMacportsLegacySupport.a` is linked into the
   compiler so it runs on 10.9).

2. **macports-legacy-support** —
   https://github.com/Wowfunhappy/macports-legacy-support

   Provides POSIX/libc functions missing from the 10.9 SDK (arc4random,
   atcalls, dprintf, fdopendir, fmemopen, getentropy, sincos, statxx,
   utimensat, ...). `libpolyfill.a` in `prebuilt/` includes these object
   files alongside the WebKit-specific stubs in this directory.

3. **CMake and Ninja**

   Any reasonably recent release works. Standard upstream binaries.

4. **Python 3 and ICU**

   For Python and ICU on 10.9, build stock upstream sources with the
   custom clang and link against `libMacPortsLegacySupport.a`. Python
   3.9.21 with `--without-ensurepip --disable-test-modules` works.
   ICU 74.2 static build works.

## How `libpolyfill.a` is built

It is `libMacportsLegacySupport.a` (from the macports-legacy-support
repo above) merged with the WebKit-specific object files compiled from:

- `polyfill_stubs.m`        → polyfill_stubs.o
- `vector_stubs.c`          → vector_stubs.o
- WebCore stubs             → webcore_stubs.o
- Sandbox vector stubs      → sandbox_vector_stubs.o
- Sundry runtime helpers    → polyfill_pal.o, polyfill_rtti.o,
                              polyfill_tzone_{data,funcs}.o,
                              polyfill_classes.o, polyfill_heaprefs.o,
                              const_polyfill.o, missing34.o,
                              final_stubs.o

The `.a` is included prebuilt for convenience. To rebuild from source,
combine the macports-legacy-support build artifacts with object files
compiled from the `.c` / `.m` / `.cpp` / `.s` sources in this directory
using `libtool -static -o libpolyfill.a *.o`.

## Verification

After building WebKit, run:

```
MavericksSupport/scripts/verify_fixes.sh
```

It greps for sentinel comments in the source tree and checks that the
expected polyfill stubs are stripped from the binary. Adjust the paths
at the top of the script for your checkout location.
