set(WebKitTestRunner_DIR "${TOOLS_DIR}/WebKitTestRunner")

file(MAKE_DIRECTORY ${WebKitTestRunner_DERIVED_SOURCES_DIR}/InjectedBundle)
file(MAKE_DIRECTORY ${WebKitTestRunner_DERIVED_SOURCES_DIR}/UIScriptContext)

set(WebKitTestRunner_SOURCES
    CyclicRedundancyCheck.cpp
    GeolocationProviderMock.cpp
    Options.cpp
    PixelDumpSupport.cpp
    TestController.cpp
    TestInvocation.cpp
    TestOptions.cpp
    UIScriptControllerCommon.cpp
    WebNotificationProvider.cpp
    WorkQueueManager.cpp
)

set(WebKitTestRunner_LIBRARIES
    WebKit::TestRunnerShared
    WebKit::WebCoreTestSupport
)
set(WebKitTestRunner_FRAMEWORKS
    JavaScriptCore
    PAL
    WTF
    WebCore
    WebKit
    bmalloc
)

if (COMPILER_IS_GCC_OR_CLANG)
    if (HAVE_STD_EXPERIMENTAL_FILESYSTEM)
        list(APPEND WebKitTestRunner_LIBRARIES stdc++fs)
    endif ()
endif ()

set(WebKitTestRunner_PRIVATE_INCLUDE_DIRECTORIES
    ${CMAKE_BINARY_DIR}
    ${WebKitTestRunner_DERIVED_SOURCES_DIR}
    ${WebKitTestRunner_DERIVED_SOURCES_DIR}/UIScriptContext
    ${WebKitTestRunner_DIR}
)

set(WebKitTestRunner_WEB_PREFERENCES_TEMPLATES
    ${WebKitTestRunner_DIR}/Scripts/PreferencesTemplates/TestOptionsGeneratedKeys.h.erb
)

set(WebKitTestRunner_WEB_PREFERENCES
    ${WTF_SCRIPTS_DIR}/Preferences/UnifiedWebPreferences.yaml
)

set_source_files_properties(${WebKitTestRunner_WEB_PREFERENCES} PROPERTIES GENERATED TRUE)

add_custom_command(
    OUTPUT ${WebKitTestRunner_DERIVED_SOURCES_DIR}/TestOptionsGeneratedKeys.h
    DEPENDS ${WebKitTestRunner_WEB_PREFERENCES_TEMPLATES} ${WebKitTestRunner_WEB_PREFERENCES} WTF_CopyPreferences
    COMMAND ${Ruby_EXECUTABLE} ${WTF_SCRIPTS_DIR}/GeneratePreferences.rb --frontend WebKit --outputDir "${WebKitTestRunner_DERIVED_SOURCES_DIR}" --template ${WebKitTestRunner_DIR}/Scripts/PreferencesTemplates/TestOptionsGeneratedKeys.h.erb ${WebKitTestRunner_WEB_PREFERENCES}
    COMMAND_EXPAND_LISTS
    VERBATIM)

list(APPEND WebKitTestRunner_SOURCES
    ${WebKitTestRunner_DERIVED_SOURCES_DIR}/TestOptionsGeneratedKeys.h
)

set(WebKitTestRunner_DEPENDENCIES TestRunnerInjectedBundle)

set(TestRunnerInjectedBundle_SOURCES
    InjectedBundle/AccessibilityController.cpp
    InjectedBundle/AccessibilityTextMarker.cpp
    InjectedBundle/AccessibilityTextMarkerRange.cpp
    InjectedBundle/AccessibilityUIElement.cpp
    InjectedBundle/EventSendingController.cpp
    InjectedBundle/GCController.cpp
    InjectedBundle/InjectedBundle.cpp
    InjectedBundle/InjectedBundleMain.cpp
    InjectedBundle/InjectedBundlePage.cpp
    InjectedBundle/TestRunner.cpp
    InjectedBundle/TextInputController.cpp
)

set(TestRunnerInjectedBundle_PRIVATE_INCLUDE_DIRECTORIES
    ${CMAKE_BINARY_DIR}
    ${WebKitTestRunner_DERIVED_SOURCES_DIR}/InjectedBundle
    ${WebKitTestRunner_DIR}
    ${WebKitTestRunner_DIR}/InjectedBundle
    # MAVERICKS_BACKPORT: the injected-bundle mac/ sources quote-include cocoa/ headers (AccessibilityCommonCocoa.h)
    # and the shared cocoa/ headers (CrashReporterInfo.h), which the Mac CMake path did not put on the bundle's
    # include path (Apple builds this via Xcode). Add both so the bundle compiles.
    ${WebKitTestRunner_DIR}/InjectedBundle/cocoa
    ${WebKitTestRunner_DIR}/cocoa
)

set(TestRunnerInjectedBundle_LIBRARY_TYPE SHARED)
set(TestRunnerInjectedBundle_PRIVATE_LIBRARIES
    WebKit::TestRunnerShared
    WebKit::WebCoreTestSupport
)
set(TestRunnerInjectedBundle_FRAMEWORKS ${WebKitTestRunner_FRAMEWORKS})

set(TestRunnerInjectedBundle_IDL_FILES
    "${WebKitTestRunner_DIR}/InjectedBundle/Bindings/AccessibilityController.idl"
    "${WebKitTestRunner_DIR}/InjectedBundle/Bindings/AccessibilityTextMarker.idl"
    "${WebKitTestRunner_DIR}/InjectedBundle/Bindings/AccessibilityTextMarkerRange.idl"
    "${WebKitTestRunner_DIR}/InjectedBundle/Bindings/AccessibilityUIElement.idl"
    "${WebKitTestRunner_DIR}/InjectedBundle/Bindings/EventSendingController.idl"
    "${WebKitTestRunner_DIR}/InjectedBundle/Bindings/GCController.idl"
    "${WebKitTestRunner_DIR}/InjectedBundle/Bindings/TestRunner.idl"
    "${WebKitTestRunner_DIR}/InjectedBundle/Bindings/TextInputController.idl"
)

GENERATE_BINDINGS(TestRunnerInjectedBundleBindings
    OUTPUT_SOURCE TestRunnerInjectedBundle_SOURCES
    INPUT_FILES ${TestRunnerInjectedBundle_IDL_FILES}
    BASE_DIR ${WebKitTestRunner_DIR}/InjectedBundle/Bindings
    FEATURES ${FEATURE_DEFINES_WITH_SPACE_SEPARATOR}
    DESTINATION ${WebKitTestRunner_DERIVED_SOURCES_DIR}/InjectedBundle
    GENERATOR TestRunner
)

set(TestRunnerInjectedBundle_DEPENDENCIES
    TestRunnerInjectedBundleBindings
)

WEBKIT_EXECUTABLE_DECLARE(WebKitTestRunner)
WEBKIT_LIBRARY_DECLARE(TestRunnerInjectedBundle)
WEBKIT_INCLUDE_CONFIG_FILES_IF_EXISTS()

WEBKIT_LIBRARY(TestRunnerInjectedBundle)
WEBKIT_EXECUTABLE(WebKitTestRunner)

# MAVERICKS_BACKPORT: the SHARED injected bundle absorbs the WTF (and bmalloc) OBJECT libraries directly, which
# REDEFINES the WTF/JSC process-singleton g_config (the __DATA,__wtf_config record holding the JSC structure-heap
# base, gigacage limits, etc.) -- a SECOND, never-initialized copy alongside the one in the JavaScriptCore
# framework the bundle also links. The bundle's inline JSC binding code (creating window.internals) then reads a
# null structure-heap base and crashes the WebContent process. JavaScriptCore.framework already contains WTF and
# exports its symbols (WebCore/WebKit import g_config from it, never define their own), so strip the absorbed
# WTF/bmalloc objects from the bundle and let it import them from the framework -- keeping g_config a single
# initialized instance. (The standalone WebKitTestRunner executable keeps them: it initializes its own config.)
if (TARGET TestRunnerInjectedBundle)
    get_target_property(_ib_link_libs TestRunnerInjectedBundle LINK_LIBRARIES)
    set(_ib_link_libs_filtered "")
    foreach (_ib_lib IN LISTS _ib_link_libs)
        if ((NOT _ib_lib STREQUAL "WTF") AND (NOT _ib_lib STREQUAL "bmalloc") AND (NOT _ib_lib MATCHES "TARGET_OBJECTS:(WTF|bmalloc)>"))
            list(APPEND _ib_link_libs_filtered "${_ib_lib}")
        endif ()
    endforeach ()
    set_target_properties(TestRunnerInjectedBundle PROPERTIES LINK_LIBRARIES "${_ib_link_libs_filtered}")
endif ()

# MAVERICKS_BACKPORT: WebKitTestRunner is a WebKit2 tool but also needs the WebKit1 (WebKitLegacy) <WebKit/...>
# umbrella on its include path, because the WebKit2 <WebKit/WebKit.h> umbrella pulls in <WebKit/WebKitLegacy.h>
# -> <WebKit/DOM.h>, which only exist in the WebKitLegacy headers root (added in PlatformMac.cmake). That root
# also contains a WebKit1 <WebKit/WebKit.h> (the legacy umbrella, no WKWebView), which would shadow the WebKit2
# umbrella and leave WKWebView only forward-declared -- breaking the TestRunnerWKWebView : WKWebView subclass.
# So force the WebKit2 headers root to be searched first; WebKit1-only headers (DOM.h, WebView.h, ...) still
# resolve from the WebKitLegacy root since WebKit2 does not ship them. (Inverse of the DumpRenderTree order fix.)
if (TARGET WebKitTestRunner)
    target_include_directories(WebKitTestRunner BEFORE PRIVATE ${WebKit_FRAMEWORK_HEADERS_DIR})
endif ()

if (COMPILER_IS_GCC_OR_CLANG)
    WEBKIT_ADD_TARGET_CXX_FLAGS(TestRunnerInjectedBundle -Wno-unused-parameter)
    WEBKIT_ADD_TARGET_CXX_FLAGS(WebKitTestRunner -Wno-unused-parameter)
endif ()
