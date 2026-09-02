#!/bin/bash
# Make the in-place build products loadable on 10.9, without installing anything over the system.
#
# The build-dir frameworks are not standalone-loadable: install.sh normally redirects their post-10.9
# framework dependencies onto the polyfill at install time. This applies just that, in place and
# idempotently, so a test driver run straight out of WebKitBuild/Release resolves everything from the
# build tree -- including the WebKit2 XPC services, which launchd spawns with no DYLD_* of their own.
# Re-run it after any relink; the run wrappers do.
#
# Usage: bash MavericksSupport/scripts/make-build-binaries-runnable.sh [extra Mach-O paths...]
#   Extra paths are repointed alongside the frameworks, the two layout-test drivers and the XPC
#   services -- that is where an API-test binary goes.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXTRA_BINS="$*"

LIBDIR="$ROOT/WebKitBuild/Release/lib"
BINDIR="$ROOT/WebKitBuild/Release/bin"
POLYBUILD="$ROOT/MavericksSupport/polyfill/build"
WKTR_DIR="$ROOT/Tools/WebKitTestRunner"
. "$ROOT/MavericksSupport/scripts/cctools.sh"
INT="$CCTOOLS/install_name_tool"

# install_name_tool over a file this script just copied. A failure is the Mach-O being unwritable or
# out of load-command padding, and the copy would keep the install name it was built with.
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

# WebKit2 XPC service executables (WebContent/Networking/GPU) link the post-10.9 system frameworks directly, so
# they need the same redirection as the frameworks.
XPC_BINS=""
XPCDIR="$LIBDIR/WebKit.framework/Versions/A/XPCServices"
if [ -d "$XPCDIR" ]; then
    for svc in "$XPCDIR"/*.xpc; do
        exe="$svc/Contents/MacOS/$(basename "${svc%.xpc}")"
        [ -f "$exe" ] && XPC_BINS="$XPC_BINS $exe"
    done
fi

# WebKitTestRunner's WebKit2 injected bundle: the cmake build emits it as a plain dylib (lib/libTestRunnerInjected
# Bundle.dylib), but -[NSBundle initWithPath:] in the WebContent process needs a real .bundle wrapper next to the
# executable (TestController::initializeInjectedBundlePath builds the path from the main bundle). Assemble/refresh
# it here, and include its binary in the repoint pass below so its polyfill deps resolve from the build tree too.
BUNDLE_BIN=""
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
    BUNDLE_BIN="$IB_EXE"
fi

# change every dependency matching <substr> to <new> (handles 0..N matches; idempotent if already <new>).
repoint_all() { # bin substr new
    local bin="$1" substr="$2" new="$3" dep deps loaded
    # otool's own status first: it exits 1 on a file it cannot read, which is not "no matching deps".
    if ! loaded=$("$CCTOOLS/otool" -L "$bin"); then
        echo "ERROR: could not read the load commands of $bin" >&2
        exit 1
    fi
    # The greps are the 0-match half of "0..N matches", so their status-1 is the answer, not a failure.
    deps=$(echo "$loaded" | awk '{print $1}' | grep -F "$substr" | grep -vF "$new" | sort -u \
           || [ "$?" -eq 1 ])
    [ -n "$deps" ] || return 0
    while IFS= read -r dep; do
        if ! "$INT" -change "$dep" "$new" "$bin"; then
            echo "ERROR: could not repoint $dep to $new in $bin" >&2
            exit 1
        fi
    done <<< "$deps"
}

for fwbin in \
    "$LIBDIR/JavaScriptCore.framework/Versions/A/JavaScriptCore" \
    "$LIBDIR/WebCore.framework/Versions/A/WebCore" \
    "$LIBDIR/WebKitLegacy.framework/Versions/A/WebKitLegacy" \
    "$LIBDIR/WebKit.framework/Versions/A/WebKit" \
    "$BINDIR/DumpRenderTree" \
    "$BINDIR/WebKitTestRunner" \
    $BUNDLE_BIN \
    $XPC_BINS \
    $EXTRA_BINS; do
    [ -f "$fwbin" ] || continue
    # The two polyfill dylibs already carry an @rpath install_name (build-polyfill.sh), so the build records
    # @rpath/<leaf> and they resolve from the staged copies in $LIBDIR — no rewrite needed. Only the post-10.9
    # system frameworks the build still links directly need redirecting onto the reexporting polyfill.
    for fw in $REDIRECT_FRAMEWORKS; do
        repoint_all "$fwbin" "/System/Library/Frameworks/${fw}.framework/" "$POLY"
    done
    echo "  repointed $(basename "$fwbin")"
done

