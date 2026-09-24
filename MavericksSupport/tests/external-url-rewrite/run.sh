#!/bin/bash
# Loads https://rewrite-source.invalid:18990/ pages in Safari with rewrite.c's WKExternalURLRewrite in the
# installed Networking service, which serves every load from 127.0.0.1:18991. The first pass inserts the
# rewrite at launch; the second loads it into a running service after its first load.
# Needs the installed build and sudo; it quits and relaunches Safari, and restores the service's Info.plist.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
PLIST=/System/Library/PrivateFrameworks/WebKit2.framework/Versions/A/XPCServices/com.apple.WebKit.Networking.xpc/Contents/Info.plist
SERVICE_TEMP_DIR="$(getconf DARWIN_USER_TEMP_DIR)com.apple.WebKit.Networking+com.apple.Safari"
SOURCE=https://rewrite-source.invalid:18990
WORK="$(mktemp -d /tmp/external-url-rewrite.XXXXXX)"
SERVER_PID=
failures=0

fail() { echo "FAIL $*"; failures=$((failures + 1)); }

quit_safari() {
    local pid
    pid="$(pgrep -x Safari || true)"
    [ -n "$pid" ] || return 0
    osascript -e 'tell application "Safari" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 20); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.5; done
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 20); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.5; done
    echo "FAIL Safari ($pid) did not quit" >&2
    exit 1
}

networking_pids() { pgrep -f '^com\.apple\.WebKit\.Networking' || true; }

networking_maps() {
    local pid
    for pid in $(networking_pids); do vmmap "$pid" 2>/dev/null; done | grep -q "$1"
}

insert_library() {
    sudo cp "$WORK/Info.plist" "$PLIST"
    sudo /usr/libexec/PlistBuddy -c "Add :XPCService:EnvironmentVariables dict" \
        -c "Add :XPCService:EnvironmentVariables:DYLD_INSERT_LIBRARIES string $1" "$PLIST"
}

# Navigates the front document and waits until its title starts with $2.
load() {
    osascript -e "tell application \"Safari\" to set URL of front document to \"$1\"" >/dev/null
    TITLE=
    for _ in $(seq 60); do
        TITLE="$(osascript -e 'tell application "Safari" to get name of front document' 2>/dev/null || true)"
        case "$TITLE" in "$2"*) return 0 ;; esac
        sleep 0.5
    done
    return 1
}

start_server() {
    REWRITE_COOKIE="$1" python3 "$HERE/server.py" 2>"$WORK/server.log" &
    SERVER_PID=$!
    sleep 1
}

stop_server() {
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=
}

launch_safari() {
    open -a Safari
    for _ in $(seq 60); do
        osascript -e 'tell application "Safari" to if (count of documents) is 0 then make new document' >/dev/null 2>&1 || true
        [ -n "$(networking_pids)" ] && osascript -e 'tell application "Safari" to get name of front document' >/dev/null 2>&1 && return 0
        sleep 0.5
    done
    fail "Safari did not start"
}

check_page() {
    local cookie="$1" address path
    echo "title: $TITLE"
    case "$TITLE" in PASS*) ;; *) fail "the page did not report PASS" ;; esac
    address="$(osascript -e 'tell application "Safari" to get URL of front document' 2>/dev/null || true)"
    [ "$address" = "$SOURCE/page.html" ] || fail "the address bar shows $address"
    case "$TITLE" in *"location=$SOURCE/page.html "*) ;; *) fail "the document is not at the requested URL" ;; esac
    case "$TITLE" in *'"redirectCount":0'*) ;; *) fail "the navigation reports a redirect" ;; esac
    for path in /page.html /style.css /script.js /img.svg /data.json "/data.json?x=1"; do
        grep -qF "GET $path HTTP/1.1 Host=127.0.0.1:18991 " "$WORK/server.log" || fail "no request for $path reached the server as 127.0.0.1:18991"
    done
    if grep -v 'Host=127.0.0.1:18991 ' "$WORK/server.log" | grep -q '^GET'; then fail "a request carried another Host"; fi
    # The cookie the rewritten top-level page set returns with the next top-level navigation.
    load "$SOURCE/check.html" checked || fail "check.html did not load"
    grep -F "GET /check.html " "$WORK/server.log" | grep -qF "Cookie=rewritten=$cookie" || fail "the navigation to check.html did not carry the page's cookie"
}

cleanup() {
    [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
    quit_safari
    sudo cp "$WORK/Info.plist" "$PLIST"
    rm -f "$SERVICE_TEMP_DIR/librewrite.dylib"
}

for library in rewrite late-loader; do
    clang -Wall -Werror -dynamiclib -arch x86_64 -mmacosx-version-min=10.9 -framework CoreFoundation \
        -o "$WORK/lib$library.dylib" "$HERE/$library.c"
done
cp "$PLIST" "$WORK/Info.plist"
quit_safari
trap cleanup EXIT

echo "== inserted at launch"
insert_library "$WORK/librewrite.dylib"
start_server "launch$$"
launch_safari
networking_maps librewrite.dylib || fail "the Networking service did not load librewrite.dylib"
load "$SOURCE/page.html" PASS || true
check_page "launch$$"
cat "$WORK/server.log"
stop_server
quit_safari

echo "== loaded after the first load"
rm -f "$SERVICE_TEMP_DIR/librewrite.dylib"
insert_library "$WORK/liblate-loader.dylib"
start_server "late$$"
launch_safari
networking_maps liblate-loader.dylib || fail "the Networking service did not load liblate-loader.dylib"
load "http://127.0.0.1:18991/check.html" checked || fail "the direct first load did not complete"
if networking_maps librewrite.dylib; then fail "librewrite.dylib was loaded before the trigger"; fi
mkdir -p "$SERVICE_TEMP_DIR"
cp "$WORK/librewrite.dylib" "$SERVICE_TEMP_DIR/"
kill -INFO $(networking_pids)
for _ in $(seq 20); do networking_maps librewrite.dylib && break; sleep 0.5; done
networking_maps librewrite.dylib || fail "the Networking service did not load librewrite.dylib late"
load "$SOURCE/page.html" PASS || true
check_page "late$$"
cat "$WORK/server.log"
stop_server

[ "$failures" = 0 ] && echo PASS
exit "$failures"
