set_property(DIRECTORY . PROPERTY FOLDER "WebKitLegacy")

set(WebKitLegacy_SOURCES
    Storage/InProcessIDBServer.cpp
    Storage/StorageAreaImpl.cpp
    Storage/StorageAreaSync.cpp
    Storage/StorageNamespaceImpl.cpp
    Storage/StorageSyncManager.cpp
    Storage/StorageThread.cpp
    Storage/StorageTracker.cpp
    Storage/WebDatabaseProvider.cpp
    Storage/WebStorageNamespaceProvider.cpp

    # MAVERICKS_BACKPORT: build the legacy socket provider + WebKitLegacy inspector
    # debuggable/controller sources, which the modern upstream WebKitLegacy build omits.
    WebCoreSupport/LegacySocketProvider.cpp
    WebCoreSupport/LegacyWebPageDebuggable.cpp
    WebCoreSupport/LegacyWebPageInspectorController.cpp
    WebCoreSupport/NetworkStorageSessionMap.cpp
    # MAVERICKS_BACKPORT: compile the in-process SocketStreamHandle (CFNetwork) + legacy
    # WebSocketChannel, the WebKitLegacy-side backing for the 10.9 WebSocket implementation.
    WebCoreSupport/SocketStreamHandle.cpp
    WebCoreSupport/SocketStreamHandleImpl.cpp
    WebCoreSupport/SocketStreamHandleImplCFNet.cpp
    WebCoreSupport/WebBroadcastChannelRegistry.cpp
    WebCoreSupport/WebResourceLoadScheduler.cpp
    # MAVERICKS_BACKPORT: legacy WebSocketChannel, the WebKitLegacy-side backing for the
    # 10.9 WebSocket implementation, which the modern upstream WebKitLegacy build omits.
    WebCoreSupport/WebSocketChannel.cpp
    WebCoreSupport/WebViewGroup.cpp
)

set(WebKitLegacy_PRIVATE_INCLUDE_DIRECTORIES
    "${CMAKE_BINARY_DIR}"
    "${WEBKITLEGACY_DIR}/Storage"
    "${WEBKITLEGACY_DIR}/WebCoreSupport"
    "${WebKitLegacy_DERIVED_SOURCES_DIR}"
)

set(WebKitLegacy_FRAMEWORKS
    JavaScriptCore
    PAL
    WTF
    WebCore
    bmalloc
)

set(WebKitLegacy_INTERFACE_LIBRARIES WebKitLegacy)
set(WebKitLegacy_INTERFACE_INCLUDE_DIRECTORIES ${WebKitLegacy_FRAMEWORK_HEADERS_DIR})
set(WebKitLegacy_INTERFACE_DEPENDENCIES WebKitLegacy_CopyHeaders)

WEBKIT_FRAMEWORK_DECLARE(WebKitLegacy)
WEBKIT_INCLUDE_CONFIG_FILES_IF_EXISTS()
WEBKIT_FRAMEWORK(WebKitLegacy)

WEBKIT_COPY_FILES(WebKitLegacy_CopyHeaders
    DESTINATION ${WebKitLegacy_FRAMEWORK_HEADERS_DIR}/WebKitLegacy
    FILES ${WebKitLegacy_PUBLIC_FRAMEWORK_HEADERS}
    FLATTENED
)

# MAVERICKS_BACKPORT: legacy consumers (DumpRenderTree, and 10.9 WebKit-ObjC plug-ins) include the WebKit1
# public headers under the historical <WebKit/...> umbrella, not <WebKitLegacy/...>. The Apple Xcode build
# ships a WebKit.framework umbrella for this; the CMake Mac path only populates <WebKitLegacy/...>. The
# headers are written into ${WebKitLegacy_FRAMEWORK_HEADERS_DIR}/WebKitLegacy at configure time (the
# forwarding-header foreach in PlatformMac.cmake, included just above), so a sibling WebKit -> WebKitLegacy
# directory symlink makes every one of them resolvable as <WebKit/X.h> too (the Headers root is already on
# the interface include path, and clang's -I fallthrough finds them after the framework lookup misses).
# Also provide the modern <WebKit/WebKitLegacy.h> umbrella spelling that newer tooling uses; this tree's
# source umbrella is still mac/Misc/WebKit.h, so forward to it.
if (NOT EXISTS ${WebKitLegacy_FRAMEWORK_HEADERS_DIR}/WebKitLegacy/WebKitLegacy.h)
    file(WRITE ${WebKitLegacy_FRAMEWORK_HEADERS_DIR}/WebKitLegacy/WebKitLegacy.h "#import <WebKitLegacy/WebKit.h>\n")
endif ()
# MAVERICKS_BACKPORT: WebFeature.h is a WebKitLegacy WebView SPI that DumpRenderTree reads via
# <WebKit/WebFeature.h>, but it is not among the forwarded public headers; forward it explicitly so the
# include resolves to this full interface rather than the WebKit2 forward-declaration-only WebFeature.h.
if (EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/mac/WebView/WebFeature.h" AND NOT EXISTS "${WebKitLegacy_FRAMEWORK_HEADERS_DIR}/WebKitLegacy/WebFeature.h")
    file(WRITE ${WebKitLegacy_FRAMEWORK_HEADERS_DIR}/WebKitLegacy/WebFeature.h "#import \"${CMAKE_CURRENT_SOURCE_DIR}/mac/WebView/WebFeature.h\"\n")
endif ()
if (NOT EXISTS ${WebKitLegacy_FRAMEWORK_HEADERS_DIR}/WebKit)
    file(CREATE_LINK WebKitLegacy ${WebKitLegacy_FRAMEWORK_HEADERS_DIR}/WebKit SYMBOLIC)
endif ()
