#!/bin/bash
# Run a TestWebKitAPI binary against the build-dir frameworks on macOS 10.9, without installing
# anything over the system.
#
# Prereqs (one-time): configure with the API tests enabled and build the binary —
#   cmake -S . -B WebKitBuild/Release -DDEVELOPER_MODE=ON -DENABLE_API_TESTS=ON \
#         -DDEVELOPER_MODE_FATAL_WARNINGS=OFF
#   ninja -C WebKitBuild/Release TestWebKitCocoa
#
# Usage:  bash MavericksSupport/scripts/run-api-tests.sh <binary> [gtest args...]
#   e.g.  bash MavericksSupport/scripts/run-api-tests.sh TestWebKitCocoa --gtest_filter='WKHTTPCookieStore.*'
#         bash MavericksSupport/scripts/run-api-tests.sh TestWTF --gtest_list_tests
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BINDIR="$ROOT/WebKitBuild/Release/bin"

if [ $# -lt 1 ]; then
    echo "Usage: bash MavericksSupport/scripts/run-api-tests.sh <binary> [gtest args...]" >&2
    exit 2
fi
BINARY="$1"; shift
if [ ! -x "$BINDIR/$BINARY" ]; then
    echo "$BINARY not built — see the prereqs at the top of $0" >&2
    exit 1
fi

# An aborted run orphans build-tree test processes (killing the runner does not reach grandchildren),
# and an orphan parked on a GL-retrying page spams "CoreAnimation: failed to create OpenGL context"
# until 10.9's WindowServer hits its null-texture compositor race and takes the login session down.
reap_test_orphans() {
    pkill -9 -f "WebKitBuild/Release/bin/$BINARY" 2>/dev/null
    pkill -9 -f "WebKitBuild/Release/.*com\.apple\.WebKit\.(WebContent|Networking)" 2>/dev/null
    return 0
}
reap_test_orphans
trap reap_test_orphans EXIT INT TERM

if ! bash "$ROOT/MavericksSupport/scripts/make-build-binaries-runnable.sh" "$BINDIR/$BINARY"; then
    echo "ERROR: could not make the build products loadable" >&2
    exit 1
fi

# Unify the leaf-name libpolyfill_classes.dylib resolution on this repo's copy: the test binary links
# Quartz, which transitively loads a system-installed backport's JavaScriptCore.framework and the copy
# bundled inside it, and two copies of the dylib register the same ObjC classes twice.
export DYLD_LIBRARY_PATH="$ROOT/MavericksSupport/polyfill/build${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"

"$BINDIR/$BINARY" "$@"
exit $?
