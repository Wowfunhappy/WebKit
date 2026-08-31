# Every backport change to the Mac port's CMake configuration.
#
# Source/cmake/OptionsMac.cmake is kept BYTE-UPSTREAM and includes this file twice: once just before
# WEBKIT_OPTION_END() for the feature values, and once at the end for everything else. See
# MavericksSupport/cmake/WebCorePlatformMavericks.cmake for the rationale. WEBKIT_OPTION_DEFAULT_PORT_VALUE
# is a plain set() (WebKitFeatures.cmake), so a later call inside BEGIN/END overrides upstream's earlier one.

if (NOT DEFINED MAVERICKS_OPTIONS_PHASE)
    message(FATAL_ERROR "OptionsMacMavericks.cmake needs MAVERICKS_OPTIONS_PHASE set to OPTIONS or POST.")
endif ()

if (MAVERICKS_OPTIONS_PHASE STREQUAL "OPTIONS")

# the third-party libraries this port links that 10.9 does not supply — ICU,
# libgcrypt/libtasn1/libgpg-error, brotli, woff2, libwebp, libxml2, and the whole GStreamer media
# runtime. MavericksSupport/deps/build_deps.sh builds them all from source with the in-tree
# toolchain into deps/build/{include,lib,bin}; MavericksSupport/bootstrap.sh runs it. Every
# reference resolves through MAVERICKS_DEPS, so the artifact tree has exactly one location. Defined in
# the OPTIONS phase: WebKitFindPackage.cmake's ICU lookup (find_package in OptionsMac.cmake) reads it
# before the POST phase runs.
set(MAVERICKS_SUPPORT "${CMAKE_SOURCE_DIR}/MavericksSupport" CACHE INTERNAL "MavericksSupport dir")
set(MAVERICKS_DEPS "${MAVERICKS_SUPPORT}/deps/build" CACHE INTERNAL "third-party libraries built by deps/build_deps.sh")
if (NOT EXISTS "${MAVERICKS_DEPS}/lib/libgcrypt.a")
    message(FATAL_ERROR
        "${MAVERICKS_DEPS} holds no built dependencies.\n"
        "Run MavericksSupport/bootstrap.sh (or MavericksSupport/deps/build_deps.sh) first.")
endif ()

# ICU. The system libicucore is ICU 51 and lacks the modern Intl symbols JSC needs (ucfpos_*,
# udtitvfmt_*, ureldatefmt_*, ulistfmt_*, ...), so this port links the ICU 74.2 static libraries
# deps/build_deps.sh builds -- matching the 74.2 headers WebKitFindPackage.cmake stages. Answering the
# three cache entries here is what makes its `find_library(ICU_*_LIBRARY icucore)` calls no-ops:
# find_library leaves an already-answered result alone.
set(ICU_I18N_LIBRARY "${MAVERICKS_DEPS}/lib/libicui18n.a" CACHE FILEPATH "" FORCE)
set(ICU_UC_LIBRARY   "${MAVERICKS_DEPS}/lib/libicuuc.a"   CACHE FILEPATH "" FORCE)
set(ICU_DATA_LIBRARY "${MAVERICKS_DEPS}/lib/libicudata.a" CACHE FILEPATH "" FORCE)

# upstream injects WEBKIT_BUNDLE_VERSION from Version.xcconfig via the Xcode
# build; the CMake port never defines it, so the UI-process/child version handshake in
# ProcessLauncherCocoa.mm and XPCServiceMain.mm has no macro to reference. Define it here from the
# single WEBKIT_MAC_VERSION source of truth so both sites agree and neither hardcodes a literal.
add_compile_definitions(WEBKIT_BUNDLE_VERSION="${WEBKIT_MAC_VERSION}")

# this port's values for the features PlatformEnableCocoa.h decides with a
# `#if !defined(ENABLE_X)` block. A command-line definition preempts that block, so the port states
# its answer here rather than editing the shared header.
#   APPLE_PAY_AMS_UI              needs ENABLE(PAYMENT_REQUEST), which follows Apple Pay OFF.
#   IMAGE_ANALYSIS_ENHANCEMENTS   builds on VisionKit's VKCImageAnalysis (macOS 13+).
#   LEGACY_PDFKIT_PLUGIN/         the inline PDF plugins need PDFKit SPI 10.9 lacks; PDFs take the
#   UNIFIED_PDF/PDF_PLUGIN        download path instead.
#   PREDEFINED_COLOR_SPACE_       10.9 CoreGraphics has no Display-P3 named color space, so canvas
#   DISPLAY_P3                    must not advertise 'display-p3' either.
#   REMOTE_LAYER_TREE_ON_MAC_     compositing goes through TiledCoreAnimation here, and DOM painting
#   BY_DEFAULT, GPU_PROCESS_DOM_   stays in the web process with it. Upstream couples these two choices
#   RENDERING_BY_DEFAULT           through one >= 4-core heuristic (WebViewImpl's drawing-area pick and
#                                 defaultUseGPUProcessForDOMRenderingEnabled); this port pins the
#                                 drawing area, so it pins the paired half too. The GPU process still
#                                 serves WebGL and canvas, upstream's own shape for its TCA Macs.
#   ROUTING_ARBITRATION           SharedRoutingArbitrator drives AVAudioRoutingArbiter, a class 10.9's
#                                 AVFoundation does not export (verified with nm), reached through a
#                                 non-optional SOFT_LINK_CLASS_FOR_SOURCE. The proxy and its Cocoa
#                                 implementation are withheld from the source lists for the same
#                                 reason (WebKitPlatformMavericks.cmake).
#   SERVER_PRECONNECT             10.9 cannot warm a connection without transferring: a task flagged
#                                 _preconnect performs a full GET when resumed, fetching every main
#                                 resource twice and rotating a per-response Set-Cookie session out
#                                 from under the page just rendered.
#   DNS_SERVER_FOR_TESTING        its SPI is macOS 10.15+. The _IN_NETWORKING_PROCESS companion is stated
#                                 too: its own block keys on `defined(ENABLE_DNS_SERVER_FOR_TESTING)`
#                                 rather than the value, which a `=0` definition satisfies.
add_compile_definitions(
    ENABLE_APPLE_PAY_AMS_UI=0
    ENABLE_IMAGE_ANALYSIS_ENHANCEMENTS=0
    ENABLE_LEGACY_PDFKIT_PLUGIN=0
    ENABLE_UNIFIED_PDF=0
    ENABLE_PDF_PLUGIN=0
    ENABLE_PREDEFINED_COLOR_SPACE_DISPLAY_P3=0
    ENABLE_REMOTE_LAYER_TREE_ON_MAC_BY_DEFAULT=0
    ENABLE_GPU_PROCESS_DOM_RENDERING_BY_DEFAULT=0
    ENABLE_ROUTING_ARBITRATION=0
    ENABLE_SERVER_PRECONNECT=0
    ENABLE_DNS_SERVER_FOR_TESTING=0
    ENABLE_DNS_SERVER_FOR_TESTING_IN_NETWORKING_PROCESS=0
)

# This port's own flag, not an upstream one. The GPU process here is provisioned for rasterization:
# its profile (MavericksSupport/sandbox/com.apple.WebKit.GPUProcess.sb.in) grants DOM and canvas
# rasterization and WebGL, and no camera, microphone or AVFoundation access. Capture and the WebRTC
# platform codecs therefore run in the web process, which holds those grants, and the GPU-process
# defaults for them key on this flag.
add_compile_definitions(ENABLE_GPU_PROCESS_RASTERIZATION_ONLY=1)

# The source-list filter macro used by the WebCore/WebKit platform overlays.
include(${CMAKE_SOURCE_DIR}/MavericksSupport/cmake/MavericksSourceLists.cmake)

# OFF -- Apple Pay does not exist on 10.9. PassKit.framework here is the Passbook
# pass viewer (PKPass is present; PKPaymentRequest, PKPayment, PKPaymentMethod, PKContact and
# PKPaymentAuthorizationViewController are all absent -- verified with nm against the 10.9 binary).
# Apple Pay on the Mac arrived in 10.12. Left OFF rather than stubbed: exposing window.ApplePaySession
# to content would advertise a payment method that can never authorize, which breaks checkout flows
# that feature-detect it -- a wrong answer, not an inert one.
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_APPLE_PAY PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(USE_LCMS PRIVATE OFF)
# ENABLE WOFF2 web fonts. Our modern UA makes servers (Google Fonts, Material
# Icons, etc.) send WOFF2; without a decoder CGFontCreateWithDataProvider fails on the raw bytes
# and icon/web fonts render as empty boxes. Decoder = locally-built libwoff2dec + libbrotli (see
# PlatformMac.cmake). [[project_woff2_enabled]]
WEBKIT_OPTION_DEFAULT_PORT_VALUE(USE_WOFF2 PRIVATE ON)

# ON, the value PlatformEnableCocoa.h gives PLATFORM(MAC) and the one Apple's own
# Mac build uses; WebKitFeatures.cmake's OFF is the cross-port default. The feature stands entirely on
# libAccessibility's _AXSIsolatedTreeMode, which the AccessibilitySupport soft-link resolves through a
# dylib 10.9 does not ship — so isIsolatedTreeEnabled() answers false here and no isolated tree is ever
# built, while the Mac accessibility sources compile as upstream writes them.
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_ACCESSIBILITY_ISOLATED_TREE PRIVATE ON)

# OFF — parental-controls content filtering uses the 10.9-absent WebFilterEvaluator/NEFilter SPI.
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_CONTENT_FILTERING PRIVATE OFF)

# ON — 10.9 Dashboard widgets need -apple-dashboard-region control regions
# (subsystem removed upstream in 2d364c6; restored for the backport). The flag is declared here, inside
# the WEBKIT_OPTION_BEGIN/END window WEBKIT_OPTION_DEFINE requires, and takes its Mac value below.
WEBKIT_OPTION_DEFINE(ENABLE_DASHBOARD_SUPPORT "Toggle legacy Dashboard widget support" PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_DASHBOARD_SUPPORT PRIVATE ON)

# ON, upstream's Mac value. What 10.9 lacks is AVContentKeySession (10.12+, gated
# off by HAVE_AVCONTENTKEYSESSION), which only FairPlay Streaming needs; ClearKey needs no platform CDM
# at all. This port's media stack is GStreamer, and its ClearKey decryption runs through the restored
# CDMProxyClearKey + webkitclearkey decryptor element.
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_ENCRYPTED_MEDIA PRIVATE ON)

# ON, matching the 1 PlatformEnableCocoa.h gives `ENABLE(MEDIA_SOURCE) && ENABLE(GPU_PROCESS)`.
# The two sides of MediaProvider have to agree and only this value makes them: PlatformEnableCocoa.h
# turns this on, which the C++ side sees, while preprocess-idls.pl is handed FEATURE_DEFINES, which
# WEBKIT_OPTION_END builds from the declared WebKit options alone -- so an undeclared flag reaches the
# headers but not the IDL, HTMLMediaElement.idl's MediaProvider union stays three-membered while the
# C++ one grows a fourth, and JSHTMLMediaElement is asked to convert between them. Declaring it puts
# it in FEATURE_DEFINES, so both sides of that union agree.
WEBKIT_OPTION_DEFINE(ENABLE_MEDIA_SOURCE_IN_WORKERS "Toggle MediaSource in Workers support" PRIVATE ON)

# OFF — Web Inspector extensions are not part of the 10.9 drop-in scope.
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_INSPECTOR_EXTENSIONS PRIVATE OFF)

# OFF — the value the GStreamer-engine ports (GTK, WPE) inherit, rather than the ON
# that Apple's Mac build can afford because AVFoundation implements the legacy CDM there. MediaPlayer.cpp
# gates the AVFoundation engines out on this port, leaving MediaPlayerPrivateGStreamer as the only
# registered engine, and it implements none of MediaPlayerPrivateInterface::createSession / setCDM /
# setCDMSession / keyAdded. Turning this ON therefore has CDMPrivateMediaPlayer answer
# MediaPlayer::supportsKeySystem("org.w3.clearkey") true, hand back a WebKitMediaKeySession whose
# LegacyCDMSession is null, and WebKitMediaKeySession::keyRequestTimerFired then returns without
# emitting webkitkeymessage or webkitkeyerror — measured: a page that picks the legacy API over the
# modern one hangs silently. ENABLE_ENCRYPTED_MEDIA above stays ON; modern EME is what this port serves.
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_LEGACY_ENCRYPTED_MEDIA PRIVATE OFF)
# ON — this is the value Apple's Mac build actually uses. PlatformEnableCocoa.h:598
# turns MEDIA_RECORDER on for every Cocoa port with MEDIA_STREAM + VIDEO (both ON here), but that only
# fires `#if !defined(ENABLE_MEDIA_RECORDER)`, and WebKitFeatures.cmake already defines it as 0 for ports
# that do not opt in — so the CMake Mac port silently ends up with it OFF. Two consequences of leaving
# it off: MediaRecorder (a real web API, served here by MediaRecorderPrivateAVFImpl with the libwebm
# writer) is missing, and ENABLE_MEDIA_RECORDER_WEBM stays off with it, which
# removes MediaSourceConfiguration::supportsLimitedMatroska — a member upstream's own byte-upstream
# SourceBufferPrivateAVFObjC.mm:795 reads unguarded, so that TU cannot compile without this.
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_MEDIA_RECORDER PRIVATE ON)

# OFF — on a USE(GLIB) port, which this is because it uses GStreamer,
# ENABLE(MEDIA_SESSION) selects MediaSessionManagerGLib as the platform manager (Internals.cpp:421,
# `#if ENABLE(MEDIA_SESSION) && USE(GLIB)`). That class is an MPRIS implementation over D-Bus
# (GDBusNodeInfo, mprisInterface, dbusNotificationsEnabled — platform/audio/glib/
# MediaSessionManagerGLib.h). MPRIS is the Linux desktop media-controls protocol; macOS has no session
# D-Bus bus for it to talk to, and there is no Cocoa MediaSession manager to select instead. ON would
# mean either a manager that cannot function or the API with no platform backend — the same
# advertises-what-it-cannot-deliver problem as ENABLE_APPLE_PAY above.
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_MEDIA_SESSION PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_MEDIA_SESSION_COORDINATOR PRIVATE OFF)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_MEDIA_SESSION_PLAYLIST PRIVATE OFF)
# Right-click menu on <video>/<audio>. Complements the restored classic Aqua media controls (#68).
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_MEDIA_CONTROLS_CONTEXT_MENUS PRIVATE ON)
# DeviceOrientation/DeviceMotion. A Mac has no sensors, so the events simply never fire — which is
# exactly what they do on Apple's Mac build, where this is on. Sites feature-detect the API.
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_DEVICE_ORIENTATION PRIVATE ON)
# navigator.standalone — a one-property shim; on for every Cocoa port upstream.
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_NAVIGATOR_STANDALONE PRIVATE ON)
# WebDriver, for parity with the three WEBDRIVER_*_INTERACTIONS options already restored above.
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_WEBDRIVER_BIDI PRIVATE ON)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_WEBDRIVER_KEYBOARD_GRAPHEME_CLUSTERS PRIVATE ON)
# OFF — the one hit from that sweep deliberately left off. WK_WEB_EXTENSIONS is the
# modern WebExtensions API (WebExtensionController and a large UIProcess surface). Safari 7 predates it
# and ships its own .safariextz extension model, which this port already supports
# ([[webkit-mavericks-extensions]]); enabling a second, unreachable extension system would add a large
# amount of code no browser on this OS can drive.
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_WK_WEB_EXTENSIONS PRIVATE OFF)

# ON — WebCodecs, matching what Apple ships (PlatformEnableCocoa.h defaults it
# to 1 on Mac; the cmake feature default is OFF only because non-Apple ports opt in per-port).
# Video codecs come from libwebrtc (VideoEncoder.cpp/VideoDecoder.cpp take the USE(LIBWEBRTC) &&
# PLATFORM(COCOA) branch), audio codecs from the GStreamer AudioEncoder/AudioDecoder implementations
# (USE(GSTREAMER) wins that selection). Sites feature-detect these (Google Meet's media session setup
# uses VideoEncoder/AudioEncoder).
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_WEB_CODECS PRIVATE ON)
# ON. Everything WebMemorySampler.mac.mm calls is present on this OS -- probed here
# with dlsym: malloc_get_all_zones, malloc_get_zone_name, malloc_zone_statistics, task_info; and
# task_info(TASK_BASIC_INFO_64) answers KERN_SUCCESS on this kernel. The earlier "newer task-introspection
# SPI" premise named no symbol and none is in fact missing.
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_MEMORY_SAMPLER PRIVATE ON)

# ON — enable OffscreenCanvas (incl. in workers) for modern sites; backed by the ANGLE/CG canvas path.
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_OFFSCREEN_CANVAS PRIVATE ON)
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_OFFSCREEN_CANVAS_IN_WORKERS PRIVATE ON)
# OFF -- the Payment Request API is backed on Cocoa by the same Apple Pay machinery
# 10.9 lacks (see ENABLE_APPLE_PAY above); with no payment handler it would expose a PaymentRequest that
# can only ever reject.
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_PAYMENT_REQUEST PRIVATE OFF)
# OFF -- a product decision, not an availability gap: 10.9 PDFKit is present and
# complete (PDFDocument/PDFPage/PDFAnnotation/PDFSelection/PDFThumbnailView all verified present).
# Safari 7 hands PDFs to its own viewer, and inlining WebKit's instead regresses that; see
# [[webkit-mavericks-inline-pdf]].
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_PDFKIT_PLUGIN PRIVATE OFF)

# OFF — Picture-in-Picture is a video-presentation mode implemented on
# VideoPresentationInterfaceMac, which needs VIDEO_PRESENTATION_MODE (off; see below).
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_PICTURE_IN_PICTURE_API PRIVATE OFF)

# OFF for one named, measured reason: ResourceUsageThreadCocoa.mm:116 asks
# thread_info() for THREAD_EXTENDED_INFO, and this kernel answers KERN_INVALID_ARGUMENT (4) -- probed on
# this host, while THREAD_IDENTIFIER_INFO and TASK_BASIC_INFO_64 both answer KERN_SUCCESS. Upstream's own
# `continue` on that failure drops every thread, so the overlay would draw an empty thread list rather
# than report anything.
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_RESOURCE_USAGE PRIVATE OFF)

# OFF — native AVKit video fullscreen / PiP (VideoPresentationInterfaceMac,
# VideoPresentationManager). The upstream implementation assumes ENABLE(GPU_PROCESS), which this port
# runs without: VideoPresentationManager.mm reads Settings::blockMediaLayerRehostingInWebContentProcess(),
# a setting defined only under #if ENABLE(GPU_PROCESS), so the mode does not compile with the GPU process
# off. Element fullscreen for <video> is unaffected. Setting the option OFF here lets cmakeconfig.h
# preempt PlatformEnableCocoa.h's block, so that header stays byte-upstream (no hard override). The
# VideoPresentation/PlaybackSession interface files are withheld from the build lists rather than edited.
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_VIDEO_PRESENTATION_MODE PRIVATE OFF)

# OFF -- WebXR needs an OpenXR runtime to bind against, and there is no OpenXR
# framework on 10.9 (verified absent from both /System/Library/Frameworks and PrivateFrameworks) nor any
# VR/AR device support in this OS for one to sit on.
WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_WEBXR PRIVATE OFF)

# ON, transported over the Mozilla autopush service instead of the Apple Push Service.
# 10.9's apsd cannot serve W3C Web Push: APSConnection ships no -requestURLTokenForInfo:completion: /
# -invalidateURLTokenForInfo:completion: (both verified absent from 10.9's ApplePushService), which
# ApplePushServiceConnection::subscribe/unsubscribe send unguarded, and APSURLTokenInfo is an absent class.
# USE_MOZILLA_PUSH_SERVICE below swaps that backend for MozillaPushServiceConnection, which speaks the same
# WebSocket protocol Firefox uses against push.services.mozilla.com (webpushd/MozillaPushServiceConnection.h).
# The CMake Mac port historically defined no webpushd target (upstream builds it only from WebKit.xcodeproj);
# PlatformMac.cmake now compiles the daemon sources into WebKit.framework, as the Xcode build does, plus a
# webpushd tool target. This is not a WebKitFeatures.cmake option, so set it directly: cmakeconfig.h then
# agrees with PlatformEnableCocoa.h:266, which turns it on for every PLATFORM(MAC), and that header stays
# byte-upstream.
SET_AND_EXPOSE_TO_BUILD(ENABLE_WEB_PUSH_NOTIFICATIONS TRUE)
# this port's Web Push transport; see ENABLE_WEB_PUSH_NOTIFICATIONS above. Gates the
# MozillaPushServiceConnection backend in webpushd and the client-side pieces Safari 7 cannot provide
# itself: the default webPushMachServiceName, the PushAPIEnabled default, the daemon->client pending-push
# event plus the WebsiteDataStore pump, and the notification-provider mirror onto the service worker
# manager singleton.
SET_AND_EXPOSE_TO_BUILD(USE_MOZILLA_PUSH_SERVICE TRUE)
# webpushd deploys here exactly the way upstream's relocatable flavor models —
# the binary rides inside WebKit.framework (Versions/A/Daemons) and WebKit registers the launchd job
# at runtime — so use that flavor: the relocatable mach-service and job names, the
# PushDatabase.relocatable.db filename, and the plain ~/Library/WebKit/WebPush storage path (the
# non-relocatable branch demands the com.apple.webkit.webpushd group container, which this
# unentitled daemon cannot read). Upstream defines this flag only in Xcode configurations, so
# cmakeconfig.h is its only definition and no header is preempted.
SET_AND_EXPOSE_TO_BUILD(ENABLE_RELOCATABLE_WEBPUSHD TRUE)
# OFF -- declarative Web Push is a layer over the same push infrastructure, targeting
# daemon-side notification display, which needs HAVE(FULL_FEATURED_USER_NOTIFICATIONS) (macOS 14+; on this
# port the daemon cannot show notifications, the UI process does). Classic push -> service worker ->
# showNotification does not need it. The dependency is one-way: every ENABLE(DECLARATIVE_WEB_PUSH) site has
# an #else, so WEB_PUSH on / DECLARATIVE off compiles; only the reverse split does not. Upstream Cocoa turns
# it on for PLATFORM(MAC) in PlatformEnableCocoa.h:343 behind `#if !defined(...)`; this preempts that so the
# header stays byte-upstream.
SET_AND_EXPOSE_TO_BUILD(ENABLE_DECLARATIVE_WEB_PUSH FALSE)

# ON — 10.9's ImageIO predates AVIF, so WebCore's own AVIFImageDecoder
# serves it, the same way WEBPImageDecoder serves WebP (ScalableImageDecoder::create dispatches
# both). libavif is built decode-only on the dav1d already in deps by deps/build_deps.sh.
WEBKIT_OPTION_DEFAULT_PORT_VALUE(USE_AVIF PRIVATE ON)
else ()

# WebRTC is libwebrtc (ThirdParty/libwebrtc, gated on USE_LIBWEBRTC in Source/CMakeLists.txt) with
# Apple's Cocoa glue (LibWebRTCProviderCocoa, the VideoToolbox WK_RTCVideo* codec factories, Cocoa
# capture sources), so sites see the same WebRTC stack Safari ships. USE_GSTREAMER_WEBRTC is FALSE in
# OptionsMacGStreamer.cmake; the two backends each define PeerConnectionBackend::create, so exactly one is built.
SET_AND_EXPOSE_TO_BUILD(USE_LIBWEBRTC ON)
# WebCrypto via libgcrypt instead of CommonCrypto/CryptoKit.
# See PlatformMac.cmake for libgcrypt include + link, and SourcesCocoa.txt
# for the crypto/gcrypt/ source replacements.
SET_AND_EXPOSE_TO_BUILD(USE_GCRYPT TRUE)


# HTML5 <video>/<audio> via the upstream GStreamer media player instead of the
# custom AVAssetReader pump (AVPlayer is dead on 10.9). GStreamer 1.28.5 comes from deps/build,
# built for 10.9 with no symbol shims. Use the
# software/appsink path: GL + TextureMapper + CoordinatedGraphics OFF; decoded frames reach CG via
# ImageGStreamerCG.cpp. OptionsMacGStreamer.cmake defines the GLib::* targets + GSTREAMER_* vars from
# that tree (no pkg-config on this toolchain).
SET_AND_EXPOSE_TO_BUILD(USE_GSTREAMER TRUE)
# GStreamer integration needs WTF's GLib helper layer (GRefPtr/GUniquePtr/GSpanExtras/WTFGType, all
# #if USE(GLIB)). Only the helper headers/sources are added on Mac (see WTF/wtf/PlatformMac.cmake) —
# NOT the GLib platform replacements (RunLoopGLib/FileSystemGlib/URLGLib), which would collide with the
# Cocoa run loop / file system. USE(GLIB) is referenced by exactly one Cocoa-built WTF file otherwise.
SET_AND_EXPOSE_TO_BUILD(USE_GLIB TRUE)
SET_AND_EXPOSE_TO_BUILD(USE_GSTREAMER_GL FALSE)
SET_AND_EXPOSE_TO_BUILD(USE_TEXTURE_MAPPER FALSE)
SET_AND_EXPOSE_TO_BUILD(USE_COORDINATED_GRAPHICS FALSE)
include("${CMAKE_SOURCE_DIR}/MavericksSupport/cmake/OptionsMacGStreamer.cmake")

# link the libxml2 2.13 from deps/build (@rpath install name, shipped
# alongside GStreamer) instead of the SDK tbd. The SDK tbd binds /usr/lib/libxml2.2.dylib,
# which on 10.9 is libxml2 2.9.0 — its __xmlRaiseError crashes on fatal parse errors from
# SVG/XML payloads, and its runtime behavior diverges from the 2.9.13 SDK headers WebCore
# compiles against. Headers and dylib match here. libxslt stays on the system copy: it uses
# the system libxml 2.9.0 internally, which is safe across the boundary — libxml2 keeps
# xmlDoc/xmlNode struct ABI stable across 2.x, and WebCore intercepts libxslt's document
# loading at the libxslt layer (xsltSetLoaderFunc), so no uncontrolled 2.9 parsing happens.
set(LIBXML2_INCLUDE_DIR "${MAVERICKS_DEPS}/include/libxml2" CACHE PATH "" FORCE)
set(LIBXML2_LIBRARY "${MAVERICKS_DEPS}/lib/libxml2.2.dylib" CACHE FILEPATH "" FORCE)

# Polyfill libraries for macOS 10.9
#
# Build-environment locations. The clang-22 toolchain root derives from the compiler in
# use, and the MavericksSupport artifacts are named relative to the source tree, so a fresh
# checkout plus a bootstrapped toolchain configures wherever it sits (see MAVERICKS_DEPS above).
get_filename_component(MAVERICKS_TC "${CMAKE_CXX_COMPILER}" DIRECTORY)   # .../clang-22/bin
get_filename_component(MAVERICKS_TC "${MAVERICKS_TC}" DIRECTORY)         # .../clang-22
set(MAVERICKS_TC "${MAVERICKS_TC}" CACHE INTERNAL "clang-22 toolchain root")

# link libc++ DYNAMICALLY (one shared copy) rather than statically into every
# dylib. Static libc++ per-dylib gives WebCore and JavaScriptCore each their own copy of libc++'s
# locale/iostream global state; destroying a std::stringstream then corrupts across copies and
# crashes WebContent. These are the clang-22 toolchain's libc++/libc++abi
# (install_name @rpath/libc++.1.dylib); the postbuild deploys a private copy next to the
# frameworks and points an LC_RPATH at it so the system's old 10.9 libc++ is NOT used.
link_libraries(${MAVERICKS_TC}/lib/libc++.1.dylib)
link_libraries(${MAVERICKS_TC}/lib/libc++abi.1.dylib)
# clang++.cfg puts -L<toolchain>/lib on every C++ link, so CMake's ABI detection records that
# directory as an implicit one -- a kind it will not order into a target's runtime search path.
# deps/build/lib is on that path for everything that links a GStreamer dylib and carries the media
# runtime's own copies of these two, so CMake sees a name it cannot safely resolve. Spelling the
# toolchain directory as explicit lets it order the two, ahead of deps/build/lib.
list(REMOVE_ITEM CMAKE_CXX_IMPLICIT_LINK_DIRECTORIES "${MAVERICKS_TC}/lib")
list(REMOVE_ITEM CMAKE_OBJCXX_IMPLICIT_LINK_DIRECTORIES "${MAVERICKS_TC}/lib")

# WebKit intends RTTI disabled everywhere (Xcode's GCC_ENABLE_CPP_RTTI=NO covers ObjC++ too), but
# WebKitCompilerFlags.cmake applies -fno-rtti to CXX alone, leaving OBJCXX (.mm) with RTTI on. That
# mismatch makes .mm files emit and reference C++ typeinfos for classes whose .cpp definitions
# (compiled -fno-rtti) emit none -- strong-undefined "typeinfo for ..." symbols that abort every
# WebKit process at dyld load. No .mm in the tree uses dynamic_cast or typeid.
if (CMAKE_OBJCXX_COMPILER_LOADED)
    set(CMAKE_OBJCXX_FLAGS "${CMAKE_OBJCXX_FLAGS} -fno-rtti")
endif ()
# libpolyfill.a supplies the symbols this port provides in place of the 10.9 runtime's: the
# POSIX/libc base, the framework-SPI gap-fills, and the handful of deliberate replacements for 10.9
# functions that misbehave. Linked into every binary.
#
# This plain listing is what the BUILD-TIME TOOLS get (LLIntOffsetsExtractor and friends), and
# ordinary archive semantics are fine for them: they just need the libc gap-fills to resolve, and
# they never ship. Anything that DOES ship additionally force-loads the archive, because for shipped
# code it matters which definition wins rather than merely that the link succeeds -- see
# _WEBKIT_FORCE_LOAD_POLYFILL in WebKitBuildRulesMavericks.cmake. Force-loading it here instead would drag the
# whole archive into every build tool, which then needs every framework the polyfill references on
# its link line.
link_libraries(${MAVERICKS_SUPPORT}/polyfill/build/libpolyfill.a)
# libpolyfill_classes.dylib (the polyfill ObjC class stubs) is NOT link_libraries'd here: it is linked
# per-framework by _MAVERICKS_LINK_POLYFILL_CLASSES so it covers framework targets without also
# being dragged into build tools, and the classes its owning framework is linked earlier than are handled by
# the reexport+repoint in MavericksSupport/scripts/stage-frameworks.sh.
# QuartzCore's CALayer is the superclass of the CABackdropLayer stub; linking it everywhere (it is a 10.9
# system framework) is harmless and also covers any binary that uses CALayer directly.
link_libraries("-framework QuartzCore")

# the Apple Mac port builds the layout-test tools (ImageDiff) via Xcode upstream, so
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

# with DEVELOPER_MODE, bmalloc builds its mbmalloc microbenchmark dylib, which links
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
# exclude ASM_NASM (libvpx/libwebrtc .asm via nasm) — nasm rejects -m*/-W*/-iframework.
add_compile_options($<$<NOT:$<COMPILE_LANGUAGE:ASM_NASM>>:-mmacosx-version-min=10.9>)
add_link_options(-mmacosx-version-min=10.9)

# skip clang.cfg for ASM-language (.S) sources so its link flags
# (-lobjc/-framework) are not parsed as assembler input. ASM_NASM uses nasm, not
# clang, so it is excluded.
add_compile_options($<$<COMPILE_LANGUAGE:ASM>:--no-default-config>)

# the modern SDK's availability annotations flag every post-10.9 API
# WebKit calls against the 10.9 deployment target. WebKit handles 10.9 via weak
# linking plus targeted runtime guards rather than @available everywhere, so silence
# the availability/deprecation diagnostics (nasm rejects -W*).
add_compile_options(
  $<$<NOT:$<COMPILE_LANGUAGE:ASM_NASM>>:-Wno-unguarded-availability-new>
  $<$<NOT:$<COMPILE_LANGUAGE:ASM_NASM>>:-Wno-unguarded-availability>
  $<$<NOT:$<COMPILE_LANGUAGE:ASM_NASM>>:-Wno-deprecated-declarations>
  $<$<NOT:$<COMPILE_LANGUAGE:ASM_NASM>>:-Wno-availability>)

# libc++ marks parts of the standard library (std::filesystem from
# 10.15, the std::any/optional/variant bad-access throwers and aligned operator new
# from 10.14, ...) unavailable below those versions, because those symbols entered the
# SYSTEM libc++ dylib then. This build ships the clang-22 libc++ privately (install_name
# @rpath/libc++.1.dylib, deployed beside the frameworks) and forces its use, so those
# symbols are always present regardless of the OS libc++. Disable the vendor
# availability markup so the standard library is usable against the 10.9 target, and tell the
# compiler the same for C++17 aligned new/delete (operator new(size_t, align_val_t) and friends),
# whose availability clang checks itself rather than through libc++'s markup: the private
# libc++abi exports them, so `new` of an over-aligned type is fine here.
add_compile_options($<$<NOT:$<COMPILE_LANGUAGE:ASM_NASM>>:-D_LIBCPP_DISABLE_AVAILABILITY>)
add_compile_options($<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-faligned-allocation>)

# gap-fill header overlay, searched AFTER the real SDK (-idirafter) so
# the SDK's header always wins where present and only genuinely-missing headers fall
# through. With a modern SDK the Apple headers come from the SDK; the overlay mainly
# covers third-party gaps (e.g. libwebrtc's opus_defines.h).
add_compile_options($<$<NOT:$<COMPILE_LANGUAGE:ASM_NASM>>:-idirafter> $<$<NOT:$<COMPILE_LANGUAGE:ASM_NASM>>:${MAVERICKS_SUPPORT}/polyfill/headers>)

# clang-22 enables C++/ObjC modules by default, so __has_feature(modules) is true.
# Many WebKit SPI headers guard their forward declarations with `#if !__has_feature(modules)`,
# expecting the types to come from framework modules instead. But the 10.9 system frameworks lack the
# newer types those declarations cover (CMTag, FigThreadAbortAction, ...), leaving them undeclared.
# Disable implicit modules so the SPI headers fall back to providing the declarations textually.
add_compile_options($<$<NOT:$<COMPILE_LANGUAGE:ASM_NASM>>:-fno-modules> $<$<NOT:$<COMPILE_LANGUAGE:ASM_NASM>>:-fno-cxx-modules>)

# WebCrypto runs on libgcrypt (USE_GCRYPT), not the Swift CryptoKit path.
# CryptoKey*/CryptoAlgorithm* gate the Swift bridge (PALSwift-Generated.h, generated only by
# Apple's internal Swift build) on `#if !defined(CLANG_WEBKIT_BRANCH)`. Define it so the Swift
# path is skipped and the gcrypt/CommonCrypto fallbacks compile. Value is unused (only its
# definedness is tested). nasm has no preprocessor C macros, so exclude ASM_NASM.
add_compile_options($<$<NOT:$<COMPILE_LANGUAGE:ASM_NASM>>:-DCLANG_WEBKIT_BRANCH=0>)

# libwebrtc's final static archive aggregates ~2000 objects; `ar qc <all .o>`
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
endif ()
