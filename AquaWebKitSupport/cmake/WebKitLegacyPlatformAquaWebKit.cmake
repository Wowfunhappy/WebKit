# Every backport change to WebKitLegacy's Mac CMake configuration.
#
# Source/WebKitLegacy/CMakeLists.txt is kept BYTE-UPSTREAM; Source/WebKitLegacy/PlatformCocoa.cmake and
# PlatformMac.cmake carry only the two include()s of this file. See
# AquaWebKitSupport/cmake/WebCorePlatformAquaWebKit.cmake for the rationale.
#
# Two phases:
#   LISTS    before WEBKIT_COMPUTE_SOURCES, where the unified-source lists are still editable.
#   POST     at the end of PlatformMac.cmake, once upstream has filled WebKitLegacy_SOURCES, for the
#            added sources, the target itself and the framework's Headers directory.

if (NOT DEFINED AQUAWEBKIT_WEBKITLEGACY_PHASE)
    message(FATAL_ERROR "WebKitLegacyPlatformAquaWebKit.cmake needs AQUAWEBKIT_WEBKITLEGACY_PHASE set to LISTS or POST.")
endif ()

if (AQUAWEBKIT_WEBKITLEGACY_PHASE STREQUAL "LISTS")

# WebView +initialize calls PAL::GCrypt::initialize() (WebCrypto is libgcrypt-backed on this port), so
# WebKitLegacy needs gcrypt.h reachable.
list(APPEND WebKitLegacy_PRIVATE_INCLUDE_DIRECTORIES
    "${AQUAWEBKIT_SUPPORT}/source/WebKitLegacy/mac/LegacyExtensions"
    "${AQUAWEBKIT_SUPPORT}/source/WebKitLegacy/mac/Misc"
    "${AQUAWEBKIT_SUPPORT}/source/WebKitLegacy/mac/WebCoreSupport"
    "${AQUAWEBKIT_DEPS}/include"
)

set(AQUAWEBKIT_WITHHELD_WEBKITLEGACY_COCOA_SOURCES "")

# The restored legacy CSS Dashboard region support, and the 10.9 SDK class DOMNotation.
set(AQUAWEBKIT_ADDED_WEBKITLEGACY_COCOA_SOURCES
    "mac/WebView/WebDashboardRegion.mm @nonARC"
    "mac/DOM/DOMNotation.mm @nonARC"
)

AQUAWEBKIT_FILTER_SOURCE_LIST("${WEBKITLEGACY_DIR}" WebKitLegacy_UNIFIED_SOURCE_LIST_FILES "SourcesCocoa.txt"
    AQUAWEBKIT_WITHHELD_WEBKITLEGACY_COCOA_SOURCES AQUAWEBKIT_ADDED_WEBKITLEGACY_COCOA_SOURCES)

# WebVideoFullscreenController is the AVKit presentation-mode controller, built on
# PlaybackSessionInterfaceAVKitLegacy, which exists only under ENABLE(VIDEO_PRESENTATION_MODE); that is
# off on this port, and element fullscreen serves <video>. Its Mac caller carries the same guard.
set(AQUAWEBKIT_WITHHELD_WEBKITLEGACY_CMAKE_COCOA_SOURCES "mac/WebView/WebVideoFullscreenController.mm @nonARC")
set(AQUAWEBKIT_ADDED_WEBKITLEGACY_CMAKE_COCOA_SOURCES "")
AQUAWEBKIT_FILTER_SOURCE_LIST("${WEBKITLEGACY_DIR}" WebKitLegacy_UNIFIED_SOURCE_LIST_FILES "SourcesCMakeCocoa.txt"
    AQUAWEBKIT_WITHHELD_WEBKITLEGACY_CMAKE_COCOA_SOURCES AQUAWEBKIT_ADDED_WEBKITLEGACY_CMAKE_COCOA_SOURCES)

elseif (AQUAWEBKIT_WEBKITLEGACY_PHASE STREQUAL "POST")

list(APPEND WebKitLegacy_SOURCES
    # Safari's HTTP WebDownload over the shared curl transport; WebDownload.mm reaches its header by
    # bare name, so the directory goes on the include path.
    ${AQUAWEBKIT_SUPPORT}/source/WebKitLegacy/mac/Misc/WebDownloadCurl.mm

    # The in-process SocketStreamHandle and the legacy WebSocketChannel, the WebKitLegacy-side backing
    # for the 10.9 WebSocket implementation. Its transport is this port's curl one rather than
    # upstream's CFStream file, so a WebSocket handshake presents the browser's ClientHello.
    WebCoreSupport/SocketStreamHandle.cpp
    WebCoreSupport/SocketStreamHandleImpl.cpp
    ${AQUAWEBKIT_SUPPORT}/source/WebKitLegacy/WebCoreSupport/SocketStreamHandleImplCurl.cpp
    WebCoreSupport/WebSocketChannel.cpp

    # The restored WebKeyGenerator Safari 7 imports downloaded certificates through, and the
    # WebKitSystemInterface function it calls.
    mac/WebCoreSupport/WebKeyGenerator.mm
    ${AQUAWEBKIT_SUPPORT}/source/WebKitLegacy/mac/WebCoreSupport/WebKitSystemInterface.mm
    # The restored WebKit1 getUserMedia client.
    ${AQUAWEBKIT_SUPPORT}/source/WebKitLegacy/mac/WebCoreSupport/WebUserMediaClient.mm
    # Hands WebKit's UI-process router the WebKit 1 views Safari 7 extension pages live in.
    ${AQUAWEBKIT_SUPPORT}/source/WebKitLegacy/mac/LegacyExtensions/WebLegacyExtensionPageObserver.mm
)

# The sources above supply the complete in-process WebSocket transport.
target_compile_definitions(WebKitLegacy PRIVATE WEBKIT_LEGACY_WEBSOCKET_CHANNEL=1)

# NSURLDownload file-format gzip decoding is separate from HTTP Content-Encoding.
find_package(ZLIB REQUIRED)
target_link_libraries(WebKitLegacy PRIVATE ZLIB::ZLIB)

# Plain Objective-C sources compile as -std=gnu17.
foreach (_aquaWebKitFile ${WebKitLegacy_SOURCES})
    get_filename_component(_aquaWebKitExt "${_aquaWebKitFile}" EXT)
    if (_aquaWebKitExt STREQUAL ".m")
        set_source_files_properties(${_aquaWebKitFile} PROPERTIES COMPILE_FLAGS -std=gnu17)
    endif ()
endforeach ()

# macOS's bundled WebKit-ObjC plug-ins -- notably Safari Web Clips' WebClip.plugin -- were linked
# against a 10.9 WebKit.framework that was an umbrella re-exporting WebCore, so they import e.g.
# _OBJC_CLASS_$_WebUndefined two-level-bound "from WebKit". WebUndefined (the JS `undefined` in the
# WebKit-ObjC bridge) lives in WebCore here and was the only such symbol our WebKit.framework did not
# already vend. Re-export WebCore through WebKit.framework, as 10.9 did, so those plug-ins resolve
# their imports. (ld64.lld implements -reexport_library but not -reexported_symbols_list.)
#
# The old ObjC "fixup" dispatch symbols (__objc_empty_cache and friends) that legacy Dashboard widget
# Plugin bundles and Web Clips also bind "from WebKit" arrive through the same chain: WebCore
# re-exports libobjc (Source/WebCore's -Wl,-reexport-lobjc), and this re-export carries it onward.
set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -Wl,-reexport_library,${CMAKE_BINARY_DIR}/lib/WebCore.framework/Versions/A/WebCore")

# Upstream's WK_WEBINSPECTORUI_LDFLAGS (WebKitLegacy.xcconfig: -weak_framework WebInspectorUI), needed
# against -dead_strip_dylibs as WebKitPlatformAquaWebKit.cmake links it into WebKit.
target_link_options(WebKitLegacy PRIVATE
    -F${CMAKE_LIBRARY_OUTPUT_DIRECTORY}
    "SHELL:-weak_framework WebInspectorUI"
    "LINKER:-needed_framework,WebInspectorUI"
)
add_dependencies(WebKitLegacy WebInspectorUIFramework)

# Upstream's INSTALL_NAME_DIR for the WebInspectorUI stub, applied at build time so WebKit and
# WebKitLegacy record the system framework's path; under CMP0068 BUILD_WITH_INSTALL_RPATH does not.
set_target_properties(WebInspectorUIFramework PROPERTIES BUILD_WITH_INSTALL_NAME_DIR ON)

# The image for the inspector window's native dock button, which the frontend this port ships needs to
# re-dock (see -[WebInspectorWindowController window]). Upstream ships it from its Xcode project; this
# is that copy step for the CMake build.
set(WebKitLegacy_RESOURCES_DIR ${CMAKE_LIBRARY_OUTPUT_DIRECTORY}/WebKitLegacy.framework/Versions/A/Resources)
foreach (_dock_image DockLegacy)
    add_custom_command(OUTPUT ${WebKitLegacy_RESOURCES_DIR}/${_dock_image}.pdf
        COMMAND ${CMAKE_COMMAND} -E copy ${WEBKITLEGACY_DIR}/mac/Resources/${_dock_image}.pdf ${WebKitLegacy_RESOURCES_DIR}/${_dock_image}.pdf
        DEPENDS ${WEBKITLEGACY_DIR}/mac/Resources/${_dock_image}.pdf
        VERBATIM)
    list(APPEND WebKitLegacy_DOCK_IMAGE_FILES ${WebKitLegacy_RESOURCES_DIR}/${_dock_image}.pdf)
endforeach ()
add_custom_target(WebKitLegacyInspectorDockImages ALL DEPENDS ${WebKitLegacy_DOCK_IMAGE_FILES})
add_dependencies(WebKitLegacy WebKitLegacyInspectorDockImages)

# The authentication panel WebPanelAuthenticationHandler puts on screen for a WK1 app that has no
# resource-load delegate of its own. -[WebAuthenticationPanel loadNib] resolves the nib through this
# framework's bundle, in the English.lproj stock 10.9 ships it in. Upstream compiles the xib from its
# Xcode project; the script is that step for the CMake build.
find_program(AQUAWEBKIT_IBTOOL ibtool HINTS /Applications/Xcode.app/Contents/Developer/usr/bin)
if (NOT AQUAWEBKIT_IBTOOL)
    message(FATAL_ERROR "WebKitLegacyPlatformAquaWebKit.cmake: no ibtool, so WebAuthenticationPanel.nib cannot be compiled.")
endif ()
set(WebKitLegacy_AUTHENTICATION_PANEL_NIB ${WebKitLegacy_RESOURCES_DIR}/English.lproj/WebAuthenticationPanel.nib)
add_custom_command(OUTPUT ${WebKitLegacy_AUTHENTICATION_PANEL_NIB}
    COMMAND ${AQUAWEBKIT_SUPPORT}/scripts/compile-authentication-panel-nib.sh
        ${AQUAWEBKIT_IBTOOL}
        ${WEBKITLEGACY_DIR}/mac/Panels/en.lproj/WebAuthenticationPanel.xib
        ${WebKitLegacy_AUTHENTICATION_PANEL_NIB}
    DEPENDS ${WEBKITLEGACY_DIR}/mac/Panels/en.lproj/WebAuthenticationPanel.xib
        ${AQUAWEBKIT_SUPPORT}/scripts/compile-authentication-panel-nib.sh
    VERBATIM)
add_custom_target(WebKitLegacyAuthenticationPanelNib ALL DEPENDS ${WebKitLegacy_AUTHENTICATION_PANEL_NIB})
add_dependencies(WebKitLegacy WebKitLegacyAuthenticationPanelNib)

# Legacy consumers (DumpRenderTree, and 10.9 WebKit-ObjC plug-ins) include the WebKit1 public headers
# under the historical <WebKit/...> umbrella, not <WebKitLegacy/...>. The Apple Xcode build ships a
# WebKit.framework umbrella for this; the CMake Mac path only populates <WebKitLegacy/...>. The headers
# are written into ${WebKitLegacy_FRAMEWORK_HEADERS_DIR}/WebKitLegacy at configure time by the
# forwarding-header loop above, so a sibling WebKit -> WebKitLegacy directory symlink makes every one
# of them resolvable as <WebKit/X.h> too (the Headers root is already on the interface include path,
# and clang's -I fallthrough finds them after the framework lookup misses). The modern
# <WebKit/WebKitLegacy.h> umbrella spelling newer tooling uses forwards to this tree's source umbrella,
# mac/Misc/WebKit.h.
if (NOT EXISTS ${WebKitLegacy_FRAMEWORK_HEADERS_DIR}/WebKitLegacy/WebKitLegacy.h)
    file(WRITE ${WebKitLegacy_FRAMEWORK_HEADERS_DIR}/WebKitLegacy/WebKitLegacy.h "#import <WebKitLegacy/WebKit.h>\n")
endif ()
# WebFeature.h is a WebKitLegacy WebView SPI that DumpRenderTree reads via <WebKit/WebFeature.h>, but
# it is not among the forwarded public headers; forward it explicitly so the include resolves to this
# full interface rather than the WebKit2 forward-declaration-only WebFeature.h.
if (EXISTS "${WEBKITLEGACY_DIR}/mac/WebView/WebFeature.h" AND NOT EXISTS "${WebKitLegacy_FRAMEWORK_HEADERS_DIR}/WebKitLegacy/WebFeature.h")
    file(WRITE ${WebKitLegacy_FRAMEWORK_HEADERS_DIR}/WebKitLegacy/WebFeature.h "#import \"${WEBKITLEGACY_DIR}/mac/WebView/WebFeature.h\"\n")
endif ()
# WebKeyGenerator.mm imports its own header as <WebKitLegacy/WebKeyGenerator.h>.
if (NOT EXISTS "${WebKitLegacy_FRAMEWORK_HEADERS_DIR}/WebKitLegacy/WebKeyGenerator.h")
    file(WRITE ${WebKitLegacy_FRAMEWORK_HEADERS_DIR}/WebKitLegacy/WebKeyGenerator.h "#import \"${WEBKITLEGACY_DIR}/mac/WebCoreSupport/WebKeyGenerator.h\"\n")
endif ()
if (NOT EXISTS ${WebKitLegacy_FRAMEWORK_HEADERS_DIR}/WebKit)
    file(CREATE_LINK WebKitLegacy ${WebKitLegacy_FRAMEWORK_HEADERS_DIR}/WebKit SYMBOLIC)
endif ()

else ()
    message(FATAL_ERROR "WebKitLegacyPlatformAquaWebKit.cmake: unknown AQUAWEBKIT_WEBKITLEGACY_PHASE '${AQUAWEBKIT_WEBKITLEGACY_PHASE}'.")
endif ()
