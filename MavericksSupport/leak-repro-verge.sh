#!/bin/bash
# Reproduce the Document-retention leak on a real complex site (theverge),
# alternating with a trivial page, watching the SAME WebContent pid's RSS.
# Then capture heap/leaks forensics on the grown process.
set -u
COMPLEX="${1:-https://www.theverge.com/}"
ROUNDS="${2:-5}"
TRIVIAL="about:blank"

wc_pid() { ps -o pid=,command= -ax | grep 'WebKit.WebContent' | grep -v grep | awk '{print $1}' | head -1; }
wc_rss() { ps -o rss= -p "$1" 2>/dev/null | tr -d ' '; }
nav() { osascript -e "tell application \"Safari\" to set URL of front document to \"$1\"" >/dev/null 2>&1; }

echo "=== killing any running Safari/WebContent ==="
pkill -x Safari 2>/dev/null; pkill -f com.apple.WebKit 2>/dev/null; sleep 2

echo "=== launching Safari ==="
: > /tmp/safari-stderr.log
/Applications/Safari.app/Contents/MacOS/Safari >>/tmp/safari-stderr.log 2>&1 &
sleep 6
# ensure a document exists
osascript -e 'tell application "Safari"
  if (count of documents) = 0 then make new document
end tell' >/dev/null 2>&1
sleep 1

echo "=== priming with $COMPLEX ==="
nav "$COMPLEX"; sleep 18
PID=$(wc_pid)
echo "WebContent pid=$PID  rss=$(wc_rss "$PID") KB (after first complex load)"

for r in $(seq 1 "$ROUNDS"); do
  nav "$TRIVIAL"; sleep 5
  P2=$(wc_pid)
  nav "$COMPLEX"; sleep 16
  P3=$(wc_pid)
  echo "round $r: trivial->complex  pid(now)=$P3  rss=$(wc_rss "$P3") KB  (pid stable=$([ "$P3" = "$PID" ] && echo yes || echo NO:$PID->$P3))"
done

# settle on trivial so the current document is tiny; leaked ones should remain
nav "$TRIVIAL"; sleep 6
PID=$(wc_pid)
echo
echo "=== FINAL on trivial page: WebContent pid=$PID rss=$(wc_rss "$PID") KB ==="
echo "(if rss is still hundreds of MB while showing about:blank => leaked documents retained)"
echo
echo "### heap top object classes (sudo heap) ###"
sudo heap "$PID" 2>/dev/null | grep -E 'WebCore::|JSC::|WebKit::|^Total|COUNT' | head -45
echo
echo "### leaks summary (sudo leaks) ###"
sudo leaks "$PID" 2>/dev/null | grep -E 'leaks for|total leaked|Process .* nodes|reachable|leaked bytes' | head -20
echo "(Safari still running; pid $PID is WebContent)"
