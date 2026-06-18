#!/bin/bash
# Recompile polyfill_stubs.o from polyfill_stubs.m and swap it into the prebuilt
# libpolyfill.a. The original recipe for libpolyfill.a was lost; this restores a
# reproducible build for the one object we maintain (polyfill_stubs.o), leaving
# the archive's other (also-prebuilt) objects untouched.
#
# polyfill_stubs.m provides MINIMAL @implementations for post-10.9 ObjC classes
# and definitions for missing CF constants / C functions. It must be compiled
# with --no-default-config so the clang wrapper does NOT force-include
# MavericksSupport/compat.h: compat.h now declares full @interfaces for some of
# the same classes (NSTouchBar, NSPresentationIntent, the TouchBar items, …) and
# force-including it would cause duplicate-interface / weak-property errors.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TC="${MAVERICKS_CLANG:-/Users/jonathan/Desktop/Compilers/toolchains/clang-22}"
CLANG="$TC/bin/clang"
AR="$TC/bin/llvm-ar"
SRC="$HERE/polyfill_stubs.m"
LIB="$HERE/prebuilt/libpolyfill.a"
# libpolyfill_classes.a is the SAME compiled object, force-loaded into JavaScriptCore (member name
# polyfill_classes_rebuild.o). Because JSC force-loads it, every symbol polyfill_stubs.m defines must
# be present here too — otherwise JSC pulls polyfill_stubs.o out of libpolyfill.a to satisfy a missing
# one (e.g. _os_log_internal) and its C-function defs collide with the force-loaded copy (duplicate
# symbol). Keep the two archives byte-for-byte in sync by deriving both from this one compile.
LIBC="$HERE/prebuilt/libpolyfill_classes.a"
OBJDIR="$(mktemp -d -t polyfillstubs)"
OBJ="$OBJDIR/polyfill_stubs.o"
OBJC="$OBJDIR/polyfill_classes_rebuild.o"

echo "Compiling $SRC ..."
"$CLANG" -c --no-default-config -mmacosx-version-min=10.9 \
    -Wno-unused-command-line-argument \
    -o "$OBJ" "$SRC"
cp "$OBJ" "$OBJC"

if [ ! -f "$LIB.orig-backup" ]; then
    echo "Backing up original archive -> $LIB.orig-backup"
    cp "$LIB" "$LIB.orig-backup"
fi
if [ ! -f "$LIBC.orig-backup" ]; then
    echo "Backing up original archive -> $LIBC.orig-backup"
    cp "$LIBC" "$LIBC.orig-backup"
fi

echo "Replacing polyfill_stubs.o in $(basename "$LIB") ..."
"$AR" r "$LIB" "$OBJ"
"$AR" s "$LIB" 2>/dev/null || true   # refresh archive symbol index

echo "Replacing polyfill_classes_rebuild.o in $(basename "$LIBC") ..."
"$AR" r "$LIBC" "$OBJC"
"$AR" s "$LIBC" 2>/dev/null || true

echo "Done. Classes now in polyfill_stubs.o:"
nm "$OBJ" | grep -c 'S _OBJC_CLASS_\$_' | sed 's/^/  defined ObjC classes: /'
