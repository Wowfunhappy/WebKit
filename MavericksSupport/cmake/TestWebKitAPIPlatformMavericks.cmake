# Mavericks regression tests and the Network.framework test-server implementation.

# JavaScriptCore exports the shared WTF runtime; these clients need only its headers.
foreach (_mavAPITarget TestWebCore TestWebKit TestWebKitLegacy)
    list(REMOVE_ITEM ${_mavAPITarget}_LIBRARIES WTF)
endforeach ()

list(APPEND TestWTF_SOURCES
    ${CMAKE_SOURCE_DIR}/MavericksSupport/source/Tools/TestWebKitAPI/Tests/WTF/TextBreakIteratorClusters.cpp
)

list(APPEND TestWebCore_SOURCES
    ${CMAKE_SOURCE_DIR}/MavericksSupport/source/Tools/TestWebKitAPI/Tests/WebCore/BackdropFiltersMavericks.mm
    ${CMAKE_SOURCE_DIR}/MavericksSupport/source/Tools/TestWebKitAPI/Tests/WebCore/GStreamerCocoaPixelBuffer.mm
    ${CMAKE_SOURCE_DIR}/MavericksSupport/source/Tools/TestWebKitAPI/Tests/WebCore/AudioCaptureRestart.mm
    ${TESTWEBKITAPI_DIR}/Tests/WebCore/AbortableTaskQueue.cpp
    ${CMAKE_SOURCE_DIR}/MavericksSupport/source/Tools/TestWebKitAPI/Tests/WebCore/ImageBufferEncoding.cpp
)

# Upstream's TestWebKit target includes the Cocoa API tests and their fixtures.
list(APPEND TestWebKit_SOURCES
    ${MAVERICKS_SUPPORT}/source/Tools/TestWebKitAPI/cocoa/NetworkFrameworkMavericks.mm
    ${MAVERICKS_SUPPORT}/source/Tools/TestWebKitAPI/Tests/WebSocketServerTrust.mm
)
list(REMOVE_ITEM TestWebKit_LIBRARIES "-framework Network")
# Tests built on API this OS does not have: system accent colours, WebTransport over Network.framework,
# the font-panel helper's object_setInstanceVariableWithStrongDefault and NSImmediateActionGestureRecognizer.
# 10.9's AppKit keeps __NSInspectorBarItemController's class symbol local, so the Inspector Bar helper's
# subclass of it cannot link, and NSInspectorBar has no -setItemController:.
list(APPEND TestWebKit_UNIFIED_SOURCE_EXCLUDES
    "FontAttributes\\.mm"
    "FontManagerTests\\.mm"
    "ImmediateActionTests\\.mm"
    "InspectorBar\\.mm"
    "SystemColors\\.mm"
    "WKWebViewForTestingImmediateActions\\.mm"
    "WebTransport\\.mm"
)
list(REMOVE_ITEM TestWebKit_SOURCES
    Helpers/cocoa/WebTransportServer.mm
    Helpers/mac/NSFontPanelTesting.mm
    Helpers/mac/TestInspectorBar.mm
    Helpers/mac/WKWebViewForTestingImmediateActions.mm)

# Frameworks this OS does not ship load weakly.
foreach (_framework AuthenticationServices LocalAuthentication Reveal UniformTypeIdentifiers)
    list(REMOVE_ITEM TestWebKit_LIBRARIES "-framework ${_framework}")
    list(APPEND TestWebKit_LIBRARIES "-weak_framework ${_framework}")
endforeach ()
target_compile_options(TestWebKit PRIVATE $<$<COMPILE_LANGUAGE:OBJC,OBJCXX>:-fobjc-weak>)

# Give the API tests their own website data store and testing identity.
set(PRODUCT_NAME TestWebKitAPI)
set(PRODUCT_BUNDLE_IDENTIFIER com.apple.WebKit.TestWebKitAPI)
configure_file(${TESTWEBKITAPI_DIR}/Info.plist ${CMAKE_CURRENT_BINARY_DIR}/TestWebKitAPIInfo.plist)
target_link_options(TestWebKit PRIVATE
    "-Wl,-sectcreate,__TEXT,__info_plist,${CMAKE_CURRENT_BINARY_DIR}/TestWebKitAPIInfo.plist")
set_property(TARGET TestWebKit APPEND PROPERTY LINK_DEPENDS
    "${CMAKE_CURRENT_BINARY_DIR}/TestWebKitAPIInfo.plist")
add_dependencies(TestWebKit TestWebKitAPIInjectedBundle)

# NSBundle looks for both injected bundles beside the API test executable.
set_target_properties(TestWebKitAPIInjectedBundle TestWebKitAPIWebProcessPlugIn PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "${TESTWEBKITAPI_RUNTIME_OUTPUT_DIRECTORY}")

list(APPEND TestWebCore_PRIVATE_INCLUDE_DIRECTORIES
    ${WEBCORE_DIR}/platform/graphics
    ${WEBCORE_DIR}/platform/graphics/gstreamer
)
list(APPEND TestWebCore_LIBRARIES ${GSTREAMER_LIBRARIES} ${GSTREAMER_VIDEO_LIBRARIES} "-framework CoreVideo")
