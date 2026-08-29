# Every backport change to WebCore's Mac CMake configuration.
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
# compile the upstream GStreamer media player (software/appsink path) for the
# Mac/CG port. GStreamer.cmake consumes the GSTREAMER_*/GLib targets set by OptionsMacGStreamer.cmake.
if (USE_GSTREAMER)
    include(platform/GStreamer.cmake)
endif ()

# no SceneKit.framework link. WebCore binds no SceneKit symbols on this
# port (the <model> element's SceneKit backing TUs are stubbed and its runtime pref defaults
# off on Mac), but a hard link records an LC_LOAD_DYLIB that loads the 10.9 system SceneKit
# into every WebKit client at launch. Apps that bundle a newer SceneKit — Xcode 6's editor
# plug-ins reference @rpath/SceneKit and ship v186 in Contents/SharedFrameworks — then get
# the already-loaded 10.9 image (dyld matches the framework's partial path
# SceneKit.framework/Versions/A/SceneKit to the loaded /System copy) instead of their bundled
# one, which lacks 10.10+ classes such as SCNParticlePropertyController, and abort at launch.

# Lookup.framework depends on WebKit.framework, creating a circular dep chain:
# WebCore -> Lookup -> WebKit -> WebKitLegacy -> WebCore
# This causes all frameworks to load simultaneously and crashes the ObjC runtime.
# Do not link Lookup directly. Every use of it in the tree goes through
# SOFT_LINK_PRIVATE_FRAMEWORK_FOR_SOURCE(PAL, Lookup) in PAL/pal/mac/LookupSoftLink.mm, so the
# framework is dlopened on first use and upstream's link line adds nothing but the load command.
# find_library(LOOKUP_FRAMEWORK Lookup HINTS ${CMAKE_OSX_SYSROOT}/System/Library/PrivateFrameworks)
# list(APPEND WebCore_LIBRARIES ${LOOKUP_FRAMEWORK})

# pass bare macro names (no =1) to the CSS value preprocessor; the value-1 form trips the in-tree makeprop/CSS preprocessor here.
set(CSS_VALUE_PLATFORM_DEFINES "WTF_PLATFORM_MAC WTF_PLATFORM_COCOA ENABLE_APPLE_PAY_NEW_BUTTON_TYPES")

# #68: also build the classic Safari 7 / Mavericks media-controls script.
# make-js-file-arrays.py names the array from the basename, emitting mediaControlsAppleJavaScript,
# which RenderThemeCocoa serves on the 10.9 deployment target instead of ModernMediaControlsJavaScript.
set(WebCore_USER_AGENT_SCRIPTS
    ${WebCore_DERIVED_SOURCES_DIR}/ModernMediaControls.js
    ${WEBCORE_DIR}/Modules/mediacontrols/mediaControlsApple.js
)

# WOFF2 web-font decoder (USE_WOFF2=ON). Our modern UA makes Google Fonts/Material
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

# platform/ios holds several files the Mac build genuinely needs once
# ENABLE(VIDEO_PRESENTATION_MODE) is on -- WebAVPlayerController and the PlaybackSessionInterface /
# VideoPresentationInterface family, all of which compile under PLATFORM(COCOA) rather than
# PLATFORM(IOS_FAMILY). platform/cocoa/WebAVPlayerLayer.mm includes "WebAVPlayerController.h" by bare
# name, and VideoPresentationInterfaceMac.mm allocates a WebAVPlayerLayer, so the Mac build needs this
# directory on its header search path. Upstream's Xcode build has every platform subdirectory on the
# search path, which is why it never has to say so; the CMake port lists them individually. Verified no
# filename collisions with platform/mac, platform/cocoa, platform, or platform/graphics/cocoa.

# libwebm headers. The `webm` library target comes from ThirdParty/libwebrtc/CMakeLists.txt, which
# stages its headers flat under ${CMAKE_BINARY_DIR}/libwebrtc/PrivateHeaders/webm/. WebCore also spells
# <webm/common/vp9_header_parser.h> and <webm/mkvmuxer/mkvmuxer.h>, and libwebm's own headers include
# each other relative to the library root ("common/webmids.h", "mkvmuxer/mkvmuxertypes.h"), so both
# layouts are staged here and put on the include path.
set(LIBWEBM_DIR "${THIRDPARTY_DIR}/libwebrtc/Source/third_party/libwebm")
set(LIBWEBM_STAGED_INCLUDE "${CMAKE_BINARY_DIR}/libwebm/Headers")
# The staging below runs at configure time: the glob tracks the header set, the property their contents.
file(GLOB_RECURSE LIBWEBM_HEADERS CONFIGURE_DEPENDS
    "${LIBWEBM_DIR}/webm_parser/include/webm/*"
    "${LIBWEBM_DIR}/mkvmuxer/*.h"
    "${LIBWEBM_DIR}/common/*.h")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS ${LIBWEBM_HEADERS})
file(COPY "${LIBWEBM_DIR}/webm_parser/include/webm" DESTINATION "${LIBWEBM_STAGED_INCLUDE}")
file(COPY "${LIBWEBM_DIR}/mkvmuxer" DESTINATION "${LIBWEBM_STAGED_INCLUDE}/webm"
     FILES_MATCHING PATTERN "*.h")
file(COPY "${LIBWEBM_DIR}/common" DESTINATION "${LIBWEBM_STAGED_INCLUDE}/webm"
     FILES_MATCHING PATTERN "*.h")
file(COPY "${LIBWEBM_DIR}/mkvmuxer" DESTINATION "${LIBWEBM_STAGED_INCLUDE}"
     FILES_MATCHING PATTERN "*.h")
file(COPY "${LIBWEBM_DIR}/common" DESTINATION "${LIBWEBM_STAGED_INCLUDE}"
     FILES_MATCHING PATTERN "*.h")


# re-export /usr/lib/libobjc.A.dylib through WebCore, exactly as stock 10.9 did.
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
    # PlatformMac.cmake lists this beside the .cpp that exists; only the .cpp is in the tree.
    platform/mediastream/mac/RealtimeOutgoingVideoSourceCocoa.mm

    # The AudioToolbox WebCodecs pair. USE(GSTREAMER) wins the backend selection in
    # platform/AudioEncoder.cpp and platform/AudioDecoder.cpp, so nothing calls either class, but their
    # own guard is ENABLE(WEB_CODECS) && USE(AVFOUNDATION) and both are true here. AudioEncoderCocoa
    # calls PlatformRawAudioDataCocoa::sampleBuffer(), whose TU is withheld below because its
    # PlatformRawAudioData factories duplicate PlatformRawAudioDataGStreamer.cpp's. Upstream lists these
    # two in SourcesCocoa.txt as well; withholding them there alone drops their HEADER_FILE_ONLY marking
    # and hands them to this list to compile standalone.
    platform/audio/cocoa/AudioDecoderCocoa.cpp
    platform/audio/cocoa/AudioEncoderCocoa.cpp
)


# --------------------------------------------------------------------------
# Source-list entries withheld from and added to upstream's Sources*.txt
# (MAVERICKS_FILTER_SOURCE_LIST, from cmake/MavericksSourceLists.cmake).
# --------------------------------------------------------------------------

# Withheld from SourcesCocoa.txt: replaced by the GCrypt/OpenSSL crypto backend, superseded by the
# GStreamer backend this port selects for media and WebCodecs, or built on frameworks, SPI and
# languages this deployment target and toolchain do not have.
set(MAVERICKS_WITHHELD_COCOA_SOURCES
    "JSApplePayDisbursementRequest.cpp"
    "crypto/cocoa/CommonCryptoDERUtilities.cpp"
    "crypto/cocoa/CryptoAlgorithmAESCBCCocoa.cpp"
    "crypto/cocoa/CryptoAlgorithmAESCFBCocoa.cpp"
    "crypto/cocoa/CryptoAlgorithmAESCTRCocoa.cpp"
    "crypto/cocoa/CryptoAlgorithmAESGCMCocoa.cpp"
    "crypto/cocoa/CryptoAlgorithmAESKWCocoa.cpp"
    "crypto/cocoa/CryptoAlgorithmECDHCocoa.cpp"
    "crypto/cocoa/CryptoAlgorithmECDSACocoa.cpp"
    "crypto/cocoa/CryptoAlgorithmEd25519Cocoa.cpp"
    "crypto/cocoa/CryptoAlgorithmHKDFCocoa.cpp"
    "crypto/cocoa/CryptoAlgorithmHMACCocoa.cpp"
    "crypto/cocoa/CryptoAlgorithmPBKDF2Cocoa.cpp"
    "crypto/cocoa/CryptoAlgorithmRSASSA_PKCS1_v1_5Cocoa.cpp"
    "crypto/cocoa/CryptoAlgorithmRSA_OAEPCocoa.cpp"
    "crypto/cocoa/CryptoAlgorithmRSA_PSSCocoa.cpp"
    "crypto/cocoa/CryptoAlgorithmRegistryCocoa.cpp"
    "crypto/cocoa/CryptoAlgorithmX25519Cocoa.cpp"
    "crypto/cocoa/CryptoKeyECCocoa.cpp"
    "crypto/cocoa/CryptoKeyOKPCocoa.cpp"
    "crypto/cocoa/CryptoKeyRSACocoa.cpp"
    "crypto/CommonCryptoUtilities.cpp"
    "html/canvas/GPUCanvasContextCocoa.mm @nonARC"
    "html/canvas/UsdModelLoader.swift"
    "platform/audio/cocoa/AudioDecoderCocoa.cpp"
    "platform/audio/cocoa/AudioEncoderCocoa.cpp"
    "platform/audio/cocoa/PlatformRawAudioDataCocoa.cpp"
    "platform/cocoa/CoreLocationGeolocationProvider.mm @nonARC"
    "platform/graphics/avfoundation/objc/SourceBufferParserAVFObjC.mm @nonARC @no-unify"
    "platform/ios/PlaybackSessionInterfaceAVKitLegacy.mm @nonARC @no-unify"
    "platform/ios/PlaybackSessionInterfaceIOS.mm @nonARC @no-unify"
    "platform/ios/WebAVPlayerController.mm @nonARC"
)

# Withheld from SourcesGStreamer.txt: the GStreamer flavor of the libwebrtc glue (its
# LibWebRTCProviderGStreamer.cpp defines the same WebRTCProvider::create as LibWebRTCProviderCocoa.cpp),
# and the GStreamer capture stack -- RealtimeMediaSourceCenterGStreamer.cpp and
# MediaStreamAudioSourceGStreamer.cpp define the same symbols as the Cocoa TUs, and the GStreamer mock
# capture sources define the MockRealtime*Source::create the Cocoa mocks define. The GStreamer capture
# sources, capturers and device managers stay compiled: RealtimeMediaSourceCenterMac selects the Cocoa
# factories, so they are never instantiated, while the GStreamer player's audio-output selection and
# GStreamerCommon's teardown call into GStreamerCaptureDeviceManager, which needs the rest of them.
set(MAVERICKS_WITHHELD_GSTREAMER_SOURCES
    "Modules/mediastream/RTCRtpSFrameTransformerOpenSSL.cpp"
    "platform/mediastream/libwebrtc/gstreamer/GStreamerVideoCommon.cpp"
    "platform/mediastream/libwebrtc/gstreamer/GStreamerVideoDecoderFactory.cpp"
    "platform/mediastream/libwebrtc/gstreamer/GStreamerVideoEncoderFactory.cpp"
    "platform/mediastream/libwebrtc/gstreamer/GStreamerVideoFrameLibWebRTC.cpp"
    "platform/mediastream/libwebrtc/gstreamer/LibWebRTCProviderGStreamer.cpp"
    "platform/mediastream/libwebrtc/gstreamer/RealtimeIncomingAudioSourceLibWebRTC.cpp"
    "platform/mediastream/libwebrtc/gstreamer/RealtimeIncomingVideoSourceLibWebRTC.cpp"
    "platform/mediastream/libwebrtc/gstreamer/RealtimeOutgoingAudioSourceLibWebRTC.cpp"
    "platform/mediastream/libwebrtc/gstreamer/RealtimeOutgoingVideoSourceLibWebRTC.cpp"
    "platform/mediastream/gstreamer/MockDisplayCaptureSourceGStreamer.cpp"
    "platform/mediastream/gstreamer/MockRealtimeAudioSourceGStreamer.cpp"
    "platform/mediastream/gstreamer/MockRealtimeVideoSourceGStreamer.cpp"
    "Modules/webaudio/MediaStreamAudioSourceGStreamer.cpp"
    "platform/mediastream/gstreamer/RealtimeMediaSourceCenterGStreamer.cpp"
)

# Added to SourcesCocoa.txt: the GCrypt crypto backend that replaces the withheld CommonCrypto one,
# this port's own glue TU, and Cocoa TUs upstream builds only from WebCore.xcodeproj. Lines are copied
# verbatim, so @nonARC / @no-unify are preserved.
set(MAVERICKS_ADDED_COCOA_SOURCES
    # upstream builds this only from WebCore.xcodeproj (SourcesCocoa.txt lists just the .cpp); its
    # HAVE(AVAUDIOAPPLICATION)/HAVE(VOICEACTIVITYDETECTION) branches compile out below macOS 14.
    "platform/mediastream/mac/CoreAudioCaptureUnit.mm @nonARC"
    "crypto/gcrypt/CryptoAlgorithmAESCBCGCrypt.cpp"
    "crypto/gcrypt/CryptoAlgorithmAESCFBGCrypt.cpp"
    "crypto/gcrypt/CryptoAlgorithmAESCTRGCrypt.cpp"
    "crypto/gcrypt/CryptoAlgorithmAESGCMGCrypt.cpp"
    "crypto/gcrypt/CryptoAlgorithmAESKWGCrypt.cpp"
    "crypto/gcrypt/CryptoAlgorithmECDHGCrypt.cpp"
    "crypto/gcrypt/CryptoAlgorithmECDSAGCrypt.cpp"
    "crypto/gcrypt/CryptoAlgorithmEd25519GCrypt.cpp"
    "crypto/gcrypt/CryptoAlgorithmHKDFGCrypt.cpp"
    "crypto/gcrypt/CryptoAlgorithmHMACGCrypt.cpp"
    "crypto/gcrypt/CryptoAlgorithmPBKDF2GCrypt.cpp"
    "crypto/gcrypt/CryptoAlgorithmRSASSA_PKCS1_v1_5GCrypt.cpp @no-unify"
    "crypto/gcrypt/CryptoAlgorithmRSA_OAEPGCrypt.cpp @no-unify"
    "crypto/gcrypt/CryptoAlgorithmRSA_PSSGCrypt.cpp @no-unify"
    "crypto/gcrypt/CryptoAlgorithmRegistryGCrypt.cpp"
    "crypto/gcrypt/CryptoAlgorithmX25519GCrypt.cpp"
    "crypto/gcrypt/CryptoKeyECGCrypt.cpp"
    "crypto/gcrypt/CryptoKeyOKPGCrypt.cpp"
    "crypto/gcrypt/CryptoKeyRSAGCrypt.cpp"
    "crypto/gcrypt/GCryptRFC7748.cpp"
    "crypto/gcrypt/GCryptRFC8032.cpp"
    "crypto/gcrypt/GCryptUtilities.cpp"
    "platform/audio/cocoa/AudioSessionCocoa.mm @nonARC"
    "platform/graphics/avfoundation/objc/QueuedVideoOutput.mm"
    "platform/graphics/cocoa/MediaPlayerEnumsCocoa.mm"
    "platform/graphics/cocoa/TextTransformCocoa.cpp"
    "platform/image-decoders/webp/WEBPImageDecoder.cpp"
    "platform/mac/WebCoreView.mm @nonARC"
    "platform/graphics/cocoa/ANGLEUtilitiesCocoa.mm @nonARC @no-unify"
)

# Added to SourcesGStreamer.txt: the CoreGraphics/Cocoa halves of the GStreamer player that upstream's
# GTK/WPE-oriented list does not carry, plus the SourcesGLib.txt entries the GStreamer set calls into
# (GStreamerDataChannelHandler delivers binary datachannel messages via SharedBuffer::create(GBytes*)).
set(MAVERICKS_ADDED_GSTREAMER_SOURCES
    "platform/glib/ApplicationGLib.cpp"
    "platform/glib/SharedBufferGlib.cpp"
    "platform/graphics/gstreamer/ImageGStreamerCG.cpp"
)

set(MAVERICKS_WITHHELD_WEBCORE_SOURCES "")

# Added to Sources.txt: WEB_AUTHN and DASHBOARD_SUPPORT are on for this port, so the sources behind
# AuthenticationExtensionsClientInputs/Outputs and CSSDashboardRegionValue are built. BeforeLoadEvent
# (the restored beforeload event uBlock's network blocking uses) and TextListParser compile standalone.
set(MAVERICKS_ADDED_WEBCORE_SOURCES
    "Modules/webauthn/AuthenticationExtensionsClientInputs.cpp"
    "Modules/webauthn/AuthenticationExtensionsClientOutputs.cpp"
    "css/CSSDashboardRegionValue.cpp"
    "dom/BeforeLoadEvent.cpp @no-unify"
    "editing/TextListParser.cpp @no-unify"
)

MAVERICKS_FILTER_SOURCE_LIST("${WEBCORE_DIR}" WebCore_UNIFIED_SOURCE_LIST_FILES "Sources.txt" MAVERICKS_WITHHELD_WEBCORE_SOURCES MAVERICKS_ADDED_WEBCORE_SOURCES)
# the WebCore sources this backport wrote itself, kept with the rest of the 10.9
# glue -- ${MAVERICKS_SUPPORT}/source mirrors the Source/ path each one plugs into. The GStreamer pair
# video layer follows the same USE_GSTREAMER condition as the list it sits beside. Sources that ride
# in a unified bundle stay in Source/, where their list position decides which files share a bundle.
list(APPEND WebCore_SOURCES
    ${MAVERICKS_SUPPORT}/source/WebCore/platform/cocoa/MavericksBackportWebCoreGlue.mm
)
if (USE_GSTREAMER)
    list(APPEND WebCore_PRIVATE_INCLUDE_DIRECTORIES "${MAVERICKS_SUPPORT}/source/WebCore/platform/graphics/gstreamer")
    list(APPEND WebCore_SOURCES
        ${MAVERICKS_SUPPORT}/source/WebCore/platform/graphics/gstreamer/VideoLayerGStreamerCocoa.mm
        ${MAVERICKS_SUPPORT}/source/WebCore/platform/graphics/gstreamer/VideoFrameGStreamerCocoa.mm
    )
endif ()

MAVERICKS_FILTER_SOURCE_LIST("${WEBCORE_DIR}" WebCore_UNIFIED_SOURCE_LIST_FILES "SourcesCocoa.txt" MAVERICKS_WITHHELD_COCOA_SOURCES MAVERICKS_ADDED_COCOA_SOURCES)
MAVERICKS_FILTER_SOURCE_LIST("${WEBCORE_DIR}" WebCore_UNIFIED_SOURCE_LIST_FILES "platform/SourcesGStreamer.txt" MAVERICKS_WITHHELD_GSTREAMER_SOURCES MAVERICKS_ADDED_GSTREAMER_SOURCES)

# --------------------------------------------------------------------------
# Entries added to upstream's lists.
# --------------------------------------------------------------------------
list(APPEND WebCoreTestSupport_SOURCES
    # WebKitTestRunner's UIScriptController and AccessibilityUIElementMac call
    # WebCoreTestSupport::serializationForCSS(NSColor *), but this source was missing from the Mac
    # WebCoreTestSupport build, leaving the symbol undefined when linking WebKitTestRunner.
    testing/cocoa/CocoaColorSerialization.mm
)

list(APPEND WebCore_IDL_FILES
    # also generate the ApplePayDisbursementRequest IDL binding.
    Modules/applepay/ApplePayDisbursementRequest.idl

    # the Remote Playback partial interface, which adds `remote` and
    # `disableRemotePlayback` to HTMLMediaElement. DerivedSources.make lists it and CMakeLists.txt does
    # not, so the CMake port builds RemotePlayback.idl and RemotePlayback.cpp but exposes no way to
    # reach them -- same shape as the ENABLE_MEDIA_RECORDER gap in OptionsMacMavericks.cmake. Without
    # `disableRemotePlayback` a page cannot satisfy HTMLMediaElement::deferredMediaSourceOpenCanProgress
    # (ManagedMediaSourceNeedsAirPlay defaults true on Mac), so a ManagedMediaSource never leaves
    # "closed" and every player that prefers it -- dash.js 5 among them -- stalls before addSourceBuffer.
    Modules/remoteplayback/HTMLMediaElement+RemotePlayback.idl
)

# definitions upstream compiles only from WebCore.xcodeproj and never added to a CMake
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
)

list(APPEND WebCore_LIBRARIES
    "${MAVERICKS_DEPS}/lib/libwebpdemux.a"
    "${MAVERICKS_DEPS}/lib/libwebp.a"
    "${MAVERICKS_DEPS}/lib/libsharpyuv.a"
    # libavif for the AVIFImageDecoder (USE_AVIF). It decodes AV1 through
    # the same libdav1d the media stack loads, so the process carries one AV1 decoder; that
    # dylib's @rpath install name is repointed at the deployed copy by stage-frameworks.sh.
    "${MAVERICKS_DEPS}/lib/libavif.a"
    # The unversioned symlink, not the majored name: it records @rpath/libdav1d.7.dylib as the
    # load command either way, and this keeps dav1d's SOVERSION out of a second file.
    "${MAVERICKS_DEPS}/lib/libdav1d.dylib"
    "${MAVERICKS_DEPS}/lib/libgcrypt.a"
    "${MAVERICKS_DEPS}/lib/libtasn1.a"
    "${MAVERICKS_DEPS}/lib/libgpg-error.a"
)

list(APPEND WebCore_PRIVATE_FRAMEWORK_HEADERS
    # export PlatformDynamicRangeLimitCocoa.h — the CADynamicRange limit helper
    # WebViewImpl.mm imports as <WebCore/PlatformDynamicRangeLimitCocoa.h>. Upstream's Xcode build finds
    # it by basename; the CMake port stages private headers by explicit list, so it must be named here.
    platform/graphics/ca/cocoa/PlatformDynamicRangeLimitCocoa.h
    # export NSURLUtilities.h — the restored (un-stubbed) WKShareSheet.mm imports it as
    # <WebCore/NSURLUtilities.h>. Upstream's Xcode build finds it by basename; the CMake port needs it named.
    platform/cocoa/NSURLUtilities.h
    # export TouchEvent.h (touch-event interface header).
    dom/TouchEvent.h
    # export EditingHTMLConverter.h (HTML serialization helper).
    editing/cocoa/EditingHTMLConverter.h
    # export NodeHTMLConverter.h and TextAttachmentForSerialization.h (HTML/attachment serialization).
    editing/cocoa/NodeHTMLConverter.h
    editing/cocoa/TextAttachmentForSerialization.h
    # export ContentChangeObserver.h and DOMTimerHoldingTank.h (page/cocoa observers).
    page/cocoa/ContentChangeObserver.h
    page/cocoa/DOMTimerHoldingTank.h
    # export WebTextIndicatorLayer.h (text-indicator layer).
    page/cocoa/WebTextIndicatorLayer.h
    # export CorrectionIndicator.h (autocorrection indicator UI).
    page/mac/CorrectionIndicator.h
    # export ScrollerMac.h/ScrollerPairMac.h (mac overlay-scroller painting).
    page/scrolling/mac/ScrollerMac.h
    page/scrolling/mac/ScrollerPairMac.h
    # export ScrollingTreePluginScrollingNodeMac.h.
    page/scrolling/mac/ScrollingTreePluginScrollingNodeMac.h
    # export WebCoreMainThread.h (main-thread helper) ahead of the platform headers.
    platform/WebCoreMainThread.h
    # export AudioUtilitiesCocoa.h and SpatialAudioExperienceHelper.h (audio helpers).
    platform/audio/cocoa/AudioUtilitiesCocoa.h
    platform/audio/cocoa/SpatialAudioExperienceHelper.h
    # export additional platform/cocoa headers (visual-effect/view/geolocation/CoreVideo) the WK build references.
    platform/cocoa/AppleVisualEffect.h
    platform/cocoa/CocoaView.h
    platform/cocoa/CocoaWritingToolsTypes.h
    platform/cocoa/CoreLocationGeolocationProvider.h
    platform/cocoa/CoreVideoExtras.h
    # export the ParentalControls content/URL-filter headers + PlatformTextAlternatives.h.
    platform/cocoa/ParentalControlsContentFilter.h
    platform/cocoa/ParentalControlsURLFilter.h
    platform/cocoa/ParentalControlsURLFilterParameters.h
    platform/cocoa/PlatformTextAlternatives.h
    # export the video-presentation/fullscreen + WebKitAvailability cocoa headers the WK build references.
    platform/cocoa/VideoFullscreenCaptions.h
    platform/cocoa/VideoPresentationLayerProvider.h
    platform/cocoa/VideoPresentationModel.h
    platform/cocoa/VideoPresentationModelVideoElement.h
    platform/cocoa/WebAVPlayerLayer.h
    platform/cocoa/WebAVPlayerLayerView.h
    platform/cocoa/WebKitAvailability.h
    # GameControllerSPI.h is a Private framework header in the Xcode project
    # (so <WebCore/GameControllerSPI.h> resolves there) but the CMake port omits it from the copy
    # list; ENABLE(GAMEPAD) is ON for this port, so it must be forwarded like the other SPI headers.
    platform/gamepad/cocoa/GameControllerSPI.h
    # export MediaPlaybackTargetWirelessPlayback.h (wireless playback target type).
    platform/graphics/MediaPlaybackTargetWirelessPlayback.h
    # export MediaPlayerPrivateAVFoundation.h (base AVFoundation media player).
    platform/graphics/avfoundation/MediaPlayerPrivateAVFoundation.h
    # AudioVideoRendererAVFObjC.h (exported just above) includes
    # <WebCore/WebAVSampleBufferListener.h>, so the forwarded copy needs its dependency forwarded too.
    # Upstream's Xcode build resolves it through header maps and never needs the explicit entry.
    platform/graphics/avfoundation/WebAVSampleBufferListener.h
    # export PlatformCALayerDelegatedContents.h and ContentsFormatCocoa.h (CA layer contents/format).
    platform/graphics/ca/PlatformCALayerDelegatedContents.h
    platform/graphics/ca/cocoa/ContentsFormatCocoa.h
    # export CGWindowUtilities.h (CGS window helpers).
    platform/graphics/cg/CGWindowUtilities.h
    # export IOSurfacePoolIdentifier.h.
    platform/graphics/cg/IOSurfacePoolIdentifier.h
    # export ImageBufferCGPDFDocumentBackend.h (CG PDF-document image buffer backend).
    platform/graphics/cg/ImageBufferCGPDFDocumentBackend.h
    # export ImageDecoderCG.h (CG image decoder).
    platform/graphics/cg/ImageDecoderCG.h
    # export PathCG.h (CG path helpers).
    platform/graphics/cg/PathCG.h
    # export AV1UtilitiesCocoa.h (AV1 codec utility helpers).
    platform/graphics/cocoa/AV1UtilitiesCocoa.h
    # export DynamicContentScalingDisplayList.h.
    platform/graphics/cocoa/DynamicContentScalingDisplayList.h
    # export additional graphics/cocoa headers (font/HEVC/media-enum/presentation) the WK build references.
    platform/graphics/cocoa/FontCascadeCocoaInlines.h
    platform/graphics/cocoa/HEVCUtilitiesCocoa.h
    platform/graphics/cocoa/IOSurfaceDrawingBuffer.h
    platform/graphics/cocoa/MediaPlayerEnumsCocoa.h
    platform/graphics/cocoa/NullPlaybackSessionInterface.h
    platform/graphics/cocoa/NullVideoPresentationInterface.h
    platform/graphics/cocoa/SystemFontDatabaseCoreText.h
    platform/graphics/cocoa/TextTrackRepresentationCocoa.h
    # export VideoTargetFactory.h (video presentation target creation).
    platform/graphics/cocoa/VideoTargetFactory.h
    # export AppKitControlSystemImage.h (AppKit control system-image drawing).
    platform/graphics/mac/AppKitControlSystemImage.h
    # export ScrollbarTrackCornerSystemImageMac.h (scrollbar corner system image).
    platform/graphics/mac/ScrollbarTrackCornerSystemImageMac.h
    # export the platform/ios headers the WK build references (shared iOS-named types/stubs).
    platform/ios/AbstractPasteboard.h
    platform/ios/DeviceOrientationUpdateProvider.h
    platform/ios/KeyEventCodesIOS.h
    platform/ios/LegacyTileCache.h
    platform/ios/LocalCurrentTraitCollection.h
    platform/ios/LocalizedDeviceModel.h
    platform/ios/PlatformEventFactoryIOS.h
    # export additional playback-session/video-presentation interface headers.
    platform/ios/PlaybackSessionInterfaceAVKitLegacy.h
    platform/ios/PlaybackSessionInterfaceIOS.h
    platform/ios/PlaybackSessionInterfaceTVOS.h
    platform/ios/QuickLook.h
    platform/ios/TileControllerMemoryHandlerIOS.h
    platform/ios/UIViewControllerUtilities.h
    platform/ios/VideoPresentationInterfaceAVKitLegacy.h
    platform/ios/VideoPresentationInterfaceIOS.h
    platform/ios/VideoPresentationInterfaceTVOS.h
    # export the remaining platform/ios shared headers referenced by the WK build.
    platform/ios/WebBackgroundTaskController.h
    platform/ios/WebCoreMotionManager.h
    platform/ios/WebEvent.h
    platform/ios/WebEventPrivate.h
    platform/ios/WebItemProviderPasteboard.h
    platform/ios/WebSQLiteDatabaseTrackerClient.h
    platform/ios/WebVideoFullscreenControllerAVKit.h
    # export the full WAK/WebThread header set (WAK*/WK*/WebCoreThread*) the WK build needs.
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
    # export WebCoreThreadSystemInterface.h (part of the WAK/WebThread headers built here).
    platform/ios/wak/WebCoreThreadSystemInterface.h
    # export VideoPresentationInterfaceMac.h (video presentation/fullscreen path).
    platform/mac/VideoPresentationInterfaceMac.h
    # WebNSAttributedStringExtras.h lives under platform/cocoa here (upstream path is platform/mac).
    platform/cocoa/WebNSAttributedStringExtras.h
    # export BaseAudioMediaStreamTrackRendererUnit.h (shared base for the audio renderer unit).
    platform/mediastream/cocoa/BaseAudioMediaStreamTrackRendererUnit.h
    # export the mac capture-source headers (getUserMedia camera/audio/screen capture).
    platform/mediastream/mac/AVVideoCaptureSource.h
    platform/mediastream/mac/BaseAudioCaptureUnit.h
    platform/mediastream/mac/CoreAudioCaptureDeviceManager.h
    platform/mediastream/mac/CoreAudioCaptureSource.h
    platform/mediastream/mac/CoreAudioCaptureUnit.h
    # export the ScreenCaptureKit capture headers.
    platform/mediastream/mac/ScreenCaptureKitCaptureSource.h
    platform/mediastream/mac/ScreenCaptureKitSharingSessionManager.h
    # export RangeResponseGenerator.h (byte-range media response handling).
    platform/network/cocoa/RangeResponseGenerator.h
    # export WebRTCVideoDecoder.h (libwebrtc video-codecs path).
    platform/video-codecs/cocoa/WebRTCVideoDecoder.h
    # export RenderThemeMac.h (restored Aqua form-control theme; needed by the WK build).
    rendering/mac/RenderThemeMac.h
)

list(APPEND WebCore_PRIVATE_INCLUDE_DIRECTORIES
    "${WEBCORE_DIR}/crypto/gcrypt"
    # crypto/cocoa header dir for CryptoUtilitiesCocoa.h — still needed by the WebRTC
    # SFrame transformer (CommonCrypto AES-CTR helper), distinct from the libgcrypt WebCrypto impl.
    "${WEBCORE_DIR}/crypto/cocoa"
    # headers for everything MavericksSupport/deps/build_deps.sh builds
    # that WebCore compiles against — libgcrypt/libtasn1/libgpg-error (WebCrypto), brotli,
    # woff2, libwebp, libavif, libxml2.
    "${MAVERICKS_DEPS}/include"
    # upstream's CMake lists platform/graphics/mac but not its controls/ subdirectory
    # (nor the two directories below), so a bare `#import "ImageControlsButtonMac.h"` (RenderThemeMac.mm,
    # ControlFactoryMac.mm) does not resolve on the CMake port -- Apple builds this tree with Xcode, whose
    # header maps make every header reachable by basename regardless of directory. Nothing 10.9-specific;
    # it is a gap in the CMake port that only shows once ENABLE(SERVICE_CONTROLS) compiles those includes.
    #
    # Name the directories rather than keeping flat-path copies of the headers in Source/WebCore/: a copy
    # does not track the original, and one that sits outside its own directory cannot resolve its sibling
    # includes (ImageControlsButtonMac.h `#import "ControlMac.h"`).
    "${WEBCORE_DIR}/platform/graphics/mac/controls"
    "${WEBCORE_DIR}/platform/graphics/cocoa/controls"
    "${WEBCORE_DIR}/Modules/applepay-ams-ui"
    # Same gap, same fix: RenderThemeCocoa.mm resolves a bare `#import "DrawGlyphsRecorder.h"` whose
    # canonical home is platform/graphics/coretext/ (the only entries this file had for that directory
    # were SOURCES, never an include path).
    "${WEBCORE_DIR}/platform/graphics/coretext"
    "${WEBCORE_DIR}/platform/image-decoders"
    "${WEBCORE_DIR}/platform/image-decoders/webp"
    # USE_AVIF is ON here, so ScalableImageDecoder.cpp resolves a bare
    # `#include "AVIFImageDecoder.h"`. Upstream's Mac build never compiles that branch.
    "${WEBCORE_DIR}/platform/image-decoders/avif"
    # Same gap: MediaPlayerPrivateGStreamer.cpp resolves a bare `#include "GStreamerMediaStreamSource.h"`
    # from platform/mediastream/gstreamer, and GStreamerCommon.cpp reaches "ApplicationGLib.h" in
    # platform/glib, whose ApplicationGLib.cpp this port builds. Only the GTK and WPE ports list these
    # directories as include paths. No basename in either is reachable from a directory already on this list.
    "${WEBCORE_DIR}/platform/mediastream/gstreamer"
    "${WEBCORE_DIR}/platform/glib"
    "${WEBCORE_DIR}/platform/ios"
    "${LIBWEBM_STAGED_INCLUDE}"
    "${LIBWEBM_STAGED_INCLUDE}/webm"
)

# upstream ships 0-byte husks at accessibility/AXIsolatedTree.{h,cpp} beside the real
# pair in accessibility/isolatedtree/, and lists accessibility first. Xcode's header maps resolve a bare
# `#include "AXIsolatedTree.h"` to the real file; the CMake port resolves it to the husk, so Page.cpp sees
# an incomplete AXIsolatedTree wherever ENABLE_ACCESSIBILITY_ISOLATED_TREE is on -- upstream's CMake ports
# keep it off, so only this port reaches it. Search the real directory first. AXIsolatedTree.h is the one
# basename it carries that any other directory on this list also carries.
list(REMOVE_ITEM WebCore_PRIVATE_INCLUDE_DIRECTORIES "${WEBCORE_DIR}/accessibility/isolatedtree")
list(INSERT WebCore_PRIVATE_INCLUDE_DIRECTORIES 0 "${WEBCORE_DIR}/accessibility/isolatedtree")

# #137: the text-track container and the WebVTT cue display tree are styled by
# modern-media-controls/controls/text-tracks.css, which upstream injects into the media element's shadow
# root together with the rest of ModernMediaControls.css. The classic controls this port serves inject
# nothing, so the sheet is compiled separately and Style::UserAgentStyle adds it at document scope.
# make-css-file-arrays.pl derives the array name from the basename via (\w+)\.css, which stops at the
# hyphen; copy it under a name that yields mediaTextTracksUserAgentStyleSheet.
add_custom_command(
    OUTPUT ${WebCore_DERIVED_SOURCES_DIR}/mediaTextTracks.css
    DEPENDS ${WEBCORE_DIR}/Modules/modern-media-controls/controls/text-tracks.css
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        ${WEBCORE_DIR}/Modules/modern-media-controls/controls/text-tracks.css
        ${WebCore_DERIVED_SOURCES_DIR}/mediaTextTracks.css
    VERBATIM)

list(APPEND WebCore_USER_AGENT_STYLE_SHEETS
    # #68: classic Safari 7 / Mavericks media-controls stylesheet.
    # make-css-file-arrays.pl derives the array name from the basename, so this emits
    # mediaControlsAppleUserAgentStyleSheet, which RenderThemeCocoa serves on the 10.9
    # deployment target instead of ModernMediaControlsUserAgentStyleSheet.
    ${WEBCORE_DIR}/Modules/mediacontrols/mediaControlsApple.css
    ${WebCore_DERIVED_SOURCES_DIR}/mediaTextTracks.css
)

# --------------------------------------------------------------------------
# stale entries in upstream's own PlatformMac.cmake — upstream lists these files
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


# upstream's 5051d18 moved TextIndicatorWindow to WebKitLegacy but left both files
# in PlatformMac.cmake's lists, so the CMake Mac port names two paths WebCore no longer ships.
list(REMOVE_ITEM WebCore_SOURCES page/mac/TextIndicatorWindow.mm)
list(REMOVE_ITEM WebCore_PRIVATE_FRAMEWORK_HEADERS page/mac/TextIndicatorWindow.h)
