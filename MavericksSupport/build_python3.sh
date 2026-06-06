#!/bin/bash
# Build the Python 3 interpreter that WebKit's build-time code generators need.
# It is a BUILD TOOL (not linked into WebKit), so it installs alongside cmake/
# ninja in the toolchain tools dir rather than in-tree. Built with vanilla
# clang-22 (--no-default-config) targeting 10.9, so it detects the real 10.9
# libc feature set (e.g. falls back off the 10.12+ getentropy) and runs on 10.9.
set -euo pipefail
TC=/Users/jonathan/Desktop/Compilers/toolchains/clang-22
PREFIX=/Users/jonathan/Desktop/Compilers/toolchains/tools/python3
SCRATCH=/Users/jonathan/Desktop/Compilers/depbuild
VER=3.9.21
mkdir -p "$SCRATCH/src" "$SCRATCH/vanilla-bin"
printf '#!/bin/sh\nexec "%s/bin/clang" --no-default-config -Wno-implicit-function-declaration -Wno-implicit-int "$@"\n' "$TC" > "$SCRATCH/vanilla-bin/cc"
chmod +x "$SCRATCH/vanilla-bin/cc"
cd "$SCRATCH/src"
[ -f Python-$VER.tgz ] || curl -fsSLO https://www.python.org/ftp/python/$VER/Python-$VER.tgz
rm -rf Python-$VER && tar xf Python-$VER.tgz && cd Python-$VER
export MACOSX_DEPLOYMENT_TARGET=10.9
export CFLAGS="-O2 -mmacosx-version-min=10.9"
./configure CC="$SCRATCH/vanilla-bin/cc" --prefix="$PREFIX" --without-ensurepip
# Python uses __builtin_available (posix_spawn  10.13); clang emits
# __isPlatformVersionAtLeast, absent on 10.9. Force-load the toolchain availability
# shim at link (LIBS, normally just -ldl) without disturbing configure probes.
SHIM="-Wl,-force_load,$TC/lib/libpolyfill.a"
make -j4 LIBS="-ldl $SHIM"
make install LIBS="-ldl $SHIM"
echo "=== python3 built ==="
"$PREFIX/bin/python3" --version
"$PREFIX/bin/python3" -c 'import sys; print("ok", sys.version.split()[0])'
