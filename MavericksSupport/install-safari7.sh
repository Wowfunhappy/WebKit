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
#   WebCore        -> /System/Library/Frameworks/WebKit.framework/Versions/A/Frameworks/WebCore.framework  (nested, matches stock 10.9)
#
# Private C++ runtime (libc++/libc++abi from the clang-22 toolchain) and the
# CoreGraphics polyfill dylib are embedded INSIDE the framework bundles (#68:
# self-contained, nothing in /usr/local), referenced by absolute in-bundle path so
# the system's old 10.9 libc++ is never used by us and never overwritten (it is not
# a strict superset — see INSTALL-PLAN.md).
#
# SAFETY: the factory (stock) frameworks are preserved ONCE in $STOCK_BACKUP (the
# flat *.framework dirs in stock-webkit-backup). Installs do NOT snapshot each build —
# a re-run only replaces our own previous build, and backing that up every time is pure
# disk churn (~670MB/run, which once filled the startup disk). backup() captures stock
# at most once and is skipped entirely whenever the stock backup already exists.
# Run with: sudo bash install-safari7.sh   (writes to /System, /usr/local)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
LIBDIR="$REPO/WebKitBuild/Release/lib"
TC="${MAVERICKS_CLANG:-$REPO/MavericksSupport/toolchain/build/clang}"
INT="${INSTALL_NAME_TOOL:-install_name_tool}"
OTOOL="${OTOOL:-otool}"
# Canonical stock backup (flat *.framework dirs), preserved once. BACKUP_ROOT is a
# single fixed dir — NOT a per-run timestamped one — so backup() never accumulates a
# new ~670MB snapshot on every install.
STOCK_BACKUP="${STOCK_BACKUP:-$(dirname "$REPO")/stock-webkit-backup}"
BACKUP_ROOT="${BACKUP_ROOT:-$STOCK_BACKUP/replaced-original}"

FRAMEWORKS_DIR=/System/Library/Frameworks
PRIVATE_DIR=/System/Library/PrivateFrameworks
# #68: the private C++ runtime (libc++/libc++abi) AND libcg_polyfill.dylib live INSIDE the
# framework bundles, so the install is fully self-contained — nothing in /usr/local and no
# separate top-level runtime dir. Both homes are under /System/Library/[Private]Frameworks,
# which the sandbox grants read to (the #18 reason these can't live in /usr/local: sandboxd
# "deny file-read-data /usr/local/lib/webkit-private/..."); we reference them by ABSOLUTE
# in-bundle path (never @rpath) so they can't shadow the system libc++ via DYLD_FALLBACK.
# libc++/libc++abi/libunwind go in the base framework (JavaScriptCore — every WebKit framework
# links the C++ runtime, and clang's libc++abi unwinds via clang's own libunwind); libcg_polyfill
# in WebCore (its only consumers are WebCore/WebKit/WebKit2).
PRIVLIBCXX=/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Frameworks
# WebCore is nested INSIDE the public WebKit umbrella, matching the stock 10.9 layout: stock has NO
# top-level /System/Library/PrivateFrameworks/WebCore.framework — its WebKit2/WebKit binaries link
# WebCore at this nested path. The CG polyfill + GStreamer tree live in WebCore's own Frameworks dir.
WEBCORE_BUNDLE=$FRAMEWORKS_DIR/WebKit.framework/Versions/A/Frameworks/WebCore.framework
PRIVLIB=$WEBCORE_BUNDLE/Versions/A/Frameworks
OLD_PRIVRT=/System/Library/WebKitPrivateRuntime   # pre-#68 standalone location; removed at the end

# GStreamer (#90): the vendored lib tree is deployed inside WebCore.framework (self-contained, beside
# libcg_polyfill). The libs are self-contained via their own LC_RPATH @loader_path/../lib, so they ship
# as-is; only the WebKit frameworks' @rpath/libg*/libgst*/etc. deps are rewritten to these absolute paths.
GST_SRC="$REPO/MavericksSupport/deps/gstreamer/lib"
GST_DEPLOY="$PRIVLIB/gstreamer/lib"

# Absolute install_name each framework binary must advertise (matches Safari's
# LC_LOAD_DYLIB). macOS 10.9 ships bash 3.2 (no associative arrays), so this is a
# function keyed by the installed binary name rather than a `declare -A` map.
id_path() {
    case "$1" in
        JavaScriptCore) echo "$FRAMEWORKS_DIR/JavaScriptCore.framework/Versions/A/JavaScriptCore";;
        WebKit)         echo "$FRAMEWORKS_DIR/WebKit.framework/Versions/A/WebKit";;        # our WebKitLegacy
        WebKit2)        echo "$PRIVATE_DIR/WebKit2.framework/Versions/A/WebKit2";;          # our WebKit (WK2)
        WebCore)        echo "$WEBCORE_BUNDLE/Versions/A/WebCore";;                          # nested in WebKit.framework (stock layout)
        *) echo "";;
    esac
}

backup() {
    local path="$1"
    [ -e "$path" ] || return 0
    # Stock is already preserved in the canonical $STOCK_BACKUP; never snapshot our own
    # incremental builds (that churn is what filled the startup disk). Skip entirely once
    # the stock backup exists.
    [ -d "$STOCK_BACKUP/WebKit.framework" ] && return 0
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
        @rpath/libunwind.1.dylib)          echo "$PRIVLIBCXX/libunwind.1.dylib";;
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

# libcg_polyfill.dylib is linked with a BAKED absolute install_name (/usr/local/lib/...) at build
# time, so rewrite_rpath_deps (which only touches @rpath deps) never sees it. Repoint it to its
# in-bundle location in every binary: the CG polyfill inside WebCore.framework ($PRIVLIB).
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
# Order matters: install_framework rm -rf's its destination bundle. WebCore now nests inside
# WebKit.framework, so WebKitLegacy (-> WebKit.framework) MUST run first, then WebCore is laid into it.
install_framework JavaScriptCore "$FRAMEWORKS_DIR/JavaScriptCore.framework" JavaScriptCore
install_framework WebKitLegacy   "$FRAMEWORKS_DIR/WebKit.framework"         WebKit
install_framework WebCore        "$WEBCORE_BUNDLE"                          WebCore
install_framework WebKit         "$PRIVATE_DIR/WebKit2.framework"           WebKit2
# Match stock: the public WebKit umbrella exposes its nested frameworks via a top-level symlink
# (WebKit.framework/Frameworks -> Versions/Current/Frameworks). Loads use the full Versions/A path,
# but recreate the symlink so the on-disk layout is identical to stock 10.9.
ln -sfh Versions/Current/Frameworks "$FRAMEWORKS_DIR/WebKit.framework/Frameworks" 2>/dev/null || \
    ln -sf Versions/Current/Frameworks "$FRAMEWORKS_DIR/WebKit.framework/Frameworks" 2>/dev/null || true

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
#   x86_64 (us):    WebKit -> WebKit.framework/.../Frameworks/WebCore + JavaScriptCore
#   i386  (stock):  WebKit -> WebKit.framework/.../Frameworks/WebCore + JavaScriptCore
# Both arches resolve WebCore at the SAME nested path (the stock 10.9 layout); the nested
# WebCore binary is itself fattened with the stock i386 slice (graft_i386 below), so dyld
# picks our modern x86_64 WebCore for 64-bit Safari and the stock i386 WebCore for 32-bit apps.
# The stock i386 slices reference only 10.9 system libs by absolute path (no
# @rpath, no private runtime), so no install-name rewriting is needed for them.
STOCK_BACKUP="${STOCK_BACKUP:-$(dirname "$REPO")/stock-webkit-backup}"

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

echo "### Grafting stock i386 slices for 32-bit app compatibility"
graft_i386 "$FRAMEWORKS_DIR/JavaScriptCore.framework/Versions/A/JavaScriptCore" \
           "$STOCK_BACKUP/JavaScriptCore.framework/Versions/A/JavaScriptCore"
graft_i386 "$FRAMEWORKS_DIR/WebKit.framework/Versions/A/WebKit" \
           "$STOCK_BACKUP/WebKit.framework/Versions/A/WebKit"
graft_i386 "$PRIVATE_DIR/WebKit2.framework/Versions/A/WebKit2" \
           "$STOCK_BACKUP/WebKit2.framework/Versions/A/WebKit2"
graft_i386 "$WEBCORE_BUNDLE/Versions/A/WebCore" \
           "$STOCK_BACKUP/WebKit.framework/Versions/A/Frameworks/WebCore.framework/Versions/A/WebCore"

# ---------------------------------------------------------------------------
# #38: Dashboard "Web Clip" widgets must launch the 64-bit DashboardClient to load our x86_64-only
# WebKit. The Dock reads this widget's AllowInternetPlugins flag BEFORE any WebKit code runs: if it is
# true, the Dock writes "32bit" into com.apple.dashboard.plist and spawns an i386 DashboardClient that
# cannot load our framework (EBADARCH crash). Opt the widget out of the (now-defunct) internet-plugin
# path so the Dock spawns 64-bit. Lossless (NPAPI is gone), and there is NO in-framework lever for this
# — the Dock decides the architecture before any of our code runs, so it must be a system-plist edit.
echo "### Forcing 64-bit launch for the Dashboard Web Clip widget"
WEBCLIP_PLIST="/Library/Widgets/Web Clip.wdgt/Contents/Info.plist"
[ -f "$WEBCLIP_PLIST" ] || WEBCLIP_PLIST="/Library/Widgets/Web Clip.wdgt/Info.plist"
if [ -f "$WEBCLIP_PLIST" ]; then
    if /usr/libexec/PlistBuddy -c 'Set :AllowInternetPlugins false' "$WEBCLIP_PLIST" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c 'Add :AllowInternetPlugins bool false' "$WEBCLIP_PLIST" 2>/dev/null; then
        echo "  Web Clip.wdgt AllowInternetPlugins -> false (64-bit DashboardClient)"
    else
        echo "  warning: could not set AllowInternetPlugins on Web Clip.wdgt"
    fi
else
    echo "  Web Clip.wdgt not found — skipping (set its AllowInternetPlugins=false manually if you use Dashboard Web Clips)"
fi

# ---------------------------------------------------------------------------
# #68: deploy the private runtime libs INSIDE the framework bundles. Done here, AFTER every
# install_framework (each rm -rf's its bundle) and after the 32-bit graft (which only lipo's
# binaries and recreates the nested i386 WebCore subdir — neither touches these lib dirs).
# The frameworks/XPC binaries already record these absolute in-bundle paths (set during
# install_framework via id_path/rewrite_*); we just place the files + fix their own ids.
echo "### Deploying private C++ runtime into JavaScriptCore.framework ($PRIVLIBCXX)"
mkdir -p "$PRIVLIBCXX"
# The clang-22 libc++/libc++abi unwind via clang's own libunwind.1.dylib (referenced @rpath), so it
# is deployed here too — without it the frameworks fail to load (unmapped @rpath/libunwind.1.dylib).
for lib in libc++.1.dylib libc++abi.1.dylib libunwind.1.dylib; do
    cp -f "$TC/lib/$lib" "$PRIVLIBCXX/$lib"
    "$INT" -id "$PRIVLIBCXX/$lib" "$PRIVLIBCXX/$lib" 2>/dev/null || true
done
# libc++ loads libc++abi via @rpath (and libc++abi has a self-referential @rpath load too); both also
# load @rpath/libunwind.1.dylib. Pin all absolute so dyld resolves them in processes with no rpath set.
"$INT" -change @rpath/libc++abi.1.dylib "$PRIVLIBCXX/libc++abi.1.dylib" "$PRIVLIBCXX/libc++.1.dylib" 2>/dev/null || true
"$INT" -change @rpath/libc++abi.1.dylib "$PRIVLIBCXX/libc++abi.1.dylib" "$PRIVLIBCXX/libc++abi.1.dylib" 2>/dev/null || true
"$INT" -change @rpath/libunwind.1.dylib "$PRIVLIBCXX/libunwind.1.dylib" "$PRIVLIBCXX/libc++.1.dylib" 2>/dev/null || true
"$INT" -change @rpath/libunwind.1.dylib "$PRIVLIBCXX/libunwind.1.dylib" "$PRIVLIBCXX/libc++abi.1.dylib" 2>/dev/null || true
echo "### Deploying CG polyfill into WebCore.framework ($PRIVLIB)"
mkdir -p "$PRIVLIB"
if [ -f "$HERE/polyfill/build/libcg_polyfill.dylib" ]; then
    cp -f "$HERE/polyfill/build/libcg_polyfill.dylib" "$PRIVLIB/libcg_polyfill.dylib"
    # -id cosmetic (loaded by absolute path); polyfill dylibs lack headerpad, so tolerate a too-long id.
    "$INT" -id "$PRIVLIB/libcg_polyfill.dylib" "$PRIVLIB/libcg_polyfill.dylib" 2>/dev/null || true
fi
# TCC polyfill: WebKit::TCCLibrary() dlopens this in place of the system TCC framework on 10.9 (which
# lacks the camera/microphone privacy services). It sits beside the WebKit2 binary under Frameworks/
# so the dlopen "@loader_path/Frameworks/libtcc_polyfill.dylib" resolves to it.
WK2_FRAMEWORKS="$PRIVATE_DIR/WebKit2.framework/Versions/A/Frameworks"
if [ -f "$HERE/polyfill/build/libtcc_polyfill.dylib" ]; then
    mkdir -p "$WK2_FRAMEWORKS"
    cp -f "$HERE/polyfill/build/libtcc_polyfill.dylib" "$WK2_FRAMEWORKS/libtcc_polyfill.dylib"
fi
# GStreamer (#90): deploy the vendored lib tree (libs + plugins) into WebCore.framework. The libs are
# self-contained via their own LC_RPATH @loader_path/../lib; the frameworks' @rpath/libg* deps were
# rewritten to $GST_DEPLOY during install_framework, so they resolve to these copies at runtime.
echo "### Deploying GStreamer libs into WebCore.framework ($GST_DEPLOY)"
if [ -d "$GST_SRC" ]; then
    # Rebuild the 10.9 libSystem compat shim from the current polyfill sources so the deployed
    # copy always matches legacy-support/src (clock_gettime, the *at family, mkostemp, ...). The
    # GStreamer dylibs' libSystem dependency is already repointed to @rpath/libsystem_compat.dylib.
    bash "$REPO/MavericksSupport/deps/gstreamer/build-libsystem-compat.sh" >/dev/null \
        && echo "  rebuilt libsystem_compat.dylib" \
        || echo "  warning: libsystem_compat.dylib rebuild failed — deploying the checked-in copy"
    # Same for the CoreServices compat shim: libgio imports two 10.10+ LaunchServices functions
    # (LSCopyApplicationURLsForBundleIdentifier / LSCopyDefaultApplicationURLForContentType) that
    # crash gst_init_check on 10.9. libgio/libglib's CoreServices dependency is already repointed to
    # @rpath/libcoreservices_compat.dylib (reexports CoreServices + supplies those two as NULL).
    bash "$REPO/MavericksSupport/deps/gstreamer/build-coreservices-compat.sh" >/dev/null \
        && echo "  rebuilt libcoreservices_compat.dylib" \
        || echo "  warning: libcoreservices_compat.dylib rebuild failed — deploying the checked-in copy"
    # And the CoreText compat shim: libharfbuzz imports two 10.10+ OpenType-feature key constants
    # (kCTFontOpenTypeFeatureTag / kCTFontOpenTypeFeatureValue), without which the text-rendering plugins
    # (libgstassrender / libgstclosedcaption / libgstpango) fail to dlopen on 10.9. libharfbuzz's CoreText
    # dependency is repointed to @rpath/libcoretext_compat.dylib (reexports CoreText + supplies the two).
    bash "$REPO/MavericksSupport/deps/gstreamer/build-coretext-compat.sh" >/dev/null \
        && echo "  rebuilt libcoretext_compat.dylib" \
        || echo "  warning: libcoretext_compat.dylib rebuild failed — deploying the checked-in copy"
    # And the AudioToolbox compat shim: libgstosxaudio (osxaudiosink) imports the AudioComponent API
    # (AudioComponentFindNext / InstanceNew / InstanceDispose) which the 26.1 SDK homes in AudioToolbox
    # but 10.9 keeps in AudioUnit, so without it the macOS audio sink fails to dlopen and there is no
    # audio output. libgstosxaudio's AudioToolbox dependency is repointed to @rpath/libaudiotoolbox_compat.dylib
    # (reexports AudioToolbox + AudioUnit).
    bash "$REPO/MavericksSupport/deps/gstreamer/build-audiotoolbox-compat.sh" >/dev/null \
        && echo "  rebuilt libaudiotoolbox_compat.dylib" \
        || echo "  warning: libaudiotoolbox_compat.dylib rebuild failed — deploying the checked-in copy"
    mkdir -p "$GST_DEPLOY"
    cp -Rp "$GST_SRC/." "$GST_DEPLOY/"
    # applemedia (#117): the macOS-26-built libgstapplemedia.dylib (avfvideosrc / avfdeviceprovider --
    # the macOS camera-capture plugin) hard-links Metal.framework (absent on 10.9) via its dead
    # Vulkan/MoltenVK video path and references 15 CoreVideo/AVFoundation constants added after 10.9, so
    # it fails to dlopen and getUserMedia/enumerateDevices report no camera. This builds the stubs +
    # reexport shims into $GST_DEPLOY and repoints the plugin onto them so it loads (camera capture works).
    bash "$REPO/MavericksSupport/deps/gstreamer/build-applemedia-compat.sh" "$GST_DEPLOY" >/dev/null \
        && echo "  built applemedia compat shims (camera capture)" \
        || echo "  warning: applemedia compat build failed — camera capture (getUserMedia video) will not work"
    # WebRTC audio DSP: the C++17 libs libgstwebrtcdsp + libwebrtc-audio-processing link the 10.9 system
    # libc++ (too old for std::bad_optional_access etc.) and fail to dlopen, so getUserMedia/WebRTC audio
    # gets no echo cancellation / noise suppression. Repoint them onto the bundle's modern C++ runtime.
    bash "$REPO/MavericksSupport/deps/gstreamer/build-cxxgst-compat.sh" "$GST_DEPLOY" >/dev/null \
        && echo "  built cxxgst compat shim (WebRTC audio DSP)" \
        || echo "  warning: cxxgst compat build failed — WebRTC audio DSP plugins will not load"
else
    echo "  warning: GStreamer source tree $GST_SRC missing — media will not load"
fi
# Sandbox grants read only to world-readable files under /System with traversable parents.
# Make the in-bundle lib dirs traversable and the dylibs world-readable.
chmod 755 "$PRIVLIBCXX" "$PRIVLIB" 2>/dev/null || true
chmod 644 "$PRIVLIBCXX"/*.dylib "$PRIVLIB"/*.dylib 2>/dev/null || true
# GStreamer tree: every dir traversable, every dylib world-readable (sandboxed WebContent loads them).
find "$GST_DEPLOY" -type d -exec chmod 755 {} + 2>/dev/null || true
find "$GST_DEPLOY" -type f -name '*.dylib' -exec chmod 644 {} + 2>/dev/null || true
# Remove the pre-#68 standalone runtime dir now that nothing references it (self-contained).
if [ -d "$OLD_PRIVRT" ]; then
    rm -rf "$OLD_PRIVRT"
    echo "  removed legacy $OLD_PRIVRT"
fi

# ---------------------------------------------------------------------------
# #66/#69: the unified undocked Web Inspector toolbar (gradient + 78px traffic-light inset)
# is now injected by WebInspectorUIProxyMac.mm into the inspector frontend HTML at load time,
# so the stock system WebInspectorUI Main.css is left PRISTINE (no system-file edit). The
# native half (_WKInspectorWindow emulating NSWindowStyleMaskFullSizeContentView so #toolbar
# fills the titlebar region) lives in WebKit. Here we only restore the stock Main.css by
# stripping any WK66-UNIFIED rules a previous install appended to it.
echo "### Restoring stock Web Inspector Main.css (#69: toolbar CSS now injected at load time)"
INSPECTOR_CSS=/System/Library/PrivateFrameworks/WebInspectorUI.framework/Versions/A/Resources/Main.css
if [ -f "$INSPECTOR_CSS" ] && grep -q 'WK66-UNIFIED' "$INSPECTOR_CSS"; then
    # Marker-only match — never line-matches the giant minified stylesheet (line 1).
    grep -v 'WK66-UNIFIED' "$INSPECTOR_CSS" > "$INSPECTOR_CSS.tmp66" && mv "$INSPECTOR_CSS.tmp66" "$INSPECTOR_CSS"
    echo "  stripped legacy WK66-UNIFIED rules from $INSPECTOR_CSS (now pristine)"
fi

echo "### Done. Verify with: MavericksSupport/safari7-abi/check-abi-gap.sh and 'otool -L' on each installed binary."
echo "### (Nested XPCServices binaries' @rpath deps are rewritten automatically by install_framework.)"
