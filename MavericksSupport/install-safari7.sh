#!/bin/bash
# install-safari7.sh — deploy the built product where stock Safari 7.0.6 (WebKit 9537.78.2) on
# macOS 10.9.5 loads it. The build already shaped the artifacts: MavericksSupport/scripts/
# stage-frameworks.sh produces WebKitBuild/Release/staged/, a tree laid out exactly as it lands
# on disk (10.9 name shift, bundle resources, private C++ runtime / polyfill / GStreamer deploys,
# absolute install names, demangler guard, full XPC service set, stock i386 slices). Installing is
# therefore a copy plus the few things that live in host files nobody builds.
#
# See scripts/framework-layout.sh for the layout and MavericksSupport/safari7-abi/INSTALL-PLAN.md
# for the rationale.
#
# SAFETY: the factory (stock) frameworks are preserved ONCE in $STOCK_BACKUP (the flat *.framework
# dirs in stock-webkit-backup), captured at build time by scripts/backup-stock-frameworks.sh.
# Installs do NOT snapshot each build — a re-run only replaces our own previous build, and backing
# that up every time is pure disk churn (~670MB/run, which once filled the startup disk). backup()
# below captures stock at most once and is skipped entirely whenever the stock backup already exists.
# Run with: sudo bash install-safari7.sh   (writes to /System only — fully self-contained, no /usr/local)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/scripts/framework-layout.sh"
OTOOL="$(wk_find_otool)"
LIPO="$(wk_find_lipo)"

# BACKUP_ROOT is a single fixed dir — NOT a per-run timestamped one — so backup() never
# accumulates a new ~670MB snapshot on every install.
BACKUP_ROOT="${BACKUP_ROOT:-$STOCK_BACKUP/replaced-original}"
OLD_PRIVRT=/System/Library/WebKitPrivateRuntime   # nothing references this; cleared below

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

# ---------------------------------------------------------------------------
# PREFLIGHT: refuse to touch /System unless the staged product is present and complete. The copy
# loop below rm -rf's each destination bundle before writing it, so a defect noticed at the third
# bundle would leave /System half-new and half-stale — a mismatched, possibly-unbootable install.
# Verifying the whole staged tree up front puts every check that can fail BEFORE the first write.
echo "### Preflight"
if [ "$(id -u)" != 0 ]; then
    echo "ERROR: this writes to /System — run it as root: sudo bash $0" >&2
    exit 1
fi
if [ ! -d "$WK_STAGE_ROOT" ]; then
    echo "ERROR: no staged product at $WK_STAGE_ROOT." >&2
    echo "       Build it first: bash MavericksSupport/rebuild.sh" >&2
    exit 1
fi
wk_verify_tree "$WK_STAGE_ROOT" "the staged tree ($WK_STAGE_ROOT)" || {
    echo "       Rebuild it: bash MavericksSupport/rebuild.sh" >&2
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
# The frameworks carry their own runtime, so this standalone dir has no users.
if [ -d "$OLD_PRIVRT" ]; then
    rm -rf "$OLD_PRIVRT"
    echo "  removed $OLD_PRIVRT"
fi

# ---------------------------------------------------------------------------
# #38: Dashboard widgets must launch the 64-bit DashboardClient to load our x86_64-only WebKit.
# All in-layer widgets share ONE DashboardClient process, and the Dock picks its architecture
# BEFORE any WebKit code runs: when a widget is added it reads that widget's AllowInternetPlugins
# flag and records it as "32bit" in the user's com.apple.dashboard.plist; if ANY in-layer widget
# carries 32bit=1 the Dock spawns an i386 DashboardClient, which loads the grafted STOCK 2013
# WebKit slice instead of ours — so every widget (including all Web Clips) loses the modern
# engine. AllowInternetPlugins exists solely to enable NPAPI internet plug-ins, which were
# 32-bit-only; no installed widget embeds plug-in content and NPAPI is gone from the modern
# engine, so the flag is vacuous except for this harmful architecture forcing. (Native
# .widgetplugin bundles are a separate mechanism — all fat x86_64+i386 — and are unaffected.)
# Clear the flag in every installed widget (governs future adds) and normalize the already-
# recorded 32bit values in each user's dashboard plist (governs the existing layout). There is
# NO in-framework lever for this — the Dock decides before any of our code runs.
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

# ---------------------------------------------------------------------------
echo "### Verifying the installed product"
wk_verify_tree "" "the installed system"
echo "### Done. Verify further with: MavericksSupport/safari7-abi/check-abi-gap.sh"
