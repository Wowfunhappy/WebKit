#!/bin/bash
#
# Builds libcxxgst_compat.dylib and repoints the macOS-26-built C++17 GStreamer libs onto it.
#
# Some vendored GStreamer libs (libwebrtc-audio-processing-2.1 + libgstwebrtcdsp -- the WebRTC audio
# DSP: echo cancellation / noise suppression / AGC) are modern C++17 and link the SYSTEM
# /usr/lib/libc++.1.dylib. On 10.9 that system libc++ is too old to have the C++17 symbols they need
# (std::bad_optional_access, ...), so they fail to dlopen ("Symbol not found") and WebRTC/getUserMedia
# audio gets no echo cancellation. The bundle libc++ (in JavaScriptCore.framework) HAS those symbols
# but, unlike the system libc++, does NOT reexport libc++abi (so std::exception::what etc. would still
# be missing). This builds a shim that reexports the bundle libc++ + libc++abi + libunwind -- the
# complete modern C++ runtime -- then repoints every deployed GStreamer dylib that links the system
# libc++ onto it (a superset, so libs that did not need C++17 keep working, and the whole GStreamer
# tree shares one C++ runtime).
#
# Usage: build-cxxgst-compat.sh <gst_lib_dir> [<clang>]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
LIBDIR="${1:?usage: build-cxxgst-compat.sh <gst_lib_dir> [clang]}"
CLANG="${2:-$REPO/MavericksSupport/toolchain/build/clang/bin/clang}"
[ -x "$CLANG" ] || CLANG=/usr/bin/clang
PRIVLIBCXX=/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Frameworks
SHIM="$LIBDIR/libcxxgst_compat.dylib"

if [ ! -f "$PRIVLIBCXX/libc++.1.dylib" ] || [ ! -f "$PRIVLIBCXX/libc++abi.1.dylib" ]; then
    echo "  bundle C++ runtime not found in $PRIVLIBCXX -- skipping cxxgst compat"
    exit 0
fi

"$CLANG" --no-default-config -isysroot / -mmacosx-version-min=10.9 -dynamiclib -nostdlib \
    "$HERE/cxxgst_compat_stub.c" \
    -Wl,-reexport_library,"$PRIVLIBCXX/libc++.1.dylib" \
    -Wl,-reexport_library,"$PRIVLIBCXX/libc++abi.1.dylib" \
    -Wl,-reexport_library,"$PRIVLIBCXX/libunwind.1.dylib" \
    -install_name @rpath/libcxxgst_compat.dylib \
    -compatibility_version 1.0.0 -current_version 9999.0.0 \
    -o "$SHIM"

# Repoint every deployed GStreamer dylib that links the (too-old-on-10.9) system libc++ onto the shim.
# install_name_tool -change is a no-op for files that do not have that load command.
find "$LIBDIR" -name '*.dylib' ! -name 'libcxxgst_compat.dylib' | while read -r f; do
    if otool -L "$f" 2>/dev/null | grep -q '/usr/lib/libc++\.1\.dylib'; then
        install_name_tool -change /usr/lib/libc++.1.dylib @rpath/libcxxgst_compat.dylib "$f" 2>/dev/null || true
    fi
done

echo "built libcxxgst_compat.dylib + repointed C++17 GStreamer libs onto the modern C++ runtime"
