# Every change this port makes to Source/ThirdParty/libwebrtc/CMakeLists.txt, which is the GTK and
# WPE ports' CMake for a library Cocoa builds from libwebrtc.xcodeproj instead. That file calls the
# macros below at the points its own lists and targets are built; macros rather than functions,
# because each one edits a list variable in its caller's scope.

# mkvmuxer.cc constructs mkvmuxer::MkvWriter for Segment's chunked writers (mkvmuxer.cc:3641).
macro(MAVERICKS_LIBWEBRTC_WEBM_SOURCES)
    list(APPEND webm_SOURCES Source/third_party/libwebm/mkvmuxer/mkvwriter.cc)
endmacro()

macro(MAVERICKS_LIBWEBRTC_ADD_TARGET)
    # This list is not what libwebrtc.xcodeproj builds. The vendored SDK lives at
    # Source/webrtc/webkit_sdk (webkit.org/b/277146 renamed it from sdk); h265_vps_sps_pps_tracker.cc
    # is gone (h26x_packet_buffer.cc, which the list has, covers H.264 and H.265). Test, tool, demo and
    # fake TUs carry main()s and reference test-only symbols; the Windows task-queue factory defines the
    # same symbol as the stdlib one; RtcEventLogImpl needs the protobuf encoders and is only constructed
    # under WEBRTC_ENABLE_RTC_EVENT_LOG; the ALSA audio device module is Linux-only; the three x86_64
    # perlasm regenerations duplicate the checked-in gen/crypto/*-apple.S. The abseil TUs and the ObjC
    # SDK TUs appended below (RTCEncodedImage+Private's -nativeEncodedImage and
    # -initWithNativeEncodedImage:, which objc_video_encoder_factory.mm's completion block and the
    # decoder send on every frame; the AV1 codec classes and frame reorder queue the H.264/H.265 decoders and
    # the default factories use; h264.cc, whose H264Decoder::Create the internal decoder factory calls
    # and which the list has only in its non-Apple branch; gcd_helpers.m behind task_queue_gcd.cc) are
    # referenced by listed members but absent from the list.
    string(REPLACE "Source/webrtc/sdk/" "Source/webrtc/webkit_sdk/" webrtc_SOURCES "${webrtc_SOURCES}")
    list(REMOVE_ITEM webrtc_SOURCES Source/webrtc/modules/video_coding/h265_vps_sps_pps_tracker.cc)
    list(FILTER webrtc_SOURCES EXCLUDE REGEX "/audio_device/linux/|/fake_[a-z0-9_]+\\.cc$|_testing(_common)?\\.cc$|_unittest\\.cc$|_test\\.cc$|(^|/)test/|/tools/|/rtc_tools/|/testdata/|/virtual_socket_server\\.cc$|/compute_interpolated_gain_curve\\.cc$|/corruption_detection/evaluation/|/bwe_rtp\\.cc$|/video_loopback_main\\.cc$|/print_hash_of\\.cc$|/gaussian_distribution_gentables\\.cc$|/boringssl/src/tool/|/bazel-example/|/fipstools/|/libyuv/util/|/default_task_queue_factory_win\\.cc$|/rtc_event_log_impl\\.cc$|(^|/)(chacha/chacha-x86_64|cipher/aes128gcmsiv-x86_64|cipher/chacha20_poly1305_x86_64)-")
    list(APPEND webrtc_SOURCES
        Source/third_party/abseil-cpp/absl/base/internal/tracing.cc
        Source/third_party/abseil-cpp/absl/crc/crc32c.cc
        Source/third_party/abseil-cpp/absl/crc/internal/cpu_detect.cc
        Source/third_party/abseil-cpp/absl/crc/internal/crc.cc
        Source/third_party/abseil-cpp/absl/crc/internal/crc_cord_state.cc
        Source/third_party/abseil-cpp/absl/crc/internal/crc_memcpy_fallback.cc
        Source/third_party/abseil-cpp/absl/crc/internal/crc_memcpy_x86_arm_combined.cc
        Source/third_party/abseil-cpp/absl/crc/internal/crc_non_temporal_memcpy.cc
        Source/third_party/abseil-cpp/absl/crc/internal/crc_x86_arm_combined.cc
        Source/third_party/abseil-cpp/absl/debugging/internal/decode_rust_punycode.cc
        Source/third_party/abseil-cpp/absl/debugging/internal/demangle_rust.cc
        Source/third_party/abseil-cpp/absl/debugging/internal/utf8_for_code_point.cc
        Source/third_party/abseil-cpp/absl/random/internal/entropy_pool.cc
        Source/third_party/abseil-cpp/absl/status/internal/status_internal.cc
        Source/third_party/abseil-cpp/absl/strings/internal/damerau_levenshtein_distance.cc
        Source/third_party/abseil-cpp/absl/synchronization/internal/kernel_timeout.cc
        Source/third_party/abseil-cpp/absl/synchronization/internal/pthread_waiter.cc
        Source/third_party/abseil-cpp/absl/synchronization/internal/waiter_base.cc
        Source/webrtc/webkit_sdk/objc/api/peerconnection/RTCEncodedImage+Private.mm
        Source/webrtc/webkit_sdk/objc/api/peerconnection/RTCVideoCodecInfo+Private.mm
        Source/webrtc/webkit_sdk/objc/api/video_codec/RTCVideoDecoderAV1.mm
        Source/webrtc/webkit_sdk/objc/api/video_codec/RTCVideoEncoderAV1.mm
        Source/webrtc/webkit_sdk/objc/components/video_codec/RTCVideoFrameReorderQueue.mm
        Source/webrtc/webkit_sdk/objc/helpers/NSString+StdString.mm
        Source/webrtc/modules/video_coding/codecs/h264/h264.cc
        Source/webrtc/rtc_base/system/gcd_helpers.m
    )
    if (APPLE)
        # libaom, the AV1 codec libwebrtc.xcodeproj builds into libwebrtc
        # (Configurations/BaseTarget-libaom.xcconfig: realtime-only, decoder on, the "generic" no-SIMD
        # config on x86_64 -- config/linux/generic/config/aom_config.h), which the list above omits
        # together with the two codec wrappers that call it. libaom's own CMake builds it, in its own
        # configure: that CMake FORCEs its compiler flags into the cache it runs in
        # (build/cmake/compiler_flags.cmake), so it cannot be a subdirectory of libwebrtc's. Its libyuv
        # and libwebm are off because the webrtc target already compiles both.
        include(ExternalProject)
        set(AOM_SOURCE "${CMAKE_CURRENT_SOURCE_DIR}/Source/third_party/libaom/source/libaom")
        set(AOM_BINARY "${CMAKE_CURRENT_BINARY_DIR}/libaom")
        ExternalProject_Add(aom_build
            SOURCE_DIR "${AOM_SOURCE}"
            BINARY_DIR "${AOM_BINARY}"
            CMAKE_GENERATOR "${CMAKE_GENERATOR}"
            CMAKE_ARGS
                "-DCMAKE_TOOLCHAIN_FILE=${CMAKE_TOOLCHAIN_FILE}"
                "-DCMAKE_MAKE_PROGRAM=${CMAKE_MAKE_PROGRAM}"
                "-DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}"
                "-DCMAKE_OSX_SYSROOT=${CMAKE_OSX_SYSROOT}"
                "-DCMAKE_OSX_DEPLOYMENT_TARGET=${CMAKE_OSX_DEPLOYMENT_TARGET}"
                "-DCMAKE_C_FLAGS=${CMAKE_C_FLAGS}"
                "-DCMAKE_CXX_FLAGS=${CMAKE_CXX_FLAGS} -D_LIBCPP_DISABLE_AVAILABILITY -faligned-allocation"
                -DAOM_TARGET_CPU=generic
                -DCONFIG_REALTIME_ONLY=1
                -DCONFIG_AV1_HIGHBITDEPTH=0
                -DCONFIG_LIBYUV=0
                -DCONFIG_WEBM_IO=0
                -DCONFIG_PIC=1
                -DCONFIG_SIZE_LIMIT=1
                -DDECODE_WIDTH_LIMIT=16384
                -DDECODE_HEIGHT_LIMIT=16384
                -DENABLE_EXAMPLES=OFF
                -DENABLE_TESTS=OFF
                -DENABLE_TESTDATA=OFF
                -DENABLE_TOOLS=OFF
                -DENABLE_DOCS=OFF
            BUILD_COMMAND "${CMAKE_COMMAND}" --build "${AOM_BINARY}" --target aom
            BUILD_BYPRODUCTS "${AOM_BINARY}/libaom.a"
            INSTALL_COMMAND ""
        )
        add_library(aom STATIC IMPORTED GLOBAL)
        set_target_properties(aom PROPERTIES IMPORTED_LOCATION "${AOM_BINARY}/libaom.a")
        add_dependencies(aom aom_build)
        list(APPEND webrtc_SOURCES
            Source/webrtc/modules/video_coding/codecs/av1/libaom_av1_decoder.cc
            Source/webrtc/modules/video_coding/codecs/av1/libaom_av1_encoder.cc
        )
    endif ()

    # On Cocoa libwebrtc is a dylib that ships inside WebCore.framework and that WebCore and WebKit
    # each link (Configurations/libwebrtc.xcconfig; WebCore.xcconfig and WebKit.xcconfig both pass
    # -weak-lwebrtc). Linking the archive into both frameworks instead gives a process two copies of
    # every WK_RTC* ObjC class -- "Class WK_RTCVideoDecoderAV1 is implemented in both .../WebCore and
    # .../WebKit2. One of the two will be used. Which one is undefined." -- and two copies of
    # libwebrtc's C++ globals with them.
    if (APPLE)
        add_library(webrtc SHARED ${webrtc_SOURCES})
    else ()
        add_library(webrtc STATIC ${webrtc_SOURCES})
    endif ()
    if (APPLE)
        # libaom's public headers include each other as <aom/...>.
        target_link_libraries(webrtc PUBLIC aom)
        target_include_directories(webrtc PRIVATE "${AOM_SOURCE}")

        # Configurations/Base.xcconfig:33 gives the whole libwebrtc project CLANG_ENABLE_OBJC_ARC,
        # and its ObjC sources are written for it: RTCVideoEncoderH264's -setCallback: assigns the
        # completion block straight to an ivar, which under manual retain/release stores a stack
        # block that is dead by the time VideoToolbox reports the encoded frame.
        target_compile_options(webrtc PRIVATE "$<$<COMPILE_LANGUAGE:OBJC,OBJCXX>:-fobjc-arc>")
    endif ()
endmacro()

# Called after libwebrtc/CMakeLists.txt has set the target's own properties, so these win.
macro(MAVERICKS_LIBWEBRTC_FINALIZE_TARGET)
    if (APPLE)
        # Configurations/Base.xcconfig:104 gives the whole libwebrtc project
        # OTHER_CFLAGS = -fvisibility=default, which overrides its own GCC_SYMBOLS_PRIVATE_EXTERN at
        # line 61: on Cocoa the export list, not visibility, is what holds this library's symbols in.
        # The hidden preset is the GTK/WPE build's.
        set_target_properties(webrtc PROPERTIES CXX_VISIBILITY_PRESET default)
        set_target_properties(webrtc PROPERTIES C_VISIBILITY_PRESET default)

        # The preprocessor definitions Configurations/Base-libwebrtc.xcconfig gives
        # libwebrtc.xcodeproj that libwebrtc/CMakeLists.txt lacks -- RTC_ENABLE_H265 is what the H.265
        # paths of nalu_rewriter and the VideoToolbox codecs compile under; the rest select the same
        # SSL, SCTP, codec and trace configuration Apple's build has.
        target_compile_definitions(webrtc PRIVATE
            FEATURE_ENABLE_SSL
            HAVE_OPENSSL_SSL_H
            HAVE_PTHREAD_COND_TIMEDWAIT_RELATIVE
            HAVE_SA_LEN
            HAVE_SCONN_LEN
            HAVE_SRTP
            OPENSSL
            RTC_DISABLE_TRACE_EVENTS
            RTC_ENABLE_H265
            SCTP_PROCESS_LEVEL_LOCKS
            SCTP_SIMPLE_ALLOCATOR
            SCTP_USE_OPENSSL_SHA1
            SSL_USE_OPENSSL
            USE_BUILTIN_SW_CODECS
            WEBRTC_EXCLUDE_TRANSIENT_SUPPRESSOR
            WEBRTC_NON_STATIC_TRACE_EVENT_HANDLERS=0
            __APPLE_USE_RFC_2292
            __Userspace__
            __Userspace_os_Darwin
        )

        # The export surface libwebrtc.xcodeproj's "Generate Export Files" phase emits for a release
        # build: Configurations/libwebrtc.exp followed by the release variant.
        set(webrtc_EXPORTS_INPUTS
            "${CMAKE_CURRENT_SOURCE_DIR}/Configurations/libwebrtc.exp"
            "${CMAKE_CURRENT_SOURCE_DIR}/Configurations/libwebrtc.release.exp")
        set(webrtc_EXPORTS "")
        foreach (_exp IN LISTS webrtc_EXPORTS_INPUTS)
            file(READ "${_exp}" _expText)
            string(APPEND webrtc_EXPORTS "${_expText}")
        endforeach ()
        # Three AsyncPacketSocket entry points beyond that list. Upstream compiles their caller,
        # NetworkProcess/webrtc/LibWebRTCSocketClient.cpp, out on Cocoa; 10.9 has no Network.framework,
        # so HAVE(NETWORK_FRAMEWORK) is false here and WebKit builds it.
        string(APPEND webrtc_EXPORTS
            "__ZN6webrtc17AsyncPacketSocket19SubscribeCloseEventEPKvNSt3__18functionIFvPS0_iEEE\n"
            "__ZN6webrtc17AsyncPacketSocket30RegisterReceivedPacketCallbackEN4absl12AnyInvocableIFvPS0_RKNS_16ReceivedIpPacketEEEE\n"
            "__ZN6webrtc17AsyncPacketSocket32DeregisterReceivedPacketCallbackEv\n")
        # file(GENERATE) leaves the file alone when the content is unchanged; file(WRITE) would bump
        # its mtime on every reconfigure and, through LINK_DEPENDS below, relink the whole dylib.
        set(webrtc_EXPORTED_SYMBOLS_FILE "${CMAKE_CURRENT_BINARY_DIR}/libwebrtc.generated.exp")
        file(GENERATE OUTPUT "${webrtc_EXPORTED_SYMBOLS_FILE}" CONTENT "${webrtc_EXPORTS}")
        set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS ${webrtc_EXPORTS_INPUTS})
        target_link_options(webrtc PRIVATE "-Wl,-exported_symbols_list,${webrtc_EXPORTED_SYMBOLS_FILE}")
        set_property(TARGET webrtc APPEND PROPERTY LINK_DEPENDS "${webrtc_EXPORTED_SYMBOLS_FILE}")

        # The archives libwebrtc.xcconfig names in WEBRTC_LDFLAGS that are separate targets here
        # (libaom is linked above; vpx and libsrtp are already objects of this target, and libyuv is
        # compiled into it).
        target_link_libraries(webrtc PRIVATE opus webm
            "-framework AVFoundation" "-framework AppKit" "-framework AudioToolbox"
            "-framework CoreAudio" "-framework CoreFoundation" "-framework CoreGraphics"
            "-framework CoreMedia" "-framework CoreVideo" "-framework Foundation"
            "-framework IOSurface" "-framework Security" "-framework SystemConfiguration"
            "-framework VideoToolbox")
        set_target_properties(webrtc PROPERTIES INSTALL_NAME_DIR "@rpath")

        # A shipped image of its own: the polyfill layer wins inside it the way it does inside the
        # frameworks, and its ObjC code needs the __wk_marker section that scopes the selref patcher to
        # WebKit's own binaries.
        _WEBKIT_FORCE_LOAD_POLYFILL(webrtc)
        _WEBKIT_FORCE_LOAD_WK_MARKER(webrtc)
    endif ()
endmacro()

# The SDK include directories libwebrtc/CMakeLists.txt lists still spell the pre-webkit_sdk layout.
macro(MAVERICKS_LIBWEBRTC_INCLUDE_DIRECTORIES)
    string(REPLACE "Source/webrtc/sdk/" "Source/webrtc/webkit_sdk/" webrtc_INCLUDE_DIRECTORIES "${webrtc_INCLUDE_DIRECTORIES}")
endmacro()

macro(MAVERICKS_LIBWEBRTC_OPUS_SOURCES)
    # The list carries opus's demo and dump_modes tools (main()s; dump_modes redefines
    # opus_select_arch) and the fixed-point SILK sources, which opus's own silk_sources.mk builds only
    # under FIXED_POINT (this is a float build; they do not type-check against it). extensions.c
    # supplies opus_packet_extensions_*, called by the listed opus and webrtc audio code.
    list(APPEND opus_SOURCES Source/third_party/opus/src/src/extensions.c)
    list(FILTER opus_SOURCES EXCLUDE REGEX "/dump_modes/|_demo\\.c$|/opus_compare\\.c$|/opus/src/doc/|/silk/fixed/")
endmacro()

macro(MAVERICKS_LIBWEBRTC_VPX_SOURCES)
    # The list carries libvpx's tools/ (main()) and the root-level tool helpers (args, ivf/y4m readers
    # and writers, tools_common with its usage_exit hook, ...), a second vpx_config.c (linux/ppc64)
    # beside this port's mac/x64 one, and the two-pass encoder TUs vp9cx.mk strips under
    # CONFIG_REALTIME_ONLY (set in config/mac/x64/vpx_config.h).
    list(FILTER vpx_SOURCES EXCLUDE REGEX "/libvpx/tools/|/libvpx/(args|ivfdec|ivfenc|md5_utils|rate_hist|tools_common|video_reader|video_writer|vpxstats|warnings|y4menc|y4minput)\\.c$|/config/linux/ppc64/|/vp9_firstpass\\.c$|/vp9_mbgraph\\.c$|/vp9_temporal_filter\\.c$|/temporal_filter_(ssse3|sse4|avx2)\\.c$|/vp9_alt_ref_aq\\.c$|/vp9_aq_(variance|360|complexity)\\.c$")
endmacro()
