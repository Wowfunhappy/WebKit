# Every backport change to WebKitLegacy's Mac CMake configuration.
#
# Source/WebKitLegacy/CMakeLists.txt is kept BYTE-UPSTREAM and Source/WebKitLegacy/PlatformMac.cmake
# carries only the three include()s of this file. See MavericksSupport/cmake/WebCorePlatformMavericks.cmake
# for the rationale.
#
# Three phases, because PlatformMac.cmake computes sources, classifies them, writes forwarding headers
# and then operates on the target, each from a different point in the file:
#   LISTS    before WEBKIT_COMPUTE_SOURCES, where the unified-source lists are still editable.
#   SOURCES  after upstream has filled WebKitLegacy_SOURCES and the forwarding-header list, before the
#            compile-flags loop and the forwarding-header loop read them.
#   POST     at the end of the file, for the target itself and the framework's Headers directory.

if (NOT DEFINED MAVERICKS_WEBKITLEGACY_PHASE)
    message(FATAL_ERROR "WebKitLegacyPlatformMavericks.cmake needs MAVERICKS_WEBKITLEGACY_PHASE set to LISTS, SOURCES or POST.")
endif ()

if (MAVERICKS_WEBKITLEGACY_PHASE STREQUAL "LISTS")

# WebView +initialize calls PAL::GCrypt::initialize() (WebCrypto is libgcrypt-backed on this port), so
# WebKitLegacy needs gcrypt.h reachable.
list(APPEND WebKitLegacy_PRIVATE_INCLUDE_DIRECTORIES
    "${MAVERICKS_DEPS}/include"
)

set(MAVERICKS_WITHHELD_WEBKITLEGACY_COCOA_SOURCES "")

# The restored legacy CSS Dashboard region support.
set(MAVERICKS_ADDED_WEBKITLEGACY_COCOA_SOURCES
    "mac/WebView/WebDashboardRegion.mm @nonARC"
)

MAVERICKS_FILTER_SOURCE_LIST("${WEBKITLEGACY_DIR}" WebKitLegacy_UNIFIED_SOURCE_LIST_FILES "SourcesCocoa.txt"
    MAVERICKS_WITHHELD_WEBKITLEGACY_COCOA_SOURCES MAVERICKS_ADDED_WEBKITLEGACY_COCOA_SOURCES)

elseif (MAVERICKS_WEBKITLEGACY_PHASE STREQUAL "SOURCES")

# Stale entry in upstream's own list: it names WebDefaultPolicyDelegate.m, and upstream ships the
# Objective-C++ .mm at that path.
list(REMOVE_ITEM WebKitLegacy_SOURCES
    mac/DefaultDelegates/WebDefaultPolicyDelegate.m
)

list(APPEND WebKitLegacy_SOURCES
    mac/DefaultDelegates/WebDefaultPolicyDelegate.mm

    # The legacy socket provider and the WebKitLegacy inspector debuggable/controller, which the
    # modern upstream WebKitLegacy build omits.
    WebCoreSupport/LegacySocketProvider.cpp
    WebCoreSupport/LegacyWebPageDebuggable.cpp
    WebCoreSupport/LegacyWebPageInspectorController.cpp
    # The in-process SocketStreamHandle (CFNetwork) and the legacy WebSocketChannel, the
    # WebKitLegacy-side backing for the 10.9 WebSocket implementation.
    WebCoreSupport/SocketStreamHandle.cpp
    WebCoreSupport/SocketStreamHandleImpl.cpp
    WebCoreSupport/SocketStreamHandleImplCFNet.cpp
    WebCoreSupport/WebSocketChannel.cpp
    # WebCrypto is libgcrypt-backed on this port, and WebKit1 needs its own client for it.
    WebCoreSupport/WebCryptoClient.mm

    # The legacy WebKeyGenerator (<keygen> support) and LegacyHistoryItemClient, which the modern
    # upstream WebKitLegacy build omits.
    mac/Misc/WebKeyGenerator.mm
    mac/WebCoreSupport/LegacyHistoryItemClient.mm
    # The restored WebKit1 getUserMedia client.
    mac/WebCoreSupport/WebUserMediaClient.mm
)

list(APPEND WebKitLegacy_LEGACY_FORWARDING_HEADERS_FILES
    # The restored WebKit1 getUserMedia client's header.
    mac/WebCoreSupport/WebUserMediaClient.h
)

# The preferences add_custom_command below reads WebKit_WEB_PREFERENCES and
# WebKit_WEB_PREFERENCES_TEMPLATES, which are set in Source/WebKit's directory scope and are empty
# here -- so the rule had no file-level input and an edit to the yaml's WebKitLegacy column never
# regenerated WebPreferencesDefinitions.h. Name WebKitLegacy's own inputs in this scope: the yaml the
# generator reads (a copy destination under WTF_SCRIPTS_DIR, hence GENERATED) and the four templates
# it renders.
set(WebKit_WEB_PREFERENCES
    ${WTF_SCRIPTS_DIR}/Preferences/UnifiedWebPreferences.yaml
)
set_source_files_properties(${WebKit_WEB_PREFERENCES} PROPERTIES GENERATED TRUE)

set(WebKit_WEB_PREFERENCES_TEMPLATES
    ${WEBKITLEGACY_DIR}/mac/Scripts/PreferencesTemplates/WebViewPreferencesChangedGenerated.mm.erb
    ${WEBKITLEGACY_DIR}/mac/Scripts/PreferencesTemplates/WebPreferencesDefinitions.h.erb
    ${WEBKITLEGACY_DIR}/mac/Scripts/PreferencesTemplates/WebPreferencesExperimentalFeatures.mm.erb
    ${WEBKITLEGACY_DIR}/mac/Scripts/PreferencesTemplates/WebPreferencesInternalFeatures.mm.erb
)

elseif (MAVERICKS_WEBKITLEGACY_PHASE STREQUAL "POST")

# Plain Objective-C sources compile as -std=gnu17. The classification loop above knows only C99_FILES
# and CPP_FILES and hands everything else the -ObjC++ branch, which no .m file can take.
foreach (_mavFile ${WebKitLegacy_SOURCES})
    get_filename_component(_mavExt "${_mavFile}" EXT)
    if (_mavExt STREQUAL ".m")
        list(FIND C99_FILES ${_mavFile} _mavC99Index)
        if (_mavC99Index EQUAL -1)
            set_source_files_properties(${_mavFile} PROPERTIES COMPILE_FLAGS -std=gnu17)
        endif ()
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

# Upstream's WK_WEBINSPECTORUI_LDFLAGS (WebKitLegacy.xcconfig: -weak_framework WebInspectorUI) -- the
# load command dyld needs so [NSBundle bundleWithIdentifier:@"com.apple.WebInspectorUI"] finds the
# frontend bundle in WK1 host processes (WebInspectorFrontendClient and WebInspectorWindowController
# resolve Main.html and localizedStrings.js through it). The xcconfig flag has no CMake counterpart.
# Linked by exact dylib path because the stock 10.9 framework is not in the modern SDK's search paths.
target_link_options(WebKitLegacy PRIVATE -weak_library /System/Library/PrivateFrameworks/WebInspectorUI.framework/Versions/A/WebInspectorUI)

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
if (NOT EXISTS ${WebKitLegacy_FRAMEWORK_HEADERS_DIR}/WebKit)
    file(CREATE_LINK WebKitLegacy ${WebKitLegacy_FRAMEWORK_HEADERS_DIR}/WebKit SYMBOLIC)
endif ()

else ()
    message(FATAL_ERROR "WebKitLegacyPlatformMavericks.cmake: unknown MAVERICKS_WEBKITLEGACY_PHASE '${MAVERICKS_WEBKITLEGACY_PHASE}'.")
endif ()
