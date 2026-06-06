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
# 10.9 backport: ENABLE WOFF2 web fonts. Our modern UA makes servers (Google Fonts, Material
# Icons, etc.) send WOFF2; without a decoder CGFontCreateWithDataProvider fails on the raw bytes
# and icon/web fonts render as empty boxes. Decoder = locally-built libwoff2dec + libbrotli (see
# PlatformMac.cmake). [[project_woff2_enabled]]
WEBKIT_OPTION_DEFAULT_PORT_VALUE(USE_WOFF2 PRIVATE ON)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_APPLICATION_MANIFEST PRIVATE ON)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(USE_SYSTEM_MALLOC PRIVATE ON)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_ASYNC_SCROLLING PRIVATE ON)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_ATTACHMENT_ELEMENT PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_AVF_CAPTIONS PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_CACHE_PARTITIONING PRIVATE ON)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_CONTENT_EXTENSIONS PRIVATE ON)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_CONTENT_FILTERING PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_CURSOR_VISIBILITY PRIVATE ON)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_DARK_MODE_CSS PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_DATACUE_VALUE PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_DRAG_SUPPORT PRIVATE ON)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_ENCRYPTED_MEDIA PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_EXPERIMENTAL_FEATURES PRIVATE ON)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_GAMEPAD PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_GPU_PROCESS PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_INSPECTOR_ALTERNATE_DISPATCHERS PRIVATE ON)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_INSPECTOR_EXTENSIONS PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_INSPECTOR_TELEMETRY PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_LEGACY_CUSTOM_PROTOCOL_MANAGER PRIVATE ON)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_LEGACY_ENCRYPTED_MEDIA PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_MEDIA_SOURCE PRIVATE ON)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_MEDIA_STREAM PRIVATE ON)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_MEMORY_SAMPLER PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_MOUSE_CURSOR_SCALE PRIVATE ON)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_OFFSCREEN_CANVAS PRIVATE ON)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_OFFSCREEN_CANVAS_IN_WORKERS PRIVATE ON)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_PAYMENT_REQUEST PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_PDFKIT_PLUGIN PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_PERIODIC_MEMORY_MONITOR PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_PICTURE_IN_PICTURE_API PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_POINTER_LOCK PRIVATE ON)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_RESOURCE_USAGE PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_SANDBOX_EXTENSIONS PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_SERVICE_CONTROLS PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_SHAREABLE_RESOURCE PRIVATE ON)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_SPEECH_SYNTHESIS PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_TELEPHONE_NUMBER_DETECTION PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_TEXT_AUTOSIZING PRIVATE ON)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_VARIATION_FONTS PRIVATE ON)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_VIDEO_PRESENTATION_MODE PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_WEBDRIVER_KEYBOARD_INTERACTIONS PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_WEBDRIVER_MOUSE_INTERACTIONS PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_WEBDRIVER_WHEEL_INTERACTIONS PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_WEBXR PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_WEB_API_STATISTICS PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_WEB_AUTHN PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_WEB_RTC PRIVATE ON)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_WIRELESS_PLAYBACK_TARGET PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(USE_AVIF PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(USE_JPEGXL PRIVATE OFF)

WEBKIT_OPTION_END()

# USE_LIBWEBRTC follows ENABLE_WEB_RTC: libwebrtc is the WebRTC implementation, so it must be off when
# WebRTC is off (otherwise USE(LIBWEBRTC) code compiles but pulls in WK_RTCVideoDecoder* ObjC classes
# that crash WebContent at load on 10.9). Re-enabling WEB_RTC re-enables libwebrtc for #278.
SET_AND_EXPOSE_TO_BUILD(USE_LIBWEBRTC ${ENABLE_WEB_RTC})
# 10.9 backport: WebCrypto via libgcrypt instead of CommonCrypto/CryptoKit.
# See PlatformMac.cmake for libgcrypt include + link, and SourcesCocoa.txt
# for the crypto/gcrypt/ source replacements.
SET_AND_EXPOSE_TO_BUILD(USE_GCRYPT TRUE)

set(ENABLE_WEBKIT_LEGACY ON)
# WebKit2 RE-ENABLED for Safari drop-in. The user's developer correctly noted
# that WK2 is where Safari's actual rendering/JS/networking lives. Many 10.10+
# APIs need polyfills which we add as we go.
set(ENABLE_WEBKIT ON)

set(bmalloc_LIBRARY_TYPE OBJECT)
set(WTF_LIBRARY_TYPE OBJECT)
set(JavaScriptCore_LIBRARY_TYPE SHARED)
set(PAL_LIBRARY_TYPE OBJECT)
set(WebCore_LIBRARY_TYPE SHARED)

# 10.9 backport: enable ANGLE-backed WebGL. ANGLE uses its CGL OpenGL backend (see
# ThirdParty/ANGLE/PlatformMac.cmake) since Metal is unavailable on 10.9.
set(USE_ANGLE_EGL ON)

find_package(ICU 70.1 REQUIRED COMPONENTS data i18n uc)
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
set(MAVERICKS_DEPS "${MAVERICKS_SUPPORT}/deps" CACHE INTERNAL "in-tree third-party deps")

# 10.9 backport: link libc++ DYNAMICALLY (one shared copy) rather than statically into every
# dylib. Static libc++ per-dylib gives WebCore and JavaScriptCore each their own copy of libc++'s
# locale/iostream global state; destroying a std::stringstream then corrupts across copies and
# crashes WebContent (see task #280). These are the clang-22 toolchain's libc++/libc++abi
# (install_name @rpath/libc++.1.dylib); the postbuild deploys a private copy next to the
# frameworks and points an LC_RPATH at it so the system's old 10.9 libc++ is NOT used.
link_libraries(${MAVERICKS_TC}/lib/libc++.1.dylib)
link_libraries(${MAVERICKS_TC}/lib/libc++abi.1.dylib)
link_libraries(${MAVERICKS_TC}/lib/libMacportsLegacySupport.a)
# libpolyfill.a contains const_polyfill.o (real CFSTR definitions for
# 101 Apple CFString constants previously broken by xorl stubs).
link_libraries(${MAVERICKS_SUPPORT}/prebuilt/libpolyfill.a)
# -nostdlib++ is needed because we use a custom libc++ (clang-22).
# Upstream WebKit applies -undefined dynamic_lookup only to WebCore via its
# target LINK_FLAGS (with -umbrella WebKit), not globally. We follow that pattern.
add_link_options(-nostdlib++)
# Ensure dylibs have proper version info for Safari compatibility
add_link_options("LINKER:-compatibility_version,1.0.0" "LINKER:-current_version,615.1.1")
# Set deployment target so dyld shared cache accepts our frameworks
# 10.9 backport: exclude ASM_NASM (libvpx/libwebrtc .asm via nasm) — nasm rejects -m*/-W*/-iframework.
add_compile_options($<$<NOT:$<COMPILE_LANGUAGE:ASM_NASM>>:-mmacosx-version-min=10.9>)
add_link_options(-mmacosx-version-min=10.9)

# Overlay framework dir for patched headers (lightweight generics on collection types)
add_compile_options($<$<NOT:$<COMPILE_LANGUAGE:ASM_NASM>>:-iframework> $<$<NOT:$<COMPILE_LANGUAGE:ASM_NASM>>:${MAVERICKS_SUPPORT}/sdk-overlay>)

# 10.9 backport: clang-22 enables C++/ObjC modules by default, so __has_feature(modules) is true.
# Many WebKit SPI headers guard their forward declarations with `#if !__has_feature(modules)`,
# expecting the types to come from framework modules instead. But the 10.9 system frameworks lack the
# newer types those declarations cover (CMTag, FigThreadAbortAction, ...), leaving them undeclared.
# Disable implicit modules so the SPI headers fall back to providing the declarations textually.
add_compile_options($<$<NOT:$<COMPILE_LANGUAGE:ASM_NASM>>:-fno-modules> $<$<NOT:$<COMPILE_LANGUAGE:ASM_NASM>>:-fno-cxx-modules>)

# 10.9 backport: libwebrtc's final static archive aggregates ~2000 objects; `ar qc <all .o>`
# exceeds ARG_MAX ("Argument list too long"). With CMAKE_NINJA_FORCE_RESPONSE_FILE=1 (passed on
# the cmake command line) ninja writes objects to a response file and invokes the archiver as
# `<ar> qc <target> @objects.rsp`. Apple's ar/libtool reject @response-files, but llvm-ar accepts
# them -> use llvm-ar. FORCE also wraps yasm's ASM flags in @file (which yasm can't read), so the
# ASM_NASM compiler is a thin wrapper that expands @file before exec'ing yasm. These two `set()`s
# run after project()/enable_language so they override the rule values at generation WITHOUT
# re-triggering compiler detection (which would reset CMAKE_C_COMPILER etc.).
foreach(_lang C CXX OBJC OBJCXX)
    set(CMAKE_${_lang}_CREATE_STATIC_LIBRARY "${MAVERICKS_TC}/bin/llvm-ar qc <TARGET> <OBJECTS>")
endforeach()
