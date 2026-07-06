# FIXME: These should line up with versions in Configurations/Version.xcconfig.
# See Source/WebKitLegacy/PlatformWin.cmake for how WebKitVersion.h is generated.
set(WEBKIT_MAC_VERSION 615.1.1)
set(MACOSX_FRAMEWORK_BUNDLE_VERSION 615.1.1+)

WEBKIT_OPTION_BEGIN()
# Private options shared with other WebKit ports. Add options here only if
# we need a value different from the default defined in WebKitFeatures.cmake.

# FIXME: https://bugs.webkit.org/show_bug.cgi?id=231776
# WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_API_TESTS PRIVATE ON)

WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_APPLE_PAY PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(USE_LCMS PRIVATE OFF)
# MAVERICKS_BACKPORT: ENABLE WOFF2 web fonts. Our modern UA makes servers (Google Fonts, Material
# Icons, etc.) send WOFF2; without a decoder CGFontCreateWithDataProvider fails on the raw bytes
# and icon/web fonts render as empty boxes. Decoder = locally-built libwoff2dec + libbrotli (see
# PlatformMac.cmake). [[project_woff2_enabled]]
WEBKIT_OPTION_DEFAULT_PORT_VALUE(USE_WOFF2 PRIVATE ON)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_APPLICATION_MANIFEST PRIVATE ON)
# MAVERICKS_BACKPORT: ON — use the system malloc instead of bmalloc to avoid bmalloc's reliance on newer VM/madvise behavior on 10.9.
WEBKIT_OPTION_DEFAULT_PORT_VALUE(USE_SYSTEM_MALLOC PRIVATE ON)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_ASYNC_SCROLLING PRIVATE ON)
# MAVERICKS_BACKPORT: OFF — <attachment> element depends on newer NSTextAttachment/QuickLookThumbnailing SPI absent on 10.9.
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_ATTACHMENT_ELEMENT PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_AVF_CAPTIONS PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_CACHE_PARTITIONING PRIVATE ON)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_CONTENT_EXTENSIONS PRIVATE ON)
# MAVERICKS_BACKPORT: OFF — parental-controls content filtering uses the 10.9-absent WebFilterEvaluator/NEFilter SPI.
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_CONTENT_FILTERING PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_CURSOR_VISIBILITY PRIVATE ON)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_DARK_MODE_CSS PRIVATE ON)
# MAVERICKS_BACKPORT: ON — 10.9 Dashboard widgets need -apple-dashboard-region control regions
# (subsystem removed upstream in 2d364c6; restored for the backport).
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_DASHBOARD_SUPPORT PRIVATE ON)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_DATACUE_VALUE PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_DRAG_SUPPORT PRIVATE ON)
# MAVERICKS_BACKPORT: OFF — Encrypted Media Extensions (CDM/AVContentKeySession) is unavailable on 10.9.
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_ENCRYPTED_MEDIA PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_EXPERIMENTAL_FEATURES PRIVATE ON)
# MAVERICKS_BACKPORT: OFF — Gamepad uses the 10.9-absent GameController framework / newer IOKit HID SPI.
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_GAMEPAD PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_GPU_PROCESS PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_INSPECTOR_ALTERNATE_DISPATCHERS PRIVATE ON)
# MAVERICKS_BACKPORT: OFF — Web Inspector extensions are not part of the 10.9 drop-in scope.
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_INSPECTOR_EXTENSIONS PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_INSPECTOR_TELEMETRY PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_LEGACY_CUSTOM_PROTOCOL_MANAGER PRIVATE ON)
# MAVERICKS_BACKPORT: OFF — EME/CDM (AVContentKeySession etc.) is unavailable on 10.9.
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_LEGACY_ENCRYPTED_MEDIA PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_MEDIA_SOURCE PRIVATE ON)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_MEDIA_STREAM PRIVATE ON)
# MAVERICKS_BACKPORT: OFF — memory sampler uses newer task-introspection SPI absent on 10.9; not needed for the drop-in.
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_MEMORY_SAMPLER PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_MOUSE_CURSOR_SCALE PRIVATE ON)
# MAVERICKS_BACKPORT: ON — enable OffscreenCanvas (incl. in workers) for modern sites; backed by the ANGLE/CG canvas path.
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_OFFSCREEN_CANVAS PRIVATE ON)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_OFFSCREEN_CANVAS_IN_WORKERS PRIVATE ON)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_PAYMENT_REQUEST PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_PDFKIT_PLUGIN PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_PERIODIC_MEMORY_MONITOR PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_PICTURE_IN_PICTURE_API PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_POINTER_LOCK PRIVATE ON)
# MAVERICKS_BACKPORT: OFF — resource-usage overlay relies on newer task/memory introspection SPI not present on 10.9.
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_RESOURCE_USAGE PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_SANDBOX_EXTENSIONS PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_SERVICE_CONTROLS PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_SHAREABLE_RESOURCE PRIVATE ON)
# MAVERICKS_BACKPORT: Web Speech API synthesis, backed by a 10.9 NSSpeechSynthesizer
# polyfill of AVSpeechSynthesizer (SpeechSynthesisAVFoundationPolyfill_109.mm).
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_SPEECH_SYNTHESIS PRIVATE ON)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_TELEPHONE_NUMBER_DETECTION PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_TEXT_AUTOSIZING PRIVATE ON)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_VARIATION_FONTS PRIVATE ON)
# MAVERICKS_BACKPORT: OFF — fullscreen/PiP video presentation needs 10.10+ AVKit/fullscreen SPI absent on 10.9.
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_VIDEO_PRESENTATION_MODE PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_WEBDRIVER_KEYBOARD_INTERACTIONS PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_WEBDRIVER_MOUSE_INTERACTIONS PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_WEBDRIVER_WHEEL_INTERACTIONS PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_WEBXR PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_WEB_API_STATISTICS PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_WEB_AUTHN PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_WEB_RTC PRIVATE ON)
# MAVERICKS_BACKPORT: OFF — AirPlay wireless-playback-target routing depends on 10.10+ AVFoundation/MediaToolbox SPI absent on 10.9.
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_WIRELESS_PLAYBACK_TARGET PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(USE_AVIF PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(USE_JPEGXL PRIVATE OFF)

WEBKIT_OPTION_END()

# MAVERICKS_BACKPORT: WebRTC runs on the GStreamer webrtcbin backend, NOT libwebrtc. USE_GSTREAMER_WEBRTC
# is set TRUE in OptionsMacGStreamer.cmake (included below) and PeerConnectionBackend selects the
# GStreamer backend. The two backends are mutually exclusive — each defines the same
# PeerConnectionBackend::create factory and a WebRTCProvider, so building both is a duplicate-symbol
# link error. libwebrtc is therefore OFF: this also skips the entire ThirdParty/libwebrtc build
# (Source/CMakeLists.txt gates it on USE_LIBWEBRTC) and the WK_RTCVideoDecoder* ObjC classes (10.10+
# VideoToolbox SPI that crash WebContent at load on 10.9). ENABLE_WEB_RTC stays ON.
SET_AND_EXPOSE_TO_BUILD(USE_LIBWEBRTC OFF)
# MAVERICKS_BACKPORT: WebCrypto via libgcrypt instead of CommonCrypto/CryptoKit.
# See PlatformMac.cmake for libgcrypt include + link, and SourcesCocoa.txt
# for the crypto/gcrypt/ source replacements.
SET_AND_EXPOSE_TO_BUILD(USE_GCRYPT TRUE)

# MAVERICKS_BACKPORT: HTML5 <video>/<audio> via the upstream GStreamer media player instead of the
# custom AVAssetReader pump (AVPlayer is dead on 10.9). GStreamer is vendored at
# MavericksSupport/deps/gstreamer (prebuilt 1.20.7, runs on 10.9 with a small symbol polyfill). Use the
# software/appsink path: GL + TextureMapper + CoordinatedGraphics OFF; decoded frames reach CG via
# ImageGStreamerCG.cpp. OptionsMacGStreamer.cmake defines the GLib::* targets + GSTREAMER_* vars from
# the vendored tree (no pkg-config on this toolchain).
SET_AND_EXPOSE_TO_BUILD(USE_GSTREAMER TRUE)
# GStreamer integration needs WTF's GLib helper layer (GRefPtr/GUniquePtr/GSpanExtras/WTFGType, all
# #if USE(GLIB)). Only the helper headers/sources are added on Mac (see WTF/wtf/PlatformMac.cmake) —
# NOT the GLib platform replacements (RunLoopGLib/FileSystemGlib/URLGLib), which would collide with the
# Cocoa run loop / file system. USE(GLIB) is referenced by exactly one Cocoa-built WTF file otherwise.
SET_AND_EXPOSE_TO_BUILD(USE_GLIB TRUE)
SET_AND_EXPOSE_TO_BUILD(USE_GSTREAMER_GL FALSE)
SET_AND_EXPOSE_TO_BUILD(USE_TEXTURE_MAPPER FALSE)
SET_AND_EXPOSE_TO_BUILD(USE_COORDINATED_GRAPHICS FALSE)
include(OptionsMacGStreamer)

set(ENABLE_WEBKIT_LEGACY ON)
# MAVERICKS_BACKPORT: WebKit2 RE-ENABLED for Safari drop-in. The user's developer correctly noted
# that WK2 is where Safari's actual rendering/JS/networking lives. Many 10.10+
# APIs need polyfills which we add as we go.
set(ENABLE_WEBKIT ON)

set(bmalloc_LIBRARY_TYPE OBJECT)
set(WTF_LIBRARY_TYPE OBJECT)
set(JavaScriptCore_LIBRARY_TYPE SHARED)
set(PAL_LIBRARY_TYPE OBJECT)
set(WebCore_LIBRARY_TYPE SHARED)

# MAVERICKS_BACKPORT: enable ANGLE-backed WebGL. ANGLE uses its CGL OpenGL backend (see
# ThirdParty/ANGLE/PlatformMac.cmake) since Metal is unavailable on 10.9.
set(USE_ANGLE_EGL ON)

find_package(ICU 70.1 REQUIRED COMPONENTS data i18n uc)
# MAVERICKS_BACKPORT: link the vendored libxml2 2.13 (already shipped for GStreamer,
# @rpath install name, 10.9-massaged via libsystem_compat) instead of the SDK tbd.
# The SDK tbd binds /usr/lib/libxml2.2.dylib, which on 10.9 is libxml2 2.9.0 — its
# __xmlRaiseError crashes on fatal parse errors from SVG/XML payloads (the bug the
# retired safeXmlParseChunk SIGSEGV guard papered over), and its runtime behavior
# diverges from the 2.9.13 SDK headers WebCore compiles against. Headers and dylib
# now match. libxslt stays on the system copy (no vendored build): it keeps using the
# system libxml 2.9.0 internally, which is safe across the boundary — libxml2 keeps
# xmlDoc/xmlNode struct ABI stable across 2.x, and WebCore intercepts libxslt's
# document loading at the libxslt layer (xsltSetLoaderFunc), so no uncontrolled 2.9
# parsing happens. Align libxslt if/when the deps move to a from-source build.
set(LIBXML2_INCLUDE_DIR "${CMAKE_SOURCE_DIR}/MavericksSupport/deps/gstreamer/include/libxml2" CACHE PATH "" FORCE)
set(LIBXML2_LIBRARY "${CMAKE_SOURCE_DIR}/MavericksSupport/deps/gstreamer/lib/libxml2.2.dylib" CACHE FILEPATH "" FORCE)
find_package(LibXml2 2.8.0 REQUIRED)
find_package(LibXslt 1.1.13 REQUIRED)

# Polyfill libraries for macOS 10.9
#
# Build-environment locations. Rather than hardcode an absolute toolchain path
# (which broke when the VM was reorganized), derive the clang-22 toolchain root
# from the compiler in use, and reference the in-tree MavericksSupport artifacts
# relative to the source tree so a fresh checkout + toolchain just works.
get_filename_component(MAVERICKS_TC "${CMAKE_CXX_COMPILER}" DIRECTORY)   # .../clang-22/bin
get_filename_component(MAVERICKS_TC "${MAVERICKS_TC}" DIRECTORY)         # .../clang-22
set(MAVERICKS_TC "${MAVERICKS_TC}" CACHE INTERNAL "clang-22 toolchain root")
set(MAVERICKS_SUPPORT "${CMAKE_SOURCE_DIR}/MavericksSupport" CACHE INTERNAL "MavericksSupport dir")
set(MAVERICKS_DEPS "${MAVERICKS_SUPPORT}/deps/build" CACHE INTERNAL "third-party libraries built by deps/build_deps.sh")

# MAVERICKS_BACKPORT: link libc++ DYNAMICALLY (one shared copy) rather than statically into every
# dylib. Static libc++ per-dylib gives WebCore and JavaScriptCore each their own copy of libc++'s
# locale/iostream global state; destroying a std::stringstream then corrupts across copies and
# crashes WebContent (see task #280). These are the clang-22 toolchain's libc++/libc++abi
# (install_name @rpath/libc++.1.dylib); the postbuild deploys a private copy next to the
# frameworks and points an LC_RPATH at it so the system's old 10.9 libc++ is NOT used.
link_libraries(${MAVERICKS_TC}/lib/libc++.1.dylib)
link_libraries(${MAVERICKS_TC}/lib/libc++abi.1.dylib)
# libpolyfill.a supplies every symbol WebKit references that the 10.9 runtime lacks:
# the POSIX/libc base plus the WebKit-specific framework-SPI stubs. Linked into every
# binary.
link_libraries(${MAVERICKS_SUPPORT}/polyfill/build/libpolyfill.a)
# libpolyfill_classes.dylib (the polyfill ObjC class stubs) is NOT link_libraries'd here: it is linked
# per-framework in WEBKIT_FRAMEWORK (WebKitMacros.cmake) so it covers the framework targets without also
# being dragged into build tools, and the classes its owning framework is linked earlier than are handled by
# the reexport+repoint in install-safari7.sh (see the WEBKIT_FRAMEWORK note).
# QuartzCore's CALayer is the superclass of the CABackdropLayer stub; linking it everywhere (it is a 10.9
# system framework) is harmless and also covers any binary that uses CALayer directly.
link_libraries("-framework QuartzCore")

# MAVERICKS_BACKPORT: the Apple Mac port builds the layout-test tools (ImageDiff) via Xcode upstream, so
# the CMake path never defines the Apple::<framework> imported targets that Tools/ImageDiff references.
# Provide them as INTERFACE targets that link the system frameworks via -framework, so ENABLE_LAYOUT_TESTS
# can configure on the Mac CMake port. Defining unused imported targets is harmless to the framework build.
foreach (_appleFramework CoreFoundation CoreGraphics CoreText ImageIO)
    if (NOT TARGET Apple::${_appleFramework})
        add_library(Apple::${_appleFramework} INTERFACE IMPORTED GLOBAL)
        set_target_properties(Apple::${_appleFramework} PROPERTIES
            INTERFACE_LINK_LIBRARIES "-framework ${_appleFramework}")
    endif ()
endforeach ()

# MAVERICKS_BACKPORT: with DEVELOPER_MODE, bmalloc builds its mbmalloc microbenchmark dylib, which links
# Threads::Threads. The other CMake ports (GTK/WPE/JSCOnly/PlayStation) call find_package(Threads); the Mac
# port did not because the framework build links pthread implicitly. Provide the imported target so the
# DEVELOPER_MODE tooling configures (on Darwin this resolves to the C library's built-in pthreads).
find_package(Threads)
# -nostdlib++ is needed because we use a custom libc++ (clang-22).
# Upstream WebKit applies -undefined dynamic_lookup only to WebCore via its
# target LINK_FLAGS (with -umbrella WebKit), not globally. We follow that pattern.
add_link_options(-nostdlib++)
# Ensure dylibs have proper version info for Safari compatibility
# Apply the dylib version stamps only to non-executables: -compatibility_version
# and -current_version are "only valid with -dylib", so passing them to build-tool
# executables (LLIntSettingsExtractor, etc.) fails the link.
add_link_options(
  "$<$<NOT:$<STREQUAL:$<TARGET_PROPERTY:TYPE>,EXECUTABLE>>:LINKER:-compatibility_version,1.0.0>"
  "$<$<NOT:$<STREQUAL:$<TARGET_PROPERTY:TYPE>,EXECUTABLE>>:LINKER:-current_version,615.1.1>")
# Set deployment target so dyld shared cache accepts our frameworks
# MAVERICKS_BACKPORT: exclude ASM_NASM (libvpx/libwebrtc .asm via nasm) — nasm rejects -m*/-W*/-iframework.
add_compile_options($<$<NOT:$<COMPILE_LANGUAGE:ASM_NASM>>:-mmacosx-version-min=10.9>)
add_link_options(-mmacosx-version-min=10.9)

# MAVERICKS_BACKPORT: skip clang.cfg for ASM-language (.S) sources so its link flags
# (-lobjc/-framework) are not parsed as assembler input. ASM_NASM uses nasm, not
# clang, so it is excluded.
add_compile_options($<$<COMPILE_LANGUAGE:ASM>:--no-default-config>)

# MAVERICKS_BACKPORT: the modern SDK's availability annotations flag every post-10.9 API
# WebKit calls against the 10.9 deployment target. WebKit handles 10.9 via weak
# linking plus targeted runtime guards rather than @available everywhere, so silence
# the availability/deprecation diagnostics (nasm rejects -W*).
add_compile_options(
  $<$<NOT:$<COMPILE_LANGUAGE:ASM_NASM>>:-Wno-unguarded-availability-new>
  $<$<NOT:$<COMPILE_LANGUAGE:ASM_NASM>>:-Wno-unguarded-availability>
  $<$<NOT:$<COMPILE_LANGUAGE:ASM_NASM>>:-Wno-deprecated-declarations>
  $<$<NOT:$<COMPILE_LANGUAGE:ASM_NASM>>:-Wno-availability>)

# MAVERICKS_BACKPORT: libc++ marks parts of the standard library (std::filesystem from
# 10.15, the std::any/optional/variant bad-access throwers and aligned operator new
# from 10.14, ...) unavailable below those versions, because those symbols entered the
# SYSTEM libc++ dylib then. This build ships the clang-22 libc++ privately (install_name
# @rpath/libc++.1.dylib, deployed beside the frameworks) and forces its use, so those
# symbols are always present regardless of the OS libc++. Disable the vendor
# availability markup so the standard library is usable against the 10.9 target.
add_compile_options($<$<NOT:$<COMPILE_LANGUAGE:ASM_NASM>>:-D_LIBCPP_DISABLE_AVAILABILITY>)

# MAVERICKS_BACKPORT: gap-fill header overlay, searched AFTER the real SDK (-idirafter) so
# the SDK's header always wins where present and only genuinely-missing headers fall
# through. With a modern SDK the Apple headers come from the SDK; the overlay mainly
# covers third-party gaps (e.g. libwebrtc's opus_defines.h).
add_compile_options($<$<NOT:$<COMPILE_LANGUAGE:ASM_NASM>>:-idirafter> $<$<NOT:$<COMPILE_LANGUAGE:ASM_NASM>>:${MAVERICKS_SUPPORT}/polyfill/headers>)

# MAVERICKS_BACKPORT: clang-22 enables C++/ObjC modules by default, so __has_feature(modules) is true.
# Many WebKit SPI headers guard their forward declarations with `#if !__has_feature(modules)`,
# expecting the types to come from framework modules instead. But the 10.9 system frameworks lack the
# newer types those declarations cover (CMTag, FigThreadAbortAction, ...), leaving them undeclared.
# Disable implicit modules so the SPI headers fall back to providing the declarations textually.
add_compile_options($<$<NOT:$<COMPILE_LANGUAGE:ASM_NASM>>:-fno-modules> $<$<NOT:$<COMPILE_LANGUAGE:ASM_NASM>>:-fno-cxx-modules>)

# MAVERICKS_BACKPORT: WebCrypto runs on libgcrypt (USE_GCRYPT), not the Swift CryptoKit path.
# CryptoKey*/CryptoAlgorithm* gate the Swift bridge (PALSwift-Generated.h, generated only by
# Apple's internal Swift build) on `#if !defined(CLANG_WEBKIT_BRANCH)`. Define it so the Swift
# path is skipped and the gcrypt/CommonCrypto fallbacks compile. Value is unused (only its
# definedness is tested). nasm has no preprocessor C macros, so exclude ASM_NASM.
add_compile_options($<$<NOT:$<COMPILE_LANGUAGE:ASM_NASM>>:-DCLANG_WEBKIT_BRANCH=0>)

# MAVERICKS_BACKPORT: libwebrtc's final static archive aggregates ~2000 objects; `ar qc <all .o>`
# exceeds ARG_MAX ("Argument list too long"). With CMAKE_NINJA_FORCE_RESPONSE_FILE=1 (passed on
# the cmake command line) ninja writes objects to a response file and invokes the archiver as
# `<ar> qc <target> @objects.rsp`. Apple's ar/libtool reject @response-files, but llvm-ar accepts
# them -> use llvm-ar. FORCE also wraps yasm's ASM flags in @file (which yasm can't read), so the
# ASM_NASM compiler is a thin wrapper that expands @file before exec'ing yasm. These two `set()`s
# run after project()/enable_language so they override the rule values at generation WITHOUT
# re-triggering compiler detection (which would reset CMAKE_C_COMPILER etc.).
# CRITICAL: `ar qc` is *quick-append* (q) — it APPENDS objects to an existing archive rather than
# recreating it, so each rebuild re-adds every member (observed 4176 members vs 2053 unique). A
# force_load consumer (WebCore) then hits "duplicate symbol" link errors. Ninja never caught this for
# WebCore because the force_load is a raw -Wl flag it doesn't track as a dependency edge. Fix: delete
# <TARGET> before archiving so `qc` always writes a fresh archive. (CREATE_STATIC_LIBRARY runs as a
# list of command lines; the <OBJECTS>/@response-file substitution only applies to the llvm-ar line.)
foreach(_lang C CXX OBJC OBJCXX)
    set(CMAKE_${_lang}_CREATE_STATIC_LIBRARY
        "${CMAKE_COMMAND} -E rm -f <TARGET>"
        "${MAVERICKS_TC}/bin/llvm-ar qc <TARGET> <OBJECTS>")
endforeach()
