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
