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
# CoreGraphics polyfill dylib are installed to /usr/local/lib and our frameworks
# are pointed at them, so the system's old 10.9 libc++ is never used by us and
# never overwritten (it is not a strict superset — see INSTALL-PLAN.md).
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
PRIVLIB=/usr/local/lib
# libc++/libc++abi must NOT go directly in /usr/local/lib: that directory is in the
# default DYLD_FALLBACK_LIBRARY_PATH, so our modern libc++ would shadow the copy
# other tools (cmake, ninja, …) resolve by leaf name and crash them. Put the C++
# runtime in a dedicated subdir that nothing searches implicitly; our frameworks
# reference it by absolute path. (libcg_polyfill.dylib can stay in /usr/local/lib —
# nothing but our frameworks ever requests it.)
PRIVLIBCXX=/usr/local/lib/webkit-private

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
            strip_rpaths "$f"
            verify_no_rpath "$f"
        fi
    done < <(find "$destBundle" -type f -perm +111)
    echo "  installed."
}

echo "### Deploying private C++ runtime to $PRIVLIBCXX (out of the fallback path)"
mkdir -p "$PRIVLIBCXX"
for lib in libc++.1.dylib libc++abi.1.dylib; do
    cp -f "$TC/lib/$lib" "$PRIVLIBCXX/$lib"
    "$INT" -id "$PRIVLIBCXX/$lib" "$PRIVLIBCXX/$lib"
done
# libc++ depends on libc++abi via @rpath; pin it absolute too. The toolchain's
# libc++abi also carries a self-referential @rpath/libc++abi LC_LOAD_DYLIB —
# pin that as well, or dyld fails to load it in processes with no rpath set.
"$INT" -change @rpath/libc++abi.1.dylib "$PRIVLIBCXX/libc++abi.1.dylib" "$PRIVLIBCXX/libc++.1.dylib" 2>/dev/null || true
"$INT" -change @rpath/libc++abi.1.dylib "$PRIVLIBCXX/libc++abi.1.dylib" "$PRIVLIBCXX/libc++abi.1.dylib" 2>/dev/null || true
echo "### Deploying CG polyfill to $PRIVLIB"
mkdir -p "$PRIVLIB"
if [ -f "$HERE/prebuilt/libcg_polyfill.dylib" ]; then
    backup "$PRIVLIB/libcg_polyfill.dylib"
    cp -f "$HERE/prebuilt/libcg_polyfill.dylib" "$PRIVLIB/libcg_polyfill.dylib"
    "$INT" -id "$PRIVLIB/libcg_polyfill.dylib" "$PRIVLIB/libcg_polyfill.dylib"
fi

echo "### Installing frameworks (name shift)"
install_framework JavaScriptCore "$FRAMEWORKS_DIR/JavaScriptCore.framework" JavaScriptCore
install_framework WebCore        "$PRIVATE_DIR/WebCore.framework"           WebCore
install_framework WebKitLegacy   "$FRAMEWORKS_DIR/WebKit.framework"         WebKit
install_framework WebKit         "$PRIVATE_DIR/WebKit2.framework"           WebKit2

echo "### Done. Verify with: MavericksSupport/safari7-abi/check-abi-gap.sh and 'otool -L' on each installed binary."
echo "### (Nested XPCServices binaries' @rpath deps are rewritten automatically by install_framework.)"
