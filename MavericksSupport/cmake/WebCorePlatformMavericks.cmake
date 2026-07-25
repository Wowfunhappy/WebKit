# MAVERICKS_BACKPORT: every backport change to WebCore's Mac CMake configuration.
#
# Source/WebCore/PlatformMac.cmake is kept BYTE-UPSTREAM and ends with a single `include()` of this
# file. Keeping the divergence here instead of in upstream's file means an upstream merge of
# PlatformMac.cmake never conflicts, and everything this port changes is visible in one place.
#
# This file is included at the END of upstream's PlatformMac.cmake, which is itself included from
# Source/WebCore/CMakeLists.txt:2772 -- before the lists are consumed (CSS_VALUE_PLATFORM_DEFINES at
# :2879, WebCore_USER_AGENT_SCRIPTS at :2906, the WebCore target later still). So appending to,
# removing from, and re-setting those variables here all take effect.

# --------------------------------------------------------------------------
# Standalone backport blocks (targets, definitions, framework lookups, staging).
# --------------------------------------------------------------------------
# MAVERICKS_BACKPORT: compile the upstream GStreamer media player (software/appsink path) for the
# Mac/CG port. GStreamer.cmake consumes the GSTREAMER_*/GLib targets set by OptionsMacGStreamer.cmake.
if (USE_GSTREAMER)
    include(platform/GStreamer.cmake)
endif ()

# MAVERICKS_BACKPORT: no Compression.framework link (Compression API is 10.11+; absent on 10.9).

# MAVERICKS_BACKPORT: no Metal.framework link (Metal is 10.11+; absent on 10.9).
# MAVERICKS_BACKPORT: no NetworkExtension.framework link (absent on 10.9).

# MAVERICKS_BACKPORT: no SceneKit.framework link. WebCore binds no SceneKit symbols on this
# port (the <model> element's SceneKit backing TUs are stubbed and its runtime pref defaults
# off on Mac), but a hard link records an LC_LOAD_DYLIB that loads the 10.9 system SceneKit
# into every WebKit client at launch. Apps that bundle a newer SceneKit — Xcode 6's editor
# plug-ins reference @rpath/SceneKit and ship v186 in Contents/SharedFrameworks — then get
# the already-loaded 10.9 image (dyld matches the framework's partial path
# SceneKit.framework/Versions/A/SceneKit to the loaded /System copy) instead of their bundled
# one, which lacks 10.10+ classes such as SCNParticlePropertyController, and abort at launch.

# MAVERICKS_BACKPORT: Lookup.framework depends on WebKit.framework, creating a circular dep chain:
# WebCore -> Lookup -> WebKit -> WebKitLegacy -> WebCore
# This causes all frameworks to load simultaneously and crashes the ObjC runtime.
# Do not link Lookup directly; its symbols resolve via -undefined dynamic_lookup.
# find_library(LOOKUP_FRAMEWORK Lookup HINTS ${CMAKE_OSX_SYSROOT}/System/Library/PrivateFrameworks)
# list(APPEND WebCore_LIBRARIES ${LOOKUP_FRAMEWORK})

# MAVERICKS_BACKPORT: pass bare macro names (no =1) to the CSS value preprocessor; the value-1 form trips the in-tree makeprop/CSS preprocessor here.
set(CSS_VALUE_PLATFORM_DEFINES "WTF_PLATFORM_MAC WTF_PLATFORM_COCOA ENABLE_APPLE_PAY_NEW_BUTTON_TYPES")

# MAVERICKS_BACKPORT (#68): also build the classic Safari 7 / Mavericks media-controls script.
# make-js-file-arrays.py names the array from the basename, emitting mediaControlsAppleJavaScript,
# which RenderThemeCocoa serves on the 10.9 deployment target instead of ModernMediaControlsJavaScript.
set(WebCore_USER_AGENT_SCRIPTS
    ${WebCore_DERIVED_SOURCES_DIR}/ModernMediaControls.js
    ${WEBCORE_DIR}/Modules/mediacontrols/mediaControlsApple.js
)

# MAVERICKS_BACKPORT: vendored libwebp for the WEBPImageDecoder fallback (ImageIO on
# this build can't decode WebP). Static libs at MavericksSupport/deps/libwebp/lib.
# IMPORTANT: changing this section invalidates WebCore IPC structs — must rebuild
# WebKit too (`ninja WebKit`) or Safari crashes in IPC::ArgumentCoder decode.

# MAVERICKS_BACKPORT: libgcrypt powers WebCrypto (replaces the cocoa CommonCrypto path).
# libtasn1 handles SPKI/PKCS8 ASN.1 parsing for the gcrypt EC/RSA importers.
# All built in-tree by MavericksSupport/deps/build_deps.sh; static link.

# MAVERICKS_BACKPORT: WOFF2 web-font decoder (USE_WOFF2=ON). Our modern UA makes Google Fonts/Material
# Icons serve WOFF2; WOFFFileFormat.cpp::convertWOFFToSfntIfNecessary then calls woff2::ConvertWOFF2ToTTF
# (Brotli-decompress + table reconstruction). Built locally from google/woff2 + google/brotli (static).
# WebCore/CMakeLists.txt does `list(APPEND WebCore_LIBRARIES WOFF2::dec)` when USE_WOFF2 is ON, so we
# define that imported target here (instead of via find_package) and carry brotli as interface deps.
if (NOT TARGET WOFF2::dec)
    add_library(WOFF2::dec UNKNOWN IMPORTED GLOBAL)
    set_target_properties(WOFF2::dec PROPERTIES
        IMPORTED_LOCATION "${MAVERICKS_DEPS}/lib/libwoff2dec.a"
        INTERFACE_INCLUDE_DIRECTORIES "${MAVERICKS_DEPS}/include"
        INTERFACE_LINK_LIBRARIES "${MAVERICKS_DEPS}/lib/libbrotlidec.a;${MAVERICKS_DEPS}/lib/libbrotlicommon.a"
    )
endif ()

# MAVERICKS_BACKPORT: platform/ios holds several files the Mac build genuinely needs once
# ENABLE(VIDEO_PRESENTATION_MODE) is on -- WebAVPlayerController and the PlaybackSessionInterface /
# VideoPresentationInterface family, all of which compile under PLATFORM(COCOA) rather than
# PLATFORM(IOS_FAMILY). platform/cocoa/WebAVPlayerLayer.mm includes "WebAVPlayerController.h" by bare
# name, and VideoPresentationInterfaceMac.mm allocates a WebAVPlayerLayer, so the Mac build needs this
# directory on its header search path. Upstream's Xcode build has every platform subdirectory on the
# search path, which is why it never has to say so; the CMake port lists them individually. Verified no
# filename collisions with platform/mac, platform/cocoa, platform, or platform/graphics/cocoa.

# MAVERICKS_BACKPORT: libwebm (webm_parser component + the VP9
# uncompressed-header parser). Apple's Mac port gets libwebm from its internal SDK, so upstream's CMake
# never has to name it; without it the sources that include <webm/...> cannot compile. That is a
# third-party gap, not a 10.9 one, and it reaches live code -- AudioFileReaderCocoa.mm (Web Audio
# decodeAudioData) calls SourceBufferParserWebM::create() directly.
#
# The copy used is the one already vendored in-tree under ThirdParty/libwebrtc -- unbuilt otherwise,
# since USE_LIBWEBRTC is OFF, but present. That is deliberate rather than incidental: it is the vintage
# WebKit is written against. Current upstream libwebm has dropped webm::Callback::OnElementEnd, which
# SourceBufferParserWebM.h declares `final`, so building against a fresh checkout fails with
# "only virtual member functions can be marked 'final'".
#
# The headers are staged into the build tree rather than added as two include directories because WebKit
# spells one of them <webm/common/vp9_header_parser.h> while libwebm ships it at common/, outside the
# webm/ include root -- so no directory in the source tree satisfies every spelling at once.
set(LIBWEBM_DIR "${THIRDPARTY_DIR}/libwebrtc/Source/third_party/libwebm")
set(LIBWEBM_STAGED_INCLUDE "${CMAKE_BINARY_DIR}/libwebm/Headers")
file(COPY "${LIBWEBM_DIR}/webm_parser/include/webm" DESTINATION "${LIBWEBM_STAGED_INCLUDE}")
file(COPY "${LIBWEBM_DIR}/common/vp9_header_parser.h" DESTINATION "${LIBWEBM_STAGED_INCLUDE}/webm/common")
# MAVERICKS_BACKPORT: the muxer half of libwebm. MediaRecorderPrivateWriterWebM.cpp includes
# <webm/mkvmuxer/mkvmuxer.h>, and that TU is built now that ENABLE_MEDIA_RECORDER_WEBM is on, so the
# parser alone is not enough.
file(COPY "${LIBWEBM_DIR}/mkvmuxer" DESTINATION "${LIBWEBM_STAGED_INCLUDE}/webm"
     FILES_MATCHING PATTERN "*.h")
file(COPY "${LIBWEBM_DIR}/common" DESTINATION "${LIBWEBM_STAGED_INCLUDE}/webm"
     FILES_MATCHING PATTERN "*.h")
# libwebm's own headers include each other by paths relative to the library root -- mkvmuxer.h does
# `#include "common/webmids.h"` and `#include "mkvmuxer/mkvmuxertypes.h"`. Those do not resolve against
# the webm/-prefixed tree above, so stage the root layout as well and put both on the include path.
file(COPY "${LIBWEBM_DIR}/mkvmuxer" DESTINATION "${LIBWEBM_STAGED_INCLUDE}"
     FILES_MATCHING PATTERN "*.h")
file(COPY "${LIBWEBM_DIR}/common" DESTINATION "${LIBWEBM_STAGED_INCLUDE}"
     FILES_MATCHING PATTERN "*.h")

# NOTE: the source list must be complete BEFORE add_library() -- appending to LIBWEBM_SOURCES after the
# target exists has no effect on it.
file(GLOB LIBWEBM_SOURCES "${LIBWEBM_DIR}/webm_parser/src/*.cc")
list(APPEND LIBWEBM_SOURCES
    "${LIBWEBM_DIR}/common/vp9_header_parser.cc"
    "${LIBWEBM_DIR}/mkvmuxer/mkvmuxer.cc"
    "${LIBWEBM_DIR}/mkvmuxer/mkvmuxerutil.cc"
    "${LIBWEBM_DIR}/mkvmuxer/mkvwriter.cc"
    "${LIBWEBM_DIR}/common/webm_endian.cc"
)
add_library(webm STATIC ${LIBWEBM_SOURCES})
target_include_directories(webm PRIVATE
    "${LIBWEBM_DIR}"
    "${LIBWEBM_DIR}/webm_parser"
    "${LIBWEBM_DIR}/webm_parser/include"
)
# MAVERICKS_BACKPORT: WEBRTC_WEBKIT_BUILD is what makes this vendored libwebm the version WebKit is
# written against. It guards seven places in the library -- including webm::Callback::OnElementEnd,
# which SourceBufferParserWebM.h declares `final`, and Vp9HeaderParser's color_range()/subsampling_x()/
# subsampling_y(), which VP9UtilitiesCocoa.mm calls. WebKit defines it in
# platform/mediastream/libwebrtc/LibWebRTCMacros.h (as 1), but that header is only reached through the
# libwebrtc code paths, which this port does not build (USE_LIBWEBRTC is OFF) -- so without defining it
# here the library and its WebCore consumers see an unpatched libwebm and fail to compile.
#
# It is defined for ALL of WebCore rather than just the translation units that name these symbols, and
# that is deliberate: webm::Callback::OnElementEnd is a VIRTUAL function inside the guard, so a TU that
# sees it and a TU that does not disagree about webm::Callback's vtable layout. Mixing them would be an
# ODR violation that links cleanly and then dispatches to the wrong slot at runtime, rather than
# failing loudly. The library target gets the same define for the same reason.
target_compile_definitions(webm PRIVATE WEBRTC_WEBKIT_BUILD=1)
add_definitions(-DWEBRTC_WEBKIT_BUILD=1)

# libwebm is third-party: do not fail this build on its warnings.
target_compile_options(webm PRIVATE -w)
set_target_properties(webm PROPERTIES POSITION_INDEPENDENT_CODE ON)


# MAVERICKS_BACKPORT: re-export /usr/lib/libobjc.A.dylib through WebCore, exactly as stock 10.9 did.
# (Verified against the stock framework: stock WebCore.framework/WebCore carries an LC_REEXPORT_DYLIB for
# /usr/lib/libobjc.A.dylib, and stock WebKit.framework/WebKit re-exports WebCore — so plug-ins resolve the
# old ObjC "fixup" dispatch symbols via a WebKit -> WebCore -> libobjc chain.) Legacy native plug-ins —
# Safari Web Clips' WebClip.plugin and Dashboard widget Plugin bundles such as Sol.wdgt's
# TimeZoneHelper.bundle and the Dictionary widget — two-level-bind __objc_empty_cache / __objc_empty_vtable
# / _objc_msgSend_fixup / _objc_msgSendSuper2_fixup "from WebKit" and reach them through that chain. The
# modern build SDK's libobjc.tbd dropped those symbols, but the re-export binds dynamically against the
# running 10.9 /usr/lib/libobjc.A.dylib (install_name /usr/lib/libobjc.A.dylib), which still vends all four.
# WebKitLegacy already re-exports this WebCore, so WebKit.framework reaches libobjc transitively, matching
# stock; nothing else needs the flag.
set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -Wl,-reexport-lobjc")

# testing/MockWebAuthenticationConfiguration.idl is listed in BOTH the base CMakeLists.txt
# WebCoreTestSupport_IDL_FILES set and PlatformMac.cmake's append, so it lands in the list twice and the
# binding generator emits JSMockWebAuthenticationConfiguration.cpp as a duplicate ninja output ("defined
# as an output multiple times"). Upstream never trips this because Apple builds Mac with Xcode; the CMake
# Mac port is the first to build TestSupport with WEB_AUTHN on. Collapse the duplicate here (this include
# runs after both add sites, before GENERATE_BINDINGS) — REMOVE_DUPLICATES, not REMOVE_ITEM, so the one
# needed copy survives.
list(REMOVE_DUPLICATES WebCoreTestSupport_IDL_FILES)

# --------------------------------------------------------------------------
# Entries withheld from upstream's lists. Expressed as REMOVE_ITEM rather than by
# editing upstream's file, so PlatformMac.cmake stays byte-upstream.
# --------------------------------------------------------------------------
list(REMOVE_ITEM WebCore_LIBRARIES
    ${COMPRESSION_LIBRARY}
    ${METAL_LIBRARY}
    ${NETWORKEXTENSION_LIBRARY}
    ${SCENEKIT_LIBRARY}
    opus
    vpx
    yuv
    ${LOOKUP_FRAMEWORK}
)

list(REMOVE_ITEM WebCore_PRIVATE_FRAMEWORK_HEADERS
    platform/mac/WebNSAttributedStringExtras.h
)

list(REMOVE_ITEM WebCore_SOURCES
    Modules/webaudio/MediaStreamAudioSourceCocoa.cpp
    accessibility/mac/WebAccessibilityObjectWrapperMac.mm
    platform/audio/cocoa/AudioDecoderCocoa.cpp
    platform/audio/cocoa/AudioEncoderCocoa.cpp
    platform/graphics/avfoundation/AVTrackPrivateAVFObjCImpl.mm
    platform/mediastream/mac/RealtimeOutgoingVideoSourceCocoa.mm
)

# --------------------------------------------------------------------------
# Entries added to upstream's lists.
# --------------------------------------------------------------------------
list(APPEND WebCoreTestSupport_SOURCES
    # MAVERICKS_BACKPORT: WebKitTestRunner's UIScriptController and AccessibilityUIElementMac call
    # WebCoreTestSupport::serializationForCSS(NSColor *), but this source was missing from the Mac
    # WebCoreTestSupport build, leaving the symbol undefined when linking WebKitTestRunner.
    testing/cocoa/CocoaColorSerialization.mm
)

list(APPEND WebCore_IDL_FILES
    # MAVERICKS_BACKPORT: also generate the ApplePayDisbursementRequest IDL binding.
    Modules/applepay/ApplePayDisbursementRequest.idl
)

# MAVERICKS_BACKPORT: definitions upstream compiles only from WebCore.xcodeproj and never added to a CMake
# source list, so the CMake Mac port compiles their callers but not the definitions. WebCore links with
# "-undefined dynamic_lookup" (Source/WebCore/CMakeLists.txt), which lets those references survive the link
# as flat-namespace undefined symbols instead of failing it -- and every one of them then aborts any client
# that binds WebCore eagerly (dlopen RTLD_NOW, or a hard-bound framework), because dyld must resolve them up
# front and nothing defines them. Listed here rather than in Sources*.txt to keep the in-tree diff off
# upstream's lists; entries added this way compile as their own TU, exactly as upstream's own PlatformMac.cmake
# entries (e.g. platform/gamepad/cocoa/GameControllerSoftLink.mm) do. Non-ARC like their SourcesCocoa.txt
# siblings, which is this build's default (WebKitMacros.cmake only adds -fobjc-arc for -ARC.mm sources).
list(APPEND WebCore_SOURCES
    # Plain X.690 DER length arithmetic over a Vector<uint8_t> -- despite the directory it pulls in no
    # CommonCrypto, and WebAuthn's Modules/webauthn/fido/U2fResponseConverter.cpp calls
    # bytesUsedToEncodedLength() whichever WebCrypto backend is built. SourcesCocoa.txt comments the whole
    # crypto/cocoa directory out for the libgcrypt swap, which took this file with it.
    crypto/cocoa/CommonCryptoDERUtilities.cpp
    # The MediaRecorderPrivateWriter base: create/close/writeFrames plus its ctor and dtor, all called from
    # platform/mediarecorder/MediaRecorderPrivateEncoder.cpp (which SourcesCocoa.txt does build).
    platform/mediarecorder/MediaRecorderPrivateWriter.cpp
    # Gamepad haptics: GameControllerGamepad.mm calls GameControllerHapticEngines::create/playEffect/
    # stopEffects/stop and its dtor. GameControllerHapticEffect.mm and CoreHapticsSoftLink.mm come along as
    # the engines' own dependencies. CoreHaptics is absent on 10.9 and soft-linked optionally
    # (CoreHapticsSoftLink.mm), so this adds no load-time dependency on it.
    platform/gamepad/cocoa/CoreHapticsSoftLink.mm
    platform/gamepad/cocoa/GameControllerHapticEffect.mm
    platform/gamepad/cocoa/GameControllerHapticEngines.mm
)

list(APPEND WebCore_LIBRARIES
    "${CMAKE_SOURCE_DIR}/MavericksSupport/deps/libwebp/lib/libwebpdemux.a"
    "${CMAKE_SOURCE_DIR}/MavericksSupport/deps/libwebp/lib/libwebp.a"
    "${CMAKE_SOURCE_DIR}/MavericksSupport/deps/libwebp/lib/libsharpyuv.a"
    "${MAVERICKS_DEPS}/lib/libgcrypt.a"
    "${MAVERICKS_DEPS}/lib/libtasn1.a"
    "${MAVERICKS_DEPS}/lib/libgpg-error.a"
)

list(APPEND WebCore_PRIVATE_FRAMEWORK_HEADERS
    # MAVERICKS_BACKPORT: export PlatformDynamicRangeLimitCocoa.h — the CADynamicRange limit helper
    # WebViewImpl.mm imports as <WebCore/PlatformDynamicRangeLimitCocoa.h>. Upstream's Xcode build finds
    # it by basename; the CMake port stages private headers by explicit list, so it must be named here.
    platform/graphics/ca/cocoa/PlatformDynamicRangeLimitCocoa.h
    # MAVERICKS_BACKPORT: export NSURLUtilities.h — the restored (un-stubbed) WKShareSheet.mm imports it as
    # <WebCore/NSURLUtilities.h>. Upstream's Xcode build finds it by basename; the CMake port needs it named.
    platform/cocoa/NSURLUtilities.h
    # MAVERICKS_BACKPORT: export TouchEvent.h (touch-event interface header).
    dom/TouchEvent.h
    # MAVERICKS_BACKPORT: export EditingHTMLConverter.h (HTML serialization helper).
    editing/cocoa/EditingHTMLConverter.h
    # MAVERICKS_BACKPORT: export NodeHTMLConverter.h and TextAttachmentForSerialization.h (HTML/attachment serialization).
    editing/cocoa/NodeHTMLConverter.h
    editing/cocoa/TextAttachmentForSerialization.h
    # MAVERICKS_BACKPORT: export ContentChangeObserver.h and DOMTimerHoldingTank.h (page/cocoa observers).
    page/cocoa/ContentChangeObserver.h
    page/cocoa/DOMTimerHoldingTank.h
    # MAVERICKS_BACKPORT: export WebTextIndicatorLayer.h (text-indicator layer).
    page/cocoa/WebTextIndicatorLayer.h
    # MAVERICKS_BACKPORT: export CorrectionIndicator.h (autocorrection indicator UI).
    page/mac/CorrectionIndicator.h
    # MAVERICKS_BACKPORT: export ScrollerMac.h/ScrollerPairMac.h (mac overlay-scroller painting).
    page/scrolling/mac/ScrollerMac.h
    page/scrolling/mac/ScrollerPairMac.h
    # MAVERICKS_BACKPORT: export ScrollingTreePluginScrollingNodeMac.h.
    page/scrolling/mac/ScrollingTreePluginScrollingNodeMac.h
    # MAVERICKS_BACKPORT: export WebCoreMainThread.h (main-thread helper) ahead of the platform headers.
    platform/WebCoreMainThread.h
    # MAVERICKS_BACKPORT: export AudioUtilitiesCocoa.h and SpatialAudioExperienceHelper.h (audio helpers).
    platform/audio/cocoa/AudioUtilitiesCocoa.h
    platform/audio/cocoa/SpatialAudioExperienceHelper.h
    # MAVERICKS_BACKPORT: export additional platform/cocoa headers (visual-effect/view/geolocation/CoreVideo) the WK build references.
    platform/cocoa/AppleVisualEffect.h
    platform/cocoa/CocoaView.h
    platform/cocoa/CocoaWritingToolsTypes.h
    platform/cocoa/CoreLocationGeolocationProvider.h
    platform/cocoa/CoreVideoExtras.h
    # MAVERICKS_BACKPORT: export the ParentalControls content/URL-filter headers + PlatformTextAlternatives.h.
    platform/cocoa/ParentalControlsContentFilter.h
    platform/cocoa/ParentalControlsURLFilter.h
    platform/cocoa/ParentalControlsURLFilterParameters.h
    platform/cocoa/PlatformTextAlternatives.h
    # MAVERICKS_BACKPORT: export the video-presentation/fullscreen + WebKitAvailability cocoa headers the WK build references.
    platform/cocoa/VideoFullscreenCaptions.h
    platform/cocoa/VideoPresentationLayerProvider.h
    platform/cocoa/VideoPresentationModel.h
    platform/cocoa/VideoPresentationModelVideoElement.h
    platform/cocoa/WebAVPlayerLayer.h
    platform/cocoa/WebAVPlayerLayerView.h
    platform/cocoa/WebKitAvailability.h
    # MAVERICKS_BACKPORT: GameControllerSPI.h is a Private framework header in the Xcode project
    # (so <WebCore/GameControllerSPI.h> resolves there) but the CMake port omits it from the copy
    # list; ENABLE(GAMEPAD) is ON for this port, so it must be forwarded like the other SPI headers.
    platform/gamepad/cocoa/GameControllerSPI.h
    # MAVERICKS_BACKPORT: export MediaPlaybackTargetWirelessPlayback.h (wireless playback target type).
    platform/graphics/MediaPlaybackTargetWirelessPlayback.h
    # MAVERICKS_BACKPORT: export MediaPlayerPrivateAVFoundation.h (base AVFoundation media player).
    platform/graphics/avfoundation/MediaPlayerPrivateAVFoundation.h
    # MAVERICKS_BACKPORT: AudioVideoRendererAVFObjC.h (exported just above) includes
    # <WebCore/WebAVSampleBufferListener.h>, so the forwarded copy needs its dependency forwarded too.
    # Upstream's Xcode build resolves it through header maps and never needs the explicit entry.
    platform/graphics/avfoundation/WebAVSampleBufferListener.h
    # MAVERICKS_BACKPORT: export PlatformCALayerDelegatedContents.h and ContentsFormatCocoa.h (CA layer contents/format).
    platform/graphics/ca/PlatformCALayerDelegatedContents.h
    platform/graphics/ca/cocoa/ContentsFormatCocoa.h
    # MAVERICKS_BACKPORT: export CGWindowUtilities.h (CGS window helpers).
    platform/graphics/cg/CGWindowUtilities.h
    # MAVERICKS_BACKPORT: export IOSurfacePoolIdentifier.h.
    platform/graphics/cg/IOSurfacePoolIdentifier.h
    # MAVERICKS_BACKPORT: export ImageBufferCGPDFDocumentBackend.h (CG PDF-document image buffer backend).
    platform/graphics/cg/ImageBufferCGPDFDocumentBackend.h
    # MAVERICKS_BACKPORT: export ImageDecoderCG.h (CG image decoder).
    platform/graphics/cg/ImageDecoderCG.h
    # MAVERICKS_BACKPORT: export PathCG.h (CG path helpers).
    platform/graphics/cg/PathCG.h
    # MAVERICKS_BACKPORT: export AV1UtilitiesCocoa.h (AV1 codec utility helpers).
    platform/graphics/cocoa/AV1UtilitiesCocoa.h
    # MAVERICKS_BACKPORT: export DynamicContentScalingDisplayList.h.
    platform/graphics/cocoa/DynamicContentScalingDisplayList.h
    # MAVERICKS_BACKPORT: export additional graphics/cocoa headers (font/HEVC/media-enum/presentation) the WK build references.
    platform/graphics/cocoa/FontCascadeCocoaInlines.h
    platform/graphics/cocoa/HEVCUtilitiesCocoa.h
    platform/graphics/cocoa/IOSurfaceDrawingBuffer.h
    platform/graphics/cocoa/MediaPlayerEnumsCocoa.h
    platform/graphics/cocoa/NullPlaybackSessionInterface.h
    platform/graphics/cocoa/NullVideoPresentationInterface.h
    platform/graphics/cocoa/SystemFontDatabaseCoreText.h
    platform/graphics/cocoa/TextTrackRepresentationCocoa.h
    # MAVERICKS_BACKPORT: export VideoTargetFactory.h (video presentation target creation).
    platform/graphics/cocoa/VideoTargetFactory.h
    # MAVERICKS_BACKPORT: export AppKitControlSystemImage.h (AppKit control system-image drawing).
    platform/graphics/mac/AppKitControlSystemImage.h
    # MAVERICKS_BACKPORT: export ScrollbarTrackCornerSystemImageMac.h (scrollbar corner system image).
    platform/graphics/mac/ScrollbarTrackCornerSystemImageMac.h
    # MAVERICKS_BACKPORT: export the platform/ios headers the WK build references (shared iOS-named types/stubs).
    platform/ios/AbstractPasteboard.h
    platform/ios/DeviceOrientationUpdateProvider.h
    platform/ios/KeyEventCodesIOS.h
    platform/ios/LegacyTileCache.h
    platform/ios/LocalCurrentTraitCollection.h
    platform/ios/LocalizedDeviceModel.h
    platform/ios/PlatformEventFactoryIOS.h
    # MAVERICKS_BACKPORT: export additional playback-session/video-presentation interface headers.
    platform/ios/PlaybackSessionInterfaceAVKitLegacy.h
    platform/ios/PlaybackSessionInterfaceIOS.h
    platform/ios/PlaybackSessionInterfaceTVOS.h
    platform/ios/QuickLook.h
    platform/ios/TileControllerMemoryHandlerIOS.h
    platform/ios/UIViewControllerUtilities.h
    platform/ios/VideoPresentationInterfaceAVKitLegacy.h
    platform/ios/VideoPresentationInterfaceIOS.h
    platform/ios/VideoPresentationInterfaceTVOS.h
    # MAVERICKS_BACKPORT: export the remaining platform/ios shared headers referenced by the WK build.
    platform/ios/WebBackgroundTaskController.h
    platform/ios/WebCoreMotionManager.h
    platform/ios/WebEvent.h
    platform/ios/WebEventPrivate.h
    platform/ios/WebItemProviderPasteboard.h
    platform/ios/WebSQLiteDatabaseTrackerClient.h
    platform/ios/WebVideoFullscreenControllerAVKit.h
    # MAVERICKS_BACKPORT: export the full WAK/WebThread header set (WAK*/WK*/WebCoreThread*) the WK build needs.
    platform/ios/wak/WAKAppKitStubs.h
    platform/ios/wak/WAKClipView.h
    platform/ios/wak/WAKResponder.h
    platform/ios/wak/WAKScrollView.h
    platform/ios/wak/WAKView.h
    platform/ios/wak/WAKWindow.h
    platform/ios/wak/WKContentObservation.h
    platform/ios/wak/WKGraphics.h
    platform/ios/wak/WKTypes.h
    platform/ios/wak/WKUtilities.h
    platform/ios/wak/WKView.h
    platform/ios/wak/WKViewPrivate.h
    platform/ios/wak/WebCoreThread.h
    platform/ios/wak/WebCoreThreadInternal.h
    platform/ios/wak/WebCoreThreadMessage.h
    # MAVERICKS_BACKPORT: export WebCoreThreadSystemInterface.h (part of the WAK/WebThread headers built here).
    platform/ios/wak/WebCoreThreadSystemInterface.h
    # MAVERICKS_BACKPORT: export VideoPresentationInterfaceMac.h (video presentation/fullscreen path).
    platform/mac/VideoPresentationInterfaceMac.h
    # MAVERICKS_BACKPORT: WebNSAttributedStringExtras.h lives under platform/cocoa here (upstream path is platform/mac).
    platform/cocoa/WebNSAttributedStringExtras.h
    # MAVERICKS_BACKPORT: export BaseAudioMediaStreamTrackRendererUnit.h (shared base for the audio renderer unit).
    platform/mediastream/cocoa/BaseAudioMediaStreamTrackRendererUnit.h
    # MAVERICKS_BACKPORT: export the mac capture-source headers (getUserMedia camera/audio/screen capture).
    platform/mediastream/mac/AVVideoCaptureSource.h
    platform/mediastream/mac/BaseAudioCaptureUnit.h
    platform/mediastream/mac/CoreAudioCaptureDeviceManager.h
    platform/mediastream/mac/CoreAudioCaptureSource.h
    platform/mediastream/mac/CoreAudioCaptureUnit.h
    # MAVERICKS_BACKPORT: export the ScreenCaptureKit capture headers.
    platform/mediastream/mac/ScreenCaptureKitCaptureSource.h
    platform/mediastream/mac/ScreenCaptureKitSharingSessionManager.h
    # MAVERICKS_BACKPORT: export RangeResponseGenerator.h (byte-range media response handling).
    platform/network/cocoa/RangeResponseGenerator.h
    # MAVERICKS_BACKPORT: export WebRTCVideoDecoder.h (GStreamer/WebRTC video-codecs path).
    platform/video-codecs/cocoa/WebRTCVideoDecoder.h
    # MAVERICKS_BACKPORT: export RenderThemeMac.h (restored Aqua form-control theme; needed by the WK build).
    rendering/mac/RenderThemeMac.h
)

list(APPEND WebCore_PRIVATE_INCLUDE_DIRECTORIES
    "${WEBCORE_DIR}/crypto/gcrypt"
    # MAVERICKS_BACKPORT: crypto/cocoa header dir for CryptoUtilitiesCocoa.h — still needed by the WebRTC
    # SFrame transformer (CommonCrypto AES-CTR helper), distinct from the libgcrypt WebCrypto impl.
    "${WEBCORE_DIR}/crypto/cocoa"
    # MAVERICKS_BACKPORT: libgcrypt/libtasn1/libgpg-error built in-tree by
    # MavericksSupport/deps/build_deps.sh; see [[project_webcrypto_cc_stubs_stripped]]
    # for the prior CommonCrypto approach that's now retired.
    "${MAVERICKS_DEPS}/include"
    # MAVERICKS_BACKPORT: upstream's CMake lists platform/graphics/mac but not its controls/ subdirectory
    # (nor the two directories below), so a bare `#import "ImageControlsButtonMac.h"` (RenderThemeMac.mm,
    # ControlFactoryMac.mm) does not resolve on the CMake port -- Apple builds this tree with Xcode, whose
    # header maps make every header reachable by basename regardless of directory. Nothing 10.9-specific;
    # it is a gap in the CMake port that only shows once ENABLE(SERVICE_CONTROLS) compiles those includes.
    #
    # Add the directories rather than keeping flat-path DUPLICATES of the headers in Source/WebCore/, which
    # was the previous workaround for all four of ImageControlsButtonMac.h, ControlFactoryCocoa.h,
    # ApplePayAMSUIPaymentHandler.h and LibWebRTCProvider.h. A duplicate header is a second copy that no
    # longer tracks the original, and the ImageControlsButtonMac.h one broke the moment it was first
    # compiled: the copy sits outside controls/, so its own `#import "ControlMac.h"` sibling include could
    # not resolve. (LibWebRTCProvider.h's real directory was already on this list, so that copy shadowed a
    # perfectly reachable header for no reason.) All four copies are deleted.
    "${WEBCORE_DIR}/platform/graphics/mac/controls"
    "${WEBCORE_DIR}/platform/graphics/cocoa/controls"
    "${WEBCORE_DIR}/Modules/applepay-ams-ui"
    # Same gap, same fix: RenderThemeCocoa.mm resolves a bare `#import "DrawGlyphsRecorder.h"` whose
    # canonical home is platform/graphics/coretext/ (the only entries this file had for that directory
    # were SOURCES, never an include path).
    "${WEBCORE_DIR}/platform/graphics/coretext"
    "${CMAKE_SOURCE_DIR}/MavericksSupport/deps/libwebp/include"
    "${WEBCORE_DIR}/platform/image-decoders"
    "${WEBCORE_DIR}/platform/image-decoders/webp"
    "${MAVERICKS_DEPS}/include"
    "${WEBCORE_DIR}/platform/ios"
    "${LIBWEBM_STAGED_INCLUDE}"
    # libwebm's headers include each other by paths relative to the library root
    # ("common/webmids.h", "mkvmuxer/mkvmuxertypes.h"), which do not resolve against the
    # webm/-prefixed spellings WebKit uses -- so the webm/ subdirectory is on the path too.
    "${LIBWEBM_STAGED_INCLUDE}/webm"
)

list(APPEND WebCore_USER_AGENT_STYLE_SHEETS
    # MAVERICKS_BACKPORT (#68): classic Safari 7 / Mavericks media-controls stylesheet.
    # make-css-file-arrays.pl derives the array name from the basename, so this emits
    # mediaControlsAppleUserAgentStyleSheet, which RenderThemeCocoa serves on the 10.9
    # deployment target instead of ModernMediaControlsUserAgentStyleSheet.
    ${WEBCORE_DIR}/Modules/mediacontrols/mediaControlsApple.css
)

# --------------------------------------------------------------------------
# MAVERICKS_BACKPORT: stale entries in upstream's own PlatformMac.cmake — upstream lists these files
# but ships no file at those paths (moved or deleted upstream without updating the CMake Mac port, the
# same staleness behind its pre-rename VideoFullscreenManager[Proxy] message-file names). Withheld
# here so no file has to exist to satisfy them. Nothing includes any of these headers.
# --------------------------------------------------------------------------
list(REMOVE_ITEM WebCore_PRIVATE_FRAMEWORK_HEADERS
    platform/cocoa/PlatformView.h
    # NOTE: upstream really does list this .mm under the framework-headers variable, not SOURCES.
    platform/cocoa/PublicSuffixCocoa.mm
    platform/graphics/cocoa/MediaPlaybackTargetContext.h
    platform/graphics/mac/SwitchingGPUClient.h
    platform/mac/VideoFullscreenInterfaceMac.h
)

list(REMOVE_ITEM WebCore_SOURCES
    platform/cocoa/RuntimeApplicationChecksCocoa.mm
    platform/graphics/mac/ImageMac.mm
    platform/graphics/mac/IntPointMac.mm
    platform/graphics/mac/IntSizeMac.mm
)

