#!/bin/bash
# Build the WebKit polyfill archives from source into polyfill/build/ (gitignored).
# Everything here compiles from polyfill/src + legacy-support. Symbols 10.9 genuinely
# lacks (framework SPI, WebKit-internal) are added as real implementations as the
# relink surfaces them.
#
#   libpolyfill.a          linked into every binary (OptionsMac.cmake)
#   libpolyfill_classes.a  force-loaded into JavaScriptCore (polyfill_classes.o ObjC class stubs + objc_inject)
#   libwtf_compat.a        force-loaded into JavaScriptCore
#   libcg_polyfill.dylib   embedded into WebCore.framework by install-safari7.sh
#   libtcc_polyfill.dylib  embedded into WebKit2.framework; loaded by WebKit::TCCLibrary() in place of
#                          the system TCC framework (10.9 lacks camera/microphone TCC services)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"          # polyfill/scripts
POLY="$(cd "$HERE/.." && pwd)"                                 # polyfill
REPO="$(cd "$POLY/../.." && pwd)"                              # repo root
TC="${MAVERICKS_CLANG:-$REPO/MavericksSupport/toolchain/build/clang}"
SDK="${MAVERICKS_SDK:-$(dirname "$REPO")/MacOSX26.1.sdk}"             # libc++ headers for the C++ unit
CLANG="$TC/bin/clang"; AR="$TC/bin/llvm-ar"
SRC="$POLY/src"; LEGACY="$POLY/legacy-support"; OUT="$POLY/build"
OBJ="$(mktemp -d -t polybuild)"; trap 'rm -rf "$OBJ"' EXIT
mkdir -p "$OUT"

# polyfill_stubs.m / vector_stubs.c etc. are compiled with --no-default-config so the
# clang wrapper does NOT force its default link set; they are pure object code.
CF='--no-default-config -mmacosx-version-min=10.9 -Wno-unused-command-line-argument'

echo "### compiling polyfill/src"
"$CLANG" -c $CF -o "$OBJ/polyfill_stubs.o"   "$SRC/polyfill_stubs.m"
"$CLANG" -c $CF -o "$OBJ/polyfill_classes.o" "$SRC/polyfill_classes.m"
"$CLANG" -c $CF -o "$OBJ/vector_stubs.o"    "$SRC/vector_stubs.c"
"$CLANG" -c $CF -o "$OBJ/const_polyfill.o"  "$SRC/const_polyfill.c"
"$CLANG" -c $CF -o "$OBJ/graphics_shims.o"  "$SRC/graphics_shims.c"
# system_spi_polyfill.c needs the SDK's CoreText/Security/ImageIO headers (it calls 10.9-present APIs
# but the declarations live in the modern SDK). Min 10.9 so it deploys back; symbols resolve at runtime.
"$CLANG" -c --no-default-config -isysroot "$SDK" -mmacosx-version-min=10.9 \
    -Wno-unused-command-line-argument -Wno-deprecated-declarations \
    -o "$OBJ/system_spi_polyfill.o" "$SRC/system_spi_polyfill.c"
# objc_inject.m references post-10.9 selectors (declared only in the SDK) + deprecated 10.9 colors.
"$CLANG" -c --no-default-config -isysroot "$SDK" -mmacosx-version-min=10.9 \
    -Wno-deprecated-declarations -Wno-unused-command-line-argument \
    -o "$OBJ/objc_inject.o" "$SRC/objc_inject.m"

echo "### compiling legacy-support (macports-legacy-support: POSIX/libc gap-fills)"
bash "$HERE/build-legacy-polyfills.sh" "$CLANG" "$OBJ/legacy.a" "$OBJ/legacy-obj"
( cd "$OBJ" && "$AR" x legacy.a )    # unpack the legacy objects next to ours

echo "### libpolyfill.a (C function/constant stubs only — NO ObjC classes)"
rm -f "$OUT/libpolyfill.a"
"$AR" rcs "$OUT/libpolyfill.a" "$OBJ/polyfill_stubs.o" "$OBJ/vector_stubs.o" \
    "$OBJ/const_polyfill.o" "$OBJ/graphics_shims.o" "$OBJ/system_spi_polyfill.o" "$OBJ/legacy-obj"/*.o

echo "### libpolyfill_classes.dylib (the ObjC class stubs — ONE shared definition)"
# The polyfilled classes have absent-on-10.9 SYSTEM names (NSScrollingPredominantAxisFilter, UTType,
# CABackdropLayer, NSVisualEffectView, SecKeyProxy, _NSHTTPAlternativeServicesStorage, ...) which WebKit
# references with a two-level-namespace binding to the system framework that owns them in the build SDK
# (AppKit/QuartzCore/Foundation/Security/CFNetwork/CoreServices). On 10.9 those frameworks lack the class.
# This ONE dylib defines all the stubs (so each class is defined exactly once across the loaded images — no
# "Class X is implemented in both ..." ObjC runtime warning). It is also link_libraries'd into every framework
# (WEBKIT_FRAMEWORK in WebKitMacros.cmake), which is enough for the classes the linker happens to resolve
# against it (the AppKit/QuartzCore/Foundation ones). For the classes whose owning framework is linked BEFORE
# this dylib (Security -> SecKeyProxy; CFNetwork -> _NSHTTPAlternativeServices*/_NSHSTSStorage; CoreServices ->
# LSBundleProxy; QuartzCore in some binaries -> CABackdropLayer), the reference instead binds to that system
# framework. To capture those deterministically (CMake link order is not controllable enough), this dylib
# REEXPORTS those four frameworks and install-safari7.sh install_name_tool -change's each WebKit binary's
# dependency on them to this dylib: the class then resolves here, and the framework's real symbols pass through
# the reexport. compatibility_version is set very high so the repointed (Security/... compat 1.0.0) load
# commands are satisfied. install_name mirrors libcg_polyfill.dylib so install-safari7.sh can relocate it into
# the bundle and repoint refs to an absolute in-bundle path (no /usr/local at runtime).
source "$REPO/MavericksSupport/reexport-shim.sh"
build_reexport_shim --clang "$CLANG" --out "$OUT/libpolyfill_classes.dylib" \
    --install-name /usr/local/lib/libpolyfill_classes.dylib --compat 9999.0.0 --current 9999.0.0 \
    --framework Foundation --framework AppKit --framework CoreFoundation \
    --reexport-framework QuartzCore --reexport-framework CoreServices \
    --reexport-framework Security --reexport-framework CFNetwork \
    "$OBJ/polyfill_classes.o"

echo "### libpolyfill_classes.a (force-loaded into JSC: method injection only)"
# objc_inject.o's method-injection +load ships ONLY here and is force-loaded into JavaScriptCore so it runs
# once — in JSC, before WebCore/WebKit use the injected AppKit/Foundation methods. The class stubs themselves
# now live in libpolyfill_classes.dylib (above), not here.
rm -f "$OUT/libpolyfill_classes.a"
"$AR" rcs "$OUT/libpolyfill_classes.a" "$OBJ/objc_inject.o"

echo "### libwtf_compat.a"
"$TC/bin/clang++" -c --no-default-config -isysroot "$SDK" -mmacosx-version-min=10.9 -fblocks -std=c++17 \
    -Wno-unused-command-line-argument -o "$OBJ/wtf_compat.o" "$SRC/wtf_compat.cpp"
"$CLANG" -c --no-default-config -mmacosx-version-min=10.9 \
    -o "$OBJ/wtf_compat_asm.o" "$SRC/wtf_compat_asm.s"
rm -f "$OUT/libwtf_compat.a"
"$AR" rcs "$OUT/libwtf_compat.a" "$OBJ/wtf_compat.o" "$OBJ/wtf_compat_asm.o"

echo "### libcg_polyfill.dylib"
# -compatibility_version 1.0.0 matches the global dylib versioning OptionsMac.cmake stamps on every
# WebKit dylib, so WebCore (which records "requires libcg_polyfill 1.0.0") loads the deployed copy.
# Without it the dylib defaults to 0.0.0 and dyld rejects it ("Incompatible library version").
"$CLANG" --no-default-config -mmacosx-version-min=10.9 -dynamiclib \
    -install_name /usr/local/lib/libcg_polyfill.dylib \
    -compatibility_version 1.0.0 -current_version 615.1.1 \
    -o "$OUT/libcg_polyfill.dylib" "$SRC/cg_colorspace.c" -framework CoreGraphics -framework CoreFoundation

echo "### libtcc_polyfill.dylib"
# dlopen'd by WebKit::TCCLibrary() via @loader_path (relative to the WebKit2 binary), so the install
# name is matched to where install-safari7.sh deploys it (WebKit2.framework/Versions/A/Frameworks).
"$CLANG" --no-default-config -mmacosx-version-min=10.9 -dynamiclib \
    -install_name @loader_path/Frameworks/libtcc_polyfill.dylib \
    -compatibility_version 1.0.0 -current_version 615.1.1 \
    -o "$OUT/libtcc_polyfill.dylib" "$SRC/tcc_polyfill.c" -framework CoreFoundation

echo "### done -> $OUT"
ls -la "$OUT"
