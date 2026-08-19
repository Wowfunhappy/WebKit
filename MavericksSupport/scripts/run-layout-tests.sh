#!/bin/bash
# Run WebKit layout tests against the build-dir test drivers on macOS 10.9, without installing anything
# over the system. One wrapper, two ports — the port is never inferred:
#
#   --wk1   WebKit1, driver = DumpRenderTree      (run-webkit-tests -1)
#   --wk2   WebKit2, driver = WebKitTestRunner    (run-webkit-tests -2)
#
# Prereqs (one-time): build the drivers with the layout-test config enabled —
#   cmake -S . -B WebKitBuild/Release -DDEVELOPER_MODE=ON -DENABLE_LAYOUT_TESTS=ON \
#         -DENABLE_API_TESTS=OFF -DDEVELOPER_MODE_FATAL_WARNINGS=OFF
#   --wk1:  ninja -C WebKitBuild/Release DumpRenderTree ImageDiff LayoutTestHelper
#   --wk2:  ninja -C WebKitBuild/Release WebKitTestRunner TestRunnerInjectedBundle ImageDiff
# (Flip ENABLE_LAYOUT_TESTS back OFF + rebuild before install.sh: the test build instruments WebCore
#  with Internals and must not be shipped over the system.)
#
# Before each run the in-place build frameworks are made loadable (idempotent, re-done after any relink):
# the polyfill classes dylib is staged into WebKitBuild/Release/lib (already on every build binary's
# @rpath) and every direct dependency on a post-10.9 system framework is repointed to it, so dyld resolves
# them from the build tree for both the in-process drivers and the launchd-spawned WebKit2 XPC services
# (which get no DYLD_*); the WebKit2 injected bundle is assembled as a real .bundle beside the driver.
# See [[webkit-mavericks-wktr-wk2]].
#
# Usage:  bash MavericksSupport/scripts/run-layout-tests.sh --wk1|--wk2 [run-webkit-tests args] <test paths...>
#   e.g.  bash MavericksSupport/scripts/run-layout-tests.sh --wk1 storage/domstorage/localstorage/
#         bash MavericksSupport/scripts/run-layout-tests.sh --wk2 --child-processes=2 fast/dom/ fast/css/
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() {
    echo "Usage: bash MavericksSupport/scripts/run-layout-tests.sh --wk1|--wk2 [run-webkit-tests args] <test paths...>" >&2
    echo "       --wk1 = WebKit1/DumpRenderTree, --wk2 = WebKit2/WebKitTestRunner (required, never inferred)" >&2
}

case "${1-}" in
    --wk1) PORT_FLAG="-1"; DRIVER="DumpRenderTree";   NINJA_TARGETS="DumpRenderTree ImageDiff LayoutTestHelper" ;;
    --wk2) PORT_FLAG="-2"; DRIVER="WebKitTestRunner"; NINJA_TARGETS="WebKitTestRunner TestRunnerInjectedBundle ImageDiff" ;;
    *)     usage; exit 2 ;;
esac
shift

if [ ! -x "$ROOT/WebKitBuild/Release/bin/$DRIVER" ]; then
    echo "$DRIVER not built — see the prereqs at the top of $0" >&2
    echo "  ninja -C WebKitBuild/Release $NINJA_TARGETS" >&2
    exit 1
fi

# Orphan hygiene + worker cap: an aborted run orphans build-tree test processes (killing the python
# runner does not reach grandchildren), and an orphan parked on a GL-retrying test page spams
# "CoreAnimation: failed to create OpenGL context" until 10.9's WindowServer hits its null-texture
# compositor race and takes the login session down. So reap stale build-tree test processes before
# starting AND on every exit (both drivers, whichever port), and refuse more than 2 parallel workers.
reap_test_orphans() {
    pkill -9 -f "WebKitBuild/Release/bin/DumpRenderTree" 2>/dev/null
    pkill -9 -f "WebKitBuild/Release/bin/WebKitTestRunner" 2>/dev/null
    pkill -9 -f "WebKitBuild/Release/.*com\.apple\.WebKit\.(WebContent|Networking)" 2>/dev/null
    return 0
}
reap_test_orphans
trap reap_test_orphans EXIT INT TERM
for arg in "$@"; do
    case "$arg" in
        --child-processes=*)
            n="${arg#*=}"
            if [ "$n" -gt 2 ] 2>/dev/null; then
                echo "ERROR: --child-processes=$n refused — >2 parallel workers can crash 10.9's WindowServer (grey screen, session logout). Use --child-processes=2." >&2
                exit 1
            fi;;
    esac
done

# --- Make the in-place build frameworks loadable ------------------------------------------------
LIBDIR="$ROOT/WebKitBuild/Release/lib"
BINDIR="$ROOT/WebKitBuild/Release/bin"
POLYBUILD="$ROOT/MavericksSupport/polyfill/build"
WKTR_DIR="$ROOT/Tools/WebKitTestRunner"
INT="${INSTALL_NAME_TOOL:-install_name_tool}"

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
    if ! loaded=$(/usr/bin/otool -L "$bin"); then
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
    $XPC_BINS; do
    [ -f "$fwbin" ] || continue
    # The two polyfill dylibs already carry an @rpath install_name (build-polyfill.sh), so the build records
    # @rpath/<leaf> and they resolve from the staged copies in $LIBDIR — no rewrite needed. Only the post-10.9
    # system frameworks the build still links directly need redirecting onto the reexporting polyfill.
    for fw in $REDIRECT_FRAMEWORKS; do
        repoint_all "$fwbin" "/System/Library/Frameworks/${fw}.framework/" "$POLY"
    done
    echo "  repointed $(basename "$fwbin")"
done

# --- Run ------------------------------------------------------------------------------------------

# point the leaf-name libpolyfill_classes.dylib resolution at OUR repo's polyfill build dir
# (NOT /usr/local/lib, NOT a system path). This matters only when the Safari 7 backport is ALSO installed
# system-wide: the test driver links Quartz, which transitively loads the SYSTEM (installed-backport)
# JavaScriptCore.framework and its bundled libpolyfill_classes.dylib. Without this, the build's @rpath copy and
# the system framework's bundled copy are two different files => duplicate ObjC class registration => crash. The
# leaf override unifies both loads onto the single repo copy. Self-contained to the repo; never written to /usr.
export DYLD_LIBRARY_PATH="$ROOT/MavericksSupport/polyfill/build${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"

# No exec: the runner must stay our child so the EXIT trap can reap orphans even
# when this wrapper is interrupted.
"$ROOT/MavericksSupport/toolchain/build/python3/bin/python3" "$ROOT/Tools/Scripts/run-webkit-tests" \
    "$PORT_FLAG" --no-build --no-new-test-results --release --root="$ROOT/WebKitBuild/Release/bin" \
    "$@"
exit $?
