#!/bin/bash
# install.sh — copy the staged product (WebKitBuild/Release/staged, laid out exactly as it lands on disk
# by scripts/stage-frameworks.sh) onto the 10.9 system where stock Safari 7.0.6 loads it, then the few
# things that live in host files nobody builds. See scripts/framework-layout.sh for the layout.
#
# The factory (stock) frameworks are preserved ONCE in $STOCK_BACKUP (captured at build time by
# stage-frameworks.sh); a re-run only replaces our own previous build and backs nothing up.
# Run with: sudo bash install.sh   (writes to /System only — fully self-contained, no /usr/local)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/scripts/framework-layout.sh"

BACKUP_ROOT="${BACKUP_ROOT:-$STOCK_BACKUP/replaced-original}"

backup() {
    local path="$1"
    [ -e "$path" ] || return 0
    [ -d "$STOCK_BACKUP/WebKit.framework" ] && return 0   # stock already preserved; never snapshot our own builds
    local dest="$BACKUP_ROOT$path"
    if [ -e "$dest" ]; then echo "  (backup already exists for $path)"; return 0; fi
    mkdir -p "$(dirname "$dest")"
    echo "  backing up $path -> $dest"
    cp -Rp "$path" "$dest"
}

# ---------------------------------------------------------------------------
# PREFLIGHT: every check that can fail runs BEFORE the first write (the copy loop rm -rf's each
# destination bundle, so a defect noticed at the third bundle would leave /System half-new).
echo "### Preflight"
if [ "$(id -u)" != 0 ]; then
    echo "ERROR: this writes to /System — run it as root: sudo bash $0" >&2
    exit 1
fi
if [ ! -d "$WK_STAGE_ROOT" ]; then
    echo "ERROR: no staged product at $WK_STAGE_ROOT." >&2
    echo "       Build it first: bash MavericksSupport/build.sh" >&2
    exit 1
fi
if [ ! -f "$WK_STAGE_ROOT/.build-complete" ]; then
    echo "ERROR: $WK_STAGE_ROOT has no .build-complete stamp, so it is left over from a build that" >&2
    echo "       did not finish. Installing it would put stale code on the system." >&2
    echo "       Rebuild it: bash MavericksSupport/build.sh" >&2
    exit 1
fi
wk_verify_tree "$WK_STAGE_ROOT" "the staged tree ($WK_STAGE_ROOT)" || {
    echo "       Rebuild it: bash MavericksSupport/build.sh" >&2
    exit 1; }

# ---------------------------------------------------------------------------
# Copy the staged bundles into place. WebCore rides inside WebKit.framework (nested, as on stock
# 10.9), so three copies place all four frameworks. The staged tree already carries the modes the
# sandbox needs (world-readable dylibs under traversable dirs), and `cp -p` carries them across
# verbatim — without it cp applies root's umask instead, which can drop the world-read bit a
# sandboxed WebContent needs. `cp -p` also copies the staged tree's ownership, so chown follows to
# put the installed files under root:wheel like every other framework in /System.
echo "### Installing frameworks from $WK_STAGE_ROOT"
for bundle in $WK_INSTALL_ROOTS; do
    echo "== $bundle =="
    backup "$bundle"
    rm -rf "$bundle"
    mkdir -p "$(dirname "$bundle")"
    cp -RPp "$WK_STAGE_ROOT$bundle" "$bundle"
    chown -R root:wheel "$bundle"
    echo "  installed."
done

# ---------------------------------------------------------------------------
# XPC service inventory. 10.9 resolves an xpc_connection_create() name for a service under /System
# through /System/Library/Caches/com.apple.xpchelper.cache, which the OS builds once at install time
# and never revisits. A service this port ships that stock 10.9 never had -- com.apple.WebKit.GPU --
# is absent from that cache, so launchd answers the connection with an error, ProcessLauncher reports
# a pid of 0, and GPUProcessProxy treats every launch as a crash. xpchelper regenerates the cache
# from what is on disk.
echo "### Rebuilding the system XPC service cache"
/usr/libexec/xpchelper --rebuild-cache
# Match on the recorded executable path rather than the service name: the cache interns the names
# adjacent to other fields, so a name is not a line of its own, and one service name is a prefix of
# another's ("...Networking" of "...Networking.Development").
for svc in $WK_XPC_SERVICES; do
    if [ "$(strings /System/Library/Caches/com.apple.xpchelper.cache | grep -Fc "$XPCSERVICES/$svc.xpc/Contents/MacOS/$svc")" = 0 ]; then
        echo "ERROR: $svc is missing from the rebuilt XPC service cache." >&2
        exit 1
    fi
done
echo "  cache holds all $(set -- $WK_XPC_SERVICES; echo $#) WebKit services"

# ---------------------------------------------------------------------------
# Web Push daemon: the webpushd binary rides inside the WK2 framework (staged with it above), and
# WebKit submits its launchd job when a browser session that uses push starts up
# (UIProcess/WebsiteData/Cocoa/WebsiteDataStoreCocoa.mm). Clear the job this login session holds, so
# the daemon serving the previous framework is gone and the next Safari launch registers afresh —
# the webpushd analog of the stale WebContent trap.
echo "### Clearing the webpushd launchd job"
WEBPUSHD_LABEL=com.apple.webkit.webpushd.relocatable
# Only this install's invoking user has a reachable launchd session; any other logged-in user's
# session keeps its job until logout and registers afresh on the next Safari launch after that.
if [ -n "${SUDO_USER:-}" ]; then
    if sudo -u "$SUDO_USER" launchctl remove "$WEBPUSHD_LABEL" 2>/dev/null; then
        echo "  cleared $WEBPUSHD_LABEL from $SUDO_USER's session"
    else
        echo "  $SUDO_USER's session holds no $WEBPUSHD_LABEL job"
    fi
else
    echo "  no SUDO_USER, so any job in a live session stays until that session ends"
fi

# ---------------------------------------------------------------------------
# #38: the Dock picks the DashboardClient architecture before any WebKit code runs, from each
# widget's AllowInternetPlugins flag, and a widget carrying it runs i386 -- which loads the grafted
# stock i386 slice rather than our x86_64 engine. On the Web Clip widget the flag only ever enabled
# NPAPI plug-ins, which the clip does not embed and the modern engine lacks, so clearing it is what
# puts Web Clips on this port's engine. This is the one widget the port owns; every other widget on
# the system, Apple's and third-party alike, keeps whatever its author declared.
force_64bit_web_clip_widget() {
    echo "### Clearing AllowInternetPlugins on the Web Clip widget (64-bit DashboardClient)"
    local wdgt="/Library/Widgets/Web Clip.wdgt"
    local wplist="$wdgt/Info.plist"
    [ -f "$wplist" ] || wplist="$wdgt/Contents/Info.plist"
    if [ ! -f "$wplist" ]; then
        echo "  no Web Clip widget installed"
        return 0
    fi
    local cur
    cur=$(/usr/libexec/PlistBuddy -c 'Print :AllowInternetPlugins' "$wplist" 2>/dev/null) || cur=""
    if [ "$cur" != "true" ]; then
        echo "  already 64-bit"
        return 0
    fi
    if /usr/libexec/PlistBuddy -c 'Set :AllowInternetPlugins false' "$wplist"; then
        echo "  AllowInternetPlugins -> false"
    else
        echo "  warning: could not clear AllowInternetPlugins on $wplist"
    fi
}
force_64bit_web_clip_widget

# ---------------------------------------------------------------------------
echo "### Verifying the installed product"
wk_verify_tree "" "the installed system"
echo "### Done."
