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
OTOOL="$(wk_find_otool)"
LIPO="$(wk_find_lipo)"

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
# #38: all in-layer Dashboard widgets share ONE DashboardClient, and the Dock picks its architecture
# before any WebKit code runs: a widget whose AllowInternetPlugins flag is set is recorded as 32bit in
# com.apple.dashboard.plist, and any 32bit widget makes the Dock spawn an i386 DashboardClient, which
# loads the grafted stock i386 slice instead of our x86_64 engine. The flag only ever enabled NPAPI
# plug-ins, which no widget embeds and the modern engine lacks. So: clear it in every installed
# widget (governs future adds) and normalize the recorded 32bit values in each user's dashboard plist
# (governs the existing layout).
normalize_dashboard() {
    echo "### Forcing 64-bit DashboardClient (clear widget AllowInternetPlugins + recorded 32bit flags)"
    for wdgt in /Library/Widgets/*.wdgt /Users/*/Library/Widgets/*.wdgt; do
        [ -d "$wdgt" ] || continue
        wplist="$wdgt/Contents/Info.plist"
        [ -f "$wplist" ] || wplist="$wdgt/Info.plist"
        [ -f "$wplist" ] || continue
        cur=$(/usr/libexec/PlistBuddy -c 'Print :AllowInternetPlugins' "$wplist" 2>/dev/null) || cur=""
        if [ "$cur" = "true" ]; then
            if /usr/libexec/PlistBuddy -c 'Set :AllowInternetPlugins false' "$wplist"; then
                echo "  $(basename "$wdgt") AllowInternetPlugins -> false"
            else
                echo "  warning: could not clear AllowInternetPlugins on $wdgt"
            fi
        fi
    done
    for home in /Users/*; do
        [ -f "$home/Library/Preferences/com.apple.dashboard.plist" ] || continue
        huser=$(stat -f %Su "$home") || continue
        # The temp file must be owned by (and writable as) the owning user: `defaults export`
        # run via sudo -u onto a root-owned 0600 file in /tmp exits 0 but writes NOTHING, and
        # the import leg cannot read it either — the normalization would silently no-op.
        tmpdash=$(sudo -u "$huser" mktemp "$home/Library/Preferences/dashboard-plist.XXXXXX" 2>/dev/null) || tmpdash=""
        if [ -z "$tmpdash" ]; then
            echo "  warning: could not create a temp prefs file for $huser; 32bit flags not normalized"
            continue
        fi
        # Round-trip through `defaults` (as the owning user) so cfprefsd's cache stays coherent.
        # Do not trust the export's exit status: verify the file actually contains a plist.
        if sudo -u "$huser" defaults export com.apple.dashboard "$tmpdash" 2>/dev/null \
            && [ -s "$tmpdash" ] \
            && /usr/libexec/PlistBuddy -c 'Print' "$tmpdash" >/dev/null 2>&1; then
            i=0
            changed=0
            while /usr/libexec/PlistBuddy -c "Print :layer-gadgets:$i" "$tmpdash" >/dev/null 2>&1; do
                g32=$(/usr/libexec/PlistBuddy -c "Print :layer-gadgets:$i:32bit" "$tmpdash" 2>/dev/null) || g32=""
                if [ "$g32" = "true" ]; then
                    if /usr/libexec/PlistBuddy -c "Set :layer-gadgets:$i:32bit 0" "$tmpdash" 2>/dev/null; then
                        changed=1
                    else
                        echo "  warning: could not clear 32bit on gadget $i for $huser"
                    fi
                fi
                i=$((i + 1))
            done
            if [ "$changed" = "1" ]; then
                if sudo -u "$huser" defaults import com.apple.dashboard "$tmpdash"; then
                    echo "  $huser: cleared recorded 32bit flag(s) in com.apple.dashboard"
                    DASHBOARD_PREFS_CHANGED=1
                else
                    echo "  warning: could not import normalized com.apple.dashboard for $huser"
                fi
            fi
        else
            echo "  warning: could not export $huser's com.apple.dashboard; 32bit flags not normalized"
        fi
        rm -f "$tmpdash"
    done
    # A live Dock holds the old layout (and possibly an i386 DashboardClient); restart it so the
    # next Dashboard activation spawns from the normalized plist. The Dock relaunches itself.
    if [ "${DASHBOARD_PREFS_CHANGED:-0}" = "1" ]; then
        killall DashboardClient 2>/dev/null || true
        killall Dock 2>/dev/null || true
        echo "  restarted Dock to pick up the 64-bit Dashboard layout"
    fi
}
normalize_dashboard

# ---------------------------------------------------------------------------
echo "### Verifying the installed product"
wk_verify_tree "" "the installed system"
echo "### Done."
