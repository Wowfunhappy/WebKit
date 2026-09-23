#!/bin/bash
# Build the local compiler cache with the toolchain's C++ runtime and Mavericks libc.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../scripts/build-log.sh"
build_log_open
TOOLCHAIN="$(cd "$HERE/.." && pwd)"
CLANG="$TOOLCHAIN/build/clang"
CMAKE="$TOOLCHAIN/build/cmake/bin/cmake"
PREFIX="${CCACHE_PREFIX_DIR:-$TOOLCHAIN/build/ccache}"
VERSION=4.14
REPO="$(cd "$TOOLCHAIN/../.." && pwd)"
SDK="${MAVERICKS_SDK:-$(dirname "$REPO")/MacOSX26.1.sdk}"
export MACOSX_DEPLOYMENT_TARGET=10.9
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ccache-build.XXXXXX")"
trap 'rc=$?; rm -rf "$WORK"; build_log_report $rc' EXIT

echo "### Downloading ccache $VERSION"
curl -fsSL -o "$WORK/ccache.tar.gz" "https://github.com/ccache/ccache/releases/download/v${VERSION}/ccache-${VERSION}.tar.gz"
tar xzf "$WORK/ccache.tar.gz" -C "$WORK"

# Native C headers and libraries let feature probes select Mavericks implementations.
# The SDK supplies C++20 headers, paired with the toolchain's private libc++.
# WebKit uses the local disk store.
"$CMAKE" -S "$WORK/ccache-$VERSION" -B "$WORK/build" -G Ninja \
    -DCMAKE_MAKE_PROGRAM="$TOOLCHAIN/build/ninja/bin/ninja" \
    -DCMAKE_C_COMPILER="$CLANG/bin/clang" \
    -DCMAKE_CXX_COMPILER="$CLANG/bin/clang++" \
    -DCMAKE_ASM_COMPILER="$CLANG/bin/clang" \
    -DCMAKE_AR="$CLANG/bin/llvm-ar" \
    -DCMAKE_RANLIB="$CLANG/bin/llvm-ranlib" \
    -DCMAKE_OSX_SYSROOT=/ -DCMAKE_OSX_DEPLOYMENT_TARGET=10.9 \
    -DCMAKE_C_FLAGS=--no-default-config \
    -DCMAKE_ASM_FLAGS=--no-default-config \
    -DCMAKE_CXX_FLAGS="--no-default-config -isystem $SDK/usr/include/c++/v1 -D_LIBCPP_DISABLE_AVAILABILITY -faligned-allocation" \
    -DCMAKE_EXE_LINKER_FLAGS="-fuse-ld=$CLANG/bin/ld64.lld -Wl,-platform_version,macos,10.9,10.9 -L$CLANG/lib -lc++abi -lunwind" \
    -DCMAKE_BUILD_RPATH="$CLANG/lib" \
    -DCMAKE_INSTALL_RPATH="@executable_path/../../clang/lib" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_BUILD_TYPE=Release -DDEPS=DOWNLOAD \
    -DENABLE_DOCUMENTATION=OFF -DENABLE_TESTING=OFF \
    -DHTTP_STORAGE_BACKEND=OFF -DREDIS_STORAGE_BACKEND=OFF

"$CMAKE" --build "$WORK/build" -j 2

CCACHE_BIN="$WORK/build/ccache"
. "$TOOLCHAIN/../scripts/cctools.sh"

echo "### Validate: no dependency on the host's compression libraries"
# ccache reads its manifests through the zstd and zlib it builds in; 10.9's libz is 1.2.5, whose
# gzFile layout differs from the SDK's zlib.h.
linked="$("$CCTOOLS/otool" -L "$CCACHE_BIN")"   # capture first, so a failing otool can't read as a pass
echo "$linked" | grep -qE '/libz\.|/libzstd' && { echo "### FAIL: links a host compression library"; exit 1; } || echo "### bundled zlib and zstd"

echo "### Validate: compiling the same input twice yields a DIRECT cache hit"
export CCACHE_DIR="$WORK/cachedir"
# The probe includes a header so there is an include set to hash into a manifest -- the path
# direct mode takes, and the one worth checking.
printf '#include <stdio.h>\nint f(void){return 41;}\n' > "$WORK/probe.c"
for o in p1.o p2.o; do "$CCACHE_BIN" "$CLANG/bin/clang" --no-default-config -isysroot "$SDK" -c "$WORK/probe.c" -o "$WORK/$o"; done
# The direct counter alone: ccache falls back to preprocessed mode whenever direct mode fails, so a
# total that lumps the two together stays healthy with direct mode dead.
direct=$("$CCACHE_BIN" --print-stats | awk -F'\t' '$1 == "direct_cache_hit" { print $2 }')
[ "${direct:-0}" -ge 1 ] && echo "### direct mode works ($direct hit)" || { echo "### FAIL: no direct cache hit"; "$CCACHE_BIN" -s -v; exit 1; }

echo "### Validate: 10.9-self-sufficient (no post-10.9 imports)"
undefined="$("$CCTOOLS/nm" -u "$CCACHE_BIN")"   # capture first, so a failing nm can't read as a pass
echo "$undefined" | grep -iE 'getentropy|getrandom|clock_gettime|_availability_version_check|os_log' \
    && { echo "### FAIL: post-10.9 symbol"; exit 1; } || echo "### 10.9-clean"

# Install to a separate file before replacing the executable used by active builds.
DESTDIR="$WORK/install" "$CMAKE" --install "$WORK/build"
mkdir -p "$PREFIX/bin"
cp "$WORK/install$PREFIX/bin/ccache" "$PREFIX/bin/ccache.new"
mv -f "$PREFIX/bin/ccache.new" "$PREFIX/bin/ccache"
"$PREFIX/bin/ccache" --version | head -1
echo "### ccache OK -> $PREFIX/bin/ccache"
