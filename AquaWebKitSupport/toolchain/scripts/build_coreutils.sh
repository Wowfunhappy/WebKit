#!/bin/bash
# Build GNU sort for the WebKit configure. Source/WebKit/Scripts/generate-swift-availability-macros,
# which Source/WebKit/PlatformMac.cmake runs at every configure, orders versions with `sort -V`;
# 10.9's /usr/bin/sort is coreutils 5.93, which predates -V. Only sort is built, and build.sh puts
# toolchain/build/coreutils/bin ahead of /usr/bin on PATH. Built with the in-tree clang targeting
# 10.9. Installs into the toolchain build tree (toolchain/build/coreutils, gitignored). All paths
# are relative to this script.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The one build log: this script routes its own output there, so a bare invocation fills it.
. "$HERE/../../scripts/build-log.sh"
build_log_open
. "$HERE/../../scripts/host-headers.sh"
TOOLCHAIN="$(cd "$HERE/.." && pwd)"
CLANG="$TOOLCHAIN/build/clang"
PREFIX="${COREUTILS_PREFIX:-$TOOLCHAIN/build/coreutils}"
VER=9.12
SHA256=14cbf5a4de0c7b7fa3b9fa7fada4c58b2defe33336aa8fd83d7622c5c4ebdc13
WORK="$(mktemp -d "${TMPDIR:-/tmp}/coreutils-build.XXXXXX")"
trap 'rc=$?; rm -rf "$WORK"; build_log_report $rc' EXIT
export MACOSX_DEPLOYMENT_TARGET=10.9

cd "$WORK"
echo "### Downloading coreutils $VER"
curl -fsSLO "https://ftp.gnu.org/gnu/coreutils/coreutils-$VER.tar.gz"
echo "$SHA256  coreutils-$VER.tar.gz" | /usr/bin/shasum -a 256 -c -
tar xzf "coreutils-$VER.tar.gz"
cd "coreutils-$VER"
echo "### Patching"
patch -p1 < "$TOOLCHAIN/patches/coreutils-renameatu-string-h.patch"

echo "### Configuring"
# The compile reads 10.9's own headers; --no-default-config drops the in-tree clang's forced link
# set (libobjc and the base frameworks), so sort links libSystem alone. CFLAGS carries no -g, as
# with the toolchain's other from-source builds: 10.9's dsymutil aborts on clang-22's DWARF.
./configure CC="$CLANG/bin/clang --no-default-config" CFLAGS="-O2" \
    --disable-nls --without-libgmp --without-openssl
echo "### Building sort"
# Automake generates BUILT_SOURCES (gnulib's replacement headers) only ahead of `all`; this goal
# generates them alone, then src/sort builds with just the objects it links.
make -j"$(sysctl -n hw.ncpu)" -f Makefile -f - built-sources <<'EOF'
built-sources: $(BUILT_SOURCES)
EOF
make -j"$(sysctl -n hw.ncpu)" src/sort
rm -rf "$PREFIX"
mkdir -p "$PREFIX/bin"
install -m 755 src/sort "$PREFIX/bin/sort"

"$PREFIX/bin/sort" --version | head -1
[ "$(printf '%s\n' 10.16 10.9 1.10 1.9 | "$PREFIX/bin/sort" -V | tr '\n' ' ')" = "1.9 1.10 10.9 10.16 " ] \
    || { echo "FATAL: $PREFIX/bin/sort -V misorders versions"; exit 1; }
echo "### sort OK -> $PREFIX/bin/sort"
