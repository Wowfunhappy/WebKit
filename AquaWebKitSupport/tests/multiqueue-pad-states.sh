#!/bin/bash
# Check requested-pad state and decodebin shutdown against the published runtime.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEPS="$ROOT/AquaWebKitSupport/deps/build"
WORK=$(mktemp -d /tmp/webkit-multiqueue-pad-states.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
export LC_ALL=C
export GST_PLUGIN_SYSTEM_PATH="$DEPS/lib/gstreamer-1.0"
export GST_PLUGIN_PATH=""
export GST_REGISTRY="$WORK/registry.bin"
export GST_REGISTRY_FORK=no
export DYLD_FALLBACK_LIBRARY_PATH="$DEPS/lib"
"$ROOT/AquaWebKitSupport/toolchain/build/clang/bin/clang" -mmacosx-version-min=10.9 -Wall \
    "$ROOT/AquaWebKitSupport/tests/multiqueue-pad-states.c" -o "$WORK/check" \
    -I"$DEPS/include/gstreamer-1.0" -I"$DEPS/include/glib-2.0" -I"$DEPS/lib/glib-2.0/include" \
    -L"$DEPS/lib" -Wl,-rpath,"$DEPS/lib" -lgstreamer-1.0 -lgobject-2.0 -lglib-2.0
perl -e 'alarm 30; exec @ARGV' "$WORK/check" "$@"
