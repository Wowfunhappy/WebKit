# Source selection and shared-library integration for the Mavericks libwebrtc build.

macro(MAVERICKS_LIBWEBRTC_ADD_TARGET)
    # Keep production sources, Cocoa capture and the checked-in Apple assembly.
    string(REPLACE "Source/webrtc/sdk/" "Source/webrtc/webkit_sdk/" webrtc_SOURCES "${webrtc_SOURCES}")
    list(REMOVE_ITEM webrtc_SOURCES Source/webrtc/modules/video_coding/h265_vps_sps_pps_tracker.cc)
    list(FILTER webrtc_SOURCES EXCLUDE REGEX "/audio_device/linux/|/fake_[a-z0-9_]+\\.cc$|_testing(_common)?\\.cc$|_unittest\\.cc$|_test\\.cc$|(^|/)test/|/tools/|/rtc_tools/|/testdata/|/virtual_socket_server\\.cc$|/compute_interpolated_gain_curve\\.cc$|/corruption_detection/evaluation/|/bwe_rtp\\.cc$|/video_loopback_main\\.cc$|/print_hash_of\\.cc$|/gaussian_distribution_gentables\\.cc$|/boringssl/src/tool/|/bazel-example/|/fipstools/|/libyuv/util/|/default_task_queue_factory_win\\.cc$|/rtc_event_log_impl\\.cc$|(^|/)(chacha/chacha-x86_64|cipher/aes128gcmsiv-x86_64|cipher/chacha20_poly1305_x86_64)-")
    list(APPEND webrtc_SOURCES
        Source/third_party/abseil-cpp/absl/base/internal/tracing.cc
        Source/third_party/abseil-cpp/absl/crc/internal/crc_memcpy_fallback.cc
        Source/third_party/abseil-cpp/absl/crc/internal/crc_memcpy_x86_arm_combined.cc
        Source/third_party/abseil-cpp/absl/crc/internal/crc_non_temporal_memcpy.cc
        Source/third_party/abseil-cpp/absl/random/internal/entropy_pool.cc
        Source/third_party/abseil-cpp/absl/status/internal/status_internal.cc
        Source/third_party/abseil-cpp/absl/strings/internal/damerau_levenshtein_distance.cc
        Source/webrtc/modules/video_coding/codecs/h264/h264.cc
    )
    # WebCore and WebKit share libwebrtc's Objective-C classes and C++ globals through one dylib.
    if (APPLE)
        add_library(webrtc SHARED ${webrtc_SOURCES})
    else ()
        add_library(webrtc STATIC ${webrtc_SOURCES})
    endif ()
    if (APPLE)
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
        # Cocoa's Xcode project uses default visibility and an explicit export list for WebRTC and WebM.
        set_target_properties(webrtc webm PROPERTIES CXX_VISIBILITY_PRESET default C_VISIBILITY_PRESET default)
        # OptionsCocoa's directory flags follow the visibility presets; match the Xcode override.
        target_compile_options(webrtc PRIVATE "$<$<COMPILE_LANGUAGE:C,CXX>:-fvisibility=default>")
        target_compile_options(webm PRIVATE "$<$<COMPILE_LANGUAGE:C,CXX>:-fvisibility=default>")

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
        # Socket callbacks used by the libwebrtc transport. Upstream compiles their caller,
        # NetworkProcess/webrtc/LibWebRTCSocketClient.cpp, out on Cocoa; 10.9 has no Network.framework,
        # so HAVE(NETWORK_FRAMEWORK) is false here and WebKit builds it.
        string(APPEND webrtc_EXPORTS
            "__ZN6webrtc17AsyncPacketSocket19SubscribeCloseEventEPKvNSt3__18functionIFvPS0_iEEE\n"
            "__ZN6webrtc17AsyncPacketSocket30RegisterReceivedPacketCallbackEN4absl12AnyInvocableIFvPS0_RKNS_16ReceivedIpPacketEEEE\n"
            "__ZN6webrtc17AsyncPacketSocket32DeregisterReceivedPacketCallbackEv\n"
            "__ZN6webrtc17AsyncPacketSocket19SubscribeSentPacketEPvN4absl12AnyInvocableIFvPS0_RKNS_14SentPacketInfoEEEE\n"
            "__ZN6webrtc17AsyncPacketSocket21UnsubscribeCloseEventEPKv\n"
            "__ZN6webrtc18callback_list_impl21CallbackListReceivers11AddReceiverINS_15UntypedFunction29NontrivialUntypedFunctionArgsEEEvPKvT_\n"
            "__ZN6webrtc18callback_list_impl21CallbackListReceivers15RemoveReceiversEPKv\n")
        # file(GENERATE) leaves the file alone when the content is unchanged; file(WRITE) would bump
        # its mtime on every reconfigure and, through LINK_DEPENDS below, relink the whole dylib.
        set(webrtc_EXPORTED_SYMBOLS_FILE "${CMAKE_CURRENT_BINARY_DIR}/libwebrtc.generated.exp")
        file(GENERATE OUTPUT "${webrtc_EXPORTED_SYMBOLS_FILE}" CONTENT "${webrtc_EXPORTS}")
        set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS ${webrtc_EXPORTS_INPUTS})
        target_link_options(webrtc PRIVATE "-Wl,-exported_symbols_list,${webrtc_EXPORTED_SYMBOLS_FILE}")
        set_property(TARGET webrtc APPEND PROPERTY LINK_DEPENDS "${webrtc_EXPORTED_SYMBOLS_FILE}")

        # Codec/container libraries and the system frameworks used by Cocoa capture.
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
    # Assembly reads its feature definitions from vpx_config.asm. Keep inherited
    # C/C++ definitions and compiler options on their compiler languages.
    get_directory_property(_webrtc_compile_definitions COMPILE_DEFINITIONS)
    set_property(DIRECTORY PROPERTY COMPILE_DEFINITIONS "")
    foreach (_definition IN LISTS _webrtc_compile_definitions)
        add_compile_definitions("$<$<NOT:$<COMPILE_LANGUAGE:ASM_NASM>>:${_definition}>")
    endforeach ()
    get_directory_property(_webrtc_compile_options COMPILE_OPTIONS)
    set_property(DIRECTORY PROPERTY COMPILE_OPTIONS "")
    foreach (_option IN LISTS _webrtc_compile_options)
        add_compile_options("$<$<NOT:$<COMPILE_LANGUAGE:ASM_NASM>>:${_option}>")
    endforeach ()
    set(CMAKE_ASM_NASM_COMPILE_OBJECT "<CMAKE_ASM_NASM_COMPILER> <DEFINES> <INCLUDES> <FLAGS> -f ${CMAKE_ASM_NASM_OBJECT_FORMAT} -o <OBJECT> <SOURCE>")
    # The list carries libvpx's tools/ (main()) and the root-level tool helpers (args, ivf/y4m readers
    # and writers, tools_common with its usage_exit hook, ...), a second vpx_config.c (linux/ppc64)
    # beside this port's mac/x64 one, and the two-pass encoder TUs vp9cx.mk strips under
    # CONFIG_REALTIME_ONLY (set in config/mac/x64/vpx_config.h).
    list(FILTER vpx_SOURCES EXCLUDE REGEX "/libvpx/tools/|/libvpx/(args|ivfdec|ivfenc|md5_utils|rate_hist|tools_common|video_reader|video_writer|vpxstats|warnings|y4menc|y4minput)\\.c$|/config/linux/ppc64/|/vp9_firstpass\\.c$|/vp9_mbgraph\\.c$|/vp9_temporal_filter\\.c$|/temporal_filter_(ssse3|sse4|avx2)\\.c$|/vp9_alt_ref_aq\\.c$|/vp9_aq_(variance|360|complexity)\\.c$")
endmacro()
