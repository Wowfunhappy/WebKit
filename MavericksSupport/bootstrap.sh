#!/bin/bash
# One-shot setup for a fresh clone: everything a WebKit build needs that is not committed. Requires the
# macOS SDK as a sibling of the checkout (see README.md). Idempotent: each step skips work already present.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WK_IBTOOL=/Applications/Xcode.app/Contents/Developer/usr/bin/ibtool
if [ ! -x "$WK_IBTOOL" ]; then
    WK_IBTOOL="$(command -v ibtool || true)"
fi
if [ -z "$WK_IBTOOL" ] || ! "$WK_IBTOOL" --version >/dev/null 2>&1; then
    echo "ERROR: Xcode 6.2's ibtool is required to compile WebAuthenticationPanel.nib." >&2
    echo "Install Xcode 6.2 at /Applications/Xcode.app, or provide a working ibtool on PATH." >&2
    exit 1
fi

echo "### [1/4] toolchain (clang + cmake/ninja/python3/nasm/ccache)"
"$HERE/toolchain/bootstrap.sh"

echo "### [2/4] SDK patches (symbol re-homes + iOS-only class availability)"
"$HERE/sdk/patch-sdk.sh"

echo "### [3/4] third-party libraries linked into WebKit + the GStreamer runtime"
[ -f "$HERE/deps/build/lib/libgcrypt.a" ] || "$HERE/deps/build_deps.sh"

echo "### [4/4] polyfill archives"
"$HERE/polyfill/build-polyfill.sh"

echo "### bootstrap complete -- build with: bash MavericksSupport/build.sh (it configures WebKitBuild/Release on first run)"
