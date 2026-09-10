#!/bin/bash
# Build CMake from source into the toolchain build tree (toolchain/build/cmake,
# gitignored). Built with the in-tree clang. All paths relative to this script.
# The first build is slow (~15 min); CMake bootstraps itself with a plain make.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The one build log: this script routes its own output there, so a bare invocation fills it.
. "$HERE/../../scripts/build-log.sh"
build_log_open
TOOLCHAIN="$(cd "$HERE/.." && pwd)"
CLANG="$TOOLCHAIN/build/clang"
PREFIX="${CMAKE_INSTALL_PREFIX:-$TOOLCHAIN/build/cmake}"
VERSION=3.28.6
# Host tools are C++: clang must find libc++ headers, which live in the SDK. Pass it as
# -isysroot rather than exporting SDKROOT -- the /usr/bin/{make,ar} xcrun shims read SDKROOT
# too, and on a host where Xcode is the selected developer dir they refuse to run when it
# names an SDK Xcode has no record of. That is fatal here (bootstrap and the build below are
# make-driven) but only on such hosts; Command-Line-Tools-only ones tolerate it.
REPO="$(cd "$TOOLCHAIN/../.." && pwd)"
SDK="${MAVERICKS_SDK:-$(dirname "$REPO")/MacOSX26.1.sdk}"
export MACOSX_DEPLOYMENT_TARGET=10.9
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cmake-build.XXXXXX")"
trap 'rc=$?; rm -rf "$WORK"; build_log_report $rc' EXIT

echo "### Downloading CMake $VERSION"
curl -fsSL -o "$WORK/cmake.tar.gz" "https://github.com/Kitware/CMake/releases/download/v${VERSION}/cmake-${VERSION}.tar.gz"
tar xzf "$WORK/cmake.tar.gz" -C "$WORK"
cd "$WORK/cmake-${VERSION}"
# cmake's bundled zlib has a Classic-Mac OS leftover that #defines fdopen to NULL
# when TARGET_OS_MAC is set -- but TargetConditionals.h sets that on modern macOS
# too, which breaks the SDK's real fdopen declaration (_stdio.h: "expected identifier").
# Drop the offending line so fdopen resolves to the SDK's prototype.
/usr/bin/sed -i '' '/define fdopen(fd,mode) NULL/d' Utilities/cmzlib/zutil.h
echo "### Bootstrapping CMake with the in-tree clang (slow)"
CC="$CLANG/bin/clang" CXX="$CLANG/bin/clang++" \
CFLAGS="-isysroot $SDK" CXXFLAGS="-isysroot $SDK" LDFLAGS="-isysroot $SDK" \
    ./bootstrap --prefix="$PREFIX" --parallel="$(sysctl -n hw.ncpu)" \
    -- -DCMAKE_USE_OPENSSL=OFF -DCMAKE_OSX_SYSROOT="$SDK"
make -j"$(sysctl -n hw.ncpu)"
make install
"$PREFIX/bin/cmake" --version | head -1
echo "### cmake OK -> $PREFIX/bin/cmake"
