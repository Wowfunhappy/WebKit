#!/bin/bash
# framework-layout.sh — the on-disk layout of the installed backport, shared by the
# build-time stager (scripts/stage-frameworks.sh) and the installer (install.sh).
# This file is SOURCED, never executed: it defines paths, helpers and one verification
# gate, and performs no work of its own.
#
# Name shift (built framework -> installed bundle, installed binary name):
#   JavaScriptCore -> /System/Library/Frameworks/JavaScriptCore.framework           (bin: JavaScriptCore)
#   WebKitLegacy   -> /System/Library/Frameworks/WebKit.framework                   (bin: WebKit)
#   WebCore        -> ...WebKit.framework/Versions/A/Frameworks/WebCore.framework   (bin: WebCore — nested, as on stock 10.9)
#   WebKit (WK2)   -> /System/Library/PrivateFrameworks/WebKit2.framework           (bin: WebKit2)

WK_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WK_SUPPORT="$WK_REPO/MavericksSupport"
# The frameworks ninja links, as the build names them.
WK_LIBDIR="$WK_REPO/WebKitBuild/Release/lib"
# The complete, installable product the build produces: a tree laid out exactly as it
# lands on disk, so installing is a plain copy. Under WebKitBuild, hence gitignored.
WK_STAGE_ROOT="${WK_STAGE_ROOT:-$WK_REPO/WebKitBuild/Release/staged}"

# ---------------------------------------------------------------------------
# Installed locations. Every path below is the FINAL absolute path; the staged tree
# mirrors it under $WK_STAGE_ROOT, so "$WK_STAGE_ROOT$SOME_PATH" is its staged twin.
FRAMEWORKS_DIR=/System/Library/Frameworks
PRIVATE_DIR=/System/Library/PrivateFrameworks
JSC_BUNDLE=$FRAMEWORKS_DIR/JavaScriptCore.framework
WEBKIT_BUNDLE=$FRAMEWORKS_DIR/WebKit.framework
WEBKIT2_BUNDLE=$PRIVATE_DIR/WebKit2.framework
# WebCore is nested INSIDE the public WebKit umbrella, matching the stock 10.9 layout: stock has NO
# top-level /System/Library/PrivateFrameworks/WebCore.framework — its WebKit2/WebKit binaries link
# WebCore at this nested path.
WEBCORE_BUNDLE=$WEBKIT_BUNDLE/Versions/A/Frameworks/WebCore.framework
# The three bundles an install replaces. WebCore rides inside WEBKIT_BUNDLE.
WK_INSTALL_ROOTS="$JSC_BUNDLE $WEBKIT_BUNDLE $WEBKIT2_BUNDLE"

# #68: the private C++ runtime (libc++/libc++abi from the clang-22 toolchain) and the polyfill
# ObjC-classes dylib live INSIDE the framework bundles, so the product is fully self-contained —
# nothing in /usr/local and no separate top-level runtime dir. Both homes are under
# /System/Library/[Private]Frameworks, which the sandbox grants read to (the #18 reason these can't
# live in /usr/local: sandboxd "deny file-read-data /usr/local/lib/webkit-private/..."); binaries
# reference them by ABSOLUTE in-bundle path (never @rpath) so they can't shadow the system libc++
# via DYLD_FALLBACK. libc++/libc++abi go in the base framework (JavaScriptCore — every WebKit
# framework links the C++ runtime).
# The unwinder is NOT vendored: a process must have exactly one _Unwind_* implementation, and
# system frames (Foundation, libobjc, app plug-ins like iBooks' BKEpubWebProcessPlugIn) always
# drive /usr/lib/system/libunwind.dylib. An exception crossing system and backport frames with a
# second, newer libunwind loaded hands the system unwinder's opaque _Unwind_Context to the modern
# accessors (different UnwindCursor layout) and crashes mid-unwind, so every @rpath/libunwind
# reference is bound to the system unwinder instead (its exports cover all symbols we import:
# _Unwind_Resume plus libc++abi's eight classic _Unwind_* entry points).
PRIVLIBCXX=$JSC_BUNDLE/Versions/A/Frameworks
SYSTEM_UNWINDER=/usr/lib/system/libunwind.dylib
# GStreamer (#90) ships inside WebCore's own Frameworks dir.
PRIVLIB=$WEBCORE_BUNDLE/Versions/A/Frameworks
GST_DEPLOY=$PRIVLIB/gstreamer/lib
XPCSERVICES=$WEBKIT2_BUNDLE/Versions/A/XPCServices

# Canonical stock backup (flat *.framework dirs), captured once by
# scripts/stage-frameworks.sh and read by the i386 graft.
STOCK_BACKUP="${STOCK_BACKUP:-$(dirname "$WK_REPO")/stock-webkit-backup}"

# macOS 10.9's QuickLook launches the FIXED helper-service set the 2014 stock WebKit shipped, so the
# product ships those nine bundles -- Networking and WebContent plus seven identity-renamed clones --
# alongside the GPU service. WebContent.EnhancedSecurity is the eighth clone, for a different caller:
# ProcessLauncherCocoa::webContentServiceName asks for it by name whenever a navigation carries
# enhanced security, which the Cocoa heuristics turn on for plain-http main-frame loads, and a service
# name launchd cannot resolve is a process that never starts. Upstream builds it as a same-binary
# variant carrying entitlements and launch attributes; neither exists on 10.9, so the clone is the
# whole of it. Each entry is "<base service>:<clone name>". See the cloning step in
# stage-frameworks.sh.
WK_XPC_VARIANTS="Networking:Networking.Development
WebContent:WebContent.Development
WebContent:WebContent.EnhancedSecurity
WebContent:OfflineStorage
WebContent:OfflineStorage.Development
WebContent:Plugin.32
WebContent:Plugin.64
WebContent:Plugin.Development"

# The service names launchd resolves, in the spelling xpc_connection_create() passes and
# /System/Library/Caches/com.apple.xpchelper.cache records.
WK_XPC_SERVICES="$(for n in Networking WebContent GPU $(echo "$WK_XPC_VARIANTS" | sed 's/^[^:]*://'); do echo "com.apple.WebKit.$n"; done)"

# Absolute install_name each framework binary advertises (matches Safari's LC_LOAD_DYLIB).
# macOS 10.9 ships bash 3.2 (no associative arrays), so this is a function keyed by the
# installed binary name rather than a `declare -A` map.
id_path() {
    case "$1" in
        JavaScriptCore) echo "$JSC_BUNDLE/Versions/A/JavaScriptCore";;
        WebKit)         echo "$WEBKIT_BUNDLE/Versions/A/WebKit";;        # our WebKitLegacy
        WebKit2)        echo "$WEBKIT2_BUNDLE/Versions/A/WebKit2";;      # our WebKit (WK2)
        WebCore)        echo "$WEBCORE_BUNDLE/Versions/A/WebCore";;      # nested in WebKit.framework (stock layout)
        *) echo "";;
    esac
}

# ---------------------------------------------------------------------------
# cctools, by absolute path.
. "$WK_SUPPORT/scripts/cctools.sh"
INSTALL_NAME_TOOL="$CCTOOLS/install_name_tool"
OTOOL="$CCTOOLS/otool"
LIPO="$CCTOOLS/lipo"

# ---------------------------------------------------------------------------
# The gate that says a tree is a complete, loadable product. The stager runs it on the staged
# tree (its build-time acceptance test) and the installer runs it on the staged tree before
# writing to /System and again on /System afterwards, so a truncated copy is caught in all
# three places. $1 = path prefix ("" for the installed system, "$WK_STAGE_ROOT" for the staged
# tree), $2 = label for messages. Requires $OTOOL and $LIPO.
wk_verify_tree() {
    local pre="$1" label="$2"
    local bad=0 f n

    # Every framework binary, including the nested WebCore.
    for f in "$JSC_BUNDLE/Versions/A/JavaScriptCore" \
             "$WEBKIT_BUNDLE/Versions/A/WebKit" \
             "$WEBCORE_BUNDLE/Versions/A/WebCore" \
             "$WEBKIT2_BUNDLE/Versions/A/WebKit2"; do
        if [ ! -f "$pre$f" ]; then
            echo "  MISSING framework binary: $pre$f" >&2; bad=1; continue
        fi
        # Fat with the stock i386 slice: 32-bit WebView apps load the stock legacy WebKit1
        # through these same bundles, and an x86_64-only binary makes dyld reject them.
        case "$("$LIPO" -info "$pre$f" 2>/dev/null)" in
            *i386*) ;;
            *) echo "  NOT FAT (no i386 slice): $pre$f" >&2; bad=1;;
        esac
    done

    # The private C++ runtime and the polyfill ObjC classes every WebKit binary loads.
    for f in "$PRIVLIBCXX/libc++.1.dylib" "$PRIVLIBCXX/libc++abi.1.dylib" \
             "$PRIVLIBCXX/libpolyfill_classes.dylib"; do
        [ -f "$pre$f" ] || { echo "  MISSING in-bundle dylib: $pre$f" >&2; bad=1; }
    done

    # libwebrtc: WebCore and WebKit2 both carry a hard LC_LOAD_DYLIB on it, so a tree without it is
    # a tree where no WebKit app reaches its entry point.
    [ -f "$pre$PRIVLIB/libwebrtc.dylib" ] || {
        echo "  MISSING libwebrtc: $pre$PRIVLIB/libwebrtc.dylib" >&2; bad=1; }

    # GStreamer, the sole media engine.
    [ -f "$pre$GST_DEPLOY/libgstreamer-1.0.0.dylib" ] || {
        echo "  MISSING GStreamer runtime: $pre$GST_DEPLOY/libgstreamer-1.0.0.dylib" >&2; bad=1; }

    # Networking, WebContent and GPU, plus the seven identity-renamed clones QuickLook resolves
    # before it will render a web preview.
    for svc in $WK_XPC_SERVICES; do
        f="$XPCSERVICES/$svc.xpc/Contents/MacOS/$svc"
        [ -f "$pre$f" ] || { echo "  MISSING XPC service executable: $pre$f" >&2; bad=1; }
    done

    # The Web Push daemon: it rides inside WebKit2.framework, and WebKit submits its launchd job
    # from WebsiteDataStoreCocoa.mm by this path, so a tree without it has no Web Push.
    f="$WEBKIT2_BUNDLE/Versions/A/Daemons/webpushd"
    [ -x "$pre$f" ] || { echo "  MISSING Web Push daemon: $pre$f" >&2; bad=1; }

    # Sandbox profiles. AuxiliaryProcess::initializeSandbox() and webpushd's applySandbox() look
    # these up BY NAME under WebKit2.framework's Resources and CRASH()/RELEASE_ASSERT rather than
    # continue when the file is not there, so a missing profile is a child process that dies at
    # launch. The set is exact in both directions: an EXTRA .sb means a profile the build no longer
    # generates is riding along in the build tree (what a renamed custom-command output leaves
    # behind), and shipping a stale security policy is exactly as wrong as shipping none.
    local profiles_dir="$WEBKIT2_BUNDLE/Versions/A/Resources"
    local expected_profiles="com.apple.WebProcess.sb
com.apple.WebKit.NetworkProcess.sb
com.apple.WebKit.GPUProcess.sb
com.apple.WebKit.webpushd.relocatable.mac.sb"
    for n in $expected_profiles; do
        [ -f "$pre$profiles_dir/$n" ] || {
            echo "  MISSING sandbox profile: $pre$profiles_dir/$n" >&2; bad=1; }
    done
    local found expected
    for f in "$pre$profiles_dir"/*.sb; do
        [ -e "$f" ] || continue
        found="$(basename "$f")"
        local known=0
        for expected in $expected_profiles; do
            [ "$found" = "$expected" ] && known=1
        done
        [ "$known" = 1 ] || {
            echo "  UNEXPECTED sandbox profile (stale build output?): $f" >&2; bad=1; }
    done

    # XPCServiceMain resolves the service entry points with
    # CFBundleGetBundleWithIdentifier(com.apple.WebKit2): in this packaging the com.apple.WebKit
    # identity belongs to WebKitLegacy, which exports no service initializers. If WebKit2's
    # Info.plist loses that identifier, every WebContent/Networking spawn exits(1) at bootstrap
    # and launchd respawns them unboundedly — a storm that ends in a 10.9 kernel panic
    # (memorystatus_dirty_set NULL deref). Refuse to ship a tree where the lookup cannot succeed.
    local wk2_plist="$pre$WEBKIT2_BUNDLE/Versions/A/Resources/Info.plist"
    local wk2_identifier
    wk2_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$wk2_plist" 2>/dev/null)"
    [ "$wk2_identifier" = "com.apple.WebKit2" ] || {
        echo "  WRONG WebKit2 bundle identifier ('$wk2_identifier', want com.apple.WebKit2): $wk2_plist" >&2
        echo "  (the XPC service entry-point lookup depends on it; see XPCServiceMain.mm)" >&2; bad=1; }

    # Single-unwinder rule (see the PRIVLIBCXX comment above): every reference is bound to the
    # system unwinder, so a private libunwind anywhere in the tree means a rewrite was missed.
    # Fail loudly rather than ship a process that mixes two _Unwind_* implementations.
    local root bin
    for root in $WK_INSTALL_ROOTS; do
        [ -d "$pre$root" ] || continue
        while read -r bin; do
            [ -n "$bin" ] || continue
            if "$OTOOL" -L "$bin" 2>/dev/null | grep -q 'libunwind\.1\.dylib'; then
                echo "  VIOLATION: $bin references a private libunwind.1.dylib" >&2
                bad=1
            fi
        done < <(find "$pre$root" \( -type f -perm +111 \) -o \( -type f -name '*.dylib' \) 2>/dev/null)
    done

    if [ "$bad" != 0 ]; then
        echo "### FAILED: $label is not a complete WebKit product (see the errors above)." >&2
        return 1
    fi
    echo "  verified: $label is complete (4 framework binaries fat with i386, $(set -- $WK_XPC_SERVICES; echo $#) XPC services, webpushd, private runtime + libwebrtc + GStreamer, single unwinder)"
}
