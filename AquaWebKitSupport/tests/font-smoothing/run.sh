#!/bin/bash
# Measures, in Safari with the installed WebKit, whether text gets subpixel (LCD) or grayscale smoothing:
# page.html's cells name the expected kind and fringe.c judges a screen capture of them. The run opens one
# Safari window, brings it to the front, and closes it; Safari's other windows are left alone.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/font-smoothing.XXXXXX") || exit 2
W=""
cleanup() {
    [ -n "$W" ] && osascript -e "tell application \"Safari\" to close window id $W" >/dev/null 2>&1
    rm -rf "$WORK"
}
trap cleanup EXIT

if ! /usr/bin/clang -O2 -o "$WORK/fringe" "$HERE/fringe.c" -framework ApplicationServices >> /tmp/wk_build.log 2>&1; then
    echo "FAIL fringe.c did not compile; see /tmp/wk_build.log"
    exit 2
fi
cp "$HERE/page.html" "$WORK/page.html" && cp /Library/Fonts/Georgia.ttf "$WORK/Georgia.ttf" || exit 2
URL="file://$WORK/page.html"

safari() { osascript -e "tell application \"Safari\" to $1"; }

safari "make new document with properties {URL:\"$URL\"}" >/dev/null || exit 2

# The probe's window: its title, and its tab showing this run's copy of the page.
for _ in $(seq 60); do
    W=$(osascript -e 'on run argv
        tell application "Safari"
            repeat with w in windows
                if name of w starts with "font smoothing probe" and URL of current tab of w is item 1 of argv then return id of w
            end repeat
        end tell
        return ""
    end run' "$URL" 2>/dev/null)
    [ -n "$W" ] && break
    sleep 0.25
done
if [ -z "$W" ]; then
    echo "FAIL the probe's window did not appear"
    exit 1
fi

safari "set bounds of window id $W to {0, 22, 1024, 700}" >/dev/null
safari activate >/dev/null
safari "set index of window id $W to 1" >/dev/null

title=""
for _ in $(seq 60); do
    title=$(safari "get name of current tab of window id $W" 2>/dev/null)
    case "$title" in *ready*|*"did not load"*) break;; esac
    sleep 0.25
done
case "$title" in
    *ready*) ;;
    *) echo "FAIL page did not finish: \"$title\""; exit 1;;
esac
regions=$(safari "do JavaScript \"cellRegions()\" in current tab of window id $W")
if echo "$regions" | grep -q '^outside-viewport'; then
    echo "FAIL cells outside the visible page area:" $(echo "$regions" | sed -n 's/^outside-viewport //p')
    exit 1
fi

# A window over the probe would hand its own pixels to the measurement.
front=$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true')
index=$(safari "get index of window id $W")
if [ "$front" != "Safari" ] || [ "$index" != "1" ]; then
    echo "FAIL the probe's window is not in front (frontmost application \"$front\", window index $index)"
    exit 1
fi
screencapture -x "$WORK/capture.png"

echo "$regions" | "$WORK/fringe" "$WORK/capture.png"
status=$?
[ $status -eq 0 ] && echo "PASS: every cell has its expected smoothing" || echo "FAIL: see the cells above"
exit $status
