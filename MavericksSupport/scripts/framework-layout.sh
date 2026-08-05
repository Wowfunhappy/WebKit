#!/bin/bash
# framework-layout.sh — the on-disk layout of the installed backport, shared by the
# build-time stager (scripts/stage-frameworks.sh) and the installer (install-safari7.sh).
# This file is SOURCED, never executed: it defines paths, helpers and one verification
# gate, and performs no work of its own.
#
# Name shift (built framework -> installed bundle, installed binary name):
#   JavaScriptCore -> /System/Library/Frameworks/JavaScriptCore.framework           (bin: JavaScriptCore)
#   WebKitLegacy   -> /System/Library/Frameworks/WebKit.framework                   (bin: WebKit)
#   WebCore        -> ...WebKit.framework/Versions/A/Frameworks/WebCore.framework   (bin: WebCore — nested, as on stock 10.9)
#   WebKit (WK2)   -> /System/Library/PrivateFrameworks/WebKit2.framework           (bin: WebKit2)
# See MavericksSupport/safari7-abi/INSTALL-PLAN.md for the rationale.

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
# scripts/backup-stock-frameworks.sh and read by the i386 graft.
STOCK_BACKUP="${STOCK_BACKUP:-$(dirname "$WK_REPO")/stock-webkit-backup}"

# macOS 10.9's QuickLook launches the FIXED helper-service set the 2014 stock WebKit shipped, so the
# product ships all nine bundles: the two services modern WebKit builds, plus seven identity-renamed
# clones. Each entry is "<base service>:<clone name>". See the cloning step in stage-frameworks.sh.
WK_XPC_VARIANTS="Networking:Networking.Development
WebContent:WebContent.Development
WebContent:OfflineStorage
WebContent:OfflineStorage.Development
WebContent:Plugin.32
WebContent:Plugin.64
WebContent:Plugin.Development"

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
# cctools resolution. /usr/bin/{install_name_tool,lipo,otool} can be xcrun-style shims that
# exec Xcode's xcodebuild — which crashes on 10.9 when a modern Xcode.app is present, and
# errors out when no Xcode/CLT is installed at all. Never trust a candidate by name: probe
# each one with a real invocation and take the first that actually works. Candidate order:
# explicit env override, bare name from PATH (healthy CLT installs), MacPorts cctools
# (mp-<name>), Xcode toolchain binary by absolute path (bypasses the broken shim).
WK_XCTC=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin
wk_probe_lipo()  { "$1" -info /usr/lib/dyld >/dev/null 2>&1; }
wk_probe_otool() { "$1" -h /usr/lib/dyld >/dev/null 2>&1; }
wk_probe_int()   {
    _t="$(mktemp -t int_probe)" || return 1
    cp /usr/lib/libz.1.dylib "$_t" 2>/dev/null || { rm -f "$_t"; return 1; }
    "$1" -id /tmp/int_probe.dylib "$_t" >/dev/null 2>&1; _rc=$?
    rm -f "$_t"; return $_rc
}
wk_resolve_tool() { # $1 = probe fn, $2 = friendly name, $3.. = candidates
    _probe="$1"; _name="$2"; shift 2
    for _cand in "$@"; do
        [ -n "$_cand" ] || continue
        _path="$(command -v "$_cand" 2>/dev/null || true)"
        [ -n "$_path" ] || continue
        if "$_probe" "$_path" 2>/dev/null; then echo "$_path"; return 0; fi
    done
    echo "framework-layout.sh: no working $_name found (tried: $*)" >&2
    return 1
}
wk_find_install_name_tool() { wk_resolve_tool wk_probe_int install_name_tool "${INSTALL_NAME_TOOL:-}" install_name_tool mp-install_name_tool "$WK_XCTC/install_name_tool"; }
wk_find_otool()             { wk_resolve_tool wk_probe_otool otool "${OTOOL:-}" otool mp-otool "$WK_XCTC/otool"; }
wk_find_lipo()              { wk_resolve_tool wk_probe_lipo lipo "${LIPO:-}" lipo mp-lipo "$WK_XCTC/lipo"; }

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

    # GStreamer, the sole media engine.
    [ -f "$pre$GST_DEPLOY/libgstreamer-1.0.0.dylib" ] || {
        echo "  MISSING GStreamer runtime: $pre$GST_DEPLOY/libgstreamer-1.0.0.dylib" >&2; bad=1; }

    # The full stock XPC service set: the two real services plus the seven clones QuickLook
    # resolves before it will render a web preview.
    for n in Networking WebContent $(echo "$WK_XPC_VARIANTS" | sed 's/^[^:]*://'); do
        f="$XPCSERVICES/com.apple.WebKit.$n.xpc/Contents/MacOS/com.apple.WebKit.$n"
        [ -f "$pre$f" ] || { echo "  MISSING XPC service executable: $pre$f" >&2; bad=1; }
    done

    # Sandbox profiles. AuxiliaryProcess::initializeSandbox() and webpushd's applySandbox() look
    # these up BY NAME under WebKit2.framework's Resources and CRASH()/RELEASE_ASSERT rather than
    # continue when the file is not there, so a missing profile is a child process that dies at
    # launch. The set is exact in both directions: an EXTRA .sb means a profile the build no longer
    # generates is riding along in the build tree (what a renamed custom-command output leaves
    # behind), and shipping a stale security policy is exactly as wrong as shipping none.
    local profiles_dir="$WEBKIT2_BUNDLE/Versions/A/Resources"
    local expected_profiles="com.apple.WebProcess.sb
com.apple.WebKit.NetworkProcess.sb
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
    echo "  verified: $label is complete (4 framework binaries fat with i386, 9 XPC services, private runtime + GStreamer, single unwinder)"
}
