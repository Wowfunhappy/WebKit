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
    # thread. ANGLE's contract for that is explicit: without ANGLE_ENABLE_SHARE_CONTEXT_LOCK,
    # SCOPED_SHARE_CONTEXT_LOCK() expands to NOTHING (libGLESv2/global_state.h) and "the client needs
    # to use gl calls in a threadsafe way" — the global mutex ANGLE always takes covers EGL entry
    # points only. This client cannot make that promise, so the lock is enabled.
    #
    # Note this is NOT what keeps two threads off one real GL context: the CGL backend virtualizes one
    # CGLContextObj + RendererGL per EGLDisplay, and CGL forbids a context being current on two
    # threads at once, which no lock inside ANGLE repairs (measured: with only this lock, concurrent
    # main-thread + worker WebGL still aborted in Apple's GLEngine). That is solved by giving each
    # thread its own EGLDisplay — see initializeEGLDisplay in GraphicsContextGLCocoa.mm.
    #
    # ANGLE_FORCE_CONTEXT_CHECK_EVERY_CALL is deliberately NOT set. It exists for contexts that share
    # a RendererGL, which per-thread displays never do, and it compares against the process-global
    # g_LastContext (global_state.cpp), so with two threads drawing it would call
    # Context::dirtyAllState() on effectively every GL entry point — a full state re-sync per call,
    # degrading the very concurrency this configuration exists to provide.
    ANGLE_ENABLE_SHARE_CONTEXT_LOCK
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
