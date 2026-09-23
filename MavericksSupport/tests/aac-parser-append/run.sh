#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
. "$ROOT/MavericksSupport/polyfill/polyfill-env.sh"
AAC_DEPS="$ROOT/MavericksSupport/deps/build"
OUT="$ROOT/WebKitBuild/Release/aac-parser-append"
mkdir -p "$OUT"
EXTRA=()
if [ "$#" -eq 1 ]; then
    EXTRA=(-DPROBE_AAC_PARSER "$1" -I"$ROOT/MavericksSupport/deps/work/trees/build-gstgood/gst/audioparsers")
fi
"$CLANG" $MODERN "$ROOT/MavericksSupport/tests/aac-parser-append/main.c" ${EXTRA[@]+"${EXTRA[@]}"} \
    -I"$AAC_DEPS/include/gstreamer-1.0" -I"$AAC_DEPS/include/glib-2.0" -I"$AAC_DEPS/lib/glib-2.0/include" \
    -L"$AAC_DEPS/lib" -Wl,-rpath,"$AAC_DEPS/lib" -lgstapp-1.0 -lgstbase-1.0 -lgstreamer-1.0 \
    -lgstpbutils-1.0 -lgobject-2.0 -lglib-2.0 -o "$OUT/aac-parser-append" >> /tmp/wk_build.log 2>&1
export GST_REGISTRY_FORK=no GST_PLUGIN_PATH="$AAC_DEPS/lib/gstreamer-1.0"
FIXTURE="$ROOT/LayoutTests/media/media-source/content/test-adts.aac"
for chunk in 0 1 17 235 4096; do
    "$OUT/aac-parser-append" "$FIXTURE" "$chunk" complete
done
for mode in partial truncated resync; do
    "$OUT/aac-parser-append" "$FIXTURE" 17 "$mode"
done
"$ROOT/MavericksSupport/toolchain/build/python3/bin/python3" - "$FIXTURE" "$OUT" <<'PY'
from pathlib import Path
import sys
data = Path(sys.argv[1]).read_bytes()
offset = 0
while offset < len(data):
    last = offset
    offset += ((data[offset + 3] & 3) << 11) | (data[offset + 4] << 3) | (data[offset + 5] >> 5)
for length in (7, 9):
    header = bytearray(data[last:last + 7])
    header[1] = header[1] | 1 if length == 7 else header[1] & ~1
    header[3] &= ~3
    header[4] = length >> 3
    header[5] = ((length & 7) << 5) | (header[5] & 31)
    Path(sys.argv[2], f'minimum-{length}.aac').write_bytes(data[:last] + header + bytes(length - 7))
PY
for length in 7 9; do
    "$OUT/aac-parser-append" "$OUT/minimum-$length.aac" 17 complete
done
