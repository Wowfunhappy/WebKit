#!/bin/bash
# build_nasm.sh — build a modern nasm for the libwebrtc/libvpx x86 assembly.
#
# The macOS CommandLineTools nasm is ancient (Apple nasm 0.98) and cannot emit
# macho64 or honor CMake's GNU-style -MD/-MT dependency flags, so the libwebrtc
# build (ENABLE_WEB_RTC=ON) fails on every .asm with "unrecognised output
# format `macho64'" / "more than one input file". nasm 2.16 emits macho64,
# supports -MD/-MT depfiles, and reads @response-files (required because the
# build uses CMAKE_NINJA_FORCE_RESPONSE_FILE=1). The toolchain file
# (mac10.9-toolchain.cmake) points CMAKE_ASM_NASM_COMPILER at the result.
#
# Installs into the toolchain build tree (toolchain/build/nasm, gitignored). All
# paths are relative to this script -- no absolute/user-specific paths.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLCHAIN="$(cd "$HERE/.." && pwd)"
PREFIX="${NASM_PREFIX:-$TOOLCHAIN/build/nasm}"
VERSION=2.16.03
WORK="$(mktemp -d -t nasm-build)"
trap 'rm -rf "$WORK"' EXIT
URL="https://www.nasm.us/pub/nasm/releasebuilds/${VERSION}/nasm-${VERSION}.tar.gz"

echo "### Downloading nasm ${VERSION}"
curl -fsSL -o "$WORK/nasm.tar.gz" "$URL"
tar xzf "$WORK/nasm.tar.gz" -C "$WORK"

cd "$WORK/nasm-${VERSION}"
echo "### Configuring (prefix=$PREFIX)"
./configure --prefix="$PREFIX" > "$WORK/configure.log" 2>&1
echo "### Building"
make -j"$(sysctl -n hw.ncpu)" > "$WORK/make.log" 2>&1
echo "### Installing"
make install > "$WORK/install.log" 2>&1

"$PREFIX/bin/nasm" -v
echo "### Verifying macho64 + -MD support"
printf '' > "$WORK/empty.asm"
"$PREFIX/bin/nasm" -MD "$WORK/dep.d" -f macho64 -o "$WORK/out.o" "$WORK/empty.asm" \
    && echo "### nasm OK: macho64 + -MD work"
