#!/bin/bash
# Build the polyfill layer into polyfill/build/ (gitignored) and run its gates. See README.md for how the
# layer works and where a polyfill goes; the directory a source sits in decides which product it lands in:
#
#   polyfills/c/        libpolyfill.a           force-loaded into every WebKit image, hidden
#   polyfills/shared/   libpolyfill.a           (also compiled by deps/build_deps.sh and toolchain/scripts/build_python3.sh)
#   polyfills/methods/  libpolyfill_methods.a   force-loaded into WebCore (with the selref-scope mechanism)
#   polyfills/classes/  libpolyfill_classes.dylib   one shared, exported definition of each absent class
#   polyfills/webkit/   libpolyfill_webkit.a    force-loaded into WebKit.framework only
#   polyfills/jsc/      libwtf_compat.a         force-loaded into JavaScriptCore only
#   polyfills/cdm/      libwidevinegap.dylib    loaded by the Widevine CDM, not by WebKit
#   mechanism/          wk_polyfill_runtime.o -> libpolyfill.a; wk_selref_scope.o -> libpolyfill_methods.a;
#                       wk_image_marker.o -> libwk_marker.a (force-loaded into every WebKit framework)
set -euo pipefail
POLY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"          # polyfill
REPO="$(cd "$POLY/../.." && pwd)"
TC="${MAVERICKS_CLANG:-$REPO/MavericksSupport/toolchain/build/clang}"
SDK="${MAVERICKS_SDK:-$(dirname "$REPO")/MacOSX26.1.sdk}"
CLANG="$TC/bin/clang"; CLANGXX="$TC/bin/clang++"; AR="$TC/bin/llvm-ar"
. "$REPO/MavericksSupport/scripts/cctools.sh"; NM="$CCTOOLS/nm"
PF="$POLY/polyfills"; MECH="$POLY/mechanism"; OUT="$POLY/build"
TMECH="$POLY/tests/mechanism"; TBEHAV="$POLY/tests/behaviour"; TGATES="$POLY/tests/gates"
OBJ="$(mktemp -d -t polybuild)"; trap 'rm -rf "$OBJ"' EXIT
mkdir -p "$OUT" "$OBJ"/{c,shared,methods,classes,webkit,jsc,cdm,mech,tests}

# --- bounded-parallel compile queue ------------------------------------------------------------
# Each compile writes its own object; cc_wait marks the point where a batch must have finished before
# something archives or links its objects. Diagnostics are captured per compile and replayed in queue
# order so each unit's warnings arrive together.
CC_JOBS=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
CC_PIDS=""; CC_LOGS=""; CC_RC=0; CC_N=0
_cc_reap() { local pid; set -- $CC_PIDS; pid="$1"; shift; CC_PIDS="$*"; wait "$pid" || CC_RC=1; }
cc_queue() {
    while [ "$(set -- $CC_PIDS; echo $#)" -ge "$CC_JOBS" ]; do _cc_reap; done
    local log="$OBJ/cc.$CC_N.log"; CC_N=$((CC_N + 1)); CC_LOGS="$CC_LOGS $log"
    "$@" > "$log" 2>&1 &
    CC_PIDS="$CC_PIDS $!"
}
cc_wait() {
    local log
    while [ -n "$CC_PIDS" ]; do _cc_reap; done
    for log in $CC_LOGS; do [ -s "$log" ] && cat "$log"; done
    CC_LOGS=""
    [ "$CC_RC" = 0 ] || { echo "### a compile failed (see the diagnostics above)" >&2; exit 1; }
}

# --- flag sets ---------------------------------------------------------------------------------
# --no-default-config: the clang wrapper's cfg carries WebKit's link set; these are pure object code.
# -Wall -Wextra: the diagnostic set WebKit's own build uses, so a defect here surfaces the way one in
# Source/ does.
WARN='-Wall -Wextra -Wno-unused-command-line-argument'
INC="-I$MECH"                                        # so a polyfill can #include "wk_polyfill.h"
HOST="--no-default-config -mmacosx-version-min=10.9 $WARN"                       # the 10.9 host headers
MODERN="--no-default-config -isysroot $SDK -mmacosx-version-min=10.9 -Wno-deprecated-declarations $WARN"
# HIDDEN: libpolyfill.a is force-loaded into WebKit's binaries, so its definitions only ever need to
# satisfy references within the image that pulled them in. Keeping them out of the export tables confines
# the layer to WebKit -- nothing else in the process can bind to a polyfill by accident -- and lets a
# polyfill reach the system implementation through a process-wide dlsym without finding itself.
HIDDEN='-fvisibility=hidden'

# --- compile -----------------------------------------------------------------------------------
echo "### compiling polyfills/c (every WebKit image)"
# -I deps/build/include: libcompression.c decodes Brotli through the vendored codec headers.
CINC="$INC -I$REPO/MavericksSupport/deps/build/include"
for f in "$PF"/c/*.c "$PF"/c/*.m; do
    [ -e "$f" ] || continue
    cc_queue "$CLANG" -c $MODERN $HIDDEN $CINC -o "$OBJ/c/$(basename "${f%.*}").o" "$f"
done
for f in "$PF"/c/*.cpp; do
    [ -e "$f" ] || continue
    cc_queue "$CLANGXX" -c $MODERN $HIDDEN $INC -std=c++17 -O2 -o "$OBJ/c/$(basename "${f%.*}").o" "$f"
done

echo "### compiling polyfills/shared (also compiled by the vendored non-WebKit builds)"
# Plain C written against the 10.9 host headers, which is what deps/build_deps.sh and build_python3.sh
# compile them with too. -DWK_POLYFILL_REGISTERED lets a shared source declare a registry entry under
# #ifdef, which only this build defines, so those builds gain no dependency on the registry.
SHAREDCF="--no-default-config -isysroot / -mmacosx-version-min=10.9 -fPIC -O2 $WARN -I$PF/shared/include"
for f in "$PF"/shared/*.c; do
    cc_queue "$CLANG" -c $SHAREDCF $HIDDEN -DWK_POLYFILL_REGISTERED $INC -o "$OBJ/shared/$(basename "${f%.c}").o" "$f"
done

echo "### compiling polyfills/methods (WebCore)"
for f in "$PF"/methods/*.m; do
    cc_queue "$CLANG" -c $MODERN $INC -o "$OBJ/methods/$(basename "${f%.m}").o" "$f"
done

echo "### compiling polyfills/classes (one shared definition each)"
# Exported: other images bind to these classes through the reexport-and-repoint in
# scripts/stage-frameworks.sh, and hiding would drop the WKMavPolyfillPriv_* aliases from the export table.
for f in "$PF"/classes/*.m; do
    cc_queue "$CLANG" -c $HOST $INC -o "$OBJ/classes/$(basename "${f%.m}").o" "$f"
done

echo "### compiling polyfills/webkit (WebKit.framework only)"
for f in "$PF"/webkit/*.mm; do
    cc_queue "$CLANG" -c $MODERN $INC -fobjc-arc -o "$OBJ/webkit/$(basename "${f%.mm}").o" "$f"
done

echo "### compiling polyfills/jsc (JavaScriptCore only)"
for f in "$PF"/jsc/*.cpp; do
    cc_queue "$CLANGXX" -c $MODERN -fblocks -std=c++17 -o "$OBJ/jsc/$(basename "${f%.cpp}").o" "$f"
done
for f in "$PF"/jsc/*.s; do
    cc_queue "$CLANG" -c $HOST -o "$OBJ/jsc/$(basename "${f%.s}").o" "$f"
done

echo "### compiling mechanism"
cc_queue "$CLANG" -c $HOST $HIDDEN $INC -o "$OBJ/mech/wk_polyfill_runtime.o" "$MECH/wk_polyfill_runtime.c"
cc_queue "$CLANG" -c $MODERN $INC        -o "$OBJ/mech/wk_selref_scope.o"    "$MECH/wk_selref_scope.m"
cc_queue "$CLANG" -c $HOST               -o "$OBJ/mech/wk_image_marker.o"    "$MECH/wk_image_marker.c"

echo "### compiling polyfills/cdm (the Widevine CDM's libSystem gap library)"
# Exported (no HIDDEN): another image binds to these. getentropy and aligned_alloc are the layer's own
# shared sources, compiled a second time with their exports intact.
CDMCF="--no-default-config -isysroot / -mmacosx-version-min=10.9 -fPIC -O2 $WARN -I$PF/shared/include"
cc_queue "$CLANG" -c $CDMCF -o "$OBJ/cdm/getentropy.o"    "$PF/shared/getentropy.c"
cc_queue "$CLANG" -c $CDMCF -o "$OBJ/cdm/aligned_alloc.o" "$PF/shared/aligned_alloc.c"
for f in "$PF"/cdm/*.c; do
    cc_queue "$CLANG" -c $CDMCF -o "$OBJ/cdm/$(basename "${f%.c}").o" "$f"
done
cc_wait

# --- archives ----------------------------------------------------------------------------------
# ar_stable / tmp_stable: write an output only when its content changes, keeping the old mtime otherwise.
# This runs on every incremental build, and libpolyfill.a / libpolyfill_classes.dylib are link inputs of
# LLIntOffsetsExtractor, whose relink forces the slow offlineasm LLIntAssembly.h regeneration; llvm-ar and
# clang -dynamiclib (content-hashed LC_UUID) are deterministic, so unchanged inputs yield identical bytes.
ar_stable() {  # $1 = output .a, remaining args = object files
    local out="$1"; shift
    "$AR" rcs "$out.tmp" "$@"
    tmp_stable "$out"
}
tmp_stable() {  # $1 = final path; the builder already wrote "$1.tmp"
    if [ -f "$1" ] && cmp -s "$1" "$1.tmp"; then rm -f "$1.tmp"; else mv -f "$1.tmp" "$1"; fi
}

echo "### libpolyfill.a"
# Some SDK headers put an explicit visibility("default") on their declarations (DISPATCH_EXPORT, OS_EXPORT),
# which overrides $HIDDEN on the definition and lands the polyfill in every framework's export table --
# where the process-wide dlsym WK_ORIGINAL performs finds the layer's own copy instead of 10.9's. nmedit -p
# demotes every defined global in the members to private extern; the symbols stay visible to the nm-based
# checks below and still satisfy the force_load link. One list feeds both the demotion and the archive.
LIBPOLYFILL_MEMBERS=("$OBJ"/c/*.o "$OBJ/mech/wk_polyfill_runtime.o" "$OBJ"/shared/*.o)
for o in "${LIBPOLYFILL_MEMBERS[@]}"; do "$CCTOOLS/nmedit" -p "$o"; done
ar_stable "$OUT/libpolyfill.a" "${LIBPOLYFILL_MEMBERS[@]}"
leaked=$($NM -m "$OUT/libpolyfill.a" | grep -v 'private external\|undefined\|non-external' \
    | grep 'external' || true)
if [ -n "$leaked" ]; then
    echo "ERROR: libpolyfill.a still EXPORTS these symbols; every framework that force-loads it would" >&2
    echo "re-export them, shadowing the system flat-namespace-wide:" >&2
    echo "$leaked" >&2
    exit 1
fi
# Force-loading turns two definitions of one symbol into a hard link error; catch them here.
dupes=$($NM -g "$OUT/libpolyfill.a" 2>/dev/null | awk '$2 ~ /^[TDSB]$/ { print $3 }' | sort | uniq -d)
if [ -n "$dupes" ]; then
    echo "ERROR: libpolyfill.a defines these symbols more than once; force_load makes that a link failure:" >&2
    echo "$dupes" | sed 's/^/  /' >&2
    exit 1
fi

echo "### libpolyfill_classes.dylib"
# The polyfilled classes have absent-on-10.9 SYSTEM names, which WebKit references with a two-level
# binding to the framework that owns them in the build SDK. This one dylib defines every stub (each class
# defined exactly once across the loaded images) and is link_libraries'd into every framework, which
# resolves the classes the linker reaches it for (AppKit/QuartzCore/Foundation). For classes whose owning
# framework is linked BEFORE this dylib (Security -> SecKeyProxy; CFNetwork -> _NSHTTPAlternativeServices*;
# CoreServices -> LSBundleProxy; QuartzCore in some binaries -> CABackdropLayer) the dylib REEXPORTS those
# frameworks and scripts/stage-frameworks.sh repoints each WebKit binary's dependency on them to it, so the
# class resolves here and the framework's real symbols pass through. compatibility_version is very high so
# the repointed load commands are satisfied; the install name is @rpath (self-contained, mapped to the
# in-bundle copy by staging). -licucore is for NSDateComponentsFormatter, which spells its durations out
# through 10.9's own ICU. -headerpad_max_install_names leaves room for the long absolute in-bundle install
# name staging stamps on it.
"$CLANG" --no-default-config -mmacosx-version-min=10.9 -dynamiclib -Wl,-headerpad_max_install_names \
    -install_name @rpath/libpolyfill_classes.dylib -compatibility_version 9999.0.0 -current_version 9999.0.0 \
    -licucore -framework CoreFoundation \
    -Wl,-reexport_framework,Foundation -Wl,-reexport_framework,AppKit -Wl,-reexport_framework,QuartzCore \
    -Wl,-reexport_framework,CoreServices -Wl,-reexport_framework,Security -Wl,-reexport_framework,CFNetwork \
    "$OBJ"/classes/*.o -o "$OUT/libpolyfill_classes.dylib.tmp"
tmp_stable "$OUT/libpolyfill_classes.dylib"

echo "### libpolyfill_methods.a"
# The selref-scope patcher plus the method polyfills, force-loaded into WebCore so they load early in every
# rendering process and the AppKit categories stay off the setuid-JSC path.
ar_stable "$OUT/libpolyfill_methods.a" "$OBJ/mech/wk_selref_scope.o" "$OBJ"/methods/*.o

echo "### libpolyfill_webkit.a"
# Archived apart from the WebCore archive so its ObjC classes register once, in WebKit.framework alone.
ar_stable "$OUT/libpolyfill_webkit.a" "$OBJ"/webkit/*.o

echo "### libwk_marker.a"
ar_stable "$OUT/libwk_marker.a" "$OBJ/mech/wk_image_marker.o"

echo "### libwtf_compat.a"
ar_stable "$OUT/libwtf_compat.a" "$OBJ"/jsc/*.o

echo "### libwidevinegap.dylib"
# Installed beside the downloaded module by WebKit's WidevineCdmInstaller, which is also what points the
# module at it.
"$CLANG" --no-default-config -isysroot / -mmacosx-version-min=10.9 -dynamiclib \
    -install_name @loader_path/libwidevinegap.dylib "$OBJ"/cdm/*.o -o "$OUT/libwidevinegap.dylib.tmp"
tmp_stable "$OUT/libwidevinegap.dylib"

# --- self-tests --------------------------------------------------------------------------------
echo "### polyfill mechanism self-tests"
T="$OBJ/tests"
# The guarantee a polyfill author relies on: force_load makes our definition win deterministically and the
# declared body/value runs unconditionally, tested on both sides of the present/absent line against this
# runtime, with a second image carrying its own copy of a polyfill the way every shipped framework does.
"$CLANG" $HOST $INC -o "$T/wk_polyfill_test" "$TMECH/wk_polyfill_test.c" "$MECH/wk_polyfill_runtime.c" \
    -framework CoreFoundation -framework CoreGraphics
"$CLANG" $HOST $INC -dynamiclib -o "$T/wk_polyfill_sibling.dylib" "$TMECH/wk_polyfill_sibling.c" \
    "$MECH/wk_polyfill_runtime.c" -framework CoreFoundation -framework CoreGraphics
WK_POLYFILL_SIBLING="$T/wk_polyfill_sibling.dylib" "$T/wk_polyfill_test"
# The selector mechanism's dlopen guarantee: a WK_POLYFILL_ADD whose class arrives via dlopen is installed
# by the time dlopen returns, with no further image load. The fixture is a single-image dylib (libobjc/
# libSystem deps only): a system framework's dlopen cascades loads whose add-image events would rescue even
# a drainless mechanism.
"$CLANG" $MODERN $INC -fno-objc-arc -dynamiclib -o "$T/wk_selref_dlopen_fixture.dylib" "$TMECH/wk_selref_dlopen_fixture.m" -lobjc
"$CLANG" $MODERN $INC -fno-objc-arc -o "$T/wk_selref_dlopen" "$TMECH/wk_selref_dlopen.m" "$MECH/wk_selref_scope.m" -framework Foundation -lobjc
"$T/wk_selref_dlopen" "$T/wk_selref_dlopen_fixture.dylib"
# The contentInsets mechanism (methods/scrollview-inset-tile.h): a re-classed scroll view keeps working, and
# applies its insets exactly once, with KVO's isa-swizzle stacked on the dynamic subclass.
"$CLANG" $MODERN $INC -fno-objc-arc -I"$PF/methods" -o "$T/scrollview_insets" "$TBEHAV/AppKit-scrollview-insets.m" \
    -framework AppKit -framework Foundation -lobjc
"$T/scrollview_insets"
# Probes that link the SHIPPED archive (without -force_load, so only the members they reach are pulled)
# and call the polyfilled symbols exactly as WebKit will.
PROBE_LIBS="$OUT/libpolyfill.a -framework Foundation -framework CoreFoundation -framework Security -framework CoreMedia -lsqlite3 -lbsm -lsandbox -lobjc"
"$CLANG" $MODERN $INC -fno-objc-arc -o "$T/dispatch_activate" "$TBEHAV/libSystem-dispatch.m" $PROBE_LIBS
"$T/dispatch_activate"
"$CLANG" $MODERN $INC -fno-objc-arc -o "$T/sectask_identity" "$TBEHAV/Security-sectask.m" $PROBE_LIBS
"$T/sectask_identity"
"$CLANG" $MODERN $INC -o "$T/timebase" "$TBEHAV/libSystem-timebase.c" $PROBE_LIBS
"$T/timebase"
"$CLANG" $MODERN $INC -Wno-unguarded-availability-new -o "$T/unfair_lock" "$TBEHAV/libSystem-unfair-lock.c" $PROBE_LIBS
"$T/unfair_lock"
# -lc++: realizing a font reaches the variable-font instancer, which is C++.
"$CLANG" $MODERN $INC -o "$T/optical_size" "$TBEHAV/CoreText-optical-size.c" $PROBE_LIBS \
    -framework CoreText -framework CoreGraphics -lc++
"$T/optical_size"
"$CLANG" $MODERN $INC -o "$T/face_selection" "$TBEHAV/CoreText-face-selection.c" $PROBE_LIBS \
    -framework CoreText -framework CoreGraphics -lc++
"$T/face_selection"
"$CLANG" $MODERN $INC -o "$T/font_provenance" "$TBEHAV/CoreText-font-provenance.c" $PROBE_LIBS \
    -framework CoreText -framework CoreGraphics -lc++
"$T/font_provenance"
"$CLANG" $MODERN $INC -o "$T/feature_clear" "$TBEHAV/CoreText-feature-clear.c" $PROBE_LIBS \
    -framework CoreText -framework CoreGraphics -lc++
"$T/feature_clear"
# The 10.9 host headers, not the modern SDK's: AudioUnit* live in AudioUnit.framework here and in
# AudioToolbox from 10.10 on, so only these headers put the probe's references where this OS has them.
"$CLANG" $HOST -Wno-deprecated-declarations $INC -o "$T/audiounit_max_frames" "$TBEHAV/AudioUnit-max-frames.c" \
    $PROBE_LIBS -framework AudioUnit -framework CoreAudio
"$T/audiounit_max_frames"

# --- shadow gates ------------------------------------------------------------------------------
# Every polyfill's body runs unconditionally: force_load makes our definition win, the selref rewrite sends
# WebKit's `foo` to `wk_foo`, and there is no runtime forwarding to 10.9. So a polyfill written for a symbol,
# method or class 10.9 actually HAS silently replaces the working system one. These gates ask this
# machine's runtime (dlopen/dlsym and the ObjC runtime, not the modern SDK's stubs) whether anything the
# layer defines is something 10.9 already provides, and require the answer to be declared: WK_POLYFILL_REPLACES
# / WK_POLYFILL_SEL_REPLACES, or delete it. There is no allowlist. Plain-C units with no registry entry
# (shared/, the mechanism) are held to the same rule. Probe programs: tests/gates/.
echo "### shadow gates"
W="$OBJ/shadow"; mkdir -p "$W/members"
# The 10.9 images a WebKit binary's references can bind against. Not AVFoundation: on 10.9 dlsym(handle) walks
# the whole dependency tree, and AVFoundation drags in CoreWiFi, whose PRIVATE clock_gettime copy would
# false-positive symbols no real two-level bind could reach (the layer's AVFoundation additions are classes,
# covered by the class gate).
SYSTEM_LIBS="/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics
/System/Library/Frameworks/CoreText.framework/CoreText
/System/Library/Frameworks/QuartzCore.framework/QuartzCore
/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation
/System/Library/Frameworks/Foundation.framework/Foundation
/System/Library/Frameworks/AppKit.framework/AppKit
/System/Library/Frameworks/Security.framework/Security
/System/Library/Frameworks/CFNetwork.framework/CFNetwork
/System/Library/Frameworks/CoreServices.framework/CoreServices
/System/Library/Frameworks/ImageIO.framework/ImageIO
/System/Library/Frameworks/IOKit.framework/IOKit
/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration
/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox
/System/Library/Frameworks/AudioUnit.framework/AudioUnit
/System/Library/Frameworks/CoreAudio.framework/CoreAudio
/System/Library/Frameworks/CoreMedia.framework/CoreMedia
/System/Library/Frameworks/CoreVideo.framework/CoreVideo
/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices
/System/Library/Frameworks/Accelerate.framework/Accelerate
/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox
/System/Library/Frameworks/MediaAccessibility.framework/MediaAccessibility
/System/Library/PrivateFrameworks/TCC.framework/TCC
/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI
/System/Library/PrivateFrameworks/DataDetectorsCore.framework/DataDetectorsCore
/System/Library/Frameworks/Quartz.framework/Frameworks/PDFKit.framework/PDFKit
/usr/lib/libSystem.B.dylib
/usr/lib/libobjc.A.dylib
/usr/lib/libsqlite3.dylib
/usr/lib/libz.dylib
/usr/lib/libsandbox.1.dylib
/usr/lib/system/libsystem_sandbox.dylib"
# The method probes also need the frameworks owning the classes the categories extend.
OBJC_LIBS="$SYSTEM_LIBS
/System/Library/Frameworks/AVFoundation.framework/AVFoundation
/System/Library/Frameworks/CoreLocation.framework/CoreLocation"
# DataDetectors (owns DDActionsManager) cannot join the lists above: it links the stock WebKit install paths
# -- on this machine the installed backport, carrying the force-loaded layer, whose exports would then look
# like 10.9's -- and its transitive closure adds categories that flip other rows' answers (ISSupport adds
# -[NSString containsString:]). So it joins a SECOND presence pass in a separate process whose answers are
# used ONLY for rows the first pass could not load the class for.
PROBE_ONLY_LIBS="/System/Library/PrivateFrameworks/DataDetectors.framework/DataDetectors"

# What the layer defines: strong (T/D/S/B) globals of every product force-loaded into a WebKit binary.
for lib in libpolyfill.a libpolyfill_methods.a libpolyfill_classes.dylib libwtf_compat.a libwk_marker.a libpolyfill_webkit.a; do
    $NM -g "$OUT/$lib" 2>/dev/null | awk -v lib="$lib" '$2 ~ /^[TDSB]$/ { sub(/^_/, "", $3); print $3 "\t" lib }'
done | sort -u > "$W/defined"
cut -f1 "$W/defined" | sort -u > "$W/names"
# What 10.9 has, and what the registry declares.
"$CLANG" $HOST -o "$W/present" "$TGATES/shadow-present.c"
"$W/present" $SYSTEM_LIBS < "$W/names" | sort -u > "$W/on109"
# -undefined dynamic_lookup: the registry probe reads the section and calls no polyfill, so it must not need
# a link line that grows with every framework function a body references.
"$CLANG" $HOST $INC -o "$W/registry" "$TGATES/shadow-registry.c" \
    -Wl,-force_load,"$OUT/libpolyfill.a" -Wl,-undefined,dynamic_lookup $SYSTEM_LIBS
"$W/registry" | sort -u > "$W/registry.tsv"
awk -F'\t' '$2 == "REPLACES" { print $1 }' "$W/registry.tsv" | sort -u > "$W/replaces"

# --- shared-state gate -------------------------------------------------------------------------
# polyfills/shared/ is force-loaded into every media dylib AND into each of WebKit's frameworks, and
# polyfills/c/ into each of the frameworks, so the process holds many copies of each of these files. An exported DATA symbol is how one copy would try
# to reach another copy's state, and it cannot: the framework link makes the symbol local again, so
# dlsym answers with whichever copy an unrelated load order put first. State a shared/ file keeps for
# itself is therefore per-image however it is named. The data these files are allowed to export is the
# kind the registry declares a CONSTANT -- an absent CFStringRef and its friends, written once and read
# by anyone. Anything else is state, and belongs on the object it describes, where the system owns the
# association.
echo "### shared-state gate"
awk -F'\t' '$3 == "CONSTANT" { print $1 }' "$W/registry.tsv" | sort -u > "$W/constants"
# C (common) belongs with D/S/B: a tentative definition is exported shared data too.
# polyfills/c/ is force-loaded into each of WebKit's four frameworks, so its members are multiply
# instantiated for the same reason and are held to the same rule. Both are compiled exactly as they
# ship -- $HIDDEN included -- so only data a file deliberately exports is scored.
SHARED_DATA="$W/shared_data"; : > "$SHARED_DATA"
{
    for src in "$PF"/shared/*.c; do
        obj="$W/sharedgate_shared_$(basename "${src%.c}").o"
        "$CLANG" $SHAREDCF $HIDDEN -DWK_POLYFILL_REGISTERED $INC -c -o "$obj" "$src" || exit 1
        "$NM" -g "$obj" | awk -v f="shared/$(basename "$src")" '$2 ~ /^[DSBC]$/ \
            { sub(/^_/, "", $3); print $3 "\t" f }'
    done
    for src in "$PF"/c/*.c "$PF"/c/*.m; do
        obj="$W/sharedgate_c_$(basename "${src%.*}").o"
        "$CLANG" $MODERN $HIDDEN $CINC -c -o "$obj" "$src" || exit 1
        "$NM" -g "$obj" | awk -v f="c/$(basename "$src")" '$2 ~ /^[DSBC]$/ \
            { sub(/^_/, "", $3); print $3 "\t" f }'
    done
} | sort -u > "$SHARED_DATA"
join -t"$(printf '\t')" -v1 -1 1 -2 1 "$SHARED_DATA" "$W/constants" > "$W/shared_state_offenders"
if [ -s "$W/shared_state_offenders" ]; then
    echo "ERROR: a force-loaded polyfill exports data the registry does not declare a CONSTANT."
    echo "Every image that force-loads it gets its own copy and no copy can reach another's, so this"
    echo "is per-image state however it is named:"
    awk -F'\t' '{ printf "  %-40s %s\n", $2, $1 }' "$W/shared_state_offenders"
    echo "Keep it on the object it describes -- an AudioUnit property listener, a CFTypeRef"
    echo "association -- so the system owns the association, or declare it WK_POLYFILL_CONSTANT."
    exit 1
fi
echo "  shared-state gate: clean -- $(ls "$PF"/shared/*.c "$PF"/c/*.c "$PF"/c/*.m | wc -l | tr -d ' ') force-loaded sources, $(wc -l < "$SHARED_DATA" | tr -d ' ') exported data symbol(s), all declared CONSTANT"

# Presence is asked of the EXACT linker symbol (an ABI-variant spelling such as syslog$DARWIN_EXTSN or
# fdopendir$INODE64 is its own symbol); for the registry match the variant suffix is stripped, since a
# registry entry names the C function while the suffix comes from an asm label on it. OBJC_ names keep
# their $.
cut -f1 "$W/on109" | sort -u > "$W/present_names"
awk 'NR == FNR { accounted[$0] = 1; next }
     { base = $0
       if ($0 !~ /^OBJC_/ && match($0, /\$[A-Z][A-Z0-9_]*$/)) base = substr($0, 1, RSTART - 1)
       if (!($0 in accounted) && !(base in accounted)) print $0 }' "$W/replaces" "$W/present_names" > "$W/offenders"
if [ -s "$W/offenders" ]; then
    {
        echo
        echo "ERROR: the polyfill layer defines symbols the 10.9 runtime ALREADY provides, and nothing says so."
        echo "force_load makes our definition win with no forwarding to 10.9, so WebKit silently gets ours:"
        echo
        while read -r symbol; do
            origins=$(awk -F'\t' -v s="$symbol" '$1 == s { printf "%s ", $2 }' "$W/defined")
            provider=$(awk -F'\t' -v s="$symbol" '$1 == s { print $2 }' "$W/on109")
            printf '  %-44s defined in %s(10.9 has it in %s)\n' "$symbol" "$origins" "$provider"
        done < "$W/offenders"
        echo
        echo "If shadowing 10.9 is the POINT, declare it WK_POLYFILL_REPLACES (see README.md); otherwise delete"
        echo "the definition and let WebKit bind 10.9's symbol."
    } >&2
    exit 1
fi

# ObjC methods: one program force-loads the method polyfills (WITHOUT wk_selref_scope.o, whose constructor
# would install wk_ entry points on every class that has the real method -- the fact being measured) to read
# the registry and see which class each private selector lands on; a second, with nothing of the layer
# linked, asks 10.9 whether that class already implements the public selector.
( cd "$W/members" && "$AR" x "$OUT/libpolyfill_methods.a" && rm -f wk_selref_scope.o )
"$CLANG" $HOST $INC -o "$W/selregistry" "$TGATES/shadow-selregistry.m" \
    $(for o in "$W"/members/*.o; do printf -- '-Wl,-force_load,%s ' "$o"; done) "$OUT/libpolyfill.a" \
    -Wl,-undefined,dynamic_lookup -lobjc $OBJC_LIBS
"$W/selregistry" > "$W/selregistry.raw"
grep '^ADDMAP' "$W/selregistry.raw" | cut -f2- | sort -u > "$W/addmap.tsv" || true
grep -v '^ADDMAP' "$W/selregistry.raw" | sort -u > "$W/selregistry.tsv"
"$CLANG" $HOST -o "$W/selpresent" "$TGATES/shadow-selpresent.m" -lobjc
awk -F'\t' '$4 != "-" { print $4 "\t" $5 "\t" $1 "\t" $6 }' "$W/selregistry.tsv" \
    | "$W/selpresent" $OBJC_LIBS | sort -u > "$W/selon109.base"
awk -F'\t' '$4 != "-" { print $4 "\t" $5 "\t" $1 "\t" $6 }' "$W/selregistry.tsv" \
    | "$W/selpresent" $OBJC_LIBS $PROBE_ONLY_LIBS | sort -u > "$W/selon109.ext"
awk -F'\t' 'NR == FNR { ext[$1 FS $2 FS $3] = $0; next }
            $4 == "NOCLASS" && (($1 FS $2 FS $3) in ext) { print ext[$1 FS $2 FS $3]; next }
            { print }' "$W/selon109.ext" "$W/selon109.base" | sort -u > "$W/selon109"
: > "$W/seloffenders"; : > "$W/seldead"; : > "$W/selnoclass"
while IFS=$'\t' read -r pub priv intent cls side image; do
    if [ "$cls" = "-" ]; then printf '%s\t%s\n' "$pub" "$priv" >> "$W/seldead"; continue; fi
    [ "$side" = "class" ] && sigil=+ || sigil=-
    verdict=$(awk -F'\t' -v c="$cls" -v s="$side" -v p="$pub" '$1 == c && $2 == s && $3 == p { print $4 "\t" $5 }' "$W/selon109")
    state=${verdict%%$'\t'*}; owner=${verdict#*$'\t'}
    if [ "$state" = "NOCLASS" ]; then printf '%s\t%s\t%s\n' "$cls" "$pub" "$priv" >> "$W/selnoclass"; continue; fi
    [ "$state" = "PRESENT" ] || continue
    [ "$intent" = "REPLACES" ] && continue
    printf '%s\t%s\t%s\t%s\n' "$sigil[$cls $pub]" "$priv" "$cls" "$owner" >> "$W/seloffenders"
done < "$W/selregistry.tsv"
if [ -s "$W/selnoclass" ]; then
    {
        echo
        echo "ERROR: the presence probe could not load these polyfilled methods' classes, so whether 10.9"
        echo "implements them was NEVER CHECKED:"
        echo
        while IFS=$'\t' read -r cls pub priv; do printf '  [%s %s] -> %s\n' "$cls" "$pub" "$priv"; done < "$W/selnoclass"
        echo
        echo "Add the framework that owns each class to OBJC_LIBS in build-polyfill.sh, or fix the class name."
    } >&2
    exit 1
fi
if [ -s "$W/seloffenders" ]; then
    {
        echo
        echo "ERROR: these WK_POLYFILL_SEL gap-fills name a method 10.9 ALREADY implements; the selref rewrite"
        echo "makes WebKit run ours in place of 10.9's working method:"
        echo
        while IFS=$'\t' read -r sent priv cls owner; do printf '  %-42s -> %-38s 10.9 defines it on %s, in %s\n' "$sent" "$priv" "$cls" "$owner"; done < "$W/seloffenders"
        echo
        echo "Delete the polyfill, or declare WK_POLYFILL_SEL_REPLACES if shadowing 10.9 is the point."
    } >&2
    exit 1
fi
if [ -s "$W/seldead" ]; then
    {
        echo
        echo "ERROR: these WK_POLYFILL_SEL registrations point at a private selector no class implements; the"
        echo "rewrite still happens, so WebKit sends a selector that exists nowhere:"
        echo
        while IFS=$'\t' read -r pub priv; do printf '  %-46s -> %s\n' "$pub" "$priv"; done < "$W/seldead"
        echo
        echo "Implement the wk_ method on the class it belongs to, or drop the registration."
    } >&2
    exit 1
fi

# Dead gap-fill ADDs: wk_alias_class runs before wk_install_added and binds wk_<pub> to the REAL method on
# every class that itself defines <pub>; a plain WK_POLYFILL_ADD then class_addMethod()s, which no-ops there,
# so a WK_POLYFILL_SEL_REPLACES it backs never installs and the rewrite reaches 10.9's original. Only the
# class's OWN method list matters (an inheriting class gets no alias, so the ADD is live there).
"$CLANG" $HOST -o "$W/ownprobe" "$TGATES/shadow-ownprobe.m" -lobjc
: > "$W/gapadds"
while IFS=$'\t' read -r cls sel addintent; do
    [ "$addintent" = "GAP_FILL" ] || continue
    awk -F'\t' -v p="$sel" -v c="$cls" '$2 == p && $3 == "REPLACES" { print c "\t" $1 "\t" p; exit }' "$W/selregistry.tsv" >> "$W/gapadds"
done < "$W/addmap.tsv"
cut -f1,2 "$W/gapadds" | sort -u | "$W/ownprobe" $OBJC_LIBS > "$W/own.base"
cut -f1,2 "$W/gapadds" | sort -u | "$W/ownprobe" $OBJC_LIBS $PROBE_ONLY_LIBS > "$W/own.ext"
awk -F'\t' 'NR == FNR { ext[$1 FS $2] = $0; next }
            $3 == "NOCLASS" && (($1 FS $2) in ext) { print ext[$1 FS $2]; next }
            { print }' "$W/own.ext" "$W/own.base" | awk -F'\t' '$3 == "OWNS"' > "$W/deadadds"
if [ -s "$W/deadadds" ]; then
    {
        echo
        echo "ERROR: these WK_POLYFILL_ADD gap-fills install the private selector of a WK_POLYFILL_SEL_REPLACES on"
        echo "a class that itself defines the public selector, so the replacement body never installs there:"
        echo
        while IFS=$'\t' read -r cls pub state; do
            priv=$(awk -F'\t' -v c="$cls" -v p="$pub" '$1 == c && $2 == p { print $3; exit }' "$W/gapadds")
            printf '  WK_POLYFILL_ADD(%s, %s)  is dead: %s owns %s\n' "$cls" "$priv" "$cls" "$pub"
        done < "$W/deadadds"
        echo
        echo "Declare each WK_POLYFILL_ADD_REPLACES (class_replaceMethod installs regardless), or drop the SEL_REPLACES."
    } >&2
    exit 1
fi

# Classes: a stub registered for a class 10.9 HAS would answer WebKit's soft-link with a handful of methods
# in place of the real class. There is no REPLACES form for a class.
"$CLANG" $HOST -o "$W/clspresent" "$TGATES/shadow-clspresent.m" -lobjc
"$W/clspresent" "$OUT/libpolyfill_classes.dylib" | sort -u > "$W/clson109"
if awk -F'\t' '$3 == "PRESENT"' "$W/clson109" | grep -q .; then
    {
        echo
        echo "ERROR: these WK_POLYFILL_CLASS registrations name a class 10.9 ALREADY has:"
        echo
        awk -F'\t' '$3 == "PRESENT" { printf "  %-46s present in %s\n", $1, $2 }' "$W/clson109"
        echo
        echo "Delete the stub and let WebKit soft-link 10.9's own class."
    } >&2
    exit 1
fi

# A public selector registered twice: class_addMethod is a no-op once the wk_ method exists, so the FIRST
# definition is live and the second is dead code an edit can land on. Scanned from source because the
# runtime registry is sort -u'd.
dupsel=$(grep -hvE '^[[:space:]]*//' "$PF"/methods/*.m "$PF"/webkit/*.mm 2>/dev/null \
    | grep -oE 'WK_POLYFILL_SEL(_REPLACES)?\("[^"]+"' | sed -E 's/.*\("//; s/"$//' | sort | uniq -d)
if [ -n "$dupsel" ]; then
    { echo; echo "ERROR: these public selectors are registered more than once (only the first is live):"; echo
      printf '  %s\n' $dupsel; echo; echo "Collapse each to exactly one definition."; } >&2
    exit 1
fi

echo "  shadow gates: clean -- $(wc -l < "$W/names" | tr -d ' ') defined symbols, $(wc -l < "$W/registry.tsv" | tr -d ' ') registered;"
echo "    $(wc -l < "$W/present_names" | tr -d ' ') present on 10.9, each declared WK_POLYFILL_REPLACES"
echo "    $(wc -l < "$W/selregistry.tsv" | tr -d ' ') ObjC method polyfills, each landing on a class; $(awk -F'\t' '$4 == "PRESENT"' "$W/selon109" | wc -l | tr -d ' ') present on 10.9, each declared WK_POLYFILL_SEL_REPLACES"
echo "    $(wc -l < "$W/clson109" | tr -d ' ') ObjC class polyfills, none of which 10.9 has"
echo "    $(wc -l < "$W/gapadds" | tr -d ' ') gap-fill ADDs back a SEL_REPLACES; none dead on a class owning the public selector"

echo "### done -> $OUT"
ls -la "$OUT"
