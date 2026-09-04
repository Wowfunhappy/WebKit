find_library(CARBON_LIBRARY Carbon)
find_library(FOUNDATION_LIBRARY Foundation)

find_library(APPLICATIONSERVICES_LIBRARY ApplicationServices)
find_library(CORESERVICES_LIBRARY CoreServices)
add_definitions(-iframework ${APPLICATIONSERVICES_LIBRARY}/Versions/Current/Frameworks)
add_definitions(-iframework ${CORESERVICES_LIBRARY}/Versions/Current/Frameworks)

link_directories(../../WebKitLibraries)
add_definitions(-DJSC_API_AVAILABLE\\\(...\\\)=)
add_definitions(-DJSC_CLASS_AVAILABLE\\\(...\\\)=)

list(APPEND WebKitTestRunner_LIBRARIES
    ${CARBON_LIBRARY}
)

list(APPEND WebKitTestRunner_INCLUDE_DIRECTORIES
    ${CMAKE_BINARY_DIR}
    ${CMAKE_SOURCE_DIR}/WebKitLibraries
    ${ICU_INCLUDE_DIRS}
    ${WEBCORE_DIR}/testing/cocoa
    ${WEBKITLEGACY_DIR}
    # MAVERICKS_BACKPORT: the <WebKit/WebKit.h> (WK2) umbrella pulls in <WebKit/WebKitLegacy.h>, which includes
    # the WebKit1 DOM umbrella <WebKit/DOM.h>. Those resolve via the WebKit->WebKitLegacy headers symlink in
    # ${WebKitLegacy_FRAMEWORK_HEADERS_DIR}, so put that forwarded-headers root on the path (WebKitTestRunner
    # does not link WebKitLegacy, so it isn't added automatically).
    ${WebKitLegacy_FRAMEWORK_HEADERS_DIR}
    ${WebKitTestRunner_DIR}/cf
    ${WebKitTestRunner_DIR}/cg
    ${WebKitTestRunner_DIR}/cocoa
    ${WebKitTestRunner_DIR}/mac
    ${WebKitTestRunner_DIR}/InjectedBundle/mac
    ${WebKitTestRunner_SHARED_DIR}/EventSerialization/mac
    ${WebKitTestRunner_SHARED_DIR}/cocoa
    ${WebKitTestRunner_SHARED_DIR}/mac
    ${WebKitTestRunner_SHARED_DIR}/spi
    # MAVERICKS_BACKPORT: the testing helpers (UIScriptControllerCocoa.mm, WKTextExtractionTestingHelpers.mm)
    # import a WebKit-internal Cocoa API header by name (#import "_WKTextExtractionInternal.h"), which Apple's
    # Xcode build resolves via the WebKit project header search path. The cmake port forwards the public/private
    # Cocoa API headers but not the *Internal.h ones, so add the source dir last (after the WebKit2 forwarded
    # headers prepended in CMakeLists.txt) to satisfy these quoted internal includes without shadowing anything.
    ${WEBKIT_DIR}/UIProcess/API/Cocoa
)

list(APPEND TestRunnerInjectedBundle_SOURCES
    ${WebKitTestRunner_DIR}/InjectedBundle/cocoa/AccessibilityCommonCocoa.mm
    ${WebKitTestRunner_DIR}/InjectedBundle/cocoa/ActivateFontsCocoa.mm
    ${WebKitTestRunner_DIR}/InjectedBundle/cocoa/InjectedBundlePageCocoa.mm

    ${WebKitTestRunner_DIR}/InjectedBundle/mac/AccessibilityControllerMac.mm
    ${WebKitTestRunner_DIR}/InjectedBundle/mac/AccessibilityNotificationHandler.mm
    ${WebKitTestRunner_DIR}/InjectedBundle/cocoa/AccessibilityTextMarkerRangeCocoa.mm
    ${WebKitTestRunner_DIR}/InjectedBundle/mac/InjectedBundleMac.mm
    ${WebKitTestRunner_DIR}/InjectedBundle/mac/AccessibilityTextMarkerMac.mm
    ${WebKitTestRunner_DIR}/InjectedBundle/mac/AccessibilityUIElementMac.mm
    # MAVERICKS_BACKPORT: these are referenced by the bundle (AccessibilityUIElementClientMac::create and
    # setCrashReportApplicationSpecificInfo from InjectedBundlePageCocoa.mm) but were not in the Mac source
    # list (Apple builds this via Xcode), so the bundle failed to link with undefined symbols.
    ${WebKitTestRunner_DIR}/InjectedBundle/mac/AccessibilityUIElementClientMac.mm
    ${WebKitTestRunner_DIR}/cocoa/CrashReporterInfo.mm
    ${WebKitTestRunner_DIR}/InjectedBundle/mac/TestRunnerMac.mm

    ${WebKitTestRunner_SHARED_DIR}/EventSerialization/mac/EventSerializerMac.mm
    ${WebKitTestRunner_SHARED_DIR}/EventSerialization/mac/SharedEventStreamsMac.mm
)

list(APPEND TestRunnerInjectedBundle_LIBRARIES
    ${FOUNDATION_LIBRARY}
    JavaScriptCore
    WTF
    WebCoreTestSupport
    WebKit
)
# MAVERICKS_BACKPORT: append as a STRING, not a list. CMAKE_SHARED_LINKER_FLAGS is a space-separated string;
# the backport already puts -fuse-ld=lld in it, so the upstream `set(VAR ${VAR} "-framework Cocoa")` form
# produced a ';'-joined list ("-fuse-ld=lld;-framework Cocoa"), which the shell split (-framework: not found).
set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -framework Cocoa")

list(APPEND WebKitTestRunner_SOURCES
    ${WebKitTestRunner_DIR}/cocoa/TestControllerCocoa.mm
    ${WebKitTestRunner_DIR}/cocoa/TestRunnerWKWebView.mm
    ${WebKitTestRunner_DIR}/cocoa/TestWebsiteDataStoreDelegate.mm
    ${WebKitTestRunner_DIR}/cocoa/UIScriptControllerCocoa.mm
    # MAVERICKS_BACKPORT: cocoa sources that define symbols the WebKitTestRunner executable references
    # (EventSenderProxyCocoa::mouseButtonsCurrentlyDown, TestInvocation::dumpPixelsAndCompareWithExpected,
    # WebNotificationProvider::simulateWebNotificationClick..., setCrashReportApplicationSpecificInformationToURL)
    # but which were missing from the Mac source list (Apple builds them via Xcode).
    # WKTextExtractionTestingHelpers.mm is intentionally omitted: it depends on the Swift-only _WKTextExtraction
    # classes that this build cannot compile (see UIScriptControllerCocoa.mm's WTR_WK_TEXT_EXTRACTION_AVAILABLE).
    ${WebKitTestRunner_DIR}/cocoa/EventSenderProxyCocoa.mm
    ${WebKitTestRunner_DIR}/cocoa/TestInvocationCocoa.mm
    ${WebKitTestRunner_DIR}/cocoa/WebNotificationProviderCocoa.mm
    ${WebKitTestRunner_DIR}/cocoa/CrashReporterInfo.mm

    ${WebKitTestRunner_DIR}/mac/EventSenderProxy.mm
    ${WebKitTestRunner_DIR}/mac/PlatformWebViewMac.mm
    ${WebKitTestRunner_DIR}/mac/TestControllerMac.mm
    ${WebKitTestRunner_DIR}/mac/UIScriptControllerMac.mm
    ${WebKitTestRunner_DIR}/mac/WebKitTestRunnerDraggingInfo.mm
    ${WebKitTestRunner_DIR}/mac/WebKitTestRunnerEvent.mm
    ${WebKitTestRunner_DIR}/mac/WebKitTestRunnerPasteboard.mm
    ${WebKitTestRunner_DIR}/mac/WebKitTestRunnerWindow.mm
    ${WebKitTestRunner_DIR}/mac/main.mm

    ${WebKitTestRunner_SHARED_DIR}/cocoa/ClassMethodSwizzler.mm
    ${WebKitTestRunner_SHARED_DIR}/cocoa/PlatformViewHelpers.mm
    ${WebKitTestRunner_SHARED_DIR}/cocoa/PoseAsClass.mm
    # MAVERICKS_BACKPORT: WebKitTestRunnerPasteboard.mm calls +[NSPasteboard _modernPasteboardType:],
    # which this shared source defines.
    ${WebKitTestRunner_SHARED_DIR}/mac/NSPasteboardAdditions.mm
    # MAVERICKS_BACKPORT: shared cocoa sources defining InstanceMethodSwizzler, ModifierKeys and
    # LayoutTestSpellChecker, referenced by EventSenderProxy/TestController but missing from the Mac list.
    ${WebKitTestRunner_SHARED_DIR}/cocoa/InstanceMethodSwizzler.mm
    ${WebKitTestRunner_SHARED_DIR}/cocoa/ModifierKeys.mm
    ${WebKitTestRunner_SHARED_DIR}/cocoa/LayoutTestSpellChecker.mm

    ${WebKitTestRunner_SHARED_DIR}/EventSerialization/mac/EventSerializerMac.mm
    ${WebKitTestRunner_SHARED_DIR}/EventSerialization/mac/SharedEventStreamsMac.mm
)

link_directories(../../WebKitLibraries)
