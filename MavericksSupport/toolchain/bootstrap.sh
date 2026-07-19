#!/bin/bash
# Reconstruct the toolchain ARTIFACTS (toolchain/build/) from the COMMITTED inputs
# (toolchain/vendor/ + toolchain/scripts/). Run this once after cloning, before
# configuring WebKit. Idempotent -- re-running only does the missing work; delete
# toolchain/build/ to force a full rebuild.
#
# Taxonomy reminder: anything under build/ is a regenerable artifact (gitignored);
# anything under vendor/ or scripts/ is committed (a binary we can't rebuild, or
# source). The macOS SDK is the one input NOT in the repo -- supply it as a sibling
# of the checkout (../MacOSX26.1.sdk) or via MAVERICKS_SDK.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # MavericksSupport/toolchain
VENDOR="$HERE/vendor"
BUILD="$HERE/build"
SCRIPTS="$HERE/scripts"
mkdir -p "$BUILD"

echo "### [1/6] assemble build/clang from vendor/clang"
CLANG_OUT="$BUILD/clang"
if [ ! -x "$CLANG_OUT/bin/clang-22" ]; then
    rm -rf "$CLANG_OUT"; mkdir -p "$CLANG_OUT/bin"
    bunzip2 -c "$VENDOR/clang/bin/clang-22.bz2" > "$CLANG_OUT/bin/clang-22"
    bunzip2 -c "$VENDOR/clang/bin/lld.bz2"      > "$CLANG_OUT/bin/lld"
    chmod +x "$CLANG_OUT/bin/clang-22" "$CLANG_OUT/bin/lld"
    # FIXME: hold clang's mtime steady across re-extraction so ccache, which identifies the
    # compiler by mtime, keeps its cache. TODO: Remove this and uncomment
    # `compiler_check = content` in ccache.conf. This will invalidate the existing cache.
    touch -t 202606191815.21 "$CLANG_OUT/bin/clang-22" "$CLANG_OUT/bin/lld"
    cp "$VENDOR/clang/bin/"{llvm-ar,llvm-nm,llvm-objcopy,clang.cfg,clang++.cfg} "$CLANG_OUT/bin/"
    # clang/lld/llvm tools are multi-call binaries invoked under several names; recreate
    # the name symlinks here so vendor/ never has to commit them.
    ( cd "$CLANG_OUT/bin"
      ln -sf clang-22 clang; ln -sf clang clang++; ln -sf lld ld64.lld
      ln -sf llvm-ar llvm-ranlib; ln -sf llvm-objcopy llvm-strip )
    cp -R "$VENDOR/clang/lib" "$CLANG_OUT/lib"
    # Recreate the dylib version chain (libX.dylib -> libX.1.dylib -> libX.1.0.dylib) that
    # -lc++/-lc++abi/-lunwind resolve against and the @rpath/libX.1.dylib install names need.
    ( cd "$CLANG_OUT/lib"
      for base in libc++ libc++abi libunwind; do
        ln -sf "$base.1.0.dylib" "$base.1.dylib"; ln -sf "$base.1.dylib" "$base.dylib"
      done )
    echo "    clang $("$CLANG_OUT/bin/clang" --version | head -1 | awk '{print $3}') assembled"
else
    echo "    already present, skipping"
fi

echo "### [2/6] python3"; [ -x "$BUILD/python3/bin/python3" ] || "$SCRIPTS/build_python3.sh"
echo "### [3/6] nasm";    [ -x "$BUILD/nasm/bin/nasm" ]       || "$SCRIPTS/build_nasm.sh"
echo "### [4/6] ninja";   [ -x "$BUILD/ninja/bin/ninja" ]     || "$SCRIPTS/build_ninja.sh"
echo "### [5/6] cmake";   [ -x "$BUILD/cmake/bin/cmake" ]     || "$SCRIPTS/build_cmake.sh"
echo "### [6/6] ccache";  [ -x "$BUILD/ccache/bin/ccache" ]   || "$SCRIPTS/build_ccache.sh"

echo
echo "### toolchain ready under $BUILD"
echo "Configure WebKit with:"
echo "  $BUILD/cmake/bin/cmake -S . -B WebKitBuild/Release -G Ninja \\"
echo "    -DCMAKE_MAKE_PROGRAM=$BUILD/ninja/bin/ninja \\"
echo "    -DCMAKE_TOOLCHAIN_FILE=MavericksSupport/mac10.9-toolchain.cmake \\"
echo "    -DPORT=Mac -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \\"
echo "    -DCMAKE_NINJA_FORCE_RESPONSE_FILE=1"
