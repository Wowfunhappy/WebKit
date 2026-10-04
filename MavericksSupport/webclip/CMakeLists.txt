# The Web Clip Dashboard widget's plug-in. It hosts each clip in a WKWebView and is a client of the
# frameworks, not part of them: it compiles against the SDK's headers alone, so this directory drops
# every include path, definition and option it inherits from Source/WebKit. The staging script places
# the binary and its page script inside the installed widget's plug-in bundle.
set_directory_properties(PROPERTIES INCLUDE_DIRECTORIES "" COMPILE_DEFINITIONS "" COMPILE_OPTIONS "")

add_library(WebClipPlugin MODULE
    src/WCClipperView.m
    src/WCExtras.m
    src/WCSafariStorage.mm
    src/WCSnapper.m
    src/WCTheme.m
    src/WCThemesMore.m
    src/WCViews.m
    src/WebClipper.m)
set_target_properties(WebClipPlugin PROPERTIES
    OUTPUT_NAME WebClip
    PREFIX ""
    SUFFIX ""
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/WebClipPlugin")
target_compile_options(WebClipPlugin PRIVATE -fobjc-arc -Wno-deprecated-declarations -Wno-unguarded-availability-new)
add_dependencies(WebClipPlugin WebKit WebKitLegacy)
target_link_options(WebClipPlugin PRIVATE "$<TARGET_FILE:JavaScriptCore>" "$<TARGET_FILE:WebCore>" "$<TARGET_FILE:WebKit>" "$<TARGET_FILE:WebKitLegacy>" "SHELL:-framework Cocoa" "SHELL:-framework QuartzCore" -lsqlite3)
# The page script is a build output of its own, so that a change to it alone reaches the plug-in.
add_custom_command(OUTPUT "${CMAKE_BINARY_DIR}/WebClipPlugin/WCPageAgent.js"
    COMMAND ${CMAKE_COMMAND} -E copy "${CMAKE_CURRENT_SOURCE_DIR}/src/WCPageAgent.js" "${CMAKE_BINARY_DIR}/WebClipPlugin/WCPageAgent.js"
    DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/src/WCPageAgent.js"
    VERBATIM)
add_custom_target(WebClipPageAgent DEPENDS "${CMAKE_BINARY_DIR}/WebClipPlugin/WCPageAgent.js")
add_dependencies(WebClipPlugin WebClipPageAgent)

# The plug-in's injected bundle runs in each clip's web content process and calls into WebCore, so it
# compiles with the definitions and options the frameworks' sources share and against their headers.
get_directory_property(_webclip_bundle_definitions DIRECTORY "${CMAKE_SOURCE_DIR}" COMPILE_DEFINITIONS)
get_directory_property(_webclip_bundle_options DIRECTORY "${CMAKE_SOURCE_DIR}" COMPILE_OPTIONS)
add_library(WebClipPageBundle MODULE bundle/WCPageBundle.cpp)
set_target_properties(WebClipPageBundle PROPERTIES
    BUNDLE TRUE
    BUNDLE_EXTENSION bundle
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/bundle/Info.plist"
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/WebClipPlugin")
target_compile_definitions(WebClipPageBundle PRIVATE ${_webclip_bundle_definitions})
target_compile_options(WebClipPageBundle PRIVATE ${_webclip_bundle_options})
target_include_directories(WebClipPageBundle PRIVATE
    "${CMAKE_BINARY_DIR}"
    "${bmalloc_FRAMEWORK_HEADERS_DIR}"
    "${WTF_FRAMEWORK_HEADERS_DIR}"
    "${JavaScriptCore_FRAMEWORK_HEADERS_DIR}"
    "${JavaScriptCore_PRIVATE_FRAMEWORK_HEADERS_DIR}"
    "${PAL_FRAMEWORK_HEADERS_DIR}"
    "${WebCore_PRIVATE_FRAMEWORK_HEADERS_DIR}"
    "${WebKit_FRAMEWORK_HEADERS_DIR}"
    "${WebKit_PRIVATE_FRAMEWORK_HEADERS_DIR}"
    ${ICU_INCLUDE_DIRS})
target_include_directories(WebClipPageBundle SYSTEM PRIVATE ${GSTREAMER_INCLUDE_DIRS})

# The plug-in's reader of Safari's website data uses WebCore's storage functions, so it compiles as the
# injected bundle does.
set(_webclip_webcore_include_directories
    "${CMAKE_BINARY_DIR}"
    "${bmalloc_FRAMEWORK_HEADERS_DIR}"
    "${WTF_FRAMEWORK_HEADERS_DIR}"
    "${JavaScriptCore_FRAMEWORK_HEADERS_DIR}"
    "${JavaScriptCore_PRIVATE_FRAMEWORK_HEADERS_DIR}"
    "${PAL_FRAMEWORK_HEADERS_DIR}"
    "${WebCore_PRIVATE_FRAMEWORK_HEADERS_DIR}"
    ${ICU_INCLUDE_DIRS}
    ${GSTREAMER_INCLUDE_DIRS})
# A source file's options take no SHELL: groups, so each group's words go in on their own; a group the
# frameworks keep from Swift sources applies to this Objective-C++ source.
set(_webclip_webcore_options -fno-objc-arc)
foreach (_option IN LISTS _webclip_bundle_options)
    if (_option MATCHES "^\\$<\\$<NOT:\\$<COMPILE_LANGUAGE:Swift>>:SHELL:(.*)>$" OR _option MATCHES "^SHELL:(.*)$")
        separate_arguments(_words UNIX_COMMAND "${CMAKE_MATCH_1}")
        list(APPEND _webclip_webcore_options ${_words})
    else ()
        list(APPEND _webclip_webcore_options "${_option}")
    endif ()
endforeach ()
set_source_files_properties(src/WCSafariStorage.mm PROPERTIES
    COMPILE_DEFINITIONS "${_webclip_bundle_definitions}"
    COMPILE_OPTIONS "${_webclip_webcore_options}"
    INCLUDE_DIRECTORIES "${_webclip_webcore_include_directories}")
add_dependencies(WebClipPageBundle WebKit)
target_link_options(WebClipPageBundle PRIVATE "$<TARGET_FILE:JavaScriptCore>" "$<TARGET_FILE:WebCore>" "$<TARGET_FILE:WebKit>")
add_dependencies(WebClipPlugin WebClipPageBundle)
