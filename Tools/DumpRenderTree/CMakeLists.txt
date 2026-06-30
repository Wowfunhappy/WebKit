set(DumpRenderTree_DIR "${TOOLS_DIR}/DumpRenderTree")
set(DumpRenderTree_BINDINGS_DIR "${TOOLS_DIR}/DumpRenderTree/Bindings")

file(MAKE_DIRECTORY ${DumpRenderTree_DERIVED_SOURCES_DIR})

set(DumpRenderTree_SOURCES
    AccessibilityController.cpp
    AccessibilityTextMarker.cpp
    AccessibilityUIElement.cpp
    CyclicRedundancyCheck.cpp
    GCController.cpp
    JavaScriptThreading.cpp
    PixelDumpSupport.cpp
    TestOptions.cpp
    TestRunner.cpp
    WorkQueue.cpp
)

set(DumpRenderTree_LIBRARIES
    WebKit::TestRunnerShared
    WebKit::WebCoreTestSupport
)
set(DumpRenderTree_FRAMEWORKS
    JavaScriptCore
    PAL
    WTF
    WebCore
    WebKitLegacy
    bmalloc
)

set(DumpRenderTree_PRIVATE_INCLUDE_DIRECTORIES
    ${CMAKE_BINARY_DIR}
    ${DumpRenderTree_DERIVED_SOURCES_DIR}
    ${DumpRenderTree_DIR}
)

set(DumpRenderTree_WEB_PREFERENCES_TEMPLATES
    ${DumpRenderTree_DIR}/Scripts/PreferencesTemplates/TestOptionsGeneratedWebKitLegacyKeyMapping.cpp.erb
    ${DumpRenderTree_DIR}/Scripts/PreferencesTemplates/TestOptionsGeneratedKeys.h.erb
)

set(DumpRenderTree_WEB_PREFERENCES
    ${WTF_SCRIPTS_DIR}/Preferences/UnifiedWebPreferences.yaml
)

set_source_files_properties(${DumpRenderTree_WEB_PREFERENCES} PROPERTIES GENERATED TRUE)

add_custom_command(
    OUTPUT ${DumpRenderTree_DERIVED_SOURCES_DIR}/TestOptionsGeneratedWebKitLegacyKeyMapping.cpp ${DumpRenderTree_DERIVED_SOURCES_DIR}/TestOptionsGeneratedKeys.h
    DEPENDS ${DumpRenderTree_WEB_PREFERENCES_TEMPLATES} ${DumpRenderTree_WEB_PREFERENCES} WTF_CopyPreferences
    COMMAND ${Ruby_EXECUTABLE} ${WTF_SCRIPTS_DIR}/GeneratePreferences.rb --frontend WebKitLegacy --outputDir "${DumpRenderTree_DERIVED_SOURCES_DIR}" --template ${DumpRenderTree_DIR}/Scripts/PreferencesTemplates/TestOptionsGeneratedWebKitLegacyKeyMapping.cpp.erb --template ${DumpRenderTree_DIR}/Scripts/PreferencesTemplates/TestOptionsGeneratedKeys.h.erb ${DumpRenderTree_WEB_PREFERENCES}
    VERBATIM)

list(APPEND DumpRenderTree_SOURCES
    ${DumpRenderTree_DERIVED_SOURCES_DIR}/TestOptionsGeneratedWebKitLegacyKeyMapping.cpp
    ${DumpRenderTree_DERIVED_SOURCES_DIR}/TestOptionsGeneratedKeys.h
)

WEBKIT_EXECUTABLE_DECLARE(DumpRenderTree)
WEBKIT_INCLUDE_CONFIG_FILES_IF_EXISTS()
WEBKIT_EXECUTABLE(DumpRenderTree)

# MAVERICKS_BACKPORT: DumpRenderTree links both the WebKit2 (WebKit) and WebKit1 (WebKitLegacy) frameworks,
# whose <WebKit/...> umbrellas share a few header names (e.g. WebFeature.h, where WebKit2 ships only a
# forward declaration). The WebKit2 headers root lands first via its interface includes, so force the
# WebKit1 (WebKitLegacy) headers root to be searched before it; WebKit2-only headers still resolve from the
# later entry. (WebKitLegacy_FRAMEWORK_HEADERS_DIR is set globally in WebKitFS.cmake.)
if (TARGET DumpRenderTree)
    target_include_directories(DumpRenderTree BEFORE PRIVATE ${WebKitLegacy_FRAMEWORK_HEADERS_DIR})
endif ()
