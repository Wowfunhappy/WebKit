#!/bin/bash
# Make the in-place build products loadable on 10.9, without installing anything over the system.
#
# The build-dir binaries are not standalone-loadable. stage-frameworks.sh gives the product two things
# the linked binaries lack: their post-10.9 framework dependencies redirected onto the polyfill, and
# their C++ runtime bound to private libc++/libc++abi copies that drive the system unwinder
# (single-unwinder rule, framework-layout.sh). This applies both to every Mach-O under
# WebKitBuild/Release/{bin,lib}, in place and idempotently, so a test driver run straight out of the
# build tree resolves everything from it -- including the WebKit2 XPC services, which launchd spawns
# with no DYLD_* of their own -- and never loads the toolchain's libc++/libc++abi/libunwind.1.
# Re-run it after any relink; the run wrappers do.
#
# The build tree keeps the @rpath form of every dependency, which is what stage-frameworks.sh maps
# into the product when it stages a binary this script has rewritten. Resolution is steered through
# each binary's LC_RPATHs instead: the toolchain's entries go, the build's lib dir is present, and any
# other directory offering a C++ runtime comes after it. Every rewrite changes load commands only, so
# each file keeps the mtime the link gave it and ninja's view of the build stays unchanged.
#
# Usage: bash MavericksSupport/scripts/make-build-binaries-runnable.sh [extra Mach-O paths...]
#   Extra paths are rewritten and verified alongside the build tree's own Mach-Os.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXTRA_BINS="$*"

LIBDIR="$ROOT/WebKitBuild/Release/lib"
BINDIR="$ROOT/WebKitBuild/Release/bin"
POLYBUILD="$ROOT/MavericksSupport/polyfill/build"
WKTR_DIR="$ROOT/Tools/WebKitTestRunner"
TC="${MAVERICKS_CLANG:-$ROOT/MavericksSupport/toolchain/build/clang}"
# The GStreamer plugins build.sh mirrors from the staged product; WebContent loads them through
# GST_PLUGIN_SYSTEM_PATH. They reference only real 10.9 frameworks, so they take the C++ runtime and
# unwinder rewrites and not the framework redirect.
GST_PLUGINS="$LIBDIR/WebCore.framework/Versions/A/Frameworks/gstreamer/lib/gstreamer-1.0"
# framework-layout.sh: SYSTEM_UNWINDER, and the cctools (CCTOOLS) it sources.
. "$ROOT/MavericksSupport/scripts/framework-layout.sh"
INT="$CCTOOLS/install_name_tool"

# A directory's canonical path (the path itself when it does not exist): LC_RPATH entries are compared
# by the directory they name, whatever spelling the build or MAVERICKS_CLANG gave it.
canon() { (cd "$1" 2>/dev/null && pwd -P) || echo "$1"; }
TC_REAL="$(canon "$TC")"
LIBDIR_REAL="$(canon "$LIBDIR")"

# install_name_tool over a file this script rewrites. A failure is the Mach-O being unwritable or
# out of load-command padding, and the file would keep the load commands it was built with.
int_or_die() {
    if ! "$INT" "$@"; then
        echo "ERROR: install_name_tool $* failed" >&2
        exit 1
    fi
}

# Polyfill dylibs the build links, and the post-10.9 frameworks whose missing symbols libpolyfill_classes supplies.
POLYFILL_LEAVES="libpolyfill_classes.dylib"
REDIRECT_FRAMEWORKS="QuartzCore Security CoreServices CFNetwork"
POLY="@rpath/libpolyfill_classes.dylib"   # resolved from WebKitBuild/Release/lib via each binary's @rpath

# Stage the polyfills into the build's @rpath dir with an @rpath install id (refresh when the source is newer).
for leaf in $POLYFILL_LEAVES; do
    src="$POLYBUILD/$leaf"; dst="$LIBDIR/$leaf"
    [ -f "$src" ] || continue
    if [ ! -f "$dst" ] || [ "$src" -nt "$dst" ]; then
        if ! cp -f "$src" "$dst"; then
            echo "ERROR: could not stage $src into $LIBDIR" >&2
            exit 1
        fi
        int_or_die -id "@rpath/$leaf" "$dst"
        echo "  staged $leaf -> $LIBDIR"
    fi
done

# Stage the private C++ runtime into the build's lib dir (refresh when the toolchain's is newer). The
# copies keep their @rpath install names; the rewrite pass below binds their unwinder load to the
# system one and gives them the LC_RPATH that resolves libc++abi beside libc++, like every other
# Mach-O here. Each refresh is written beside the copy and moved into place, a new inode each time.
for lib in libc++.1.dylib libc++abi.1.dylib; do
    src="$TC/lib/$lib"; dst="$LIBDIR/$lib"
    if [ ! -f "$src" ]; then
        echo "ERROR: $src missing — the toolchain's C++ runtime is what the build links against" >&2
        exit 1
    fi
    if [ ! -f "$dst" ] || [ "$src" -nt "$dst" ]; then
        if ! cp -f "$src" "$dst.tmp" || ! mv -f "$dst.tmp" "$dst"; then
            echo "ERROR: could not stage $src into $LIBDIR" >&2
            exit 1
        fi
        echo "  staged $lib -> $LIBDIR"
    fi
done

# WebKitTestRunner's WebKit2 injected bundle: the cmake build emits it as a plain dylib (lib/libTestRunnerInjected
# Bundle.dylib), but -[NSBundle initWithPath:] in the WebContent process needs a real .bundle wrapper next to the
# executable (TestController::initializeInjectedBundlePath builds the path from the main bundle). Assemble/refresh
# it here; the rewrite pass below covers its binary like every other Mach-O under bin/.
IB_SRC="$LIBDIR/libTestRunnerInjectedBundle.dylib"
if [ -f "$IB_SRC" ]; then
    IB_BUNDLE="$BINDIR/WebKitTestRunnerInjectedBundle.bundle"
    IB_EXE="$IB_BUNDLE/Contents/MacOS/WebKitTestRunnerInjectedBundle"
    if [ ! -f "$IB_EXE" ] || [ "$IB_SRC" -nt "$IB_EXE" ]; then
        mkdir -p "$IB_BUNDLE/Contents/MacOS"
        if ! cp -f "$IB_SRC" "$IB_EXE"; then
            echo "ERROR: could not assemble $IB_EXE from $IB_SRC" >&2
            exit 1
        fi
        int_or_die -id "WebKitTestRunnerInjectedBundle" "$IB_EXE"
        # The injected bundle activates the layout-test fonts from its own Contents/Resources
        # (ActivateFontsCocoa.mm: -[NSBundle bundleForClass:] resourceURL). Apple's Xcode build copies the
        # WebKitTestRunner font set there; mirror that so CTFontManagerRegisterFontsForURLs succeeds (otherwise
        # activateFonts() calls exit(1) and the WebContent process dies before running any test).
        mkdir -p "$IB_BUNDLE/Contents/Resources"
        if ! cp -f "$WKTR_DIR/fonts/"* "$IB_BUNDLE/Contents/Resources/" ||
           ! cp -f "$WKTR_DIR/FontWithFeatures.otf" "$WKTR_DIR/FontWithFeatures.ttf" \
                   "$IB_BUNDLE/Contents/Resources/"; then
            echo "ERROR: could not stage the layout-test fonts into $IB_BUNDLE/Contents/Resources" >&2
            exit 1
        fi
        if [ ! -f "$IB_BUNDLE/Contents/Info.plist" ]; then
            cat > "$IB_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>English</string>
  <key>CFBundleExecutable</key><string>WebKitTestRunnerInjectedBundle</string>
  <key>CFBundleIdentifier</key><string>com.apple.WebKitTestRunnerInjectedBundle</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST
        fi
        echo "  assembled WebKitTestRunnerInjectedBundle.bundle"
    fi
fi

# The load commands of one Mach-O, read once. Fails on a file otool cannot read: that is not "no
# load commands".
load_commands() { # bin
    local out
    if ! out=$("$CCTOOLS/otool" -l "$1"); then
        echo "ERROR: could not read the load commands of $1" >&2
        exit 1
    fi
    echo "$out"
}
# The dylibs a Mach-O loads (every LC_*_DYLIB except its own LC_ID_DYLIB), and its LC_RPATHs, in order.
loaded_dylibs() { echo "$1" | awk '/^ *cmd /{c=$2} /^ *name /{if (c != "LC_ID_DYLIB") print $2}'; }
lc_rpaths()     { echo "$1" | awk '/cmd LC_RPATH/{r=1} r && /^ *path /{print $2; r=0}'; }

# change every dependency matching <substr> to <new> (handles 0..N matches; idempotent if already <new>).
repoint_all() { # bin substr new
    local bin="$1" substr="$2" new="$3" dep deps loaded
    # otool's own status first: it exits 1 on a file it cannot read, which is not "no matching deps".
    if ! loaded=$("$CCTOOLS/otool" -L "$bin"); then
        echo "ERROR: could not read the load commands of $bin" >&2
        exit 1
    fi
    # Line 1 is the file's own path. The greps are the 0-match half of "0..N matches", so their status-1
    # is the answer, not a failure.
    deps=$(echo "$loaded" | awk 'NR > 1 {print $1}' | grep -F "$substr" | grep -vF "$new" | sort -u \
           || [ "$?" -eq 1 ])
    [ -n "$deps" ] || return 0
    while IFS= read -r dep; do
        if ! "$INT" -change "$dep" "$new" "$bin"; then
            echo "ERROR: could not repoint $dep to $new in $bin" >&2
            exit 1
        fi
    done <<< "$deps"
}

# Rewrite one Mach-O's LC_RPATHs so @rpath/libc++.1.dylib and @rpath/libc++abi.1.dylib resolve at
# $LIBDIR: the toolchain's entries are deleted, and for a binary that loads the runtime that way
# $LIBDIR is added when absent and any other absolute entry that offers a C++ runtime ahead of it is
# moved behind it (dyld searches a binary's own LC_RPATHs in order, before those of the images that
# loaded it).
fix_rpaths() { # bin
    local bin="$1" cmds rp real have_libdir=0 move="" loads_runtime
    cmds=$(load_commands "$bin") || exit 1
    loads_runtime=$(loaded_dylibs "$cmds" | grep -c '^@rpath/libc++')
    for rp in $(lc_rpaths "$cmds"); do
        case "$rp" in /*) ;; *) continue;; esac
        real="$(canon "$rp")"
        case "$real" in
            "$TC_REAL"/*)   int_or_die -delete_rpath "$rp" "$bin";;
            "$LIBDIR_REAL") have_libdir=1;;
            *)              [ "$have_libdir" = 1 ] && continue
                            if [ -e "$real/libc++.1.dylib" ] || [ -e "$real/libc++abi.1.dylib" ]; then
                                move="$move $rp"
                            fi;;
        esac
    done
    [ "$loads_runtime" -gt 0 ] || return 0
    [ "$have_libdir" = 1 ] || int_or_die -add_rpath "$LIBDIR" "$bin"
    for rp in $move; do
        int_or_die -delete_rpath "$rp" "$bin"
        int_or_die -add_rpath "$rp" "$bin"
    done
}

# Every Mach-O under bin/ and lib/ (executables, dylibs, bundle and XPC service binaries, the mirrored
# GStreamer plugins, the staged runtime copies), plus any extra path given.
build_tree_machos() {
    local f
    while IFS= read -r f; do
        case "$(file -b "$f")" in *Mach-O*) echo "$f";; esac
    done < <(find "$BINDIR" "$LIBDIR" -type f \( -perm +111 -o -name '*.dylib' \) 2>/dev/null | sort)
    for f in $EXTRA_BINS; do [ -f "$f" ] && echo "$f"; done
}
MACHOS=$(build_tree_machos)

# Carries each Mach-O's link-time mtime across its rewrite (touch -r copies the timestamp exactly).
MTIME_REF=$(mktemp -t make-build-binaries-runnable) || exit 1
trap 'rm -f "$MTIME_REF"' EXIT

for bin in $MACHOS; do
    touch -r "$bin" "$MTIME_REF"
    case "$bin" in
        "$GST_PLUGINS"/*) ;;
        *)
            # The polyfill dylib carries an @rpath install_name (build-polyfill.sh), so the build records
            # @rpath/<leaf> and it resolves from the staged copy in $LIBDIR — no rewrite needed. Only the
            # post-10.9 system frameworks the build links directly need redirecting onto the reexporting polyfill.
            # A reexport provider must retain its native dependencies. Redirecting its own
            # imports back to its install ID makes a self-reexport cycle in dyld.
            install_id=$("$CCTOOLS/otool" -D "$bin" 2>/dev/null | tail -n +2)
            if [ "$install_id" != "$POLY" ]; then
                for fw in $REDIRECT_FRAMEWORKS; do
                    repoint_all "$bin" "/System/Library/Frameworks/${fw}.framework/" "$POLY"
                done
            fi;;
    esac
    # C++ runtime in @rpath form under every path a load command may carry, resolved through the
    # LC_RPATHs; the unwinder is the system one, under any path the private one may carry.
    repoint_all "$bin" "libc++.1.dylib" "@rpath/libc++.1.dylib"
    repoint_all "$bin" "libc++abi.1.dylib" "@rpath/libc++abi.1.dylib"
    repoint_all "$bin" "libunwind.1.dylib" "$SYSTEM_UNWINDER"
    fix_rpaths "$bin"
    touch -r "$MTIME_REF" "$bin"
done
echo "  rewrote $(echo "$MACHOS" | grep -c .) Mach-Os under WebKitBuild/Release/{bin,lib}"

# Single-unwinder gate over the build tree, the counterpart of stage-frameworks.sh's over the product.
# For every Mach-O above: no private libunwind load, no LC_RPATH into the toolchain, and each C++
# runtime load in @rpath form resolving -- through the binary's own LC_RPATHs, in dyld's order -- at
# the copy in $LIBDIR.
echo "  verifying single-unwinder rule over the build tree"
VIOLATIONS=0
violation() { echo "  VIOLATION: $1: $2" >&2; VIOLATIONS=$((VIOLATIONS + 1)); }
verify_runtime_binding() { # bin
    local bin="$1" cmds names rpaths name leaf rp dir resolved
    cmds=$(load_commands "$bin") || exit 1
    names=$(loaded_dylibs "$cmds")
    rpaths=$(lc_rpaths "$cmds")
    if [ "$(echo "$names" | grep -cF libunwind.1.dylib)" -gt 0 ]; then
        violation "$bin" "loads a private libunwind.1.dylib"
    fi
    for rp in $rpaths; do
        case "$(canon "$rp")" in "$TC_REAL"/*) violation "$bin" "LC_RPATH into the toolchain: $rp";; esac
    done
    for name in $names; do
        leaf="${name##*/}"
        case "$leaf" in libc++.1.dylib|libc++abi.1.dylib) ;; *) continue;; esac
        if [ "$name" != "@rpath/$leaf" ]; then
            violation "$bin" "loads $name (a C++ runtime outside $LIBDIR)"
            continue
        fi
        resolved=""
        for rp in $rpaths; do
            dir="$rp"
            case "$dir" in @loader_path*) dir="$(dirname "$bin")${dir#@loader_path}";; esac
            if [ -e "$dir/$leaf" ]; then resolved="$dir"; break; fi
        done
        [ -n "$resolved" ] && [ "$(canon "$resolved")" = "$LIBDIR_REAL" ] ||
            violation "$bin" "@rpath/$leaf resolves at ${resolved:-no LC_RPATH of its own}, not $LIBDIR"
    done
}
for bin in $MACHOS; do
    verify_runtime_binding "$bin"
done
if [ "$VIOLATIONS" -ne 0 ]; then
    echo "ERROR: $VIOLATIONS build-tree binaries would load a C++ runtime or unwinder other than the build's (mixed-unwinder hazard)" >&2
    exit 1
fi
