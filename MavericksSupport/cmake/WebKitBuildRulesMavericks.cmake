# Target and source rules owned by the Mavericks backport, called from Source/cmake/WebKitMacros.cmake
# so that file's own macros stay byte-upstream.

# generate-unified-source-bundles.rb names every ObjC++ bundle -ARC.mm (and the opted-out ones
# -nonARC.mm), so a bundle by that name compiles with the project-wide ARC the Cocoa build sets in
# Configurations/Base.xcconfig.
macro(_MAVERICKS_SET_ARC_IF_NEEDED _file)
    if (MAVERICKS_SUPPORT AND "${_file}" MATCHES "-ARC\\.mm$")
        set_source_files_properties("${_file}" PROPERTIES COMPILE_FLAGS "-fobjc-arc")
    endif ()
endmacro()

# The polyfill ObjC-class stubs dylib, linked into every WebKit framework. The polyfilled classes have
# absent-on-10.9 SYSTEM names (UTType, NSScrollingPredominantAxisFilter, CABackdropLayer, SecKeyProxy,
# ...) that the build SDK declares in system frameworks (AppKit/QuartzCore/Foundation/Security/
# CFNetwork/CoreServices); under the two-level namespace a reference binds to whichever provider the
# linker resolves it against. Linking the dylib here covers the classes the linker resolves against IT
# -- those owned by frameworks it reaches after it -- which then bind to this ONE shared definition (no
# "Class X is implemented in both ..." warning, no "Symbol not found" crash). It only ever wins for the
# absent classes it defines; real 10.9 classes (NSColor, NSView, ...) are not in it and still bind to
# their system framework. Link-line ordering is not controllable enough to beat EVERY system framework,
# so classes owned by frameworks linked earlier (Security -> SecKeyProxy; CFNetwork ->
# _NSHTTPAlternativeServices*/_NSHSTSStorage; CoreServices -> LSBundleProxy; QuartzCore in some
# binaries) are resolved at staging time instead: libpolyfill_classes.dylib reexports those four
# frameworks and MavericksSupport/scripts/stage-frameworks.sh repoints each binary's dependency on them
# to it (rewrite_abs_deps).
macro(_MAVERICKS_LINK_POLYFILL_CLASSES _target)
    if (MAVERICKS_SUPPORT)
        target_link_libraries(${_target} PRIVATE
            ${MAVERICKS_SUPPORT}/polyfill/build/libpolyfill_classes.dylib)
    endif ()
endmacro()

# What every target this build creates gets from the port. The three XPC process executables are the
# only SHIPPED binaries WEBKIT_EXECUTABLE produces, so they are named here rather than force-loading
# the polyfill from that macro -- which also builds the build-time tools, where dragging the whole
# archive in would only add link-line requirements for polyfills they never call.
# The test drivers need it for a different reason: they are standalone images that call the layer's
# gap-fills directly (DumpRenderTree reaches UTTypeIsDynamic, TestWebKitAPI reaches
# SecKeyCreateWithData), and an ordinary archive link never pulls those -- they are compiled
# -fvisibility=hidden, so they do not satisfy a reference from another object. The reference then binds
# to the SDK's stub for a symbol this OS does not have, and the process dies at first use.
macro(_MAVERICKS_APPLY_TARGET_POLICY _target)
    _MAVERICKS_LINK_POLYFILL_CLASSES(${_target})
    foreach (_mavShipped WebProcess NetworkProcess GPUProcess
                         DumpRenderTree WebKitTestRunner TestRunnerInjectedBundle
                         TestWTF TestWebCore TestWebKit TestWebKitLegacy)
        if ("${_target}" STREQUAL "${_mavShipped}")
            _WEBKIT_FORCE_LOAD_POLYFILL(${_target})
        endif ()
    endforeach ()
    # The test images additionally carry their own calls to selectors 10.9 lacks (Challenge.mm sends
    # -[NSKeyedArchiver initRequiringSecureCoding:]). WK_POLYFILL_ADD_METHODS installs those under a
    # renamed selector and the patcher rewrites the call sites only in marked images, so an unmarked
    # image sends the original name to a class that does not implement it.
    foreach (_mavTestImage DumpRenderTree WebKitTestRunner TestRunnerInjectedBundle
                           TestWTF TestWebCore TestWebKit TestWebKitLegacy)
        if ("${_target}" STREQUAL "${_mavTestImage}")
            _WEBKIT_FORCE_LOAD_WK_MARKER(${_target})
        endif ()
    endforeach ()
endmacro()

# CMake's default Info.plist leaves CFBundleIdentifier empty; stamp the canonical identifier that
# CFBundleGetBundleWithIdentifier resolves for WebCore::copyLocalizedString.
macro(_MAVERICKS_SET_FRAMEWORK_IDENTIFIER _target)
    if (MAVERICKS_SUPPORT)
        set_target_properties(${_target} PROPERTIES
            MACOSX_FRAMEWORK_IDENTIFIER "com.apple.${_target}")
    endif ()
endmacro()

# Force-load libpolyfill.a into a shipped binary.
#
# The polyfill layer replaces symbols 10.9 has as well as adding ones it lacks, so which definition
# wins has to be decided by us rather than by the linker. Linked as an ordinary archive (what
# OptionsMac.cmake does for build-time tools) a member is pulled only if it resolves a still-undefined
# symbol at the point the archive is reached, so the winner depends on where the archive sits relative
# to the SDK stub that also defines the symbol, and on whether an unrelated symbol in the same object
# happens to drag the member in. Both move under edits that have nothing to do with the polyfill.
# Force-loading makes every member part of the image, and an image binds its own references to its own
# definitions in preference to importing from a dylib -- regardless of link order and of weak imports.
#
# Applied to everything this port SHIPS: the four frameworks, libwebrtc, and the three XPC process
# executables (which are thin entry-point shims, but AuxiliaryProcessMain and the crash/sandbox setup
# around it run before the framework is entered). NOT applied via WEBKIT_EXECUTABLE, which also builds
# the build-time tools: force-loading the whole archive into a tool means every library any polyfill
# references has to be on that tool's link line, for polyfills it will never call.
#
# A shipped binary has to link what the archive's members reference, since force_load makes every
# member part of the image whether or not that image calls it. The frameworks link these already; the
# executables link almost nothing on their own, so name them here. The list is exactly what
# libpolyfill.a leaves undefined: CoreGraphics and CoreText for the graphics gap-fills, Security for
# the trust-evaluation ones, CoreFoundation for CF types and the ObjC runtime it reexports.
# libwtf_compat.a is JavaScriptCore's alone: it defines the WTF C++ API of Safari 7's era (currentTime,
# monotonicallyIncreasingTime, the threadID-based thread calls, callOnMainThread, ...), which Safari binds
# out of JavaScriptCore. The method polyfills (libpolyfill_methods.a) go to WebCore instead, so a
# dyld-restricted setuid program that loads only JSC -- the macOS Installer's privileged `runner`, which
# loads JavaScriptCore via Install.framework/DistributionKit to run Distribution scripts -- starts without
# tripping AppKit's "running setugid(), which is not allowed" abort.
macro(_WEBKIT_FORCE_LOAD_POLYFILL _target)
    if (MAVERICKS_SUPPORT)
        if ("${_target}" STREQUAL "JavaScriptCore")
            target_link_options(${_target} PRIVATE
                "-Wl,-force_load,${MAVERICKS_SUPPORT}/polyfill/build/libwtf_compat.a")
            set_property(TARGET ${_target} APPEND PROPERTY LINK_DEPENDS
                "${MAVERICKS_SUPPORT}/polyfill/build/libwtf_compat.a")
        endif ()
        target_link_options(${_target} PRIVATE
            "-Wl,-force_load,${MAVERICKS_SUPPORT}/polyfill/build/libpolyfill.a")
        # Make it a real link input, so regenerating the archive (build-polyfill.sh) relinks.
        set_property(TARGET ${_target} APPEND PROPERTY LINK_DEPENDS
            "${MAVERICKS_SUPPORT}/polyfill/build/libpolyfill.a")
        # The libcompression polyfill (polyfills/compression.c) codes Brotli through the vendored
        # codec, so every force-load consumer needs the brotli archives (plain, not force-loaded).
        target_link_libraries(${_target} PRIVATE
            "${MAVERICKS_DEPS}/lib/libbrotlienc.a"
            "${MAVERICKS_DEPS}/lib/libbrotlidec.a"
            "${MAVERICKS_DEPS}/lib/libbrotlicommon.a")
        get_target_property(_wkPolyfillTargetType ${_target} TYPE)
        if (_wkPolyfillTargetType STREQUAL "EXECUTABLE")
            target_link_libraries(${_target} PRIVATE
                "-framework CoreFoundation" "-framework CoreGraphics"
                "-framework CoreText" "-framework Security")
        endif ()
    endif ()
endmacro()

# Tag an image with __DATA,__wk_marker (libwk_marker.a). The selref patcher (wk_selref_scope.o,
# force-loaded into WebCore) rewrites __objc_selrefs only in marked images, so the method polyfills
# (WK_POLYFILL_ADD_METHODS) are scoped to WebKit's own binaries -- a host app embedding WebKit is never
# patched and never sees the modern public selectors. Pure data (no initializer), so it is safe even in
# frameworks like JavaScriptCore.
macro(_WEBKIT_FORCE_LOAD_WK_MARKER _target)
    if (MAVERICKS_SUPPORT)
        target_link_options(${_target} PRIVATE
            "-Wl,-force_load,${MAVERICKS_SUPPORT}/polyfill/build/libwk_marker.a")
        set_property(TARGET ${_target} APPEND PROPERTY LINK_DEPENDS
            "${MAVERICKS_SUPPORT}/polyfill/build/libwk_marker.a")
    endif ()
endmacro()

# libwebrtc is a dylib on Cocoa, weak-linked by the two frameworks whose code calls into it
# (Configurations/libwebrtc.xcconfig; WebCore.xcconfig and WebKit.xcconfig each pass -weak-lwebrtc).
macro(_MAVERICKS_LINK_LIBWEBRTC _target)
    if (USE_LIBWEBRTC)
        target_link_options(${_target} PRIVATE "SHELL:-weak_library $<TARGET_FILE:webrtc>")
        add_dependencies(${_target} webrtc)
        set_property(TARGET ${_target} APPEND PROPERTY LINK_DEPENDS "$<TARGET_FILE:webrtc>")
    endif ()
endmacro()
