# WebInspectorUI.framework — the Cocoa build product of Source/WebInspectorUI. Upstream's
# WebInspectorUI.xcodeproj links the empty WebInspectorUI.c into a framework binary, stamps
# Info.plist with com.apple.WebInspectorUI and copies the built frontend into Resources/; the CMake
# build stops at the frontend itself, so this file supplies the bundle around it.
#
# WebKit and WebKitLegacy carry a weak load command for
# /System/Library/PrivateFrameworks/WebInspectorUI.framework/Versions/A/WebInspectorUI, and dyld
# resolves a framework load command against DYLD_FRAMEWORK_PATH before its own path. The test
# harnesses put CMAKE_LIBRARY_OUTPUT_DIRECTORY there (run-layout-tests.sh, run-api-tests.sh), so
# [NSBundle bundleWithIdentifier:@"com.apple.WebInspectorUI"] answers this framework under
# WebKitTestRunner and DumpRenderTree, and Safari, which sets no such variable, keeps the system
# frontend.

add_library(WebInspectorUIFramework SHARED ${WEBINSPECTORUI_DIR}/WebInspectorUI.c)
add_dependencies(WebInspectorUIFramework WebInspectorUI)
set_target_properties(WebInspectorUIFramework PROPERTIES
    OUTPUT_NAME WebInspectorUI
    FRAMEWORK TRUE
    FRAMEWORK_VERSION A
    MACOSX_FRAMEWORK_IDENTIFIER "com.apple.WebInspectorUI"
    MACOSX_FRAMEWORK_SHORT_VERSION_STRING "${MACOSX_FRAMEWORK_BUNDLE_VERSION}"
    MACOSX_FRAMEWORK_BUNDLE_VERSION "${MACOSX_FRAMEWORK_BUNDLE_VERSION}")

set(WebInspectorUI_FRAMEWORK_RESOURCES_DIR
    ${CMAKE_LIBRARY_OUTPUT_DIRECTORY}/WebInspectorUI.framework/Versions/A/Resources)

add_custom_command(
    OUTPUT ${CMAKE_BINARY_DIR}/inspector-framework-resources.stamp
    DEPENDS ${CMAKE_BINARY_DIR}/inspector-resources.stamp WebInspectorUIFramework
    COMMAND ${CMAKE_COMMAND} -E copy_directory ${WebInspectorUI_RESOURCES_DIR}/WebInspectorUI ${WebInspectorUI_FRAMEWORK_RESOURCES_DIR}
    # The frontend asks for localizedStrings.js by bundle-relative name, so the bundle carries it at
    # <lang>.lproj/, where NSBundle's localization lookup answers it, and not in the second copy the
    # CMake build keeps under Localizations/.
    COMMAND ${CMAKE_COMMAND} -E remove_directory ${WebInspectorUI_FRAMEWORK_RESOURCES_DIR}/Localizations
    COMMAND ${CMAKE_COMMAND} -E copy ${WebInspectorUI_LOCALIZED_STRINGS_DIR}/localizedStrings.js ${WebInspectorUI_FRAMEWORK_RESOURCES_DIR}/en.lproj/localizedStrings.js
    COMMAND ${CMAKE_COMMAND} -E touch ${CMAKE_BINARY_DIR}/inspector-framework-resources.stamp
    VERBATIM
)

add_custom_target(
    WebInspectorUIFrameworkResources ALL
    DEPENDS ${CMAKE_BINARY_DIR}/inspector-framework-resources.stamp
)
