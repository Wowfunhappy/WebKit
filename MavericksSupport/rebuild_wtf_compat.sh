#!/bin/bash
# Recompile wtf_compat.o from wtf_compat.cpp and swap it into the prebuilt
# libwtf_compat.a (force-loaded into JavaScriptCore). Like libpolyfill, the
# original recipe was lost; this restores a reproducible build for the object we
# maintain (wtf_compat.o), leaving wtf_compat_asm.o (hand asm, no source here)
# untouched.
#
# Compiled with --no-default-config so the clang wrapper does NOT force-include
# MavericksSupport/compat.h (this is a freestanding compat shim that only needs
# system + libc++ headers).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TC="${MAVERICKS_CLANG:-/Users/jonathan/Desktop/Compilers/toolchains/clang-22}"
CLANGXX="$TC/bin/clang++"
AR="$TC/bin/llvm-ar"
SRC="$HERE/wtf_compat.cpp"
LIB="$HERE/prebuilt/libwtf_compat.a"
OBJ="$(mktemp -d -t wtfcompat)/wtf_compat.o"

echo "Compiling $SRC ..."
"$CLANGXX" -c --no-default-config -mmacosx-version-min=10.9 -fblocks -std=c++17 \
    -Wno-unused-command-line-argument \
    -o "$OBJ" "$SRC"

if [ ! -f "$LIB.orig-backup" ]; then
    echo "Backing up original archive -> $LIB.orig-backup"
    cp "$LIB" "$LIB.orig-backup"
fi

echo "Replacing wtf_compat.o in $(basename "$LIB") ..."
"$AR" r "$LIB" "$OBJ"
"$AR" s "$LIB" 2>/dev/null || true

echo "Done. Members now in $(basename "$LIB"):"
"$AR" t "$LIB" | sed 's/^/  /'
