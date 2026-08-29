# Every backport change to WebKit's Mac CMake configuration.
#
# Source/WebKit/PlatformMac.cmake is kept BYTE-UPSTREAM and ends with a single `include()` of this
# file. See MavericksSupport/cmake/WebCorePlatformMavericks.cmake for the rationale.

# --------------------------------------------------------------------------
# Standalone backport blocks (targets, definitions, framework lookups, staging).
# --------------------------------------------------------------------------



# system zlib for the NetworkProcess gzip content-decoder (NetworkDataTaskCocoa.mm).
# 10.9 CFNetwork suppresses its transparent Content-Encoding: gzip decode for .gz/.tgz URLs and hands the
# raw compressed body to WebKit, which inflate() un-does. WebCore links ZLIB::ZLIB already, but that
# framework's symbols are not re-exported to WebKit.
find_package(ZLIB REQUIRED)
list(APPEND WebKit_PRIVATE_LIBRARIES ZLIB::ZLIB)

# the webpushd daemon implementation lives in WebKit.framework, as it does in the
# upstream Xcode build (whose webpushd tool target compiles only webpushd.cpp against the framework).
# Upstream's list, minus iOS-only WebClipCache.mm, _WKMockUserNotificationCenter.mm (needs
# HAVE(FULL_FEATURED_USER_NOTIFICATIONS), macOS 14+) and ApplePushServiceConnection.mm — 10.9's
# ApplePushService cannot mint URL tokens and the modern SDK ships no .tbd to link it, so this port's
# transport is MozillaPushServiceConnection + MozillaPushWebSocket (USE_MOZILLA_PUSH_SERVICE).
if (ENABLE_WEB_PUSH_NOTIFICATIONS)
    # The two Mozilla-transport files are this backport's own, so they live beside the rest of the
    # 10.9 glue; ${MAVERICKS_SUPPORT}/source mirrors the Source/ path of whatever each one plugs into.
    list(APPEND WebKit_PRIVATE_INCLUDE_DIRECTORIES "${MAVERICKS_SUPPORT}/source/WebKit/webpushd")
    list(APPEND WebKit_SOURCES
        ${MAVERICKS_SUPPORT}/source/WebKit/webpushd/MozillaPushServiceConnection.mm
        ${MAVERICKS_SUPPORT}/source/WebKit/webpushd/MozillaPushWebSocket.mm
        webpushd/MockPushServiceConnection.mm
        webpushd/PushClientConnection.mm
        webpushd/PushService.mm
        webpushd/PushServiceConnection.mm
        webpushd/WebPushDaemon.mm
        webpushd/WebPushDaemonMain.mm
    )
    # The two Mozilla files are written for ARC (bare ObjC ivar assignments, no manual retains); under
    # this port's default MRR compile the ivars drop their references and the daemon use-after-frees on
    # the first stream callback. They traffic in no os_object types, so the OS_OBJECT_USE_OBJC=1 mangling
    # the rest of the build uses is unaffected; the upstream daemon files keep the port-wide MRR default,
    # under which their RetainPtr/adoptNS ownership is correct either way.
    set_source_files_properties(
        ${MAVERICKS_SUPPORT}/source/WebKit/webpushd/MozillaPushServiceConnection.mm
        ${MAVERICKS_SUPPORT}/source/WebKit/webpushd/MozillaPushWebSocket.mm
        PROPERTIES COMPILE_FLAGS "-fobjc-arc")
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

# quote the linker-flags append (preserve prior flags) and drop -framework AuthKit (AuthKit absent on 10.9).
# the CCID (smart-card) WebAuthn transport hard-references TKSmartCardSlotManager from
# CryptoTokenKit, which is 10.10+. Weak-link it so WebKit still loads on 10.9 — the class resolves to nil and
# CcidService finds no smart-card slots (graceful "no CCID authenticator" degradation, like the other
# soft-linked WebAuthn backends).
target_link_options(WebKit PRIVATE -weak_framework CryptoTokenKit)
# upstream's WK_WEBINSPECTORUI_LDFLAGS (WebKit.xcconfig: -weak_framework
# WebInspectorUI) — the load command dyld needs so [NSBundle bundleWithIdentifier:
# @"com.apple.WebInspectorUI"] finds the frontend bundle in every host process
# (WKInspectorResourceURLSchemeHandler RELEASE_ASSERTs on a nil bundle; iBooks crashed there).
# The xcconfig flag never made it into this CMake build. Linked by exact dylib path because the
# stock 10.9 framework is not in the modern SDK's search paths.
target_link_options(WebKit PRIVATE -weak_library /System/Library/PrivateFrameworks/WebInspectorUI.framework/Versions/A/WebInspectorUI)

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
# Keep this target free of "-undefined dynamic_lookup". Upstream applies that flag to WebCore only
# (Source/WebCore/CMakeLists.txt, "-umbrella WebKit"). On WebKit it masks real defects rather than
# adapting to 10.9: it lets genuinely undefined WebKit-INTERNAL symbols survive the link as
# flat-namespace lookups, and the rationale for it -- "bind them lazily so absence surfaces at call
# time" -- does not hold for a client that binds eagerly (dlopen RTLD_NOW, or a hard-bound framework),
# where dyld must resolve every undefined symbol up front and aborts on the first one nothing defines.
# Every WebKit-internal symbol is defined instead: NetworkSoftLink.mm and MediaRecorderPrivateWriter et
# al. are compiled (see the WebCore/WebKit source-list additions), BidiBrowserAgent's non-GLib fallback
# is gated on the ports that actually build the GLib one, and ENABLE_WEB_PUSH_NOTIFICATIONS is off,
# which is what keeps the WebPushDaemonMain/WebPushToolMain references out. Without the flag, the
# linker is the gate that catches the next such omission at build time.
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
    # ENABLE_ROUTING_ARBITRATION is off (AVAudioRoutingArbiter is absent at this deployment target),
    # so AudioSessionRoutingArbitratorProxy is withheld from Sources.txt below and there is nothing
    # for the generated receiver to call.
    UIProcess/Media/AudioSessionRoutingArbitratorProxy
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
)

list(APPEND WebKit_LIBRARIES
    "${MAVERICKS_DEPS}/lib/libbrotlidec.a"
    "${MAVERICKS_DEPS}/lib/libbrotlicommon.a"
)

list(APPEND WebKit_MESSAGES_IN_FILES
    # upstream's CMake Mac port still lists this by its pre-rename name,
    # UIProcess/Cocoa/VideoFullscreenManagerProxy, for which no .messages.in exists -- the file
    # upstream actually ships is VideoPresentationManagerProxy.messages.in (the class was renamed;
    # only the Xcode build, which drives Apple's Mac port, was updated). Name the real file.
    UIProcess/Cocoa/VideoPresentationManagerProxy
    # same pre-rename staleness as VideoPresentationManagerProxy above.
    WebProcess/cocoa/VideoPresentationManager
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
    # forward these headers (referenced via <WebKit/...> but missing upstream from the list).
    UIProcess/API/Cocoa/WKJSScriptingBuffer.h
    UIProcess/API/Cocoa/WKJSSerializedNode.h
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
    UIProcess/API/Cocoa/_WKImmersiveEnvironmentDelegate.h
    UIProcess/API/Cocoa/_WKPageLoadTiming.h
    UIProcess/API/Cocoa/_WKSpatialBackdropSource.h
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
    # register the CoreIPC CF/Cocoa serialization descriptors so their generated coders build.
    Shared/cf/CFTypes.serialization.in
    Shared/cf/CoreIPCBoolean.serialization.in
    Shared/cf/CoreIPCCFArray.serialization.in
    Shared/cf/CoreIPCCFDictionary.serialization.in
    Shared/cf/CoreIPCCGColorSpace.serialization.in
    Shared/cf/CoreIPCNumber.serialization.in
    Shared/cf/CoreIPCSecAccessControl.serialization.in
    Shared/cf/CoreIPCSecCertificate.serialization.in
    Shared/cf/CoreIPCSecKeychainItem.serialization.in
    Shared/cf/CoreIPCSecTrust.serialization.in
    Shared/Cocoa/CoreIPCArray.serialization.in
    Shared/Cocoa/CoreIPCAuditToken.serialization.in
    Shared/Cocoa/CoreIPCCFCharacterSet.serialization.in
    Shared/Cocoa/CoreIPCCFType.serialization.in
    Shared/Cocoa/CoreIPCCFURL.serialization.in
    Shared/Cocoa/CoreIPCColor.serialization.in
    Shared/Cocoa/CoreIPCContacts.serialization.in
    Shared/Cocoa/CoreIPCData.serialization.in
    Shared/Cocoa/CoreIPCDate.serialization.in
    Shared/Cocoa/CoreIPCDateComponents.serialization.in
    Shared/Cocoa/CoreIPCDictionary.serialization.in
    Shared/Cocoa/CoreIPCError.serialization.in
    Shared/Cocoa/CoreIPCLocale.serialization.in
    Shared/Cocoa/CoreIPCNSCFObject.serialization.in
    Shared/Cocoa/CoreIPCNSShadow.serialization.in
    Shared/Cocoa/CoreIPCNSURLCredential.serialization.in
    Shared/Cocoa/CoreIPCNSURLProtectionSpace.serialization.in
    Shared/Cocoa/CoreIPCNSURLRequest.serialization.in
    Shared/Cocoa/CoreIPCNSValue.serialization.in
    Shared/Cocoa/CoreIPCNull.serialization.in
    Shared/Cocoa/CoreIPCPersonNameComponents.serialization.in
    Shared/Cocoa/CoreIPCPresentationIntent.serialization.in
    Shared/Cocoa/CoreIPCSecureCoding.serialization.in
    Shared/Cocoa/CoreIPCString.serialization.in
    Shared/Cocoa/CoreIPCURL.serialization.in
    # register these additional serialization descriptors so their generated coders build.
    Shared/AppPrivacyReportTestingData.serialization.in
    Shared/AdditionalFonts.serialization.in
    Shared/AlternativeTextClient.serialization.in
    Shared/IPCTester.serialization.in
    Shared/KeyEventInterpretationContext.serialization.in
    Shared/PDFDisplayMode.serialization.in
    Shared/PushMessageForTesting.serialization.in
    Shared/TextAnimationTypes.serialization.in
    Shared/UserInterfaceIdiom.serialization.in
    Shared/ViewWindowCoordinates.serialization.in
    Shared/Cocoa/CoreIPCAVOutputContext.serialization.in
    Shared/Cocoa/CoreIPCCVPixelBufferRef.serialization.in
    Shared/Cocoa/CoreIPCDDScannerResult.serialization.in
    Shared/Cocoa/CoreIPCPlist.serialization.in
    Shared/Cocoa/CoreIPCStringSet.serialization.in
    Shared/Cocoa/CursorContext.serialization.in
    Shared/Cocoa/GestureTypes.serialization.in
    Shared/Cocoa/InteractionInformationAtPosition.serialization.in
    Shared/Cocoa/InteractionInformationRequest.serialization.in
    Shared/Cocoa/SharedCARingBuffer.serialization.in
    Shared/RemoteLayerTree/BufferAndBackendInfo.serialization.in
    Shared/RemoteLayerTree/RemoteLayerTree.serialization.in
    Shared/RemoteLayerTree/RemoteScrollingCoordinatorTransaction.serialization.in
    Shared/RemoteLayerTree/RemoteScrollingUIState.serialization.in
    Shared/mac/CoreIPCDDSecureActionContext.serialization.in
    Shared/mac/PDFContextMenuItem.serialization.in
    Shared/mac/SecItemRequestData.serialization.in
    Shared/mac/SecItemResponseData.serialization.in
    Shared/mac/WebHitTestResultPlatformData.serialization.in
    Platform/cocoa/MediaPlaybackTargetContextSerialized.serialization.in
    WebProcess/WebPage/RemoteLayerTree/PlatformCAAnimationRemoteProperties.serialization.in
)

# --------------------------------------------------------------------------
# Applied IN PLACE in Source/WebKit/PlatformMac.cmake instead of here, because each modifies or
# removes an upstream statement rather than appending to a list, and this file runs at the END of
# upstream's:
#   * -framework AuthKit dropped from target_link_options (AuthKit is absent on 10.9)
#   * CMAKE_SHARED_LINKER_FLAGS set in string form, not list form
#   * RUNLOOP_TYPE NSRunLoop (inside an if() block whose other statements consume it)
#   * the WebContentProcess.nib rule (ibtool -> empty placeholder; inside a function())
#   * the DEPENDS added to the .sb preprocessing rule (inside an add_custom_command())
#   * upstream's global add_definitions("-ObjC++ ...") dropped
# Each carries its own marker at the site.
# --------------------------------------------------------------------------


# --------------------------------------------------------------------------
# Source-list entries withheld from and added to upstream's Sources*.txt
# (MAVERICKS_FILTER_SOURCE_LIST, from cmake/MavericksSourceLists.cmake).
# --------------------------------------------------------------------------

# Withheld from Sources.txt: AudioSessionRoutingArbitratorProxy is built on AVAudioSession routing
# arbitration, which this deployment target has no equivalent of.
set(MAVERICKS_WITHHELD_WEBKIT_SOURCES
    "UIProcess/Media/AudioSessionRoutingArbitratorProxy.cpp"
)

# Added to Sources.txt: the legacy WK2 icon database Safari 7's favicon client drives, the FIDO/WebAuthn
# sources upstream's list drops (WEB_AUTHN is on here), the WK109 injected-bundle page-group user content
# and navigation-action sources Safari 7's bundle policy client reads, and two service-worker inspector
# sources that post-date the base upstream commit.
set(MAVERICKS_ADDED_WEBKIT_SOURCES
    "UIProcess/WebIconDatabase.cpp"
    "UIProcess/WebProcessPoolIconDatabase.cpp"
    "UIProcess/WebAuthentication/AuthenticatorManager.cpp"
    "UIProcess/WebAuthentication/fido/CtapAuthenticator.cpp"
    "UIProcess/WebAuthentication/fido/CtapCcidDriver.cpp"
    "UIProcess/WebAuthentication/fido/CtapHidDriver.cpp"
    "UIProcess/WebAuthentication/Virtual/VirtualAuthenticatorManager.cpp"
    "UIProcess/WebAuthentication/Virtual/VirtualHidConnection.cpp"
    "WebProcess/InjectedBundle/InjectedBundleNavigationAction.cpp"
    "WebProcess/InjectedBundle/InjectedBundlePagePolicyClient.cpp"
    "WebProcess/Inspector/ServiceWorkerDebuggableFrontendChannel.cpp"
    "WebProcess/Inspector/ServiceWorkerDebuggableProxy.cpp"
)

# Withheld from SourcesCocoa.txt. WKWebView.mm comes back below with @no-unify; WKView.mm's place is
# taken by WKViewMavericks.mm, appended to WebKit_SOURCES near the top of this file. The rest are the
# VideoPresentationMode, AudioSession routing arbitration, model-process, os_log streaming,
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
    "UIProcess/Media/cocoa/AudioSessionRoutingArbitratorProxyCocoa.mm @nonARC"
    "WebProcess/cocoa/VideoPresentationManager.mm @nonARC"
    "AudioSessionRoutingArbitratorProxyMessageReceiver.cpp"
    "LogStreamMessageReceiver.cpp"
    "ModelProcessModelPlayerProxyMessageReceiver.cpp"
    "SmartMagnificationControllerMessageReceiver.cpp"
    "VideoPresentationManagerMessageReceiver.cpp"
    "VideoPresentationManagerProxyMessageReceiver.cpp"
    "WebDeviceOrientationUpdateProviderMessageReceiver.cpp"
    "WebDeviceOrientationUpdateProviderProxyMessageReceiver.cpp"
)

# Added to SourcesCocoa.txt. Most are files upstream builds only from its Xcode project, whose symbols
# the CMake link needs: the CoreIPC coders, WKKeyedCoder, AdditionalFonts, _WKWarningView,
# _WKCaptionStyleMenuControllerMac, RemoteScrollingTreeCocoa, PositionInformationForWebPage and
# DataDetectionResult. The rest are this port's own: MavericksPageClient.mm is the PageClient behind
# the legacy WKView, WKBrowsingContextGroup.mm and WKProcessGroup.mm are the ObjC classes Apple's
# QuickLook HTML preview bundle instantiates,
# WKTypeRefWrapper.mm is what Mail's WKConnection body coding reaches for, _WKTextExtractionItems.mm
# stands in for _WKTextExtraction.swift, and the WebAuthentication sources come back with WEB_AUTHN.
#
# CoreIPCCVPixelBufferRef.mm is @nonARC so RetainPtr<CVPixelBufferRef> in sendRightFromPixelBuffer
# mangles as plain RetainPtr rather than RetainPtrArc, matching the non-ARC
# WebKitPlatformGeneratedSerializers.mm that references it.
set(MAVERICKS_ADDED_WEBKIT_COCOA_SOURCES
    "Shared/API/Cocoa/WKTypeRefWrapper.mm @nonARC @no-unify"
    "Shared/AdditionalFonts.mm"
    "Shared/Cocoa/ArgumentCodersCocoa.mm @nonARC"
    "Shared/Cocoa/BackgroundFetchStateCocoa.mm"
    "Shared/Cocoa/CoreIPCAVOutputContext.mm"
    "Shared/Cocoa/CoreIPCArray.mm"
    "Shared/Cocoa/CoreIPCCFType.mm @nonARC"
    "Shared/Cocoa/CoreIPCCFURL.mm"
    "Shared/Cocoa/CoreIPCCVPixelBufferRef.mm @nonARC"
    "Shared/Cocoa/CoreIPCContacts.mm"
    "Shared/Cocoa/CoreIPCDDScannerResult.mm"
    "Shared/Cocoa/CoreIPCDateComponents.mm"
    "Shared/Cocoa/CoreIPCDictionary.mm"
    "Shared/Cocoa/CoreIPCError.mm @nonARC"
    "Shared/Cocoa/CoreIPCLocale.mm"
    "Shared/Cocoa/CoreIPCNSCFObject.mm @nonARC"
    "Shared/Cocoa/CoreIPCNSShadow.mm"
    "Shared/Cocoa/CoreIPCNSURLCredential.mm"
    "Shared/Cocoa/CoreIPCNSURLProtectionSpace.mm"
    "Shared/Cocoa/CoreIPCNSURLRequest.mm"
    "Shared/Cocoa/CoreIPCNSValue.mm"
    "Shared/Cocoa/CoreIPCNull.mm"
    "Shared/Cocoa/CoreIPCPersonNameComponents.mm"
    "Shared/Cocoa/CoreIPCPlistArray.mm"
    "Shared/Cocoa/CoreIPCPlistDictionary.mm"
    "Shared/Cocoa/CoreIPCPlistObject.mm"
    "Shared/Cocoa/CoreIPCPresentationIntent.mm"
    "Shared/Cocoa/CoreIPCSecureCoding.mm"
    "Shared/Cocoa/CoreIPCStringSet.mm"
    "Shared/Cocoa/DataDetectionResult.mm @nonARC"
    "Shared/Cocoa/WKKeyedCoder.mm"
    "Shared/Cocoa/WebPushMessageCocoa.mm"
    "Shared/cf/CoreIPCCFArray.mm @no-unify"
    "Shared/cf/CoreIPCCFDictionary.mm @no-unify"
    "Shared/cf/CoreIPCCGColorSpace.mm @no-unify @nonARC"
    "Shared/cf/CoreIPCNumber.mm @no-unify"
    "Shared/cf/CoreIPCSecTrust.mm @no-unify"
    "UIProcess/API/Cocoa/WKBrowsingContextGroup.mm @nonARC"
    "UIProcess/API/Cocoa/WKConnection.mm @nonARC @no-unify"
    "UIProcess/API/Cocoa/WKProcessGroup.mm @nonARC"
    "UIProcess/API/Cocoa/WKWebView.mm @nonARC @no-unify"
    "UIProcess/API/Cocoa/_WKTextExtractionItems.mm @nonARC"
    "UIProcess/Cocoa/AuxiliaryProcessProxyCocoa.mm @nonARC"
    "UIProcess/mac/MavericksPageClient.mm @nonARC"
    "UIProcess/Cocoa/CSPExtensionUtilities.mm"
    "UIProcess/Cocoa/_WKWarningView.mm @nonARC"
    "UIProcess/Downloads/DownloadProxyCocoa.mm"
    "UIProcess/RemoteLayerTree/cocoa/RemoteScrollingTreeCocoa.mm @nonARC"
    "UIProcess/WebAuthentication/Cocoa/AuthenticationServicesSoftLink.mm @nonARC @no-unify"
    "UIProcess/WebAuthentication/Cocoa/HidConnection.mm @nonARC"
    "UIProcess/WebAuthentication/Cocoa/HidService.mm @nonARC"
    "UIProcess/WebAuthentication/Cocoa/WebAuthenticatorCoordinatorProxy.mm @nonARC"
    "UIProcess/WebAuthentication/Virtual/VirtualAuthenticatorUtils.mm @nonARC"
    "UIProcess/WebAuthentication/Virtual/VirtualLocalConnection.mm @nonARC"
    "UIProcess/WebAuthentication/Virtual/VirtualService.mm @nonARC"
    "UIProcess/mac/_WKCaptionStyleMenuControllerMac.mm @nonARC"
    "WebProcess/WebPage/Cocoa/PositionInformationForWebPage.mm @nonARC"
)

MAVERICKS_FILTER_SOURCE_LIST("${WEBKIT_DIR}" WebKit_UNIFIED_SOURCE_LIST_FILES "Sources.txt" MAVERICKS_WITHHELD_WEBKIT_SOURCES MAVERICKS_ADDED_WEBKIT_SOURCES)
MAVERICKS_FILTER_SOURCE_LIST("${WEBKIT_DIR}" WebKit_UNIFIED_SOURCE_LIST_FILES "SourcesCocoa.txt" MAVERICKS_WITHHELD_WEBKIT_COCOA_SOURCES MAVERICKS_ADDED_WEBKIT_COCOA_SOURCES)
