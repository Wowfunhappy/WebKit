# Every backport change to ANGLE's build configuration.
#
# Source/ThirdParty/ANGLE/PlatformMac.cmake ends with a single include() of this file, which runs after
# upstream has filled the ANGLE_* lists; Source/ThirdParty/ANGLE/CMakeLists.txt is byte-upstream. See
# AquaWebKitSupport/cmake/WebCorePlatformAquaWebKit.cmake for the rationale. The backend switch GL.cmake
# reads (angle_enable_cgl) is set in OptionsMacAquaWebKit.cmake.

# CGL uses the desktop-GL renderer and GLSL translator.
list(REMOVE_ITEM ANGLE_SOURCES ${metal_backend_sources} ${angle_translator_lib_msl_sources})
list(APPEND ANGLE_SOURCES ${gl_backend_sources})

list(REMOVE_ITEM ANGLE_DEFINITIONS ANGLE_ENABLE_METAL)
list(APPEND ANGLE_DEFINITIONS
    ANGLE_ENABLE_OPENGL
    ANGLE_ENABLE_CGL
    # The CGL backend is desktop OpenGL; DispatchTableGL::initProcsDesktopGL()
    # (DispatchTableGL_autogen.cpp) loads its entry points under this definition.
    ANGLE_ENABLE_GL_DESKTOP_BACKEND
)

find_library(OPENGL_LIBRARY OpenGL)
list(REMOVE_ITEM ANGLEGLESv2_LIBRARIES ${METAL_LIBRARY})
list(APPEND ANGLEGLESv2_LIBRARIES ${OPENGL_LIBRARY})
