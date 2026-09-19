#!/bin/bash
# Run after build_deps.sh prepares and builds gst-plugins-bad. No network I/O.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TREE="$ROOT/MavericksSupport/deps/work/trees/build-gstbad"
DEPS="$ROOT/MavericksSupport/deps/build"
CLANG="$ROOT/MavericksSupport/toolchain/build/clang/bin/clang"
NINJA="$TREE/b/build.ninja"
TEST_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/hls-resync.XXXXXX")
export LC_ALL=C
export GST_PLUGIN_SYSTEM_PATH=""
export GST_PLUGIN_PATH=""
export GST_REGISTRY="$TEST_BUILD/registry.bin"
LINE=$(rg -n '^build ext/hls/libgsthls.dylib.p/gsthlsdemux.c.o: c_COMPILER' "$NINJA" | cut -d: -f1)
[ -n "$LINE" ] || { echo 'Missing HLS compile recipe' >&2; exit 1; }
ARGS=$(sed -n "$((LINE + 3))p" "$NINJA" | sed 's/^ ARGS = //; s/-fdiagnostics-color=always//')
(
    cd "$TREE/b" || exit 1
    eval '"$CLANG"' "$ARGS -UG_DISABLE_ASSERT -UNDEBUG -I../ext/hls -c \"$ROOT/MavericksSupport/tests/hls-resync.c\" -o \"$TEST_BUILD/check.o\"" || exit 1
    "$CLANG" -mmacosx-version-min=10.9 -o "$TEST_BUILD/check" "$TEST_BUILD/check.o" \
        ext/hls/libgsthls.dylib.p/gsthlsdemux-util.c.o \
        ext/hls/libgsthls.dylib.p/gsthlselement.c.o \
        ext/hls/libgsthls.dylib.p/m3u8.c.o \
        -L"$DEPS/lib" -Wl,-rpath,"$DEPS/lib" \
        -lgstadaptivedemux-1.0 -lgsturidownloader-1.0 -lgstpbutils-1.0 \
        -lgstvideo-1.0 -lgstbase-1.0 -lgstreamer-1.0 -lgobject-2.0 \
        -lglib-2.0 -lgsttag-1.0 -lcrypto -lgio-2.0 -framework CoreFoundation
) >> /tmp/wk_build.log 2>&1 || exit 1
"$TEST_BUILD/check"
