#!/bin/bash
# Build and run the Objective-C garbage-collection regression test (github #118).
#
#   bash MavericksSupport/tests/objc-gc/run-gctest.sh [runs]     # default 10
#
# Tests the INSTALLED frameworks, so install first (MavericksSupport/install-safari7.sh).
# The binary is built into a gitignored build/ next to this script -- it is regenerable, so
# it is never committed (see the project's no-committed-binaries rule).
#
# Why the flag step: the runtime decides a process collects from the MAIN executable's
# __objc_imageinfo, and modern clang cannot produce that (-fobjc-gc is gone), so the bit is
# set post-link. Without it the test would run refcounted and prove nothing.
#
# Needs a network connection (the test loads apple.com and example.com) and the 10.9 SDK
# from Xcode 6 / the Command Line Tools.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPPORT="$(cd "$HERE/../.." && pwd)"
RUNS="${1:-10}"
OUT="$HERE/build"
mkdir -p "$OUT"

SDK="${MAVERICKS_TEST_SDK:-}"
if [ -z "$SDK" ]; then
    for candidate in \
        /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX10.9.sdk \
        /Library/Developer/CommandLineTools/SDKs/MacOSX10.9.sdk; do
        [ -d "$candidate" ] && { SDK="$candidate"; break; }
    done
fi
[ -n "$SDK" ] || { echo "No 10.9 SDK found; set MAVERICKS_TEST_SDK." >&2; exit 1; }

# The SYSTEM clang, deliberately: this stands in for a third-party 10.9 app built with the
# tools of its era, linking the WebKit headers the OS ships.
echo "### building gctest (SDK: $SDK)"
/usr/bin/clang -isysroot "$SDK" -mmacosx-version-min=10.9 -Wall \
    -framework Cocoa -framework WebKit \
    -o "$OUT/gctest" "$HERE/gctest.m"

echo "### marking it as requiring garbage collection"
python "$SUPPORT/scripts/set-objc-gc-supported.py" --require "$OUT/gctest"

echo "### running $RUNS time(s) against the installed frameworks"
PASS=0
for i in $(seq 1 "$RUNS"); do
    if "$OUT/gctest" > "$OUT/run-$i.log" 2>&1; then
        PASS=$((PASS + 1))
    else
        echo "  run $i FAILED (exit $?); see $OUT/run-$i.log"
        grep -E "FAILED|Segmentation" "$OUT/run-$i.log" | head -2 || true
    fi
done

echo "### gctest: $PASS/$RUNS passed"
[ "$PASS" -eq "$RUNS" ]
