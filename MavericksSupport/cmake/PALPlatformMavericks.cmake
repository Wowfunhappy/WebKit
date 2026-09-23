# PAL source selection and public headers for Mavericks.

# WebCrypto uses the GCrypt backend.
set(MAVERICKS_WITHHELD_PAL_COCOA_SOURCES
    "crypto/CryptoAlgorithmAESGCMCocoa.cpp"
    "crypto/CryptoAlgorithmAESKWCocoaBridging.cpp"
    "crypto/CryptoAlgorithmEd25519CocoaBridging.cpp"
    "crypto/CryptoAlgorithmHKDFCocoaBridging.cpp"
    "crypto/CryptoAlgorithmHMACCocoaBridging.cpp"
    "crypto/CryptoAlgorithmX25519CocoaBridging.cpp"
    "crypto/CryptoEDKeyBridging.cpp"
    "crypto/PlatformECKey.cpp"
    "crypto/commoncrypto/CryptoDigestCommonCrypto.cpp"
)
set(MAVERICKS_ADDED_PAL_COCOA_SOURCES "")
MAVERICKS_FILTER_SOURCE_LIST("${PAL_DIR}/pal" PAL_UNIFIED_SOURCE_LIST_FILES "SourcesCocoa.txt"
    MAVERICKS_WITHHELD_PAL_COCOA_SOURCES MAVERICKS_ADDED_PAL_COCOA_SOURCES)

list(APPEND PAL_PUBLIC_HEADERS
    crypto/gcrypt/Handle.h
    crypto/gcrypt/Initialization.h
    crypto/gcrypt/Utilities.h
    crypto/tasn1/Utilities.h
    cf/CoreAudioExtras.h
    cocoa/AVFAudioSoftLink.h
    cocoa/AccessibilitySoftLink.h
    cocoa/ContactsSoftLink.h
    cocoa/EnhancedSecurityCocoa.h
    cocoa/LockdownModeCocoa.h
    cocoa/WebContentAnalysisSoftLink.h
    cocoa/WebContentRestrictionsSoftLink.h
    mac/ScreenCaptureKitSoftLink.h
    spi/cf/VideoToolboxSPI.h
    spi/cocoa/ARKitSPI.h
    spi/cocoa/AVStreamDataParserSPI.h
    spi/cocoa/AudioToolboxCoreSPI.h
    spi/cocoa/ContactsSPI.h
    spi/cocoa/CoreCryptoSPI.h
    spi/cocoa/CoreMotionSPI.h
    spi/cocoa/FoundationSPI.h
    spi/cocoa/NSKeyedUnarchiverSPI.h
    spi/cocoa/TranslationUIServicesSPI.h
    spi/cocoa/UIFoundationSPI.h
    spi/cocoa/UniformTypeIdentifiersSPI.h
    spi/cocoa/WebContentRestrictionsSPI.h
    spi/cocoa/WebPrivacySPI.h
    spi/cocoa/WritingToolsSPI.h
    spi/cocoa/WritingToolsUISPI.h
    spi/ios/AXRuntimeSPI.h
    spi/ios/BarcodeSupportSPI.h
    spi/ios/BrowserEngineKitSPI.h
    spi/ios/CelestialSPI.h
    spi/ios/CoreUISPI.h
    spi/ios/DataDetectorsUISoftLink.h
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
    spi/mac/NSSearchFieldCellSPI.h
    spi/mac/NSTextFieldCellSPI.h
    spi/mac/PowerLogSPI.h
    spi/mac/QuarantineSPI.h
    ios/AVRoutingSoftLink.h
    ios/ManagedConfigurationSoftLink.h
    ios/QuickLookSoftLink.h
    ios/SystemStatusSoftLink.h
    ios/UIKitSoftLink.h
    system/ios/UserInterfaceIdiom.h
)

list(APPEND PAL_SOURCES
    crypto/gcrypt/CryptoDigestGCrypt.cpp
    crypto/tasn1/Utilities.cpp
)

list(APPEND PAL_PRIVATE_INCLUDE_DIRECTORIES
    "${MAVERICKS_DEPS}/include"
)
