#!/bin/bash
# Build the polyfill layer into polyfill/build/ (gitignored). See polyfill/README.md for how the
# layer works and where to add a polyfill; this script is only the build.
#
#   libpolyfill.a          the C functions and data constants
#   libpolyfill_classes.a  the ObjC method polyfills + the selector mechanism
#   libpolyfill_classes.dylib  the ObjC class polyfills (one shared, exported definition each)
#   libwtf_compat.a        WTF compatibility symbols for JavaScriptCore
#   libwk_marker.a         the tag identifying a binary as ours
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"          # polyfill/scripts
POLY="$(cd "$HERE/.." && pwd)"                                 # polyfill
REPO="$(cd "$POLY/../.." && pwd)"                              # repo root
TC="${MAVERICKS_CLANG:-$REPO/MavericksSupport/toolchain/build/clang}"
SDK="${MAVERICKS_SDK:-$(dirname "$REPO")/MacOSX26.1.sdk}"             # libc++ headers for the C++ unit
CLANG="$TC/bin/clang"; AR="$TC/bin/llvm-ar"
PF="$POLY/polyfills"; MECH="$POLY/mechanism"; LEGACY="$POLY/legacy-support"; OUT="$POLY/build"
OBJ="$(mktemp -d -t polybuild)"; trap 'rm -rf "$OBJ"' EXIT
mkdir -p "$OUT"

# --no-default-config so the clang wrapper does NOT force its default link set; these are pure
# object code.
CF='--no-default-config -mmacosx-version-min=10.9 -Wno-unused-command-line-argument'

# HIDDEN is for the libpolyfill.a members only. That archive is force-loaded into WebKit's binaries,
# so its definitions only ever need to satisfy references within the image that pulled them in.
# Keeping them out of the export tables is what confines the layer to WebKit -- nothing else in the
# process can bind to a polyfill by accident -- and it lets a polyfill reach the system
# implementation through a process-wide dlsym without finding itself. (deps/build_deps.sh compiles
# these same sources into the vendored dylibs as private copies for the same reason.)
#
# Deliberately NOT applied to polyfills/classes.m: that one exists to EXPORT one shared definition of
# each absent-on-10.9 ObjC class, which other images bind to via the reexport-and-repoint in
# scripts/stage-frameworks.sh. Hiding there drops the WKMavPolyfillPriv_* class aliases from the dylib's
# export table.
HIDDEN='-fvisibility=hidden'

# The polyfills themselves, plus the two mechanism units that ship alongside them. -I$MECH so a
# polyfill can just #include "wk_polyfill.h".
INC="-I$MECH"
# Some polyfills reference declarations that exist only in the modern SDK (post-10.9 APIs we are
# supplying, and 10.9-present SPI the old headers never declared).
SDKCF="--no-default-config -isysroot $SDK -mmacosx-version-min=10.9 $INC \
    -Wno-unused-command-line-argument -Wno-deprecated-declarations"

echo "### compiling polyfills"
"$CLANG" -c $CF $HIDDEN $INC -o "$OBJ/runtime.o"       "$PF/runtime.m"
"$CLANG" -c $CF $HIDDEN $INC -o "$OBJ/constants.o"     "$PF/constants.m"
"$CLANG" -c $CF $HIDDEN $INC -o "$OBJ/graphics.o"      "$PF/graphics.c"
# The variable-font instancer graphics.c calls is C++ (see wtf-compat.cpp for the same shape): it
# needs the modern SDK's libc++ headers, but it goes into libpolyfill.a with the rest so that the
# one force-loaded archive stays self-contained.
"$TC/bin/clang++" -c --no-default-config -isysroot "$SDK" -mmacosx-version-min=10.9 -std=c++17 -O2 \
    $HIDDEN -Wno-unused-command-line-argument \
    -o "$OBJ/variable-font-instancer.o" "$PF/LegacyCoreTextVariableFontInstancer.cpp"
"$CLANG" -c $SDKCF $HIDDEN    -o "$OBJ/system-spi.o"   "$PF/system-spi.m"
# compression.c decodes/encodes Brotli through the vendored codec headers (the WOFF2 dependency tree).
"$CLANG" -c $SDKCF $HIDDEN -I"$REPO/MavericksSupport/deps/build/include" \
                              -o "$OBJ/compression.o"  "$PF/compression.c"
"$CLANG" -c $CF $INC          -o "$OBJ/classes.o"      "$PF/classes.m"
"$CLANG" -c $SDKCF            -o "$OBJ/methods.o"      "$PF/methods.m"

# The two WebKit-framework-scoped polyfills, archived separately (below) so their ObjC classes are
# registered exactly once, in WebKit.framework alone: libpolyfill_classes.a is force-loaded into WebCore
# and JSC, and adding these there would be a duplicate class registration in every image that links it.
# websocket-109.mm is written against ARC (zeroing __weak, block copy semantics).
"$CLANG" -c $SDKCF            -o "$OBJ/webkit-classes-109.o" "$PF/webkit-classes-109.mm"
"$CLANG" -c $SDKCF -fobjc-arc -o "$OBJ/websocket-109.o"      "$PF/websocket-109.mm"

echo "### compiling mechanism"
"$CLANG" -c $CF $HIDDEN $INC -o "$OBJ/wk_polyfill_runtime.o" "$MECH/wk_polyfill_runtime.c"
"$CLANG" -c $SDKCF            -o "$OBJ/wk_selref_scope.o"    "$MECH/wk_selref_scope.m"
"$CLANG" -c $CF               -o "$OBJ/wk_image_marker.o"    "$MECH/wk_image_marker.c"

echo "### compiling legacy-support (macports-legacy-support: POSIX/libc gap-fills)"
bash "$HERE/build-legacy-polyfills.sh" "$CLANG" "$OBJ/legacy.a" "$OBJ/legacy-obj"
( cd "$OBJ" && "$AR" x legacy.a )    # unpack the legacy objects next to ours

echo "### compiling polyfills/shared (also compiled by the vendored non-WebKit builds)"
# -isysroot /: these are plain C written against the 10.9 host headers, which is what the vendored
# GStreamer/python3 builds compile them with too (deps/build_deps.sh, toolchain/scripts/build_python3.sh).
#
# -DWK_POLYFILL_REGISTERED is the one thing THIS build adds: it lets a shared source declare its
# registry entry (jit.c's mmap override) so WK_POLYFILL_REPORT can see it, while the same file still
# compiles as plain C for the vendored builds, which define nothing and get no registry dependency.
mkdir -p "$OBJ/shared-obj"
for c in "$PF"/shared/*.c; do
    "$CLANG" -c --no-default-config -isysroot / -mmacosx-version-min=10.9 -fPIC $HIDDEN -O2 \
        -DWK_POLYFILL_REGISTERED $INC \
        -o "$OBJ/shared-obj/$(basename "${c%.c}").o" "$c"
done

# ar_stable: write an archive only when its content actually changes, preserving the old file's mtime
# otherwise. build-polyfill.sh runs on every incremental build; regenerating an archive with a fresh mtime
# makes ninja relink every binary that links it — and libpolyfill.a is link_libraries'd into ALL binaries
# including LLIntOffsetsExtractor, whose relink forces the very slow offlineasm LLIntAssembly.h regeneration
# on every build. Keeping the mtime stable when the bytes are identical skips that cascade (llvm-ar is
# deterministic, so unchanged inputs yield byte-identical archives).
ar_stable() {  # $1 = output .a, remaining args = object files
    local out="$1"; shift
    "$AR" rcs "$out.tmp" "$@"
    if [ -f "$out" ] && cmp -s "$out" "$out.tmp"; then
        rm -f "$out.tmp"
    else
        mv -f "$out.tmp" "$out"
    fi
}

# tmp_stable: same mtime-preservation as ar_stable, but for an output produced by an external builder that
# already wrote "$1.tmp". Needed for libpolyfill_classes.dylib: it too is an explicit link input of
# LLIntSettingsExtractor/LLIntOffsetsExtractor, so relinking it with a fresh mtime every build re-triggers the
# slow offlineasm LLIntAssembly.h regeneration ar_stable was added to avoid. The dylib is built from
# polyfill_classes.o (the ObjC class stubs), which changes rarely, and clang -dynamiclib emits a
# content-hashed LC_UUID, so unchanged inputs yield byte-identical output and the swap is skipped.
tmp_stable() {  # $1 = final path; builder already wrote "$1.tmp"
    local out="$1"
    if [ -f "$out" ] && cmp -s "$out" "$out.tmp"; then
        rm -f "$out.tmp"
    else
        mv -f "$out.tmp" "$out"
    fi
}

echo "### libpolyfill.a (C function/constant stubs only — NO ObjC classes)"
# Some SDK headers put an explicit __attribute__((visibility("default"))) on their declarations
# (DISPATCH_EXPORT, OS_EXPORT, ...), and an explicit attribute on the declaration overrides the
# $HIDDEN flag on the definition — the polyfill then lands in every framework's EXPORT table. That
# breaks both halves of the HIDDEN contract above: the process-wide dlsym WK_ORIGINAL performs finds
# the layer's own copy instead of 10.9's implementation (dispatch_get_global_queue crashed every
# WebKit process at launch this way — resolveOriginal rejected the copy as ours, returned NULL, and
# the REPLACES body called through it), and host apps can bind to a polyfill by accident. nmedit -p
# demotes every defined global in the members to private extern — the same state $HIDDEN already put
# the others in — so the attribute cannot punch through. The symbols stay visible to the nm-based
# dup/shadow checks below (private externs are still external in an object file) and still satisfy
# the force_load link's references. ONE list feeds both the demotion and the archive, so a member
# added later cannot skip the demotion and re-export its globals.
LIBPOLYFILL_MEMBERS=("$OBJ/runtime.o" "$OBJ/wk_polyfill_runtime.o" \
    "$OBJ/constants.o" "$OBJ/graphics.o" "$OBJ/variable-font-instancer.o" "$OBJ/system-spi.o" \
    "$OBJ/compression.o" "$OBJ/shared-obj"/*.o "$OBJ/legacy-obj"/*.o)
for o in "${LIBPOLYFILL_MEMBERS[@]}"; do
    nmedit -p "$o"
done
ar_stable "$OUT/libpolyfill.a" "${LIBPOLYFILL_MEMBERS[@]}"
# Belt and braces: fail the build if any archive member still carries an exported (non-private)
# defined global — the launch-crash class the demotion exists to prevent.
leaked=$(/usr/bin/nm -m "$OUT/libpolyfill.a" 2>/dev/null \
    | grep -v 'private external\|undefined\|non-external' | grep 'external' || true)
if [ -n "$leaked" ]; then
    echo "ERROR: libpolyfill.a still EXPORTS these symbols; every framework that force-loads it" >&2
    echo "would re-export them, shadowing the system flat-namespace-wide (see the nmedit note):" >&2
    echo "$leaked" >&2
    exit 1
fi

# In an ordinary archive link two definitions of one symbol are invisible: whichever member the linker
# pulls decides the winner. Force-loading makes them a hard link error instead, so catch them here with
# a clearer message than ld's.
dupes=$(/Library/Developer/CommandLineTools/usr/bin/nm -g "$OUT/libpolyfill.a" 2>/dev/null \
    | awk '$2 ~ /^[TDSB]$/ { print $3 }' | sort | uniq -d)
if [ -n "$dupes" ]; then
    echo "ERROR: libpolyfill.a defines these symbols more than once; force_load makes that a link" >&2
    echo "failure. Keep one definition:" >&2
    echo "$dupes" | sed 's/^/  /' >&2
    exit 1
fi

echo "### libpolyfill_classes.dylib (the ObjC class stubs — ONE shared definition)"
# The polyfilled classes have absent-on-10.9 SYSTEM names (NSScrollingPredominantAxisFilter, UTType,
# CABackdropLayer, NSVisualEffectView, SecKeyProxy, _NSHTTPAlternativeServicesStorage, ...) which WebKit
# references with a two-level-namespace binding to the system framework that owns them in the build SDK
# (AppKit/QuartzCore/Foundation/Security/CFNetwork/CoreServices). On 10.9 those frameworks lack the class.
# This ONE dylib defines all the stubs (so each class is defined exactly once across the loaded images — no
# "Class X is implemented in both ..." ObjC runtime warning). It is also link_libraries'd into every framework
# (WEBKIT_FRAMEWORK in WebKitMacros.cmake), which is enough for the classes the linker happens to resolve
# against it (the AppKit/QuartzCore/Foundation ones). For the classes whose owning framework is linked BEFORE
# this dylib (Security -> SecKeyProxy; CFNetwork -> _NSHTTPAlternativeServices*/_NSHSTSStorage; CoreServices ->
# LSBundleProxy; QuartzCore in some binaries -> CABackdropLayer), the reference instead binds to that system
# framework. To capture those deterministically (CMake link order is not controllable enough), this dylib
# REEXPORTS those four frameworks and scripts/stage-frameworks.sh install_name_tool -change's each WebKit binary's
# dependency on them to this dylib: the class then resolves here, and the framework's real symbols pass through
# the reexport. compatibility_version is set very high so the repointed (Security/... compat 1.0.0) load
# commands are satisfied. The install_name is @rpath/libpolyfill_classes.dylib (self-contained, like every
# other WebKit dylib): the build resolves it from WebKitBuild/Release/lib via each binary's @rpath, and
# stage-frameworks.sh maps that @rpath dep to the absolute in-bundle copy it deploys (no /usr/local anywhere).
#
# -licucore is for NSDateComponentsFormatter: it spells its durations out with the CLDR unit names and
# plural rules in 10.9's ICU, reached through ICU's C API. That is the OS's own libicucore, two-level
# bound, and distinct from the modern ICU deps/build_deps.sh builds.
source "$REPO/MavericksSupport/scripts/reexport-shim.sh"
build_reexport_shim --clang "$CLANG" --out "$OUT/libpolyfill_classes.dylib.tmp" \
    --install-name @rpath/libpolyfill_classes.dylib --compat 9999.0.0 --current 9999.0.0 \
    --cflags "-licucore" \
    --framework CoreFoundation \
    --reexport-framework Foundation --reexport-framework AppKit --reexport-framework QuartzCore --reexport-framework CoreServices \
    --reexport-framework Security --reexport-framework CFNetwork \
    "$OBJ/classes.o"
tmp_stable "$OUT/libpolyfill_classes.dylib"   # preserve mtime when unchanged (see ar_stable / tmp_stable)

echo "### libpolyfill_webkit.a (force-loaded into WebKit ONLY: NSURLSessionWebSocketTask/Message +"
echo "###                          the stub @implementations Safari 9.1.3 binds out of WebKit.framework)"
ar_stable "$OUT/libpolyfill_webkit.a" "$OBJ/webkit-classes-109.o" "$OBJ/websocket-109.o"

echo "### libpolyfill_classes.a (force-loaded into WebCore: selref-scope mechanism + polyfill list)"
# The selref-scope patcher (wk_selref_scope.o) + the polyfill methods (wk_polyfills.o) ship here and are
# force-loaded into WebCore (see Source/WebCore/CMakeLists.txt), so they load early in every rendering
# process and keep the AppKit categories off the setuid-JSC-only path. The class stubs live in
# libpolyfill_classes.dylib (above), not here.
ar_stable "$OUT/libpolyfill_classes.a" "$OBJ/wk_selref_scope.o" "$OBJ/methods.o"

echo "### libwk_marker.a (the __wk_marker tag — force-loaded into every WebKit framework)"
# Marks each framework binary as a WebKit image so wk_selref_scope's patcher rewrites its selrefs.
ar_stable "$OUT/libwk_marker.a" "$OBJ/wk_image_marker.o"

echo "### libwtf_compat.a"
"$TC/bin/clang++" -c --no-default-config -isysroot "$SDK" -mmacosx-version-min=10.9 -fblocks -std=c++17 \
    -Wno-unused-command-line-argument -o "$OBJ/wtf_compat.o" "$PF/wtf-compat.cpp"
"$CLANG" -c --no-default-config -mmacosx-version-min=10.9 \
    -o "$OBJ/wtf_compat_asm.o" "$PF/wtf-compat-asm.s"
# objc-gc.c: Objective-C garbage-collection support (github #118) — rides in the JSC-resident
# archive so it initializes exactly once, in every process that loads any WebKit framework.
"$CLANG" -c $CF $HIDDEN -o "$OBJ/objc-gc.o" "$PF/objc-gc.c"
ar_stable "$OUT/libwtf_compat.a" "$OBJ/wtf_compat.o" "$OBJ/wtf_compat_asm.o" "$OBJ/objc-gc.o"

echo "### polyfill mechanism self-test"
# The guarantee a polyfill author relies on: force_load makes our definition win deterministically, and
# the declared body/value then runs unconditionally -- no runtime forwarding to 10.9, no value-mirroring
# (a gap-fill mistakenly declared for a symbol 10.9 has is caught by the shadow check below, not
# silently corrected). Tested on both sides of the present/absent line, against this runtime.
"$CLANG" --no-default-config -mmacosx-version-min=10.9 -Wall -Wextra -I"$MECH" \
    -o "$OBJ/wk_polyfill_test" "$POLY/tests/wk_polyfill_test.c" "$MECH/wk_polyfill_runtime.c" \
    -framework CoreFoundation -framework CoreGraphics
# A second image carrying its own copy of a polyfill, the way every shipped framework does.
"$CLANG" --no-default-config -mmacosx-version-min=10.9 -dynamiclib -I"$MECH" \
    -o "$OBJ/wk_polyfill_sibling.dylib" "$POLY/tests/wk_polyfill_sibling.c" "$MECH/wk_polyfill_runtime.c" \
    -framework CoreFoundation -framework CoreGraphics
WK_POLYFILL_SIBLING="$OBJ/wk_polyfill_sibling.dylib" "$OBJ/wk_polyfill_test"

# The selector mechanism's dlopen guarantee: a WK_POLYFILL_ADD whose class arrives via dlopen (the
# DDActionsManager/soft-link shape) is installed by the time dlopen returns, with no further image
# load — the drain in wk_image_initializing, not the add-image callback, is what delivers this. The
# probe target must be the purpose-built fixture dylib (libobjc/libSystem deps only, a single-image
# dlopen): a system framework's dlopen cascades further loads whose add-image events rescue even a
# drainless mechanism, making the test vacuous.
"$CLANG" $SDKCF -fno-objc-arc -dynamiclib \
    -o "$OBJ/wk_selref_dlopen_fixture.dylib" "$POLY/tests/wk_selref_dlopen_fixture.m" -lobjc
"$CLANG" $SDKCF -fno-objc-arc \
    -o "$OBJ/wk_selref_dlopen" "$POLY/tests/wk_selref_dlopen.m" "$MECH/wk_selref_scope.m" \
    -framework Foundation -lobjc
"$OBJ/wk_selref_dlopen" "$OBJ/wk_selref_dlopen_fixture.dylib"

# The contentInsets application mechanism (polyfills/scrollview-inset-tile.h, one static definition
# shared by methods.m and this probe): a re-classed scroll view must keep working — and keep applying
# its insets exactly once — with KVO's isa-swizzle stacked on top of the dynamic subclass, and a repeat
# non-zero set must not stack a second subclass. Guards the anchored super-dispatch in the -tile
# override (an object_getClass-derived super send resolves to the KVO-stacked class itself and recurses
# without bound).
"$CLANG" $SDKCF -fno-objc-arc -I"$PF" \
    -o "$OBJ/wk_scrollview_insets" "$POLY/tests/wk_scrollview_insets.m" \
    -framework AppKit -framework Foundation -lobjc
"$OBJ/wk_scrollview_insets"

# Two probes that link the SHIPPED archive and call the polyfilled symbols exactly as WebKit will.
# Linked WITHOUT -force_load: the linker then pulls exactly the archive members that define the
# symbols each probe calls (system-spi.o and the mechanism it needs), rather than the whole layer
# and every vendored dependency the rest of it references. What runs is still the shipped object
# code out of the shipped archive, which is the point.
POLYFILL_PROBE_LIBS="$OUT/libpolyfill.a
    -framework Foundation -framework CoreFoundation -framework Security -framework CoreMedia
    -lsqlite3 -lbsm -lsandbox -lobjc"

# dispatch_activate must resume each object exactly once, and the mark that makes that "once" true
# has to be keyed to the object rather than to its address: dispatch_source_create() returns a
# SUSPENDED source and the allocator recycles addresses immediately, so an address-keyed mark
# silently refuses to resume recycled sources and their timers never fire.
"$CLANG" $SDKCF -fno-objc-arc \
    -o "$OBJ/wk_dispatch_activate" "$POLY/tests/wk_dispatch_activate.m" $POLYFILL_PROBE_LIBS
"$OBJ/wk_dispatch_activate"

# SecTaskCopySigningIdentifier / SecTaskGetCodeSignStatus answer "who is on the other end of this
# connection?" for CodeSigning.mm, and PushClientConnection::create() REJECTS a client whose
# identifier comes back empty — so a stub returning NULL is webpushd refusing every connection, not
# a degraded answer. This probe requires a real identifier for a real process.
"$CLANG" $SDKCF -fno-objc-arc \
    -o "$OBJ/wk_sectask_identity" "$POLY/tests/wk_sectask_identity.m" $POLYFILL_PROBE_LIBS
"$OBJ/wk_sectask_identity"

echo "### shadow check"
# The self-test above covers what the registry guarantees. Plenty of what these archives ship carries
# no registry entry and gets none of it -- legacy-support/src, polyfills/shared, the mechanism itself
# -- and for those force_load just makes our definition win. So ask the running
# 10.9 whether any symbol the layer defines is one it already had, and make the answer be declared.
bash "$HERE/check-polyfill-shadows.sh" "$CLANG"

echo "### done -> $OUT"
ls -la "$OUT"
