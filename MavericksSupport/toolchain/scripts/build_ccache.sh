#!/bin/bash
# Build ccache from source into the toolchain build tree (toolchain/build/ccache,
# gitignored). Built with the in-tree clang. All paths relative to this script.
#
# ccache is a build-time compiler cache. WebKit's Source/cmake/WebKitCCache.cmake auto-enables
# it (RULE_LAUNCH_COMPILE on the Mac port) when find_program(ccache) succeeds at configure time,
# so once this binary is on the build's PATH a reconfigure turns it on. It runs on this 10.9
# host, so it's built -mmacosx-version-min=10.9 (standalone -- no WebKit polyfill).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLCHAIN="$(cd "$HERE/.." && pwd)"
CLANG="$TOOLCHAIN/build/clang"
PREFIX="${CCACHE_PREFIX_DIR:-$TOOLCHAIN/build/ccache}"
VERSION=3.7.12
REPO="$(cd "$TOOLCHAIN/../.." && pwd)"
SDK="${MAVERICKS_SDK:-$(dirname "$REPO")/MacOSX26.1.sdk}"
export SDKROOT="$SDK"
export MACOSX_DEPLOYMENT_TARGET=10.9
# The in-tree clang's default config adds a WebKit link set that confuses autotools probes, so
# use --no-default-config (a plain 10.9 compiler), like the deps build. clang defaults to C23,
# under which ccache's pre-C99 C trips; pin gnu17. Build against the SDK's system zlib (the
# ancient zlib bundled in the tarball doesn't parse against the modern SDK headers).
PLAIN='--no-default-config -Wno-implicit-function-declaration -Wno-implicit-int'
export CC="$CLANG/bin/clang $PLAIN -std=gnu17"
export CXX="$CLANG/bin/clang++ $PLAIN"
export CFLAGS="-O2 -mmacosx-version-min=10.9"
export CXXFLAGS="-O2 -mmacosx-version-min=10.9"
WORK="$(mktemp -d -t ccache-build)"
trap 'rm -rf "$WORK"' EXIT

echo "### Downloading ccache $VERSION"
curl -fsSL -o "$WORK/ccache.tar.gz" "https://github.com/ccache/ccache/releases/download/v${VERSION}/ccache-${VERSION}.tar.gz"
tar xzf "$WORK/ccache.tar.gz" -C "$WORK"
cd "$WORK/ccache-${VERSION}"

echo "### Configuring (system zlib from the SDK)"
./configure

echo "### Building"
make -j4

echo "### Validate: compiling the same input twice yields a cache hit"
export CCACHE_DIR="$WORK/cachedir"
printf 'int f(void){return 41;}\n' > probe.c
./ccache "$CLANG/bin/clang" --no-default-config -c probe.c -o p1.o
./ccache "$CLANG/bin/clang" --no-default-config -c probe.c -o p2.o
./ccache -s | grep -iE "cache hit|cache miss" || true
# ccache prints two "cache hit" lines (direct + preprocessed) — sum both, don't read just the first.
hits=$(./ccache -s | awk '/cache hit/{for(i=1;i<=NF;i++)if($i ~ /^[0-9]+$/)s+=$i} END{print s+0}')
[ "${hits:-0}" -ge 1 ] && echo "### cache works ($hits hit)" || { echo "### FAIL: no cache hit"; exit 1; }

echo "### 10.9-self-sufficient? (no post-10.9 imports)"
nm -u ./ccache 2>/dev/null | grep -iE "getentropy|getrandom|clock_gettime|arc4random" \
    && { echo "### FAIL: post-10.9 symbol"; exit 1; } || echo "### 10.9-clean"

mkdir -p "$PREFIX/bin"
cp ./ccache "$PREFIX/bin/ccache"
"$PREFIX/bin/ccache" --version | head -1
echo "### ccache OK -> $PREFIX/bin/ccache"
