#!/bin/bash
# Faithful repro of the documented sustained-session leak:
# navigate MANY distinct complex sites in ONE WebContent process, no trivial page
# between, no kill. Watch the same pid's RSS + live HTMLDocument count climb.
set -u
nav(){ osascript -e "tell application \"Safari\" to set URL of front document to \"$1\"" >/dev/null 2>&1; }
wc_pid(){ ps -o pid=,command= -ax | grep 'WebKit.WebContent' | grep -v grep | awk '{print $1}' | head -1; }

SITES=(
  https://www.theverge.com/
  https://www.nytimes.com/
  https://www.cnn.com/
  https://www.reddit.com/
  https://www.bbc.com/
  https://www.espn.com/
  https://github.com/WebKit/WebKit
  https://stackoverflow.com/
  https://www.apple.com/
  https://en.wikipedia.org/wiki/Main_Page
  https://www.amazon.com/
  https://arstechnica.com/
)

pkill -x Safari 2>/dev/null; pkill -f com.apple.WebKit 2>/dev/null; sleep 2
: > /tmp/safari-stderr.log
/Applications/Safari.app/Contents/MacOS/Safari >>/tmp/safari-stderr.log 2>&1 &
sleep 6
osascript -e 'tell application "Safari"
  if (count of documents) = 0 then make new document
end tell' >/dev/null 2>&1
sleep 1

PID=""
i=0
for url in "${SITES[@]}"; do
  i=$((i+1))
  nav "$url"; sleep 14
  P=$(wc_pid)
  [ -z "$PID" ] && PID=$P
  RSS=$(ps -o rss= -p "$P" 2>/dev/null | tr -d ' ')
  HD=$(sudo heap "$P" 2>/dev/null | grep -E '\bWebCore::HTMLDocument\b' | awk '{print $1}')
  echo "nav $i  rss=${RSS}KB  HTMLDocuments=${HD}  pid=$P$([ "$P" = "$PID" ] && echo "" || echo " (CHANGED from $PID)")"
done

echo
echo "=== final heap (pid=$PID) top live contexts ==="
sudo heap "$PID" 2>/dev/null | grep -E '\b(WebCore::HTMLDocument|WebCore::LocalDOMWindow|WebCore::LocalFrame|WebCore::Document|WebCore::HTMLDivElement|WebCore::ScriptExecutionContext)\b' | grep -vE 'Wrapper|Watchpoint' | head
