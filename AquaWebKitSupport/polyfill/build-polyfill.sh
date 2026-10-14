#!/bin/bash
# Build the polyfill layer into polyfill/build/ (gitignored). See README.md for how the
# layer works and where a polyfill goes; the directory a source sits in decides which product it lands in:
#
#   polyfills/c/        libpolyfill.a           force-loaded into every WebKit image, hidden
#   polyfills/shared/   libpolyfill.a           (also compiled by deps/build_deps.sh and toolchain/scripts/build_python3.sh)
#   polyfills/methods/  libpolyfill_methods.a   force-loaded into WebCore (with the selref-scope mechanism), and
#                       the absent classes written over a library only WebCore links
#   polyfills/classes/  libpolyfill_classes.dylib   one shared, exported definition of each absent class
#   polyfills/webkit/   libpolyfill_webkit.a    force-loaded into WebKit.framework only
#   polyfills/jsc/      libwtf_compat.a         force-loaded into JavaScriptCore only
#   polyfills/cdm/      libwidevinegap.dylib    loaded by the Widevine CDM, not by WebKit
#   polyfills/helpers/  pasteboard-expiration   an executable in WebCore.framework's Helpers, run by a method polyfill
#   mechanism/          wk_polyfill_runtime.o -> libpolyfill.a; wk_selref_scope.o -> libpolyfill_methods.a;
#                       wk_image_marker.o -> libwk_marker.a (force-loaded into every WebKit framework)
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/polyfill-env.sh"
. "$REPO/AquaWebKitSupport/scripts/cctools.sh"
. "$REPO/AquaWebKitSupport/scripts/host-headers.sh"
OBJ="$(mktemp -d "${TMPDIR:-/tmp}/polybuild.XXXXXX")"; trap 'rm -rf "$OBJ"' EXIT
mkdir -p "$OUT" "$OBJ"/{c,shared,methods,classes,webkit,jsc,cdm,widevine,mech}

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

# --- compile -----------------------------------------------------------------------------------
echo "### compiling polyfills/c (every WebKit image)"
# -I deps/build/include: libcompression.c decodes Brotli through the vendored codec headers, and
# ots_font_parser.cpp the OpenType Sanitiser's.
CINC="$INC -I$REPO/AquaWebKitSupport/deps/build/include"
for f in "$PF"/c/*.c "$PF"/c/*.m; do
    [ -e "$f" ] || continue
    cc_queue "$CLANG" -c $MODERN $HIDDEN $CINC -o "$OBJ/c/$(basename "${f%.*}").o" "$f"
done
for f in "$PF"/c/*.cpp; do
    [ -e "$f" ] || continue
    cc_queue "$CLANGXX" -c $MODERN $HIDDEN $CINC -std=c++17 -o "$OBJ/c/$(basename "${f%.*}").o" "$f"
done

echo "### compiling polyfills/shared (also compiled by the vendored non-WebKit builds)"
# Plain C written against the 10.9 host headers, which is what deps/build_deps.sh and build_python3.sh
# compile them with too. -DWK_POLYFILL_REGISTERED lets a shared source declare a registry entry under
# #ifdef, which only this build defines, so those builds gain no dependency on the registry.
SHAREDCF="--no-default-config -isysroot / -mmacosx-version-min=10.9 -fPIC -O2 $WARN -I$PF/shared/include"
for f in "$PF"/shared/*.c; do
    cc_queue "$CLANG" -c $SHAREDCF $HIDDEN -DWK_POLYFILL_REGISTERED $INC -o "$OBJ/shared/$(basename "${f%.c}").o" "$f"
done

# -I polyfills/c: a method block and a C function of the same framework share a helper header there
# (README: "A helper two files need goes in a header in c/"). Both archives are force-loaded into
# WebCore, so the definition is in the image the reference is.
echo "### compiling polyfills/methods (WebCore)"
for f in "$PF"/methods/*.m; do
    cc_queue "$CLANG" -c $MODERN $BLOCKCF $(methods_unitinc "$f") -DWK_POLYFILL_UNIT="$(basename "${f%.m}")" -o "$OBJ/methods/$(basename "${f%.m}").o" "$f"
done

echo "### compiling polyfills/classes (one shared definition each)"
# Exported: other images bind to these classes through the reexport-and-repoint in
# scripts/stage-frameworks.sh, and hiding would drop the WKPolyfillPriv_* aliases from the export table.
# -Werror: against the 10.9 headers a post-10.9 API is not declared at all, so -Wunguarded-availability
# has nothing to fire on and the diagnostic that does catch a send to an absent selector -- "may not
# respond to" -- carries no flag of its own. Promoting the whole set is what makes it stop the build;
# these units compile with no warnings today, so it costs nothing.
for f in "$PF"/classes/*.m; do
    cc_queue "$CLANG" -c $HOST -fobjc-weak -Werror $INC -o "$OBJ/classes/$(basename "${f%.m}").o" "$f"
done

echo "### compiling polyfills/webkit (WebKit.framework only)"
# MINC rather than INC: websocket.mm asks c/ for the protection space its server-trust challenge carries.
# deps/build/include holds ICU, libpng, libxml2 and the rest of the vendored roots, so it reaches only
# the one unit that needs curl and openssl from it -- websocket.mm, which runs its transport on libcurl
# and builds its ClientHello from CocoaCurlClientHello.h, the header WebCore compiles.
for f in "$PF"/webkit/*.mm; do
    case "$(basename "$f")" in
        websocket.mm) UNITINC="$MINC -I$REPO/AquaWebKitSupport/deps/build/include -I$REPO/AquaWebKitSupport/source/WebCore/platform/network/cocoa" ;;
        *) UNITINC="$MINC" ;;
    esac
    cc_queue "$CLANG" -c $MODERN $BLOCKCF $UNITINC -fobjc-arc -DWK_POLYFILL_UNIT="$(basename "${f%.mm}")" -o "$OBJ/webkit/$(basename "${f%.mm}").o" "$f"
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
cc_queue "$CLANG" -c $MODERN $INC -DWK_POLYFILL_UNIT=mechanism -o "$OBJ/mech/wk_selref_scope.o" "$MECH/wk_selref_scope.m"
cc_queue "$CLANG" -c $HOST               -o "$OBJ/mech/wk_image_marker.o"    "$MECH/wk_image_marker.c"

echo "### compiling polyfills/cdm (the Widevine CDM's libSystem gap library)"
# Exported (no HIDDEN): another image binds to these. getentropy and aligned_alloc are the layer's own
# shared sources, compiled a second time with their exports intact.
CDMCF="--no-default-config -isysroot / -mmacosx-version-min=10.9 -fPIC -O2 $WARN -I$PF/shared/include"
cc_queue "$CLANG" -c $CDMCF -o "$OBJ/cdm/getentropy.o"    "$PF/shared/getentropy.c"
cc_queue "$CLANG" -c $CDMCF -o "$OBJ/cdm/aligned_alloc.o" "$PF/shared/aligned_alloc.c"
cc_queue "$CLANG" -c $CDMCF -o "$OBJ/cdm/pthread_qos.o" "$PF/shared/pthread_qos.c"
for f in "$PF"/cdm/*.c; do
    cc_queue "$CLANG" -c $CDMCF -o "$OBJ/cdm/$(basename "${f%.c}").o" "$f"
done
echo "### compiling the Widevine backend's private verification-path adapter"
cc_queue "$CLANG" -c $CDMCF -o "$OBJ/widevine/WidevineHostPaths.o" \
    "$REPO/AquaWebKitSupport/source/WebCore/platform/graphics/gstreamer/eme/WidevineHostPaths.c"
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
# demotes every defined global in the members to private extern; the symbols still satisfy the force_load
# link. One list feeds both the demotion and the archive.
LIBPOLYFILL_MEMBERS=("$OBJ"/c/*.o "$OBJ/mech/wk_polyfill_runtime.o" "$OBJ"/shared/*.o)
for o in "${LIBPOLYFILL_MEMBERS[@]}"; do "$CCTOOLS/nmedit" -p "$o"; done
ar_stable "$OUT/libpolyfill.a" "${LIBPOLYFILL_MEMBERS[@]}"
echo "### libpolyfill_classes.dylib"
# The polyfilled classes have absent-on-10.9 SYSTEM names, which WebKit references with a two-level
# binding to the framework that owns them in the build SDK. This one dylib defines every stub (each class
# defined exactly once across the loaded images) and is link_libraries'd into every framework, which
# resolves the classes the linker reaches it for (AppKit/QuartzCore/Foundation). For classes whose owning
# framework is linked BEFORE this dylib (CFNetwork -> _NSHTTPAlternativeServices*;
# CoreServices -> LSBundleProxy) the dylib REEXPORTS those
# frameworks and scripts/stage-frameworks.sh repoints each WebKit binary's dependency on them to it, so the
# class resolves here and the framework's real symbols pass through. compatibility_version is very high so
# the repointed load commands are satisfied; the install name is @rpath (self-contained, mapped to the
# in-bundle copy by staging). -licucore is for NSDateComponentsFormatter, which spells its durations out
# through 10.9's own ICU. -headerpad_max_install_names leaves room for the long absolute in-bundle install
# name staging stamps on it.
"$CLANG" --no-default-config -mmacosx-version-min=10.9 -dynamiclib -Wl,-headerpad_max_install_names \
    -install_name @rpath/libpolyfill_classes.dylib -compatibility_version 9999.0.0 -current_version 9999.0.0 \
    -licucore -framework CoreFoundation -framework ApplicationServices \
    -Wl,-reexport_framework,Foundation -Wl,-reexport_framework,AppKit -Wl,-reexport_framework,QuartzCore \
    -Wl,-reexport_framework,CoreServices -Wl,-reexport_framework,CFNetwork \
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
# Installed beside the downloaded module by WebCore's WidevineCdmInstaller, which is also what points
# the module at it.
"$CLANG" --no-default-config -isysroot / -mmacosx-version-min=10.9 -dynamiclib \
    -install_name @loader_path/libwidevinegap.dylib "$OBJ"/cdm/*.o "$OBJ"/widevine/*.o -o "$OUT/libwidevinegap.dylib.tmp"
tmp_stable "$OUT/libwidevinegap.dylib"

echo "### pasteboard-expiration"
# Built against 10.9's own AppKit: it uses nothing newer, so it needs no polyfill.
"$CLANG" $HOST -Wl,-headerpad_max_install_names -o "$OUT/pasteboard-expiration.tmp" "$PF/helpers/pasteboard-expiration.m" \
    -Wl,-force_load,"$OUT/libwk_marker.a" -framework AppKit
tmp_stable "$OUT/pasteboard-expiration"

echo "### done -> $OUT"
ls -la "$OUT"
