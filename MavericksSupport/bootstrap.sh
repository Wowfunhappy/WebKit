#!/bin/bash
# One-shot setup for a fresh clone: everything a WebKit build needs that is not committed. Requires the
# macOS SDK as a sibling of the checkout (see README.md). Idempotent: each step skips work already present.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "### [1/4] toolchain (clang + cmake/ninja/python3/nasm/ccache)"
"$HERE/toolchain/bootstrap.sh"

echo "### [2/4] SDK patches (symbol re-homes + iOS-only class availability)"
"$HERE/sdk/patch-sdk.sh"

echo "### [3/4] third-party libraries linked into WebKit + the GStreamer runtime"
[ -f "$HERE/deps/build/lib/libgcrypt.a" ] || "$HERE/deps/build_deps.sh"

echo "### [4/4] polyfill archives"
"$HERE/polyfill/build-polyfill.sh"

echo "### bootstrap complete -- build with: bash MavericksSupport/build.sh (it configures WebKitBuild/Release on first run)"
