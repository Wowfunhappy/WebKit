# MAVERICKS_BACKPORT: -ObjC++/-std=c++2b moved to per-target flags (not added globally here).
# Moved to per-target: add_definitions("-ObjC++ -std=c++2b -D__STDC_WANT_LIB_EXT1__")
find_library(APPLICATIONSERVICES_LIBRARY ApplicationServices)
find_library(CARBON_LIBRARY Carbon)
find_library(CORESERVICES_LIBRARY CoreServices)
# MAVERICKS_BACKPORT: Network.framework is 10.14+ and absent on 10.9
# Removed: Network not on 10.9
find_library(SECURITY_LIBRARY Security)
find_library(SECURITYINTERFACE_LIBRARY SecurityInterface)
find_library(QUARTZ_LIBRARY Quartz)
# MAVERICKS_BACKPORT: UniformTypeIdentifiers framework is macOS 11+ and absent on 10.9
# Removed
find_library(AVFOUNDATION_LIBRARY AVFoundation)
# MAVERICKS_BACKPORT: AVFAudio not on 10.9
# Removed: AVFAudio not on 10.9
# MAVERICKS_BACKPORT: DeviceIdentity PrivateFramework not on 10.9
# Removed: DeviceIdentity not on 10.9
add_definitions(-iframework ${QUARTZ_LIBRARY}/Frameworks)
add_definitions(-iframework ${CARBON_LIBRARY}/Frameworks)
add_definitions(-iframework ${APPLICATIONSERVICES_LIBRARY}/Versions/Current/Frameworks)
add_definitions(-DWK_XPC_SERVICE_SUFFIX=".Development")

set(MACOSX_FRAMEWORK_IDENTIFIER com.apple.WebKit)

add_definitions(-iframework ${CORESERVICES_LIBRARY}/Versions/Current/Frameworks)

include(Headers.cmake)

list(APPEND WebKit_PRIVATE_LIBRARIES

# MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
#     Accessibility
# (end MAVERICKS_BACKPORT restored block)
    WebKitLegacy
    ${APPLICATIONSERVICES_LIBRARY}
    ${CORESERVICES_LIBRARY}
# MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
#     ${DEVICEIDENTITY_LIBRARY}
#     ${NETWORK_LIBRARY}
# (end MAVERICKS_BACKPORT restored block)
    ${SECURITYINTERFACE_LIBRARY}
# MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
#     ${UNIFORMTYPEIDENTIFIERS_LIBRARY}
# (end MAVERICKS_BACKPORT restored block)
)

if (NOT AVFAUDIO_LIBRARY-NOTFOUND)
    list(APPEND WebKit_LIBRARIES ${AVFAUDIO_LIBRARY})
endif ()

# MAVERICKS_BACKPORT: ObjC class stubs removed - assembly-generated OBJC_CLASS symbols have invalid
# metadata and crash the ObjC runtime's map_images_nolock on 10.9.
# These classes are resolved via -undefined dynamic_lookup at runtime.

list(APPEND WebKit_UNIFIED_SOURCE_LIST_FILES
    "SourcesCocoa.txt"

    "Platform/SourcesCocoa.txt"
)

list(APPEND WebKit_SOURCES
    GPUProcess/media/RemoteAudioDestinationManager.cpp

    NetworkProcess/cocoa/LaunchServicesDatabaseObserver.mm
    # MAVERICKS_BACKPORT: re-enabled. NSURLSessionWebSocket* are 10.15+ classes but exist in the build
    # SDK so this compiles/links; at runtime NetworkSessionCocoa::createWebSocketTask returns nullptr
    # before any instantiation when -webSocketTaskWithRequest: is unrecognized (10.9), so the body is
    # dead code there. Provides WebSocketTask::create + instance methods the always-compiled
    # NetworkSessionCocoa references.
    NetworkProcess/cocoa/WebSocketTaskCocoa.mm

    NetworkProcess/mac/NetworkConnectionToWebProcessMac.mm

    # MAVERICKS_BACKPORT: NetworkRTC sources disabled (require frameworks not available on 10.9; WebRTC is on GStreamer here).
    # WebRTC requires frameworks not available on 10.9
    # NetworkProcess/webrtc/NetworkRTCProvider.mm
    # NetworkProcess/webrtc/NetworkRTCTCPSocketCocoa.mm
    # NetworkProcess/webrtc/NetworkRTCUDPSocketCocoa.mm
    # NetworkProcess/webrtc/NetworkRTCUtilitiesCocoa.mm

    # MAVERICKS_BACKPORT: WKDownloadProgress source disabled (NSProgress/NSKeyValueChangeKey are 10.10+, absent on 10.9).
    # WKDownloadProgress requires NSProgress/NSKeyValueChangeKey (10.10+)
    # NetworkProcess/Downloads/cocoa/WKDownloadProgress.mm

    Platform/IPC/cocoa/SharedFileHandleCocoa.cpp

    Shared/API/Cocoa/WKMain.mm

    Shared/Cocoa/DefaultWebBrowserChecks.mm
    Shared/Cocoa/XPCEndpoint.mm
    Shared/Cocoa/XPCEndpointClient.mm

    UIProcess/API/Cocoa/WKContentWorld.mm
    UIProcess/API/Cocoa/_WKAuthenticationExtensionsClientOutputs.mm
    UIProcess/API/Cocoa/_WKAuthenticatorAssertionResponse.mm
    UIProcess/API/Cocoa/_WKAuthenticatorAttestationResponse.mm
    UIProcess/API/Cocoa/_WKAuthenticatorResponse.mm
    UIProcess/API/Cocoa/_WKResourceLoadStatisticsFirstParty.mm
    UIProcess/API/Cocoa/_WKResourceLoadStatisticsThirdParty.mm

    UIProcess/Cocoa/PreferenceObserver.mm
# MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
#     UIProcess/Cocoa/WKSafeBrowsingWarning.mm
# (end MAVERICKS_BACKPORT restored block)
    UIProcess/Cocoa/WKShareSheet.mm
    UIProcess/Cocoa/WKStorageAccessAlert.mm
    UIProcess/Cocoa/WebInspectorPreferenceObserver.mm
    UIProcess/Cocoa/XPCConnectionTerminationWatchdog.mm

    UIProcess/PDF/WKPDFHUDView.mm
    UIProcess/PDF/WKPDFPageNumberIndicator.mm

    WebProcess/InjectedBundle/API/c/mac/WKBundlePageMac.mm

    WebProcess/WebAuthentication/WebAuthenticatorCoordinator.cpp

    # MAVERICKS_BACKPORT: AudioSessionRoutingArbitrator source disabled (requires ENABLE_ROUTING_ARBITRATION / GPU process, off on 10.9).
    # AudioSessionRoutingArbitrator requires ENABLE_ROUTING_ARBITRATION (GPU process)
    # WebProcess/cocoa/AudioSessionRoutingArbitrator.cpp
    WebProcess/cocoa/HandleXPCEndpointMessages.mm
    WebProcess/cocoa/LaunchServicesDatabaseManager.mm
)

list(APPEND WebKit_PRIVATE_INCLUDE_DIRECTORIES
    "${CMAKE_BINARY_DIR}/libwebrtc/PrivateHeaders"
    "${ICU_INCLUDE_DIRS}"
    # MAVERICKS_BACKPORT: WebKit Cocoa init now calls PAL::GCrypt::initialize().
    "${MAVERICKS_DEPS}/include"
    "${WEBKIT_DIR}/GPUProcess/mac"
    "${WEBKIT_DIR}/NetworkProcess/cocoa"
    "${WEBKIT_DIR}/NetworkProcess/mac"
    "${WEBKIT_DIR}/NetworkProcess/PrivateClickMeasurement/cocoa"
    "${WEBKIT_DIR}/UIProcess/mac"
    "${WEBKIT_DIR}/UIProcess/API/C/mac"
    "${WEBKIT_DIR}/UIProcess/API/Cocoa"
    "${WEBKIT_DIR}/UIProcess/API/mac"
    "${WEBKIT_DIR}/UIProcess/Authentication/cocoa"
    # MAVERICKS_BACKPORT: WKWebViewTesting.mm imports WKContentViewInteraction.h unconditionally
    # (its content is entirely PLATFORM(IOS_FAMILY)-guarded); the Xcode build resolves project
    # headers by name, so the CMake port needs the ios dir on the include path for parity.
    "${WEBKIT_DIR}/UIProcess/ios"
    "${WEBKIT_DIR}/UIProcess/Cocoa"
    "${WEBKIT_DIR}/UIProcess/Cocoa/SOAuthorization"
    "${WEBKIT_DIR}/UIProcess/Inspector/Cocoa"
    "${WEBKIT_DIR}/UIProcess/Inspector/mac"
    "${WEBKIT_DIR}/UIProcess/Launcher/mac"
    "${WEBKIT_DIR}/UIProcess/Media/cocoa"
    "${WEBKIT_DIR}/UIProcess/Notifications/cocoa"
    "${WEBKIT_DIR}/UIProcess/PDF"
    "${WEBKIT_DIR}/UIProcess/RemoteLayerTree"
    "${WEBKIT_DIR}/UIProcess/RemoteLayerTree/cocoa"
    "${WEBKIT_DIR}/UIProcess/RemoteLayerTree/mac"
    "${WEBKIT_DIR}/UIProcess/WebAuthentication/Cocoa"
    "${WEBKIT_DIR}/Platform/cg"
    "${WEBKIT_DIR}/Platform/classifier"
    "${WEBKIT_DIR}/Platform/classifier/cocoa"
    "${WEBKIT_DIR}/Platform/cocoa"
    "${WEBKIT_DIR}/Platform/mac"
    "${WEBKIT_DIR}/Platform/unix"
    "${WEBKIT_DIR}/Platform/spi/Cocoa"
    "${WEBKIT_DIR}/Platform/spi/mac"
    "${WEBKIT_DIR}/Platform/IPC/mac"
    "${WEBKIT_DIR}/Platform/IPC/cocoa"
    "${WEBKIT_DIR}/Platform/spi/Cocoa"
    "${WEBKIT_DIR}/Shared/API/Cocoa"
    "${WEBKIT_DIR}/Shared/API/c/cf"
    "${WEBKIT_DIR}/Shared/API/c/cg"
    "${WEBKIT_DIR}/Shared/API/c/mac"
    "${WEBKIT_DIR}/Shared/ApplePay/cocoa/"
    "${WEBKIT_DIR}/Shared/Authentication/cocoa"
    "${WEBKIT_DIR}/Shared/cf"
    "${WEBKIT_DIR}/Shared/Cocoa"
    "${WEBKIT_DIR}/Shared/Daemon"
    "${WEBKIT_DIR}/Shared/EntryPointUtilities/Cocoa/Daemon"
    "${WEBKIT_DIR}/Shared/EntryPointUtilities/Cocoa/XPCService"
    "${WEBKIT_DIR}/Shared/mac"
    "${WEBKIT_DIR}/Shared/Scrolling"
    "${WEBKIT_DIR}/UIProcess/Cocoa/GroupActivities"
    "${WEBKIT_DIR}/UIProcess/Media"
    "${WEBKIT_DIR}/UIProcess/WebAuthentication/fido"
    "${WEBKIT_DIR}/WebProcess/DigitalCredentials"
    "${WEBKIT_DIR}/WebProcess/WebAuthentication"
    "${WEBKIT_DIR}/WebProcess/cocoa"
    "${WEBKIT_DIR}/WebProcess/mac"
    "${WEBKIT_DIR}/WebProcess/GPU/graphics/cocoa"
    "${WEBKIT_DIR}/WebProcess/Inspector/mac"
    "${WEBKIT_DIR}/WebProcess/InjectedBundle/API/Cocoa"
    "${WEBKIT_DIR}/WebProcess/InjectedBundle/API/mac"
    "${WEBKIT_DIR}/WebProcess/MediaSession"
    "${WEBKIT_DIR}/WebProcess/Model/mac"
    "${WEBKIT_DIR}/WebProcess/Plugins/PDF"
    "${WEBKIT_DIR}/WebProcess/WebPage/Cocoa"
    "${WEBKIT_DIR}/WebProcess/WebPage/RemoteLayerTree"
    "${WEBKIT_DIR}/WebProcess/WebPage/mac"
    "${WEBKIT_DIR}/WebProcess/WebCoreSupport/mac"
    "${WEBKIT_DIR}/webpushd"
    "${WEBKITLEGACY_DIR}"
    "${WebKitLegacy_FRAMEWORK_HEADERS_DIR}"
)

set(XPCService_SOURCES
    Shared/EntryPointUtilities/Cocoa/AuxiliaryProcessMain.cpp

    Shared/EntryPointUtilities/Cocoa/XPCService/XPCServiceEntryPoint.mm
    Shared/EntryPointUtilities/Cocoa/XPCService/XPCServiceMain.mm
)

set(WebProcess_SOURCES
    WebProcess/EntryPoint/Cocoa/XPCService/WebContentServiceEntryPoint.mm
    ${XPCService_SOURCES}
)

set(NetworkProcess_SOURCES
    NetworkProcess/EntryPoint/Cocoa/XPCService/NetworkServiceEntryPoint.mm
    ${XPCService_SOURCES}
)

set(GPUProcess_SOURCES
    GPUProcess/EntryPoint/Cocoa/XPCService/GPUServiceEntryPoint.mm
    ${XPCService_SOURCES}
)

# MAVERICKS_BACKPORT: the XPC-service executables must be named WITHOUT the
# ".Development" suffix. The WK2 process launcher (and launchd, resolving the
# .xpc bundle) execs Contents/MacOS/com.apple.WebKit.WebContent — a ".Development"
# binary name yields ENOENT ("XPC Service could not exec(3)") so the WebContent /
# Networking processes never start. The bundle directories are already named
# without the suffix; this aligns the inner executable + CFBundleExecutable.
set(WebProcess_OUTPUT_NAME com.apple.WebKit.WebContent)
set(NetworkProcess_OUTPUT_NAME com.apple.WebKit.Networking)
set(GPUProcess_OUTPUT_NAME com.apple.WebKit.GPU)

set(WebProcess_INCLUDE_DIRECTORIES ${CMAKE_BINARY_DIR})
set(NetworkProcess_INCLUDE_DIRECTORIES ${CMAKE_BINARY_DIR})

add_definitions("-include WebKit2Prefix.h")

set(WebKit_FORWARDING_HEADERS_FILES
    Platform/cocoa/WKCrashReporter.h

    Shared/API/c/WKDiagnosticLoggingResultType.h

    UIProcess/API/C/WKPageDiagnosticLoggingClient.h
    UIProcess/API/C/WKPageNavigationClient.h
    UIProcess/API/C/WKPageRenderingProgressEvents.h
)

list(APPEND WebKit_MESSAGES_IN_FILES
    GPUProcess/media/RemoteImageDecoderAVFProxy

    GPUProcess/media/ios/RemoteMediaSessionHelperProxy

    GPUProcess/webrtc/UserMediaCaptureManagerProxy

    NetworkProcess/CustomProtocols/LegacyCustomProtocolManager

    Shared/API/Cocoa/RemoteObjectRegistry

    Shared/ApplePay/WebPaymentCoordinatorProxy

    UIProcess/ViewGestureController

    UIProcess/Cocoa/PlaybackSessionManagerProxy
    # MAVERICKS_BACKPORT: VideoFullscreenManagerProxy messages disabled (requires ENABLE_VIDEO_PRESENTATION_MODE, off on 10.9).
    # VideoFullscreenManagerProxy requires ENABLE_VIDEO_PRESENTATION_MODE
    # UIProcess/Cocoa/VideoFullscreenManagerProxy

    UIProcess/Inspector/WebInspectorUIExtensionControllerProxy

    # MAVERICKS_BACKPORT: AudioSessionRoutingArbitratorProxy messages disabled (requires ENABLE_GPU_PROCESS, off on 10.9).
    # AudioSessionRoutingArbitratorProxy requires ENABLE_GPU_PROCESS
    # UIProcess/Media/AudioSessionRoutingArbitratorProxy

    UIProcess/Network/CustomProtocols/LegacyCustomProtocolManagerProxy

    UIProcess/RemoteLayerTree/RemoteLayerTreeDrawingAreaProxy

    UIProcess/WebAuthentication/WebAuthenticatorCoordinatorProxy

    UIProcess/mac/SecItemShimProxy

    WebProcess/ApplePay/WebPaymentCoordinator

    WebProcess/GPU/media/RemoteImageDecoderAVFManager

    WebProcess/GPU/media/ios/RemoteMediaSessionHelper

    WebProcess/Inspector/WebInspectorUIExtensionController

    WebProcess/WebPage/ViewGestureGeometryCollector
    WebProcess/WebPage/ViewUpdateDispatcher

    WebProcess/WebPage/Cocoa/TextCheckingControllerProxy

    WebProcess/WebPage/RemoteLayerTree/RemoteScrollingCoordinator

    WebProcess/cocoa/PlaybackSessionManager
    WebProcess/cocoa/RemoteCaptureSampleManager
    WebProcess/cocoa/UserMediaCaptureManager
    # MAVERICKS_BACKPORT: VideoFullscreenManager messages disabled (ENABLE_VIDEO_PRESENTATION_MODE off on 10.9).
    # WebProcess/cocoa/VideoFullscreenManager
)

list(APPEND WebKit_SERIALIZATION_IN_FILES
    Shared/Cocoa/CacheStoragePolicy.serialization.in
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
    Shared/Cocoa/DataDetectionResult.serialization.in
    Shared/Cocoa/InsertTextOptions.serialization.in
    Shared/Cocoa/RemoteObjectInvocation.serialization.in
    Shared/Cocoa/RevealItem.serialization.in
    Shared/Cocoa/WebCoreArgumentCodersCocoa.serialization.in
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

list(APPEND WebKit_PUBLIC_FRAMEWORK_HEADERS
    Shared/API/Cocoa/RemoteObjectInvocation.h
    Shared/API/Cocoa/RemoteObjectRegistry.h
    Shared/API/Cocoa/WKBrowsingContextHandle.h
    Shared/API/Cocoa/WKDataDetectorTypes.h
    Shared/API/Cocoa/WKDragDestinationAction.h
    Shared/API/Cocoa/WKFoundation.h
    Shared/API/Cocoa/WKMain.h
    Shared/API/Cocoa/WKRemoteObject.h
    Shared/API/Cocoa/WKRemoteObjectCoder.h
    Shared/API/Cocoa/WebKit.h
    Shared/API/Cocoa/WebKitPrivate.h
    Shared/API/Cocoa/_WKFrameHandle.h
    Shared/API/Cocoa/_WKHitTestResult.h
    Shared/API/Cocoa/_WKNSFileManagerExtras.h
    Shared/API/Cocoa/_WKNSWindowExtras.h
    Shared/API/Cocoa/_WKRemoteObjectInterface.h
    Shared/API/Cocoa/_WKRemoteObjectRegistry.h
    Shared/API/Cocoa/_WKRenderingProgressEvents.h
    Shared/API/Cocoa/_WKSameDocumentNavigationType.h

    Shared/API/c/cf/WKErrorCF.h
    Shared/API/c/cf/WKStringCF.h
    Shared/API/c/cf/WKURLCF.h

    Shared/API/c/cg/WKImageCG.h

    Shared/API/c/mac/WKBaseMac.h
    Shared/API/c/mac/WKCertificateInfoMac.h
    Shared/API/c/mac/WKObjCTypeWrapperRef.h
    Shared/API/c/mac/WKURLRequestNS.h
    Shared/API/c/mac/WKURLResponseNS.h
    Shared/API/c/mac/WKWebArchiveRef.h
    Shared/API/c/mac/WKWebArchiveResource.h

    UIProcess/API/C/mac/WKContextPrivateMac.h
    UIProcess/API/C/mac/WKInspectorPrivateMac.h
    UIProcess/API/C/mac/WKPagePrivateMac.h
    UIProcess/API/C/mac/WKProtectionSpaceNS.h
    UIProcess/API/C/mac/WKWebsiteDataStoreRefPrivateMac.h

    UIProcess/API/Cocoa/NSAttributedString.h
    UIProcess/API/Cocoa/NSAttributedStringPrivate.h
    UIProcess/API/Cocoa/PageLoadStateObserver.h
    UIProcess/API/Cocoa/WKBackForwardList.h
    UIProcess/API/Cocoa/WKBackForwardListItem.h
    UIProcess/API/Cocoa/WKBackForwardListItemPrivate.h
    UIProcess/API/Cocoa/WKBackForwardListPrivate.h
    UIProcess/API/Cocoa/WKBrowsingContextController.h
    UIProcess/API/Cocoa/WKBrowsingContextControllerPrivate.h
    UIProcess/API/Cocoa/WKBrowsingContextGroup.h
    UIProcess/API/Cocoa/WKBrowsingContextGroupPrivate.h
    UIProcess/API/Cocoa/WKBrowsingContextHistoryDelegate.h
    UIProcess/API/Cocoa/WKBrowsingContextLoadDelegate.h
    UIProcess/API/Cocoa/WKBrowsingContextLoadDelegatePrivate.h
    UIProcess/API/Cocoa/WKBrowsingContextPolicyDelegate.h
    UIProcess/API/Cocoa/WKConnection.h
    UIProcess/API/Cocoa/WKContentRuleList.h
    UIProcess/API/Cocoa/WKContentRuleListPrivate.h
    UIProcess/API/Cocoa/WKContentRuleListStore.h
    UIProcess/API/Cocoa/WKContentRuleListStorePrivate.h
    UIProcess/API/Cocoa/WKContentWorld.h
    UIProcess/API/Cocoa/WKContentWorldConfiguration.h
    UIProcess/API/Cocoa/WKContentWorldPrivate.h
    UIProcess/API/Cocoa/WKContextMenuElementInfo.h
    UIProcess/API/Cocoa/WKContextMenuElementInfoPrivate.h
    UIProcess/API/Cocoa/WKDownload.h
    UIProcess/API/Cocoa/WKDownloadDelegate.h
    UIProcess/API/Cocoa/WKError.h
    UIProcess/API/Cocoa/WKErrorPrivate.h
    UIProcess/API/Cocoa/WKFindConfiguration.h
    UIProcess/API/Cocoa/WKFindResult.h
    UIProcess/API/Cocoa/WKFrameInfo.h
    UIProcess/API/Cocoa/WKFrameInfoPrivate.h
    UIProcess/API/Cocoa/WKHTTPCookieStore.h
    UIProcess/API/Cocoa/WKHTTPCookieStorePrivate.h
    UIProcess/API/Cocoa/WKHistoryDelegatePrivate.h
    # MAVERICKS_BACKPORT: forward these headers (referenced via <WebKit/...> but missing upstream from the list).
    UIProcess/API/Cocoa/WKJSScriptingBuffer.h
    UIProcess/API/Cocoa/WKJSSerializedNode.h
    UIProcess/API/Cocoa/WKMenuItemIdentifiersPrivate.h
    UIProcess/API/Cocoa/WKNSURLAuthenticationChallenge.h
    UIProcess/API/Cocoa/WKNavigation.h
    UIProcess/API/Cocoa/WKNavigationAction.h
    UIProcess/API/Cocoa/WKNavigationActionPrivate.h
    UIProcess/API/Cocoa/WKNavigationData.h
    UIProcess/API/Cocoa/WKNavigationDelegate.h
    UIProcess/API/Cocoa/WKNavigationDelegatePrivate.h
    UIProcess/API/Cocoa/WKNavigationPrivate.h
    UIProcess/API/Cocoa/WKNavigationResponse.h
    UIProcess/API/Cocoa/WKNavigationResponsePrivate.h
    UIProcess/API/Cocoa/WKOpenPanelParameters.h
    UIProcess/API/Cocoa/WKOpenPanelParametersPrivate.h
    UIProcess/API/Cocoa/WKPDFConfiguration.h
    UIProcess/API/Cocoa/WKPreferences.h
    UIProcess/API/Cocoa/WKPreferencesPrivate.h
    UIProcess/API/Cocoa/WKPreviewActionItem.h
    UIProcess/API/Cocoa/WKPreviewActionItemIdentifiers.h
    UIProcess/API/Cocoa/WKPreviewElementInfo.h
    UIProcess/API/Cocoa/WKProcessGroup.h
    UIProcess/API/Cocoa/WKProcessGroupPrivate.h
    UIProcess/API/Cocoa/WKProcessPool.h
    UIProcess/API/Cocoa/WKProcessPoolPrivate.h
    UIProcess/API/Cocoa/WKScriptMessage.h
    UIProcess/API/Cocoa/WKScriptMessageHandler.h
    UIProcess/API/Cocoa/WKScriptMessageHandlerWithReply.h
    UIProcess/API/Cocoa/WKSecurityOrigin.h
    UIProcess/API/Cocoa/WKSecurityOriginPrivate.h
    UIProcess/API/Cocoa/WKSnapshotConfiguration.h
    UIProcess/API/Cocoa/WKUIDelegate.h
    UIProcess/API/Cocoa/WKUIDelegatePrivate.h
    UIProcess/API/Cocoa/WKURLSchemeHandler.h
    UIProcess/API/Cocoa/WKURLSchemeTask.h
    UIProcess/API/Cocoa/WKURLSchemeTaskPrivate.h
    UIProcess/API/Cocoa/WKUserContentController.h
    UIProcess/API/Cocoa/WKUserContentControllerPrivate.h
    UIProcess/API/Cocoa/WKUserScript.h
    UIProcess/API/Cocoa/WKUserScriptPrivate.h
    UIProcess/API/Cocoa/WKView.h
    UIProcess/API/Cocoa/WKViewPrivate.h
    UIProcess/API/Cocoa/WKWebArchive.h
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
    UIProcess/API/Cocoa/WKWebView.h
    UIProcess/API/Cocoa/WKWebViewConfiguration.h
    UIProcess/API/Cocoa/WKWebViewConfigurationPrivate.h
    UIProcess/API/Cocoa/WKWebViewPrivate.h
    UIProcess/API/Cocoa/WKWebViewPrivateForTesting.h
    UIProcess/API/Cocoa/WKWebpagePreferences.h
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
    UIProcess/API/Cocoa/WKWebpagePreferencesPrivate.h
    UIProcess/API/Cocoa/WKWebsiteDataRecord.h
    UIProcess/API/Cocoa/WKWebsiteDataRecordPrivate.h
    UIProcess/API/Cocoa/WKWebsiteDataStore.h
    UIProcess/API/Cocoa/WKWebsiteDataStorePrivate.h
    UIProcess/API/Cocoa/WKWindowFeatures.h
    UIProcess/API/Cocoa/WKWindowFeaturesPrivate.h
    UIProcess/API/Cocoa/WebKitLegacy.h
    UIProcess/API/Cocoa/_WKActivatedElementInfo.h
    UIProcess/API/Cocoa/_WKAppHighlight.h
    UIProcess/API/Cocoa/_WKAppHighlightDelegate.h
    UIProcess/API/Cocoa/_WKApplicationManifest.h
    UIProcess/API/Cocoa/_WKAttachment.h
    UIProcess/API/Cocoa/_WKAuthenticationExtensionsClientInputs.h
    UIProcess/API/Cocoa/_WKAuthenticationExtensionsClientOutputs.h
    UIProcess/API/Cocoa/_WKAuthenticatorAssertionResponse.h
    UIProcess/API/Cocoa/_WKAuthenticatorAttachment.h
    UIProcess/API/Cocoa/_WKAuthenticatorAttestationResponse.h
    UIProcess/API/Cocoa/_WKAuthenticatorResponse.h
    UIProcess/API/Cocoa/_WKAuthenticatorSelectionCriteria.h
    UIProcess/API/Cocoa/_WKAutomationDelegate.h
    UIProcess/API/Cocoa/_WKAutomationSession.h
    UIProcess/API/Cocoa/_WKAutomationSessionConfiguration.h
    UIProcess/API/Cocoa/_WKAutomationSessionDelegate.h
    UIProcess/API/Cocoa/_WKContentRuleListAction.h
    UIProcess/API/Cocoa/_WKContextMenuElementInfo.h
    UIProcess/API/Cocoa/_WKCustomHeaderFields.h
    UIProcess/API/Cocoa/_WKDiagnosticLoggingDelegate.h
    UIProcess/API/Cocoa/_WKDownload.h
    UIProcess/API/Cocoa/_WKDownloadDelegate.h
    UIProcess/API/Cocoa/_WKElementAction.h
    UIProcess/API/Cocoa/_WKErrorRecoveryAttempting.h
    UIProcess/API/Cocoa/_WKExperimentalFeature.h
    # MAVERICKS_BACKPORT: forward this header (referenced via <WebKit/...> but missing upstream from the list).
    UIProcess/API/Cocoa/_WKFeature.h
    UIProcess/API/Cocoa/_WKFindDelegate.h
    UIProcess/API/Cocoa/_WKFindOptions.h
    UIProcess/API/Cocoa/_WKFocusedElementInfo.h
    UIProcess/API/Cocoa/_WKFormInputSession.h
    UIProcess/API/Cocoa/_WKFrameTreeNode.h
    UIProcess/API/Cocoa/_WKFullscreenDelegate.h
    UIProcess/API/Cocoa/_WKGeolocationCoreLocationProvider.h
    UIProcess/API/Cocoa/_WKGeolocationPosition.h
    UIProcess/API/Cocoa/_WKIconLoadingDelegate.h
    UIProcess/API/Cocoa/_WKInputDelegate.h
    UIProcess/API/Cocoa/_WKInspector.h
    UIProcess/API/Cocoa/_WKInspectorConfiguration.h
    UIProcess/API/Cocoa/_WKInspectorDebuggableInfo.h
    UIProcess/API/Cocoa/_WKInspectorDelegate.h
    UIProcess/API/Cocoa/_WKInspectorExtension.h
    UIProcess/API/Cocoa/_WKInspectorExtensionDelegate.h
    UIProcess/API/Cocoa/_WKInspectorExtensionHost.h
    UIProcess/API/Cocoa/_WKInspectorIBActions.h
    UIProcess/API/Cocoa/_WKInspectorPrivate.h
    UIProcess/API/Cocoa/_WKInspectorPrivateForTesting.h
    UIProcess/API/Cocoa/_WKInspectorWindow.h
    UIProcess/API/Cocoa/_WKInternalDebugFeature.h
    UIProcess/API/Cocoa/_WKLayoutMode.h
    UIProcess/API/Cocoa/_WKLinkIconParameters.h
    UIProcess/API/Cocoa/_WKOverlayScrollbarStyle.h
    UIProcess/API/Cocoa/_WKProcessPoolConfiguration.h
    UIProcess/API/Cocoa/_WKPublicKeyCredentialCreationOptions.h
    UIProcess/API/Cocoa/_WKPublicKeyCredentialDescriptor.h
    UIProcess/API/Cocoa/_WKPublicKeyCredentialEntity.h
    UIProcess/API/Cocoa/_WKPublicKeyCredentialParameters.h
    UIProcess/API/Cocoa/_WKPublicKeyCredentialRelyingPartyEntity.h
    UIProcess/API/Cocoa/_WKPublicKeyCredentialRequestOptions.h
    UIProcess/API/Cocoa/_WKPublicKeyCredentialUserEntity.h
    UIProcess/API/Cocoa/_WKRemoteWebInspectorViewController.h
    UIProcess/API/Cocoa/_WKRemoteWebInspectorViewControllerPrivate.h
    # MAVERICKS_BACKPORT: forward this header (referenced via <WebKit/...> but missing upstream from the list).
    UIProcess/API/Cocoa/_WKResidentKeyRequirement.h
    UIProcess/API/Cocoa/_WKResourceLoadDelegate.h
    UIProcess/API/Cocoa/_WKResourceLoadInfo.h
    UIProcess/API/Cocoa/_WKResourceLoadStatisticsFirstParty.h
    UIProcess/API/Cocoa/_WKResourceLoadStatisticsThirdParty.h
    UIProcess/API/Cocoa/_WKSessionState.h
    UIProcess/API/Cocoa/_WKSystemPreferences.h
    UIProcess/API/Cocoa/_WKTapHandlingResult.h
    UIProcess/API/Cocoa/_WKTextInputContext.h
    UIProcess/API/Cocoa/_WKTextManipulationConfiguration.h
    UIProcess/API/Cocoa/_WKTextManipulationDelegate.h
    UIProcess/API/Cocoa/_WKTextManipulationExclusionRule.h
    UIProcess/API/Cocoa/_WKTextManipulationItem.h
    UIProcess/API/Cocoa/_WKTextManipulationToken.h
    # MAVERICKS_BACKPORT: forward this header (referenced via <WebKit/...> but missing upstream from the list).
    UIProcess/API/Cocoa/_WKTextPreview.h
    UIProcess/API/Cocoa/_WKThumbnailView.h
    UIProcess/API/Cocoa/_WKUserContentWorld.h
    UIProcess/API/Cocoa/_WKUserInitiatedAction.h
    UIProcess/API/Cocoa/_WKUserStyleSheet.h
    UIProcess/API/Cocoa/_WKUserVerificationRequirement.h
    UIProcess/API/Cocoa/_WKVisitedLinkStore.h
    UIProcess/API/Cocoa/_WKWebAuthenticationAssertionResponse.h
    UIProcess/API/Cocoa/_WKWebAuthenticationPanel.h
    UIProcess/API/Cocoa/_WKWebAuthenticationPanelForTesting.h
    UIProcess/API/Cocoa/_WKWebsiteDataSize.h
    UIProcess/API/Cocoa/_WKWebsiteDataStoreConfiguration.h
    UIProcess/API/Cocoa/_WKWebsiteDataStoreDelegate.h

    UIProcess/API/mac/WKWebViewPrivateForTestingMac.h

    UIProcess/Cocoa/WKShareSheet.h

    WebProcess/InjectedBundle/API/Cocoa/WKWebProcessBundleParameters.h
    WebProcess/InjectedBundle/API/Cocoa/WKWebProcessPlugInCSSStyleDeclarationHandle.h
    WebProcess/InjectedBundle/API/Cocoa/WKWebProcessPlugInEditingDelegate.h
    WebProcess/InjectedBundle/API/Cocoa/WKWebProcessPlugInFormDelegatePrivate.h
    WebProcess/InjectedBundle/API/Cocoa/WKWebProcessPlugInFrame.h
    WebProcess/InjectedBundle/API/Cocoa/WKWebProcessPlugInFramePrivate.h
    WebProcess/InjectedBundle/API/Cocoa/WKWebProcessPlugInHitTestResult.h
    WebProcess/InjectedBundle/API/Cocoa/WKWebProcessPlugInLoadDelegate.h
    WebProcess/InjectedBundle/API/Cocoa/WKWebProcessPlugInNodeHandle.h
    WebProcess/InjectedBundle/API/Cocoa/WKWebProcessPlugInNodeHandlePrivate.h
    WebProcess/InjectedBundle/API/Cocoa/WKWebProcessPlugInPageGroup.h
    WebProcess/InjectedBundle/API/Cocoa/WKWebProcessPlugInRangeHandle.h
    WebProcess/InjectedBundle/API/Cocoa/WKWebProcessPlugInScriptWorld.h

    WebProcess/InjectedBundle/API/mac/WKDOMDocument.h
    WebProcess/InjectedBundle/API/mac/WKDOMElement.h
    WebProcess/InjectedBundle/API/mac/WKDOMInternals.h
    WebProcess/InjectedBundle/API/mac/WKDOMNode.h
    WebProcess/InjectedBundle/API/mac/WKDOMNodePrivate.h
    WebProcess/InjectedBundle/API/mac/WKDOMRange.h
    WebProcess/InjectedBundle/API/mac/WKDOMRangePrivate.h
    WebProcess/InjectedBundle/API/mac/WKDOMText.h
    WebProcess/InjectedBundle/API/mac/WKDOMTextIterator.h
    WebProcess/InjectedBundle/API/mac/WKWebProcessPlugIn.h
    WebProcess/InjectedBundle/API/mac/WKWebProcessPlugInBrowserContextController.h
    WebProcess/InjectedBundle/API/mac/WKWebProcessPlugInBrowserContextControllerPrivate.h
    WebProcess/InjectedBundle/API/mac/WKWebProcessPlugInPrivate.h
)

set(WebKit_FORWARDING_HEADERS_DIRECTORIES
    Platform
    Shared

    NetworkProcess/Downloads

    Platform/IPC

    Shared/API
    Shared/Cocoa

    Shared/API/Cocoa
    Shared/API/c

    Shared/API/c/cf
    Shared/API/c/mac

    UIProcess/Cocoa

    UIProcess/API/C

    UIProcess/API/C/Cocoa
    UIProcess/API/C/mac
    UIProcess/API/cpp

    WebProcess/InjectedBundle/API/Cocoa
    WebProcess/InjectedBundle/API/c
    WebProcess/InjectedBundle/API/mac
)

# FIXME: Forwarding headers should be complete copies of the header.
set(WebKitLegacyForwardingHeaders
    DOM.h
    DOMCore.h
    DOMElement.h
    DOMException.h
    DOMObject.h
    DOMPrivate.h
    WebApplicationCache.h
    WebCache.h
    WebCoreStatistics.h
    WebDOMOperations.h
    WebDOMOperationsPrivate.h
    WebDatabaseManagerPrivate.h
    WebDataSource.h
    WebDataSourcePrivate.h
    WebDefaultPolicyDelegate.h
    WebDeviceOrientation.h
    WebDeviceOrientationProviderMock.h
    WebDocument.h
    WebDocumentPrivate.h
    WebDynamicScrollBarsView.h
    WebEditingDelegate.h
    WebFrame.h
    WebFramePrivate.h
    WebFrameViewPrivate.h
    WebGeolocationPosition.h
    WebHTMLRepresentation.h
    WebHTMLView.h
    WebHTMLViewPrivate.h
    WebHistory.h
    WebHistoryItem.h
    WebHistoryItemPrivate.h
    WebHistoryPrivate.h
    WebIconDatabasePrivate.h
    WebInspector.h
    WebInspectorPrivate.h
    WebKitNSStringExtras.h
    WebNSURLExtras.h
    WebNavigationData.h
    WebNotification.h
    WebPluginDatabase.h
    WebPolicyDelegate.h
    WebPolicyDelegatePrivate.h
    WebPreferenceKeysPrivate.h
    WebPreferences.h
    WebPreferencesPrivate.h
    WebQuotaManager.h
    WebScriptWorld.h
    WebSecurityOriginPrivate.h
    WebStorageManagerPrivate.h
    WebTypesInternal.h
    WebUIDelegate.h
    WebUIDelegatePrivate.h
    WebView.h
    WebViewPrivate
    WebViewPrivate.h
)

set(ObjCForwardingHeaders
    DOMAbstractView.h
    DOMAttr.h
    DOMBeforeLoadEvent.h
    DOMBlob.h
    DOMCDATASection.h
    DOMCSSCharsetRule.h
    DOMCSSFontFaceRule.h
    DOMCSSImportRule.h
    DOMCSSKeyframeRule.h
    DOMCSSKeyframesRule.h
    DOMCSSMediaRule.h
    DOMCSSPageRule.h
    DOMCSSPrimitiveValue.h
    DOMCSSRule.h
    DOMCSSRuleList.h
    DOMCSSStyleDeclaration.h
    DOMCSSStyleRule.h
    DOMCSSStyleSheet.h
    DOMCSSSupportsRule.h
    DOMCSSUnknownRule.h
    DOMCSSValue.h
    DOMCSSValueList.h
    DOMCharacterData.h
    DOMComment.h
    DOMCounter.h
    DOMDOMImplementation.h
    DOMDOMNamedFlowCollection.h
    DOMDOMTokenList.h
    DOMDocument.h
    DOMDocumentFragment.h
    DOMDocumentType.h
    DOMElement.h
    DOMEntity.h
    DOMEntityReference.h
    DOMEvent.h
    DOMEventException.h
    DOMEventListener.h
    DOMEventTarget.h
    DOMFile.h
    DOMFileList.h
    DOMHTMLAnchorElement.h
    DOMHTMLAppletElement.h
    DOMHTMLAreaElement.h
    DOMHTMLBRElement.h
    DOMHTMLBaseElement.h
    DOMHTMLBaseFontElement.h
    DOMHTMLBodyElement.h
    DOMHTMLButtonElement.h
    DOMHTMLCanvasElement.h
    DOMHTMLCollection.h
    DOMHTMLDListElement.h
    DOMHTMLDirectoryElement.h
    DOMHTMLDivElement.h
    DOMHTMLDocument.h
    DOMHTMLElement.h
    DOMHTMLEmbedElement.h
    DOMHTMLFieldSetElement.h
    DOMHTMLFontElement.h
    DOMHTMLFormElement.h
    DOMHTMLFrameElement.h
    DOMHTMLFrameSetElement.h
    DOMHTMLHRElement.h
    DOMHTMLHeadElement.h
    DOMHTMLHeadingElement.h
    DOMHTMLHtmlElement.h
    DOMHTMLIFrameElement.h
    DOMHTMLImageElement.h
    DOMHTMLInputElement.h
    DOMHTMLInputElementPrivate.h
    DOMHTMLLIElement.h
    DOMHTMLLabelElement.h
    DOMHTMLLegendElement.h
    DOMHTMLLinkElement.h
    DOMHTMLMapElement.h
    DOMHTMLMarqueeElement.h
    DOMHTMLMediaElement.h
    DOMHTMLMenuElement.h
    DOMHTMLMetaElement.h
    DOMHTMLModElement.h
    DOMHTMLOListElement.h
    DOMHTMLObjectElement.h
    DOMHTMLOptGroupElement.h
    DOMHTMLOptionElement.h
    DOMHTMLOptionsCollection.h
    DOMHTMLParagraphElement.h
    DOMHTMLParamElement.h
    DOMHTMLPreElement.h
    DOMHTMLQuoteElement.h
    DOMHTMLScriptElement.h
    DOMHTMLSelectElement.h
    DOMHTMLStyleElement.h
    DOMHTMLTableCaptionElement.h
    DOMHTMLTableCellElement.h
    DOMHTMLTableColElement.h
    DOMHTMLTableElement.h
    DOMHTMLTableRowElement.h
    DOMHTMLTableSectionElement.h
    DOMHTMLTextAreaElement.h
    DOMHTMLTitleElement.h
    DOMHTMLUListElement.h
    DOMHTMLVideoElement.h
    DOMImplementation.h
    DOMKeyboardEvent.h
    DOMMediaError.h
    DOMMediaList.h
    DOMMessageEvent.h
    DOMMessagePort.h
    DOMMouseEvent.h
    DOMMutationEvent.h
    DOMNamedNodeMap.h
    DOMNode.h
    DOMNodeFilter.h
    DOMNodeIterator.h
    DOMNodeList.h
    DOMOverflowEvent.h
    DOMProcessingInstruction.h
    DOMProgressEvent.h
    DOMRGBColor.h
    DOMRange.h
    DOMRangeException.h
    DOMRect.h
    DOMStyleSheet.h
    DOMStyleSheetList.h
    DOMText.h
    DOMTextEvent.h
    DOMTimeRanges.h
    DOMTreeWalker.h
    DOMUIEvent.h
    DOMValidityState.h
    DOMWebKitCSSFilterValue.h
    DOMWebKitCSSRegionRule.h
    DOMWebKitCSSTransformValue.h
    DOMWebKitNamedFlow.h
    DOMWheelEvent.h
    DOMXPathException.h
    DOMXPathExpression.h
    DOMXPathNSResolver.h
    DOMXPathResult.h
)

# MAVERICKS_BACKPORT: quote the linker-flags append (preserve prior flags) and drop -framework AuthKit (AuthKit absent on 10.9).
set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -compatibility_version 1 -current_version ${WEBKIT_MAC_VERSION}")
target_link_options(WebKit PRIVATE -lsandbox)

set(WebKit_OUTPUT_NAME WebKit)

# XPC Services

function(WEBKIT_DEFINE_XPC_SERVICES)
    # MAVERICKS_BACKPORT: the modern "_WebKit" RunLoopType is unknown to 10.9's libxpc, which then falls
    # back to dispatch_main() — that parks the main thread, so the main GCD queue is drained by a
    # worker whose idle->active wakeup latency is ~166ms (~6Hz), throttling timers/rAF/page loads.
    # "NSRunLoop" makes xpc_main run a real run loop on the main thread, which drains the main queue
    # with immediate (dispatch-port) wakeups — fixing the throttle at its source instead of papering
    # over it with a display-link heartbeat.
    set(RUNLOOP_TYPE NSRunLoop)
    set(WebKit_XPC_SERVICE_DIR ${CMAKE_LIBRARY_OUTPUT_DIRECTORY}/WebKit.framework/Versions/A/XPCServices)
    WEBKIT_CREATE_SYMLINK(WebProcess ${WebKit_XPC_SERVICE_DIR} ${CMAKE_LIBRARY_OUTPUT_DIRECTORY}/WebKit.framework/XPCServices)

    function(WEBKIT_XPC_SERVICE _target _bundle_identifier _info_plist _executable_name)
        set(_service_dir ${WebKit_XPC_SERVICE_DIR}/${_bundle_identifier}.xpc/Contents)
        make_directory(${_service_dir}/MacOS)
        make_directory(${_service_dir}/_CodeSignature)
        make_directory(${_service_dir}/Resources)

        # FIXME: These version strings don't match Xcode's.
        set(BUNDLE_VERSION ${WEBKIT_VERSION})
        set(SHORT_VERSION_STRING ${WEBKIT_VERSION_MAJOR})
        set(BUNDLE_VERSION ${WEBKIT_VERSION})
        set(EXECUTABLE_NAME ${_executable_name})
        set(PRODUCT_BUNDLE_IDENTIFIER ${_bundle_identifier})
        set(PRODUCT_NAME ${_bundle_identifier})
        configure_file(${_info_plist} ${_service_dir}/Info.plist)

        set_target_properties(${_target} PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${_service_dir}/MacOS")
    endfunction()

    WEBKIT_XPC_SERVICE(WebProcess
        "com.apple.WebKit.WebContent"
        ${WEBKIT_DIR}/WebProcess/EntryPoint/Cocoa/XPCService/WebContentService/Info-OSX.plist
        ${WebProcess_OUTPUT_NAME})

    WEBKIT_XPC_SERVICE(NetworkProcess
        "com.apple.WebKit.Networking"
        ${WEBKIT_DIR}/NetworkProcess/EntryPoint/Cocoa/XPCService/NetworkService/Info-OSX.plist
        ${NetworkProcess_OUTPUT_NAME})

    if (ENABLE_GPU_PROCESS)
        WEBKIT_XPC_SERVICE(GPUProcess
            "com.apple.WebKit.GPU"
            ${WEBKIT_DIR}/GPUProcess/EntryPoint/Cocoa/XPCService/GPUService/Info-OSX.plist
            ${GPUProcess_OUTPUT_NAME})
    endif ()

    set(WebKit_RESOURCES_DIR ${CMAKE_LIBRARY_OUTPUT_DIRECTORY}/WebKit.framework/Versions/A/Resources)
    add_custom_command(OUTPUT ${WebKit_RESOURCES_DIR}/com.apple.WebProcess.sb COMMAND
        grep -o "^[^;]*" ${WEBKIT_DIR}/WebProcess/com.apple.WebProcess.sb.in | clang -E -P -w -include wtf/Platform.h -I ${WTF_FRAMEWORK_HEADERS_DIR} -I ${bmalloc_FRAMEWORK_HEADERS_DIR} -I ${WEBKIT_DIR} - > ${WebKit_RESOURCES_DIR}/com.apple.WebProcess.sb
        # MAVERICKS_BACKPORT: add an explicit DEPENDS so edits to the .sb.in source retrigger this rule.
        DEPENDS ${WEBKIT_DIR}/WebProcess/com.apple.WebProcess.sb.in
        VERBATIM)
    list(APPEND WebKit_SB_FILES ${WebKit_RESOURCES_DIR}/com.apple.WebProcess.sb)

    add_custom_command(OUTPUT ${WebKit_RESOURCES_DIR}/com.apple.WebKit.NetworkProcess.sb COMMAND
        grep -o "^[^;]*" ${WEBKIT_DIR}/NetworkProcess/mac/com.apple.WebKit.NetworkProcess.sb.in | clang -E -P -w -include wtf/Platform.h -I ${WTF_FRAMEWORK_HEADERS_DIR} -I ${bmalloc_FRAMEWORK_HEADERS_DIR} -I ${WEBKIT_DIR} - > ${WebKit_RESOURCES_DIR}/com.apple.WebKit.NetworkProcess.sb
        VERBATIM)
    list(APPEND WebKit_SB_FILES ${WebKit_RESOURCES_DIR}/com.apple.WebKit.NetworkProcess.sb)

    if (ENABLE_GPU_PROCESS)
        add_custom_command(OUTPUT ${WebKit_RESOURCES_DIR}/com.apple.WebKit.GPUProcess.sb COMMAND
            grep -o "^[^;]*" ${WEBKIT_DIR}/GPUProcess/mac/com.apple.WebKit.GPUProcess.sb.in | clang -E -P -w -include wtf/Platform.h -I ${WTF_FRAMEWORK_HEADERS_DIR} -I ${bmalloc_FRAMEWORK_HEADERS_DIR} -I ${WEBKIT_DIR} - > ${WebKit_RESOURCES_DIR}/com.apple.WebKit.GPUProcess.sb
            VERBATIM)
        list(APPEND WebKit_SB_FILES ${WebKit_RESOURCES_DIR}/com.apple.WebKit.GPUProcess.sb)
    endif ()
    if (ENABLE_WEB_PUSH_NOTIFICATIONS)
        add_custom_command(OUTPUT ${WebKit_RESOURCES_DIR}/com.apple.WebKit.webpushd.mac.sb COMMAND
            grep -o "^[^;]*" ${WEBKIT_DIR}/webpushd/mac/com.apple.WebKit.webpushd.mac.sb.in | clang -E -P -w -include wtf/Platform.h -I ${WTF_FRAMEWORK_HEADERS_DIR} -I ${bmalloc_FRAMEWORK_HEADERS_DIR} -I ${WEBKIT_DIR} - > ${WebKit_RESOURCES_DIR}/com.apple.WebKit.webpushd.mac.sb
            VERBATIM)
        list(APPEND WebKit_SB_FILES ${WebKit_RESOURCES_DIR}/com.apple.WebKit.webpushd.mac.sb)
    endif ()
    add_custom_target(WebKitSandboxProfiles ALL DEPENDS ${WebKit_SB_FILES})
    add_dependencies(WebKit WebKitSandboxProfiles)

    # MAVERICKS_BACKPORT: WebContentProcess.xib has no 10.9-runnable nib content; create an empty
    # placeholder .nib (make_directory + touch) instead of running ibtool on it.
    add_custom_command(OUTPUT ${WebKit_XPC_SERVICE_DIR}/com.apple.WebKit.WebContent.xpc/Contents/Resources/WebContentProcess.nib COMMAND
        ${CMAKE_COMMAND} -E make_directory ${WebKit_XPC_SERVICE_DIR}/com.apple.WebKit.WebContent.xpc/Contents/Resources
        COMMAND ${CMAKE_COMMAND} -E touch ${WebKit_XPC_SERVICE_DIR}/com.apple.WebKit.WebContent.xpc/Contents/Resources/WebContentProcess.nib
        VERBATIM)
    add_custom_target(WebContentProcessNib ALL DEPENDS ${WebKit_XPC_SERVICE_DIR}/com.apple.WebKit.WebContent.xpc/Contents/Resources/WebContentProcess.nib)
    add_dependencies(WebKit WebContentProcessNib)
endfunction()

set(WebKit_GENERATED_SERIALIZERS_SUFFIX mm)
# MAVERICKS_BACKPORT: link the classic-CoreGraphics-API forwarding shim (libcg_polyfill) for symbols absent on 10.9.
# From the build tree (NOT a stale /usr/local copy); its @rpath/libcg_polyfill.dylib install_name is resolved
# at install time to the absolute in-bundle copy, keeping the build self-contained (no /usr/local dependency).
list(APPEND WebKit_LIBRARIES ${MAVERICKS_SUPPORT}/polyfill/build/libcg_polyfill.dylib)

# MAVERICKS_BACKPORT: brotli decoder for NetworkDataTaskCocoa's response decoding — modern CFNetwork
# advertises and decodes "br" transparently; 10.9 CFNetwork passes br bodies through raw, so the
# NetworkProcess decodes them itself (same vendored static brotli WebCore's WOFF2 decoder uses).
list(APPEND WebKit_LIBRARIES
    "${MAVERICKS_DEPS}/lib/libbrotlidec.a"
    "${MAVERICKS_DEPS}/lib/libbrotlicommon.a"
)
