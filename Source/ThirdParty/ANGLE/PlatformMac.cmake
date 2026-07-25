# MAVERICKS_BACKPORT: ANGLE uses its CGL OpenGL backend instead of Metal (Metal is unavailable on
# 10.9). The CGL backend (src/libANGLE/renderer/gl/cgl/*) renders GLES via desktop OpenGL through
# CGL and can present into an IOSurface — the software-CGL→IOSurface→WindowServer path that works
# on this VM. angle_enable_cgl/angle_enable_gl are set in CMakeLists.txt before include(GL.cmake).
find_library(COREGRAPHICS_LIBRARY CoreGraphics)
find_library(FOUNDATION_LIBRARY Foundation)
find_library(IOKIT_LIBRARY IOKit)
find_library(IOSURFACE_LIBRARY IOSurface)
# MAVERICKS_BACKPORT: locate OpenGL (not Metal) for the CGL backend used on 10.9.
find_library(OPENGL_LIBRARY OpenGL)
find_library(QUARTZ_LIBRARY Quartz)
find_package(ZLIB REQUIRED)

list(APPEND ANGLE_SOURCES
    # MAVERICKS_BACKPORT: build the CGL/desktop-GL backend sources instead of the Metal backend (Metal absent on 10.9).
    ${gl_backend_sources}

    ${libangle_gpu_info_util_mac_sources}
    ${libangle_gpu_info_util_sources}
    ${libangle_mac_sources}
)

list(APPEND ANGLE_DEFINITIONS
    ANGLE_ENABLE_OPENGL
    ANGLE_ENABLE_CGL
    # MAVERICKS_BACKPORT: the CGL backend uses DESKTOP OpenGL. Without this, the entire
    # body of DispatchTableGL::initProcsDesktopGL() (DispatchTableGL_autogen.cpp,
    # guarded by #if defined(ANGLE_ENABLE_GL_DESKTOP_BACKEND)) compiles away, so NO
    # desktop GL entry points load and the FunctionsGL pointers stay null — caps
    # generation then calls a null genTextures/genFramebuffers and crashes WebContent.
    ANGLE_ENABLE_GL_DESKTOP_BACKEND
    # MAVERICKS_BACKPORT: this port runs WebGL in Workers in-process (there is no GPU process here,
    # see WebWorkerClient::createGraphicsContextGL), so GL entry points ARE called from more than one
    # thread. The CGL backend virtualizes ONE real context per EGLDisplay — DisplayCGL::initialize
    # creates a single CGLContextObj and hands every ContextCGL the same RendererGL (so one
    # StateManagerGL, one dispatch table, and a DisplayCGL::mThreadsWithCurrentContext set mutated
    # from each calling thread) — and without ANGLE_ENABLE_SHARE_CONTEXT_LOCK,
    # SCOPED_SHARE_CONTEXT_LOCK() expands to NOTHING (libGLESv2/global_state.h), leaving every GL
    # entry point unlocked. The global mutex ANGLE always takes covers EGL entry points only.
    #
    # These two defines are ANGLE's own configuration for exactly this case: the share-context lock
    # serialises GL entry points, and FORCE_CONTEXT_CHECK_EVERY_CALL dirties all state whenever the
    # calling context differs from the last one used, which is what makes a virtualized shared
    # context correct across threads. Note the alternative — a separate EGLDisplay per thread via
    # EGL_PLATFORM_ANGLE_DISPLAY_KEY_ANGLE — is NOT available here: that attribute is validated
    # against EGL_ANGLE_platform_angle_device_id, which Display.cpp advertises for D3D11/Vulkan/Metal
    # only, so passing it on this backend fails validation and returns EGL_NO_DISPLAY.
    ANGLE_ENABLE_SHARE_CONTEXT_LOCK
    ANGLE_FORCE_CONTEXT_CHECK_EVERY_CALL
)

list(APPEND ANGLEGLESv2_LIBRARIES
    ${COREGRAPHICS_LIBRARY}
    ${FOUNDATION_LIBRARY}
    ${IOKIT_LIBRARY}
    ${IOSURFACE_LIBRARY}
    # MAVERICKS_BACKPORT: link OpenGL (not Metal); the CGL backend renders GLES via desktop GL on 10.9.
    ${OPENGL_LIBRARY}
    ${QUARTZ_LIBRARY}
)
