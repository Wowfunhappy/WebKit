#!/bin/bash
# framework-layout.sh — the on-disk layout of the installed backport, shared by the
# build-time stager (scripts/stage-frameworks.sh) and the installer (install.sh).
# This file is SOURCED, never executed: it defines paths and helpers, and performs no work of
# its own.
#
# Name shift (built framework -> installed bundle, installed binary name):
#   JavaScriptCore -> /System/Library/Frameworks/JavaScriptCore.framework           (bin: JavaScriptCore)
#   WebKitLegacy   -> /System/Library/Frameworks/WebKit.framework                   (bin: WebKit)
#   WebCore        -> ...WebKit.framework/Versions/A/Frameworks/WebCore.framework   (bin: WebCore — nested, as on stock 10.9)
#   WebKit (WK2)   -> /System/Library/PrivateFrameworks/WebKit2.framework           (bin: WebKit2)

WK_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WK_SUPPORT="$WK_REPO/AquaWebKitSupport"
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
# The Web Clip widget's plug-in. The port supplies its executable (fat: ours for x86_64, the stock
# i386 slice for a 32-bit DashboardClient), its page script, its injected bundle, and the widget's
# script, page and style sheet with AquaWebKitSupport/webclip/WebClip.{js,html,css}.patch applied; the
# rest of the widget is Apple's.
WEBCLIP_PLUGIN="/Library/Widgets/Web Clip.wdgt/WebClip.plugin/Contents"
WEBCLIP_BINARY="$WEBCLIP_PLUGIN/MacOS/WebClip"
WEBCLIP_PAGE_AGENT="$WEBCLIP_PLUGIN/Resources/WCPageAgent.js"
WEBCLIP_EXTENSION_PAGE_SCRIPT="$WEBCLIP_PLUGIN/Resources/WCSafariExtensionPage.js"
WEBCLIP_PAGE_BUNDLE="$WEBCLIP_PLUGIN/Resources/WebClipPageBundle.bundle"
WEBCLIP_WIDGET_SCRIPT="/Library/Widgets/Web Clip.wdgt/WebClip.js"
WEBCLIP_WIDGET_PAGE="/Library/Widgets/Web Clip.wdgt/WebClip.html"
WEBCLIP_WIDGET_STYLE_SHEET="/Library/Widgets/Web Clip.wdgt/WebClip.css"

# #68: the private C++ runtime (libc++/libc++abi from the clang-22 toolchain) and the polyfill
# ObjC-classes dylib live INSIDE the framework bundles, so the product is fully self-contained —
# nothing in /usr/local and no separate top-level runtime dir. Both homes are under
# /System/Library/[Private]Frameworks, which the sandbox grants read to (the #18 reason these can't
# live in /usr/local: sandboxd "deny file-read-data /usr/local/lib/webkit-private/..."); binaries
# reference them by ABSOLUTE in-bundle path (never @rpath) so they can't shadow the system libc++
# via DYLD_FALLBACK. libc++/libc++abi go in the base framework (JavaScriptCore — every WebKit
# framework links the C++ runtime). Every C++ runtime load in the product binds to this one pair,
# the GStreamer tree's included, and no other libc++/libc++abi copy ships.
# The unwinder is NOT vendored: a process must have exactly one _Unwind_* implementation, and
# system frames (Foundation, libobjc, app plug-ins like iBooks' BKEpubWebProcessPlugIn) always
# drive /usr/lib/system/libunwind.dylib. An exception crossing system and backport frames with a
# second, newer libunwind loaded hands the system unwinder's opaque _Unwind_Context to the modern
# accessors (different UnwindCursor layout) and crashes mid-unwind, so every @rpath/libunwind
# reference is bound to the system unwinder instead (its exports cover all symbols we import:
# _Unwind_Resume plus libc++abi's eight classic _Unwind_* entry points).
SYSTEM_UNWINDER=/usr/lib/system/libunwind.dylib
# The private libraries live in the Frameworks directory of the lowest framework that loads them, so
# no framework reaches into a bundle stacked on it. The vendored third-party runtime
# (deps/build_deps.sh) is split the same way by wk_runtime_library_homes below.
#   JSC_LIBS      the C++ runtime, the polyfill classes, and what JavaScriptCore loads (ICU, GLib, libpsl,
#                 libcrypto) with their dependencies
#   WEBCORE_LIBS  libwebrtc, and what WebCore, WebKit and WebKit2 load beyond JSC_LIBS: curl with its
#                 TLS and HTTP/2 libraries, libxml2/libxslt, the FFmpeg decoders, dav1d, libopus
#   GST_LIBS      GStreamer (#90): its own libraries, its plugins (gstreamer-1.0/), and the libraries
#                 only those load
#   GST_SHARE     GStreamer's data beside GST_LIBS: the element presets (gstreamer-1.0/presets/)
JSC_LIBS=$JSC_BUNDLE/Versions/A/Frameworks
WEBCORE_LIBS=$WEBCORE_BUNDLE/Versions/A/Frameworks
GST_LIBS=$WEBCORE_LIBS/gstreamer/lib
GST_SHARE=$WEBCORE_LIBS/gstreamer/share
XPCSERVICES=$WEBKIT2_BUNDLE/Versions/A/XPCServices

# Canonical stock backup (flat *.framework dirs), captured once by
# scripts/stage-frameworks.sh and read by the i386 graft.
STOCK_BACKUP="${STOCK_BACKUP:-$(dirname "$WK_REPO")/stock-webkit-backup}"

# XPC identities requested by Safari, layout tests, and QuickLook in addition to the three CMake-built
# base services. Each entry is "<base service>:<variant name>"; stage-frameworks.sh materializes the
# same set in the build framework and the staged product.
WK_XPC_VARIANTS="Networking:Networking.Development
WebContent:WebContent.Development
WebContent:WebContent.EnhancedSecurity
WebContent:WebContent.CaptivePortal
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
# cctools, by absolute path.
. "$WK_SUPPORT/scripts/cctools.sh"
INSTALL_NAME_TOOL="$CCTOOLS/install_name_tool"
OTOOL="$CCTOOLS/otool"
LIPO="$CCTOOLS/lipo"

# ---------------------------------------------------------------------------
# The home of each library of the vendored runtime. deps/build_deps.sh installs it as one flat prefix
# whose libraries name each other @rpath/<install-name leaf>; each one ships in the Frameworks
# directory of the lowest framework that loads it (see JSC_LIBS above):
#   jsc        everything JavaScriptCore's binaries load, transitively
#   webcore    everything else the WebCore, WebKit and WebKit2 bundles and libwebrtc load, transitively,
#              short of GStreamer's own libgst* libraries; and libopus, which the polyfill layer's
#              AudioToolbox Opus encoder opens beside WebCore (AudioToolboxOpus.c)
#   gstreamer  the libgst* libraries those load and everything the plugins load, transitively
# A library nothing loads does not ship. $1 = the build's lib dir (the linked frameworks and
# libwebrtc.dylib), $2 = the prefix's lib dir. Prints "<home> <leaf> <file>" per library, where
# <file> is the prefix's copy. Requires $OTOOL.
wk_runtime_library_homes() {
    local libdir="$1" src="$2" work f leaf home queue fw
    work="$(mktemp -d "${TMPDIR:-/tmp}/wk-runtime-homes.XXXXXX")" || return 1

    # The @rpath dependency leaves of one Mach-O.
    _wk_rpath_leaves() {
        "$OTOOL" -L "$1" | awk 'NR > 1 && $1 ~ /^@rpath\// { sub(/^@rpath\//, "", $1); print $1 }'
    }
    # The Mach-Os of one built framework, short of its Versions/A/Frameworks dir (the build tree's
    # copy of this runtime).
    _wk_framework_machos() {
        local bundle="$libdir/$1.framework" f
        while IFS= read -r f; do
            case "$f" in "$bundle/Versions/A/Frameworks/"*) continue;; esac
            case "$(file -b "$f")" in *Mach-O*) echo "$f";; esac
        done < <(find "$bundle" -type f -perm +111)
    }
    # Claim each unclaimed library in the queue, and what it loads, for one home. The webcore walk
    # stops at a libgst* library and hands it to the gstreamer walk.
    _wk_claim() {
        local home="$1" leaf; shift
        set -- $*
        while [ $# -gt 0 ]; do
            leaf="$1"; shift
            [ -f "$work/file.$leaf" ] && [ ! -f "$work/home.$leaf" ] || continue
            case "$home:$leaf" in webcore:libgst*) echo "$leaf" >> "$work/gst-roots"; continue;; esac
            echo "$home" > "$work/home.$leaf"
            set -- "$@" $(cat "$work/deps.$leaf")
        done
    }

    # The prefix's libraries, by install-name leaf. Its dev-name symlinks are aliases of these, and
    # its C++ runtime pair is the toolchain's, which ships once in JSC_LIBS from the toolchain itself.
    for f in "$src"/*.dylib; do
        [ -f "$f" ] && [ ! -L "$f" ] || continue
        leaf="$("$OTOOL" -D "$f" | awk 'NR == 2')"; leaf="${leaf##*/}"
        case "$leaf" in libc++.1.dylib|libc++abi.1.dylib) continue;; esac
        echo "$f" > "$work/file.$leaf"
        _wk_rpath_leaves "$f" > "$work/deps.$leaf"
    done

    queue=""
    for f in $(_wk_framework_machos JavaScriptCore); do queue="$queue $(_wk_rpath_leaves "$f")"; done
    _wk_claim jsc $queue

    queue="libopus.0.dylib $(_wk_rpath_leaves "$libdir/libwebrtc.dylib")"
    for fw in WebKitLegacy WebCore WebKit; do
        for f in $(_wk_framework_machos $fw); do queue="$queue $(_wk_rpath_leaves "$f")"; done
    done
    _wk_claim webcore $queue

    queue="$(cat "$work/gst-roots" 2>/dev/null)"
    for f in "$src"/gstreamer-1.0/*.dylib; do queue="$queue $(_wk_rpath_leaves "$f")"; done
    _wk_claim gstreamer $queue

    for f in "$work"/home.*; do
        [ -f "$f" ] || continue
        leaf="${f#$work/home.}"
        echo "$(cat "$f") $leaf $(cat "$work/file.$leaf")"
    done
    rm -rf "$work"
    unset -f _wk_rpath_leaves _wk_framework_machos _wk_claim
}

# The installed directory of a home wk_runtime_library_homes prints.
wk_runtime_home_dir() {
    case "$1" in
        jsc)       echo "$JSC_LIBS";;
        webcore)   echo "$WEBCORE_LIBS";;
        gstreamer) echo "$GST_LIBS";;
    esac
}
