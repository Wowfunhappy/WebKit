find_library(QUARTZ_LIBRARY Quartz)
find_library(CARBON_LIBRARY Carbon)
find_library(CORESERVICES_LIBRARY CoreServices)

add_definitions(-DJSC_API_AVAILABLE\\\(...\\\)=)
add_definitions(-DJSC_CLASS_AVAILABLE\\\(...\\\)=)

# FIXME: We shouldn't need to define NS_RETURNS_RETAINED.
add_definitions(-iframework ${QUARTZ_LIBRARY}/Frameworks -iframework ${CORESERVICES_LIBRARY}/Frameworks -DNS_RETURNS_RETAINED=)

link_directories(../../WebKitLibraries)
include_directories(../../WebKitLibraries)

list(APPEND DumpRenderTree_LIBRARIES
    ${CARBON_LIBRARY}
    ${QUARTZ_LIBRARY}
    WebKit
)

list(APPEND DumpRenderTree_INCLUDE_DIRECTORIES
    ${DumpRenderTree_DIR}/cg
    ${DumpRenderTree_DIR}/cf
    ${DumpRenderTree_DIR}/cocoa
    ${DumpRenderTree_DIR}/mac
    ${DumpRenderTree_DIR}/mac/InternalHeaders/WebKit
    ${DumpRenderTree_DIR}/TestNetscapePlugIn
    ${WEBCORE_DIR}/testing/cocoa
    ${WEBKITLEGACY_DIR}
    # MAVERICKS_BACKPORT: DumpRenderTree.mm pulls in WebHTMLViewForTestingMac.h (a WebKitLegacy testing SPI
    # that lives with the WebView sources, not in the forwarded public headers) via a quoted include.
    ${WEBKITLEGACY_DIR}/mac/WebView
    ${WebKitTestRunner_SHARED_DIR}/cocoa
    ${WebKitTestRunner_SHARED_DIR}/mac
    ${WebKitTestRunner_SHARED_DIR}/spi
    # MAVERICKS_BACKPORT: DumpRenderTree.mm also uses one WebKit2 C-API header (<WebKit/WKURLRequest.h>).
    # Add the WebKit (WK2) forwarding-headers root LAST so the WebKit1 umbrella above keeps priority for the
    # header names the two frameworks share, while WK2-only headers still resolve.
    ${WebKit_FRAMEWORK_HEADERS_DIR}
)

# Common ${DumpRenderTree_SOURCES} from CMakeLists.txt are C++ source files.
list(APPEND DumpRenderTree_Cpp_SOURCES
    ${DumpRenderTree_SOURCES}
)

list(APPEND DumpRenderTree_ObjC_SOURCES
    DumpRenderTreeFileDraggingSource.m

    mac/AppleScriptController.m
    mac/NavigationController.m
    mac/ObjCPlugin.m
    mac/ObjCPluginFunction.m
    mac/TextInputControllerMac.m
)

list(APPEND DumpRenderTree_Cpp_SOURCES
    cg/PixelDumpSupportCG.cpp
)

list(APPEND DumpRenderTree_ObjCpp_SOURCES
    DefaultPolicyDelegate.mm
    cocoa/UIScriptControllerCocoa.mm
    mac/AccessibilityCommonMac.mm
    mac/AccessibilityControllerMac.mm
    mac/AccessibilityNotificationHandler.mm
    mac/AccessibilityTextMarkerMac.mm
    mac/AccessibilityUIElementMac.mm
    mac/DumpRenderTree.mm
    mac/DumpRenderTreeDraggingInfo.mm
    mac/DumpRenderTreeMain.mm
    mac/DumpRenderTreePasteboard.mm
    mac/DumpRenderTreeWindow.mm
    mac/EditingDelegate.mm
    mac/EventSendingController.mm
    mac/FrameLoadDelegate.mm
    mac/GCControllerMac.mm
    mac/HistoryDelegate.mm
    mac/MockGeolocationProvider.mm
    mac/MockWebNotificationProvider.mm
    mac/ObjCController.m
    mac/PixelDumpSupportMac.mm
    mac/PolicyDelegate.mm
    mac/ResourceLoadDelegate.mm
    mac/TestRunnerMac.mm
    mac/UIDelegate.mm
    mac/UIScriptControllerMac.mm
    mac/WorkQueueItemMac.mm
    ${WebKitTestRunner_SHARED_DIR}/cocoa/ClassMethodSwizzler.mm
    ${WebKitTestRunner_SHARED_DIR}/cocoa/LayoutTestSpellChecker.mm
    # MAVERICKS_BACKPORT: these shared TestRunnerShared sources are compiled per-consumer (the
    # TestRunnerShared object library only carries the cross-platform sources); DumpRenderTree references
    # their symbols (poseAsClass, InstanceMethodSwizzler, ModifierKeys, +_modernPasteboardType:) but did
    # not list them.
    ${WebKitTestRunner_SHARED_DIR}/cocoa/PoseAsClass.mm
    ${WebKitTestRunner_SHARED_DIR}/cocoa/InstanceMethodSwizzler.mm
    ${WebKitTestRunner_SHARED_DIR}/cocoa/ModifierKeys.mm
    ${WebKitTestRunner_SHARED_DIR}/mac/NSPasteboardAdditions.mm
)

set(DumpRenderTree_SOURCES
    ${DumpRenderTree_Cpp_SOURCES}
    ${DumpRenderTree_ObjC_SOURCES}
    ${DumpRenderTree_ObjCpp_SOURCES}
)

foreach (_file ${DumpRenderTree_ObjC_SOURCES})
    set_source_files_properties(${_file} PROPERTIES COMPILE_FLAGS "-std=c99")
endforeach ()

set(DumpRenderTree_RESOURCES
    AHEM____.TTF
    FontWithFeatures.otf
    FontWithFeatures.ttf
    WebKitWeightWatcher100.ttf
    WebKitWeightWatcher200.ttf
    WebKitWeightWatcher300.ttf
    WebKitWeightWatcher400.ttf
    WebKitWeightWatcher500.ttf
    WebKitWeightWatcher600.ttf
    WebKitWeightWatcher700.ttf
    WebKitWeightWatcher800.ttf
    WebKitWeightWatcher900.ttf
)

file(MAKE_DIRECTORY ${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/DumpRenderTree.resources)
foreach (_file ${DumpRenderTree_RESOURCES})
    if (NOT EXISTS ${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/DumpRenderTree.resources/${_file})
        file(COPY ${TOOLS_DIR}/DumpRenderTree/fonts/${_file} DESTINATION ${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/DumpRenderTree.resources)
    endif ()
endforeach ()

# MAVERICKS_BACKPORT: LayoutTestHelper is an Xcode-only target upstream, but run-webkit-tests launches it
# (start_helper) to pin the display color profile before a test run, so the CMake harness needs it too. It
# uses only 10.9-available frameworks (AppKit/ApplicationServices/IOKit/ColorSync).
set(LayoutTestHelper_SOURCES ${DumpRenderTree_DIR}/mac/LayoutTestHelper.m)
set(LayoutTestHelper_PRIVATE_INCLUDE_DIRECTORIES
    ${DumpRenderTree_DIR}
    ${CMAKE_BINARY_DIR}
    # config.h pulls in wtf/Platform.h and JavaScriptCore export macros — header-only, but the forwarding
    # dirs must be on the path (this tool does not otherwise link those frameworks).
    ${WTF_FRAMEWORK_HEADERS_DIR}
    ${bmalloc_FRAMEWORK_HEADERS_DIR}
    ${JavaScriptCore_FRAMEWORK_HEADERS_DIR}
    ${JavaScriptCore_PRIVATE_FRAMEWORK_HEADERS_DIR}
    ${PAL_FRAMEWORK_HEADERS_DIR}
    ${WebCore_PRIVATE_FRAMEWORK_HEADERS_DIR})
set(LayoutTestHelper_LIBRARIES
    "-framework AppKit"
    "-framework ApplicationServices"
    "-framework ColorSync"
    "-framework CoreFoundation"
    "-framework CoreGraphics"
    "-framework IOKit"
    # The globally force-loaded libpolyfill.a pulls in references to SQLite and Accelerate/vImage that this
    # tool does not use itself; satisfy them so the link completes.
    "-framework Accelerate"
    sqlite3
)
WEBKIT_EXECUTABLE_DECLARE(LayoutTestHelper)
WEBKIT_EXECUTABLE(LayoutTestHelper)
