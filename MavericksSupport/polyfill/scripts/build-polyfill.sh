#!/bin/bash
# Build the WebKit polyfill archives from source into polyfill/build/ (gitignored).
# Everything here compiles from polyfill/src + legacy-support. Symbols 10.9 genuinely
# lacks (framework SPI, WebKit-internal) are added as real implementations as the
# relink surfaces them.
#
#   libpolyfill.a          linked into every binary (OptionsMac.cmake)
#   libpolyfill_classes.a  force-loaded into JavaScriptCore (same object as polyfill_stubs)
#   libwtf_compat.a        force-loaded into JavaScriptCore
#   libcg_polyfill.dylib   embedded into WebCore.framework by install-safari7.sh
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
"$CLANG" -c $CF -o "$OBJ/polyfill_stubs.o"  "$SRC/polyfill_stubs.m"
"$CLANG" -c $CF -o "$OBJ/vector_stubs.o"    "$SRC/vector_stubs.c"
"$CLANG" -c $CF -o "$OBJ/const_polyfill.o"  "$SRC/const_polyfill.c"
"$CLANG" -c $CF -o "$OBJ/graphics_shims.o"  "$SRC/graphics_shims.c"

echo "### compiling legacy-support (macports-legacy-support: POSIX/libc gap-fills)"
bash "$HERE/build-legacy-polyfills.sh" "$CLANG" "$OBJ/legacy.a" "$OBJ/legacy-obj"
( cd "$OBJ" && "$AR" x legacy.a )    # unpack the legacy objects next to ours

echo "### libpolyfill.a"
rm -f "$OUT/libpolyfill.a"
"$AR" rcs "$OUT/libpolyfill.a" "$OBJ/polyfill_stubs.o" "$OBJ/vector_stubs.o" \
    "$OBJ/const_polyfill.o" "$OBJ/graphics_shims.o" "$OBJ/legacy-obj"/*.o

echo "### libpolyfill_classes.a (force-loaded into JSC; same compile as polyfill_stubs.o)"
cp "$OBJ/polyfill_stubs.o" "$OBJ/polyfill_classes_rebuild.o"
rm -f "$OUT/libpolyfill_classes.a"
"$AR" rcs "$OUT/libpolyfill_classes.a" "$OBJ/polyfill_classes_rebuild.o"

echo "### libwtf_compat.a"
"$TC/bin/clang++" -c --no-default-config -isysroot "$SDK" -mmacosx-version-min=10.9 -fblocks -std=c++17 \
    -Wno-unused-command-line-argument -o "$OBJ/wtf_compat.o" "$SRC/wtf_compat.cpp"
"$CLANG" -c --no-default-config -mmacosx-version-min=10.9 \
    -o "$OBJ/wtf_compat_asm.o" "$SRC/wtf_compat_asm.s"
rm -f "$OUT/libwtf_compat.a"
"$AR" rcs "$OUT/libwtf_compat.a" "$OBJ/wtf_compat.o" "$OBJ/wtf_compat_asm.o"

echo "### libcg_polyfill.dylib"
"$CLANG" --no-default-config -mmacosx-version-min=10.9 -dynamiclib \
    -install_name /usr/local/lib/libcg_polyfill.dylib \
    -o "$OUT/libcg_polyfill.dylib" "$SRC/cg_colorspace.c" -framework CoreGraphics -framework CoreFoundation

echo "### done -> $OUT"
ls -la "$OUT"
