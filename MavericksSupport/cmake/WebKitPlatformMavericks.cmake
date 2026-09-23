# Every backport change to WebKit's Mac CMake configuration.
#
# Source/WebKit/PlatformMac.cmake is kept BYTE-UPSTREAM and ends with a single `include()` of this
# file. See MavericksSupport/cmake/WebCorePlatformMavericks.cmake for the rationale.

# SOVERSION "A" pins the standard Versions/A framework layout, matching WebCore/JavaScriptCore/
# WebKitLegacy, the nested XPCServices (which build into Versions/A/XPCServices) and Safari 7's
# absolute LC_LOAD_DYLIB of .../WebKit2.framework/Versions/A/WebKit2. The dylib version follows
# WEBKIT_MAC_VERSION from the upstream version file.
#
# libpolyfill_webkit.a carries the RFC 6455 WebSocket client that provides
# NSURLSessionWebSocketTask/Message (10.15+, absent on 10.9) and the stub @implementations Safari 7
# binds out of WebKit.framework. A static archive linked into a framework contributes its symbols to
# that framework, which is what satisfies both the two-level "Expected in: WebKit" bind and the weak
# _OBJC_CLASS_$_NSURLSessionWebSocketMessage import. It is a SEPARATE archive from libpolyfill_methods.a
# so these ObjC classes are registered exactly once, here, rather than in every image that links the
# shared archive.
# com.apple.WebKit2 is the identity this port installs WK2 under (stage-frameworks.sh renames the
# framework to WebKit2.framework, because Safari 7's API contract gives the WebKit.framework name and
# the com.apple.WebKit identity to WebKitLegacy). Stamping it at build time makes the build tree answer
# the same CFBundleGetBundleWithIdentifier lookups the installed tree does -- XPCServiceMain.mm finds
# the network and web-content entry points that way, and a build-tree WebKit2 without this identity
# hands CFBundleGetFunctionPointerForName a null bundle, so every service dies at launch.
macro(_MAVERICKS_FINALIZE_WEBKIT_TARGET _target)
    set_target_properties(${_target} PROPERTIES
        LINKER_LANGUAGE CXX
        SOVERSION "A"
        MACOSX_FRAMEWORK_IDENTIFIER "com.apple.WebKit2")
    _MAVERICKS_LINK_LIBWEBRTC(${_target})
    if (APPLE)
        target_link_options(${_target} PRIVATE
            "-Wl,-force_load,${MAVERICKS_SUPPORT}/polyfill/build/libpolyfill_webkit.a")
        set_property(TARGET ${_target} APPEND PROPERTY LINK_DEPENDS
            "${MAVERICKS_SUPPORT}/polyfill/build/libpolyfill_webkit.a")
    endif ()
    _MAVERICKS_DEFINE_WEBPUSHD()
endmacro()

# The webpushd daemon executable, which upstream builds only from WebKit.xcodeproj. As there, the tool
# is a thin main() over WKWebPushDaemonMain -- the daemon implementation lives in WebKit.framework (see
# PlatformMac.cmake). The binary lands in Versions/A/Daemons inside the framework, the relocatable-
# webpushd layout, so the staging and install scripts carry it with the framework; launchd starts it
# from the LaunchAgent MavericksSupport/install-safari7.sh installs, as upstream's relocatable flavor
# also does.
macro(_MAVERICKS_DEFINE_WEBPUSHD)
    if (ENABLE_WEB_PUSH_NOTIFICATIONS)
        WEBKIT_EXECUTABLE_DECLARE(webpushd)
        set(webpushd_SOURCES webpushd/webpushd.cpp)
        set(webpushd_PRIVATE_INCLUDE_DIRECTORIES $<TARGET_PROPERTY:WebKit,INCLUDE_DIRECTORIES>)
        set(webpushd_LIBRARIES WebKit)
        WEBKIT_EXECUTABLE(webpushd)
        WEBKIT_ADD_PREFIX_HEADER(webpushd WebKitPrefix.h PREFIX_LANGUAGES CXX OBJCXX)
        set_target_properties(webpushd PROPERTIES
            RUNTIME_OUTPUT_DIRECTORY "${CMAKE_LIBRARY_OUTPUT_DIRECTORY}/WebKit.framework/Versions/A/Daemons")
    endif ()
endmacro()

# --------------------------------------------------------------------------
# Standalone backport blocks (targets, definitions, framework lookups, staging).
# --------------------------------------------------------------------------



# system zlib for the NetworkProcess gzip content-decoder (NetworkDataTaskCocoa.mm).
# 10.9 CFNetwork suppresses its transparent Content-Encoding: gzip decode for .gz/.tgz URLs and hands the
# raw compressed body to WebKit, which inflate() un-does. WebCore links ZLIB::ZLIB already, but that
# framework's symbols are not re-exported to WebKit.
find_package(ZLIB REQUIRED)
list(APPEND WebKit_PRIVATE_LIBRARIES ZLIB::ZLIB)

# The daemon uses Mozilla autopush and the service-worker notification path on Mavericks.
if (ENABLE_WEB_PUSH_NOTIFICATIONS)
    list(REMOVE_ITEM WebKit_SOURCES
        webpushd/ApplePushServiceConnection.mm
        webpushd/_WKMockUserNotificationCenter.mm
    )
    # The daemon entry point is supplied by WebPushDaemonMain.mm.
    list(REMOVE_ITEM WebKit_SOURCES "${CMAKE_BINARY_DIR}/WebKit/WebPushDaemonStubs.cpp")
    # The two Mozilla-transport files are this backport's own, so they live beside the rest of the
    # 10.9 glue; ${MAVERICKS_SUPPORT}/source mirrors the Source/ path of whatever each one plugs into.
    list(APPEND WebKit_PRIVATE_INCLUDE_DIRECTORIES "${MAVERICKS_SUPPORT}/source/WebKit/webpushd")
    # The Mozilla transport owns its Objective-C ivars through ARC.
    list(APPEND WebKit_ARC_SOURCES
        ${MAVERICKS_SUPPORT}/source/WebKit/webpushd/MozillaPushServiceConnection.mm
        ${MAVERICKS_SUPPORT}/source/WebKit/webpushd/MozillaPushWebSocket.mm
    )
    list(APPEND WebKit_SOURCES
        webpushd/MockPushServiceConnection.mm
        webpushd/PushClientConnection.mm
        webpushd/PushService.mm
        webpushd/PushServiceConnection.mm
        webpushd/WebPushDaemon.mm
        webpushd/WebPushDaemonMain.mm
    )
    # SMJobSubmit, which submits the daemon's launchd job from the UI process
    # (UIProcess/WebsiteData/Cocoa/WebsiteDataStoreCocoa.mm).
    target_link_options(WebKit PRIVATE "SHELL:-framework ServiceManagement")
endif ()

# the UIProcess and injected-bundle sources this backport wrote itself, kept with
# the rest of the 10.9 glue -- ${MAVERICKS_SUPPORT}/source mirrors the Source/ path each one plugs
# into. WKViewMavericks.mm carries the only @implementation WKView on this port and WKViewToolTip.mm
# its title-attribute tooltip; both compile standalone. Sources that ride in a unified bundle stay in
# Source/ -- their position in the list decides which files share a
# unified bundle, so relocating them would move every file after them into a different bundle.
list(APPEND WebKit_PRIVATE_INCLUDE_DIRECTORIES
    "${MAVERICKS_SUPPORT}/source/WebKit/UIProcess"
)
list(APPEND WebKit_SOURCES
    ${MAVERICKS_SUPPORT}/source/WebKit/UIProcess/API/mac/WKViewMavericks.mm
    ${MAVERICKS_SUPPORT}/source/WebKit/UIProcess/API/mac/WKViewToolTip.mm
    ${MAVERICKS_SUPPORT}/source/WebKit/UIProcess/mac/MavericksPageClient.mm
)

# upstream's PlatformMac.cmake lists WKProcessGroupPrivate.h among the framework
# headers to copy, but ships no such file (the same class of stale list entry as TextIndicatorWindow).
# Drop it from the copy list rather than carrying a content-free placeholder to satisfy it.
list(REMOVE_ITEM WebKit_PUBLIC_FRAMEWORK_HEADERS UIProcess/API/Cocoa/WKProcessGroupPrivate.h)

# two more source entries with no file behind them here. handleXPCEndpointMessage
# is compiled from Shared/EntryPointUtilities/Cocoa/XPCService/XPCEndpointMessages.mm, and the
# connection-termination watchdog's reason string is inline in AuxiliaryProcessProxyCocoa.mm, so
# withhold the entries rather than carrying a file that only exists to satisfy them.
list(REMOVE_ITEM WebKit_SOURCES
    UIProcess/Cocoa/XPCConnectionTerminationWatchdog.mm
    WebProcess/cocoa/HandleXPCEndpointMessages.mm
)

# _WKFeature.h imports <WebKit/WebFeature.h>, which the Xcode build satisfies from
# WebKitLegacy's copy. Forward to that one file rather than keeping a second definition of the same
# enumerations here -- two headers describing one ABI is a mis-decode waiting to happen.
configure_file("${WEBKITLEGACY_DIR}/mac/WebView/WebFeature.h"
    "${WebKit_FRAMEWORK_HEADERS_DIR}/WebKit/WebFeature.h" COPYONLY)

# header directories upstream's CMake port lists as SOURCES but never as include
# paths — Apple builds this tree with Xcode, whose header maps resolve any header by basename. Bare-name
# imports of headers living here therefore do not resolve on the CMake port. None of this is 10.9-specific.
# The feature-gated API sources (WK_WEB_EXTENSIONS, WEB_PUSH, WRITING_TOOLS, MarketplaceKit) put their
# imports above their own `#if`, so the sibling header has to be findable even when the body compiles away.
# WebAuthentication/Virtual is reached by quoted include from WebAutomationSession/WebsiteDataStore once
# ENABLE(WEB_AUTHN) is on. No header basename in these directories collides with one already reachable.
list(APPEND WebKit_PRIVATE_INCLUDE_DIRECTORIES
    "${WEBKIT_DIR}/Platform/IPC/darwin"
    "${WEBKIT_DIR}/Platform/ios"
    "${WEBKIT_DIR}/Platform/spi/ios"
    "${WEBKIT_DIR}/UIProcess/ios"
    "${WEBKIT_DIR}/UIProcess/WebsiteData/Cocoa"
    "${WEBKIT_DIR}/UIProcess/WebAuthentication/Virtual"
    "${WEBKIT_DIR}/GPUProcess/media/cocoa"
    "${WEBKIT_DIR}/WebProcess/Plugins/PDF/UnifiedPDF"
    "${WEBKIT_DIR}/WebProcess/Extensions/Cocoa"
    "${WEBKIT_DIR}/UIProcess/Extensions/Cocoa"
    "${WEBKIT_DIR}/webpushd/webpushtool"
    "${WEBKIT_DIR}/WebKitSwift/WritingTools"
    "${WEBKIT_DIR}/WebKitSwift/MarketplaceKit"
)

# PAL/pal/spi/cf/CoreMediaSPI.h includes <webrtc/webkit_sdk/WebKit/CMBaseObjectSPI.h>
# for the CMBase types whatever USE_LIBWEBRTC says, and WebCore and PAL already add this path
# unconditionally. Without it here, that header takes its forward-declaration path and WebCore and WebKit
# TUs declare CMBaseVTable as two different types — an ODR violation that links only because Itanium
# mangling omits return types.
list(APPEND WebKit_SYSTEM_INCLUDE_DIRECTORIES
    "${THIRDPARTY_DIR}/libwebrtc/Source/"
    "${THIRDPARTY_DIR}/libwebrtc/Source/webrtc"
)

# IPC serialization for the two API types whose C SPI is restored for Safari 7
# (WKPageGroup* and the do-JavaScript result).
list(APPEND WebKit_SERIALIZATION_IN_FILES
    Shared/API/APIPageGroupHandle.serialization.in
    Shared/API/APISerializedScriptValue.serialization.in
)

# re-export WebKitLegacy through WebKit.framework so its DOM ObjC classes
# (DOMHTMLAnchorElement and friends), which DataDetectors expects to find there, resolve. Linked only
# via -reexport_framework, never also as a plain dependency, or its symbols land twice.
if (APPLE)
    list(APPEND WebKit_PRIVATE_LIBRARIES "-Wl,-reexport_framework,WebKitLegacy")
endif ()

# the XPC-service executables must be named WITHOUT the
# ".Development" suffix. The WK2 process launcher (and launchd, resolving the
# .xpc bundle) execs Contents/MacOS/com.apple.WebKit.WebContent — a ".Development"
# binary name yields ENOENT ("XPC Service could not exec(3)") so the WebContent /
# Networking processes never start. The bundle directories are already named
# without the suffix; this aligns the inner executable + CFBundleExecutable.
set(WebProcess_OUTPUT_NAME com.apple.WebKit.WebContent)
set(NetworkProcess_OUTPUT_NAME com.apple.WebKit.Networking)
set(GPUProcess_OUTPUT_NAME com.apple.WebKit.GPU)

# CryptoTokenKit is absent on 10.9; the CCID transport handles a nil smart-card slot manager.
target_link_options(WebKit PRIVATE "SHELL:-weak_framework CryptoTokenKit")
# Retain the stock inspector's weak load command for NSBundle lookup.
target_link_options(WebKit PRIVATE
    -weak_library /System/Library/PrivateFrameworks/WebInspectorUI.framework/Versions/A/WebInspectorUI
    "LINKER:-needed_library,/System/Library/PrivateFrameworks/WebInspectorUI.framework/Versions/A/WebInspectorUI")

# weak-link Metal (10.11+; MTLCopyAllDevices etc. on the GPU-process
# resource-purge path), which 10.9 does not ship and whose symbols WebKit references through
# @available/weak_import. Weak-linking is what makes those references resolve to null at load and
# stay bindable up front, which is what an eagerly-bound client needs.
#
# Network.framework is NOT weak-linked, even though 10.9 ships it in no layout: the polyfill layer
# defines every nw_*/sec_* entry point WebKit references (polyfills/c/Network.c) and
# force_load makes those definitions win, so nothing is left to bind against the framework. Naming it
# here as well would put a load command for an image that does not exist into every WebKit binary and
# leave link order to decide whether a reference resolves to the polyfill or to address 0.
#
target_link_options(WebKit PRIVATE "SHELL:-weak_framework Metal")

    # the modern "_WebKit" RunLoopType is unknown to 10.9's libxpc, which then falls
    # back to dispatch_main() — that parks the main thread, so the main GCD queue is drained by a
    # worker whose idle->active wakeup latency is ~166ms (~6Hz), throttling timers/rAF/page loads.
    # "NSRunLoop" makes xpc_main run a real run loop on the main thread, which drains the main queue
    # with immediate (dispatch-port) wakeups — fixing the throttle at its source instead of papering
    # over it with a display-link heartbeat.




# brotli decoder for NetworkDataTaskCocoa's response decoding — modern CFNetwork
# advertises and decodes "br" transparently; 10.9 CFNetwork passes br bodies through raw, so the
# NetworkProcess decodes them itself (same vendored static brotli WebCore's WOFF2 decoder uses).

# --------------------------------------------------------------------------
# Entries withheld from upstream's lists. Expressed as REMOVE_ITEM rather than by
# editing upstream's file, so PlatformMac.cmake stays byte-upstream.
# --------------------------------------------------------------------------
list(REMOVE_ITEM WebKit_MESSAGES_IN_FILES
    UIProcess/Cocoa/VideoFullscreenManagerProxy
    WebProcess/cocoa/VideoFullscreenManager
)

list(REMOVE_ITEM WebKit_PRIVATE_LIBRARIES
    Accessibility
    ${DEVICEIDENTITY_LIBRARY}
    ${NETWORK_LIBRARY}
    ${UNIFORMTYPEIDENTIFIERS_LIBRARY}
)

list(REMOVE_ITEM WebKit_SOURCES
    # PlatformMac.cmake lists this file; it is not in the tree (NetworkRTCProvider is a .cpp).
    NetworkProcess/webrtc/NetworkRTCProvider.mm
    # The Network.framework WebRTC sockets and their helpers (!HAVE(NETWORK_FRAMEWORK); see PlatformHave.h).
    # The socket pair is also in SourcesCocoa.txt and withheld there below.
    NetworkProcess/webrtc/NetworkRTCTCPSocketCocoa.mm
    NetworkProcess/webrtc/NetworkRTCUDPSocketCocoa.mm
    NetworkProcess/webrtc/NetworkRTCUtilitiesCocoa.mm
    UIProcess/Cocoa/WKSafeBrowsingWarning.mm
)

# --------------------------------------------------------------------------
# Entries added to upstream's lists.
# --------------------------------------------------------------------------
# upstream compiles NetworkSoftLink.mm only from WebKit.xcodeproj and never added it to
# a CMake source list, so the CMake Mac port builds its caller -- NetworkTransportSessionCocoa.mm, which
# SourcesCocoa.txt does list -- but not the soft-link thunks it calls, leaving ~45 canLoad_Network_nw_* /
# softLink_Network_nw_* symbols undefined in WebKit.framework. The file is nothing but
# SOFT_LINK_FUNCTION_MAY_FAIL_FOR_SOURCE declarations, so it is also the correct answer for 10.9 rather than
# merely a link fix: Network.framework's WebTransport entry points arrived long after 10.9, MAY_FAIL makes
# each canLoad_* return false instead of asserting, and the object needs nothing but dlopen/dlsym.
list(APPEND WebKit_SOURCES
    NetworkProcess/cocoa/NetworkSoftLink.mm

    # WebKit.xcodeproj compiles this into the WebKit target; no CMake source list names it. Every
    # WebProcess constructor calls WebMockContentFilterManager::singleton().startObservingSettings()
    # under ENABLE(CONTENT_FILTERING) (WebProcess/WebProcess.cpp), which registers the process as the
    # client WebCore's MockContentFilterManager notifies when a test changes the mock settings.
    WebProcess/Network/WebMockContentFilterManager.cpp
)

list(APPEND WebKit_LIBRARIES
    "${MAVERICKS_DEPS}/lib/libbrotlidec.a"
    "${MAVERICKS_DEPS}/lib/libbrotlicommon.a"
)

list(APPEND WebKit_PRIVATE_INCLUDE_DIRECTORIES
    # WebKit Cocoa init calls PAL::GCrypt::initialize().
    "${MAVERICKS_DEPS}/include"
    # WKWebViewTesting.mm imports WKContentViewInteraction.h unconditionally
    # (its content is entirely PLATFORM(IOS_FAMILY)-guarded); the Xcode build resolves project
    # headers by name, so the CMake port needs the ios dir on the include path for parity.
    "${WEBKIT_DIR}/UIProcess/ios"
    # WKWebView.mm, WKPreferences.mm and WebPageProxy.cpp import
    # "WKTextExtractionUtilities.h" by name; the Xcode build resolves project headers by name, so the
    # CMake port needs this dir on the include path for parity (otherwise the include silently
    # resolved to an empty placeholder and WebKit::createItem/computeSimilarity went undeclared).
    "${WEBKIT_DIR}/UIProcess/Cocoa/TextExtraction"
    # needed once ENABLE(WEB_AUTHN) is on — the Digital Credentials bridge and the
    # WebKitSwift ObjC interop headers (all soft-linked at runtime, inert on 10.9) are reached via quoted
    # includes from the DigitalCredentials coordinator/bridge and WKDigitalCredentialsPicker.
    "${WEBKIT_DIR}/WebProcess/cocoa/IdentityDocumentServices"
    "${WEBKIT_DIR}/WebKitSwift/IdentityDocumentServices"
)

list(APPEND WebKit_PUBLIC_FRAMEWORK_HEADERS
    # Referenced via <WebKit/...> by, respectively, _WKWebExtensionController.h and
    # FullscreenTouchSecheuristic.h (FullscreenTouchSecheuristic.cpp is built on Mac).
    UIProcess/API/Cocoa/_WKWebExtensionWindowCreationOptions.h
    UIProcess/ios/fullscreen/FullscreenTouchSecheuristicParameters.h
    # Referenced via <WebKit/_WKWebExtensionTabCreationOptions.h> by _WKWebExtensionTab.h.
    UIProcess/API/Cocoa/_WKWebExtensionTabCreationOptions.h
    # the <WebKit/WebKit.h> umbrella imports these unconditionally, but they were missing
    # from the forward list, so any consumer of the umbrella (e.g. WebKitTestRunner) failed to compile. They
    # are declaration-only public API headers; forward them so the umbrella resolves. (The WKWebExtension
    # classes are inert at runtime since ENABLE_WK_WEB_EXTENSIONS=0, but the headers compile fine.)
    UIProcess/API/Cocoa/WKFormInfo.h
    UIProcess/API/Cocoa/WKWebExtension.h
    UIProcess/API/Cocoa/WKWebExtensionAction.h
    UIProcess/API/Cocoa/WKWebExtensionCommand.h
    UIProcess/API/Cocoa/WKWebExtensionContext.h
    UIProcess/API/Cocoa/WKWebExtensionController.h
    UIProcess/API/Cocoa/WKWebExtensionControllerConfiguration.h
    UIProcess/API/Cocoa/WKWebExtensionControllerDelegate.h
    UIProcess/API/Cocoa/WKWebExtensionDataRecord.h
    UIProcess/API/Cocoa/WKWebExtensionDataType.h
    UIProcess/API/Cocoa/WKWebExtensionMatchPattern.h
    UIProcess/API/Cocoa/WKWebExtensionMessagePort.h
    UIProcess/API/Cocoa/WKWebExtensionPermission.h
    UIProcess/API/Cocoa/WKWebExtensionTab.h
    UIProcess/API/Cocoa/WKWebExtensionTabConfiguration.h
    UIProcess/API/Cocoa/WKWebExtensionWindow.h
    UIProcess/API/Cocoa/WKWebExtensionWindowConfiguration.h
    # reached via <WebKit/WK...h> once ENABLE(WEB_AUTHN) is on — the Digital
    # Credentials picker and the WebKitSwift IdentityDocument interop headers cross-include each other
    # through the <WebKit/...> framework path (all soft-linked, inert on 10.9).
    UIProcess/DigitalCredentials/WKDigitalCredentialsPicker.h
    WebKitSwift/IdentityDocumentServices/WKIdentityDocumentPresentmentController.h
    WebKitSwift/IdentityDocumentServices/WKIdentityDocumentPresentmentError.h
    WebKitSwift/IdentityDocumentServices/WKIdentityDocumentPresentmentMobileDocumentRequest.h
    WebKitSwift/IdentityDocumentServices/WKIdentityDocumentPresentmentRawRequest.h
    WebKitSwift/IdentityDocumentServices/WKIdentityDocumentPresentmentRequest.h
    # headers referenced via <WebKit/X.h> by generated serializers
    # and cross-including API headers, but missing from the forwarding list.
    UIProcess/API/Cocoa/WKJSHandle.h
    UIProcess/API/Cocoa/_WKContentWorldConfiguration.h
    UIProcess/API/Cocoa/_WKTextExtraction.h
    UIProcess/API/Cocoa/_WKRectEdge.h
    # additional Cocoa API headers reached via <WebKit/X.h> by cross-including API/private
    # headers and by WebKitTestRunner's TestRunnerWKWebView / UIScriptController. Forwarding only symlinks them;
    # they are compiled only where actually included. (The legacy WebFrame.h/WebPreferences.h/WebBackForwardList.h
    # references resolve from the WebKitLegacy headers root, so they are intentionally not forwarded here.)
    UIProcess/API/Cocoa/WKDownloadDelegatePrivate.h
    UIProcess/API/Cocoa/WKWebExtensionActionPrivate.h
    UIProcess/API/Cocoa/WKWebExtensionCommandPrivate.h
    UIProcess/API/Cocoa/WKWebExtensionContextPrivate.h
    UIProcess/API/Cocoa/WKWebExtensionControllerConfigurationPrivate.h
    UIProcess/API/Cocoa/WKWebExtensionControllerDelegatePrivate.h
    UIProcess/API/Cocoa/WKWebExtensionControllerPrivate.h
    UIProcess/API/Cocoa/WKWebExtensionDataRecordPrivate.h
    UIProcess/API/Cocoa/WKWebExtensionMatchPatternPrivate.h
    UIProcess/API/Cocoa/WKWebExtensionMessagePortPrivate.h
    UIProcess/API/Cocoa/WKWebExtensionPermissionPrivate.h
    UIProcess/API/Cocoa/WKWebExtensionPrivate.h
    UIProcess/API/Cocoa/_WKPageLoadTiming.h
    UIProcess/API/Cocoa/_WKTargetedElementInfo.h
    UIProcess/API/Cocoa/_WKTargetedElementRequest.h
    UIProcess/API/Cocoa/_WKTextRun.h
    UIProcess/API/Cocoa/_WKWebPushAction.h
    UIProcess/API/Cocoa/_WKWebPushDaemonConnection.h
    UIProcess/API/Cocoa/_WKWebPushMessage.h
    UIProcess/API/Cocoa/_WKWebPushSubscriptionData.h
    UIProcess/Cocoa/_WKCaptionStyleMenuController.h
    UIProcess/API/C/mac/WKNotificationPrivateMac.h
    Shared/mac/SecItemRequestData.h
    GPUProcess/graphics/Model/Float3.h
    GPUProcess/graphics/Model/Float4x4.h
    GPUProcess/graphics/Model/ModelTypes.h
    # forward this header (referenced via <WebKit/...> but missing upstream from the list).
    UIProcess/API/Cocoa/_WKFeature.h
    # forward this header (referenced via <WebKit/...> but missing upstream from the list).
    UIProcess/API/Cocoa/_WKResidentKeyRequirement.h
    # forward this header (referenced via <WebKit/...> but missing upstream from the list).
    UIProcess/API/Cocoa/_WKTextPreview.h
)

list(APPEND WebKit_SERIALIZATION_IN_FILES
    Shared/KeyEventInterpretationContext.serialization.in
    Shared/UserInterfaceIdiom.serialization.in
)

# --------------------------------------------------------------------------
# Applied IN PLACE in Source/WebKit/PlatformMac.cmake instead of here, because each modifies or
# removes an upstream statement rather than appending to a list, and this file runs at the END of
# upstream's:
#   * -framework AuthKit dropped from target_link_options (AuthKit is absent on 10.9)
#   * CMAKE_SHARED_LINKER_FLAGS set in string form, not list form
#   * the DEPENDS added to the .sb preprocessing rule (inside an add_custom_command())
#   * upstream's global add_definitions("-ObjC++ ...") dropped
# Each carries its own marker at the site.
# --------------------------------------------------------------------------


# --------------------------------------------------------------------------
# Source-list entries withheld from and added to upstream's Sources*.txt
# (MAVERICKS_FILTER_SOURCE_LIST, from cmake/MavericksSourceLists.cmake).
# --------------------------------------------------------------------------

# Withheld from Sources.txt: nothing.
# WebAutomationSession's file-local names overlap the BiDi automation agents.
set(MAVERICKS_WITHHELD_WEBKIT_SOURCES
    "UIProcess/Automation/WebAutomationSession.cpp @no-unify-when(bundle<=8) @cost:8"
)

# Safari 7's icon database and injected-bundle policy clients, plus standalone automation.
set(MAVERICKS_ADDED_WEBKIT_SOURCES
    "UIProcess/Automation/WebAutomationSession.cpp @no-unify @cost:8"
    "UIProcess/WebIconDatabase.cpp"
    "UIProcess/WebProcessPoolIconDatabase.cpp"
    "WebProcess/InjectedBundle/InjectedBundleNavigationAction.cpp"
    "WebProcess/InjectedBundle/InjectedBundlePagePolicyClient.cpp"
)

# Withheld from SourcesCocoa.txt. WKWebView.mm comes back below with @no-unify; WKView.mm's place is
# taken by WKViewMavericks.mm, appended to WebKit_SOURCES near the top of this file. The rest are the
# VideoPresentationMode, model-process, os_log streaming,
# smart-magnification and device-orientation paths, none of which exist at this deployment target, plus
# _WKUserContentExtensionStore/_WKUserContentFilter, which need WKContentRuleListStore's enums.
set(MAVERICKS_WITHHELD_WEBKIT_COCOA_SOURCES
    # The Network.framework WebRTC path (!HAVE(NETWORK_FRAMEWORK); see PlatformHave.h).
    "NetworkProcess/webrtc/NetworkRTCSharedMonitorCocoa.mm @nonARC"
    "NetworkProcess/webrtc/NetworkRTCTCPSocketCocoa.mm @nonARC"
    "NetworkProcess/webrtc/NetworkRTCUDPSocketCocoa.mm @nonARC"
    "UIProcess/API/Cocoa/_WKUserContentExtensionStore.mm @nonARC"
    "UIProcess/API/Cocoa/_WKUserContentFilter.mm @nonARC"
    "UIProcess/API/Cocoa/WKWebView.mm @nonARC"
    "UIProcess/API/mac/WKView.mm @nonARC"
    "UIProcess/Cocoa/VideoPresentationManagerProxy.mm @nonARC"
    "WebProcess/cocoa/VideoPresentationManager.mm @nonARC @cost:7"
    "LogStreamMessageReceiver.cpp"
    "ModelProcessModelPlayerProxyMessageReceiver.cpp"
    "SmartMagnificationControllerMessageReceiver.cpp"
    "VideoPresentationManagerMessageReceiver.cpp @cost:3"
    "VideoPresentationManagerProxyMessageReceiver.cpp @cost:3"
    "WebDeviceOrientationUpdateProviderMessageReceiver.cpp"
    "WebDeviceOrientationUpdateProviderProxyMessageReceiver.cpp"
)

# Legacy Objective-C API classes, text extraction, and standalone CoreIPC translation units.
set(MAVERICKS_ADDED_WEBKIT_COCOA_SOURCES
    "Shared/API/Cocoa/WKTypeRefWrapper.mm @nonARC @no-unify"
    "Shared/cf/CoreIPCCFArray.mm @nonARC @no-unify"
    "Shared/cf/CoreIPCCFDictionary.mm @nonARC @no-unify"
    "Shared/cf/CoreIPCCGColorSpace.mm @nonARC @no-unify"
    "Shared/cf/CoreIPCNumber.mm @nonARC @no-unify"
    "Shared/cf/CoreIPCSecTrust.mm @nonARC @no-unify"
    "UIProcess/API/Cocoa/WKBrowsingContextGroup.mm @nonARC"
    "UIProcess/API/Cocoa/WKConnection.mm @nonARC @no-unify"
    "UIProcess/API/Cocoa/WKProcessGroup.mm @nonARC"
    "UIProcess/API/Cocoa/WKWebView.mm @nonARC @no-unify"
    "UIProcess/API/Cocoa/_WKTextExtractionItems.mm @nonARC"
)

# GStreamer uses the fullscreen text-track path; native video presentation is disabled.
list(REMOVE_ITEM WebKit_SOURCES WebProcess/cocoa/TextTrackRepresentationCocoa.mm)
set(MAVERICKS_WITHHELD_WEBKIT_CMAKE_COCOA_SOURCES
    "webpushd/ApplePushServiceConnection.mm @nonARC"
    "webpushd/_WKMockUserNotificationCenter.mm @nonARC"
    "WebProcess/cocoa/TextTrackRepresentationCocoa.mm @nonARC"
    "Shared/cf/CoreIPCCFArray.mm @nonARC"
    "Shared/cf/CoreIPCCFDictionary.mm @nonARC"
    "Shared/cf/CoreIPCCGColorSpace.mm @nonARC"
    "Shared/cf/CoreIPCNumber.mm @nonARC"
    "Shared/cf/CoreIPCSecTrust.mm @nonARC"
)
# 10.9 uses runtime array literals; ARC gives the request coder's static collections process-lifetime ownership.
list(APPEND MAVERICKS_WITHHELD_WEBKIT_CMAKE_COCOA_SOURCES "Shared/Cocoa/CoreIPCNSURLRequest.mm @nonARC")
set(MAVERICKS_ADDED_WEBKIT_CMAKE_COCOA_SOURCES "Shared/Cocoa/CoreIPCNSURLRequest.mm")
MAVERICKS_FILTER_SOURCE_LIST("${WEBKIT_DIR}" WebKit_UNIFIED_SOURCE_LIST_FILES "SourcesCMakeCocoa.txt" MAVERICKS_WITHHELD_WEBKIT_CMAKE_COCOA_SOURCES MAVERICKS_ADDED_WEBKIT_CMAKE_COCOA_SOURCES)

MAVERICKS_FILTER_SOURCE_LIST("${WEBKIT_DIR}" WebKit_UNIFIED_SOURCE_LIST_FILES "Sources.txt" MAVERICKS_WITHHELD_WEBKIT_SOURCES MAVERICKS_ADDED_WEBKIT_SOURCES)
MAVERICKS_FILTER_SOURCE_LIST("${WEBKIT_DIR}" WebKit_UNIFIED_SOURCE_LIST_FILES "SourcesCocoa.txt" MAVERICKS_WITHHELD_WEBKIT_COCOA_SOURCES MAVERICKS_ADDED_WEBKIT_COCOA_SOURCES)

# The Cocoa curl transport's NetworkProcess task and Private Click Measurement request, Safari's native
# resume facade and its typed resume record -- this backport's own sources, beside the rest of the 10.9 glue. NetworkDataTask.cpp and
# the download code reach the headers by bare name, so the directories go on the include path.
find_package(CURL 8.22 REQUIRED)
find_library(CURL_TASK_SYSTEM_CONFIGURATION_LIBRARY SystemConfiguration REQUIRED)
find_library(CURL_TASK_SSL_LIBRARY ssl PATHS "${MAVERICKS_DEPS}/lib" NO_DEFAULT_PATH REQUIRED)
find_library(CURL_TASK_CRYPTO_LIBRARY crypto PATHS "${MAVERICKS_DEPS}/lib" NO_DEFAULT_PATH REQUIRED)
list(APPEND WebKit_PRIVATE_LIBRARIES CURL::libcurl ${CURL_TASK_SSL_LIBRARY} ${CURL_TASK_CRYPTO_LIBRARY} ${CURL_TASK_SYSTEM_CONFIGURATION_LIBRARY})
list(APPEND WebKit_PRIVATE_INCLUDE_DIRECTORIES
    "${MAVERICKS_SUPPORT}/source/WebKit/NetworkProcess/cocoa"
    "${MAVERICKS_SUPPORT}/source/WebKit/NetworkProcess/PrivateClickMeasurement/cocoa"
    "${MAVERICKS_SUPPORT}/source/WebKit/Shared/Cocoa"
)
list(APPEND WebKit_SOURCES
    ${MAVERICKS_SUPPORT}/source/WebKit/NetworkProcess/cocoa/NetworkDataTaskCurlCocoa.mm
    ${MAVERICKS_SUPPORT}/source/WebKit/NetworkProcess/PrivateClickMeasurement/cocoa/PrivateClickMeasurementCurlLoadTask.mm
    ${MAVERICKS_SUPPORT}/source/WebKit/Shared/Cocoa/CocoaDownloadResumeData.mm
    ${MAVERICKS_SUPPORT}/source/WebKit/UIProcess/Cocoa/CocoaCurlLegacyDownload.mm
)
# Serialization inputs are joined onto ${WEBKIT_DIR}, so the overlay file is named relative to it.
list(APPEND WebKit_SERIALIZATION_IN_FILES
    ../../MavericksSupport/source/WebKit/Shared/Cocoa/CocoaDownloadResumeData.serialization.in
)

# Mavericks' libxpc maps _NSApplicationMain to POSIXSpawnType App, matching stock WebContent.
# The other services use the native adaptive NSRunLoop bootstrap and the launcher's importance boost.
function(mavericks_configure_xpc_service target)
    if (target STREQUAL "WebProcess")
        set(RUNLOOP_TYPE _NSApplicationMain PARENT_SCOPE)
    else ()
        set(RUNLOOP_TYPE NSRunLoop PARENT_SCOPE)
    endif ()
endfunction()

# Objective-C text extraction serves the legacy API; the other Swift sources require
# material hosting or the inline PDF plugin, both unavailable at this deployment target.
list(REMOVE_ITEM WebKit_SOURCES
    ${WEBKIT_DIR}/UIProcess/API/Cocoa/_WKTextExtraction.swift
    ${WEBKIT_DIR}/Platform/cocoa/WKMaterialHostingSupport.swift
    ${WEBKIT_DIR}/UIProcess/PDF/WKPDFHUDView.swift
)
