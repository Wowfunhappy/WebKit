# Every backport change to ANGLE's build configuration.
#
# Source/ThirdParty/ANGLE/CMakeLists.txt and Source/ThirdParty/ANGLE/PlatformMac.cmake are kept
# BYTE-UPSTREAM and each carries a single include() of this file. See
# MavericksSupport/cmake/WebCorePlatformMavericks.cmake for the rationale.
#
# Two phases, because the backend switches have to be answered before the renderer .cmake files read
# them and the source/definition/library lists only exist afterwards:
#   BACKEND  from CMakeLists.txt, between the platform if-chain and include(GLESv2.cmake)/include(GL.cmake).
#   POST     from the end of PlatformMac.cmake, after upstream has filled the ANGLE_* lists.

if (NOT DEFINED MAVERICKS_ANGLE_PHASE)
    message(FATAL_ERROR "ANGLEPlatformMavericks.cmake needs MAVERICKS_ANGLE_PHASE set to BACKEND or POST.")
endif ()

if (MAVERICKS_ANGLE_PHASE STREQUAL "BACKEND")

# ANGLE renders through its CGL OpenGL backend (src/libANGLE/renderer/gl/cgl/*) rather than Metal,
# which 10.9 does not have: GLES over desktop OpenGL through CGL, presenting into an IOSurface.
# GL.cmake reads angle_enable_cgl when it composes gl_backend_sources, and GLESv2.cmake reads
# is_apple for the Apple common sources the CGL backend needs (FunctionsCGL.cpp,
# apple_platform_utils.mm, system_utils_mac.cpp), so both are set ahead of those two includes.
if (APPLE)
    set(is_apple TRUE)
    set(angle_enable_cgl TRUE)
endif ()

elseif (MAVERICKS_ANGLE_PHASE STREQUAL "POST")

# The GLSL (desktop-GL) output path on Apple runs Apple-specific AST tree operations
# (UnfoldShortCircuitAST, AddAndTrueToLoopCondition, RewriteRowMajorMatrices). Compiler.cmake defines
# the group and upstream's ANGLE_SOURCES never names it, so TranslatorGLSL leaves
# sh::UnfoldShortCircuitAST undefined and WebContent takes a dyld lazy-bind crash on the first
# glCompileShader.
list(APPEND ANGLE_SOURCES ${angle_translator_glsl_apple_sources})

# The CGL/desktop-GL backend sources in place of the Metal ones.
list(REMOVE_ITEM ANGLE_SOURCES ${metal_backend_sources})
list(APPEND ANGLE_SOURCES ${gl_backend_sources})

list(REMOVE_ITEM ANGLE_DEFINITIONS ANGLE_ENABLE_METAL)
list(APPEND ANGLE_DEFINITIONS
    ANGLE_ENABLE_OPENGL
    ANGLE_ENABLE_CGL
    # The CGL backend is DESKTOP OpenGL. Without this the body of
    # DispatchTableGL::initProcsDesktopGL() (DispatchTableGL_autogen.cpp, guarded by
    # #if defined(ANGLE_ENABLE_GL_DESKTOP_BACKEND)) compiles away, no desktop GL entry point loads,
    # and caps generation calls a null genTextures.
    ANGLE_ENABLE_GL_DESKTOP_BACKEND
)

find_library(OPENGL_LIBRARY OpenGL)
list(REMOVE_ITEM ANGLEGLESv2_LIBRARIES ${METAL_LIBRARY})
list(APPEND ANGLEGLESv2_LIBRARIES ${OPENGL_LIBRARY})

else ()
    message(FATAL_ERROR "ANGLEPlatformMavericks.cmake: unknown MAVERICKS_ANGLE_PHASE '${MAVERICKS_ANGLE_PHASE}'.")
endif ()
