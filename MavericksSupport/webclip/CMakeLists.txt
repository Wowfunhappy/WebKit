# The Web Clip Dashboard widget's plug-in. It hosts each clip in a WKWebView and is a client of the
# frameworks, not part of them: it compiles against the SDK's headers alone, so this directory drops
# every include path, definition and option it inherits from Source/WebKit. The staging script places
# the binary and its page script inside the installed widget's plug-in bundle.
set_directory_properties(PROPERTIES INCLUDE_DIRECTORIES "" COMPILE_DEFINITIONS "" COMPILE_OPTIONS "")

add_library(WebClipPlugin MODULE
    src/WCClipperView.m
    src/WCExtras.m
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
target_link_options(WebClipPlugin PRIVATE "$<TARGET_FILE:WebKit>" "$<TARGET_FILE:WebKitLegacy>" "SHELL:-framework Cocoa" "SHELL:-framework QuartzCore")
add_custom_command(TARGET WebClipPlugin POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "${CMAKE_CURRENT_SOURCE_DIR}/src/WCPageAgent.js" "${CMAKE_BINARY_DIR}/WebClipPlugin/WCPageAgent.js"
    VERBATIM)
