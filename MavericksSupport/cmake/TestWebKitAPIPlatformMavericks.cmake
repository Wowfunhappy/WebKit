# TestWebKitCocoa: the Objective-C (WKWebView) half of TestWebKitAPI.
#
# Apple builds Tools/TestWebKitAPI from Xcode, where one TestWebKitAPI target holds both the C-API
# tests (Tests/WebKit, which upstream's CMake path builds as TestWebKit) and the Cocoa tests
# (Tests/WebKitCocoa, which it does not build at all). This target adds the Cocoa half: the shared
# Cocoa test harness, the cookie test files, and the 10.9 implementation of the Network.framework
# entry points HTTPServer is written against.

set(TestWebKitCocoa_SOURCES
    ${TESTWEBKITAPI_DIR}/DeprecatedGlobalValues.cpp
    ${TESTWEBKITAPI_DIR}/DeprecatedGlobalValues.mm
    ${TESTWEBKITAPI_DIR}/NetworkConnection.mm
    ${TESTWEBKITAPI_DIR}/PlatformUtilities.cpp
    ${TESTWEBKITAPI_DIR}/TestNSBundleExtras.m
    ${TESTWEBKITAPI_DIR}/TestsController.cpp
    ${TESTWEBKITAPI_DIR}/Utilities.cpp
    ${TESTWEBKITAPI_DIR}/WKWebViewConfigurationExtras.mm

    ${TESTWEBKITAPI_DIR}/cocoa/CGImagePixelReader.cpp
    ${TESTWEBKITAPI_DIR}/cocoa/HTTPServer.mm
    ${TESTWEBKITAPI_DIR}/cocoa/HostWindowManager.mm
    ${TESTWEBKITAPI_DIR}/cocoa/PlatformUtilitiesCocoa.mm
    ${TESTWEBKITAPI_DIR}/cocoa/TestCocoa.mm
    ${TESTWEBKITAPI_DIR}/cocoa/TestNavigationDelegate.mm
    ${TESTWEBKITAPI_DIR}/cocoa/TestUIDelegate.mm
    ${TESTWEBKITAPI_DIR}/cocoa/TestWKWebView.mm
    ${TESTWEBKITAPI_DIR}/cocoa/UtilitiesCocoa.mm

    ${TESTWEBKITAPI_DIR}/mac/PlatformUtilitiesMac.mm
    ${TESTWEBKITAPI_DIR}/mac/mainMac.mm

    ${TOOLS_DIR}/TestRunnerShared/cocoa/ClassMethodSwizzler.mm
    ${TOOLS_DIR}/TestRunnerShared/cocoa/InstanceMethodSwizzler.mm

    ${CMAKE_SOURCE_DIR}/MavericksSupport/source/Tools/TestWebKitAPI/cocoa/NetworkFrameworkMavericks.mm

    # Challenge.mm defines testCertificate()/testIdentity()/testIdentity2(), which HTTPServer's TLS
    # configuration calls, alongside its own tests.
    ${TESTWEBKITAPI_DIR}/Tests/WebKitCocoa/Challenge.mm

    ${TESTWEBKITAPI_DIR}/Tests/WebKitCocoa/CookieAcceptPolicy.mm
    ${TESTWEBKITAPI_DIR}/Tests/WebKitCocoa/CookiePrivateBrowsing.mm
    ${TESTWEBKITAPI_DIR}/Tests/WebKitCocoa/CookieStoreAPI.mm
    ${TESTWEBKITAPI_DIR}/Tests/WebKitCocoa/WKHTTPCookieStore.mm
)

set(TestWebKitCocoa_PRIVATE_INCLUDE_DIRECTORIES
    ${CMAKE_BINARY_DIR}
    ${TESTWEBKITAPI_DIR}
    ${TESTWEBKITAPI_DIR}/cocoa
    ${TESTWEBKITAPI_DIR}/mac
    ${TOOLS_DIR}/TestRunnerShared/cocoa
    ${JavaScriptCore_PRIVATE_FRAMEWORK_HEADERS_DIR}
    ${PAL_FRAMEWORK_HEADERS_DIR}
    ${WebCore_PRIVATE_FRAMEWORK_HEADERS_DIR}
    ${WebKit_FRAMEWORK_HEADERS_DIR}
    # <WebKit/WebKit.h> reaches <WebKit/WebKitLegacy.h> and from there the WebKit1 DOM umbrella,
    # which lives in WebKitLegacy's forwarded headers and includes its targets by source-relative
    # path ("mac/DOM/DOM.h").
    ${WebKitLegacy_FRAMEWORK_HEADERS_DIR}
    ${WEBKITLEGACY_DIR}
    ${ICU_INCLUDE_DIRS}
)

set(TestWebKitCocoa_LIBRARIES
    WebKit::gtest
    ${CARBON_LIBRARY}
    ${COCOA_LIBRARY}
)

set(TestWebKitCocoa_FRAMEWORKS
    JavaScriptCore
    PAL
    WTF
    WebCore
    WebKit
)

WEBKIT_EXECUTABLE_DECLARE(TestWebKitCocoa)
WEBKIT_EXECUTABLE(TestWebKitCocoa)
set_target_properties(TestWebKitCocoa PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${TESTWEBKITAPI_RUNTIME_OUTPUT_DIRECTORY})
if (COMPILER_IS_GCC_OR_CLANG)
    WEBKIT_ADD_TARGET_CXX_FLAGS(TestWebKitCocoa ${TestWebKitAPI_DISABLED_WARNINGS} -Wno-deprecated-declarations)
endif ()

# The Xcode target compiles these sources with TestWebKitAPIPrefix.h as its prefix header, and the
# Cocoa tests and their harness rely on what it brings in (Cocoa, gtest, the WTF string and vector
# types) as well as on the Objective-C API umbrella that config.h reaches only from its Xcode branch.
# This port's prefix header carries both, which keeps Tools/TestWebKitAPI/config.h byte-upstream.
target_compile_options(TestWebKitCocoa PRIVATE
    -include ${CMAKE_SOURCE_DIR}/MavericksSupport/source/Tools/TestWebKitAPI/TestWebKitCocoaPrefix.h)

# The Cocoa harness declares __weak ivars in files SourcesCocoa.txt marks @nonARC; Xcode compiles
# those with CLANG_ENABLE_OBJC_WEAK, which is what makes __weak legal outside ARC.
target_compile_options(TestWebKitCocoa PRIVATE $<$<COMPILE_LANGUAGE:OBJC,OBJCXX>:-fobjc-weak>)

# WebKit derives the default website data store's directories -- the cookie jar included -- from the
# main bundle's identifier, so a binary without one reads and writes the login session's own cookies
# and no test starts from an empty store. The Xcode target's identity comes from
# Configurations/TestWebKitAPI.xcconfig; a command-line tool carries its Info.plist in a
# __TEXT,__info_plist section rather than a Contents/Info.plist.
set(PRODUCT_NAME TestWebKitCocoa)
set(PRODUCT_BUNDLE_IDENTIFIER com.apple.WebKit.TestWebKitAPI)
configure_file(${TESTWEBKITAPI_DIR}/Info.plist ${CMAKE_CURRENT_BINARY_DIR}/TestWebKitCocoaInfo.plist)
target_link_options(TestWebKitCocoa PRIVATE
    "-Wl,-sectcreate,__TEXT,__info_plist,${CMAKE_CURRENT_BINARY_DIR}/TestWebKitCocoaInfo.plist")
set_property(TARGET TestWebKitCocoa APPEND PROPERTY LINK_DEPENDS
    "${CMAKE_CURRENT_BINARY_DIR}/TestWebKitCocoaInfo.plist")

# Force-load rather than link the polyfill archive: its gap-fills are compiled -fvisibility=hidden, so
# an ordinary archive link never pulls them, and the reference then binds to the SDK's Security stub --
# which make-build-binaries-runnable.sh repoints onto libpolyfill_classes.dylib, a library that
# reexports Security and defines the absent ObjC classes but carries none of the C gap-fills. So
# SecKeyCreateWithData, which Challenge.mm calls to build the TLS test identity, had nowhere to bind at
# run time. Force-loading puts every polyfill definition in the image, as the shipped processes do.
# The layer's Network.framework answers are weak (polyfills/c/Network.c), so this binary's own
# implementation of those entry points wins without any of them going missing.
_WEBKIT_FORCE_LOAD_POLYFILL(TestWebKitCocoa)

# Challenge.mm sends -[NSKeyedArchiver initRequiringSecureCoding:], which 10.9's Foundation does not
# implement. WK_POLYFILL_ADD_METHODS installs it under a renamed selector and the selref patcher
# rewrites the call sites only in images carrying __DATA,__wk_marker, so this image needs the marker
# for its own sends to reach the added method.
_WEBKIT_FORCE_LOAD_WK_MARKER(TestWebKitCocoa)

# Several tests load fixtures out of a TestWebKitAPIResources.bundle beside the executable
# (NSBundle.test_resourcesBundle, and TestWKWebView's synchronouslyLoadTestPageNamed:); the Xcode build
# produces it from a resources target. Assemble the same bundle from the non-source files that sit
# beside the Cocoa tests.
set(_mavTestResourcesBundle ${TESTWEBKITAPI_RUNTIME_OUTPUT_DIRECTORY}/TestWebKitAPIResources.bundle)
file(GLOB _mavTestResources ${TESTWEBKITAPI_DIR}/Tests/WebKitCocoa/*)
list(FILTER _mavTestResources EXCLUDE REGEX "\\.(mm|cpp|m|h|swift)$")
foreach (_entry IN LISTS _mavTestResources)
    if (IS_DIRECTORY "${_entry}")
        list(REMOVE_ITEM _mavTestResources "${_entry}")
    endif ()
endforeach ()
file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/TestWebKitAPIResourcesInfo.plist
"<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\"><dict>
  <key>CFBundleIdentifier</key><string>com.apple.WebKit.TestWebKitAPIResources</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleVersion</key><string>1</string>
</dict></plist>
")
add_custom_command(TARGET TestWebKitCocoa POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory ${_mavTestResourcesBundle}/Contents/Resources
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        ${CMAKE_CURRENT_BINARY_DIR}/TestWebKitAPIResourcesInfo.plist
        ${_mavTestResourcesBundle}/Contents/Info.plist
    COMMAND ${CMAKE_COMMAND} -E copy_if_different ${_mavTestResources}
        ${_mavTestResourcesBundle}/Contents/Resources
    VERBATIM)

# A Cocoa test that installs a WKWebProcessPlugIn names its plug-in class and loads it out of a
# TestWebKitAPI.wkbundle beside the executable (WKWebViewConfiguration's
# _test_configurationWithTestPlugInClassName:); the Xcode build produces that bundle from a target of
# its own. Assemble the same bundle here: the principal class, which instantiates the class the test
# named and forwards to it, and the plug-in classes belonging to the tests built above.
set(TestWebKitAPIWKBundle_LIBRARY_TYPE SHARED)
set(TestWebKitAPIWKBundle_OUTPUT_NAME TestWebKitAPI)

set(TestWebKitAPIWKBundle_SOURCES
    ${TESTWEBKITAPI_DIR}/cocoa/PlatformUtilitiesCocoa.mm
    ${TESTWEBKITAPI_DIR}/cocoa/WebProcessPlugIn/WebProcessPlugIn.mm

    ${TESTWEBKITAPI_DIR}/Tests/WebKitCocoa/BasicProposedCredentialPlugIn.mm
)

set(TestWebKitAPIWKBundle_PRIVATE_INCLUDE_DIRECTORIES
    ${TestWebKitCocoa_PRIVATE_INCLUDE_DIRECTORIES}
    ${bmalloc_FRAMEWORK_HEADERS_DIR}
    ${WTF_FRAMEWORK_HEADERS_DIR}
    ${JavaScriptCore_FRAMEWORK_HEADERS_DIR})
set(TestWebKitAPIWKBundle_LIBRARIES ${TestWebKitCocoa_LIBRARIES})
set(TestWebKitAPIWKBundle_FRAMEWORKS bmalloc WTF WebKit)

WEBKIT_LIBRARY_DECLARE(TestWebKitAPIWKBundle)
WEBKIT_LIBRARY(TestWebKitAPIWKBundle)
target_link_libraries(TestWebKitAPIWKBundle PRIVATE WebKit::WebKit)
target_compile_options(TestWebKitAPIWKBundle PRIVATE
    -include ${CMAKE_SOURCE_DIR}/MavericksSupport/source/Tools/TestWebKitAPI/TestWebKitCocoaPrefix.h)
if (COMPILER_IS_GCC_OR_CLANG)
    WEBKIT_ADD_TARGET_CXX_FLAGS(TestWebKitAPIWKBundle ${TestWebKitAPI_DISABLED_WARNINGS} -Wno-deprecated-declarations)
endif ()

file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/TestWebKitAPIWKBundleInfo.plist
"<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\"><dict>
  <key>CFBundleExecutable</key><string>TestWebKitAPI</string>
  <key>CFBundleIdentifier</key><string>com.apple.WebKit.TestWebKitAPI.InjectedBundle</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>NSPrincipalClass</key><string>WebProcessPlugIn</string>
</dict></plist>
")

set(_mavTestPlugInBundle ${TESTWEBKITAPI_RUNTIME_OUTPUT_DIRECTORY}/TestWebKitAPI.wkbundle)
add_custom_command(TARGET TestWebKitAPIWKBundle POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory ${_mavTestPlugInBundle}/Contents/MacOS
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        ${CMAKE_CURRENT_BINARY_DIR}/TestWebKitAPIWKBundleInfo.plist
        ${_mavTestPlugInBundle}/Contents/Info.plist
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        $<TARGET_FILE:TestWebKitAPIWKBundle> ${_mavTestPlugInBundle}/Contents/MacOS/TestWebKitAPI
    VERBATIM)
add_dependencies(TestWebKitCocoa TestWebKitAPIWKBundle)
