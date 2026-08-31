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

echo "### [1/9] assemble build/clang from vendor/clang"
CLANG_OUT="$BUILD/clang"
if [ ! -x "$CLANG_OUT/bin/clang-22" ]; then
    rm -rf "$CLANG_OUT"; mkdir -p "$CLANG_OUT/bin"
    bunzip2 -c "$VENDOR/clang/bin/clang-22.bz2" > "$CLANG_OUT/bin/clang-22"
    bunzip2 -c "$VENDOR/clang/bin/lld.bz2"      > "$CLANG_OUT/bin/lld"
    chmod +x "$CLANG_OUT/bin/clang-22" "$CLANG_OUT/bin/lld"
    cp "$VENDOR/clang/bin/"{llvm-ar,clang.cfg,clang++.cfg} "$CLANG_OUT/bin/"
    # clang/lld/llvm tools are multi-call binaries invoked under several names; recreate
    # the name symlinks here so vendor/ never has to commit them.
    ( cd "$CLANG_OUT/bin"
      ln -sf clang-22 clang; ln -sf clang clang++; ln -sf lld ld64.lld
      ln -sf llvm-ar llvm-ranlib )
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

echo "### [2/9] cctools"; [ -x "$BUILD/cctools/bin/otool" ]   || "$SCRIPTS/build_cctools.sh"
echo "### [3/9] python3"; [ -x "$BUILD/python3/bin/python3" ] || "$SCRIPTS/build_python3.sh"
echo "### [4/9] nasm";    [ -x "$BUILD/nasm/bin/nasm" ]       || "$SCRIPTS/build_nasm.sh"
echo "### [5/9] ninja";   [ -x "$BUILD/ninja/bin/ninja" ]     || "$SCRIPTS/build_ninja.sh"
echo "### [6/9] cmake";   [ -x "$BUILD/cmake/bin/cmake" ]     || "$SCRIPTS/build_cmake.sh"
echo "### [7/9] ccache";  [ -x "$BUILD/ccache/bin/ccache" ]   || "$SCRIPTS/build_ccache.sh"
echo "### [8/9] git";     [ -x "$BUILD/git/bin/git" ]         || "$SCRIPTS/build_git.sh"
echo "### [9/9] ruby";    [ -x "$BUILD/ruby/bin/ruby" ]       || "$SCRIPTS/build_ruby.sh"

echo "### toolchain ready under $BUILD"
