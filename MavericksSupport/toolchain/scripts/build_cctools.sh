#!/bin/bash
# build_cctools.sh — build the cctools this port reads Mach-O with.
#
# /usr/bin/{otool,lipo,install_name_tool,nm,strip,size,strings,libtool,ar,ranlib} are 14K xcselect
# shims that forward through xcode-select, and /usr/bin/dyldinfo does not exist at all, so a build
# that reaches for them by name gets whatever developer-tools install the machine happens to point
# at. Those ten plus nmedit and dyldinfo are built here, in the toolchain, which is what makes
# every script read the same Mach-O the same way whether or not Xcode is installed.
#
# Installs into the toolchain build tree (toolchain/build/cctools, gitignored). All paths are
# relative to this script -- no absolute/user-specific paths.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The one build log: this script routes its own output there, so a bare invocation fills it.
. "$HERE/../../scripts/build-log.sh"
build_log_open
. "$HERE/../../scripts/host-headers.sh"
TOOLCHAIN="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$TOOLCHAIN/../.." && pwd)"
PREFIX="${CCTOOLS_PREFIX:-$TOOLCHAIN/build/cctools}"
CLANG="$TOOLCHAIN/build/clang"
SHARED="$REPO/MavericksSupport/polyfill/polyfills/shared"
SDK="${MAVERICKS_SDK:-$(dirname "$REPO")/MacOSX26.1.sdk}"
COMMIT=e79d784d667816e4b15a0abd78828f9abb0a0b99
URL="https://github.com/tpoechtrager/cctools-port/archive/${COMMIT}.tar.gz"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cctools-build.XXXXXX")"
trap 'rc=$?; rm -rf "$WORK"; build_log_report $rc' EXIT

echo "### Downloading cctools-port ${COMMIT}"
curl -fsSL -o "$WORK/cctools.tar.gz" "$URL"
tar xzf "$WORK/cctools.tar.gz" -C "$WORK"
SRC="$WORK/cctools-port-${COMMIT}/cctools"

patch -p1 --batch -d "$WORK/cctools-port-${COMMIT}" < "$TOOLCHAIN/patches/cctools-drop-vestigial-blob-clone.patch"

# The C tools compile against the host headers, so they need the same 10.9 gap-fills the rest of
# this port links: open_memstream (10.13+), which libstuff's error paths call, and
# _availability_version_check, which clang's __builtin_available lowering references.
echo "### Building the 10.9 gap-fill shim"
"$CLANG/bin/clang" -c -O2 -mmacosx-version-min=10.9 -I"$SHARED/include" \
    -o "$WORK/open_memstream.o" "$SHARED/open_memstream.c"
"$CLANG/bin/clang" -c -O2 -mmacosx-version-min=10.9 -I"$SHARED/include" \
    -o "$WORK/os_version.o" "$SHARED/os_version.c"
"$CLANG/bin/llvm-ar" rcs "$WORK/libgapshim.a" "$WORK/open_memstream.o" "$WORK/os_version.o"

# dyldinfo is the one C++ tool, and 10.9 ships no libc++ headers, so it reads the same SDK WebKit
# builds against. The gap-fill wrappers are for the host headers and collide with it.
echo "### Configuring cctools"
cd "$SRC"
CC="$CLANG/bin/clang" CXX="$CLANG/bin/clang++" \
CFLAGS="-O2 -mmacosx-version-min=10.9 -I$SHARED/include" \
CXXFLAGS="-O2 -std=c++11 -isysroot $SDK -mmacosx-version-min=10.9 -stdlib=libc++" \
LDFLAGS="-Wl,-force_load,$WORK/libgapshim.a" \
./configure --prefix="$PREFIX" \
    --disable-tapi-support --disable-lto-support --disable-xar-support

# Only the directories holding the tools installed below. A whole-tree make would also build ld,
# whose libcodedirectory.c calls htonll and DISPATCH_APPLY_AUTO, both 10.10+.
echo "### Building cctools"
J="-j$(sysctl -n hw.ncpu)"
make $J -C libstuff
make $J -C libmacho
make $J -C ar
make $J -C misc
make $J -C otool
make $J -C ld64/src/3rd
make $J -C ld64/src/other dyldinfo

# What this port reads and edits Mach-O with, plus the tools the autotools, meson and cmake
# sub-builds resolve off PATH themselves -- this directory is what they find.
echo "### Installing into $PREFIX"
rm -rf "$PREFIX"
mkdir -p "$PREFIX/bin"
install -m 755 otool/otool misc/lipo misc/install_name_tool misc/nm misc/nmedit misc/strip \
        misc/size misc/strings misc/libtool misc/ranlib ar/ar \
        ld64/src/other/dyldinfo "$PREFIX/bin/"

# Every installed tool answers for itself on this host's own Mach-O. A tool that builds but
# cannot run is the failure this whole change exists to stop, so it is caught here.
for t in otool lipo install_name_tool nm nmedit strip size strings libtool ranlib ar dyldinfo; do
    [ -x "$PREFIX/bin/$t" ] || { echo "FATAL: $t did not build"; exit 1; }
done
_probe="$(mktemp -d "${TMPDIR:-/tmp}/cctools_probe.XXXXXX")"
trap 'rc=$?; rm -rf "$WORK" "$_probe"; build_log_report $rc' EXIT
cp /usr/lib/libz.1.dylib "$_probe/lib.dylib"
echo 'int wk_cctools_probe(void) { return 7; }' > "$_probe/p.c"
"$CLANG/bin/clang" -c -mmacosx-version-min=10.9 -o "$_probe/p.o" "$_probe/p.c"

"$PREFIX/bin/lipo"     -info /usr/lib/dyld            > /dev/null
"$PREFIX/bin/otool"    -h /usr/lib/dyld               > /dev/null
"$PREFIX/bin/nm"       -g /usr/lib/libz.1.dylib       > /dev/null
"$PREFIX/bin/dyldinfo" -export /usr/lib/libz.1.dylib  > /dev/null
"$PREFIX/bin/size"     /usr/lib/libz.1.dylib          > /dev/null
"$PREFIX/bin/strings"  /usr/lib/libz.1.dylib          > /dev/null
"$PREFIX/bin/install_name_tool" -id /probe.dylib "$_probe/lib.dylib" > /dev/null
"$PREFIX/bin/nmedit"   -p "$_probe/p.o"
cp /usr/lib/libz.1.dylib "$_probe/strip.dylib"
"$PREFIX/bin/strip"    -x "$_probe/strip.dylib"        > /dev/null
"$PREFIX/bin/ar"       rc "$_probe/lib.a" "$_probe/p.o"
"$PREFIX/bin/ranlib"   "$_probe/lib.a"
"$PREFIX/bin/nm"       -g "$_probe/lib.a" | grep -q wk_cctools_probe
"$PREFIX/bin/libtool"  -static -o "$_probe/lib2.a" "$_probe/p.o" > /dev/null

echo "### cctools ready: $(ls "$PREFIX/bin" | tr '\n' ' ')"
