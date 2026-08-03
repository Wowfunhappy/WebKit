# MAVERICKS_BACKPORT: every backport change to WebKit's Mac CMake configuration.
#
# Source/WebKit/PlatformMac.cmake is kept BYTE-UPSTREAM and ends with a single `include()` of this
# file. See MavericksSupport/cmake/WebCorePlatformMavericks.cmake for the rationale.

# --------------------------------------------------------------------------
# Standalone backport blocks (targets, definitions, framework lookups, staging).
# --------------------------------------------------------------------------

# MAVERICKS_BACKPORT: Network.framework is 10.14+ and absent on 10.9
# Removed: Network not on 10.9

# MAVERICKS_BACKPORT: UniformTypeIdentifiers framework is macOS 11+ and absent on 10.9
# Removed

# MAVERICKS_BACKPORT: AVFAudio not on 10.9
# Removed: AVFAudio not on 10.9
# MAVERICKS_BACKPORT: DeviceIdentity PrivateFramework not on 10.9
# Removed: DeviceIdentity not on 10.9

# MAVERICKS_BACKPORT: ObjC class stubs removed - assembly-generated OBJC_CLASS symbols have invalid
# metadata and crash the ObjC runtime's map_images_nolock on 10.9.
# These classes are resolved via -undefined dynamic_lookup at runtime.

# MAVERICKS_BACKPORT: the XPC-service executables must be named WITHOUT the
# ".Development" suffix. The WK2 process launcher (and launchd, resolving the
# .xpc bundle) execs Contents/MacOS/com.apple.WebKit.WebContent — a ".Development"
# binary name yields ENOENT ("XPC Service could not exec(3)") so the WebContent /
# Networking processes never start. The bundle directories are already named
# without the suffix; this aligns the inner executable + CFBundleExecutable.
set(WebProcess_OUTPUT_NAME com.apple.WebKit.WebContent)
set(NetworkProcess_OUTPUT_NAME com.apple.WebKit.Networking)
set(GPUProcess_OUTPUT_NAME com.apple.WebKit.GPU)

# MAVERICKS_BACKPORT: quote the linker-flags append (preserve prior flags) and drop -framework AuthKit (AuthKit absent on 10.9).
# MAVERICKS_BACKPORT: the CCID (smart-card) WebAuthn transport hard-references TKSmartCardSlotManager from
# CryptoTokenKit, which is 10.10+. Weak-link it so WebKit still loads on 10.9 — the class resolves to nil and
# CcidService finds no smart-card slots (graceful "no CCID authenticator" degradation, like the other
# soft-linked WebAuthn backends).
target_link_options(WebKit PRIVATE -weak_framework CryptoTokenKit)
# MAVERICKS_BACKPORT: upstream's WK_WEBINSPECTORUI_LDFLAGS (WebKit.xcconfig: -weak_framework
# WebInspectorUI) — the load command dyld needs so [NSBundle bundleWithIdentifier:
# @"com.apple.WebInspectorUI"] finds the frontend bundle in every host process
# (WKInspectorResourceURLSchemeHandler RELEASE_ASSERTs on a nil bundle; iBooks crashed there).
# The xcconfig flag never made it into this CMake build. Linked by exact dylib path because the
# stock 10.9 framework is not in the modern SDK's search paths.
target_link_options(WebKit PRIVATE -weak_library /System/Library/PrivateFrameworks/WebInspectorUI.framework/Versions/A/WebInspectorUI)

# MAVERICKS_BACKPORT: weak-link the two frameworks 10.9 does not ship whose symbols WebKit references
# through @available/weak_import: Metal (10.11+; MTLCopyAllDevices etc. on the GPU-process resource-purge
# path) and Network (10.14+; the nw_* WebTransport API). Weak-linking is what makes those references
# resolve to null at load and stay bindable up front, which is what an eagerly-bound client needs.
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
target_link_options(WebKit PRIVATE "SHELL:-weak_framework Metal" "SHELL:-weak_framework Network")

    # MAVERICKS_BACKPORT: the modern "_WebKit" RunLoopType is unknown to 10.9's libxpc, which then falls
    # back to dispatch_main() — that parks the main thread, so the main GCD queue is drained by a
    # worker whose idle->active wakeup latency is ~166ms (~6Hz), throttling timers/rAF/page loads.
    # "NSRunLoop" makes xpc_main run a real run loop on the main thread, which drains the main queue
    # with immediate (dispatch-port) wakeups — fixing the throttle at its source instead of papering
    # over it with a display-link heartbeat.




# MAVERICKS_BACKPORT: brotli decoder for NetworkDataTaskCocoa's response decoding — modern CFNetwork
# advertises and decodes "br" transparently; 10.9 CFNetwork passes br bodies through raw, so the
# NetworkProcess decodes them itself (same vendored static brotli WebCore's WOFF2 decoder uses).

# --------------------------------------------------------------------------
# Entries withheld from upstream's lists. Expressed as REMOVE_ITEM rather than by
# editing upstream's file, so PlatformMac.cmake stays byte-upstream.
# --------------------------------------------------------------------------
list(REMOVE_ITEM WebKit_MESSAGES_IN_FILES
    UIProcess/Cocoa/VideoFullscreenManagerProxy
    # AudioSessionRoutingArbitratorProxy.messages.in is EnabledBy=UseGPUProcessForMediaEnabled, a
    # preference that only exists when ENABLE(GPU_PROCESS) is on; with it off the generated receiver
    # references a SharedPreferencesForWebProcess member that was never emitted.
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
    NetworkProcess/webrtc/NetworkRTCProvider.mm
    NetworkProcess/webrtc/NetworkRTCTCPSocketCocoa.mm
    NetworkProcess/webrtc/NetworkRTCUDPSocketCocoa.mm
    NetworkProcess/webrtc/NetworkRTCUtilitiesCocoa.mm
    UIProcess/Cocoa/WKSafeBrowsingWarning.mm
    WebProcess/cocoa/AudioSessionRoutingArbitrator.cpp
)

# --------------------------------------------------------------------------
# Entries added to upstream's lists.
# --------------------------------------------------------------------------
# MAVERICKS_BACKPORT: upstream compiles NetworkSoftLink.mm only from WebKit.xcodeproj and never added it to
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
    # MAVERICKS_BACKPORT: upstream's CMake Mac port still lists this by its pre-rename name,
    # UIProcess/Cocoa/VideoFullscreenManagerProxy, for which no .messages.in exists -- the file
    # upstream actually ships is VideoPresentationManagerProxy.messages.in (the class was renamed;
    # only the Xcode build, which drives Apple's Mac port, was updated). Name the real file.
    UIProcess/Cocoa/VideoPresentationManagerProxy
    # MAVERICKS_BACKPORT: same pre-rename staleness as VideoPresentationManagerProxy above.
    WebProcess/cocoa/VideoPresentationManager
)

list(APPEND WebKit_PRIVATE_INCLUDE_DIRECTORIES
    # MAVERICKS_BACKPORT: WebKit Cocoa init now calls PAL::GCrypt::initialize().
    "${MAVERICKS_DEPS}/include"
    # MAVERICKS_BACKPORT: wk_selref_scope.h (WK_POLYFILL_SEL/WK_POLYFILL_ADD registry macros) for
    # the host-safe NSURLSession webSocketTaskWithRequest: polyfill in WebSocketPolyfill_109.mm.
    "${CMAKE_SOURCE_DIR}/MavericksSupport/polyfill/mechanism"
    # MAVERICKS_BACKPORT: WKWebViewTesting.mm imports WKContentViewInteraction.h unconditionally
    # (its content is entirely PLATFORM(IOS_FAMILY)-guarded); the Xcode build resolves project
    # headers by name, so the CMake port needs the ios dir on the include path for parity.
    "${WEBKIT_DIR}/UIProcess/ios"
    # MAVERICKS_BACKPORT: WKWebView.mm, WKPreferences.mm and WebPageProxy.cpp import
    # "WKTextExtractionUtilities.h" by name; the Xcode build resolves project headers by name, so the
    # CMake port needs this dir on the include path for parity (otherwise the include silently
    # resolved to an empty placeholder and WebKit::createItem/computeSimilarity went undeclared).
    "${WEBKIT_DIR}/UIProcess/Cocoa/TextExtraction"
    # MAVERICKS_BACKPORT: needed once ENABLE(WEB_AUTHN) is on — the Digital Credentials bridge and the
    # WebKitSwift ObjC interop headers (all soft-linked at runtime, inert on 10.9) are reached via quoted
    # includes from the DigitalCredentials coordinator/bridge and WKDigitalCredentialsPicker.
    "${WEBKIT_DIR}/WebProcess/cocoa/IdentityDocumentServices"
    "${WEBKIT_DIR}/WebKitSwift/IdentityDocumentServices"
)

list(APPEND WebKit_PUBLIC_FRAMEWORK_HEADERS
    # MAVERICKS_BACKPORT: forward these headers (referenced via <WebKit/...> but missing upstream from the list).
    UIProcess/API/Cocoa/WKJSScriptingBuffer.h
    UIProcess/API/Cocoa/WKJSSerializedNode.h
    # Referenced via <WebKit/...> by, respectively, _WKWebExtensionController.h and
    # FullscreenTouchSecheuristic.h (FullscreenTouchSecheuristic.cpp is built on Mac).
    UIProcess/API/Cocoa/_WKWebExtensionWindowCreationOptions.h
    UIProcess/ios/fullscreen/FullscreenTouchSecheuristicParameters.h
    # Referenced via <WebKit/_WKWebExtensionTabCreationOptions.h> by _WKWebExtensionTab.h.
    UIProcess/API/Cocoa/_WKWebExtensionTabCreationOptions.h
    # MAVERICKS_BACKPORT: the <WebKit/WebKit.h> umbrella imports these unconditionally, but they were missing
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
    # MAVERICKS_BACKPORT: reached via <WebKit/WK...h> once ENABLE(WEB_AUTHN) is on — the Digital
    # Credentials picker and the WebKitSwift IdentityDocument interop headers cross-include each other
    # through the <WebKit/...> framework path (all soft-linked, inert on 10.9).
    UIProcess/DigitalCredentials/WKDigitalCredentialsPicker.h
    WebKitSwift/IdentityDocumentServices/WKIdentityDocumentPresentmentController.h
    WebKitSwift/IdentityDocumentServices/WKIdentityDocumentPresentmentError.h
    WebKitSwift/IdentityDocumentServices/WKIdentityDocumentPresentmentMobileDocumentRequest.h
    WebKitSwift/IdentityDocumentServices/WKIdentityDocumentPresentmentRawRequest.h
    WebKitSwift/IdentityDocumentServices/WKIdentityDocumentPresentmentRequest.h
    # MAVERICKS_BACKPORT: headers referenced via <WebKit/X.h> by generated serializers
    # and cross-including API headers, but missing from the forwarding list.
    UIProcess/API/Cocoa/WKJSHandle.h
    UIProcess/API/Cocoa/WebFeature.h
    UIProcess/API/Cocoa/_WKContentWorldConfiguration.h
    UIProcess/API/Cocoa/_WKTextExtraction.h
    UIProcess/API/Cocoa/_WKRectEdge.h
    # MAVERICKS_BACKPORT: additional Cocoa API headers reached via <WebKit/X.h> by cross-including API/private
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
    # MAVERICKS_BACKPORT: forward this header (referenced via <WebKit/...> but missing upstream from the list).
    UIProcess/API/Cocoa/_WKFeature.h
    # MAVERICKS_BACKPORT: forward this header (referenced via <WebKit/...> but missing upstream from the list).
    UIProcess/API/Cocoa/_WKResidentKeyRequirement.h
    # MAVERICKS_BACKPORT: forward this header (referenced via <WebKit/...> but missing upstream from the list).
    UIProcess/API/Cocoa/_WKTextPreview.h
)

list(APPEND WebKit_SERIALIZATION_IN_FILES
    # MAVERICKS_BACKPORT: register the CoreIPC CF/Cocoa serialization descriptors so their generated coders build.
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
    # MAVERICKS_BACKPORT: register these additional serialization descriptors so their generated coders build.
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
