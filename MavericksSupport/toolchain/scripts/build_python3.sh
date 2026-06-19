#!/bin/bash
# Build the Python 3 interpreter WebKit's build-time code generators need (the
# 10.9 system only ships 2.7). Built with the in-tree clang-22 targeting 10.9 so
# it runs on the 10.9 build host. Installs into the toolchain tree
# (toolchain/python3, gitignored; rebuilt by bootstrap.sh). All paths are derived
# relative to this script -- no absolute/user-specific paths.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLCHAIN="$(cd "$HERE/.." && pwd)"
CLANG="$TOOLCHAIN/build/clang"
PREFIX="${PYTHON3_PREFIX:-$TOOLCHAIN/build/python3}"
VER=3.9.21
SCRATCH="$(mktemp -d -t py3build)"
trap 'rm -rf "$SCRATCH"' EXIT

# Vanilla cc wrapper: the in-tree clang without its forced config, tolerant of the
# legacy C in CPython's configure probes.
mkdir -p "$SCRATCH/bin"
printf '#!/bin/sh\nexec "%s/bin/clang" --no-default-config -Wno-implicit-function-declaration -Wno-implicit-int "$@"\n' "$CLANG" > "$SCRATCH/bin/cc"
chmod +x "$SCRATCH/bin/cc"

# Availability shim: clang emits __isPlatformVersionAtLeast for __builtin_available,
# which the 10.9 runtime does not provide. This defines it. We build for 10.9, so it
# reports nothing newer than 10.9 as available.
cat > "$SCRATCH/availability_shim.c" <<'EOF'
#include <stdint.h>
int32_t __isPlatformVersionAtLeast(uint32_t platform, uint32_t major,
                                   uint32_t minor, uint32_t subminor) {
    (void)platform; (void)subminor;
    if (major != 10) return major < 10;   /* <10 => yes, >10 => no */
    return minor <= 9;                     /* 10.x available iff x <= 9 */
}
EOF
"$SCRATCH/bin/cc" -c -mmacosx-version-min=10.9 -o "$SCRATCH/availability_shim.o" "$SCRATCH/availability_shim.c"
"$CLANG/bin/llvm-ar" rcs "$SCRATCH/libavailshim.a" "$SCRATCH/availability_shim.o"

cd "$SCRATCH"
echo "### Downloading CPython $VER"
curl -fsSLO "https://www.python.org/ftp/python/$VER/Python-$VER.tgz"
tar xf "Python-$VER.tgz"
cd "Python-$VER"
export MACOSX_DEPLOYMENT_TARGET=10.9
export CFLAGS="-O2 -mmacosx-version-min=10.9"
SHIM="-Wl,-force_load,$SCRATCH/libavailshim.a"
echo "### Configuring (prefix=$PREFIX)"
./configure CC="$SCRATCH/bin/cc" --prefix="$PREFIX" --without-ensurepip >/dev/null
echo "### Building + installing"
make -j"$(sysctl -n hw.ncpu)" LIBS="-ldl $SHIM" >/dev/null
make install LIBS="-ldl $SHIM" >/dev/null
echo "=== python3 built ==="
"$PREFIX/bin/python3" --version
"$PREFIX/bin/python3" -c 'import sys; print("ok", sys.version.split()[0])'
