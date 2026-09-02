find_library(CARBON_LIBRARY Carbon)
find_library(QUARTZCORE_LIBRARY QuartzCore)

set(TESTWEBKITAPI_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_RUNTIME_OUTPUT_DIRECTORY}")
add_definitions(-DJSC_API_AVAILABLE\\\(...\\\)=)
add_definitions(-DJSC_CLASS_AVAILABLE\\\(...\\\)=)

include_directories(
    "${ICU_INCLUDE_DIRS}"
)

set(test_main_SOURCES
    ${TESTWEBKITAPI_DIR}/cocoa/UtilitiesCocoa.mm
    ${TESTWEBKITAPI_DIR}/mac/mainMac.mm
)

find_library(CARBON_LIBRARY Carbon)
find_library(COCOA_LIBRARY Cocoa)
find_library(COREFOUNDATION_LIBRARY CoreFoundation)
link_directories(${CMAKE_SOURCE_DIR}/WebKitLibraries)
list(APPEND test_wtf_LIBRARIES
    ${CARBON_LIBRARY}
    ${COCOA_LIBRARY}
    ${COREFOUNDATION_LIBRARY}
)
# MAVERICKS_BACKPORT: every Mac test binary needs an entry point, and only TestWebKitLegacy was given
# one (the Apple Mac port builds TestWebKitAPI from Xcode upstream, so this CMake path never linked).
# test_main_SOURCES already carries cocoa/UtilitiesCocoa.mm, so it replaces the lone listing here.
list(APPEND TestWTF_SOURCES
    ${test_main_SOURCES}
)

list(APPEND TestWebKitAPI_LIBRARIES
    ${CARBON_LIBRARY}
)

list(APPEND TestWebKitLegacy_LIBRARIES
    WTF
    WebKit
    ${CARBON_LIBRARY}
)

list(APPEND TestWebCore_LIBRARIES
    JavaScriptCore
    WTF
    WebKit
)

set(bundle_harness_SOURCES
    ${TESTWEBKITAPI_DIR}/cocoa/PlatformUtilitiesCocoa.mm
    ${TESTWEBKITAPI_DIR}/cocoa/UtilitiesCocoa.mm
    ${TESTWEBKITAPI_DIR}/mac/InjectedBundleControllerMac.mm
    ${TESTWEBKITAPI_DIR}/mac/PlatformUtilitiesMac.mm
    ${TESTWEBKITAPI_DIR}/mac/PlatformWebViewMac.mm
    ${TESTWEBKITAPI_DIR}/mac/SyntheticBackingScaleFactorWindow.m
    ${TESTWEBKITAPI_DIR}/mac/TestBrowsingContextLoadDelegate.mm
)

list(APPEND TestWebKitLegacy_SOURCES
    ${test_main_SOURCES}
)
# MAVERICKS_BACKPORT: these two are strings, not lists -- set() with two arguments joins them with a
# semicolon, which reaches the link line as `-fuse-ld=lld;-framework Cocoa` and runs as a shell command.
set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -framework Cocoa")
set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -framework Cocoa")

list(APPEND TestWebKit_LIBRARIES
    JavaScriptCore
    WTF
    ${CARBON_LIBRARY}
)

# MAVERICKS_BACKPORT: TestWebKit names only WebKit as a framework, and on this port that one does not
# carry the WTF, JavaScriptCore, PAL or WebCore forwarded headers -- so config.h's <wtf/Platform.h> and
# the export-macro headers beside it are unreachable. TestWebCore and TestWebKitLegacy each name every
# framework whose headers they include; do the same here.
list(APPEND TestWebKit_FRAMEWORKS
    JavaScriptCore
    PAL
    WTF
    WebCore
    bmalloc
)

# TestWebKitAPIBase and TestWebKitAPIInjectedBundle are plain libraries with no framework list, and
# they read TestWebKit_PRIVATE_INCLUDE_DIRECTORIES where they are declared -- above, before this file
# is included -- so they take the header roots directly.
foreach (_target TestWebKitAPIBase TestWebKitAPIInjectedBundle)
    if (TARGET ${_target})
        target_include_directories(${_target} PRIVATE
            ${JavaScriptCore_FRAMEWORK_HEADERS_DIR}
            ${PAL_FRAMEWORK_HEADERS_DIR}
            ${WTF_FRAMEWORK_HEADERS_DIR}
            ${WebCore_FRAMEWORK_HEADERS_DIR}
            ${bmalloc_FRAMEWORK_HEADERS_DIR})
    endif ()
endforeach ()

# The injected bundle's own code allocates through FastMalloc, so it needs WTF -- IMPORTED from
# JavaScriptCore.framework, which is where every other consumer gets it. Naming the bare WTF target
# instead would absorb its objects, including the process-singleton g_config that JavaScriptCore
# already defines (see the same trap in Tools/WebKitTestRunner/CMakeLists.txt).
if (TARGET TestWebKitAPIInjectedBundle)
    target_link_libraries(TestWebKitAPIInjectedBundle PRIVATE JavaScriptCore)
endif ()

list(APPEND TestWebCore_LIBRARIES
    ${QUARTZCORE_LIBRARY}
)

list(APPEND TestWebCore_SOURCES
    ${test_main_SOURCES}
)

list(APPEND TestWebKit_SOURCES
    ${test_main_SOURCES}

    mac/OffscreenWindow.mm
    mac/PlatformUtilitiesMac.mm
    mac/PlatformWebViewMac.mm
)

# MAVERICKS_BACKPORT: seam for the Cocoa (WKWebView) API tests -- see
# MavericksSupport/cmake/TestWebKitAPIPlatformMavericks.cmake.
include(${CMAKE_SOURCE_DIR}/MavericksSupport/cmake/TestWebKitAPIPlatformMavericks.cmake)
