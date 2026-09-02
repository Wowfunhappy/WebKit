#!/bin/bash
# Build the Python 3 interpreter WebKit's build-time code generators need (the
# 10.9 system only ships 2.7). Built with the in-tree clang-22 targeting 10.9 so
# it runs on the 10.9 build host. Installs into the toolchain tree
# (toolchain/python3, gitignored; rebuilt by bootstrap.sh). All paths are derived
# relative to this script -- no absolute/user-specific paths.
set -euo pipefail
LOG=/tmp/wk_build.log
# The one build log: this script routes its own output there, so a bare invocation fills it.
exec >> "$LOG" 2>&1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLCHAIN="$(cd "$HERE/.." && pwd)"
CLANG="$TOOLCHAIN/build/clang"
PREFIX="${PYTHON3_PREFIX:-$TOOLCHAIN/build/python3}"
CCDIR="$TOOLCHAIN/build/python3-cc"
VER=3.9.21
SCRATCH="$(mktemp -d -t py3build)"
trap 'rm -rf "$SCRATCH"' EXIT

# Vanilla cc wrapper: the in-tree clang without its forced config, tolerant of the
# legacy C in CPython's configure probes. It lives in the toolchain build tree
# because sysconfig records this path, and the shim below, as the interpreter's
# compiler and link libraries.
mkdir -p "$CCDIR/bin"
printf '#!/bin/sh\nexec "%s/bin/clang" --no-default-config -Wno-implicit-function-declaration -Wno-implicit-int "$@"\n' "$CLANG" > "$CCDIR/bin/cc"
chmod +x "$CCDIR/bin/cc"

# Availability shim: clang lowers __builtin_available to compiler-rt's
# __isPlatformVersionAtLeast, which calls libSystem's _availability_version_check -- 10.15+, so
# absent here. compiler-rt supplies the comparison itself; the only gap is that one symbol, so
# link the polyfill source that defines it (the same one WebKit itself links).
POLYFILL="$TOOLCHAIN/../polyfill"
"$CCDIR/bin/cc" -c -mmacosx-version-min=10.9 -I"$POLYFILL/polyfills/shared/include" \
    -o "$SCRATCH/os_version.o" "$POLYFILL/polyfills/shared/os_version.c"
"$CLANG/bin/llvm-ar" rcs "$CCDIR/libavailshim.a" "$SCRATCH/os_version.o"

rm -rf "$PREFIX"
cd "$SCRATCH"
echo "### Downloading CPython $VER"
curl -fsSLO "https://www.python.org/ftp/python/$VER/Python-$VER.tgz"
tar xf "Python-$VER.tgz"
cd "Python-$VER"
export MACOSX_DEPLOYMENT_TARGET=10.9
export CFLAGS="-O2 -mmacosx-version-min=10.9"
SHIM="-Wl,-force_load,$CCDIR/libavailshim.a"
echo "### Configuring (prefix=$PREFIX)"
# --with-openssl: webkitpy imports `ssl` at module load and the WPT server serves https, so the
# _ssl and _hashlib extension modules have to be there. 10.9's system OpenSSL is 0.9.8, below
# CPython 3.9's 1.0.2 floor, so the toolchain's own static build (build_openssl.sh) supplies it.
OPENSSL="$TOOLCHAIN/build/openssl"
[ -d "$OPENSSL" ] || { echo "### openssl missing at $OPENSSL -- run build_openssl.sh first"; exit 1; }
./configure CC="$CCDIR/bin/cc" --prefix="$PREFIX" --without-ensurepip \
    --with-openssl="$OPENSSL"
echo "### Building + installing"
make -j"$(sysctl -n hw.ncpu)" LIBS="-ldl $SHIM"
make install LIBS="-ldl $SHIM"
echo "=== python3 built ==="
"$PREFIX/bin/python3" --version
"$PREFIX/bin/python3" -c 'import sys; print("ok", sys.version.split()[0])'
"$PREFIX/bin/python3" -c 'import ssl, hashlib; print("ssl", ssl.OPENSSL_VERSION)'
