#!/bin/bash
# Build ICU 74.2 (static) for the WebKit-on-Mavericks backport.
#
# JSC's Intl implementation calls ICU >= 64 functions (ucfpos_*, udtitvfmt_*,
# ureldatefmt_*, ulistfmt_*, ufieldpositer_*, ...) that the 10.9 system ICU
# (libicucore, ICU 51) does not export, so we link our own modern ICU. Built
# with vanilla clang-22 (--no-default-config) targeting 10.9; static so there is
# nothing to deploy at runtime. Headers + static libs install in-tree under
# MavericksSupport/deps/{include,lib}.
#
# Usage: MavericksSupport/deps/build_icu.sh
set -euo pipefail
TC=/Users/jonathan/Desktop/Compilers/toolchains/clang-22
DEPS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRATCH=/Users/jonathan/Desktop/Compilers/depbuild
SRC="$SCRATCH/src"
VBIN="$SCRATCH/vanilla-bin"
STAGE="$SCRATCH/icu-install"
VER=74-2

mkdir -p "$SRC" "$STAGE" "$DEPS_DIR/include" "$DEPS_DIR/lib"
# ICU is C++ and its build tools (makeconv/genrb/...) link C++ iostreams, so it
# needs the FULL clang-22 wrapper (which wires up clang-22's libc++); vanilla
# --no-default-config mixes clang-22 libc++ headers with the system 10.9 libc++
# and the host tools fail to link. ICU uses no gnulib, so the wrapper's
# force-included compat header doesn't disturb its configure probes.

cd "$SRC"
[ -f icu4c-${VER}-src.tgz ] || curl -fsSL -o icu4c-${VER}-src.tgz \
  "https://github.com/unicode-org/icu/releases/download/release-${VER}/icu4c-${VER//-/_}-src.tgz"
rm -rf icu && tar xf icu4c-${VER}-src.tgz   # extracts to ./icu
cd icu/source

export CC="$TC/bin/clang" CXX="$TC/bin/clang++"
export AR="$TC/bin/llvm-ar" RANLIB="$TC/bin/llvm-ranlib"
export MACOSX_DEPLOYMENT_TARGET=10.9
export CFLAGS="-O2 -mmacosx-version-min=10.9"
export CXXFLAGS="-O2 -mmacosx-version-min=10.9 -std=c++17"

# --disable-renaming: emit UNVERSIONED symbols (ucfpos_open, not ucfpos_open_74)
# to match WebKit, which sets U_DISABLE_RENAMING=1 (it normally links Apple's
# unversioned libicucore). Without this the JSC Intl symbols stay unresolved.
./configure --prefix="$STAGE" --enable-static --disable-shared --disable-renaming \
  --disable-samples --disable-tests --disable-extras --disable-icuio --disable-layoutex
make -j4
make install

echo "==== installed ICU libs ===="
ls -la "$STAGE/lib"/*.a
echo "==== collect in-tree (headers + static libs) ===="
rm -rf "$DEPS_DIR/include/unicode"
cp -R "$STAGE/include/unicode" "$DEPS_DIR/include/unicode"
for l in "$STAGE"/lib/libicuuc.a "$STAGE"/lib/libicui18n.a "$STAGE"/lib/libicudata.a; do
  [ -f "$l" ] && cp "$l" "$DEPS_DIR/lib/"
done
echo "==== done ===="; ls -la "$DEPS_DIR/lib"/libicu*.a
