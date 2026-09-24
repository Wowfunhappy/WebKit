#!/bin/bash
# Loads https://rewrite-source.invalid:18990/ pages with rewrite.c's WKExternalURLRewrite, which serves every
# load from 127.0.0.1:18991. The WebKit1 pass inserts it into wk1-client, which also downloads through
# WebDownload. The Safari passes put it in the installed Networking service: one inserts it at launch, one
# loads it into the running service after its first load.
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
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        cat "$WORK/server.log" >&2
        echo "FAIL the fixture could not start on 127.0.0.1:18991" >&2
        SERVER_PID=
        exit 1
    fi
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

# $1: the page's title, $2: the address the client shows for it, $3: the cookie value the page set.
check_page() {
    local path
    echo "title: $1"
    case "$1" in PASS*) ;; *) fail "the page did not report PASS" ;; esac
    [ "$2" = "$SOURCE/page.html" ] || fail "the client shows the address $2"
    case "$1" in *"location=$SOURCE/page.html "*) ;; *) fail "the document is not at the requested URL" ;; esac
    case "$1" in *'"redirectCount":0'*) ;; *) fail "the navigation reports a redirect" ;; esac
    case "$1" in *"\"name\":\"$SOURCE/page.html\""*) ;; *) fail "the navigation timing entry is not the requested URL" ;; esac
    case "$1" in *"responseURL=$SOURCE/data.json "*) ;; *) fail "XMLHttpRequest.responseURL is not the requested URL" ;; esac
    case "$1" in *"redirected=false url=$SOURCE/data.json?x=1 "*) ;; *) fail "the fetch response URL is not the requested URL" ;; esac
    for path in /page.html /style.css /script.js /img.svg /data.json "/data.json?x=1"; do
        grep -qF "GET $path HTTP/1.1 Host=127.0.0.1:18991 " "$WORK/server.log" || fail "no request for $path reached the server as 127.0.0.1:18991"
    done
    if grep -v 'Host=127.0.0.1:18991 ' "$WORK/server.log" | grep -q '^GET'; then fail "a request carried another Host"; fi
    # The page's own loads are first-party to the server it was served from.
    for path in /data.json "/data.json?x=1"; do
        grep -F "GET $path HTTP/1.1 " "$WORK/server.log" | grep -qF "Cookie=rewritten=$3" || fail "the page's request for $path did not carry the page's cookie"
    done
    # The rewrite's header changes reach the wire.
    for path in /page.html /style.css /script.js /img.svg /data.json "/data.json?x=1"; do
        grep -F "GET $path HTTP/1.1 " "$WORK/server.log" | grep -qF "X-Rewrite-Test=added" || fail "the request for $path did not carry the added header"
    done
    grep -F "GET /data.json HTTP/1.1 " "$WORK/server.log" | grep -qF "X-Page-Header=None" || fail "the XMLHttpRequest still carried the header the rewrite removed"
    grep -F "GET /page.html HTTP/1.1 " "$WORK/server.log" | grep -q "User-Agents=1 User-Agent=.* ExternalURLRewrite/1$" || fail "the page request did not carry one changed User-Agent"
    # A redirect stays on the requested site: a relative Location and one naming that site both reach the
    # fixture with the site's cookie, and the page sees the requested site's URL.
    for kind in relative absolute; do
        case "$1" in *"redirect-$kind=200 ok=true url=$SOURCE/data.json?redirected=$kind "*) ;; *) fail "the $kind redirect did not end at the requested site's URL" ;; esac
        grep -F "GET /data.json?redirected=$kind HTTP/1.1 Host=127.0.0.1:18991 " "$WORK/server.log" | grep -qF "Cookie=rewritten=$3" || fail "the $kind redirect's hop did not reach the fixture with the page's cookie"
    done
}

# A load whose URL the rewrite keeps still takes its header changes.
check_direct() {
    grep -F "GET /check.html?direct=1 HTTP/1.1 " "$WORK/server.log" | grep -qF "X-Rewrite-Test=added" || fail "the load the rewrite kept did not carry the added header"
}

# The cookie the server set is the requested site's: the page's own script sees it, and it returns with
# the next top-level navigation.
check_cookie() {
    case "$TITLE_FOR_COOKIE" in *"cookie="*"rewritten=$1"*) ;; *) fail "the page's document.cookie does not hold the cookie its server set" ;; esac
    grep -F "GET /check.html " "$WORK/server.log" | grep -qF "Cookie=rewritten=$1" || fail "the navigation to check.html did not carry the page's cookie"
}

check_safari_page() {
    TITLE_FOR_COOKIE="$TITLE"
    check_page "$TITLE" "$(osascript -e 'tell application "Safari" to get URL of front document' 2>/dev/null || true)" "$1"
    load "$SOURCE/check.html" checked || fail "check.html did not load"
    check_cookie "$1"
}

cleanup() {
    [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
    quit_safari
    sudo cp "$WORK/Info.plist" "$PLIST"
    rm -f "$SERVICE_TEMP_DIR/librewrite.dylib"
}

for library in rewrite late-loader; do
    clang -Wall -Werror -dynamiclib -arch x86_64 -mmacosx-version-min=10.9 -framework CoreFoundation \
        -o "$WORK/lib$library.dylib" "$HERE/$library.c" >>/tmp/wk_build.log 2>&1
done
clang -isysroot "${SDK:-/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX10.9.sdk}" \
    -Wall -Werror -fobjc-arc -arch x86_64 -mmacosx-version-min=10.9 -framework Cocoa -framework WebKit \
    -Wno-deprecated-declarations -o "$WORK/wk1-client" "$HERE/wk1-client.m" >>/tmp/wk_build.log 2>&1
cp "$PLIST" "$WORK/Info.plist"
quit_safari
trap cleanup EXIT

echo "== WebKit1"
start_server "wk1$$"
mkdir -p "$WORK/downloads"
DYLD_INSERT_LIBRARIES="$WORK/librewrite.dylib" "$WORK/wk1-client" "$SOURCE" "$WORK/downloads" "http://127.0.0.1:18991/check.html?direct=1" >"$WORK/wk1.log" 2>&1 || fail "wk1-client exited with $?"
cat "$WORK/wk1.log"
TITLE_FOR_COOKIE="$(sed -n 's/^TITLE //p' "$WORK/wk1.log")"
check_page "$TITLE_FOR_COOKIE" "$(sed -n 's/^ADDRESS //p' "$WORK/wk1.log")" "wk1$$"
grep -qx "CHECK checked" "$WORK/wk1.log" || fail "check.html did not load"
check_cookie "wk1$$"
check_direct
grep -qF 'DOWNLOAD {"ok": true}' "$WORK/wk1.log" || fail "the WebDownload did not save data.json"
grep -qF "GET /data.json?download=1 HTTP/1.1 Host=127.0.0.1:18991 " "$WORK/server.log" || fail "the WebDownload did not reach the server as 127.0.0.1:18991"
cat "$WORK/server.log"
stop_server

echo "== inserted at launch"
insert_library "$WORK/librewrite.dylib"
start_server "launch$$"
launch_safari
networking_maps librewrite.dylib || fail "the Networking service did not load librewrite.dylib"
load "$SOURCE/page.html" PASS || true
check_safari_page "launch$$"
load "http://127.0.0.1:18991/check.html?direct=1" checked || fail "the direct load did not complete"
check_direct
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
check_safari_page "late$$"
cat "$WORK/server.log"
stop_server

[ "$failures" = 0 ] && echo PASS
exit "$failures"
