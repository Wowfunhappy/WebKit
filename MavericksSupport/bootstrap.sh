#!/bin/bash
# One-shot setup for a fresh clone: build everything a WebKit build needs that is NOT
# committed -- the toolchain helper tools, the third-party libraries linked into WebKit,
# and the from-source polyfill archives. Requires the macOS SDK as a sibling of the
# checkout (see README.md). Idempotent: each step skips work already present.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "### [1/3] toolchain (clang + cmake/ninja/python3/nasm)"
"$HERE/toolchain/bootstrap.sh"

echo "### [2/3] third-party libraries linked into WebKit (ICU, gcrypt, brotli, woff2) + GStreamer runtime"
[ -f "$HERE/deps/build/lib/libgcrypt.a" ] || "$HERE/deps/build_deps.sh"

echo "### [3/3] from-source polyfill archives"
"$HERE/polyfill/scripts/build-polyfill.sh"

echo "### bootstrap complete -- configure WebKit per MavericksSupport/toolchain/bootstrap.sh output"
