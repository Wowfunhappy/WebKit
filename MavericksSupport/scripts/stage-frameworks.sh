#!/bin/bash
# stage-frameworks.sh — the last phase of the build: turn what ninja linked into the COMPLETE,
# installable product, staged at WebKitBuild/Release/staged/ laid out exactly as it lands on
# disk. Installing is then a plain copy (MavericksSupport/install-safari7.sh).
#
# Everything that shapes an artifact happens here: the 10.9 name shift, the bundle resources
# CMake does not copy, the private C++ runtime / polyfill / GStreamer deploys, the install-name
# rewrite to absolute /System paths, the demangler guard, the full stock XPC service set, and
# the stock i386 graft. See scripts/framework-layout.sh for the layout these produce.
#
# Step order is load-bearing, top to bottom:
#   1 copy + layout + rename    2 resources    3 runtime/polyfill/GStreamer deploys
#   4 install names    5 demangler guard    6 XPC clones    7 single-unwinder gate    8 i386 graft
# The graft is LAST because install_name_tool and the demangler guard operate on THIN x86_64
# binaries: run against a fat file they risk header-padding failures, and they would put the
# stock i386 slice through a rewrite it must never receive. Grafting after all binary mutation
# removes that hazard. The XPC clones come after the install-name rewrite so each clone inherits
# the rewritten load commands. Nothing here touches /System.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/framework-layout.sh"

REPO="$WK_REPO"
LIBDIR="$WK_LIBDIR"
STAGE="$WK_STAGE_ROOT"
TC="${MAVERICKS_CLANG:-$WK_SUPPORT/toolchain/build/clang}"
# GST_SRC is overridable so a freshly-built deps/build (e.g. a GStreamer version bump under
# test) can be staged without first refreshing the committed deps/gstreamer snapshot.
GST_SRC="${GST_SRC:-$WK_SUPPORT/deps/gstreamer/lib}"

INT="$(wk_find_install_name_tool)"
OTOOL="$(wk_find_otool)"
LIPO="$(wk_find_lipo)"
echo "### Tools: install_name_tool=$INT otool=$OTOOL lipo=$LIPO"

# The staged twin of an installed path.
s() { echo "$STAGE$1"; }

# ---------------------------------------------------------------------------
# The stock i386 slices the graft in step 8 consumes live beside the checkout; capture them
# while the system still has them. Runs first so a build that cannot produce a 32-bit-capable
# product fails before doing any work.
bash "$HERE/backup-stock-frameworks.sh"

# ---------------------------------------------------------------------------
# Map an @rpath/X.framework/... or @rpath/libY.dylib dependency to its absolute target.
absolute_for_rpath_dep() {
    local dep="$1"   # e.g. @rpath/WebCore.framework/Versions/A/WebCore
    case "$dep" in
        @rpath/JavaScriptCore.framework/*) id_path JavaScriptCore;;
        @rpath/WebCore.framework/*)        id_path WebCore;;
        # NOTE: our build's WebKitLegacy is named "WebKitLegacy" and WK2 "WebKit".
        @rpath/WebKitLegacy.framework/*)   id_path WebKit;;
        @rpath/WebKit.framework/*)         id_path WebKit2;;
        @rpath/libc++.1.dylib)             echo "$PRIVLIBCXX/libc++.1.dylib";;
        @rpath/libc++abi.1.dylib)          echo "$PRIVLIBCXX/libc++abi.1.dylib";;
        # Single-unwinder rule (see framework-layout.sh): bind to the system unwinder.
        @rpath/libunwind.1.dylib)          echo "$SYSTEM_UNWINDER";;
        # The polyfill classes dylib carries an @rpath install_name (build-polyfill.sh), so every binary that
        # links it — and the WK2 layout-test harness, which also redirects the post-10.9 frameworks onto the
        # reexporting libpolyfill_classes — records @rpath/<leaf>. Map it to its deployed in-bundle home.
        @rpath/libpolyfill_classes.dylib)  echo "$PRIVLIBCXX/libpolyfill_classes.dylib";;
        # GStreamer (#90): any remaining @rpath/libX.dylib present in the vendored GStreamer tree maps
        # to its deployed copy inside WebCore.framework. The -e guard avoids mis-mapping a stray dep.
        @rpath/*.dylib)
            local base="${dep#@rpath/}"
            if [ -e "$GST_SRC/$base" ]; then echo "$GST_DEPLOY/$base"; else echo ""; fi
            ;;
        *) echo "";;
    esac
}

# Rewrite every @rpath dependency in one Mach-O binary to its absolute target.
rewrite_rpath_deps() {
    local bin="$1"
    local dep abs
    while read -r dep; do
        [ -z "$dep" ] && continue
        case "$dep" in @rpath/*) ;; *) continue;; esac
        abs="$(absolute_for_rpath_dep "$dep")"
        if [ -n "$abs" ]; then
            "$INT" -change "$dep" "$abs" "$bin"
        else
            echo "  WARNING: unmapped @rpath dependency in $(basename "$bin"): $dep" >&2
        fi
    done < <("$OTOOL" -L "$bin" | awk 'NR>1{print $1}')
}

# Repoint one of $bin's LC_LOAD_DYLIB load commands — the one whose recorded path CONTAINS <match> — to
# <new>. The match-by-substring form locates a load command by a stable fragment of its path — used here for
# the system frameworks (pass "/<Name>.framework/"). The staging-side counterpart of the build-side reexport
# shims (the vendored GStreamer dylibs are pre-repointed at vendor time; these are the WebKit ones).
repoint_framework_dep() {
    local bin="$1" match="$2" new="$3" cur
    cur=$("$OTOOL" -L "$bin" 2>/dev/null | awk -v m="$match" 'index($1, m){print $1; exit}')
    [ -n "$cur" ] && "$INT" -change "$cur" "$new" "$bin" 2>/dev/null || true
}

# The polyfill classes dylib carries an @rpath install_name, so rewrite_rpath_deps already remapped it to its
# in-bundle home in JavaScriptCore.framework ($PRIVLIBCXX, the universal dependency every WebKit binary already
# loads) via absolute_for_rpath_dep. This pass handles the absolute SYSTEM-framework deps the build links
# directly, which have no @rpath form.
rewrite_abs_deps() {
    local bin="$1"
    # Redirect Security/CoreServices/CFNetwork/QuartzCore/AppKit to libpolyfill_classes.dylib, which REEXPORTS each of
    # them and ADDS the absent-on-10.9 ObjC classes the build SDK declares in them (SecKeyProxy,
    # _NSHTTPAlternativeServices*/_NSHSTSStorage, LSBundleProxy, CABackdropLayer, ...). WebKit's two-level
    # reference to those classes is stamped "from <that framework>"; redirecting the framework's load command
    # to this dylib makes the class resolve from the single shared definition here (no "Class X is implemented
    # in both ..." warning, no "Symbol not found" crash), while the framework's real symbols pass straight
    # through the reexport. Safe + uniform: a binary that only uses the framework's real API is unaffected.
    # (Never applied to libpolyfill_classes.dylib itself — it is not in the WebKit Mach-O list this pass walks,
    # so a self-redirect can't occur.)
    local _fw
    for _fw in Security CoreServices CFNetwork QuartzCore AppKit Foundation; do
        repoint_framework_dep "$bin" "/${_fw}.framework/" "$PRIVLIBCXX/libpolyfill_classes.dylib"
    done
}

# Remove every LC_RPATH from one Mach-O binary. After rewrite_rpath_deps no
# @rpath dependency remains, so the rpaths (which point back into the build
# tree / toolchain) are not just stale but actively dangerous: a leftover
# @rpath dep would silently resolve into WebKitBuild and load a SECOND copy
# of a framework into the process (this happened with WebCore -> build-dir
# JavaScriptCore: two JSC images, two VMs, SIGTRAP on the WK1 JS bridge).
strip_rpaths() {
    local bin="$1"
    local rp
    while read -r rp; do
        [ -z "$rp" ] && continue
        "$INT" -delete_rpath "$rp" "$bin" 2>/dev/null || true
    done < <("$OTOOL" -l "$bin" | awk '/cmd LC_RPATH/{f=1} f && /path /{print $2; f=0}')
}

# Hard verification: no @rpath dependency and no LC_RPATH may survive in a
# staged WebKit binary. A miss here means a process will mix installed + build-tree
# images; fail the build loudly instead.
verify_no_rpath() {
    local bin="$1"
    if "$OTOOL" -L "$bin" | awk 'NR>1{print $1}' | grep -q '^@rpath/'; then
        echo "ERROR: $bin still has @rpath dependencies after rewrite:" >&2
        "$OTOOL" -L "$bin" | awk 'NR>1{print $1}' | grep '^@rpath/' >&2
        return 1
    fi
    if "$OTOOL" -l "$bin" | grep -q 'cmd LC_RPATH'; then
        echo "ERROR: $bin still has LC_RPATH entries after strip" >&2
        return 1
    fi
}

# PREFLIGHT (#168 fallout): absolute_for_rpath_dep maps every @rpath dep the build produces (the WebKit
# frameworks, the polyfill leaf, the C++ runtime, the vendored GStreamer dylibs), so the only way to trip this
# is a genuinely unknown @rpath dylib (a newly vendored lib, a typo). Scan all four source bundles up front and
# abort with the remediation, so the failure names every offender at once instead of surfacing one binary deep
# into staging.
preflight_check_rpaths() {
    local bad=0 fw src f dep abs
    for fw in JavaScriptCore WebKitLegacy WebCore WebKit; do
        src="$LIBDIR/$fw.framework"
        [ -d "$src" ] || continue
        while IFS= read -r f; do
            file "$f" 2>/dev/null | grep -q "Mach-O" || continue
            while read -r dep; do
                case "$dep" in @rpath/*) ;; *) continue;; esac
                abs="$(absolute_for_rpath_dep "$dep")"
                if [ -z "$abs" ]; then
                    echo "  UNMAPPABLE @rpath dep in ${f#$LIBDIR/}: $dep" >&2
                    bad=1
                fi
            done < <("$OTOOL" -L "$f" | awk 'NR>1{print $1}')
        done < <(find "$src" -type f -perm +111)
    done
    if [ "$bad" != 0 ]; then
        echo "ERROR: build tree has unmappable @rpath deps — refusing to stage." >&2
        echo "       A binary references an @rpath dylib absolute_for_rpath_dep doesn't know how to relocate" >&2
        echo "       into the bundle (e.g. a newly vendored dylib). Add a case for it there, or relink the" >&2
        echo "       offending binary; for the XPC-service execs, 'ninja -C WebKitBuild/Release NetworkProcess" >&2
        echo "       WebProcess' (or a full rebuild.sh) relinks them." >&2
        exit 1
    fi
}
preflight_check_rpaths

# ---------------------------------------------------------------------------
# Step 1: copy each built framework into the staged tree and apply the final bundle layout —
# binary rename, Versions/Current + top-level symlinks, stock bundle identity.
echo "### Staging frameworks into $STAGE (name shift)"
rm -rf "$STAGE"
stage_framework() {
    local builtName="$1" destBundle="$(s "$2")" destBinName="$3"
    local src="$LIBDIR/$builtName.framework"
    [ -d "$src" ] || { echo "ERROR: missing built framework $src" >&2; return 1; }

    echo "== $builtName -> ${destBundle#$STAGE} (binary: $destBinName) =="
    mkdir -p "$(dirname "$destBundle")"
    cp -RP "$src" "$destBundle"

    # Rename the binary (Versions/A/<old> -> Versions/A/<new>) + Current symlink + top symlink.
    local va="$destBundle/Versions/A"
    if [ "$builtName" != "$destBinName" ] && [ -f "$va/$builtName" ]; then
        mv "$va/$builtName" "$va/$destBinName"
        # -h replaces the Versions/Current symlink itself; without it ln follows Current into
        # Versions/A and leaves a self-referential Versions/A/A behind.
        ln -sfh "A" "$destBundle/Versions/Current"
        rm -f "$destBundle/$builtName"
        ln -sf "Versions/Current/$destBinName" "$destBundle/$destBinName"
        # Fix Info.plist CFBundleExecutable.
        /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $destBinName" "$va/Resources/Info.plist" 2>/dev/null || true
        # MAVERICKS_BACKPORT: keep the STOCK bundle identifier for the name-shifted frameworks
        # (WebKitLegacy installs as WebKit.framework = com.apple.WebKit; WK2 installs as
        # WebKit2.framework = com.apple.WebKit2). The build stamps com.apple.<target-name>
        # (see WebKitMacros.cmake), which is right for WebCore/JavaScriptCore but not these two.
        /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.apple.$destBinName" "$va/Resources/Info.plist" 2>/dev/null || true
    fi

    # The build emits its XPCServices symlinks as ABSOLUTE paths back into the build tree — at the
    # bundle top level, where a framework wants the standard relative form, and once more inside
    # Versions/A/XPCServices, where the installed bundle wants nothing at all. Give the top-level
    # link its relative form and drop every other build-tree link, so the staged bundle stands alone.
    if [ -L "$destBundle/XPCServices" ]; then
        rm -f "$destBundle/XPCServices"
        ln -s "Versions/Current/XPCServices" "$destBundle/XPCServices"
    fi
    local l
    while IFS= read -r l; do
        case "$(readlink "$l")" in "$REPO"/*) rm -f "$l";; esac
    done < <(find "$destBundle" -type l)
}
# Order matters: WebCore nests inside WebKit.framework, so WebKitLegacy (-> WebKit.framework)
# is staged first and WebCore is laid into it.
stage_framework JavaScriptCore "$JSC_BUNDLE"      JavaScriptCore
stage_framework WebKitLegacy   "$WEBKIT_BUNDLE"   WebKit
stage_framework WebCore        "$WEBCORE_BUNDLE"  WebCore
stage_framework WebKit         "$WEBKIT2_BUNDLE"  WebKit2
# Match stock: the public WebKit umbrella exposes its nested frameworks via a top-level symlink
# (WebKit.framework/Frameworks -> Versions/Current/Frameworks). Loads use the full Versions/A path,
# but the symlink keeps the on-disk layout identical to stock 10.9.
ln -sfh Versions/Current/Frameworks "$(s "$WEBKIT_BUNDLE")/Frameworks"

# The WebKit Mach-O binaries this build produces: each bundle's own contents, minus its
# Versions/A/Frameworks dir (which holds the nested WebCore — staged as its own bundle — and the
# deployed C++ runtime / polyfill / GStreamer dylibs, all handled explicitly below).
webkit_machos() {
    local bundle f
    for bundle in "$(s "$JSC_BUNDLE")" "$(s "$WEBKIT_BUNDLE")" "$(s "$WEBCORE_BUNDLE")" "$(s "$WEBKIT2_BUNDLE")"; do
        while IFS= read -r f; do
            case "$f" in "$bundle/Versions/A/Frameworks/"*) continue;; esac
            file "$f" 2>/dev/null | grep -q "Mach-O" && echo "$f"
        done < <(find "$bundle" -type f -perm +111)
    done
}

# ---------------------------------------------------------------------------
# Step 2: the bundle resources the CMake Mac build compiles into WebCore but does not copy.
echo "### Staging WebCore bundle resources"
RES="$(s "$WEBCORE_BUNDLE")/Versions/A/Resources"
# RenderThemeCocoa loads two of them from the framework bundle at runtime: the localized-strings
# script (defines the UIStrings table that UIString() reads — without it the controls JS throws at
# load and NO control bar renders) and the SVG/PDF/PNG control icons. With them, <video controls>
# shows a working control bar.
mkdir -p "$RES/modern-media-controls/images"
cp -f "$REPO/Source/WebCore/en.lproj/modern-media-controls-localized-strings.js" "$RES/" 2>/dev/null || \
    echo "  WARN: modern-media-controls-localized-strings.js not found"
# Flat icon dir: RenderThemeCocoa looks up <name>.<type> in modern-media-controls/images.
cp -f "$REPO"/Source/WebCore/Modules/modern-media-controls/images/macOS/* "$RES/modern-media-controls/images/" 2>/dev/null || \
    echo "  WARN: macOS media-control icons not found"
echo "  staged modern-media-controls resources ($(ls "$RES/modern-media-controls/images" 2>/dev/null | wc -l | tr -d ' ') icons)"

# The Web Audio HRTF impulse-response database AudioBus::loadPlatformResource() reads from the
# bundle (audio/Composite.wav, the concatenated database used when USE(CONCATENATED_IMPULSE_RESPONSES);
# subject name "Composite"). With it, an HRTF PannerNode (positional audio) gets a real URL instead of
# making +[NSData dataWithContentsOfURL:] throw on nil and aborting the whole WebContent process
# (e.g. the 5-million-devs.netlify.com 3D game reload loop).
mkdir -p "$RES/audio"
cp -f "$REPO/Source/WebCore/platform/audio/resources/Composite.wav" "$RES/audio/" 2>/dev/null \
    && echo "  staged HRTF database (audio/Composite.wav)" \
    || echo "  WARN: HRTF Composite.wav not found"

# linearSRGB.icc: 10.9 CG has no kCGColorSpaceLinearSRGB, so WebCore's
# linearSRGBColorSpaceSingleton() builds the linear sRGB space from this
# profile (the classic pre-10.12 mechanism; stock 10.9 WebCore shipped the
# same file). With it, SVG filters run in linear space.
cp -f "$REPO/Source/WebCore/Resources/linearSRGB.icc" "$RES/" 2>/dev/null \
    && echo "  staged linearSRGB.icc" \
    || echo "  WARN: linearSRGB.icc not found"

# Localizable.strings: WEB_UI_STRING looks localized UI strings up in the WebCore
# bundle (copyLocalizedString → CFBundleCopyLocalizedString). With the table every
# string renders as its translation rather than its localization KEY (e.g. "Allow"
# instead of "Allow (usermedia)" on the getUserMedia consent sheet). The bundle
# identifier side is stamped at build time (WebKitMacros.cmake).
mkdir -p "$RES/en.lproj"
cp -f "$REPO/Source/WebCore/en.lproj/Localizable.strings" "$RES/en.lproj/" 2>/dev/null \
    && echo "  staged en.lproj/Localizable.strings" \
    || echo "  WARN: Localizable.strings not found"

# ---------------------------------------------------------------------------
# Step 3: deploy the dylibs that ship inside the bundles. The frameworks' load commands are
# rewritten to these absolute in-bundle paths in step 4.
echo "### Deploying private C++ runtime into JavaScriptCore.framework ($PRIVLIBCXX)"
mkdir -p "$(s "$PRIVLIBCXX")"
for lib in libc++.1.dylib libc++abi.1.dylib; do
    cp -f "$TC/lib/$lib" "$(s "$PRIVLIBCXX")/$lib"
    "$INT" -id "$PRIVLIBCXX/$lib" "$(s "$PRIVLIBCXX")/$lib" 2>/dev/null || true
done
# libc++ loads libc++abi via @rpath (and libc++abi has a self-referential @rpath load too); both also
# load @rpath/libunwind.1.dylib. Pin all absolute so dyld resolves them in processes with no rpath set,
# with the unwinder pinned to the system one (single-unwinder rule, see framework-layout.sh).
for lib in libc++.1.dylib libc++abi.1.dylib; do
    "$INT" -change @rpath/libc++abi.1.dylib "$PRIVLIBCXX/libc++abi.1.dylib" "$(s "$PRIVLIBCXX")/$lib" 2>/dev/null || true
    "$INT" -change @rpath/libunwind.1.dylib "$SYSTEM_UNWINDER" "$(s "$PRIVLIBCXX")/$lib" 2>/dev/null || true
done

echo "### Deploying polyfill ObjC classes dylib into JavaScriptCore.framework ($PRIVLIBCXX)"
if [ -f "$WK_SUPPORT/polyfill/build/libpolyfill_classes.dylib" ]; then
    cp -f "$WK_SUPPORT/polyfill/build/libpolyfill_classes.dylib" "$(s "$PRIVLIBCXX")/libpolyfill_classes.dylib"
    "$INT" -id "$PRIVLIBCXX/libpolyfill_classes.dylib" "$(s "$PRIVLIBCXX")/libpolyfill_classes.dylib" 2>/dev/null || true
else
    echo "ERROR: libpolyfill_classes.dylib missing — every WebKit app would fail to load (polyfill ObjC classes)." >&2
    echo "       Build it with MavericksSupport/polyfill/scripts/build-polyfill.sh (rebuild.sh does this)." >&2
    exit 1
fi

# GStreamer (#90), the sole media engine: deploy the vendored lib tree (libs + plugins) into
# WebCore.framework. The libs are self-contained via their own LC_RPATH @loader_path/../lib, so they
# ship as-is; only the WebKit frameworks' @rpath/libg*/libgst*/etc. deps are rewritten to these
# absolute paths (step 4).
echo "### Deploying GStreamer libs into WebCore.framework ($GST_DEPLOY)"
if [ -d "$GST_SRC" ]; then
    # The runtime is built from source for 10.9 (MavericksSupport/deps/build_deps.sh)
    # and proved self-contained by that script's resolution gate: every strong undefined symbol in
    # every dylib/plugin resolves on this host, no NULL-binding weak imports beyond the documented
    # allow-list, no compat/reexport shims, and the C++17 runtime is vendored in-tree
    # (libc++.1.dylib / libc++abi.1.dylib).
    mkdir -p "$(s "$GST_DEPLOY")"
    cp -Rp "$GST_SRC/." "$(s "$GST_DEPLOY")/"
    # Single-unwinder rule: the vendored tree carries the toolchain's libunwind and @rpath references
    # to it (resolved via the libs' @loader_path/../lib LC_RPATH). Bind every reference to the system
    # unwinder and leave the vendored copy out of the product.
    find "$(s "$GST_DEPLOY")" -type f -name '*.dylib' | while read -r gstlib; do
        if "$OTOOL" -L "$gstlib" 2>/dev/null | grep -q '@rpath/libunwind.1.dylib'; then
            "$INT" -change @rpath/libunwind.1.dylib "$SYSTEM_UNWINDER" "$gstlib"
        fi
    done
    rm -f "$(s "$GST_DEPLOY")/libunwind.1.dylib"
else
    echo "ERROR: GStreamer source tree $GST_SRC missing — the product would have no media engine." >&2
    exit 1
fi

# Sandbox grants read only to world-readable files under /System with traversable parents.
# Make the in-bundle lib dirs traversable and the dylibs world-readable, here in the staged tree,
# so a plain copy carries the right modes onto the system.
chmod 755 "$(s "$PRIVLIBCXX")" "$(s "$PRIVLIB")" 2>/dev/null || true
chmod 644 "$(s "$PRIVLIBCXX")"/*.dylib 2>/dev/null || true
# GStreamer tree: every dir traversable, every dylib world-readable (sandboxed WebContent loads them).
find "$(s "$GST_DEPLOY")" -type d -exec chmod 755 {} + 2>/dev/null || true
find "$(s "$GST_DEPLOY")" -type f -name '*.dylib' -exec chmod 644 {} + 2>/dev/null || true

# ---------------------------------------------------------------------------
# Step 4: every WebKit binary advertises and loads absolute /System paths. This covers the four
# framework binaries plus every nested Mach-O (the XPC service executables and helper tools, which
# reference @rpath/WebKit.framework etc. and must be remapped just like the main binaries, or the
# WebContent/Networking processes fail to launch and pages never render).
echo "### Rewriting install names to absolute /System paths"
for name in JavaScriptCore:$JSC_BUNDLE/Versions/A/JavaScriptCore \
            WebKit:$WEBKIT_BUNDLE/Versions/A/WebKit \
            WebCore:$WEBCORE_BUNDLE/Versions/A/WebCore \
            WebKit2:$WEBKIT2_BUNDLE/Versions/A/WebKit2; do
    "$INT" -id "$(id_path "${name%%:*}")" "$(s "${name#*:}")"
done
while IFS= read -r f; do
    rewrite_rpath_deps "$f"
    rewrite_abs_deps "$f"
    strip_rpaths "$f"
    verify_no_rpath "$f"
done < <(webkit_machos)
echo "  rewritten: $(webkit_machos | wc -l | tr -d ' ') Mach-O binaries carry absolute paths and no LC_RPATH"

# ---------------------------------------------------------------------------
# Step 5: the demangler guard. The 10.9 libc++abi __cxa_demangle heap-corrupts on some modern-C++
# mangled names (WebCore's Style CSSValueCreation/ToCSS lambda locals). ReportCrash demangles every
# symbol of every mapped image while writing a crash report, so ONE such symbol makes ReportCrash
# itself crash and no .crash is ever produced for a WebKit process (sample/spindump break the same
# way). The guard scans binaries and renames the offending LOCAL symbols _Z -> _z in the string table
# so symbolication skips demangling them. See MavericksSupport/demangler/neutralize-demangler-crashers.py.
#
# Pass 1 covers the two real XPC service executables, ahead of the cloning in step 6 so every clone
# inherits a patched table. Pass 2 covers the frameworks and every dylib deployed into them in step 3
# — each of those can map into a WebKit process, and one drifted symbol silently re-breaks ReportCrash.
echo "### Demangler guard (pass 1/2): XPC service executables"
/usr/bin/python "$WK_SUPPORT/demangler/neutralize-demangler-crashers.py" \
    "$(s "$XPCSERVICES")/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking" \
    "$(s "$XPCSERVICES")/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent" || {
        echo "ERROR: demangler guard (pass 1) failed" >&2; exit 1; }

echo "### Demangler guard (pass 2/2): frameworks + all in-bundle dylibs"
DEMANGLER_GUARD_BINS="$(s "$JSC_BUNDLE")/Versions/A/JavaScriptCore
$(s "$WEBKIT_BUNDLE")/Versions/A/WebKit
$(s "$WEBCORE_BUNDLE")/Versions/A/WebCore
$(s "$WEBKIT2_BUNDLE")/Versions/A/WebKit2
$(find "$(s "$PRIVLIBCXX")" "$(s "$PRIVLIB")" -name '*.dylib' -type f 2>/dev/null || true)"
echo "$DEMANGLER_GUARD_BINS" | grep -v '^$' | sort -u | \
    xargs /usr/bin/python "$WK_SUPPORT/demangler/neutralize-demangler-crashers.py" || {
        echo "ERROR: demangler guard (pass 2) failed" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Step 6: QuickLook web previews (.webloc from a Dock stack) need the FULL stock WK2 XPC service set.
#
# macOS 10.9's QuickLook (QuickLookUIHelper, sandboxed) renders a web preview by loading our WebKit2
# and launching the SAME fixed set of helper services the 2014 stock WebKit shipped: production AND
# ".Development" variants of every service, plus OfflineStorage and Plugin.{32,64}. xpcd resolves the
# sandboxed host's connection to each service through the on-disk .xpc bundles; when a requested bundle
# is MISSING the domain-extension fails the sandbox check and the preview hangs (spins forever). Modern
# WebKit builds Networking.xpc + WebContent.xpc (it folded OfflineStorage into NetworkProcess and dropped
# the NPAPI Plugin process), so the other seven bundles ship as identity-renamed clones of those two.
# (Safari is unaffected either way: ProcessLauncherCocoa requests only the two production services, and
# Safari's own host is not sandboxed the way QuickLook's is.)
#
# The .Development network/web variants clone their production counterpart; the storage/plugin bundles
# clone WebContent — they only need to EXIST and be launchable so xpcd's domain check passes (the actual
# rendering is done by WebContent + Networking, and QuickLook launches this set for every web preview
# regardless of page content). Cloning happens after step 4, so each clone inherits the absolute load
# commands intact, and after step 5, so each inherits a guarded string table. A clone differs from its
# base ONLY in the three identity keys + the renamed executable file.
make_xpc_variant() {
    local base="$1" newname="$2"
    local src="$(s "$XPCSERVICES")/com.apple.WebKit.$base.xpc"
    local dst="$(s "$XPCSERVICES")/com.apple.WebKit.$newname.xpc"
    [ -d "$src" ] || { echo "  xpc-variant: missing base $src" >&2; return 1; }
    rm -rf "$dst"
    cp -RP "$src" "$dst"
    mv "$dst/Contents/MacOS/com.apple.WebKit.$base" "$dst/Contents/MacOS/com.apple.WebKit.$newname"
    local pl="$dst/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.apple.WebKit.$newname" "$pl"
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable com.apple.WebKit.$newname" "$pl"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName       com.apple.WebKit.$newname" "$pl"
    echo "  created $newname.xpc (clone of $base)"
}
echo "### Creating the full stock WK2 XPC service set (QuickLook web previews)"
while IFS=: read -r base newname; do
    [ -n "$base" ] || continue
    make_xpc_variant "$base" "$newname"
done <<EOF
$WK_XPC_VARIANTS
EOF

# ---------------------------------------------------------------------------
# Step 7: single-unwinder gate over everything staged so far, while every binary is still thin and
# a violation is cheap to fix. wk_verify_tree runs the same check again at the end, once the tree is
# complete; this one pins the failure to the rewriting steps above rather than to the graft.
echo "### Verifying single-unwinder rule (no libunwind.1.dylib references)"
UNWIND_VIOLATIONS=0
for root in $WK_INSTALL_ROOTS; do
    while read -r bin; do
        [ -n "$bin" ] || continue
        if "$OTOOL" -L "$bin" 2>/dev/null | grep -q 'libunwind\.1\.dylib'; then
            echo "  VIOLATION: $bin references a private libunwind.1.dylib" >&2
            UNWIND_VIOLATIONS=$((UNWIND_VIOLATIONS + 1))
        fi
    done < <(find "$(s "$root")" \( -type f -perm +111 \) -o \( -type f -name '*.dylib' \) 2>/dev/null)
done
if [ "$UNWIND_VIOLATIONS" -ne 0 ]; then
    echo "### FAILED: $UNWIND_VIOLATIONS binaries reference a private libunwind (mixed-unwinder hazard)" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 8, last: 32-bit (i386) compatibility — graft the STOCK 10.9 i386 slices back in.
#
# This backport builds x86_64 only, but macOS 10.9 still runs 32-bit apps and the stock WebKit
# shipped fat (x86_64 + i386). A 32-bit app that loads WebKit against x86_64-only binaries hits
# "dyld: no compatible architecture" and CRASHES. Keep the modern x86_64 slice for 64-bit clients
# (Safari) and fatten each framework binary with the ORIGINAL stock i386 slice, so 32-bit WebView
# apps load the stock legacy WebKit1. dyld selects the slice by process arch and each slice keeps
# its OWN load commands, so the two dependency graphs stay fully independent:
#   x86_64 (ours):  WebKit -> WebKit.framework/.../Frameworks/WebCore + JavaScriptCore
#   i386  (stock):  WebKit -> WebKit.framework/.../Frameworks/WebCore + JavaScriptCore
# Both arches resolve WebCore at the SAME nested path (the stock 10.9 layout); the nested WebCore
# binary is fattened too, so dyld picks the modern x86_64 WebCore for 64-bit Safari and the stock
# i386 WebCore for 32-bit apps. The stock i386 slices reference only 10.9 system libs by absolute
# path (no @rpath, no private runtime), so they need no install-name rewriting — which is also why
# this step runs after all of it.

# Replace a binary's bytes in place (preserves inode/owner/mode of the dest).
replace_inplace() { cat "$1" > "$2"; }

# Fatten a staged x86_64 binary with the i386 slice of a stock fat binary.
graft_i386() {
    local dest="$1" stock="$2"
    [ -f "$dest" ]  || { echo "  graft: missing staged $dest" >&2; return 1; }
    [ -f "$stock" ] || { echo "  graft: missing stock $stock" >&2; return 1; }
    case "$("$LIPO" -info "$stock" 2>/dev/null)" in
        *i386*) ;;
        *) echo "  graft: stock $stock has no i386 slice" >&2; return 1;;
    esac
    local ti tf
    ti="$(mktemp -t graft_i386)"; tf="$(mktemp -t graft_fat)"
    "$LIPO" -thin i386 "$stock" -output "$ti"
    "$LIPO" -create "$dest" "$ti" -output "$tf"
    replace_inplace "$tf" "$dest"
    rm -f "$ti" "$tf"
    echo "  grafted i386 into $(basename "$dest") -> $("$LIPO" -info "$dest" 2>/dev/null | sed 's/.*are: //')"
}

echo "### Grafting stock i386 slices for 32-bit app compatibility"
graft_i386 "$(s "$JSC_BUNDLE")/Versions/A/JavaScriptCore" \
           "$STOCK_BACKUP/JavaScriptCore.framework/Versions/A/JavaScriptCore"
graft_i386 "$(s "$WEBKIT_BUNDLE")/Versions/A/WebKit" \
           "$STOCK_BACKUP/WebKit.framework/Versions/A/WebKit"
graft_i386 "$(s "$WEBKIT2_BUNDLE")/Versions/A/WebKit2" \
           "$STOCK_BACKUP/WebKit2.framework/Versions/A/WebKit2"
graft_i386 "$(s "$WEBCORE_BUNDLE")/Versions/A/WebCore" \
           "$STOCK_BACKUP/WebKit.framework/Versions/A/Frameworks/WebCore.framework/Versions/A/WebCore"

# ---------------------------------------------------------------------------
# Everything under /System is world-readable with traversable parents — the sandbox grants read on
# nothing else, and a sandboxed WebContent loads dylibs from deep inside these bundles. `a+rX` adds
# exactly those bits (X touches only directories and files that are already executable), leaving the
# 755/644 split above intact and never making a data file executable. Done here so the modes are a
# property of the artifact rather than of whatever umask the installing shell happens to have.
chmod -R a+rX "$STAGE"

echo "### Verifying the staged product"
wk_verify_tree "$STAGE" "the staged tree ($STAGE)"
echo "### Staging done. Install with: sudo bash MavericksSupport/install-safari7.sh"
