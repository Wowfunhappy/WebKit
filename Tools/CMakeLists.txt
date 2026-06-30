set_property(DIRECTORY . PROPERTY FOLDER "Tools")

set(TestRunnerShared_LIBRARY_TYPE OBJECT)

# MAVERICKS_BACKPORT: the Apple Mac port builds DumpRenderTree/WebKitTestRunner via Xcode upstream, so the
# CMake path never defines WebKitTestRunner_SHARED_DIR — yet both drivers' PlatformMac.cmake reference it
# (it is where the shared cocoa/ sources such as ClassMethodSwizzler.mm live). Define it here, before the
# subdirectories are added, so DumpRenderTree (added before WebKitTestRunner) also sees it.
set(WebKitTestRunner_SHARED_DIR "${TOOLS_DIR}/TestRunnerShared")

# Individual subdirectories are added in the port's cmake file
WEBKIT_INCLUDE_CONFIG_FILES_IF_EXISTS()

if (ENABLE_LAYOUT_TESTS)
    add_subdirectory(TestRunnerShared)

    if (ENABLE_IMAGE_DIFF)
        add_subdirectory(ImageDiff)
    endif ()

    if (ENABLE_WEBKIT_LEGACY)
        add_subdirectory(DumpRenderTree)
    endif ()

    if (ENABLE_WEBKIT)
        add_subdirectory(WebKitTestRunner)
    endif ()
endif ()

if (ENABLE_API_TESTS)
    add_subdirectory(TestWebKitAPI)
endif ()
