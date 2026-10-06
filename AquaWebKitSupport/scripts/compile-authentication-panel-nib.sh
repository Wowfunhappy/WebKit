#!/bin/bash
# compile-authentication-panel-nib.sh — compile WebKitLegacy's WebAuthenticationPanel.xib into the
# framework's Resources, for the CMake build.
#
# Usage: compile-authentication-panel-nib.sh <ibtool> <xib> <output.nib>
#
# Xcode 6.2's ibtool is the newest that runs on 10.9 and reads Interface Builder documents up to the
# Xcode 7 format; the xib is saved in the Xcode 8 format. The rewrite below restates the document's
# format markers in the older spelling — the panel's own content is already in a shape this ibtool
# reads, so nothing else changes.
set -eu
set -o pipefail

IBTOOL="$1"
XIB="$2"
NIB="$3"

[ -x "$IBTOOL" ] || { echo "ERROR: ibtool not executable at $IBTOOL" >&2; exit 1; }
[ -f "$XIB" ] || { echo "ERROR: no xib at $XIB" >&2; exit 1; }

TOOLS_VERSION=7706
WORK="$(dirname "$NIB")/$(basename "$XIB" .xib).ibtool.xib"
mkdir -p "$(dirname "$NIB")"

/usr/bin/perl -pe "
    s/ toolsVersion=\"[0-9.]+\"/ toolsVersion=\"$TOOLS_VERSION\"/;
    s/ propertyAccessControl=\"[a-zA-Z]+\"//;
    s/(<plugIn identifier=\"com\.apple\.InterfaceBuilder\.CocoaPlugin\" version=\")[0-9.]+(\")/\${1}$TOOLS_VERSION\${2}/;
    s{^\s*<capability name=\"documents saved in the Xcode 8 format\".*\n}{};
" "$XIB" > "$WORK"

"$IBTOOL" --errors --warnings --notices --minimum-deployment-target 10.9 \
    --compile "$NIB" "$WORK"
rm -f "$WORK"
[ -s "$NIB" ] || { echo "ERROR: $IBTOOL produced no nib at $NIB" >&2; exit 1; }
