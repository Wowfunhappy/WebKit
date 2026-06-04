# 10.9 backport: ANGLE uses its CGL OpenGL backend instead of Metal (Metal is unavailable on
# 10.9). The CGL backend (src/libANGLE/renderer/gl/cgl/*) renders GLES via desktop OpenGL through
# CGL and can present into an IOSurface — the software-CGL→IOSurface→WindowServer path that works
# on this VM. angle_enable_cgl/angle_enable_gl are set in CMakeLists.txt before include(GL.cmake).
find_library(COREGRAPHICS_LIBRARY CoreGraphics)
find_library(FOUNDATION_LIBRARY Foundation)
find_library(IOKIT_LIBRARY IOKit)
find_library(IOSURFACE_LIBRARY IOSurface)
find_library(OPENGL_LIBRARY OpenGL)
find_library(QUARTZ_LIBRARY Quartz)
find_package(ZLIB REQUIRED)

list(APPEND ANGLE_SOURCES
    ${gl_backend_sources}

    ${libangle_gpu_info_util_mac_sources}
    ${libangle_gpu_info_util_sources}
    ${libangle_mac_sources}
)

list(APPEND ANGLE_DEFINITIONS
    ANGLE_ENABLE_OPENGL
    ANGLE_ENABLE_CGL
    # 10.9 backport: the CGL backend uses DESKTOP OpenGL. Without this, the entire
    # body of DispatchTableGL::initProcsDesktopGL() (DispatchTableGL_autogen.cpp,
    # guarded by #if defined(ANGLE_ENABLE_GL_DESKTOP_BACKEND)) compiles away, so NO
    # desktop GL entry points load and the FunctionsGL pointers stay null — caps
    # generation then calls a null genTextures/genFramebuffers and crashes WebContent.
    ANGLE_ENABLE_GL_DESKTOP_BACKEND
)

list(APPEND ANGLEGLESv2_LIBRARIES
    ${COREGRAPHICS_LIBRARY}
    ${FOUNDATION_LIBRARY}
    ${IOKIT_LIBRARY}
    ${IOSURFACE_LIBRARY}
    ${OPENGL_LIBRARY}
    ${QUARTZ_LIBRARY}
)
