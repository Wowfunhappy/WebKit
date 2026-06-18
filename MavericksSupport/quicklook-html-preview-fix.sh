#!/bin/bash
# QuickLook HTML preview fix for the macOS 10.9 Safari-7 WebKit backport.
#
# Background
# ----------
# Two layers had to be fixed for QuickLook HTML files to show rendered content
# instead of the user's "Can't load display bundles" error / a blank icon:
#
#   1. SANDBOX (see install-safari7.sh + webkit-mavericks-sandbox-runtime memory):
#      our private C++ runtime was relocated out of sandbox-denied /usr/local to
#      /System/Library/WebKitPrivateRuntime so QuickLook's sandboxed daemons can
#      dlopen our WebKit. This makes ALL display bundles load (text/image/pdf/...)
#      and HTML thumbnails render. That fix lives in install-safari7.sh.
#
#   2. THE HTML DISPLAY BUNDLE (this script):
#      Apple ships two HTML QuickLook display bundles -- Web.qldisplay
#      (QLWebDisplayBundle, WebKit1) and Web2.qldisplay (QLWeb2DisplayBundle,
#      WebKit2). QuickLook prefers Web2 for HTML. Web2 links the legacy WebKit2
#      Objective-C SPI (WKProcessGroup / WKBrowsingContextGroup / WKView /
#      WKBrowsingContextController). Modern WebKit (615) deleted WKProcessGroup
#      and WKBrowsingContextGroup, so stock Web2 failed to dlopen at all.
#
#      We restored those classes in WebKit2 (WKProcessGroup.mm,
#      WKBrowsingContextGroup.mm, WKView legacy initializer + browsingContext-
#      Controller load/delegate bridge) so Apple's Web2 now LOADS. However its
#      WKView-based render path is heavily tailored to Safari's host process and
#      crashes inside the QuickLook host (quicklook.satellite / qlmanage),
#      falling back to a thumbnail. Apple's *WebKit1* Web.qldisplay
#      (QLWebDisplayBundle) renders the same previews and does NOT crash in the
#      QuickLook host. So we point the "Web2" display-bundle id at Apple's own
#      WebKit1 display bundle. Both are Apple components; this just selects the
#      one compatible with the available API on 10.9.
#
# This script is idempotent. Run it once after installing WebKit.

set -e
QLU="/System/Library/Frameworks/Quartz.framework/Versions/A/Frameworks/QuickLookUI.framework/Versions/A/PlugIns"
WEB="$QLU/Web.qldisplay"
WEB2="$QLU/Web2.qldisplay"
BACKUP="$QLU/Web2.qldisplay.apple-webkit2"

if [ ! -d "$WEB" ]; then
    echo "error: $WEB not found" >&2
    exit 1
fi

# Preserve Apple's original WebKit2 Web2 once (so this is reversible).
if [ ! -e "$BACKUP" ] && [ -d "$WEB2" ]; then
    cp -R "$WEB2" "$BACKUP"
    echo "backed up Apple's original Web2.qldisplay -> $(basename "$BACKUP")"
fi

# Replace Web2 with a copy of the WebKit1 Web bundle, relabeled to the Web2 id
# so QuickLook resolves com.apple.qldisplay.Web2 to the WebKit1 display bundle.
rm -rf "$WEB2"
cp -R "$WEB" "$WEB2"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.apple.qldisplay.Web2" "$WEB2/Contents/Info.plist"

echo "Web2.qldisplay now: id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$WEB2/Contents/Info.plist") principal=$(/usr/libexec/PlistBuddy -c 'Print :NSPrincipalClass' "$WEB2/Contents/Info.plist")"

# QuickLook daemons cache loaded display bundles; restart them.
pkill -9 quicklookd 2>/dev/null || true
pkill -9 quicklook.satellite 2>/dev/null || true
qlmanage -r >/dev/null 2>&1 || true
qlmanage -r cache >/dev/null 2>&1 || true
echo "done. QuickLook HTML previews now use Apple's WebKit1 display bundle."
