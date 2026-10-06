include(PlatformCocoa.cmake)

find_library(IOKIT_LIBRARY IOKit)
find_library(QUARTZ_LIBRARY Quartz)

list(APPEND ANGLE_SOURCES
    ${libangle_gpu_info_util_mac_sources}
)

list(APPEND ANGLEGLESv2_LIBRARIES
    ${IOKIT_LIBRARY}
    ${QUARTZ_LIBRARY}
)

# AQUAWEBKIT: single seam -- see AquaWebKitSupport/cmake/ANGLEPlatformAquaWebKit.cmake, which
# carries every change this port makes to ANGLE's build configuration.
set(AQUAWEBKIT_ANGLE_PHASE POST)
include(${CMAKE_SOURCE_DIR}/AquaWebKitSupport/cmake/ANGLEPlatformAquaWebKit.cmake)
