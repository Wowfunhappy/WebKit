#!/bin/bash
# Tests the installed WebKit frameworks. Build and install the port before running.
# The plain executable runs with 10.9-SDK behaviors. Override.app's Info.plist turns one behavior on
# and names one that does not exist; IntegerValue.app gives that behavior an integer, which is ignored.
set -eu
set -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SDK="${SDK:-/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX10.9.sdk}"
mkdir -p "$HERE/build"
/usr/bin/clang -isysroot "$SDK" -o "$HERE/build/host" "$HERE/host.m" \
    -framework Cocoa -framework WebKit -Wno-deprecated-declarations -O0 -g >> /tmp/wk_build.log 2>&1

# make_app <name> <AquaWebKitSDKAlignedBehaviors entries>
make_app() {
    local app="$HERE/build/$1.app"
    mkdir -p "$app/Contents/MacOS"
    cp "$HERE/build/host" "$app/Contents/MacOS/host"
    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>host</string>
    <key>CFBundleIdentifier</key><string>org.aquawebkit.tests.attachment-plugin-$1</string>
    <key>AquaWebKitSDKAlignedBehaviors</key>
    <dict>
$2
    </dict>
</dict>
</plist>
PLIST
}

# expect_stderr <file> <message>
expect_stderr() {
    if grep -qF "$2" "$1"; then
        echo "PASS reported: $2"
    else
        echo "FAIL reported: $2"
        exit 1
    fi
}

make_app Override '        <key>KeepEditableSelectionOnMouseFocus</key><true/>
        <key>NoSuchBehavior</key><true/>'
make_app IntegerValue '        <key>KeepEditableSelectionOnMouseFocus</key><integer>1</integer>'

echo "== 10.9 SDK behaviors"
"$HERE/build/host"
echo "== Info.plist turns KeepEditableSelectionOnMouseFocus on"
"$HERE/build/Override.app/Contents/MacOS/host" 2> "$HERE/build/Override.stderr"
expect_stderr "$HERE/build/Override.stderr" "AquaWebKitSDKAlignedBehaviors: unknown behavior NoSuchBehavior; ignored"
echo "== Info.plist gives KeepEditableSelectionOnMouseFocus an integer"
"$HERE/build/IntegerValue.app/Contents/MacOS/host" 2> "$HERE/build/IntegerValue.stderr"
expect_stderr "$HERE/build/IntegerValue.stderr" "AquaWebKitSDKAlignedBehaviors: entry KeepEditableSelectionOnMouseFocus is not a name with a Boolean; ignored"
