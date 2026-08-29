# MAVERICKS_BACKPORT: wire GStreamer 1.28.5 / glib 2.80.5 from MavericksSupport/deps/build
# (built from source for x86_64 macOS 10.9 by MavericksSupport/deps/build_deps.sh and proved
# 10.9-clean by that script's symbol-resolution gate; no compat or reexport shim dylibs) into
# the build,
# replacing the pkg-config-based FindGStreamer/FindGLIB that the GTK/WPE ports use (no pkg-config
# on this toolchain). Defines the GLib::* imported targets and all GSTREAMER_*_{INCLUDE_DIRS,
# LIBRARIES} variables that Source/WebCore/platform/GStreamer.cmake consumes, so the upstream
# MediaPlayerPrivateGStreamer compiles unchanged. Software/appsink path only (GL + TextureMapper
# + CoordinatedGraphics OFF); decoded frames reach CG via ImageGStreamerCG.cpp.
#
# GStreamer handles <video>/<audio> playback only; the AVFoundation playback engines are not used.
# getUserMedia capture and WebRTC are the Cocoa stack (AVFoundation/CoreAudio capture sources +
# libwebrtc, USE_LIBWEBRTC in OptionsMacMavericks.cmake), so webrtcbin and GStreamer capture are not built.
SET_AND_EXPOSE_TO_BUILD(USE_GSTREAMER_MEDIA_STREAM FALSE)
SET_AND_EXPOSE_TO_BUILD(USE_GSTREAMER_WEBRTC FALSE)

set(GST_ROOT "${MAVERICKS_DEPS}")
set(GST_LIB "${GST_ROOT}/lib")

set(_GST_INCLUDE_DIRS
    "${GST_ROOT}/include/gstreamer-1.0"
    "${GST_ROOT}/include/glib-2.0"
    "${GST_LIB}/glib-2.0/include"
    "${GST_ROOT}/include/gio-unix-2.0"
    "${GST_ROOT}/include/orc-0.4"
    "${GST_ROOT}/include"
)

# MAVERICKS_BACKPORT: WebCore's SharedBuffer.h (a core, widely-included public header) pulls in
# GStreamerCommon.h (#90 GstBuffer conversion), so EVERY framework that consumes WebCore headers
# (WebKit, WebKitLegacy, test harnesses) transitively includes <gst/gst.h>. On the GTK/WPE ports the
# GStreamer include dirs are global; add them globally here too so all frameworks compile, not just WebCore.
include_directories(SYSTEM ${_GST_INCLUDE_DIRS})

# --- GLib imported targets (FindGLIB.cmake equivalents) ---
set(GLIB_INCLUDE_DIRS "${GST_ROOT}/include/glib-2.0" "${GST_LIB}/glib-2.0/include")
set(GLIB_VERSION "2.80.5")
set(GLIB_FOUND TRUE)
macro(_GST_DEFINE_GLIB_TARGET _name _lib)
    if (NOT TARGET GLib::${_name})
        add_library(GLib::${_name} UNKNOWN IMPORTED GLOBAL)
        set_target_properties(GLib::${_name} PROPERTIES
            IMPORTED_LOCATION "${GST_LIB}/${_lib}"
            INTERFACE_INCLUDE_DIRECTORIES "${GLIB_INCLUDE_DIRS}")
    endif ()
endmacro()
_GST_DEFINE_GLIB_TARGET(GLib    libglib-2.0.dylib)
_GST_DEFINE_GLIB_TARGET(Object  libgobject-2.0.dylib)
_GST_DEFINE_GLIB_TARGET(Module  libgmodule-2.0.dylib)
_GST_DEFINE_GLIB_TARGET(Thread  libglib-2.0.dylib)
_GST_DEFINE_GLIB_TARGET(Gio     libgio-2.0.dylib)
# On macOS the vendored libgio-2.0 contains the gio-unix entry points too.
_GST_DEFINE_GLIB_TARGET(GioUnix libgio-2.0.dylib)
set_target_properties(GLib::Gio PROPERTIES INTERFACE_LINK_LIBRARIES "GLib::Object;GLib::GLib")
set_target_properties(GLib::GioUnix PROPERTIES
    INTERFACE_INCLUDE_DIRECTORIES "${GST_ROOT}/include/gio-unix-2.0;${GLIB_INCLUDE_DIRS}")
set(GLIB_LIBRARIES GLib::GLib)
set(GLIB_GIO_LIBRARIES GLib::Gio)
set(GLIB_GMODULE_LIBRARIES GLib::Module)
set(GLIB_GOBJECT_LIBRARIES GLib::Object)
set(GLIB_GTHREAD_LIBRARIES GLib::Thread)

# --- GStreamer component variables (FindGStreamer.cmake equivalents) ---
set(GSTREAMER_VERSION "1.28.5")
set(GSTREAMER_FOUND TRUE)
macro(_GST_DEFINE_COMPONENT _prefix _lib)
    set(${_prefix}_INCLUDE_DIRS ${_GST_INCLUDE_DIRS})
    set(${_prefix}_LIBRARIES "${GST_LIB}/${_lib}")
    set(${_prefix}_FOUND TRUE)
endmacro()
_GST_DEFINE_COMPONENT(GSTREAMER          libgstreamer-1.0.dylib)
_GST_DEFINE_COMPONENT(GSTREAMER_BASE     libgstbase-1.0.dylib)
_GST_DEFINE_COMPONENT(GSTREAMER_APP      libgstapp-1.0.dylib)
_GST_DEFINE_COMPONENT(GSTREAMER_AUDIO    libgstaudio-1.0.dylib)
_GST_DEFINE_COMPONENT(GSTREAMER_VIDEO    libgstvideo-1.0.dylib)
_GST_DEFINE_COMPONENT(GSTREAMER_PBUTILS  libgstpbutils-1.0.dylib)
_GST_DEFINE_COMPONENT(GSTREAMER_TAG      libgsttag-1.0.dylib)
_GST_DEFINE_COMPONENT(GSTREAMER_FFT      libgstfft-1.0.dylib)
_GST_DEFINE_COMPONENT(GSTREAMER_ALLOCATORS libgstallocators-1.0.dylib)
_GST_DEFINE_COMPONENT(GSTREAMER_RTP    libgstrtp-1.0.dylib)
_GST_DEFINE_COMPONENT(GSTREAMER_SDP    libgstsdp-1.0.dylib)
# Components the Mac/software build does not use are left empty (GL, mpegts, codecparsers, etc.).
set(GSTREAMER_GL_INCLUDE_DIRS "")
set(GSTREAMER_GL_LIBRARIES "")
set(GSTREAMER_MPEGTS_INCLUDE_DIRS "")
set(GSTREAMER_MPEGTS_LIBRARIES "")
set(GSTREAMER_CODECPARSERS_INCLUDE_DIRS "")
set(GSTREAMER_CODECPARSERS_LIBRARIES "")

list(APPEND GSTREAMER_INCLUDE_DIRS ${_GST_INCLUDE_DIRS})
