#!/bin/bash
# A/B leak driver: load PAGE n times (alternating about:blank), then trigger LEAKDUMP
# and report how many of PAGE's documents survive a full GC.
set -u
PAGE="$1"            # e.g. video.html or novideo.html
N="${2:-4}"
BASE="http://localhost:8731"
nav(){ osascript -e "tell application \"Safari\" to set URL of front document to \"$1\"" >/dev/null 2>&1; }

pkill -x Safari 2>/dev/null; pkill -f com.apple.WebKit 2>/dev/null; sleep 2
: > /tmp/safari-stderr.log
/Applications/Safari.app/Contents/MacOS/Safari >>/tmp/safari-stderr.log 2>&1 &
sleep 6
osascript -e 'tell application "Safari"
  if (count of documents) = 0 then make new document
end tell' >/dev/null 2>&1
sleep 1

for i in $(seq 1 "$N"); do
  nav "$BASE/$PAGE"; sleep 8
  nav "about:blank";  sleep 4
  echo "  loaded $PAGE round $i"
done

# trigger the GC + dump from a fresh doc whose URL contains leakdump
nav "$BASE/dump.html?leakdump=1"; sleep 5

PID=$(ps -o pid=,command= -ax | grep 'WebKit.WebContent' | grep -v grep | awk '{print $1}' | head -1)
LOG="/tmp/wc-stderr-$PID.log"
echo "=== WebContent pid=$PID rss=$(ps -o rss= -p "$PID"|tr -d ' ')KB log=$LOG ==="
echo "--- [LEAKDUMP] ---"
awk '/LEAKDUMP\] after full GC/{p=1} p{print} /^$/{if(p)p=p}' "$LOG" | grep -aA40 "LEAKDUMP" | tail -30
echo "--- count of '$PAGE' documents still live after GC ---"
grep -ac "$PAGE" "$LOG"
echo "--- live HTMLDocument / div counts (heap) ---"
sudo heap "$PID" 2>/dev/null | grep -E '\b(WebCore::HTMLDocument|WebCore::HTMLDivElement|WebCore::LocalDOMWindow|WebCore::LocalFrame|WebCore::HTMLMediaElement|WebCore::MediaPlayer|WebCore::CachedResource)\b' | grep -vE 'Wrapper|Watchpoint'
