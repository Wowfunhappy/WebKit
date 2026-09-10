#!/bin/bash
# Builds the fixtures, serves the checkout at http://127.0.0.1:8731, and drives Safari through both
# test pages, printing each one's RESULT object.
#
#   index.html   -- what the downloadable-font parser accepts and refuses
#   tables.html  -- which font tables this OS actually draws, so the parser's passthrough set can be
#                   read off a measurement rather than an assumption
#
# make-fixtures.sh owns every font both pages load; none of them is checked in except the CBDT
# source, so this runs from a clean checkout.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
PORT=8731
BASE="http://127.0.0.1:$PORT/MavericksSupport/tests/font-sanitizer"

bash "$HERE/make-fixtures.sh" >/dev/null || { echo "FIXTURES FAILED" >&2; exit 1; }

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$ROOT" >/dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
sleep 2

osascript -e 'tell application "Safari" to activate' >/dev/null

rc=0
for page in index tables; do
    osascript -e "tell application \"Safari\" to set URL of front document to \"$BASE/$page.html\"" >/dev/null
    result=""
    for _ in $(seq 1 40); do
        sleep 1
        R=$(osascript -e 'tell application "Safari" to do JavaScript "JSON.stringify(window.RESULT||null)" in front document' 2>/dev/null)
        case "$R" in ""|null|"missing value") continue ;; esac
        result="$R"; break
    done
    if [ -n "$result" ]; then
        echo "$page: $result"
    else
        echo "$page: TIMED OUT waiting for window.RESULT"
        rc=1
    fi
done
exit $rc
