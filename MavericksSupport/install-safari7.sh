#!/bin/bash
# install-safari7.sh — install the backported WebKit frameworks where stock
# Safari 7.0.6 (WebKit 9537.78.2) on macOS 10.9.5 loads them, performing the
# 10.9 name shift and rewriting @rpath install names to the absolute paths the
# system expects. See MavericksSupport/safari7-abi/INSTALL-PLAN.md for rationale.
#
# Name shift (built framework -> install location, binary rename):
#   JavaScriptCore -> /System/Library/Frameworks/JavaScriptCore.framework
#   WebKitLegacy   -> /System/Library/Frameworks/WebKit.framework        (bin: WebKit)
#   WebKit (WK2)   -> /System/Library/PrivateFrameworks/WebKit2.framework (bin: WebKit2)
#   WebCore        -> /System/Library/PrivateFrameworks/WebCore.framework
#
# Private C++ runtime (libc++/libc++abi from the clang-22 toolchain) and the
# CoreGraphics polyfill dylib are embedded INSIDE the framework bundles (#68:
# self-contained, nothing in /usr/local), referenced by absolute in-bundle path so
# the system's old 10.9 libc++ is never used by us and never overwritten (it is not
# a strict superset — see INSTALL-PLAN.md).
#
# SAFETY: every target path is backed up (once) to $BACKUP_ROOT before being
# overwritten. Re-running is idempotent for the backup (won't clobber an existing
# backup). Run with: sudo bash install-safari7.sh   (writes to /System, /usr/local)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
LIBDIR="$REPO/WebKitBuild/Release/lib"
TC="${MAVERICKS_CLANG:-/Users/jonathan/Desktop/Compilers/toolchains/clang-22}"
INT="${INSTALL_NAME_TOOL:-install_name_tool}"
OTOOL="${OTOOL:-otool}"
BACKUP_ROOT="${BACKUP_ROOT:-/Users/jonathan/Desktop/stock-webkit-backup/replaced-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo manual)}"

FRAMEWORKS_DIR=/System/Library/Frameworks
PRIVATE_DIR=/System/Library/PrivateFrameworks
# #68: the private C++ runtime (libc++/libc++abi) AND libcg_polyfill.dylib live INSIDE the
# framework bundles, so the install is fully self-contained — nothing in /usr/local and no
# separate top-level runtime dir. Both homes are under /System/Library/[Private]Frameworks,
# which the sandbox grants read to (the #18 reason these can't live in /usr/local: sandboxd
# "deny file-read-data /usr/local/lib/webkit-private/..."); we reference them by ABSOLUTE
# in-bundle path (never @rpath) so they can't shadow the system libc++ via DYLD_FALLBACK.
# libc++/libc++abi go in the base framework (JavaScriptCore — every WebKit framework links
# the C++ runtime); libcg_polyfill in WebCore (its only consumers are WebCore/WebKit/WebKit2).
PRIVLIBCXX=/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Frameworks
PRIVLIB=/System/Library/PrivateFrameworks/WebCore.framework/Versions/A/Frameworks
OLD_PRIVRT=/System/Library/WebKitPrivateRuntime   # pre-#68 standalone location; removed at the end

# Absolute install_name each framework binary must advertise (matches Safari's
# LC_LOAD_DYLIB). macOS 10.9 ships bash 3.2 (no associative arrays), so this is a
# function keyed by the installed binary name rather than a `declare -A` map.
id_path() {
    case "$1" in
        JavaScriptCore) echo "$FRAMEWORKS_DIR/JavaScriptCore.framework/Versions/A/JavaScriptCore";;
        WebKit)         echo "$FRAMEWORKS_DIR/WebKit.framework/Versions/A/WebKit";;        # our WebKitLegacy
        WebKit2)        echo "$PRIVATE_DIR/WebKit2.framework/Versions/A/WebKit2";;          # our WebKit (WK2)
        WebCore)        echo "$PRIVATE_DIR/WebCore.framework/Versions/A/WebCore";;
        *) echo "";;
    esac
}

backup() {
    local path="$1"
    [ -e "$path" ] || return 0
    local dest="$BACKUP_ROOT$path"
    if [ -e "$dest" ]; then echo "  (backup already exists for $path)"; return 0; fi
    mkdir -p "$(dirname "$dest")"
    echo "  backing up $path -> $dest"
    cp -Rp "$path" "$dest"
}

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

# libcg_polyfill.dylib is linked with a BAKED absolute install_name (/usr/local/lib/...) at
# build time, so rewrite_rpath_deps (which only touches @rpath deps) never sees it. Repoint it
# to the in-bundle $PRIVLIB location (inside WebCore.framework) in every binary.
rewrite_abs_deps() {
    local bin="$1"
    "$INT" -change /usr/local/lib/libcg_polyfill.dylib "$PRIVLIB/libcg_polyfill.dylib" "$bin" 2>/dev/null || true
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

# Hard verification: no @rpath dependency and no LC_RPATH may survive in an
# installed binary. A miss here means a process will mix installed + build-tree
# images; fail the install loudly instead.
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

# Install one framework: copy bundle, rename binary if needed, set LC_ID, rewrite @rpath deps
# in the main binary AND every nested Mach-O (XPCServices, helpers).
install_framework() {
    local builtName="$1" destBundle="$2" destBinName="$3"
    local src="$LIBDIR/$builtName.framework"
    [ -d "$src" ] || { echo "ERROR: missing built framework $src" >&2; return 1; }

    echo "== $builtName -> $destBundle (binary: $destBinName) =="
    backup "$destBundle"
    rm -rf "$destBundle"
    mkdir -p "$(dirname "$destBundle")"
    cp -RP "$src" "$destBundle"

    # The CMake Mac build compiles the modern-media-controls CSS/JS into the WebCore
    # binary but does NOT copy the two resources RenderThemeCocoa loads from the
    # framework bundle at runtime: the localized-strings script (defines the UIStrings
    # table that UIString() reads — without it the controls JS throws at load and NO
    # control bar renders) and the SVG/PDF/PNG control icons. Stage them here so
    # <video controls> shows a working control bar.
    if [ "$builtName" = "WebCore" ]; then
        local res="$destBundle/Versions/A/Resources"
        mkdir -p "$res/modern-media-controls/images"
        cp -f "$REPO/Source/WebCore/en.lproj/modern-media-controls-localized-strings.js" "$res/" 2>/dev/null || \
            echo "  WARN: modern-media-controls-localized-strings.js not found"
        # Flat icon dir: RenderThemeCocoa looks up <name>.<type> in modern-media-controls/images.
        cp -f "$REPO"/Source/WebCore/Modules/modern-media-controls/images/macOS/* "$res/modern-media-controls/images/" 2>/dev/null || \
            echo "  WARN: macOS media-control icons not found"
        echo "  staged modern-media-controls resources ($(ls "$res/modern-media-controls/images" 2>/dev/null | wc -l | tr -d ' ') icons)"
    fi

    # Rename the binary (Versions/A/<old> -> Versions/A/<new>) + Current symlink + top symlink.
    local va="$destBundle/Versions/A"
    if [ "$builtName" != "$destBinName" ] && [ -f "$va/$builtName" ]; then
        mv "$va/$builtName" "$va/$destBinName"
        ln -sf "A" "$destBundle/Versions/Current"
        rm -f "$destBundle/$builtName"
        ln -sf "Versions/Current/$destBinName" "$destBundle/$destBinName"
        # Fix Info.plist CFBundleExecutable.
        /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $destBinName" "$va/Resources/Info.plist" 2>/dev/null || true
    fi

    # The build emits some top-level symlinks (notably XPCServices) as ABSOLUTE
    # paths back into the build tree; rewrite them to the standard relative form so
    # the installed bundle is self-contained.
    if [ -L "$destBundle/XPCServices" ]; then
        rm -f "$destBundle/XPCServices"
        ln -s "Versions/Current/XPCServices" "$destBundle/XPCServices"
    fi

    local bin="$va/$destBinName"
    # Set this framework's own id, then rewrite its @rpath deps, then drop the
    # now-useless (and dangerous) build-tree rpaths and verify nothing remains.
    "$INT" -id "$(id_path "$destBinName")" "$bin"
    rewrite_rpath_deps "$bin"
    rewrite_abs_deps "$bin"
    strip_rpaths "$bin"
    verify_no_rpath "$bin"

    # Rewrite @rpath deps in every nested Mach-O (XPC services, helper tools). These
    # reference @rpath/WebKit.framework etc. and must be remapped just like the main
    # binary, or the WebContent/Networking processes fail to launch and pages never
    # render. Detect Mach-O by `file`, skip the main binary already handled.
    local f
    while IFS= read -r f; do
        [ "$f" = "$bin" ] && continue
        if file "$f" 2>/dev/null | grep -q "Mach-O"; then
            rewrite_rpath_deps "$f"
            rewrite_abs_deps "$f"
            strip_rpaths "$f"
            verify_no_rpath "$f"
        fi
    done < <(find "$destBundle" -type f -perm +111)
    echo "  installed."
}

# #68: the private runtime libs are deployed INTO the framework bundles AFTER the frameworks
# are installed (install_framework rm -rf's each bundle first, which would wipe a pre-placed
# lib). The frameworks' load commands are already rewritten to these absolute in-bundle paths
# during install_framework, so recording them before the files exist is fine (paths resolve at
# runtime). See the deploy block after the 32-bit graft below.
echo "### Installing frameworks (name shift)"
install_framework JavaScriptCore "$FRAMEWORKS_DIR/JavaScriptCore.framework" JavaScriptCore
install_framework WebCore        "$PRIVATE_DIR/WebCore.framework"           WebCore
install_framework WebKitLegacy   "$FRAMEWORKS_DIR/WebKit.framework"         WebKit
install_framework WebKit         "$PRIVATE_DIR/WebKit2.framework"           WebKit2

# ---------------------------------------------------------------------------
# 32-bit (i386) compatibility — graft the STOCK 10.9 i386 slices back in.
#
# Our backport builds x86_64 only, but macOS 10.9 still runs 32-bit apps and the
# stock WebKit shipped fat (x86_64 + i386). A 32-bit app that loads WebKit against
# our x86_64-only binaries hits "dyld: no compatible architecture" and CRASHES.
# Keep our modern x86_64 slice for 64-bit clients (Safari) and fatten each
# installed binary with the ORIGINAL stock i386 slice, so 32-bit WebView apps load
# the stock legacy WebKit1. dyld selects the slice by process arch and each slice
# keeps its OWN load commands, so the two dependency graphs stay fully independent:
#   x86_64 (us):    WebKit -> PrivateFrameworks/WebCore           + JavaScriptCore
#   i386  (stock):  WebKit -> WebKit.framework/.../Frameworks/WebCore + JavaScriptCore
# The i386 graph uses WebCore NESTED inside the WebKit umbrella (the stock 10.9
# layout) — a different path than our x86_64 WebCore — so the two never collide.
# The stock i386 slices reference only 10.9 system libs by absolute path (no
# @rpath, no private runtime), so no install-name rewriting is needed for them.
STOCK_BACKUP="${STOCK_BACKUP:-/Users/jonathan/Desktop/stock-webkit-backup}"

# Replace a binary's bytes in place (preserves inode/owner/mode of the dest).
replace_inplace() { cat "$1" > "$2"; }

# Fatten an installed x86_64 binary with the i386 slice of a stock fat binary.
graft_i386() {
    local dest="$1" stock="$2"
    [ -f "$dest" ]  || { echo "  graft: missing installed $dest" >&2; return 1; }
    [ -f "$stock" ] || { echo "  graft: missing stock $stock" >&2; return 1; }
    case "$(lipo -info "$stock" 2>/dev/null)" in
        *i386*) ;;
        *) echo "  graft: stock $stock has no i386 slice — skip" >&2; return 1;;
    esac
    case "$(lipo -info "$dest" 2>/dev/null)" in
        *i386*) echo "  graft: $dest already fat with i386 — skip"; return 0;;
    esac
    local ti tf
    ti="$(mktemp -t graft_i386)"; tf="$(mktemp -t graft_fat)"
    lipo -thin i386 "$stock" -output "$ti"
    lipo -create "$dest" "$ti" -output "$tf"
    replace_inplace "$tf" "$dest"
    rm -f "$ti" "$tf"
    echo "  grafted i386 into $(basename "$dest") -> $(lipo -info "$dest" 2>/dev/null | sed 's/.*are: //')"
}

# The i386 WebKit/WebKit2 slices load WebCore NESTED in the umbrella. Our modern
# build has no nested WebCore (it lives at PrivateFrameworks/WebCore for x86_64),
# so recreate the stock nested WebCore as an i386-ONLY framework for the 32-bit
# path (thinned so no 64-bit process can ever pick up the stock x86_64 WebCore).
install_nested_i386_webcore() {
    local stockNested="$STOCK_BACKUP/WebKit.framework/Versions/A/Frameworks/WebCore.framework"
    local destNested="$FRAMEWORKS_DIR/WebKit.framework/Versions/A/Frameworks/WebCore.framework"
    [ -d "$stockNested" ] || { echo "  nested WebCore: stock missing ($stockNested) — skip" >&2; return 1; }
    rm -rf "$destNested"
    mkdir -p "$(dirname "$destNested")"
    cp -RP "$stockNested" "$destNested"
    local nb="$destNested/Versions/A/WebCore" t
    if [ -f "$nb" ]; then
        t="$(mktemp -t nestedwc)"
        lipo -thin i386 "$nb" -output "$t"
        replace_inplace "$t" "$nb"; rm -f "$t"
        echo "  installed nested i386 WebCore -> $(lipo -info "$nb" 2>/dev/null | sed 's/.*: //')"
    fi
}

echo "### Grafting stock i386 slices for 32-bit app compatibility"
graft_i386 "$FRAMEWORKS_DIR/JavaScriptCore.framework/Versions/A/JavaScriptCore" \
           "$STOCK_BACKUP/JavaScriptCore.framework/Versions/A/JavaScriptCore"
graft_i386 "$FRAMEWORKS_DIR/WebKit.framework/Versions/A/WebKit" \
           "$STOCK_BACKUP/WebKit.framework/Versions/A/WebKit"
graft_i386 "$PRIVATE_DIR/WebKit2.framework/Versions/A/WebKit2" \
           "$STOCK_BACKUP/WebKit2.framework/Versions/A/WebKit2"
install_nested_i386_webcore

# ---------------------------------------------------------------------------
# #68: deploy the private runtime libs INSIDE the framework bundles. Done here, AFTER every
# install_framework (each rm -rf's its bundle) and after the 32-bit graft (which only lipo's
# binaries and recreates the nested i386 WebCore subdir — neither touches these lib dirs).
# The frameworks/XPC binaries already record these absolute in-bundle paths (set during
# install_framework via id_path/rewrite_*); we just place the files + fix their own ids.
echo "### Deploying private C++ runtime into JavaScriptCore.framework ($PRIVLIBCXX)"
mkdir -p "$PRIVLIBCXX"
for lib in libc++.1.dylib libc++abi.1.dylib; do
    cp -f "$TC/lib/$lib" "$PRIVLIBCXX/$lib"
    "$INT" -id "$PRIVLIBCXX/$lib" "$PRIVLIBCXX/$lib"
done
# libc++ loads libc++abi via @rpath (and libc++abi has a self-referential @rpath load too);
# pin both absolute so dyld resolves them in processes with no rpath set.
"$INT" -change @rpath/libc++abi.1.dylib "$PRIVLIBCXX/libc++abi.1.dylib" "$PRIVLIBCXX/libc++.1.dylib" 2>/dev/null || true
"$INT" -change @rpath/libc++abi.1.dylib "$PRIVLIBCXX/libc++abi.1.dylib" "$PRIVLIBCXX/libc++abi.1.dylib" 2>/dev/null || true
echo "### Deploying CG polyfill into WebCore.framework ($PRIVLIB)"
mkdir -p "$PRIVLIB"
if [ -f "$HERE/prebuilt/libcg_polyfill.dylib" ]; then
    cp -f "$HERE/prebuilt/libcg_polyfill.dylib" "$PRIVLIB/libcg_polyfill.dylib"
    "$INT" -id "$PRIVLIB/libcg_polyfill.dylib" "$PRIVLIB/libcg_polyfill.dylib"
fi
# Sandbox grants read only to world-readable files under /System with traversable parents.
# Make the in-bundle lib dirs traversable and the dylibs world-readable.
chmod 755 "$PRIVLIBCXX" "$PRIVLIB" 2>/dev/null || true
chmod 644 "$PRIVLIBCXX"/*.dylib "$PRIVLIB"/*.dylib 2>/dev/null || true
# Remove the pre-#68 standalone runtime dir now that nothing references it (self-contained).
if [ -d "$OLD_PRIVRT" ]; then
    rm -rf "$OLD_PRIVRT"
    echo "  removed legacy $OLD_PRIVRT"
fi

# ---------------------------------------------------------------------------
# #66: undocked Web Inspector toolbar appeared as a separate white bar instead of a
# UNIFIED titlebar+toolbar. The real fix is native: _WKInspectorWindow now emulates
# NSWindowStyleMaskFullSizeContentView (10.10+, ignored on 10.9) via a contentRect ==
# frameRect override, so the inspector's HTML #toolbar fills the top of the window and
# merges with the titlebar (traffic-light buttons float over it). Stock WebInspectorUI
# CSS intentionally leaves the UNDOCKED toolbar transparent (only `body.docked .toolbar`
# paints a gradient) because stock relied on a native textured titlebar showing through.
# Our window has no textured titlebar, so we (1) paint the same docked gradient on the
# now-top undocked toolbar and (2) reserve left space for the floating window buttons.
# Idempotent (strips any prior copy first, marked with /*WK66-UNIFIED*/).
echo "### Patching Web Inspector unified undocked toolbar (#66)"
INSPECTOR_CSS=/System/Library/PrivateFrameworks/WebInspectorUI.framework/Versions/A/Resources/Main.css
if [ -f "$INSPECTOR_CSS" ]; then
    # Idempotent: strip any prior WebKit-66 rules (each on its own /*WK66-UNIFIED*/ line).
    # Marker-only match — never line-matches the giant minified stylesheet (line 1).
    if grep -q 'WK66-UNIFIED' "$INSPECTOR_CSS"; then
        grep -v 'WK66-UNIFIED' "$INSPECTOR_CSS" > "$INSPECTOR_CSS.tmp66" && mv "$INSPECTOR_CSS.tmp66" "$INSPECTOR_CSS"
    fi
    # Ensure the stylesheet ends with a newline so our rules land on their own lines.
    [ -n "$(tail -c1 "$INSPECTOR_CSS")" ] && printf '\n' >> "$INSPECTOR_CSS"
    printf '%s\n' '/*WK66-UNIFIED*/body:not(.docked) #toolbar, body:not(.docked) .toolbar{background-image:-webkit-linear-gradient(top,rgb(216,216,216),rgb(190,190,190)) !important;box-shadow:inset rgba(255,255,255,0.1) 0 1px 0,inset rgba(0,0,0,0.02) 0 -1px 0 !important;}' >> "$INSPECTOR_CSS"
    printf '%s\n' '/*WK66-UNIFIED*/body:not(.docked) #toolbar{padding-left:78px !important;}' >> "$INSPECTOR_CSS"
    echo "  applied unified-toolbar CSS to $INSPECTOR_CSS"
else
    echo "  WARN: $INSPECTOR_CSS not found"
fi

echo "### Done. Verify with: MavericksSupport/safari7-abi/check-abi-gap.sh and 'otool -L' on each installed binary."
echo "### (Nested XPCServices binaries' @rpath deps are rewritten automatically by install_framework.)"
