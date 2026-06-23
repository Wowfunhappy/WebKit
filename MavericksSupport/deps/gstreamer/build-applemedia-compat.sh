#!/bin/bash
#
# Builds the compat shims that let the vendored libgstapplemedia.dylib (avfvideosrc / avfdeviceprovider
# -- the macOS camera-capture plugin) load on 10.9. The plugin is built on the modern host with the
# Vulkan/Metal video path enabled, so it hard-links Metal.framework (absent on 10.9) via
# libgstvulkan-1.0.0 -> libMoltenVK, and references 15 CoreVideo/AVFoundation colorimetry/audio
# constants added after 10.9. Without this, the plugin fails to dlopen ("Library not loaded:
# Metal.framework"), so GStreamer's device monitor finds no Video/Source and enumerateDevices() /
# getUserMedia report no camera.
#
# Into <gst_lib_dir> this builds:
#   libgstvulkan-1.0.0.dylib, libMoltenVK.dylib  -- no-op stubs for the 16 dead Vulkan/MoltenVK symbols
#       the plugin imports (the real Vulkan path can't run without Metal; the camera path never uses it)
#   libmetal_stub.dylib                          -- the one Metal class the plugin references directly
#   libcorevideo_compat.dylib                    -- reexports CoreVideo + 8 wide-gamut/HDR constants
#   libavfoundation_compat.dylib                 -- reexports AVFoundation + 7 AVAudioSettings keys
# then repoints the plugin's Metal/CoreVideo/AVFoundation load commands onto these shims.
#
# Usage: build-applemedia-compat.sh <gst_lib_dir> [<clang>]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
LIBDIR="${1:?usage: build-applemedia-compat.sh <gst_lib_dir> [clang]}"
CLANG="${2:-$REPO/MavericksSupport/toolchain/build/clang/bin/clang}"
[ -x "$CLANG" ] || CLANG=/usr/bin/clang
PLUGIN="$LIBDIR/gstreamer-1.0/libgstapplemedia.dylib"
if [ ! -f "$PLUGIN" ]; then
    echo "  libgstapplemedia.dylib not present in $LIBDIR -- skipping applemedia compat"
    exit 0
fi

CVREAL=/System/Library/Frameworks/CoreVideo.framework/Versions/A/CoreVideo
AVREAL=/System/Library/Frameworks/AVFoundation.framework/Versions/A/AVFoundation
CC=("$CLANG" --no-default-config -isysroot / -mmacosx-version-min=10.9 -dynamiclib -fPIC -O2)

# Stubs for the dead Vulkan/MoltenVK path. The compatibility_version must satisfy the plugin's load
# commands (libgstvulkan requires >= 2607.0.0, libMoltenVK >= 1.0.0).
"${CC[@]}" -install_name @rpath/libgstvulkan-1.0.0.dylib \
    -compatibility_version 2607.0.0 -current_version 2607.0.0 \
    "$HERE/applemedia_vulkan_stub.c"   -o "$LIBDIR/libgstvulkan-1.0.0.dylib"
"${CC[@]}" -install_name @rpath/libMoltenVK.dylib \
    -compatibility_version 1.0.0 -current_version 1.0.0 \
    "$HERE/applemedia_moltenvk_stub.c" -o "$LIBDIR/libMoltenVK.dylib"
"${CC[@]}" -install_name @rpath/libmetal_stub.dylib \
    -compatibility_version 1.0.0 -current_version 368.12.0 \
    -framework Foundation "$HERE/applemedia_metal_stub.m" -o "$LIBDIR/libmetal_stub.dylib"

# Reexport shims: forward the real framework + supply the post-10.9 constants. A high
# compatibility_version (9999) satisfies whatever version the plugin recorded for the real framework.
"${CC[@]}" -install_name @rpath/libcorevideo_compat.dylib \
    -compatibility_version 9999.0.0 -current_version 9999.0.0 \
    -framework CoreFoundation -Wl,-reexport_library,"$CVREAL" \
    "$HERE/applemedia_corevideo_compat.c" -o "$LIBDIR/libcorevideo_compat.dylib"
"${CC[@]}" -install_name @rpath/libavfoundation_compat.dylib \
    -compatibility_version 9999.0.0 -current_version 9999.0.0 \
    -framework Foundation -Wl,-reexport_library,"$AVREAL" \
    "$HERE/applemedia_avfoundation_compat.m" -o "$LIBDIR/libavfoundation_compat.dylib"

# Repoint the plugin onto the shims. Idempotent: after the first run the /System source paths are gone,
# so -change is a harmless no-op.
install_name_tool \
    -change /System/Library/Frameworks/Metal.framework/Versions/A/Metal @rpath/libmetal_stub.dylib \
    -change "$CVREAL" @rpath/libcorevideo_compat.dylib \
    -change "$AVREAL" @rpath/libavfoundation_compat.dylib \
    "$PLUGIN" 2>/dev/null || true

echo "built applemedia compat shims + repointed libgstapplemedia.dylib"
