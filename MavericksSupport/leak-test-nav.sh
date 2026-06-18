#!/bin/bash
# Cross-site navigation leak test.
# Launches Safari from the CLI (so UIProcess stderr — [WPP-LIFE] logs — is captured),
# drives same-tab cross-site navigation via osascript, then reports WebPageProxy
# lifecycle counts and WebContent RSS growth.
set -u
LOG=/tmp/safari-stderr.log
NAVS=${1:-10}

echo "=== killing any running Safari/WebContent ==="
pkill -x Safari 2>/dev/null
pkill -f com.apple.WebKit 2>/dev/null
sleep 2

echo "=== launching Safari (stderr -> $LOG) ==="
: > "$LOG"
/Applications/Safari.app/Contents/MacOS/Safari >>"$LOG" 2>&1 &
SAFARI_PID=$!
sleep 6

echo "=== driving $NAVS cross-site navigations ==="
for i in $(seq 1 "$NAVS"); do
  if [ $((i % 2)) -eq 0 ]; then URL="https://example.com/"; else URL="https://example.org/"; fi
  osascript -e "tell application \"Safari\" to set URL of front document to \"$URL\"" >/dev/null 2>&1 \
    || osascript -e "tell application \"Safari\"
        if (count of documents) = 0 then make new document
        set URL of front document to \"$URL\"
      end tell" >/dev/null 2>&1
  echo "  nav $i -> $URL"
  sleep 4
done

echo "=== settling 3s ==="
sleep 3

echo
echo "=== [WPP-LIFE] lifecycle summary ==="
echo "CTOR  count: $(grep -c '\[WPP-LIFE\] CTOR'  "$LOG")"
echo "DTOR  count: $(grep -c '\[WPP-LIFE\] DTOR'  "$LOG")"
echo "removeWebPage count: $(grep -c '\[WPP-LIFE\] WebProcessProxy::removeWebPage' "$LOG")"
echo
echo "--- last 6 CTOR ---"; grep '\[WPP-LIFE\] CTOR' "$LOG" | tail -6
echo "--- all DTOR ---";    grep '\[WPP-LIFE\] DTOR' "$LOG"
echo "--- last 6 removeWebPage ---"; grep '\[WPP-LIFE\] WebProcessProxy::removeWebPage' "$LOG" | tail -6
echo
echo "=== WebContent processes + RSS (KB) ==="
ps -o pid=,rss=,command= -ax | grep -i 'WebKit.WebContent' | grep -v grep
echo
echo "(Safari pid=$SAFARI_PID still running; kill with: pkill -x Safari)"
