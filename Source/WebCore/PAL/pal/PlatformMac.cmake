list(APPEND PAL_PUBLIC_HEADERS
    avfoundation/MediaTimeAVFoundation.h
    avfoundation/OutputContext.h
    avfoundation/OutputDevice.h

    # MAVERICKS_BACKPORT: WebCrypto via libgcrypt requires these to be reachable from
    # WebCore via the <pal/crypto/...> include path.
    crypto/gcrypt/Handle.h
    crypto/gcrypt/Initialization.h
    crypto/gcrypt/Utilities.h
    crypto/tasn1/Utilities.h

    cf/AudioToolboxSoftLink.h
    # MAVERICKS_BACKPORT: absent from upstream Mac PAL header list; CoreAudioExtras backfills CoreAudio
    # type/constant declarations the 10.9 SDK lacks, reachable via <pal/cf/CoreAudioExtras.h>.
    cf/CoreAudioExtras.h
    cf/CoreMediaSoftLink.h
    cf/CoreTextSoftLink.h
    cf/OTSVGTable.h
    cf/VideoToolboxSoftLink.h

    cg/CoreGraphicsSoftLink.h

    # MAVERICKS_BACKPORT: absent from upstream Mac PAL header list; AVFAudio / Accessibility soft-link headers
    # added so WebCore audio and accessibility sources resolve their includes on this Mac build.
    cocoa/AVFAudioSoftLink.h
    cocoa/AccessibilitySoftLink.h
    cocoa/AppSSOSoftLink.h
    cocoa/AVFoundationSoftLink.h
    # MAVERICKS_BACKPORT: absent from upstream Mac PAL header list (Contacts soft-link, reachable for unified build).
    cocoa/ContactsSoftLink.h
    cocoa/CoreMLSoftLink.h
    cocoa/CoreMaterialSoftLink.h
    cocoa/CoreTelephonySoftLink.h
    cocoa/CryptoKitPrivateSoftLink.h
    cocoa/DataDetectorsCoreSoftLink.h
    # MAVERICKS_BACKPORT: absent from upstream Mac PAL header list (EnhancedSecurity header for WebKit process bootstrap).
    cocoa/EnhancedSecurityCocoa.h
    cocoa/LinkPresentationSoftLink.h
    # MAVERICKS_BACKPORT: absent from upstream Mac PAL header list (LockdownMode header for WebKit process bootstrap).
    cocoa/LockdownModeCocoa.h
    cocoa/MediaToolboxSoftLink.h
    cocoa/NaturalLanguageSoftLink.h
    cocoa/OpenGLSoftLinkCocoa.h
    cocoa/PassKitSoftLink.h
    cocoa/QuartzCoreSoftLink.h
    cocoa/RevealSoftLink.h
    cocoa/ScreenTimeSoftLink.h
    cocoa/SpeechSoftLink.h
    cocoa/TranslationUIServicesSoftLink.h
    cocoa/UsageTrackingSoftLink.h
    cocoa/VisionKitCoreSoftLink.h
    cocoa/VisionSoftLink.h
    # MAVERICKS_BACKPORT: absent from upstream Mac PAL header list; WebContentAnalysis / WebContentRestrictions
    # soft-link headers added so WebKit parental-controls sources resolve their includes on this Mac build.
    cocoa/WebContentAnalysisSoftLink.h
    cocoa/WebContentRestrictionsSoftLink.h
    cocoa/WebPrivacySoftLink.h
    cocoa/WritingToolsUISoftLink.h

    mac/DataDetectorsSoftLink.h
    mac/LookupSoftLink.h
    mac/QuickLookUISoftLink.h
    # MAVERICKS_BACKPORT: absent from upstream Mac PAL header list (ScreenCaptureKit soft-link, reachable for unified build).
    mac/ScreenCaptureKitSoftLink.h

    spi/cf/CFNetworkConnectionCacheSPI.h
    spi/cf/CFNetworkSPI.h
    spi/cf/CFNotificationCenterSPI.h
    spi/cf/CFUtilitiesSPI.h
    spi/cf/CoreAudioSPI.h
    spi/cf/CoreMediaSPI.h
    spi/cf/CoreTextSPI.h
    spi/cf/CoreVideoSPI.h
    spi/cf/MediaAccessibilitySPI.h
    # MAVERICKS_BACKPORT: absent from upstream Mac PAL header list (VideoToolbox SPI, reachable for unified build).
    spi/cf/VideoToolboxSPI.h

    spi/cg/CoreGraphicsSPI.h
    spi/cg/ImageIOSPI.h

    # MAVERICKS_BACKPORT: absent from upstream Mac PAL header list (ARKit SPI, reachable for unified build).
    spi/cocoa/ARKitSPI.h
    spi/cocoa/AVAssetWriterSPI.h
    spi/cocoa/AVFoundationSPI.h
    spi/cocoa/AVKitSPI.h
    # MAVERICKS_BACKPORT: absent from upstream Mac PAL header list (AVStreamDataParser SPI, reachable for unified build).
    spi/cocoa/AVStreamDataParserSPI.h
    spi/cocoa/AXSpeechManagerSPI.h
    spi/cocoa/AccessibilitySupportSPI.h
    spi/cocoa/AccessibilitySupportSoftLink.h
    spi/cocoa/AppSSOSPI.h
    # MAVERICKS_BACKPORT: absent from upstream Mac PAL header list (AudioToolboxCore SPI, reachable for unified build).
    spi/cocoa/AudioToolboxCoreSPI.h
    spi/cocoa/AuthKitSPI.h
    spi/cocoa/AudioToolboxSPI.h
    spi/cocoa/CommonCryptoSPI.h
    # MAVERICKS_BACKPORT: absent from upstream Mac PAL header list; Contacts / CoreCrypto / CoreMotion SPI
    # headers added so WebCore/WebKit sources resolve their includes on this single-config Mac build.
    spi/cocoa/ContactsSPI.h
    spi/cocoa/CoreCryptoSPI.h
    spi/cocoa/CoreMotionSPI.h
    spi/cocoa/CoreMaterialSPI.h
    spi/cocoa/CoreServicesSPI.h
    spi/cocoa/CoreTelephonySPI.h
    spi/cocoa/CryptoKitPrivateSPI.h
    spi/cocoa/DataDetectorsCoreSPI.h
    spi/cocoa/FeatureFlagsSPI.h
    # MAVERICKS_BACKPORT: absent from upstream Mac PAL header list (Foundation SPI, reachable for unified build).
    spi/cocoa/FoundationSPI.h
    spi/cocoa/FilePortSPI.h
    spi/cocoa/IOKitSPI.h
    spi/cocoa/IOPMLibSPI.h
    spi/cocoa/IOPSLibSPI.h
    spi/cocoa/LaunchServicesSPI.h
    spi/cocoa/LinkPresentationSPI.h
    spi/cocoa/MediaToolboxSPI.h
    spi/cocoa/MetalSPI.h
    spi/cocoa/NEFilterSourceSPI.h
    spi/cocoa/NSAccessibilitySPI.h
    spi/cocoa/NSAttributedStringSPI.h
    spi/cocoa/NSButtonCellSPI.h
    spi/cocoa/NSCalendarDateSPI.h
    spi/cocoa/NSExtensionSPI.h
    spi/cocoa/NSFileManagerSPI.h
    # MAVERICKS_BACKPORT: absent from upstream Mac PAL header list (NSKeyedUnarchiver SPI, reachable for unified build).
    spi/cocoa/NSKeyedUnarchiverSPI.h
    spi/cocoa/NSFileSizeFormatterSPI.h
    spi/cocoa/NSProgressSPI.h
    spi/cocoa/NSStringSPI.h
    spi/cocoa/NSTouchBarSPI.h
    spi/cocoa/NSURLConnectionSPI.h
    spi/cocoa/NSURLDownloadSPI.h
    spi/cocoa/NSURLFileTypeMappingsSPI.h
    spi/cocoa/NSUserDefaultsSPI.h
    spi/cocoa/NSXPCConnectionSPI.h
    spi/cocoa/NetworkSPI.h
    spi/cocoa/NotifySPI.h
    spi/cocoa/PassKitInstallmentsSPI.h
    spi/cocoa/PassKitSPI.h
    spi/cocoa/QuartzCoreSPI.h
    spi/cocoa/RevealSPI.h
    spi/cocoa/SQLite3SPI.h
    spi/cocoa/SceneKitSPI.h
    spi/cocoa/SecKeyProxySPI.h
    spi/cocoa/ServersSPI.h
    spi/cocoa/SpeechSPI.h
    spi/cocoa/TCCSPI.h
    spi/cocoa/URLFormattingSPI.h
    # MAVERICKS_BACKPORT: absent from upstream Mac PAL header list; cocoa SPI headers added so WebCore/WebKit
    # sources resolve their includes on this single-config Mac build.
    spi/cocoa/TranslationUIServicesSPI.h
    spi/cocoa/UIFoundationSPI.h
    spi/cocoa/UniformTypeIdentifiersSPI.h
    spi/cocoa/VisionKitCoreSPI.h
    # MAVERICKS_BACKPORT: absent from upstream Mac PAL header list (WebContentRestrictions SPI, reachable for unified build).
    spi/cocoa/WebContentRestrictionsSPI.h
    spi/cocoa/WebFilterEvaluatorSPI.h
    # MAVERICKS_BACKPORT: absent from upstream Mac PAL header list; WebPrivacy / WritingTools SPI headers added for the unified build.
    spi/cocoa/WebPrivacySPI.h
    spi/cocoa/WritingToolsSPI.h
    spi/cocoa/WritingToolsUISPI.h
    spi/cocoa/pthreadSPI.h

    # MAVERICKS_BACKPORT: absent from upstream Mac PAL header list; iOS SPI headers added so the unified-build
    # of cross-platform PAL/WebCore sources resolves their includes on this single-config Mac build.
    spi/ios/AXRuntimeSPI.h
    spi/ios/BarcodeSupportSPI.h
    spi/ios/BrowserEngineKitSPI.h
    spi/ios/CelestialSPI.h
    spi/ios/CoreUISPI.h
    spi/ios/DataDetectorsUISPI.h
    # MAVERICKS_BACKPORT: absent from upstream Mac PAL header list (iOS DataDetectorsUI soft-link, reachable for unified build).
    spi/ios/DataDetectorsUISoftLink.h
    spi/ios/GraphicsServicesSPI.h
    # MAVERICKS_BACKPORT: absent from upstream Mac PAL header list; iOS SPI headers added so the unified build resolves their includes.
    spi/ios/IOKitSPIIOS.h
    spi/ios/ManagedConfigurationSPI.h
    spi/ios/MediaPlayerSPI.h
    spi/ios/MobileGestaltSPI.h
    spi/ios/MobileKeyBagSPI.h
    spi/ios/OpenGLESSPI.h
    spi/ios/QuickLookSPI.h
    spi/ios/SBSStatusBarSPI.h
    spi/ios/SystemPreviewSPI.h
    spi/ios/UIKitSPI.h

    spi/mac/CoreUISPI.h
    spi/mac/DataDetectorsSPI.h
    spi/mac/HIServicesSPI.h
    spi/mac/HIToolboxSPI.h
    spi/mac/IOKitSPIMac.h
    spi/mac/LookupSPI.h
    spi/mac/MediaRemoteSPI.h
    spi/mac/NSAppearanceSPI.h
    spi/mac/NSApplicationSPI.h
    spi/mac/NSCellSPI.h
    spi/mac/NSColorSPI.h
    spi/mac/NSColorWellSPI.h
    spi/mac/NSEventSPI.h
    spi/mac/NSGraphicsSPI.h
    spi/mac/NSImageSPI.h
    spi/mac/NSImmediateActionGestureRecognizerSPI.h
    spi/mac/NSMenuSPI.h
    spi/mac/NSPasteboardSPI.h
    spi/mac/NSPopoverColorWellSPI.h
    spi/mac/NSPopoverSPI.h
    spi/mac/NSResponderSPI.h
    spi/mac/NSScrollViewSPI.h
    spi/mac/NSScrollerImpSPI.h
    spi/mac/NSScrollingInputFilterSPI.h
    spi/mac/NSScrollingMomentumCalculatorSPI.h
    spi/mac/NSServicesRolloverButtonCellSPI.h
    spi/mac/NSSharingServicePickerSPI.h
    spi/mac/NSSharingServiceSPI.h
    spi/mac/NSSpellCheckerSPI.h
    spi/mac/NSTextFinderSPI.h
    spi/mac/NSTextInputContextSPI.h
    spi/mac/NSTextTableSPI.h
    spi/mac/NSUndoManagerSPI.h
    spi/mac/NSViewSPI.h
    spi/mac/NSWindowSPI.h
    spi/mac/PIPSPI.h
    spi/mac/QuickLookMacSPI.h
    spi/mac/SystemPreviewSPI.h
    # MAVERICKS_BACKPORT: absent from upstream Mac PAL header list; AppKit-cell / PowerLog / Quarantine SPI
    # headers added so WebCore form-control and download sources resolve their includes on 10.9.
    spi/mac/NSSearchFieldCellSPI.h
    spi/mac/NSTextFieldCellSPI.h
    spi/mac/PowerLogSPI.h
    spi/mac/QuarantineSPI.h
    spi/mac/TelephonyUtilitiesSPI.h

    system/cocoa/SleepDisablerCocoa.h

    # MAVERICKS_BACKPORT: absent from upstream Mac PAL header list; iOS soft-link / system headers added so the
    # unified-build of cross-platform PAL sources resolves their includes on this single-config Mac build.
    ios/AVRoutingSoftLink.h
    ios/ManagedConfigurationSoftLink.h
    ios/QuickLookSoftLink.h
    ios/SystemStatusSoftLink.h
    ios/UIKitSoftLink.h

    # MAVERICKS_BACKPORT: absent from upstream Mac PAL header list (iOS idiom header reachable for unified build).
    system/ios/UserInterfaceIdiom.h

    system/mac/DefaultSearchProvider.h
    system/mac/PopupMenu.h
    system/mac/SystemSleepListenerMac.h
    system/mac/WebPanel.h
)

list(APPEND PAL_SOURCES
    avfoundation/MediaTimeAVFoundation.cpp
    avfoundation/OutputContext.mm
    avfoundation/OutputDevice.mm

    cf/AudioToolboxSoftLink.cpp
    cf/CoreMediaSoftLink.cpp
    cf/CoreTextSoftLink.cpp
    cf/OTSVGTable.cpp
    cf/VideoToolboxSoftLink.cpp

    cg/CoreGraphicsSoftLink.cpp

    cocoa/AppSSOSoftLink.mm
    cocoa/AVFoundationSoftLink.mm
    cocoa/CoreMLSoftLink.mm
    cocoa/CoreMaterialSoftLink.mm
    # MAVERICKS_BACKPORT: absent from upstream PAL cmake list; defines PAL::get_Contacts_* / CN* class
    # soft-link singletons referenced by WebKit's CoreIPCContacts.mm (HAVE(CONTACTS)).
    cocoa/ContactsSoftLink.mm
    cocoa/CoreTelephonySoftLink.mm
    # MAVERICKS_BACKPORT: absent from upstream PAL cmake list; define PAL::setEnhancedSecurityEnabledForCurrentProcess
    # and PAL::setLockdownModeEnabledForCurrentProcess referenced by WebKit process bootstrap.
    cocoa/EnhancedSecurityCocoa.mm
    cocoa/LockdownModeCocoa.mm
    cocoa/CryptoKitPrivateSoftLink.mm
    cocoa/DataDetectorsCoreSoftLink.mm
    cocoa/FileSizeFormatterCocoa.mm
    cocoa/LinkPresentationSoftLink.mm
    cocoa/MediaToolboxSoftLink.cpp
    cocoa/NaturalLanguageSoftLink.mm
    cocoa/OpenGLSoftLinkCocoa.mm
    cocoa/PassKitSoftLink.mm
    cocoa/QuartzCoreSoftLink.mm
    cocoa/RevealSoftLink.mm
    cocoa/ScreenTimeSoftLink.mm
    cocoa/SpeechSoftLink.mm
    cocoa/TranslationUIServicesSoftLink.mm
    cocoa/UsageTrackingSoftLink.mm
    # MAVERICKS_BACKPORT: absent from upstream PAL cmake list; defines the PAL::getAXCustomContentClassSingleton
    # Accessibility soft-link accessor referenced by accessibility/mac/WebAccessibilityObjectWrapperBase.mm.
    cocoa/AccessibilitySoftLink.mm
    # MAVERICKS_BACKPORT: absent from upstream PAL cmake list; defines PAL::VisionLibrary /
    # PAL::getVN*Singleton soft-link helpers referenced by ImageAnalysisUtilities.mm + ShapeDetection.
    cocoa/VisionSoftLink.mm
    cocoa/VisionKitCoreSoftLink.mm
    cocoa/WebPrivacySoftLink.mm
    cocoa/WritingToolsUISoftLink.mm

    # MAVERICKS_BACKPORT: CryptoDigest + tasn1 ASN.1 helpers now use libgcrypt/libtasn1
    # (same source files as the GTK port). The CommonCrypto variant relied on
    # CC_SHA224* symbols missing from 10.9.
    crypto/gcrypt/CryptoDigestGCrypt.cpp
    crypto/tasn1/Utilities.cpp

    mac/DataDetectorsSoftLink.mm
    mac/LookupSoftLink.mm
    mac/QuickLookUISoftLink.mm

    spi/cocoa/AccessibilitySupportSoftLink.cpp

    system/ClockGeneric.cpp

    system/cocoa/SleepDisablerCocoa.cpp

    system/mac/DefaultSearchProvider.cpp
    system/mac/PopupMenu.mm
    system/mac/SoundMac.mm
    system/mac/SystemSleepListenerMac.mm
    system/mac/WebPanel.mm

    text/ios/TextEncodingRegistryIOS.mm

    text/mac/KillRingMac.mm
    text/mac/TextEncodingRegistryMac.mm
)

list(APPEND PAL_PRIVATE_INCLUDE_DIRECTORIES
    "${CMAKE_SOURCE_DIR}/Source/ThirdParty/libwebrtc/Source"
    "${PAL_DIR}/pal/avfoundation"
    "${PAL_DIR}/pal/cf"
    "${PAL_DIR}/pal/cocoa"
    "${PAL_DIR}/pal/spi/cf"
    "${PAL_DIR}/pal/spi/cg"
    "${PAL_DIR}/pal/spi/cocoa"
    "${PAL_DIR}/pal/spi/mac"
    # MAVERICKS_BACKPORT: gcrypt-based CryptoDigest needs libgcrypt headers.
    "${MAVERICKS_DEPS}/include"
)
