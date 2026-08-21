#!/bin/bash
# Build ccache from source into the toolchain build tree (toolchain/build/ccache,
# gitignored). Built with the in-tree clang. All paths relative to this script.
#
# ccache is a build-time compiler cache. WebKit's Source/cmake/WebKitCCache.cmake auto-enables
# it (RULE_LAUNCH_COMPILE on the Mac port) when find_program(ccache) succeeds at configure time,
# so once this binary is on the build's PATH a reconfigure turns it on. It runs on this 10.9
# host, so it's built -mmacosx-version-min=10.9 (standalone -- no WebKit polyfill).
set -euo pipefail
LOG=/tmp/wk_build.log
# The one build log: this script routes its own output there, so a bare invocation fills it.
exec >> "$LOG" 2>&1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLCHAIN="$(cd "$HERE/.." && pwd)"
CLANG="$TOOLCHAIN/build/clang"
PREFIX="${CCACHE_PREFIX_DIR:-$TOOLCHAIN/build/ccache}"
VERSION=3.7.12
REPO="$(cd "$TOOLCHAIN/../.." && pwd)"
SDK="${MAVERICKS_SDK:-$(dirname "$REPO")/MacOSX26.1.sdk}"
export MACOSX_DEPLOYMENT_TARGET=10.9
# The in-tree clang's default config adds a WebKit link set that confuses autotools probes, so
# use --no-default-config (a plain 10.9 compiler), like the deps build. clang defaults to C23,
# under which ccache's pre-C99 C trips; pin gnu17. The SDK goes in via -isysroot, not SDKROOT:
# the /usr/bin/{make,ar} xcrun shims read SDKROOT too, and where Xcode is the selected
# developer dir they refuse to run when it names an SDK Xcode has no record of ("unable to
# find utility make"). Command-Line-Tools-only hosts tolerate it, so this only breaks on some
# machines; -isysroot reaches the compiler that needs it either way.
PLAIN="--no-default-config -isysroot $SDK -Wno-implicit-function-declaration -Wno-implicit-int"
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

# ccache must use its own zlib, not the host's. The SDK's zlib.h is 1.2.12 and 10.9's
# libz.1.dylib is 1.2.5; zlib.h's gzgetc() is a macro that reaches into struct gzFile_s, which
# only became public in 1.2.6, so that header against that runtime reads the wrong offsets and
# ccache cannot read back the manifests direct mode depends on. The bundled copy compiles from
# the sources its own header describes, so the macro is correct by construction.
# Building it needs the same patch build_cmake.sh applies to cmake's vendored zlib: zlib <= 1.2.11
# #defines fdopen to NULL under TARGET_OS_MAC, which modern TargetConditionals.h also sets, and
# that breaks the SDK's real fdopen declaration.
sed -i '' '/define fdopen(fd,mode) NULL/d' src/zlib/zutil.h

echo "### Configuring (bundled zlib)"
./configure --with-bundled-zlib

echo "### Building"
make -j4

echo "### Validate: no dependency on the host's libz"
linked="$(otool -L ./ccache)"   # capture first, so a failing otool can't read as a pass
echo "$linked" | grep -q libz && { echo "### FAIL: links host libz"; exit 1; } || echo "### no libz"

echo "### Validate: compiling the same input twice yields a DIRECT cache hit"
export CCACHE_DIR="$WORK/cachedir"
# The probe includes a header so there is an include set to hash into a manifest -- the path
# direct mode takes, and the one worth checking.
printf '#include <stdio.h>\nint f(void){return 41;}\n' > probe.c
for o in p1.o p2.o; do ./ccache "$CLANG/bin/clang" $PLAIN -c probe.c -o "$o"; done
./ccache -s | grep -iE "cache hit|cache miss" || true
# Read the direct counter alone. ccache falls back to preprocessed mode whenever direct mode
# fails, so a total that lumps the two together stays healthy with direct mode dead.
direct=$(./ccache -s | awk '/cache hit \(direct\)/{print $NF}')
[ "${direct:-0}" -ge 1 ] && echo "### direct mode works ($direct hit)" || { echo "### FAIL: no direct cache hit"; exit 1; }

echo "### 10.9-self-sufficient? (no post-10.9 imports)"
undefined="$(nm -u ./ccache)"   # capture first, so a failing nm can't read as a pass
echo "$undefined" | grep -iE "getentropy|getrandom|clock_gettime|arc4random" \
    && { echo "### FAIL: post-10.9 symbol"; exit 1; } || echo "### 10.9-clean"

mkdir -p "$PREFIX/bin"
cp ./ccache "$PREFIX/bin/ccache"
"$PREFIX/bin/ccache" --version | head -1
echo "### ccache OK -> $PREFIX/bin/ccache"
