#!/bin/bash
# OpenSSL for the toolchain's Python 3. webkitpy imports `ssl` at module load (webkitcorepy's
# autoinstall), and the WPT server the layout tests run serves https, so the interpreter needs the
# _ssl and _hashlib extension modules. 10.9's system OpenSSL is 0.9.8, which CPython 3.9 refuses
# (it needs 1.0.2 or newer), so the toolchain builds its own.
#
# Static and -fPIC: the two extension modules link it into themselves, which keeps the interpreter
# free of any dylib path or install-name arrangement.
set -euo pipefail
LOG=/tmp/wk_build.log
# The one build log: this script routes its own output there, so a bare invocation fills it.
exec >> "$LOG" 2>&1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLCHAIN="$(cd "$HERE/.." && pwd)"
CLANG="$TOOLCHAIN/build/clang"
PREFIX="${OPENSSL_PREFIX:-$TOOLCHAIN/build/openssl}"
CCDIR="$TOOLCHAIN/build/python3-cc"
VER=3.0.16
SCRATCH="$(mktemp -d -t opensslbuild)"
trap 'rm -rf "$SCRATCH"' EXIT

# The same vanilla cc wrapper build_python3.sh uses: the in-tree clang without its forced config,
# tolerant of the legacy C in OpenSSL's own probes.
mkdir -p "$CCDIR/bin"
printf '#!/bin/sh\nexec "%s/bin/clang" --no-default-config -Wno-implicit-function-declaration -Wno-implicit-int "$@"\n' "$CLANG" > "$CCDIR/bin/cc"
chmod +x "$CCDIR/bin/cc"

rm -rf "$PREFIX"
cd "$SCRATCH"
echo "### Downloading OpenSSL $VER"
curl -fsSLO "https://www.openssl.org/source/openssl-$VER.tar.gz"
tar xf "openssl-$VER.tar.gz"
cd "openssl-$VER"
echo "### Configuring (prefix=$PREFIX)"
CC="$CCDIR/bin/cc" ./Configure darwin64-x86_64-cc no-shared no-tests -fPIC \
    --prefix="$PREFIX" --libdir=lib -mmacosx-version-min=10.9
echo "### Building + installing"
make -s -j"$(sysctl -n hw.ncpu)"
make -s install_sw
echo "=== openssl built ==="
"$PREFIX/bin/openssl" version
